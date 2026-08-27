# ==============================================================================
# Durable AI Platform / Azure / netAttach / provider pinning
#
# NO `backend` BLOCK. Omnistrate stores OpenTofu state in Kubernetes secrets and
# strips any backend configuration it finds. Adding one breaks the deployment.
#
# Versions are pinned here because Omnistrate pins nothing. The runtime is
# OpenTofu (tofu), not HashiCorp Terraform.
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
