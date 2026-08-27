# ---------------------------------------------------------------------------
# Durable AI Platform, Plan 2 / identityInfra / Azure
#
# Versions are pinned here because the platform does not pin them, and the
# engine that runs these files is OpenTofu.
# No `backend` block anywhere in this repository. Omnistrate stores state in
# Kubernetes secrets and strips any backend it finds.
#
# `time` is here for a specific reason, not for convenience: Azure RBAC role
# assignments are eventually consistent, and a pod that starts before the
# assignment has propagated gets a 403 from Blob storage that looks exactly like
# a misconfigured identity. See the sleep in main.tf.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}
