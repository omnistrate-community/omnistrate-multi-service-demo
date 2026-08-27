# ==============================================================================
# Durable AI Platform / Plan 2 "Temporal AI Platform" / resource: visibilityDb
# Cloud: AZURE
# ==============================================================================
#
# WHAT THIS STACK DOES
#   Provisions the managed PostgreSQL 16 server behind Temporal's VISIBILITY
#   store (Cassandra visibility was removed in Temporal v1.24, the chart carries
#   an explicit `fail` guard, so SQL visibility is the only legal option), plus a
#   second database on the same server for Trino's Iceberg JDBC catalog.
#
# ##########################################################################
# ## THE AZURE-ONLY STEP: azure.extensions MUST INCLUDE btree_gin         ##
# ##########################################################################
#   Temporal's PostgreSQL visibility schema executes `CREATE EXTENSION btree_gin`.
#   btree_gin.control declares `trusted = true`, so since PG13 any non-superuser
#   with CREATE on the database can install it, which is why AWS RDS and GCP
#   Cloud SQL both work with no extra configuration.
#
#   Azure is different. Flexible Server refuses to create ANY extension that is
#   not on the `azure.extensions` server-parameter allowlist, regardless of role.
#   Miss this and Azure fails at Temporal schema-setup time while AWS and GCP
#   sail through, a per-cloud Terraform step, not an afterthought. It is
#   implemented below as `azurerm_postgresql_flexible_server_configuration`.
#
# DATABASE OWNERSHIP, the other privilege trap
#   The Temporal visibility schema also needs a `convert_ts` plpgsql function and
#   CREATE on schema `public`. A role with only CONNECT fails with
#   `permission denied for schema public` (PG15+ removed the public CREATE grant).
#   The role must OWN the database. On Azure the clean way to guarantee that
#   without a second Terraform provider reaching a private-only server is to make
#   the application login the SERVER ADMINISTRATOR, hence
#   `administrator_login = var.pg_user` (default "temporal").
#
#   Worth confirming: databases created through the ARM control plane
#   (azurerm_postgresql_flexible_server_database) land owned by `azure_pg_admin`,
#   of which the administrator login is a member. Membership conveys the owner's
#   privileges in PostgreSQL, so the schema job should pass. Confirm on the first
#   Azure deploy with:
#       SELECT datname, pg_get_userbyid(datdba) FROM pg_database;
#   If the owner is not `temporal`, run once as the admin:
#       ALTER DATABASE temporal_visibility OWNER TO temporal;
#       ALTER DATABASE iceberg_catalog     OWNER TO temporal;
#
# NO OPERATOR-SUPPLIED SENTINELS, every value arrives from Omnistrate templating.
#
# PLAN-SPEC WIRING
#
#   - name: visibilityDb
#     internal: true
#     dependsOn: [netAttach]
#     apiParameters:
#       - key: visibilityPassword
#         name: Visibility Store Password
#         type: Password
#         required: true
#         modifiable: false
#         export: false
#     terraformConfigurations:
#       configurationPerCloudProvider:
#         azure:
#           terraformPath: /terraform/azure/visibilitydb
#           gitConfiguration:
#             reference: refs/tags/v1.0.0
#             repositoryUrl: <this repo>
#           variablesValuesFileOverride: |
#             instance_id         = "{{ $sys.id }}"
#             region              = "{{ $sys.deploymentCell.region }}"
#             subscription_id     = "{{ $sys.deploymentCell.azure.subscriptionID }}"
#             tenant_id           = "{{ $sys.deploymentCell.azure.tenantID }}"
#             vnet_id             = "{{ $sys.deploymentCell.cloudProviderNetworkID }}"
#             resource_group_name = "{{ $netAttach.out.resource_group_name }}"
#             db_subnet_id        = "{{ $netAttach.out.db_subnet_id }}"
#             private_dns_zone_id = "{{ $netAttach.out.private_dns_zone_id }}"
#             pg_password         = "{{ $var.visibilityPassword }}"
#           requiredOutputs:
#             - key: pg_endpoint
#               exported: true
#             - key: pg_visibility_db
#               exported: true
#             - key: pg_iceberg_db
#               exported: true
#
# ==============================================================================

provider "azurerm" {
  features {
    postgresql_flexible_server {
      # `azure.extensions` is a DYNAMIC parameter, it takes effect without a
      # restart. The provider's default behaviour is to bounce the server after
      # any configuration change, which would add several minutes of downtime to
      # every apply for no reason.
      restart_server_on_configuration_value_change = false
    }
  }

  subscription_id                 = var.subscription_id != "" ? var.subscription_id : null
  tenant_id                       = var.tenant_id != "" ? var.tenant_id : null
  resource_provider_registrations = "none"
}

locals {
  # --- name sanitisation -------------------------------------------------------
  # Flexible Server names are 3-63 chars, lowercase letters, digits and hyphens.
  id_alnum   = lower(replace(var.instance_id, "/[^A-Za-z0-9]/", ""))
  id_trimmed = startswith(local.id_alnum, "instance") ? substr(local.id_alnum, 8, -1) : local.id_alnum
  id_slug    = local.id_trimmed != "" ? local.id_trimmed : local.id_alnum
  name_slug  = substr(local.id_slug, 0, 40)

  server_name = "pg-${local.name_slug}"

  # --- resource group derivation (identical logic in all four Azure stacks) ----
  vnet_id_parts  = split("/", var.vnet_id)
  vnet_id_is_arm = length(local.vnet_id_parts) >= 9
  parsed_vnet_rg = local.vnet_id_is_arm ? local.vnet_id_parts[4] : ""

  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : local.parsed_vnet_rg

  common_tags = merge(
    {
      omnistrate_instance_id = var.instance_id
      omnistrate_resource    = "visibilityDb"
      managed_by             = "omnistrate"
    },
    var.tags,
  )
}

# ------------------------------------------------------------------------------
# PostgreSQL 16 Flexible Server, VNet-integrated (private access).
#
# `public_network_access_enabled` is left unset, because supplying
# `delegated_subnet_id` puts the server in private-access mode, where the API
# owns that field. Setting it explicitly is how people get
# "public_network_access_enabled cannot be set with delegated_subnet_id" at apply
# time, long after `tofu validate` said the config was fine.
# ------------------------------------------------------------------------------
resource "azurerm_postgresql_flexible_server" "main" {
  name                = local.server_name
  resource_group_name = local.resource_group_name
  location            = var.region
  version             = var.pg_version

  delegated_subnet_id = var.db_subnet_id
  private_dns_zone_id = var.private_dns_zone_id

  # The application login IS the server administrator, see the ownership note in
  # the header. Temporal's schema tool needs CREATE on schema public.
  administrator_login    = var.pg_user
  administrator_password = var.pg_password

  sku_name              = var.pg_sku_name
  storage_mb            = var.pg_storage_mb
  auto_grow_enabled     = true
  backup_retention_days = var.pg_backup_retention_days

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = false
  }

  tags = local.common_tags

  lifecycle {
    # The availability zone is chosen by Azure when unspecified; without this the
    # next plan wants to move the server, which is a destroy-and-recreate.
    ignore_changes = [zone]

    precondition {
      condition     = local.resource_group_name != ""
      error_message = "resource_group_name could not be determined. Pass resource_group_name (preferably {{ $netAttach.out.resource_group_name }}) or a full ARM vnet_id."
    }
  }
}

# ##############################################################################
# ## AZURE-ONLY: allowlist btree_gin before Temporal's visibility schema runs. ##
# ##                                                                          ##
# ## This single resource is the difference between "Azure works" and "Azure  ##
# ## fails at schema time while AWS and GCP pass". There is no AWS or GCP     ##
# ## equivalent.                                                              ##
# ##############################################################################
resource "azurerm_postgresql_flexible_server_configuration" "azure_extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id

  # Worth confirming: whether the allowlist is case-sensitive. Azure's own portal shows
  # the values uppercased in the picker while the CLI examples use lowercase, and
  # PostgreSQL extension names are lowercase. Lowercase is used here; if a
  # `CREATE EXTENSION btree_gin` still returns "extension is not allow-listed",
  # re-apply with BTREE_GIN and file the finding.
  value = join(",", [for e in var.azure_extensions : lower(e)])
}

# ------------------------------------------------------------------------------
# Databases.
#
#   temporal_visibility : Temporal's visibility store. The Temporal chart's
#                         datastore KEY must be exactly `visibility` (the schema
#                         directory path derives from it), that is a chart value,
#                         not a database name. This is the database it points at.
#   iceberg_catalog     : Trino's Iceberg JDBC catalog, a second database on the
#                         same server rather than a separate REST catalog tier.
#
# Both are created only after the extension allowlist is in place, so nothing can
# race the schema job.
# ------------------------------------------------------------------------------
resource "azurerm_postgresql_flexible_server_database" "visibility" {
  name      = var.pg_visibility_db_name
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  depends_on = [azurerm_postgresql_flexible_server_configuration.azure_extensions]
}

resource "azurerm_postgresql_flexible_server_database" "iceberg" {
  name      = var.pg_iceberg_db_name
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  depends_on = [azurerm_postgresql_flexible_server_configuration.azure_extensions]
}
