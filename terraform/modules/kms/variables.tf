variable "name" {
  description = "Name prefix; the key alias becomes alias/<name>."
  type        = string
}

variable "deletion_window_in_days" {
  description = "Waiting period before a scheduled key deletion completes."
  type        = number
  default     = 30
}
