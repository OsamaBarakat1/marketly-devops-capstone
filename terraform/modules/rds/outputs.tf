output "endpoint" {
  description = "host:port for the instance."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "username" {
  value = aws_db_instance.this.username
}

# The ARN of the secret, never its value. Whoever creates the Kubernetes
# Secret reads it at deploy time:
#
#   aws secretsmanager get-secret-value --secret-id <arn> \
#     --query SecretString --output text
output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the generated master password."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
