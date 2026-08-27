// =============================================================================
//  Durable AI Platform, Plan 2 resource `visibilityDb`  ::  GCP
// =============================================================================
//
//  WHAT THIS STACK DOES
//    One private-IP Cloud SQL for PostgreSQL 16 instance carrying TWO databases:
//
//      temporal_visibility  Temporal's visibility store. Cassandra visibility
//                           was REMOVED in Temporal v1.24 and the chart hard-
//                           `fail`s on it, so SQL visibility is not a
//                           preference, it is the only legal configuration.
//      iceberg_catalog      Trino's Iceberg JDBC catalog. A second database on
//                           the same server, which is what lets the design skip
//                           an entire REST-catalog tier.
//
//    ...plus the `temporal` role that owns them.
//
//  THE PRIVILEGE QUESTION, ANSWERED
//    Temporal's Postgres visibility schema needs exactly two privileged things:
//    `CREATE EXTENSION btree_gin` and a `convert_ts` plpgsql function. Neither
//    needs superuser. btree_gin.control declares `trusted = true`, so from PG13
//    onward any role holding CREATE on the database can install it. The proven
//    failure boundary is a role with only CONNECT: it dies with
//    "permission denied for schema public". **The role must own the database.**
//
//    On Cloud SQL this is satisfied structurally, not by an explicit ALTER:
//    databases created through the Admin API are owned by `cloudsqlsuperuser`,
//    and every user created through the Admin API is granted membership of
//    `cloudsqlsuperuser`. The `temporal` role therefore inherits ownership
//    rights on both databases. That is why no `postgresql` provider appears in
//    this stack, running ALTER DATABASE ... OWNER TO would require the
//    OpenTofu runner to have a TCP path to a private-IP instance it has no
//    reason to reach.
//
//  SENTINELS THAT MUST BE REPLACED BEFORE USE
//    (none)
//
//  OMNISTRATE WIRING
//    - name: visibilityDb
//      internal: true
//      dependsOn: [netAttach]
//      terraformConfigurations:
//        configurationPerCloudProvider:
//          gcp:
//            terraformPath: /terraform/gcp/visibilitydb
//            variablesValuesFileOverride: |
//              project_id           = "{{ $sys.deploymentCell.gcp.projectID }}"
//              region               = "{{ $sys.deploymentCell.region }}"
//              network              = "{{ $sys.deploymentCell.cloudProviderNetworkID }}"
//              instance_id          = "{{ $sys.id }}"
//              db_subnet_group_name = "{{ $netAttach.out.db_subnet_group_name }}"
//              db_security_group_id = "{{ $netAttach.out.db_security_group_id }}"
//            gitConfiguration:
//              reference: refs/tags/vX.Y.Z
//              repositoryUrl: https://github.com/<org>/omnistrate-platform-demo.git
//            requiredOutputs:
//              - key: pg_endpoint
//                exported: false
//              - key: pg_host
//                exported: false
//              - key: pg_visibility_db
//                exported: false
//              - key: pg_iceberg_db
//                exported: false
//
//    `dependsOn: [netAttach]` is what guarantees the Private Service Access
//    peering exists before Cloud SQL tries to allocate a private IP inside it.
//    There is no intra-stack dependency to express here because the peering
//    lives in a different Omnistrate resource, hence a different tofu state.
//
//  OUTPUT CONTRACT (byte-identical across clouds)
//    pg_endpoint, pg_host, pg_port, pg_visibility_db, pg_iceberg_db,
//    pg_user, pg_password
//
// =============================================================================

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  id_lower = lower(var.instance_id)
  id_clean = replace(local.id_lower, "/[^a-z0-9]+/", "-")
  id_slug  = trim(substr(local.id_clean, 0, min(40, length(local.id_clean))), "-")

  // Cloud SQL instance names: ^[a-z]([-a-z0-9]*[a-z0-9])?$.
  instance_name = "dai-${local.id_slug}-pg-${random_id.suffix.hex}"

  network_self_link = can(regex("^(https://|projects/)", var.network)) ? var.network : "projects/${var.project_id}/global/networks/${var.network}"

  // Omitted rather than empty: passing "" to allocated_ip_range is rejected,
  // whereas null means "let Google choose a free block in the peering".
  allocated_ip_range = var.db_subnet_group_name != "" ? var.db_subnet_group_name : null

  pg_password = var.pg_password != "" ? var.pg_password : random_password.pg[0].result

  pg_port = 5432
}

// -----------------------------------------------------------------------------
// A Cloud SQL instance name cannot be reused for roughly a week after the
// instance is deleted. Omnistrate instance ids are unique per instance, so the
// normal path never collides, but a failed create followed by an automatic
// destroy-and-retry inside the SAME instance would, and it would fail in a way
// that looks like a permissions problem. The random suffix removes that class
// of failure entirely; it is stored in state, so a re-apply is stable.
// -----------------------------------------------------------------------------
resource "random_id" "suffix" {
  byte_length = 3
}

resource "random_password" "pg" {
  count = var.pg_password == "" ? 1 : 0

  length  = 28
  special = true

  // Punctuation is restricted because this password is interpolated into a
  // Helm value, a libpq DSN and a Trino catalog properties file. Anything from
  // {@ / \ : " ' ` $ &} would need three different escapings.
  override_special = "-_=+.~"

  min_lower   = 4
  min_upper   = 4
  min_numeric = 4
  min_special = 2
}

// -----------------------------------------------------------------------------
// The server.
// -----------------------------------------------------------------------------
resource "google_sql_database_instance" "this" {
  name             = local.instance_name
  project          = var.project_id
  region           = var.region
  database_version = var.database_version

  // Both of these must be false or Omnistrate cannot delete the instance:
  // `deletion_protection` is the provider-side guard, `deletion_protection_enabled`
  // is the API-side one, and they are independent.
  deletion_protection = false

  settings {
    tier                        = var.tier
    edition                     = var.edition
    availability_type           = var.availability_type
    disk_size                   = var.disk_size
    disk_type                   = var.disk_type
    disk_autoresize             = true
    deletion_protection_enabled = false
    user_labels                 = var.user_labels

    ip_configuration {
      // Private IP only. No public surface for the visibility store.
      ipv4_enabled       = false
      private_network    = local.network_self_link
      allocated_ip_range = local.allocated_ip_range

      // Lets Google-managed services (and Cloud SQL Studio) reach the instance
      // over the private path without re-enabling a public IP.
      enable_private_path_for_google_cloud_services = true

      // The Temporal postgres12 plugin connects with TLS disabled by default
      // (`tls.enabled: false`). ENCRYPTED_ONLY here would break schema setup
      // before anyone got a useful error message.
      ssl_mode = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
    }

    backup_configuration {
      enabled                        = true
      start_time                     = var.backup_start_time
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = var.transaction_log_retention_days
    }

    dynamic "database_flags" {
      for_each = var.database_flags
      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }
  }
}

// -----------------------------------------------------------------------------
// The two databases.
//
// deletion_policy = "ABANDON" keeps `tofu destroy` from trying to drop a
// database out from under live connections; the whole instance is deleted
// moments later anyway, which takes the databases with it.
// -----------------------------------------------------------------------------
resource "google_sql_database" "visibility" {
  name            = var.pg_visibility_db
  project         = var.project_id
  instance        = google_sql_database_instance.this.name
  deletion_policy = "ABANDON"
}

resource "google_sql_database" "iceberg" {
  name            = var.pg_iceberg_db
  project         = var.project_id
  instance        = google_sql_database_instance.this.name
  deletion_policy = "ABANDON"
}

// -----------------------------------------------------------------------------
// The application role. Created through the Admin API, so it lands with
// cloudsqlsuperuser membership, see the ownership note in the header.
// -----------------------------------------------------------------------------
resource "google_sql_user" "app" {
  name     = var.pg_user
  project  = var.project_id
  instance = google_sql_database_instance.this.name
  password = local.pg_password

  deletion_policy = "ABANDON"

  depends_on = [
    google_sql_database.visibility,
    google_sql_database.iceberg,
  ]
}
