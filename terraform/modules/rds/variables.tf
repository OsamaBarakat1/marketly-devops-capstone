variable "name_prefix" {
  type = string
}

variable "private_subnet_ids" {
  description = "Subnet group spans both AZs, which RDS requires even for a single-AZ instance."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "instance_class" {
  type = string
}

variable "allocated_storage" {
  type = number
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "multi_az" {
  type = bool
}

variable "engine_version" {
  description = "Major version only; AWS selects the current minor and patches it in the maintenance window."
  type        = string
  default     = "16"
}
