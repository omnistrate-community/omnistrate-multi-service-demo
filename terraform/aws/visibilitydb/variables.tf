variable "instance_id" {
  description = "Omnistrate instance id ($sys.id). Part of the RDS identifier so two instances in one cell never collide."
  type        = string

  validation {
    condition     = length(trimspace(var.instance_id)) > 0
    error_message = "instance_id must not be empty; wire it to {{ $sys.id }}."
  }
}

variable "region" {
  description = "AWS region of the deployment cell ($sys.deploymentCell.region)."
  type        = string
}

# -- wired from netAttach ---------------------------------------------------

variable "db_subnet_group_name" {
  description = "RDS DB subnet group. Wire to {{ $netAttach.out.db_subnet_group_name }}."
  type        = string
}

variable "db_security_group_id" {
  description = "Security group admitting PostgreSQL from the cell. Wire to {{ $netAttach.out.db_security_group_id }}."
  type        = string
}

# -- engine -----------------------------------------------------------------

variable "engine_version" {
  description = "PostgreSQL major (or major.minor) version. Temporal's SQL plugin targets PostgreSQL 12 and later. A major-only value lets RDS pick the newest available minor, which matters because AWS blocks new instances on retired minors."
  type        = string
  default     = "17"

  validation {
    condition     = can(regex("^(1[6-8])(\\.[0-9]+)?$", var.engine_version))
    error_message = "engine_version must be a PostgreSQL 16, 17 or 18 major, optionally with a minor."
  }
}

variable "instance_class" {
  description = "RDS instance class. db.t4g.medium is the demo default; move to db.m7g.large or larger for load tests."
  type        = string
  default     = "db.t4g.medium"
}

variable "allocated_storage" {
  description = "Initial gp3 storage in GiB (minimum 20)."
  type        = number
  default     = 50

  validation {
    condition     = var.allocated_storage >= 20
    error_message = "allocated_storage must be at least 20 GiB for gp3."
  }
}

variable "max_allocated_storage" {
  description = "Upper bound for RDS storage autoscaling in GiB. Set equal to allocated_storage to disable autoscaling."
  type        = number
  default     = 200
}

variable "storage_kms_key_id" {
  description = "Optional CMK for RDS storage encryption. Empty means the AWS-managed aws/rds key. Not wired to storageInfra by default, since a shared key would couple the database's lifecycle to the bucket's."
  type        = string
  default     = ""
}

variable "multi_az" {
  description = "Multi-AZ deployment. False for the demo (halves the cost, doubles nothing that gets shown)."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Automated backup retention in days. 0 disables backups."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "RDS deletion protection. MUST stay false: Omnistrate runs `terraform destroy` when the instance is deleted, and RDS refuses to drop a protected instance, which wedges the delete workflow. Deletion protection for this platform lives at the plan level (enableDeletionProtection)."
  type        = bool
  default     = false
}

variable "publicly_accessible" {
  description = "Assign a public IP to the database. Keep false, the security group only admits the cell's private CIDRs anyway."
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = "Enable RDS Performance Insights (7-day free tier)."
  type        = bool
  default     = false
}

variable "force_ssl" {
  description = <<-EOT
    Set rds.force_ssl. Default false, and that is a considered choice:
    Temporal's postgres12 plugin builds its DSN with sslmode=disable unless an
    explicit tls block is configured, so force_ssl=1 makes the visibility store
    fail to connect at schema time with a pg_hba error. The server still offers
    TLS to any client that asks for it (Terraform's own postgresql provider
    connects with sslmode=require), and the only route to port 5432 is the
    cell's private CIDRs. Flip this to true only in tandem with server.config
    .persistence.datastores.visibility.sql.tls in the Temporal chart values.
  EOT
  type        = bool
  default     = false
}

# -- databases and role -----------------------------------------------------

variable "pg_user" {
  description = "Master role name. It OWNS both databases, which is the privilege level Temporal's schema tool needs: CREATE EXTENSION btree_gin requires CREATE on the database, and a non-owner with only CONNECT fails with 'permission denied for schema public'."
  type        = string
  default     = "temporal"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.pg_user))
    error_message = "pg_user must be 1-63 chars, lowercase, starting with a letter (RDS master username rules)."
  }
}

variable "pg_password" {
  description = "Master password. Leave empty (the default) to generate a 32-character alphanumeric password. Plan 2 supplies it instead from the visibilityPassword apiParameter, which is declared export: false, so the value stays out of result_params. A literal password typed into the plan spec would not be protected that way."
  type        = string
  default     = ""
  sensitive   = true
}

variable "pg_port" {
  description = "PostgreSQL port. Must match db_port in the netattach stack."
  type        = number
  default     = 5432
}

variable "pg_visibility_db" {
  description = "Database backing Temporal's visibility store. Created natively by RDS as the instance's initial database, which is what makes pg_user its owner."
  type        = string
  default     = "temporal_visibility"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.pg_visibility_db))
    error_message = "pg_visibility_db must be 1-63 chars, lowercase, starting with a letter."
  }
}

variable "pg_iceberg_db" {
  description = "Second database backing Trino's Iceberg JDBC catalog. Reusing this server avoids standing up a whole REST catalog tier."
  type        = string
  default     = "iceberg_catalog"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.pg_iceberg_db))
    error_message = "pg_iceberg_db must be 1-63 chars, lowercase, starting with a letter."
  }
}

variable "manage_pg_objects" {
  description = "Create the Iceberg catalog database and pre-create btree_gin over a live SQL connection. Requires the OpenTofu runner to reach port 5432 in the cell VPC. Set false to skip both; Temporal still works, but Trino's Iceberg catalog will have nowhere to live."
  type        = bool
  default     = true
}

variable "pg_locale" {
  description = "LC_COLLATE / LC_CTYPE for the created database. RDS PostgreSQL initialises clusters as en_US.UTF-8."
  type        = string
  default     = "en_US.UTF-8"
}

variable "name_prefix" {
  description = "Short prefix for every created resource name. Keep it <= 10 characters."
  type        = string
  default     = "daip"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,9}$", var.name_prefix))
    error_message = "name_prefix must be 2-10 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }
}

variable "tags" {
  description = "Extra tags merged onto every taggable resource."
  type        = map(string)
  default     = {}
}
