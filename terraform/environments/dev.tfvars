# Development: smallest footprint that still exercises every component.
# Account ids below are placeholders (one AWS account per environment).
environment         = "dev"
allowed_account_ids = ["111111111111"]
aws_region          = "us-east-1"

vpc_cidr                   = "10.10.0.0/16"
availability_zones         = ["us-east-1a", "us-east-1b"]
single_nat_gateway         = true
enable_interface_endpoints = false # NAT is cheaper than 6 endpoints x 2 AZs at dev traffic levels

# No custom domain in dev: the ALB DNS name is used over HTTP.
domain_name = null
enable_waf  = true

container_image  = "111111111111.dkr.ecr.us-east-1.amazonaws.com/xyzz-orders-api:bootstrap"
task_cpu         = 512
task_memory      = 1024
cpu_architecture = "ARM64"
web_concurrency  = 1
min_tasks        = 1
max_tasks        = 3
# All on Fargate Spot (~70% cheaper); interruptions are acceptable in dev.
fargate_base        = 0
fargate_weight      = 0
fargate_spot_weight = 1

db_instance_class           = "db.t4g.micro"
db_multi_az                 = false
db_allocated_storage_gb     = 20
db_max_allocated_storage_gb = 50
db_backup_retention_days    = 1
db_max_connections          = 100
enable_rds_proxy            = false

enable_execute_command = true
app_log_level          = "DEBUG"
log_retention_days     = 14
alb_log_retention_days = 14
