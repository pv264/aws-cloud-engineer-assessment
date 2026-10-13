provider "aws" {
  region = var.aws_region

  # Guard rail: refuse to run against the wrong account (e.g. prod tfvars with dev creds).
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = var.repository
      CostCenter  = var.cost_center
    }
  }
}
