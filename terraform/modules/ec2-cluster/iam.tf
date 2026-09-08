# Two roles rather than one shared role. The server needs to publish the
# cluster join token; agents only need to read it. Giving agents write
# access would mean any compromised worker could rewrite the token every
# future node joins with.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  token_parameter_name = "/${var.name_prefix}/k3s/node-token"
}

# --- server role ---

resource "aws_iam_role" "server" {
  name               = "${var.name_prefix}-k3s-server-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# tfsec:ignore:aws-iam-no-policy-wildcards KMS actions cannot name the AWS-managed SSM key by ARN, so the restriction is the kms:ViaService condition below, which confines use to SSM alone.
data "aws_iam_policy_document" "server" {
  statement {
    sid       = "PublishJoinToken"
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.token_parameter_name}"]
  }

  statement {
    sid     = "EncryptJoinToken"
    actions = ["kms:Encrypt", "kms:Decrypt"]
    # The AWS-managed SSM key. Scoped so the role cannot use it against any
    # other service.
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "server" {
  name   = "${var.name_prefix}-k3s-server-policy"
  role   = aws_iam_role.server.id
  policy = data.aws_iam_policy_document.server.json
}

# Session Manager access, which is how the cluster is reached at all: the
# nodes have no public IP and there is no bastion or SSH key anywhere.
resource "aws_iam_role_policy_attachment" "server_ssm" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "server_ecr" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "server" {
  name = "${var.name_prefix}-k3s-server-profile"
  role = aws_iam_role.server.name
}

# --- agent role ---

resource "aws_iam_role" "agent" {
  name               = "${var.name_prefix}-k3s-agent-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# tfsec:ignore:aws-iam-no-policy-wildcards Same as the server role: the wildcard is constrained by the kms:ViaService condition, and the parameter itself is named exactly.
data "aws_iam_policy_document" "agent" {
  statement {
    sid = "ReadJoinToken"
    # Read only. An agent never needs to change the token.
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.token_parameter_name}"]
  }

  statement {
    sid       = "DecryptJoinToken"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "agent" {
  name   = "${var.name_prefix}-k3s-agent-policy"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent.json
}

resource "aws_iam_role_policy_attachment" "agent_ssm" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "agent_ecr" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "agent" {
  name = "${var.name_prefix}-k3s-agent-profile"
  role = aws_iam_role.agent.name
}
