output "instance_identifier" {
  value = aws_db_instance.this.identifier
}

output "instance_address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "database_name" {
  value = aws_db_instance.this.db_name
}

output "proxy_endpoint" {
  value = try(aws_db_proxy.this[0].endpoint, null)
}

output "endpoint" {
  description = "What clients should connect to: the proxy when enabled, otherwise the instance."
  value       = try(aws_db_proxy.this[0].endpoint, aws_db_instance.this.address)
}

output "master_user_secret_arn" {
  description = "ARN (not the value) of the RDS-managed Secrets Manager secret."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
