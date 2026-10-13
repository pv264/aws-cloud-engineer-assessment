variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "xyzz-orders"
}

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository."
  type        = string
}

variable "github_repository" {
  description = "Repository name (without the owner)."
  type        = string
  default     = "aws-cloud-engineer-assessment"
}

variable "environments" {
  description = "Environments deployed into this account (one per account is recommended)."
  type        = list(string)
  default     = ["dev", "staging", "prod"]
}
