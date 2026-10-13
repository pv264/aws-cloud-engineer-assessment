variable "name" {
  description = "Name of the load balancer (max 32 characters; target groups append -ecs / -lambda)."
  type        = string

  validation {
    condition     = length(var.name) <= 25
    error_message = "name must be at most 25 characters so target group names stay within 32."
  }
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Public subnets, one per AZ."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "app_port" {
  type = number
}

variable "health_check_path" {
  description = "Shallow liveness endpoint (must not depend on the database)."
  type        = string
  default     = "/health"
}

variable "enable_https" {
  description = "Create the HTTPS listener and redirect HTTP to it. A separate flag (not certificate_arn != null) because the certificate ARN is unknown at plan time when it is issued in the same run."
  type        = bool
  default     = true
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener (required when enable_https = true)."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_https || var.certificate_arn != null
    error_message = "certificate_arn is required when enable_https is true."
  }
}

variable "ssl_policy" {
  description = "TLS policy: TLS 1.3 with TLS 1.2 fallback, forward-secret ciphers only."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "idle_timeout_seconds" {
  description = "Must be lower than the application's keep-alive timeout (75s) to avoid 502s."
  type        = number
  default     = 60
}

variable "deregistration_delay_seconds" {
  type    = number
  default = 30
}

variable "slow_start_seconds" {
  description = "Ramp-up period for new targets (0 disables)."
  type        = number
  default     = 30
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "access_logs_bucket" {
  description = "S3 bucket for ALB access logs (null disables access logging)."
  type        = string
  default     = null
}

variable "legacy_lambda_function_arn" {
  description = "Migration only: ARN (ideally a published alias) of the legacy Lambda API to weight traffic against."
  type        = string
  default     = null
}

variable "ecs_traffic_weight" {
  description = "Migration only: percentage of requests sent to ECS; the remainder goes to the legacy Lambda."
  type        = number
  default     = 100

  validation {
    condition     = var.ecs_traffic_weight >= 0 && var.ecs_traffic_weight <= 100
    error_message = "ecs_traffic_weight must be between 0 and 100."
  }
}

variable "stickiness_duration_seconds" {
  description = "Target-group stickiness while splitting traffic (0 = off). Keeps a client on one stack during the canary."
  type        = number
  default     = 0
}

variable "canary_routing" {
  description = "Migration dark launch: route requests with this header from these CIDRs straight to ECS (null disables)."
  type = object({
    header_name  = string
    header_value = string
    source_cidrs = list(string)
  })
  default = null
}
