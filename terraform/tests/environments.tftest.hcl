# Offline tests: `terraform test` (no AWS credentials needed; the AWS provider is mocked).
# They exercise every environment's variables end to end, catching wiring mistakes,
# variable validation failures and policy regressions before a real plan ever runs.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "333333333333" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::127311923021:root" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      port    = 5432
      db_name = "orders"
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:333333333333:secret:rds!db-0000-AbCdEf"
        kms_key_id    = "arn:aws:kms:us-east-1:333333333333:key/0000"
        secret_status = "active"
      }]
    }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:333333333333:key/11111111-2222-3333-4444-555555555555" }
  }
  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:333333333333:loadbalancer/app/xyzz-orders/abc"
      arn_suffix = "app/xyzz-orders/abc"
      dns_name   = "xyzz-orders-123.us-east-1.elb.amazonaws.com"
    }
  }
  # The provider validates ARN syntax even for mocked values.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::333333333333:role/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:333333333333:log-group:mock" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:333333333333:mock" }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = { arn = "arn:aws:wafv2:us-east-1:333333333333:regional/webacl/mock/0000" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:333333333333:targetgroup/mock/abc"
      arn_suffix = "targetgroup/mock/abc"
    }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:333333333333:listener/app/xyzz-orders/abc/def" }
  }
  mock_resource "aws_db_proxy_default_target_group" {
    defaults = { name = "default" }
  }
  mock_resource "aws_db_proxy" {
    defaults = { name = "xyzz-orders-prod", endpoint = "xyzz-orders-prod.proxy-abc.us-east-1.rds.amazonaws.com" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:333333333333:certificate/abc"
      domain_validation_options = [{
        domain_name           = "api.xyzz.example.com"
        resource_record_name  = "_abc.api.xyzz.example.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_def.acm-validations.aws."
      }]
    }
  }
  mock_resource "aws_acm_certificate_validation" {
    defaults = { certificate_arn = "arn:aws:acm:us-east-1:333333333333:certificate/abc" }
  }
}

variables {
  container_image    = "333333333333.dkr.ecr.us-east-1.amazonaws.com/xyzz-orders-api:test"
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

run "dev" {
  command = apply

  variables {
    environment                = "dev"
    allowed_account_ids        = ["111111111111"]
    vpc_cidr                   = "10.10.0.0/16"
    availability_zones         = ["us-east-1a", "us-east-1b"]
    single_nat_gateway         = true
    enable_interface_endpoints = false
    min_tasks                  = 1
    max_tasks                  = 3
    fargate_base               = 0
    fargate_weight             = 0
    fargate_spot_weight        = 1
    db_instance_class          = "db.t4g.micro"
    db_multi_az                = false
    db_max_connections         = 100
    enable_rds_proxy           = false
  }

  assert {
    condition     = startswith(output.api_url, "http://")
    error_message = "dev without a domain should serve plain HTTP on the ALB DNS name."
  }

  assert {
    condition     = length(output.private_app_subnet_ids) == 2
    error_message = "dev should span two AZs."
  }
}

run "prod" {
  command = apply

  variables {
    environment         = "prod"
    allowed_account_ids = ["333333333333"]
    vpc_cidr            = "10.30.0.0/16"
    availability_zones  = ["us-east-1a", "us-east-1b", "us-east-1c"]
    single_nat_gateway  = false
    domain_name         = "api.xyzz.example.com"
    hosted_zone_id      = "Z00000000PRODZONE"
    min_tasks           = 3
    max_tasks           = 30
    fargate_base        = 3
    fargate_weight      = 3
    fargate_spot_weight = 1
    db_instance_class   = "db.r7g.large"
    db_multi_az         = true
    db_max_connections  = 1700
    enable_rds_proxy    = true
  }

  assert {
    condition     = output.api_url == "https://api.xyzz.example.com"
    error_message = "prod must be served over HTTPS on its custom domain."
  }

  assert {
    condition     = length(output.private_app_subnet_ids) == 3 && length(output.nat_gateway_public_ips) == 3
    error_message = "prod must span three AZs with one NAT gateway per AZ."
  }

  assert {
    condition     = length(aws_route53_record.api) == 2
    error_message = "prod needs A and AAAA alias records."
  }
}

run "migration_canary" {
  command = apply

  variables {
    environment                = "prod"
    allowed_account_ids        = ["333333333333"]
    vpc_cidr                   = "10.30.0.0/16"
    min_tasks                  = 3
    max_tasks                  = 30
    db_instance_class          = "db.r7g.large"
    db_multi_az                = true
    db_max_connections         = 1700
    legacy_lambda_function_arn = "arn:aws:lambda:us-east-1:333333333333:function:orders-api-legacy:live"
    ecs_traffic_weight         = 25
    canary_routing = {
      header_name  = "X-Orders-Canary"
      header_value = "ecs"
      source_cidrs = ["203.0.113.0/24"]
    }
  }

  assert {
    condition     = output.ecs_service_name == "xyzz-orders-prod"
    error_message = "unexpected service name"
  }
}

run "rejects_bad_traffic_weight" {
  command = plan

  variables {
    environment         = "prod"
    allowed_account_ids = ["333333333333"]
    vpc_cidr            = "10.30.0.0/16"
    min_tasks           = 3
    max_tasks           = 30
    db_instance_class   = "db.r7g.large"
    db_multi_az         = true
    db_max_connections  = 1700
    ecs_traffic_weight  = 150
  }

  expect_failures = [var.ecs_traffic_weight]
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment         = "qa"
    allowed_account_ids = ["333333333333"]
    vpc_cidr            = "10.30.0.0/16"
    min_tasks           = 1
    max_tasks           = 2
    db_instance_class   = "db.t4g.micro"
    db_multi_az         = false
    db_max_connections  = 100
  }

  expect_failures = [var.environment]
}
