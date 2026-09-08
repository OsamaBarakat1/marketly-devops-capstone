# Managed PostgreSQL replacing the per-service SQLite files. The point is
# not convenience: with several replicas spread over workers, a file on one
# node's disk is invisible to every other replica, so the data has to live
# somewhere all of them reach identically.

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  description = "Private subnets only. The database is never routable from the internet."

  tags = {
    Name = "${var.name_prefix}-db-subnet-group"
  }
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name_prefix}-pg16"
  family = "postgres16"

  description = "Logs slow queries and every connection, so problems are diagnosable after the fact."

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # milliseconds
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Performance Insights encrypts its captured query data, which can contain
# statement text, so it needs a key named explicitly.
data "aws_kms_alias" "rds" {
  name = "alias/aws/rds"
}

# tfsec:ignore:AVD-AWS-0177 The project is torn down after every session to avoid charges, which deletion protection would block. A production deployment inverts this along with skip_final_snapshot.
resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-postgres"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username

  # No password argument anywhere. RDS generates one and stores it in
  # Secrets Manager, so it never passes through a variable, a tfvars file,
  # or Terraform state — state being a plaintext record of every attribute
  # Terraform knows, and therefore the usual way database passwords leak.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.this.name

  # Only the cluster's security group can reach 5432, and there is no public
  # address to reach in the first place.
  publicly_accessible = false
  multi_az            = var.multi_az

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  auto_minor_version_upgrade = true

  # Free at 7 days retention, and the only way to see which query is
  # responsible when the application slows down.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  performance_insights_kms_key_id       = data.aws_kms_alias.rds.target_key_arn

  # Allows connecting with a short-lived IAM token instead of the master
  # password. Password auth still works, so this adds an option rather than
  # changing how the services connect today.
  iam_database_authentication_enabled = true

  # This project is torn down repeatedly to avoid charges, so the usual
  # production guards are deliberately relaxed. A real deployment would
  # invert all three.
  skip_final_snapshot = true
  # tfsec:ignore:AVD-AWS-0177
  deletion_protection = false
  apply_immediately   = true

  tags = {
    Name = "${var.name_prefix}-postgres"
  }
}
