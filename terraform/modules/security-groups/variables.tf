variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "Used to scope the NAT instance to traffic originating inside the VPC."
  type        = string
}

variable "ingress_nodeport" {
  description = "NodePort the ALB forwards to."
  type        = number
}
