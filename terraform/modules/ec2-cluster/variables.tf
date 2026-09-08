variable "name_prefix" {
  type = string
}

variable "private_subnet_ids" {
  description = "Nodes run here: no public IPs, outbound only through the NAT instance."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "server_instance_type" {
  type = string
}

variable "agent_instance_type" {
  type = string
}

variable "min_size" {
  type = number
}

variable "max_size" {
  type = number
}

variable "desired_capacity" {
  type = number
}

variable "ingress_nodeport" {
  description = "NodePort Traefik is pinned to so the ALB has a fixed target port."
  type        = number
}

variable "aws_region" {
  type = string
}
