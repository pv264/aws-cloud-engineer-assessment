variable "name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "alarm_emails" {
  description = "Email addresses subscribed to the alerts topic (production would route to PagerDuty/Opsgenie)."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  type = string
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "ecs_min_tasks" {
  type = number
}

variable "app_log_group_name" {
  type = string
}

variable "db_instance_identifier" {
  type = string
}

variable "db_max_connections" {
  description = "max_connections of the instance class (RDS default: LEAST(DBInstanceClassMemory/9531392, 5000))."
  type        = number
}

variable "db_free_storage_threshold_gb" {
  type    = number
  default = 10
}

variable "error_rate_threshold_percent" {
  type    = number
  default = 2
}

variable "min_requests_for_error_rate" {
  description = "Ignore the error rate when traffic in a minute is below this (avoids paging on 1 of 3 requests)."
  type        = number
  default     = 50
}

variable "p99_latency_threshold_seconds" {
  type    = number
  default = 1
}

variable "app_error_log_threshold" {
  type    = number
  default = 20
}

variable "lambda_function_names" {
  description = "Lambda functions to alarm on (legacy API during the migration, async workers)."
  type        = list(string)
  default     = []
}
