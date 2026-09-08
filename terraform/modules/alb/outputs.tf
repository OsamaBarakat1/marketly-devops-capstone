output "dns_name" {
  description = "Public hostname of the application."
  value       = aws_lb.this.dns_name
}

output "zone_id" {
  value = aws_lb.this.zone_id
}

output "target_group_arn" {
  value = aws_lb_target_group.nodes.arn
}

output "url" {
  value = "http://${aws_lb.this.dns_name}"
}
