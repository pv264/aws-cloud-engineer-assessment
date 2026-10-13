/**
 * Amazon RDS for PostgreSQL (+ optional RDS Proxy).
 *
 *  - Private: isolated data subnets, publicly_accessible = false, SG-restricted.
 *  - Encrypted at rest with the environment CMK; TLS enforced (rds.force_ssl = 1).
 *  - Master password generated and rotated by RDS in Secrets Manager
 *    (manage_master_user_password): it never appears in code, tfvars or state.
 *  - Multi-AZ synchronous standby with automatic failover (typically 60-120s).
 *  - RDS Proxy pools and multiplexes connections, so N ECS tasks x pool size + bursty
 *    Lambda concurrency cannot exhaust max_connections, and failovers are faster
 *    and transparent to clients.
 */

locals {
  identifier = var.name
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-"
  family      = "postgres${split(".", var.engine_version)[0]}"
  description = "${var.name} PostgreSQL parameters"

  # Reject any non-TLS connection.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Log slow statements (ms) and lock waits for troubleshooting.
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  parameter {
    name  = "log_lock_waits"
    value = "1"
  }

  # Kill sessions that leave a transaction open (they hold locks and connections).
  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "60000"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "track_io_timing"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Created up front so retention and encryption are ours, not RDS's never-expire default.
resource "aws_cloudwatch_log_group" "postgresql" {
  #checkov:skip=CKV_AWS_338:Retention is set per environment (90 days in prod); long-term archive goes to S3 where compliance requires it
  for_each = toset(["postgresql", "upgrade"])

  name              = "/aws/rds/instance/${local.identifier}/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  count = var.monitoring_interval_seconds > 0 ? 1 : 0

  name               = "${var.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.monitoring_interval_seconds > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier     = local.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name                       = var.database_name
  username                      = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb # storage auto scaling
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  port                   = 5432
  ca_cert_identifier     = "rds-ca-rsa2048-g1"
  parameter_group_name   = aws_db_parameter_group.this.name

  iam_database_authentication_enabled = true

  backup_retention_period  = var.backup_retention_days
  backup_window            = "03:00-04:00"
  maintenance_window       = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.identifier}-final"

  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  apply_immediately           = var.apply_immediately

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_arn
  performance_insights_retention_period = 7
  monitoring_interval                   = var.monitoring_interval_seconds
  monitoring_role_arn                   = try(aws_iam_role.monitoring[0].arn, null)
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  depends_on = [aws_cloudwatch_log_group.postgresql]
}

# --------------------------------- RDS Proxy ------------------------------------------

data "aws_iam_policy_document" "proxy_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "proxy" {
  count = var.enable_proxy ? 1 : 0

  name               = "${var.name}-rds-proxy"
  assume_role_policy = data.aws_iam_policy_document.proxy_assume.json
}

data "aws_iam_policy_document" "proxy" {
  count = var.enable_proxy ? 1 : 0

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn]
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

data "aws_region" "current" {}

resource "aws_iam_role_policy" "proxy" {
  count = var.enable_proxy ? 1 : 0

  name   = "read-db-secret"
  role   = aws_iam_role.proxy[0].id
  policy = data.aws_iam_policy_document.proxy[0].json
}

resource "aws_db_proxy" "this" {
  count = var.enable_proxy ? 1 : 0

  name                   = var.name
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.proxy[0].arn
  vpc_subnet_ids         = var.subnet_ids
  vpc_security_group_ids = [var.proxy_security_group_id]
  require_tls            = true
  idle_client_timeout    = 1800
  debug_logging          = false

  auth {
    auth_scheme               = "SECRETS"
    secret_arn                = aws_db_instance.this.master_user_secret[0].secret_arn
    iam_auth                  = "DISABLED"
    client_password_auth_type = "POSTGRES_SCRAM_SHA_256"
  }

  depends_on = [aws_iam_role_policy.proxy]
}

resource "aws_db_proxy_default_target_group" "this" {
  count = var.enable_proxy ? 1 : 0

  db_proxy_name = aws_db_proxy.this[0].name

  connection_pool_config {
    # Leave headroom on the database for migrations, DMS and humans.
    max_connections_percent      = 80
    max_idle_connections_percent = 20
    connection_borrow_timeout    = 10
  }
}

resource "aws_db_proxy_target" "this" {
  count = var.enable_proxy ? 1 : 0

  db_proxy_name          = aws_db_proxy.this[0].name
  target_group_name      = aws_db_proxy_default_target_group.this[0].name
  db_instance_identifier = aws_db_instance.this.identifier
}
