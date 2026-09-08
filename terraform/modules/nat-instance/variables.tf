variable "name_prefix" {
  type = string
}

variable "subnet_id" {
  description = "Public subnet the NAT instance sits in."
  type        = string
}

variable "security_group_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "private_route_table_ids" {
  description = "Private route tables that should send their default route through this instance."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "Traffic from this range is masqueraded; anything else is dropped."
  type        = string
}
