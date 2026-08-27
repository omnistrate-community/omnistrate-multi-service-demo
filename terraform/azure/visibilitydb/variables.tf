# ==============================================================================
# Durable AI Platform / Azure / visibilityDb / inputs
# ==============================================================================

variable "instance_id" {
  description = "Omnistrate instance identifier ({{ $sys.id }}). Drives the server name."
  type        = string
}

variable "region" {
  description = "Azure location for the Flexible Server ({{ $sys.deploymentCell.region }})."
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID ({{ $sys.deploymentCell.azure.subscriptionID }}). Empty string falls back to ARM_SUBSCRIPTION_ID."
  type        = string
  default     = ""
}

variable "tenant_id" {
  description = "Azure tenant ID ({{ $sys.deploymentCell.azure.tenantID }}). Empty string falls back to ARM_TENANT_ID."
  type        = string
  default     = ""
}

variable "vnet_id" {
  description = "The cell VNet's ARM resource ID ({{ $sys.deploymentCell.cloudProviderNetworkID }}). Used only to derive the resource group when resource_group_name is not supplied."
  type        = string
  default     = ""
}

variable "resource_group_name" {
  description = "Resource group to create the server in. Empty string = parse it out of vnet_id. Prefer {{ $netAttach.out.resource_group_name }}."
  type        = string
  default     = ""
}

variable "db_subnet_id" {
  description = "ARM resource ID of the delegated subnet from the netattach stack ({{ $netAttach.out.db_subnet_id }}). Must be delegated to Microsoft.DBforPostgreSQL/flexibleServers."
  type        = string

  validation {
    condition     = can(regex("/subnets/", var.db_subnet_id))
    error_message = "db_subnet_id must be a full ARM subnet resource ID; wire it to {{ $netAttach.out.db_subnet_id }}."
  }
}

variable "private_dns_zone_id" {
  description = "ARM resource ID of the private DNS zone from the netattach stack ({{ $netAttach.out.private_dns_zone_id }}). The zone must already be linked to the VNet."
  type        = string

  validation {
    condition     = can(regex("/privateDnsZones/", var.private_dns_zone_id))
    error_message = "private_dns_zone_id must be a full ARM private DNS zone resource ID; wire it to {{ $netAttach.out.private_dns_zone_id }}."
  }
}

variable "pg_version" {
  description = "PostgreSQL major version. Temporal actively tests 13.18 / 14.15 / 15.10 / 16.6; 17 and 18 are untested by Temporal. Stay on 16."
  type        = string
  default     = "16"

  validation {
    condition     = contains(["13", "14", "15", "16"], var.pg_version)
    error_message = "pg_version must be one of 13, 14, 15, 16, the majors Temporal tests against."
  }
}

variable "pg_user" {
  description = "PostgreSQL login Temporal and Trino connect as. It doubles as the Flexible Server administrator login, since Temporal's visibility schema needs CREATE on schema public and the role must own the databases."
  type        = string
  default     = "temporal"

  validation {
    condition     = !contains(["azure_superuser", "azure_pg_admin", "admin", "administrator", "root", "guest", "public"], lower(var.pg_user)) && !startswith(lower(var.pg_user), "pg_")
    error_message = "Azure rejects these administrator logins: azure_superuser, azure_pg_admin, admin, administrator, root, guest, public, and anything starting with pg_."
  }
}

variable "pg_password" {
  description = "Password for pg_user. Supplied by the customer as the Plan 2 apiParameter `visibilityPassword` ({{ $var.visibilityPassword }}) so the same value can be typed into the Temporal chart's inline `password:` field. Echoed back on the `pg_password` output for callers that would rather read it from Terraform."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.pg_password) >= 8 && length(var.pg_password) <= 128
    error_message = "Azure requires an administrator password of 8-128 characters."
  }
}

variable "pg_visibility_db_name" {
  description = "Database holding Temporal's visibility store. The Temporal chart's datastore must be named exactly `visibility`; this is the DATABASE name it connects to."
  type        = string
  default     = "temporal_visibility"
}

variable "pg_iceberg_db_name" {
  description = "Second database on the same server, backing Trino's Iceberg JDBC catalog (iceberg.catalog.type=jdbc). Reusing this server avoids standing up a whole REST catalog tier."
  type        = string
  default     = "iceberg_catalog"
}

variable "pg_sku_name" {
  description = "Flexible Server SKU. GP_Standard_D2ds_v5 (2 vCPU / 8 GiB) is the safe default. B_Standard_B2s roughly halves the idle cost for a demo, at the price of burstable CPU and no zone-redundant HA."
  type        = string
  default     = "GP_Standard_D2ds_v5"
}

variable "pg_storage_mb" {
  description = "Provisioned storage in MB. 32768 (32 GiB) is the Azure minimum."
  type        = number
  default     = 32768

  validation {
    condition     = var.pg_storage_mb >= 32768
    error_message = "Azure PostgreSQL Flexible Server requires at least 32768 MB of storage."
  }
}

variable "pg_backup_retention_days" {
  description = "Automated backup retention (7-35 days)."
  type        = number
  default     = 7

  validation {
    condition     = var.pg_backup_retention_days >= 7 && var.pg_backup_retention_days <= 35
    error_message = "pg_backup_retention_days must be between 7 and 35."
  }
}

variable "pg_port" {
  description = "PostgreSQL port. Azure Flexible Server is always 5432 and it is not configurable, this exists so the `pg_port` output is a single source of truth."
  type        = number
  default     = 5432
}

variable "azure_extensions" {
  description = <<-EOT
    Extensions added to the `azure.extensions` server parameter allowlist.
    btree_gin is MANDATORY: Temporal's PostgreSQL visibility schema runs
    `CREATE EXTENSION btree_gin`, and on Azure an extension that is not on this
    allowlist cannot be created even by the server administrator. Omit it and
    Azure fails at schema time while AWS and GCP pass. There is no AWS/GCP
    analogue to this step.
  EOT
  type        = list(string)
  default     = ["btree_gin"]

  validation {
    condition     = contains([for e in var.azure_extensions : lower(e)], "btree_gin")
    error_message = "azure_extensions must include btree_gin, Temporal's visibility schema fails without it on Azure."
  }
}

variable "tags" {
  description = "Extra tags merged onto every resource. Azure tag NAMES may not contain < > % & \\ ? /."
  type        = map(string)
  default     = {}
}
