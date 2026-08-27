# ---------------------------------------------------------------------------
# Durable AI Platform, Plan 2 / identityInfra / AWS
#
# Versions are pinned here because the platform does not pin them, and the
# engine that runs these files is OpenTofu.
# No `backend` block anywhere in this repository. Omnistrate stores state in
# Kubernetes secrets and strips any backend it finds.
#
# Only the aws provider is needed. There is no `random` here and no
# `aws_iam_access_key` anywhere: IRSA hands the pod short-lived STS credentials
# through a projected service-account token, so this stack creates no long-lived
# secret of any kind.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
