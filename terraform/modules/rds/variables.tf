variable "name" {
  description = "DB instance identifier and name prefix."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL version. A major version only (e.g. \"17\") lets RDS pick and auto-upgrade the minor."
  type        = string
  default     = "17"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "database_name" {
  type    = string
  default = "orders"
}

variable "master_username" {
  type    = string
  default = "orders_admin"
}

variable "allocated_storage_gb" {
  type    = number
  default = 50
}

variable "max_allocated_storage_gb" {
  description = "Upper bound for storage auto scaling."
  type        = number
  default     = 500
}

variable "multi_az" {
  type    = bool
  default = true
}

variable "backup_retention_days" {
  type    = number
  default = 14
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "skip_final_snapshot" {
  type    = bool
  default = false
}

variable "apply_immediately" {
  description = "Apply modifications now instead of in the maintenance window. Keep false in production."
  type        = bool
  default     = false
}

variable "monitoring_interval_seconds" {
  description = "Enhanced Monitoring granularity (0 disables)."
  type        = number
  default     = 60
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "subnet_ids" {
  description = "Isolated data subnets."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "enable_proxy" {
  type    = bool
  default = true
}

variable "proxy_security_group_id" {
  type    = string
  default = null
}

variable "kms_key_arn" {
  type = string
}
