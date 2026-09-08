# Remote state lives in S3, not on one person's laptop, and the DynamoDB
# table serializes concurrent applies so two runs cannot corrupt state.
#
# This matters for more than convenience: state records every attribute of
# every resource, so a local terraform.tfstate is an unencrypted file full of
# infrastructure detail sitting in a working directory. S3 keeps it
# encrypted and versioned.
#
# Chicken and egg: the bucket and table must exist before this block can be
# used, so they are created by terraform/bootstrap/ first. Leave this
# commented out for the initial run, then:
#
#   1. cd bootstrap && terraform init && terraform apply
#   2. copy the bucket name from its output into the block below
#   3. uncomment, then run `terraform init -migrate-state` in this directory
#
# terraform {
#   backend "s3" {
#     bucket         = "marketly-tfstate-REPLACE_WITH_BOOTSTRAP_OUTPUT"
#     key            = "marketly/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "marketly-tf-locks"
#     encrypt        = true
#   }
# }
