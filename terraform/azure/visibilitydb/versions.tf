# ==============================================================================
# Durable AI Platform / Azure / visibilityDb / provider pinning
#
# NO `backend` BLOCK. Omnistrate stores OpenTofu state in Kubernetes secrets and
# strips any backend configuration it finds.
# ==============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.2"
    }
  }
}
