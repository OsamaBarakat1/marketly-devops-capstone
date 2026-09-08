variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "The load balancer is the only public-facing component."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "autoscaling_group_name" {
  description = "Worker ASG. Attaching the target group here means scaled-out nodes register themselves."
  type        = string
}

variable "server_instance_id" {
  description = "Control-plane instance, registered directly since it is not part of the ASG."
  type        = string
}

variable "ingress_nodeport" {
  description = "Port Traefik listens on across every node."
  type        = number
}
