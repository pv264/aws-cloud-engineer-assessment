/**
 * Security groups reference each other instead of CIDR ranges, so the allowed paths
 * are exactly:
 *
 *   internet --443/80--> alb --app port--> app --5432--> rds-proxy --5432--> rds
 *                                          lambda --5432--> rds-proxy / rds
 *
 * Nothing else can reach the database: it lives in subnets with no internet route,
 * is not publicly accessible, and only accepts connections from these groups.
 */

resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5:Attached by the alb, ecs_service, rds and Lambda resources in other modules
  name        = "${var.name}-alb"
  description = "Public Application Load Balancer"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5:Attached by the alb, ecs_service, rds and Lambda resources in other modules
  name        = "${var.name}-app"
  description = "ECS Fargate tasks running the Orders API"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-app" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "lambda" {
  #checkov:skip=CKV2_AWS_5:Attached by the alb, ecs_service, rds and Lambda resources in other modules
  name        = "${var.name}-lambda"
  description = "VPC-attached Lambda functions (legacy API during migration, async workers)"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-lambda" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db_proxy" {
  #checkov:skip=CKV2_AWS_5:Attached by the alb, ecs_service, rds and Lambda resources in other modules
  name        = "${var.name}-db-proxy"
  description = "RDS Proxy"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-db-proxy" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  #checkov:skip=CKV2_AWS_5:Attached by the alb, ecs_service, rds and Lambda resources in other modules
  name        = "${var.name}-db"
  description = "RDS PostgreSQL - reachable only from app, lambda and proxy security groups"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-db" }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------- ALB ----------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from clients"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Port 80 only issues a 301 redirect to HTTPS (or serves dev traffic when no TLS
# certificate is configured).
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  #checkov:skip=CKV_AWS_260:Port 80 on the public ALB only redirects to HTTPS
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from clients (redirected to HTTPS)"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to ECS tasks"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

# Lambda targets behind the ALB (traffic shifting during the migration) are invoked
# through the Lambda API by the ALB service and need no network rule.

# ---------------------------------- App ----------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Traffic from the ALB only"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs (VPC endpoints / NAT)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "app_to_proxy" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL via RDS Proxy"
  referenced_security_group_id = aws_security_group.db_proxy.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL direct (migrations task, or when the proxy is disabled)"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
}

# --------------------------------- Lambda --------------------------------------------

resource "aws_vpc_security_group_egress_rule" "lambda_https" {
  security_group_id = aws_security_group.lambda.id
  description       = "HTTPS to AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_proxy" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "PostgreSQL via RDS Proxy"
  referenced_security_group_id = aws_security_group.db_proxy.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
}

# ------------------------------- RDS Proxy -------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "proxy_from_clients" {
  for_each = {
    app    = aws_security_group.app.id
    lambda = aws_security_group.lambda.id
  }

  security_group_id            = aws_security_group.db_proxy.id
  description                  = "PostgreSQL from ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
}

resource "aws_vpc_security_group_egress_rule" "proxy_to_db" {
  security_group_id            = aws_security_group.db_proxy.id
  description                  = "PostgreSQL to the database"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
}

# ---------------------------------- RDS ----------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "db_from_clients" {
  for_each = {
    app   = aws_security_group.app.id
    proxy = aws_security_group.db_proxy.id
  }

  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
}
# No egress rules on the database security group: RDS never initiates connections.
