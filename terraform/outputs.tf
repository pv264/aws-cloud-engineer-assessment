output "api_url" {
  description = "Base URL of the API."
  value       = var.domain_name != null ? "https://${var.domain_name}" : "${local.https_enabled ? "https" : "http"}://${module.alb.alb_dns_name}"
}

output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "private_app_subnet_ids" {
  description = "Used by CI to launch the one-off migration task."
  value       = module.network.private_app_subnet_ids
}

output "app_security_group_id" {
  description = "Used by CI to launch the one-off migration task."
  value       = module.security_groups.app_security_group_id
}

output "lambda_security_group_id" {
  description = "Attach VPC-enabled Lambdas (legacy API, async workers) to this group."
  value       = module.security_groups.lambda_security_group_id
}

output "nat_gateway_public_ips" {
  value = module.network.nat_gateway_public_ips
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_name" {
  value = module.ecs.service_name
}

output "task_definition_family" {
  value = module.ecs.task_definition_family
}

output "container_name" {
  value = module.ecs.container_name
}

output "app_log_group_name" {
  value = module.ecs.log_group_name
}

output "db_endpoint" {
  description = "Endpoint the application connects to (RDS Proxy when enabled)."
  value       = module.rds.endpoint
}

output "db_instance_address" {
  value = module.rds.instance_address
}

output "db_master_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the DB credentials (the value is never output)."
  value       = module.rds.master_user_secret_arn
}

output "assets_bucket" {
  value = module.assets_bucket.bucket_id
}

output "alerts_topic_arn" {
  value = module.monitoring.alerts_topic_arn
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${module.monitoring.dashboard_name}"
}
