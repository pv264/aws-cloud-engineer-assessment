variable "name" {
  type = string
}

variable "alb_arn" {
  description = "ALB to protect."
  type        = string
}

variable "rate_limit_per_5_minutes" {
  description = "Maximum requests per client IP in any 5-minute window before blocking."
  type        = number
  default     = 2000
}

variable "managed_rule_groups" {
  description = "AWS managed rule groups. Set count_only = true to evaluate a group without blocking."
  type = list(object({
    name       = string
    priority   = number
    count_only = bool
  }))
  default = [
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 10, count_only = false },
    { name = "AWSManagedRulesCommonRuleSet", priority = 20, count_only = false },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 30, count_only = false },
    { name = "AWSManagedRulesSQLiRuleSet", priority = 40, count_only = false },
  ]
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "kms_key_arn" {
  type    = string
  default = null
}
