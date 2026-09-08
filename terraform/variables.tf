variable "project_name" {
  description = "Prefix for every resource name, so resources are identifiable in a shared account."
  type        = string
  default     = "marketly"
}

variable "environment" {
  description = "Environment name applied as a tag and name suffix."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "Region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "One public subnet per availability zone. The ALB and the NAT instance live here."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "One private subnet per availability zone. k3s nodes and RDS live here, unreachable from the internet."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "az_count" {
  description = "Number of availability zones to span. RDS subnet groups require at least two."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2: an RDS subnet group and an ALB both require two AZs."
  }
}

# --- compute ---

variable "nat_instance_type" {
  description = "Instance type for the NAT instance. Replaces a managed NAT Gateway, which bills hourly."
  type        = string
  default     = "t3.micro"
}

variable "k3s_server_instance_type" {
  description = "Instance type for the k3s control-plane node."
  type        = string
  default     = "t3.micro"
}

variable "k3s_agent_instance_type" {
  description = "Instance type for the k3s worker nodes in the Auto Scaling Group."
  type        = string
  default     = "t3.micro"
}

variable "worker_min_size" {
  description = "Minimum number of k3s worker instances."
  type        = number
  default     = 2
}

variable "worker_max_size" {
  description = "Maximum number of k3s worker instances."
  type        = number
  default     = 3
}

variable "worker_desired_capacity" {
  description = "Desired number of k3s worker instances."
  type        = number
  default     = 2
}

variable "ingress_nodeport" {
  description = "NodePort that Traefik listens on across every node. The ALB target group forwards to this port."
  type        = number
  default     = 30080
}

# --- database ---

variable "db_instance_class" {
  description = "RDS instance class. db.t3.micro stays within the free tier."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Storage in GB. The free tier covers 20."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Initial database name. All three services connect to it, each owning its own schema."
  type        = string
  default     = "marketly"
}

variable "db_username" {
  description = "Master username. The password is never set here — RDS generates it and stores it in Secrets Manager."
  type        = string
  default     = "marketly_admin"
}

variable "db_multi_az" {
  description = "Multi-AZ doubles cost and is outside the free tier, so it is off by default."
  type        = bool
  default     = false
}

# --- CI/CD ---

variable "github_repo" {
  description = "owner/repo allowed to assume the CI role over OIDC. Only this repository can obtain credentials."
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repo))
    error_message = "github_repo must be in owner/repo form, e.g. OsamaBarakat1/marketly-devops-capstone."
  }
}

variable "github_deploy_branch" {
  description = "Branch whose workflow runs may assume the CI role. Restricting this stops a pull request from a fork from obtaining credentials."
  type        = string
  default     = "main"
}

variable "ecr_repositories" {
  description = "One ECR repository per deployable component."
  type        = list(string)
  default     = ["auth-service", "catalog-service", "orders-service", "frontend"]
}

variable "state_bucket_name" {
  description = "Remote state bucket created by terraform/bootstrap. Scopes the CI role's state access to this bucket alone."
  type        = string
  default     = ""
}

variable "state_lock_table_name" {
  description = "DynamoDB lock table created by terraform/bootstrap."
  type        = string
  default     = "marketly-tf-locks"
}
