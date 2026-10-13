terraform {
  # >= 1.11: S3 backend native state locking (use_lockfile), no DynamoDB table needed.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration: bucket/key/region come from environments/<env>.s3.tfbackend
  #   terraform init -backend-config=environments/prod.s3.tfbackend
  # so each environment has its own isolated state file.
  backend "s3" {}
}
