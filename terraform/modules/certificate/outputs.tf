output "certificate_arn" {
  description = "ARN of the validated certificate (only known once validation has completed)."
  value       = aws_acm_certificate_validation.this.certificate_arn
}
