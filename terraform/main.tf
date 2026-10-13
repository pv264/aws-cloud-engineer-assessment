/**
 * Orders platform: one environment (dev | staging | prod) per state file.
 *
 *   Route 53 -> WAF -> ALB (public subnets)
 *            -> ECS Fargate service (private app subnets, 3 AZs, auto scaling)
 *            -> RDS Proxy -> RDS PostgreSQL Multi-AZ (isolated data subnets)
 *
 * Environment differences live only in environments/<env>.tfvars.
 */

data "aws_caller_identity" "current" {}

locals {
  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  # S3 bucket names are global: suffix with the account id to avoid collisions.
  bucket_prefix = "${local.name}-${local.account_id}"

  https_enabled   = var.certificate_arn != null || var.domain_name != null
  certificate_arn = var.certificate_arn != null ? var.certificate_arn : try(module.certificate[0].certificate_arn, null)
}

module "kms" {
  source = "./modules/kms"

  name                    = local.name
  deletion_window_in_days = var.environment == "prod" ? 30 : 7
}

module "network" {
  source = "./modules/network"

  name                       = local.name
  cidr_block                 = var.vpc_cidr
  availability_zones         = var.availability_zones
  single_nat_gateway         = var.single_nat_gateway
  enable_interface_endpoints = var.enable_interface_endpoints
  flow_log_retention_days    = var.log_retention_days
  kms_key_arn                = module.kms.key_arn
}

module "security_groups" {
  source = "./modules/security_groups"

  name              = local.name
  vpc_id            = module.network.vpc_id
  app_port          = var.container_port
  alb_ingress_cidrs = var.alb_ingress_cidrs
}

# ---------------------------------- S3 buckets ----------------------------------------

data "aws_elb_service_account" "this" {}

data "aws_iam_policy_document" "alb_logs_delivery" {
  statement {
    sid       = "AllowAlbAccessLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.bucket_prefix}-alb-logs/${local.name}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }

  statement {
    sid       = "AllowAlbAccessLogDeliveryServicePrincipal"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.bucket_prefix}-alb-logs/${local.name}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
  }
}

# ALB access logs only support SSE-S3, hence no KMS key here.
module "alb_logs_bucket" {
  source = "./modules/s3_bucket"

  bucket_name                 = "${local.bucket_prefix}-alb-logs"
  versioning                  = false
  force_destroy               = var.environment != "prod"
  transition_to_ia_days       = 30
  expiration_days             = var.alb_log_retention_days
  additional_policy_documents = [data.aws_iam_policy_document.alb_logs_delivery.json]
}

# Application documents (invoices, exports) written by the API under orders/.
module "assets_bucket" {
  source = "./modules/s3_bucket"

  bucket_name                        = "${local.bucket_prefix}-assets"
  kms_key_arn                        = module.kms.key_arn
  versioning                         = true
  force_destroy                      = var.environment != "prod"
  transition_to_ia_days              = 30
  transition_to_glacier_days         = 90
  noncurrent_version_expiration_days = 30
}

# ------------------------------------- Edge -------------------------------------------

module "certificate" {
  source = "./modules/certificate"
  count  = var.certificate_arn == null && var.domain_name != null ? 1 : 0

  domain_name    = var.domain_name
  hosted_zone_id = var.hosted_zone_id
}

module "alb" {
  source = "./modules/alb"

  name                        = local.name
  vpc_id                      = module.network.vpc_id
  public_subnet_ids           = module.network.public_subnet_ids
  security_group_id           = module.security_groups.alb_security_group_id
  app_port                    = var.container_port
  enable_https                = local.https_enabled
  certificate_arn             = local.certificate_arn
  deletion_protection         = var.environment == "prod"
  access_logs_bucket          = module.alb_logs_bucket.bucket_id
  legacy_lambda_function_arn  = var.legacy_lambda_function_arn
  ecs_traffic_weight          = var.ecs_traffic_weight
  stickiness_duration_seconds = var.legacy_lambda_function_arn != null ? 3600 : 0
  canary_routing              = var.canary_routing
}

module "waf" {
  source = "./modules/waf"
  count  = var.enable_waf ? 1 : 0

  name                     = local.name
  alb_arn                  = module.alb.alb_arn
  rate_limit_per_5_minutes = var.waf_rate_limit_per_5_minutes
  log_retention_days       = var.log_retention_days
  kms_key_arn              = module.kms.key_arn
}

resource "aws_route53_record" "api" {
  for_each = var.domain_name != null && var.hosted_zone_id != null ? toset(["A", "AAAA"]) : toset([])

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = each.value

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

# ----------------------------------- Database -----------------------------------------

module "rds" {
  source = "./modules/rds"

  name                     = local.name
  engine_version           = var.db_engine_version
  instance_class           = var.db_instance_class
  allocated_storage_gb     = var.db_allocated_storage_gb
  max_allocated_storage_gb = var.db_max_allocated_storage_gb
  multi_az                 = var.db_multi_az
  backup_retention_days    = var.db_backup_retention_days
  deletion_protection      = var.environment == "prod"
  skip_final_snapshot      = var.environment == "dev"
  log_retention_days       = var.log_retention_days
  subnet_ids               = module.network.private_data_subnet_ids
  security_group_id        = module.security_groups.db_security_group_id
  enable_proxy             = var.enable_rds_proxy
  proxy_security_group_id  = module.security_groups.db_proxy_security_group_id
  kms_key_arn              = module.kms.key_arn
}

# ---------------------------------- Application ---------------------------------------

module "ecs" {
  source = "./modules/ecs_service"

  name             = local.name
  container_image  = var.container_image
  container_port   = var.container_port
  cpu              = var.task_cpu
  memory           = var.task_memory
  cpu_architecture = var.cpu_architecture

  environment = {
    APP_ENV                 = var.environment
    LOG_LEVEL               = var.app_log_level
    WEB_CONCURRENCY         = tostring(var.web_concurrency)
    DB_HOST                 = module.rds.endpoint
    DB_PORT                 = tostring(module.rds.port)
    DB_NAME                 = module.rds.database_name
    DB_SSLMODE              = "require"
    DB_POOL_SIZE            = tostring(var.db_pool_size)
    DB_MAX_OVERFLOW         = tostring(var.db_max_overflow)
    REQUIRE_IDEMPOTENCY_KEY = tostring(var.require_idempotency_key)
    # Behind RDS Proxy a per-connection startup option pins sessions; the timeout is
    # set on the database role instead (ALTER ROLE ... SET statement_timeout).
    DB_STATEMENT_TIMEOUT_MS = var.enable_rds_proxy ? "0" : "5000"
  }
  secrets = {
    DB_USER     = "${module.rds.master_user_secret_arn}:username::"
    DB_PASSWORD = "${module.rds.master_user_secret_arn}:password::"
  }

  subnet_ids                   = module.network.private_app_subnet_ids
  security_group_ids           = [module.security_groups.app_security_group_id]
  target_group_arn             = module.alb.target_group_arn
  request_count_resource_label = module.alb.request_count_resource_label

  min_capacity        = var.min_tasks
  max_capacity        = var.max_tasks
  cpu_target_percent  = var.cpu_target_percent
  requests_per_target = var.requests_per_target_per_minute
  fargate_base        = var.fargate_base
  fargate_weight      = var.fargate_weight
  fargate_spot_weight = var.fargate_spot_weight

  deployment_alarm_names = module.monitoring.deployment_alarm_names
  enable_execute_command = var.enable_execute_command
  log_retention_days     = var.log_retention_days
  kms_key_arn            = module.kms.key_arn
  assets_bucket          = { arn = module.assets_bucket.bucket_arn }
}

# ---------------------------------- Monitoring ----------------------------------------

module "monitoring" {
  source = "./modules/monitoring"

  name                    = local.name
  aws_region              = var.aws_region
  alarm_emails            = var.alarm_emails
  kms_key_arn             = module.kms.key_arn
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  # Plain names (not module.ecs outputs) so module.ecs can consume the alarm names.
  ecs_cluster_name       = local.name
  ecs_service_name       = local.name
  ecs_min_tasks          = var.min_tasks
  app_log_group_name     = module.ecs.log_group_name
  db_instance_identifier = module.rds.instance_identifier
  db_max_connections     = var.db_max_connections
  lambda_function_names  = var.monitored_lambda_function_names
}
