# ------------------------------------ General -----------------------------------------

variable "project" {
  description = "Short project name used in resource names."
  type        = string
  default     = "xyzz-orders"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.project))
    error_message = "project must be 3-16 lowercase alphanumeric characters or hyphens."
  }
}

variable "environment" {
  description = "Deployment environment."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "allowed_account_ids" {
  description = "AWS account(s) this environment may be applied to. Protects against applying with the wrong credentials."
  type        = list(string)
}

variable "repository" {
  description = "Source repository, recorded as a tag on every resource."
  type        = string
  default     = "github.com/xyzz/aws-cloud-engineer-assessment"
}

variable "cost_center" {
  type    = string
  default = "orders-platform"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for application, WAF, VPC flow and RDS logs."
  type        = number
  default     = 30
}

variable "alb_log_retention_days" {
  description = "Days to keep ALB access logs in S3."
  type        = number
  default     = 90
}

variable "alarm_emails" {
  type    = list(string)
  default = []
}

# ------------------------------------ Network -----------------------------------------

variable "vpc_cidr" {
  type = string
}

variable "availability_zones" {
  description = "AZs to deploy into, pinned explicitly (e.g. [\"us-east-1a\", \"us-east-1b\", \"us-east-1c\"])."
  type        = list(string)
}

variable "single_nat_gateway" {
  type    = bool
  default = false
}

variable "enable_interface_endpoints" {
  type    = bool
  default = true
}

variable "alb_ingress_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

# -------------------------------------- Edge ------------------------------------------

variable "domain_name" {
  description = "API hostname (e.g. api.xyzz.com). null = use the ALB DNS name over HTTP (dev only)."
  type        = string
  default     = null
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone for domain_name."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "Existing ACM certificate to use instead of issuing one for domain_name."
  type        = string
  default     = null
}

variable "enable_waf" {
  type    = bool
  default = true
}

variable "waf_rate_limit_per_5_minutes" {
  type    = number
  default = 2000
}

# ---------------------------------- Application ---------------------------------------

variable "container_image" {
  description = "Initial container image: <account>.dkr.ecr.<region>.amazonaws.com/orders-api:<git-sha>. Supplied by CI."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "task_cpu" {
  type    = number
  default = 1024
}

variable "task_memory" {
  type    = number
  default = 2048
}

variable "cpu_architecture" {
  type    = string
  default = "ARM64"
}

variable "web_concurrency" {
  description = "Uvicorn worker processes per task (about one per vCPU)."
  type        = number
  default     = 2
}

variable "min_tasks" {
  type = number
}

variable "max_tasks" {
  type = number
}

variable "cpu_target_percent" {
  type    = number
  default = 60
}

variable "requests_per_target_per_minute" {
  description = "Target ALB requests per task per minute (6,000 = 100 RPS, ~65% of a 1 vCPU task's measured capacity)."
  type        = number
  default     = 6000
}

variable "fargate_base" {
  type    = number
  default = 2
}

variable "fargate_weight" {
  type    = number
  default = 1
}

variable "fargate_spot_weight" {
  type    = number
  default = 0
}

variable "enable_execute_command" {
  type    = bool
  default = false
}

variable "app_log_level" {
  type    = string
  default = "INFO"
}

variable "require_idempotency_key" {
  type    = bool
  default = false
}

variable "db_pool_size" {
  description = "SQLAlchemy pool size per worker process. Connection budget: max_tasks x web_concurrency x (pool + overflow)."
  type        = number
  default     = 5
}

variable "db_max_overflow" {
  type    = number
  default = 5
}

# ----------------------------------- Database -----------------------------------------

variable "db_engine_version" {
  type    = string
  default = "17"
}

variable "db_instance_class" {
  type = string
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 50
}

variable "db_max_allocated_storage_gb" {
  type    = number
  default = 500
}

variable "db_multi_az" {
  type = bool
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "db_max_connections" {
  description = "max_connections of the chosen instance class; drives the connections alarm."
  type        = number
}

variable "enable_rds_proxy" {
  type    = bool
  default = true
}

# ----------------------------------- Migration ----------------------------------------

variable "legacy_lambda_function_arn" {
  description = "Migration only: legacy Lambda (alias ARN) placed behind the ALB for weighted traffic shifting. null once decommissioned."
  type        = string
  default     = null
}

variable "ecs_traffic_weight" {
  description = "Migration only: % of requests routed to ECS (rest to the legacy Lambda). Steps: 0 > 5 > 25 > 50 > 100."
  type        = number
  default     = 100

  validation {
    condition     = var.ecs_traffic_weight >= 0 && var.ecs_traffic_weight <= 100 && floor(var.ecs_traffic_weight) == var.ecs_traffic_weight
    error_message = "ecs_traffic_weight must be a whole number between 0 and 100."
  }
}

variable "canary_routing" {
  description = "Migration only: header + source CIDRs that force routing to ECS (dark launch). null disables."
  type = object({
    header_name  = string
    header_value = string
    source_cidrs = list(string)
  })
  default = null
}

variable "monitored_lambda_function_names" {
  description = "Lambda functions that get error/throttle alarms."
  type        = list(string)
  default     = []
}
