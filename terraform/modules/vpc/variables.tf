variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "public_subnet_cidrs" {
  description = "CIDR per public subnet, one per availability zone."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR per private subnet, one per availability zone."
  type        = list(string)
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across."
  type        = number
}
