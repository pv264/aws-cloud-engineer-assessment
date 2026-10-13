/**
 * Customer-managed KMS key for the environment's data at rest: RDS storage and
 * snapshots, the RDS master-user secret, Performance Insights, CloudWatch log groups,
 * SNS, ECS Exec sessions and the application S3 bucket.
 *
 * A CMK (rather than AWS-managed keys) gives us a key policy we control, CloudTrail
 * visibility of every decrypt, the ability to share encrypted snapshots across accounts
 * (DR / restore into another account), and a kill switch.
 */

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition
}

data "aws_iam_policy_document" "key" {
  #checkov:skip=CKV_AWS_109:Key policy: "*" refers to this key; root delegation to IAM is the AWS-recommended default
  #checkov:skip=CKV_AWS_111:Key policy: "*" refers to this key
  #checkov:skip=CKV_AWS_356:Key policy: "*" refers to this key
  # Delegate to IAM: access is granted by IAM policies in this account (least
  # privilege per role), not by listing principals here.
  statement {
    sid       = "EnableIAMPolicies"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid = "AllowCloudWatchLogs"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:*"]
    }
  }

  # CloudWatch alarms publish to the KMS-encrypted SNS alerts topic.
  statement {
    sid       = "AllowCloudWatchAlarmsToSNS"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "${var.name} data-at-rest key"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.key.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}
