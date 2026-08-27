# ---------------------------------------------------------------------------
# Durable AI Platform, Plan 2 / identityInfra / AWS
#
# Creates the IRSA role the instance's pods assume to reach the storage bucket.
# Nothing here is long-lived: the pod presents a projected service-account token
# to STS and gets short-term credentials back. There is no access key in this
# stack, and none is needed on AWS or GCP.
#
# Azure is the exception: Medusa cannot use workload identity there, so the
# Cassandra plan takes a static storage key. See terraform/azure/storage.
#
# The provider block lives in this top-level file because Omnistrate requires it
# in the top-level .tf of each stack.
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.region
}

locals {
  # Accept the issuer with or without a scheme and normalise to the bare
  # host+path form, which is what both the provider ARN and the trust-policy
  # condition keys use.
  oidc_host = replace(var.oidc_issuer, "https://", "")

  oidc_provider_arn = "arn:aws:iam::${var.account_id}:oidc-provider/${local.oidc_host}"

  # IAM role names allow [\w+=,.@-] and cap at 64 characters. Instance ids are
  # already safe, but truncate defensively so a longer id can never produce an
  # InvalidClientTokenId-style failure at apply time.
  role_name = substr("${var.name_prefix}-wi-${var.instance_id}", 0, 64)

  # The subjects this role trusts, one per allowed KSA.
  subjects = [for ksa in var.ksa_names : "system:serviceaccount:${var.namespace}:${ksa}"]

  manage_bucket = length(trimspace(var.bucket_name)) > 0
  manage_kms    = length(trimspace(var.kms_key_id)) > 0

  tags = merge(
    {
      "omnistrate.com/instance-id" = var.instance_id
      "app.kubernetes.io/part-of"  = "durable-ai-platform"
    },
    var.tags,
  )
}

# ---------------------------------------------------------------------------
# Trust policy
#
# Scoped to this instance's namespace AND its service accounts. Both conditions
# matter: `:aud` alone would let any pod in the cluster assume the role, which
# in a shared deployment cell means any OTHER TENANT's pod. StringLike (not
# StringEquals) only because `subjects` may hold several values.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "IRSAAssumeRoleWithWebIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "workload" {
  name                 = local.role_name
  description          = "Durable AI Platform workload identity for Omnistrate instance ${var.instance_id}"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  tags                 = local.tags
}

# ---------------------------------------------------------------------------
# Permissions
#
# Narrow by design: object CRUD on one bucket, list on that bucket, and
# decrypt or encrypt with the one CMK. No s3:* and no wildcard resource.
#
# s3:DeleteObject is required. Trino's Iceberg writer deletes during compaction
# and expire-snapshots, and vLLM's streamer cleans up partial reads.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "workload" {
  dynamic "statement" {
    for_each = local.manage_bucket ? [1] : []

    content {
      sid    = "BucketLevel"
      effect = "Allow"
      actions = [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads",
      ]
      resources = ["arn:aws:s3:::${var.bucket_name}"]
    }
  }

  dynamic "statement" {
    for_each = local.manage_bucket ? [1] : []

    content {
      sid    = "ObjectLevel"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
      ]
      resources = ["arn:aws:s3:::${var.bucket_name}/*"]
    }
  }

  dynamic "statement" {
    for_each = local.manage_kms ? [1] : []

    content {
      sid    = "BucketCMK"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
      ]
      resources = [var.kms_key_id]
    }
  }

  # Keeps the document valid when both bucket_name and kms_key_id are empty
  # (isolated syntax check). An IAM policy with zero statements is rejected.
  dynamic "statement" {
    for_each = (local.manage_bucket || local.manage_kms) ? [] : [1]

    content {
      sid       = "NoOp"
      effect    = "Deny"
      actions   = ["s3:GetObject"]
      resources = ["arn:aws:s3:::placeholder-no-bucket-wired/*"]
    }
  }
}

resource "aws_iam_policy" "workload" {
  name        = substr("${local.role_name}-policy", 0, 128)
  description = "Bucket and CMK access for Durable AI Platform instance ${var.instance_id}"
  policy      = data.aws_iam_policy_document.workload.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "workload" {
  role       = aws_iam_role.workload.name
  policy_arn = aws_iam_policy.workload.arn
}

resource "aws_iam_role_policy_attachment" "extra" {
  for_each = toset(var.extra_policy_arns)

  role       = aws_iam_role.workload.name
  policy_arn = each.value
}
