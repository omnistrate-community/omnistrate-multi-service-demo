// -----------------------------------------------------------------------------
// visibilityDb (GCP), inputs
//
// Plain portable Terraform. The variables with no default are supplied by the
// plan spec through `variablesValuesFileOverride`.
// -----------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project that owns the Cloud SQL instance. Wired from `$sys.deploymentCell.gcp.projectID`."
  type        = string
}

variable "region" {
  description = "Deployment cell region, from `$sys.deploymentCell.region`. Must match the region of the VPC the PSA peering was created in."
  type        = string
}

variable "network" {
  description = "The deployment cell's existing VPC, from `$sys.deploymentCell.cloudProviderNetworkID`, the same value netAttach used. Bare name, partial URL or self_link all accepted."
  type        = string
}

variable "instance_id" {
  description = "Omnistrate instance id, from `$sys.id`."
  type        = string
}

variable "db_subnet_group_name" {
  description = <<-EOT
    Wired from `{{ $netAttach.out.db_subnet_group_name }}`. Same key name as
    AWS, different meaning: on GCP this is the *allocated IP range* of the
    Private Service Access peering, which Cloud SQL consumes verbatim as
    `settings.ip_configuration.allocated_ip_range`.

    Empty string is legal and safe, Cloud SQL then picks any free range inside
    the peering.
  EOT
  type        = string
  default     = ""
}

variable "db_security_group_id" {
  description = <<-EOT
    Wired from `{{ $netAttach.out.db_security_group_id }}` purely so the plan
    spec's `variablesValuesFileOverride` block is identical on all three clouds.
    GCP has no attachable security group: a Cloud SQL private-IP instance lives
    in Google's producer VPC and its reachability comes from the PSA peering,
    not from a firewall rule you bind to it. Accepted and intentionally unused;
    it is not folded into user_labels because a firewall self-link contains "/"
    and Cloud SQL label values are restricted to [a-z0-9_-].
  EOT
  type        = string
  default     = ""
}

variable "database_version" {
  description = <<-EOT
    Temporal's SQL plugin targets PostgreSQL 12 and later
    are untested by Temporal. Pin 16.
  EOT
  type        = string
  default     = "POSTGRES_17"
}

variable "tier" {
  description = <<-EOT
    Machine tier. db-custom-N-M = N vCPU, M MiB RAM, and requires
    edition = ENTERPRISE. 2 vCPU / 7.5 GiB comfortably carries Temporal
    visibility plus the Iceberg JDBC catalog for a demo-scale workload.
  EOT
  type        = string
  default     = "db-custom-2-7680"
}

variable "edition" {
  description = "ENTERPRISE or ENTERPRISE_PLUS. db-custom-* tiers require ENTERPRISE."
  type        = string
  default     = "ENTERPRISE"
}

variable "availability_type" {
  description = "ZONAL or REGIONAL. REGIONAL doubles the cost; use it if the demo needs an HA story."
  type        = string
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.availability_type)
    error_message = "availability_type must be ZONAL or REGIONAL."
  }
}

variable "disk_size" {
  description = "Initial data disk size in GiB."
  type        = number
  default     = 100
}

variable "disk_type" {
  description = "PD_SSD or PD_HDD. Temporal visibility is write-heavy and latency-sensitive."
  type        = string
  default     = "PD_SSD"
}

variable "pg_user" {
  description = <<-EOT
    Application role. Must match `server.config.persistence.datastores.visibility.sql.user`
    in the Temporal chart values, and the Trino Iceberg JDBC catalog user.
  EOT
  type        = string
  default     = "temporal"
}

variable "pg_password" {
  description = <<-EOT
    Optional. Leave empty (the default) and a strong password is generated and
    published on the `pg_password` output. Plan 2 supplies it instead, as
    `{{ $var.visibilityPassword }}`, so the customer chooses one password that
    the same tfvars key carries on all three clouds. Azure requires this, since
    its administrator password is fixed at server creation and that module
    cannot generate its own.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "pg_visibility_db" {
  description = <<-EOT
    Temporal's visibility database. The DATASTORE must be named exactly
    `visibility` in the chart (temporal.persistence.schema maps store name to
    schema directory); the database name itself is free, and
    `temporal_visibility` is what Temporal's own tooling defaults to.
  EOT
  type        = string
  default     = "temporal_visibility"
}

variable "pg_iceberg_db" {
  description = <<-EOT
    Second database on the SAME server, backing Trino's Iceberg JDBC catalog
    (iceberg.catalog.type=jdbc). Reusing this server is what lets us skip an
    entire REST-catalog tier.
  EOT
  type        = string
  default     = "iceberg_catalog"
}

variable "backup_start_time" {
  description = "HH:MM UTC for the daily automated backup window."
  type        = string
  default     = "03:00"
}

variable "transaction_log_retention_days" {
  description = "PITR window in days. Requires backup_configuration.enabled."
  type        = number
  default     = 7
}

variable "database_flags" {
  description = <<-EOT
    Optional Cloud SQL database flags, name => value.

    Empty by default. Unlike Azure Flexible Server, where
    `btree_gin` MUST be added to the `azure.extensions` server parameter or
    Temporal's schema setup fails, Cloud SQL needs no allowlist step:
    btree_gin.control declares `trusted = true`, so since PG13 any role with
    CREATE on the database can install it. This variable exists for tuning
    (e.g. max_connections), not for the extension.
  EOT
  type        = map(string)
  default     = {}
}

variable "user_labels" {
  description = "Cloud SQL user labels. Keys/values must be lowercase alphanumeric, hyphen or underscore."
  type        = map(string)
  default     = {}
}
