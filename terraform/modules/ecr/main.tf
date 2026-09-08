# One repository per component, so each service is versioned and rolled back
# independently — the point of deploying them separately in the first place.

# tfsec:ignore:aws-ecr-repository-customer-key AWS-managed encryption is used because a customer-managed KMS key bills monthly per key and the images hold no secrets, only application builds.
resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name = "${var.name_prefix}-${each.value}"

  # Immutable: once a tag is pushed it can never be repointed at different
  # content. A mutable tag means the image a Deployment references today is
  # not necessarily the image it ran yesterday, which defeats both rollback
  # and any audit of what was actually deployed.
  #
  # The consequence is that CI must tag by commit SHA and cannot republish
  # ":latest" — which is the correct way to deploy to Kubernetes anyway,
  # since a moving tag gives a pod no reason to pull anything new.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Flags known CVEs in image layers on push, which is the container
    # equivalent of the dependency scanning already running on the source.
    scan_on_push = true
  }

  # The project is torn down repeatedly; without this, destroy fails on any
  # repository that still holds images.
  force_delete = true

  tags = {
    Name      = "${var.name_prefix}-${each.value}"
    Component = each.value
  }
}

# Storage is the free tier's binding constraint here (500 MB), and every
# push adds a layer set. Expiry keeps a rebuild from silently starting to
# cost money.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after one day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the most recent ${var.max_image_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
