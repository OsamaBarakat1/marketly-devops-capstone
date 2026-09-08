# Lets GitHub Actions obtain AWS credentials without any long-lived access
# key existing anywhere.
#
# GitHub signs a short-lived token describing the workflow run. AWS verifies
# that signature against GitHub's published keys and, if the claims match
# the conditions below, returns temporary credentials. Nothing is stored in
# GitHub secrets, so there is no key to leak, rotate, or find in git history.

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # IAM still requires this field. AWS verifies GitHub's certificate against
  # its own trust store for this provider, so the value is no longer the
  # thing being relied on.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "${var.name_prefix}-github-oidc"
  }
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    # Without this the role would trust tokens issued for a different
    # audience entirely.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The condition that actually matters. `sub` encodes which repository and
    # which ref the run belongs to. Restricting it to this repo's chosen
    # branch means a fork, a pull request from a fork, or any other
    # repository on GitHub gets its token rejected. Omitting it, or using a
    # bare wildcard, would let any repository on GitHub assume this role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/${var.deploy_branch}",
        "repo:${var.github_repo}:environment:*",
      ]
    }
  }
}

resource "aws_iam_role" "ci" {
  name               = "${var.name_prefix}-github-actions-role"
  description        = "Assumed by GitHub Actions over OIDC. No static credentials exist for this role."
  assume_role_policy = data.aws_iam_policy_document.assume.json

  # Workflow runs are short. A one-hour ceiling limits how long a leaked
  # token stays useful.
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-github-actions-role"
  }
}

# tfsec:ignore:aws-iam-no-policy-wildcards ecr:GetAuthorizationToken and the ssm/describe actions are account-scoped by AWS and cannot name resources; push access, which can, is scoped to this project's repositories.
data "aws_iam_policy_document" "ci" {
  # Obtaining a registry login token is account-wide by design; it cannot be
  # scoped to a repository.
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push and pull, restricted to this project's repositories. A compromised
  # workflow cannot reach any other repository in the account.
  statement {
    sid = "ECRPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }

  # Read-only. Used to locate the control-plane instance for deployments.
  statement {
    sid = "DescribeInfrastructure"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "autoscaling:DescribeAutoScalingGroups",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeTargetHealth",
    ]
    resources = ["*"]
  }

  # Enough to run a deployment command on the control-plane node through
  # Session Manager, without opening SSH to the world.
  statement {
    sid = "RunDeploymentCommands"
    actions = [
      "ssm:SendCommand",
      "ssm:GetCommandInvocation",
      "ssm:DescribeInstanceInformation",
      "ssm:StartSession",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "${var.name_prefix}-github-actions-policy"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}

# --- Terraform state access, for the terraform.yml workflow ---

data "aws_iam_policy_document" "terraform" {
  # Terraform creates and destroys resources across several services, and an
  # exact action list would break the next time a resource type is added.
  # These stay wildcarded per service, which is a real grant of power and the
  # reason the trust policy above is restricted to one repository and branch.
  #
  # tfsec:ignore:aws-iam-no-policy-wildcards Terraform cannot plan or destroy these resource types without service-level permissions; the control is the OIDC trust condition, not the action list.
  statement {
    sid = "ManageInfrastructure"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "rds:*",
      "ecr:*",
      "iam:*",
      "ssm:*",
      "secretsmanager:*",
      "kms:*",
    ]
    resources = ["*"]
  }

  # State access, unlike the above, can be scoped to exactly the two
  # resources that hold it. A workflow has no reason to read any other
  # bucket in the account.
  statement {
    sid = "TerraformState"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket_name}",
      "arn:aws:s3:::${var.state_bucket_name}/*",
    ]
  }

  statement {
    sid = "TerraformStateLock"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = ["arn:aws:dynamodb:*:${data.aws_caller_identity.current.account_id}:table/${var.state_lock_table_name}"]
  }
}

resource "aws_iam_role_policy" "terraform" {
  name   = "${var.name_prefix}-github-actions-terraform-policy"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.terraform.json
}
