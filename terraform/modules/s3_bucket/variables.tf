variable "bucket_name" {
  description = "Globally unique bucket name."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for SSE-KMS. null selects SSE-S3 (required for ALB access-log buckets)."
  type        = string
  default     = null
}

variable "versioning" {
  description = "Enable object versioning (protects against accidental overwrite/delete)."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete a non-empty bucket. Never true in production."
  type        = bool
  default     = false
}

variable "transition_to_ia_days" {
  description = "Days before objects move to STANDARD_IA. null disables the transition."
  type        = number
  default     = null
}

variable "transition_to_glacier_days" {
  description = "Days before objects move to Glacier Instant Retrieval. null disables the transition."
  type        = number
  default     = null
}

variable "expiration_days" {
  description = "Days before current objects expire. null keeps them indefinitely."
  type        = number
  default     = null
}

variable "noncurrent_version_expiration_days" {
  description = "Days before non-current object versions are deleted."
  type        = number
  default     = 30
}

variable "additional_policy_documents" {
  description = "Extra bucket-policy JSON documents merged with the TLS-only policy."
  type        = list(string)
  default     = []
}
