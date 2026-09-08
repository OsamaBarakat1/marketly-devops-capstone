# One-time bootstrap for remote state. Run this before the root
# configuration, because a backend cannot create the bucket it stores its
# own state in.
#
#   terraform init && terraform apply
#
# This config keeps its own state locally on purpose — it is the only thing
# that has to, and it is small enough to recreate.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "Region for the state bucket and lock table."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "marketly"
}

# S3 bucket names are globally unique across every AWS account, so a fixed
# name would collide with anyone else running this project.
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "state" {
  bucket = "${var.project_name}-tfstate-${random_id.suffix.hex}"

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
    Purpose   = "terraform-remote-state"
  }
}

# State records every resource attribute, so an accidental overwrite or
# deletion is unrecoverable without versions to roll back to.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State is the single most sensitive artefact this project produces: it holds
# resource identifiers, network layout, and any attribute a provider returns.
# Nothing about it should ever be publicly reachable.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Two concurrent applies — a colleague and a CI run, say — would otherwise
# read the same state, act on it, and write back conflicting results. The
# lock makes the second one wait.
resource "aws_dynamodb_table" "locks" {
  name         = "${var.project_name}-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}

output "state_bucket" {
  description = "Copy this into backend.tf in the parent directory."
  value       = aws_s3_bucket.state.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.locks.name
}

output "backend_config" {
  description = "The backend block to paste into ../backend.tf."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.bucket}"
        key            = "${var.project_name}/terraform.tfstate"
        region         = "${var.aws_region}"
        dynamodb_table = "${aws_dynamodb_table.locks.name}"
        encrypt        = true
      }
    }
  EOT
}
