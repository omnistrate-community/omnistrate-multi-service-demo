# ---------------------------------------------------------------------------
# Durable AI Platform, Plan 2 / storageInfra / AWS
#
# Versions are pinned here because the platform does not pin them, and the
# engine that runs these files is OpenTofu.
# No `backend` block anywhere in this repository. Omnistrate stores state in
# Kubernetes secrets and strips any backend it finds.
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
