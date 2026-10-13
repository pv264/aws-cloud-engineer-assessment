/**
 * Private, encrypted S3 bucket with secure defaults:
 *   - all four Block Public Access settings on, ACLs disabled (BucketOwnerEnforced)
 *   - default encryption (SSE-KMS with a bucket key, or SSE-S3 where a service
 *     such as ALB access logging does not support KMS)
 *   - TLS-only bucket policy
 *   - optional versioning and lifecycle tiering / expiry
 */

resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV2_AWS_62:No consumer for bucket events
  #checkov:skip=CKV_AWS_144:Cross-region replication is a DR-tier decision, not required for the current RPO/RTO
  #checkov:skip=CKV_AWS_18:Object-level audit comes from CloudTrail S3 data events (organisation trail)
  #checkov:skip=CKV_AWS_21:Versioning is a per-bucket input; disabled only for the ALB access-log bucket
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = var.versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "tiering-and-expiry"
    status = "Enabled"
    filter {}

    dynamic "transition" {
      for_each = var.transition_to_ia_days == null ? [] : [var.transition_to_ia_days]
      content {
        days          = transition.value
        storage_class = "STANDARD_IA"
      }
    }

    dynamic "transition" {
      for_each = var.transition_to_glacier_days == null ? [] : [var.transition_to_glacier_days]
      content {
        days          = transition.value
        storage_class = "GLACIER_IR"
      }
    }

    dynamic "expiration" {
      for_each = var.expiration_days == null ? [] : [var.expiration_days]
      content {
        days = expiration.value
      }
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

data "aws_iam_policy_document" "this" {
  source_policy_documents = var.additional_policy_documents

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]
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

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.this.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
