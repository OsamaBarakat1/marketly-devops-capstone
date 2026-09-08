# Everything here is safe to print. Credentials are deliberately absent:
# the RDS password lives in Secrets Manager and the cluster join token in
# SSM, and only their identifiers are surfaced.

output "application_url" {
  description = "Public address of the application."
  value       = module.alb.url
}

output "alb_dns_name" {
  value = module.alb.dns_name
}

# --- cluster access ---

output "k3s_server_instance_id" {
  description = "Connect with: aws ssm start-session --target <this value>"
  value       = module.ec2_cluster.server_instance_id
}

output "kubectl_access_command" {
  description = "One-liner to reach the cluster. There is no SSH key and no public IP."
  value       = "aws ssm start-session --target ${module.ec2_cluster.server_instance_id} --region ${var.aws_region}"
}

output "autoscaling_group_name" {
  value = module.ec2_cluster.autoscaling_group_name
}

# --- registries ---

output "ecr_repository_urls" {
  description = "Push targets for the CI pipeline."
  value       = module.ecr.repository_urls
}

output "ecr_registry" {
  value = module.ecr.registry_url
}

# --- database ---

output "rds_endpoint" {
  description = "Host and port only. Reachable exclusively from the cluster security group."
  value       = module.rds.endpoint
}

output "rds_database_name" {
  value = module.rds.db_name
}

output "rds_username" {
  value = module.rds.username
}

output "rds_password_secret_arn" {
  description = <<-EOT
    Secrets Manager secret holding the generated master password. Read it
    when creating the Kubernetes Secret:

      aws secretsmanager get-secret-value --secret-id <arn> \
        --query SecretString --output text
  EOT
  value       = module.rds.master_user_secret_arn
}

# --- CI/CD ---

output "github_actions_role_arn" {
  description = "Store as the AWS_ROLE_ARN repository variable in GitHub. It is not a secret: without an OIDC token from the permitted repository and branch, it grants nothing."
  value       = module.iam_oidc.role_arn
}

output "nat_instance_public_ip" {
  description = "Address that outbound traffic from private subnets appears to come from."
  value       = module.nat_instance.public_ip
}
