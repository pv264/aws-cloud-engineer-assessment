/**
 * Public Application Load Balancer.
 *
 * Migration support: when `legacy_lambda_function_arn` is set, the listener forwards to
 * TWO target groups with weights: the ECS service and the legacy Lambda function
 * (Lambda is a native ALB target type). Changing `ecs_traffic_weight` (0-100) shifts
 * traffic per request, instantly, with no DNS caching, which makes it the canary and
 * rollback lever for the serverless -> ECS cut-over (see MIGRATION.md).
 */

locals {
  https_enabled = var.enable_https
  shifting      = var.legacy_lambda_function_arn != null

  forward_targets = concat(
    [{ arn = aws_lb_target_group.app.arn, weight = local.shifting ? var.ecs_traffic_weight : 100 }],
    local.shifting ? [{ arn = aws_lb_target_group.legacy_lambda[0].arn, weight = 100 - var.ecs_traffic_weight }] : [],
  )
}

resource "aws_lb" "this" {
  #checkov:skip=CKV2_AWS_28:WAF is associated by the waf module (enable_waf)
  #checkov:skip=CKV2_AWS_20:HTTP redirects to HTTPS whenever enable_https is true; plain HTTP is dev-only
  name               = var.name
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [var.security_group_id]

  idle_timeout               = var.idle_timeout_seconds
  enable_http2               = true
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "defensive"
  enable_deletion_protection = var.deletion_protection

  dynamic "access_logs" {
    for_each = var.access_logs_bucket == null ? [] : [var.access_logs_bucket]
    content {
      enabled = true
      bucket  = access_logs.value
      prefix  = var.name
    }
  }
}

resource "aws_lb_target_group" "app" {
  #checkov:skip=CKV_AWS_378:TLS terminates at the ALB; ALB-to-task traffic stays in private subnets, restricted by security groups
  name        = "${var.name}-ecs"
  target_type = "ip" # required for Fargate (awsvpc networking)
  protocol    = "HTTP"
  port        = var.app_port
  vpc_id      = var.vpc_id

  # Route each request to the target with the fewest in-flight requests: better than
  # round robin when request latency varies (slow DB queries, cold tasks).
  load_balancing_algorithm_type = "least_outstanding_requests"
  # Must be shorter than the ECS stopTimeout so tasks finish in-flight requests
  # before they are stopped.
  deregistration_delay = var.deregistration_delay_seconds
  slow_start           = var.slow_start_seconds

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "legacy_lambda" {
  count = local.shifting ? 1 : 0

  name        = "${var.name}-lambda"
  target_type = "lambda"

  # Each ALB health check is a Lambda invocation; keep the interval long.
  health_check {
    enabled  = true
    path     = var.health_check_path
    matcher  = "200"
    interval = 60
    timeout  = 30
  }
}

resource "aws_lambda_permission" "alb" {
  count = local.shifting ? 1 : 0

  statement_id  = "AllowExecutionFromALB"
  action        = "lambda:InvokeFunction"
  function_name = var.legacy_lambda_function_arn
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.legacy_lambda[0].arn
}

resource "aws_lb_target_group_attachment" "legacy_lambda" {
  count = local.shifting ? 1 : 0

  target_group_arn = aws_lb_target_group.legacy_lambda[0].arn
  target_id        = var.legacy_lambda_function_arn

  depends_on = [aws_lambda_permission.alb]
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.certificate_arn
  ssl_policy        = var.ssl_policy

  # Security headers added by the ALB to every HTTPS response.
  routing_http_response_strict_transport_security_header_value = "max-age=31536000; includeSubDomains"
  routing_http_response_x_content_type_options_header_value    = "nosniff"

  default_action {
    type = "forward"
    forward {
      dynamic "target_group" {
        for_each = local.forward_targets
        content {
          arn    = target_group.value.arn
          weight = target_group.value.weight
        }
      }
      stickiness {
        enabled  = var.stickiness_duration_seconds > 0
        duration = max(var.stickiness_duration_seconds, 1)
      }
    }
  }
}

resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:Port 80 only issues a 301 to HTTPS when TLS is enabled
  #checkov:skip=CKV_AWS_103:Port 80 only issues a 301 to HTTPS when TLS is enabled
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # With TLS: permanent redirect to HTTPS. Without (dev only): serve the app on 80.
  default_action {
    type = local.https_enabled ? "redirect" : "forward"

    dynamic "redirect" {
      for_each = local.https_enabled ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "forward" {
      for_each = local.https_enabled ? [] : [1]
      content {
        dynamic "target_group" {
          for_each = local.forward_targets
          content {
            arn    = target_group.value.arn
            weight = target_group.value.weight
          }
        }
      }
    }
  }
}

# Dark launch: requests carrying the canary header (from allowed source ranges only) go
# straight to ECS whatever the weights are, so engineers and synthetic canaries can
# exercise ECS in production before any customer traffic is shifted.
resource "aws_lb_listener_rule" "canary" {
  count = var.canary_routing == null ? 0 : 1

  listener_arn = local.https_enabled ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
  priority     = 10

  condition {
    http_header {
      http_header_name = var.canary_routing.header_name
      values           = [var.canary_routing.header_value]
    }
  }

  condition {
    source_ip {
      values = var.canary_routing.source_cidrs
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
