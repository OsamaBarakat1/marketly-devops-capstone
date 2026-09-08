output "repository_urls" {
  description = "Component name to repository URL, used by CI when tagging images."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  description = "Consumed by the OIDC role so its push permission is scoped to these repositories only."
  value       = [for repo in aws_ecr_repository.this : repo.arn]
}

output "registry_url" {
  description = "Registry host, shared by every repository in the account."
  value       = length(aws_ecr_repository.this) > 0 ? split("/", values(aws_ecr_repository.this)[0].repository_url)[0] : ""
}
