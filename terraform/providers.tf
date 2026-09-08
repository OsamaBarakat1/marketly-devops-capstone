provider "aws" {
  region = var.aws_region

  # Credentials are never set here. The provider reads them from the ambient
  # chain — environment variables, ~/.aws/credentials, or the short-lived
  # role credentials GitHub Actions receives over OIDC. Putting keys in this
  # file would commit them to the repository.

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
