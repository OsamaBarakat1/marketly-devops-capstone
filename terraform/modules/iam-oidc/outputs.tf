output "role_arn" {
  description = "Set as the AWS_ROLE_ARN repository variable in GitHub. Not a secret — it grants nothing without a matching OIDC token."
  value       = aws_iam_role.ci.arn
}

output "role_name" {
  value = aws_iam_role.ci.name
}

output "oidc_provider_arn" {
  value = local.oidc_provider_arn
}
