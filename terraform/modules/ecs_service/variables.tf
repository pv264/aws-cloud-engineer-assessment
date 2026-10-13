variable "name" {
  description = "Name of the cluster, service and task-definition family."
  type        = string
}

variable "container_image" {
  description = "Initial image (ECR URI with an immutable tag or digest). Later deployments are done by CI/CD."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "cpu" {
  description = "Task vCPU units (1024 = 1 vCPU)."
  type        = number
  default     = 1024
}

variable "memory" {
  description = "Task memory (MiB)."
  type        = number
  default     = 2048
}

variable "cpu_architecture" {
  description = "ARM64 (Graviton, ~20% cheaper per vCPU-hour) or X86_64."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
}

variable "environment" {
  description = "Non-secret environment variables for the container."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Environment variable name => Secrets Manager valueFrom (secret ARN, optionally ':json-key::')."
  type        = map(string)
  default     = {}
}

variable "subnet_ids" {
  description = "Private application subnets."
  type        = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "target_group_arn" {
  type = string
}

variable "request_count_resource_label" {
  description = "<alb arn suffix>/<target group arn suffix> for ALBRequestCountPerTarget."
  type        = string
  default     = null
}

variable "min_capacity" {
  description = "Minimum (and initial) number of tasks. Use >= number of AZs in production."
  type        = number
  default     = 2
}

variable "max_capacity" {
  type    = number
  default = 10
}

variable "cpu_target_percent" {
  type    = number
  default = 60
}

variable "requests_per_target" {
  description = "Target ALB requests per task per minute (null disables request-based scaling)."
  type        = number
  default     = 1000
}

variable "fargate_base" {
  description = "Tasks always placed on on-demand Fargate."
  type        = number
  default     = 2
}

variable "fargate_weight" {
  type    = number
  default = 1
}

variable "fargate_spot_weight" {
  description = "Relative weight of Fargate Spot for tasks above the base (0 disables Spot)."
  type        = number
  default     = 0
}

variable "deployment_alarm_names" {
  description = "CloudWatch alarms that roll back an in-progress deployment when they fire."
  type        = list(string)
  default     = []
}

variable "enable_execute_command" {
  description = "Allow ECS Exec (audited, KMS-encrypted sessions) for break-glass debugging."
  type        = bool
  default     = false
}

variable "container_insights" {
  description = "Container Insights mode: enhanced, enabled or disabled."
  type        = string
  default     = "enhanced"
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "kms_key_arn" {
  type = string
}

variable "assets_bucket" {
  description = "Bucket the application may read/write under orders/ (null = no S3 access). An object rather than a bare ARN so that whether to grant access is known at plan time, before the bucket exists."
  type        = object({ arn = string })
  default     = null
}
