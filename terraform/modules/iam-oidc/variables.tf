variable "name_prefix" {
  type = string
}

variable "github_repo" {
  description = "owner/repo permitted to assume the role."
  type        = string
}

variable "deploy_branch" {
  description = "Branch whose workflow runs may assume the role."
  type        = string
}

variable "ecr_repository_arns" {
  description = "Push permission is scoped to these repositories rather than the whole registry."
  type        = list(string)
}

variable "state_bucket_name" {
  description = "Remote state bucket, so state access is scoped to it rather than every bucket in the account."
  type        = string
}

variable "state_lock_table_name" {
  description = "DynamoDB lock table for remote state."
  type        = string
}

variable "create_oidc_provider" {
  description = "An account can hold only one provider per URL. Set false if GitHub's provider already exists in this account."
  type        = bool
  default     = true
}
