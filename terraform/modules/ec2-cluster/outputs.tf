output "server_instance_id" {
  description = "Target for `aws ssm start-session` — the only way into the cluster."
  value       = aws_instance.server.id
}

output "server_private_ip" {
  value = aws_instance.server.private_ip
}

output "autoscaling_group_name" {
  description = "Consumed by the alb module, which attaches the target group to this group."
  value       = aws_autoscaling_group.agents.name
}

output "token_parameter_name" {
  description = "SSM parameter holding the cluster join token. The value is a SecureString and is never output."
  value       = local.token_parameter_name
}

output "server_role_arn" {
  value = aws_iam_role.server.arn
}

output "agent_role_arn" {
  value = aws_iam_role.agent.arn
}
