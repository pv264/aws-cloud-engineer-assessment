/**
 * ECS on Fargate: cluster, task definition, service and auto scaling for the Orders API.
 *
 * Deployment model: Terraform owns the infrastructure and the task-definition
 * "template". CI/CD deploys new images by registering a new revision of the same family
 * (latest revision + new image) and updating the service. The service therefore
 * ignores `task_definition` drift, and `desired_count` belongs to auto scaling.
 */

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  region         = data.aws_region.current.region
  partition      = data.aws_partition.current.partition
  container_name = "app"

  secret_arns = distinct([for value_from in values(var.secrets) : regex("^(arn:[^:]+:secretsmanager:[^:]+:[^:]+:secret:[^:]+)", value_from)[0]])

  health_check_command = "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${var.container_port}${var.health_check_path}', timeout=3)"
}

# ------------------------------------ Cluster ------------------------------------------

resource "aws_cloudwatch_log_group" "exec" {
  count = var.enable_execute_command ? 1 : 0

  name              = "/ecs/${var.name}/exec-audit"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  dynamic "configuration" {
    for_each = var.enable_execute_command ? [1] : []
    content {
      execute_command_configuration {
        kms_key_id = var.kms_key_arn
        logging    = "OVERRIDE"
        log_configuration {
          cloud_watch_log_group_name     = aws_cloudwatch_log_group.exec[0].name
          cloud_watch_encryption_enabled = true
        }
      }
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }
}

# ---------------------------------- Logging -------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}/app"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

# ------------------------------------- IAM --------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    # Confused-deputy protection: only ECS acting for this account may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:ecs:${local.region}:${local.account_id}:*"]
    }
  }
}

# Execution role: used by the ECS agent (not the app) to pull the image, write logs and
# resolve the `secrets` of the task definition.
resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0

  statement {
    sid       = "ReadOnlyTheSecretsThisTaskNeeds"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.secret_arns
  }

  statement {
    sid       = "DecryptThoseSecrets"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0

  name   = "read-task-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# Task role: the identity of the application code itself. Least privilege: only what
# the Orders API actually calls.
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "task" {
  dynamic "statement" {
    for_each = var.assets_bucket == null ? [] : [var.assets_bucket.arn]
    content {
      sid       = "OrderDocuments"
      actions   = ["s3:GetObject", "s3:PutObject"]
      resources = ["${statement.value}/orders/*"]
    }
  }

  dynamic "statement" {
    for_each = var.assets_bucket == null ? [] : [1]
    content {
      sid       = "OrderDocumentsEncryption"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_execute_command ? [1] : []
    content {
      sid = "EcsExec"
      actions = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_execute_command ? [1] : []
    content {
      sid       = "EcsExecAuditLogs"
      actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:DescribeLogGroups"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_execute_command ? [1] : []
    content {
      sid       = "EcsExecSessionEncryption"
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  count = var.assets_bucket != null || var.enable_execute_command ? 1 : 0

  name   = "orders-api"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ------------------------------- Task definition --------------------------------------

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  # Writable scratch space; the root filesystem itself is read-only.
  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.container_image
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
        name          = "http"
      }]

      environment = [for key in sort(keys(var.environment)) : { name = key, value = var.environment[key] }]
      # Resolved by the ECS agent from Secrets Manager at task start; never stored in
      # the task definition, the image or Terraform state.
      secrets = [for key in sort(keys(var.secrets)) : { name = key, valueFrom = var.secrets[key] }]

      user                   = "10001:10001"
      readonlyRootFilesystem = true
      mountPoints = [{
        sourceVolume  = "tmp"
        containerPath = "/tmp"
        readOnly      = false
      }]
      linuxParameters = {
        initProcessEnabled = true # tini as PID 1: signal forwarding + zombie reaping
        capabilities       = { drop = ["ALL"] }
      }
      ulimits = [{ name = "nofile", softLimit = 65536, hardLimit = 65536 }]

      # Time between SIGTERM and SIGKILL. Must exceed the app's graceful shutdown (25s).
      stopTimeout = 30

      healthCheck = {
        command     = ["CMD", "python", "-c", local.health_check_command]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = local.region
          awslogs-stream-prefix = "app"
          # Never block the application if CloudWatch Logs throttles.
          mode            = "non-blocking"
          max-buffer-size = "25m"
        }
      }
    }
  ])
}

# ----------------------------------- Service ------------------------------------------

resource "aws_ecs_service" "this" {
  name                    = var.name
  cluster                 = aws_ecs_cluster.this.id
  task_definition         = aws_ecs_task_definition.this.arn
  desired_count           = var.min_capacity
  platform_version        = "LATEST"
  enable_execute_command  = var.enable_execute_command
  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true

  # Spread tasks evenly across AZs again after an AZ recovers.
  availability_zone_rebalancing = "ENABLED"

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = var.fargate_base
    weight            = var.fargate_weight
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 0
    weight            = var.fargate_spot_weight
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # Grace period for the ALB health check while a new task boots.
  health_check_grace_period_seconds = 60

  # Rolling deployment that never drops below current capacity.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Automatic rollback if new tasks keep failing to start / pass health checks...
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # ...or if the 5xx / latency alarms fire while the deployment is in progress.
  dynamic "alarms" {
    for_each = length(var.deployment_alarm_names) > 0 ? [1] : []
    content {
      alarm_names = var.deployment_alarm_names
      enable      = true
      rollback    = true
    }
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_iam_role_policy_attachment.execution_managed]
}

# -------------------------------- Auto scaling ----------------------------------------

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
}

# Scale on whichever signal trips first; target tracking scales out fast and in slowly.
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "requests" {
  count = var.requests_per_target == null ? 0 : 1

  name               = "${var.name}-requests-per-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.requests_per_target
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = var.request_count_resource_label
    }
  }
}
