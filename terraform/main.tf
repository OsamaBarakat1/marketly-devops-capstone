# Wires the eight modules together. Each one receives the outputs of the
# modules before it, so the dependency graph — and therefore the create and
# destroy order — is derived rather than declared.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# 1. The network everything else lives in.
module "vpc" {
  source = "./modules/vpc"

  name_prefix          = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  az_count             = var.az_count
}

# 2. Firewall tiers. Created before anything they attach to.
module "security_groups" {
  source = "./modules/security-groups"

  name_prefix      = local.name_prefix
  vpc_id           = module.vpc.vpc_id
  vpc_cidr         = module.vpc.vpc_cidr
  ingress_nodeport = var.ingress_nodeport
}

# 3. Outbound internet for the private subnets. Must exist before any node
#    boots, since bootstrap downloads k3s.
module "nat_instance" {
  source = "./modules/nat-instance"

  name_prefix             = local.name_prefix
  subnet_id               = module.vpc.public_subnet_ids[0]
  security_group_id       = module.security_groups.nat_sg_id
  instance_type           = var.nat_instance_type
  private_route_table_ids = module.vpc.private_route_table_ids
  vpc_cidr                = module.vpc.vpc_cidr
}

# 4. Image registries. Independent of the network.
module "ecr" {
  source = "./modules/ecr"

  name_prefix      = local.name_prefix
  repository_names = var.ecr_repositories
}

# 5. The cluster itself.
module "ec2_cluster" {
  source = "./modules/ec2-cluster"

  name_prefix          = local.name_prefix
  private_subnet_ids   = module.vpc.private_subnet_ids
  security_group_id    = module.security_groups.k3s_sg_id
  server_instance_type = var.k3s_server_instance_type
  agent_instance_type  = var.k3s_agent_instance_type
  min_size             = var.worker_min_size
  max_size             = var.worker_max_size
  desired_capacity     = var.worker_desired_capacity
  ingress_nodeport     = var.ingress_nodeport
  aws_region           = var.aws_region

  # Stated explicitly because nothing else in the graph expresses it: node
  # user-data downloads the k3s installer, so the private subnets need a
  # working default route before any node boots. Passing an unused value in
  # as a variable would not order the resources inside this module; a
  # module-level depends_on does.
  depends_on = [module.nat_instance]
}

# 6. The database the three services share.
module "rds" {
  source = "./modules/rds"

  name_prefix        = local.name_prefix
  private_subnet_ids = module.vpc.private_subnet_ids
  security_group_id  = module.security_groups.rds_sg_id
  instance_class     = var.db_instance_class
  allocated_storage  = var.db_allocated_storage
  db_name            = var.db_name
  db_username        = var.db_username
  multi_az           = var.db_multi_az
}

# 7. Public entry point, attached to the worker ASG.
module "alb" {
  source = "./modules/alb"

  name_prefix            = local.name_prefix
  vpc_id                 = module.vpc.vpc_id
  public_subnet_ids      = module.vpc.public_subnet_ids
  security_group_id      = module.security_groups.alb_sg_id
  autoscaling_group_name = module.ec2_cluster.autoscaling_group_name
  server_instance_id     = module.ec2_cluster.server_instance_id
  ingress_nodeport       = var.ingress_nodeport
}

# 8. CI/CD identity. Scoped to the repositories created in step 4.
module "iam_oidc" {
  source = "./modules/iam-oidc"

  name_prefix           = local.name_prefix
  github_repo           = var.github_repo
  deploy_branch         = var.github_deploy_branch
  ecr_repository_arns   = module.ecr.repository_arns
  state_bucket_name     = var.state_bucket_name
  state_lock_table_name = var.state_lock_table_name
}
