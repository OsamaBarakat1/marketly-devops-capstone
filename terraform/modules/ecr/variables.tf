variable "name_prefix" {
  type = string
}

variable "repository_names" {
  description = "One repository per deployable component."
  type        = list(string)
}

variable "max_image_count" {
  description = "Untagged and superseded images are expired beyond this count to keep storage inside the free tier."
  type        = number
  default     = 10
}
