# ==============================================================================
# Durable AI Platform / Azure / storageInfra / provider pinning
#
# NO `backend` BLOCK. Omnistrate stores OpenTofu state in Kubernetes secrets and
# strips any backend configuration it finds.
#
# hashicorp/time is present for exactly one reason: Azure RBAC role assignments
# take up to a few minutes to propagate to the Key Vault data plane, and creating
# a key immediately after granting yourself Key Vault Crypto Officer fails with
# 403 Forbidden. See the time_sleep resource in main.tf.
# ==============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
