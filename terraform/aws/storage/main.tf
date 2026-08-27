# ===========================================================================
#  Durable AI Platform, Plan 2, resource `storageInfra`  (AWS)
# ===========================================================================
#
#  WHAT THIS STACK DOES
#    One encrypted S3 bucket that serves two consumers:
#      * the Trino Iceberg warehouse   (s3://<bucket>/warehouse)
#      * the vLLM model weights        (s3://<bucket>/models/...)
#    ...plus the customer-managed KMS key that encrypts it and the alias that
#    makes that key legible in the console during the demo.
#
#    Access is granted exclusively through the IAM role built by
#    terraform/aws/identity, this stack contains no principals, so there is no
#    dependency cycle between storage and identity.
#
#  OMNISTRATE WIRING, variablesValuesFileOverride for the aws entry:
#
#      instance_id = "{{ $sys.id }}"
#      region      = "{{ $sys.deploymentCell.region }}"
#
#  ...and the outputs this stack publishes:
#
#      requiredOutputs:
#        - key: bucket_uri
#          exported: true
#        - key: bucket_name
#          exported: true
#        - key: bucket_region
#          exported: true
#        - key: kms_key_id
#          exported: false
#
#  IAM ACTIONS this stack needs in features.CUSTOM_TERRAFORM_POLICY.policies.aws:
#      s3:CreateBucket, s3:DeleteBucket, s3:ListBucket, s3:GetBucket*, s3:PutBucket*,
#      s3:DeleteBucketPolicy, s3:GetObject, s3:PutObject, s3:DeleteObject,
#      s3:ListBucketVersions, s3:DeleteObjectVersion, s3:GetLifecycleConfiguration,
#      s3:PutLifecycleConfiguration, s3:GetEncryptionConfiguration,
#      s3:PutEncryptionConfiguration,
#      kms:CreateKey, kms:CreateAlias, kms:DeleteAlias, kms:DescribeKey,
#      kms:ScheduleKeyDeletion, kms:EnableKeyRotation, kms:DisableKeyRotation,
#      kms:GetKeyPolicy, kms:PutKeyPolicy, kms:GetKeyRotationStatus,
#      kms:ListAliases, kms:ListResourceTags, kms:TagResource, kms:UntagResource,
#      sts:GetCallerIdentity
#
#  There are no REPLACE_ME sentinels in this stack, every input comes from
#  $sys.* at deploy time.
# ===========================================================================

provider "aws" {
  region = var.region
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  slug        = trim(substr(lower(replace(var.instance_id, "/[^a-zA-Z0-9]+/", "-")), 0, 32), "-")
  name        = "${var.name_prefix}-${local.slug}"
  bucket_name = var.bucket_name_override != "" ? var.bucket_name_override : local.name

  bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}"

  tags = merge(
    {
      "Name"                       = local.name
      "app.kubernetes.io/part-of"  = "durable-ai-platform"
      "omnistrate.com/instance-id" = var.instance_id
      "omnistrate.com/component"   = "storage"
    },
    var.tags,
  )
}

# ---------------------------------------------------------------------------
# Customer-managed KMS key
#
# The key policy grants the account root full control and nothing else. That is
# deliberate: it delegates authorization to IAM, which is what lets
# terraform/aws/identity attach kms:Decrypt/GenerateDataKey to the workload role
# WITHOUT storage having to know that role's ARN. A key policy naming the role
# would make storage depend on identity, which already depends on storage.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "EnableIAMUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowUseThroughS3InThisAccount"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "Durable AI Platform object storage key for ${var.instance_id}"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = var.enable_key_rotation
  policy                  = data.aws_iam_policy_document.kms.json

  tags = local.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.this.key_id
}

# ---------------------------------------------------------------------------
# The bucket: Iceberg warehouse + vLLM model weights
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.tags, { "Name" = local.bucket_name })
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this.arn
    }

    # S3 Bucket Keys cut KMS request volume by ~99% for the many-small-objects
    # access pattern Iceberg produces. Without it the KMS bill and the KMS
    # request-rate quota both become real problems at demo scale.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # The versioning resource must settle first or the noncurrent-version rule is
  # rejected on a bucket that is not yet versioned.
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_upload_days
    }
  }

  dynamic "rule" {
    for_each = var.versioning_enabled ? [1] : []

    content {
      id     = "expire-noncurrent-versions"
      status = "Enabled"

      filter {}

      noncurrent_version_expiration {
        noncurrent_days = var.noncurrent_version_expiration_days
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Bucket policy
#
#  1. Refuse anything that is not TLS.
#  2. Refuse a PUT that explicitly names a KMS key other than ours.
#     Note the IfExists/Null pair: a PUT with no encryption header at all is
#     allowed, because S3 then applies the bucket default (our key). A plain
#     StringNotEquals would deny every ordinary unencrypted-header upload,
#     which is exactly how Trino and the RunAI streamer write.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]

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

  statement {
    sid       = "DenyWrongKmsKeyOnUpload"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.this.arn]
    }

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  # A bucket policy applied before the public access block can be rejected by
  # BlockPublicPolicy evaluation ordering; make the ordering explicit.
  depends_on = [aws_s3_bucket_public_access_block.this]
}
