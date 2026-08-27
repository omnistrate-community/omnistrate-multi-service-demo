# ==============================================================================
# Durable AI Platform / Azure / storageInfra / inputs
# ==============================================================================

variable "instance_id" {
  description = "Omnistrate instance identifier ({{ $sys.id }}). Drives the storage account and key vault names (see the sanitisation strategy in main.tf)."
  type        = string

  validation {
    condition     = length(replace(lower(var.instance_id), "/[^a-z0-9]/", "")) >= 3
    error_message = "instance_id must contain at least 3 alphanumeric characters: an Azure storage account name has a 3-character minimum after sanitisation."
  }
}

variable "region" {
  description = "Azure location for created resources ({{ $sys.deploymentCell.region }})."
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID ({{ $sys.deploymentCell.azure.subscriptionID }}). Empty string falls back to ARM_SUBSCRIPTION_ID."
  type        = string
  default     = ""
}

variable "tenant_id" {
  description = "Azure tenant ID ({{ $sys.deploymentCell.azure.tenantID }}). Empty string falls back to the tenant of the authenticated service principal."
  type        = string
  default     = ""
}

variable "vnet_id" {
  description = "The cell VNet's ARM resource ID ({{ $sys.deploymentCell.cloudProviderNetworkID }}). Used only to derive the resource group when resource_group_name is not supplied."
  type        = string
  default     = ""
}

variable "resource_group_name" {
  description = "Resource group to create storage in. Empty string = parse it out of vnet_id. Prefer feeding {{ $netAttach.out.resource_group_name }} so all four stacks agree."
  type        = string
  default     = ""
}

variable "container_name" {
  description = "Primary blob container: Iceberg warehouse + vLLM model weights. This is what the shared `bucket_name` output returns."
  type        = string
  default     = "warehouse"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.container_name))
    error_message = "Azure container names are 3-63 chars, lowercase letters, digits and hyphens, and cannot start or end with a hyphen."
  }
}

variable "medusa_container_name" {
  description = "Blob container Cassandra/Medusa writes backups into. Plan 1 takes its bucket as apiParameters; point them at this container when reusing this account."
  type        = string
  default     = "medusa"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.medusa_container_name))
    error_message = "Azure container names are 3-63 chars, lowercase letters, digits and hyphens, and cannot start or end with a hyphen."
  }
}

variable "account_replication_type" {
  description = "Storage account replication. LRS is the demo default; ZRS/GRS cost more."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.account_replication_type)
    error_message = "account_replication_type must be one of LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

variable "hierarchical_namespace_enabled" {
  description = <<-EOT
    Enable ADLS Gen2 hierarchical namespace. Required for Trino's native Azure
    filesystem (`fs.azure.enabled`) to address the Iceberg warehouse over
    abfss://. Blob VERSIONING is not supported on HNS accounts, so versioning is
    switched off automatically when this is true.
    Worth confirming: Medusa's azure_blobs backend against an HNS account. Medusa uses
    the Blob REST API, which HNS accounts serve, but this specific combination has
    not been exercised. Set to false if Medusa backups misbehave, Trino can still
    read the warehouse over the blob endpoint, with reduced listing performance.
  EOT
  type        = bool
  default     = true
}

variable "key_vault_purge_protection_enabled" {
  description = "Purge protection blocks permanent deletion for the whole soft-delete window. Left off for the demo so a torn-down instance's vault name is immediately reusable. Turn ON for anything real, and note that customer-managed keys on a storage account REQUIRE it."
  type        = bool
  default     = false
}

variable "key_vault_soft_delete_retention_days" {
  description = "Key Vault soft-delete retention. 7 is the Azure minimum."
  type        = number
  default     = 7

  validation {
    condition     = var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90
    error_message = "key_vault_soft_delete_retention_days must be between 7 and 90."
  }
}

variable "rbac_propagation_delay" {
  description = "How long to wait after granting the deploying principal Key Vault Crypto Officer before creating the key. Azure RBAC propagation to the Key Vault data plane is eventually consistent."
  type        = string
  default     = "120s"
}

variable "tags" {
  description = "Extra tags merged onto every resource. Azure tag NAMES may not contain < > % & \\ ? /."
  type        = map(string)
  default     = {}
}
