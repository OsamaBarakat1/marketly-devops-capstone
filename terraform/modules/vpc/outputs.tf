output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  description = "Consumed by the nat-instance module, which adds the default route to each."
  value       = aws_route_table.private[*].id
}

output "availability_zones" {
  value = local.azs
}
