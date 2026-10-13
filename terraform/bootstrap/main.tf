/**
 * One-time bootstrap, applied once per AWS account by an administrator (local state,
 * then optionally migrated into the bucket it creates):
 *
 *   1. S3 bucket for Terraform state (versioned, encrypted, TLS-only, no public
 *      access). Locking uses S3 native lock files (use_lockfile), so no DynamoDB.
 *   2. ECR repository for the application image (immutable tags, scan on push).
 *      With one account per environment the repository lives in a shared
 *      "tooling" account and the env accounts get pull access; kept here for brevity.
 *   3. GitHub Actions OIDC trust + IAM roles, so CI never holds long-lived AWS keys:
 *        <project>-gha-ci               build & push images      (main branch only)
 *        <project>-gha-plan             terraform plan, read-only (pull requests, main)
 *        <project>-<env>-gha-terraform  terraform apply           (GitHub environment <env>)
 *        <project>-<env>-gha-deploy     ECS deploy + migrations   (GitHub environment <env>)
 *      GitHub environment protection rules (required reviewers on prod) therefore
 *      gate who can obtain the prod roles at all.
 */

terraform {
  required_version = ">= 1.11.0, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = var.project, ManagedBy = "terraform", Stack = "bootstrap" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  github_repo = "${var.github_owner}/${var.github_repository}"
}

# --------------------------------- State bucket ---------------------------------------

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV2_AWS_62:No consumer for bucket events
  #checkov:skip=CKV_AWS_144:State is versioned; cross-region replication is optional
  #checkov:skip=CKV_AWS_18:Object-level audit comes from CloudTrail S3 data events (organisation trail)
  bucket = "${var.project}-tfstate-${local.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning = every state revision is recoverable (corrupted or bad apply -> restore).
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "state_key" {
  #checkov:skip=CKV_AWS_109:Key policy: "*" refers to this key
  #checkov:skip=CKV_AWS_111:Key policy: "*" refers to this key
  #checkov:skip=CKV_AWS_356:Key policy: "*" refers to this key
  statement {
    sid       = "EnableIAMPolicies"
    actions   = ["kms:*"]
    resources = ["*"] # in a key policy "*" means this key
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "state" {
  description         = "${var.project} Terraform state"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.state_key.json
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 50
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

# ------------------------------------- ECR --------------------------------------------

resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-api"
  image_tag_mutability = "IMMUTABLE" # a tag (git SHA) always means the same bytes

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 100 images (rollback window)"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 100 }
        action       = { type = "expire" }
      },
    ]
  })
}

# ------------------------------ GitHub Actions OIDC -----------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_trust" {
  for_each = merge(
    { ci = ["repo:${local.github_repo}:ref:refs/heads/main"] },
    { plan = ["repo:${local.github_repo}:pull_request", "repo:${local.github_repo}:ref:refs/heads/main"] },
    { for env in var.environments : "${env}-terraform" => ["repo:${local.github_repo}:environment:${env}"] },
    { for env in var.environments : "${env}-deploy" => ["repo:${local.github_repo}:environment:${env}"] },
  )

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

# CI: push images only.
resource "aws_iam_role" "ci" {
  name                 = "${var.project}-gha-ci"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["ci"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ci" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "push-images"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}

# Plan: read-only, plus what `terraform plan` needs on the state bucket (read state,
# write/delete the lock file).
resource "aws_iam_role" "plan" {
  name               = "${var.project}-gha-plan"
  assume_role_policy = data.aws_iam_policy_document.github_trust["plan"].json
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "state_access" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state_access.json
}

# Terraform apply, per environment. Broad by necessity (it creates IAM roles, VPCs,
# databases), so it is confined by: the OIDC subject (only the protected GitHub
# environment can assume it), a permissions boundary on every role it creates (in an
# AWS Organizations setup), SCPs, and the account boundary itself.
resource "aws_iam_role" "terraform" {
  for_each = toset(var.environments)

  name                 = "${var.project}-${each.value}-gha-terraform"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["${each.value}-terraform"].json
  max_session_duration = 7200
}

resource "aws_iam_role_policy_attachment" "terraform_admin" {
  #checkov:skip=CKV_AWS_274:Terraform apply role; only assumable from the protected GitHub environment, bounded by SCPs/permission boundary
  for_each = toset(var.environments)

  role       = aws_iam_role.terraform[each.value].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Application deploys, per environment: least privilege.
resource "aws_iam_role" "deploy" {
  for_each = toset(var.environments)

  name               = "${var.project}-${each.value}-gha-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust["${each.value}-deploy"].json
}

data "aws_iam_policy_document" "deploy" {
  #checkov:skip=CKV_AWS_356:ecs:Describe*/RegisterTaskDefinition do not support resource-level permissions
  for_each = toset(var.environments)

  statement {
    sid = "RegisterAndDeployTaskDefinitions"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:RegisterTaskDefinition",
      "ecs:TagResource",
    ]
    resources = ["*"] # these ECS actions do not support resource-level permissions
  }

  statement {
    sid     = "UpdateOnlyThisEnvironmentsService"
    actions = ["ecs:UpdateService"]
    resources = [
      "arn:aws:ecs:${var.aws_region}:${local.account_id}:service/${var.project}-${each.value}/${var.project}-${each.value}",
    ]
  }

  statement {
    sid       = "RunMigrationTask"
    actions   = ["ecs:RunTask"]
    resources = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/${var.project}-${each.value}:*"]
  }

  statement {
    sid     = "PassOnlyThisEnvironmentsTaskRoles"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${var.project}-${each.value}-execution",
      "arn:aws:iam::${local.account_id}:role/${var.project}-${each.value}-task",
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadMigrationLogs"
    actions   = ["logs:GetLogEvents", "logs:FilterLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/${var.project}-${each.value}/*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = toset(var.environments)

  name   = "ecs-deploy"
  role   = aws_iam_role.deploy[each.value].id
  policy = data.aws_iam_policy_document.deploy[each.value].json
}
