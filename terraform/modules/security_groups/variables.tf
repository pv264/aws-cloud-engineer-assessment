variable "name" {
  description = "Name prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC to create the security groups in."
  type        = string
}

variable "app_port" {
  description = "Container port the application listens on."
  type        = number
}

variable "db_port" {
  description = "Database port."
  type        = number
  default     = 5432
}

variable "alb_ingress_cidrs" {
  description = "IPv4 CIDRs allowed to reach the ALB. Narrow this (e.g. to the CloudFront origin-facing prefix list or a corporate range) for internal environments."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
