variable "name" {
  description = "Name prefix for all network resources."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. A /16 is expected by the subnet plan."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0)) && endswith(var.cidr_block, "/16")
    error_message = "cidr_block must be a valid /16 (e.g. 10.20.0.0/16)."
  }
}

variable "availability_zones" {
  description = "Availability Zones to span, in a fixed order (2 minimum for HA, 3 for production)."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2 && length(var.availability_zones) <= 3 && length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones must list 2 or 3 distinct AZs."
  }
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway (cheaper, AZ-level SPOF) instead of one per AZ."
  type        = bool
  default     = false
}

variable "enable_interface_endpoints" {
  description = "Create interface VPC endpoints for ECR, CloudWatch Logs, Secrets Manager, etc."
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = "AWS services that get an interface endpoint when enable_interface_endpoints is true."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "logs", "secretsmanager", "sts", "kms"]
}

variable "enable_flow_logs" {
  description = "Ship VPC flow logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention for VPC flow logs."
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "KMS key used to encrypt the flow-log log group."
  type        = string
  default     = null
}
