output "instance_id" {
  value = aws_instance.nat.id
}

output "network_interface_id" {
  value = aws_instance.nat.primary_network_interface_id
}

output "public_ip" {
  description = "Address that private-subnet traffic appears to originate from."
  value       = aws_eip.nat.public_ip
}
