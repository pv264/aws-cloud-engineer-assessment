# Staging: same topology as production (3 AZs, Multi-AZ RDS, RDS Proxy, HTTPS, WAF)
# at a smaller size, so failover tests and load tests are representative.
environment         = "staging"
allowed_account_ids = ["222222222222"]
aws_region          = "us-east-1"

vpc_cidr                   = "10.20.0.0/16"
availability_zones         = ["us-east-1a", "us-east-1b", "us-east-1c"]
single_nat_gateway         = true
enable_interface_endpoints = false

# REPLACE: real hostname and hosted zone.
domain_name    = "api.staging.xyzz.example.com"
hosted_zone_id = "Z00000000STAGINGZONE"
enable_waf     = true

container_image     = "222222222222.dkr.ecr.us-east-1.amazonaws.com/xyzz-orders-api:bootstrap"
task_cpu            = 1024
task_memory         = 2048
cpu_architecture    = "ARM64"
web_concurrency     = 2
min_tasks           = 2
max_tasks           = 6
fargate_base        = 1
fargate_weight      = 1
fargate_spot_weight = 1

db_instance_class        = "db.t4g.medium"
db_multi_az              = true
db_backup_retention_days = 7
db_max_connections       = 400
enable_rds_proxy         = true

require_idempotency_key = true
log_retention_days      = 30
alb_log_retention_days  = 30
