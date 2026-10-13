variable "domain_name" {
  description = "Primary hostname, e.g. api.example.com."
  type        = string
}

variable "subject_alternative_names" {
  description = "Additional hostnames on the certificate."
  type        = list(string)
  default     = []
}

variable "hosted_zone_id" {
  description = "Route 53 public hosted zone that serves domain_name."
  type        = string
}
