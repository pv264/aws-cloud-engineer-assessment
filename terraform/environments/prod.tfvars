# Production.
environment         = "prod"
allowed_account_ids = ["333333333333"]
aws_region          = "us-east-1"

vpc_cidr                   = "10.30.0.0/16"
availability_zones         = ["us-east-1a", "us-east-1b", "us-east-1c"]
single_nat_gateway         = false # one NAT gateway per AZ: no cross-AZ egress dependency
enable_interface_endpoints = true

# REPLACE: real hostname and hosted zone.
domain_name                  = "api.xyzz.example.com"
hosted_zone_id               = "Z00000000PRODZONE"
enable_waf                   = true
waf_rate_limit_per_5_minutes = 2000

container_image  = "333333333333.dkr.ecr.us-east-1.amazonaws.com/xyzz-orders-api:bootstrap"
task_cpu         = 1024
task_memory      = 2048
cpu_architecture = "ARM64"
web_concurrency  = 2
# min_tasks >= AZ count: losing an AZ still leaves 2/3 of capacity while ECS replaces it.
min_tasks                      = 3
max_tasks                      = 30
cpu_target_percent             = 60
requests_per_target_per_minute = 6000
# The first 3 tasks are always on-demand; above that 3 on-demand : 1 Spot.
fargate_base        = 3
fargate_weight      = 3
fargate_spot_weight = 1

db_instance_class           = "db.r7g.large"
db_multi_az                 = true
db_allocated_storage_gb     = 100
db_max_allocated_storage_gb = 1000
db_backup_retention_days    = 14
db_max_connections          = 1700
enable_rds_proxy            = true
# Budget: 30 tasks x 2 workers x (5 + 5) = 600 client connections max, multiplexed
# by RDS Proxy onto at most 80% of max_connections.
db_pool_size    = 5
db_max_overflow = 5

require_idempotency_key = false # flipped to true once all clients send Idempotency-Key
enable_execute_command  = false # break-glass only, via a reviewed change
log_retention_days      = 90
alb_log_retention_days  = 365
alarm_emails            = ["platform-oncall@xyzz.example.com"]

# --- Serverless -> ECS migration (see MIGRATION.md) -----------------------------------
# During the canary, put the legacy Lambda behind the ALB and shift traffic per request:
#   legacy_lambda_function_arn      = "arn:aws:lambda:us-east-1:333333333333:function:orders-api-legacy:live"
#   ecs_traffic_weight              = 25   # 0 -> 5 -> 25 -> 50 -> 100
#   canary_routing = { header_name = "X-Orders-Canary", header_value = "ecs", source_cidrs = ["203.0.113.0/24"] }
#   monitored_lambda_function_names = ["orders-api-legacy"]
