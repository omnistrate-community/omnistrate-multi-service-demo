# ==============================================================================
# Durable AI Platform / Plan 2 "Temporal AI Platform" / resource: storageInfra
# Cloud: AZURE
# ==============================================================================
#
# WHAT THIS STACK DOES
#   Creates the object store that backs (a) the Iceberg warehouse Trino queries
#   and (b) the vLLM model weights loaded with `--load-format runai_streamer`,
#   plus a Key Vault and key that stand in for the AWS `kms_key_id` output.
#
#   It ALSO emits `medusa_storage_account` / `medusa_storage_key`. Azure is the
#   one honest asymmetry in this design: Medusa cannot use workload identity on
#   Azure, medusa/storage/azure_storage.py requires AZURE_STORAGE_ACCOUNT from
#   the environment and pkg/medusa/reconcile.go whole-struct-overwrites the
#   container spec, destroying any `env` the CR declares. So Azure Medusa needs a
#   long-lived storage key in a Kubernetes Secret (referenced from Plan 1 as
#   `medusa.storageProperties.storageSecretRef.name`), where AWS uses IRSA and
#   GCP uses Workload Identity with no secret at all. Say it out loud rather than
#   claiming uniform keyless identity across three clouds.
#
# STORAGE ACCOUNT NAME SANITISATION  (the Azure-only naming trap)
#   Azure storage account names are 3-24 characters, LOWERCASE ALPHANUMERIC ONLY
#, no hyphens, no underscores, no uppercase, and globally unique across all
#   of Azure. Omnistrate instance IDs look like `instance-abc123xyz`, which is
#   both too long once prefixed and full of illegal characters. Strategy:
#     1. lowercase and strip every non-alphanumeric character
#     2. drop the leading literal "instance" (it carries no entropy and eats 8 of
#        the 24 characters); fall back to the untrimmed value if that empties it
#     3. prefix "dai" (Durable AI) so the name always starts with a letter and
#        clears the 3-character minimum
#     4. truncate to 24, substr() returns the whole string when it is shorter,
#        so this is safe for short IDs
#   The Key Vault name (3-24, alphanumeric + hyphens, must start with a letter)
#   reuses the same slug with a "kv-" prefix.
#
# NO OPERATOR-SUPPLIED SENTINELS, every value arrives from Omnistrate templating.
#
# PLAN-SPEC WIRING
#
#   - name: storageInfra
#     internal: true
#     dependsOn: [netAttach]
#     terraformConfigurations:
#       configurationPerCloudProvider:
#         azure:
#           terraformPath: /terraform/azure/storage
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
#           requiredOutputs:
#             - key: bucket_uri
#               exported: true
#             - key: bucket_name
#               exported: true
#             - key: medusa_storage_account
#               exported: true
#
# ==============================================================================

provider "azurerm" {
  features {
    key_vault {
      # Demo hygiene: a destroyed instance must not leave a soft-deleted vault
      # squatting on its name for 7-90 days.
      purge_soft_delete_on_destroy       = true
      purge_soft_deleted_keys_on_destroy = true
      recover_soft_deleted_key_vaults    = true
    }
  }

  subscription_id                 = var.subscription_id != "" ? var.subscription_id : null
  tenant_id                       = var.tenant_id != "" ? var.tenant_id : null
  resource_provider_registrations = "none"
}

data "azurerm_client_config" "current" {}

locals {
  # --- name sanitisation (see the header block) --------------------------------
  id_alnum   = lower(replace(var.instance_id, "/[^A-Za-z0-9]/", ""))
  id_trimmed = startswith(local.id_alnum, "instance") ? substr(local.id_alnum, 8, -1) : local.id_alnum
  id_slug    = local.id_trimmed != "" ? local.id_trimmed : local.id_alnum

  # 3-24 chars, lowercase alphanumeric ONLY.
  storage_account_name = substr("dai${local.id_slug}", 0, 24)

  # 3-24 chars, alphanumeric + hyphens, must start with a letter.
  key_vault_name = substr("kv-${local.id_slug}", 0, 24)

  # --- resource group derivation (identical logic in all four Azure stacks) ----
  vnet_id_parts  = split("/", var.vnet_id)
  vnet_id_is_arm = length(local.vnet_id_parts) >= 9
  parsed_vnet_rg = local.vnet_id_is_arm ? local.vnet_id_parts[4] : ""

  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : local.parsed_vnet_rg

  tenant_id = var.tenant_id != "" ? var.tenant_id : data.azurerm_client_config.current.tenant_id

  common_tags = merge(
    {
      omnistrate_instance_id = var.instance_id
      omnistrate_resource    = "storageInfra"
      managed_by             = "omnistrate"
    },
    var.tags,
  )
}

# ------------------------------------------------------------------------------
# Storage account, the Azure analogue of an S3 bucket's *account*.
#
# On Azure the "bucket" concept splits in two: the ACCOUNT (globally unique DNS
# name, holds the credentials) and the CONTAINER (the namespace objects live in).
# The shared `bucket_name` output returns the CONTAINER, because that is what
# every consumer, Iceberg warehouse path, vLLM model URI, Medusa `bucket_name`, # actually addresses.
# ------------------------------------------------------------------------------
resource "azurerm_storage_account" "main" {
  name                = local.storage_account_name
  resource_group_name = local.resource_group_name
  location            = var.region

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.account_replication_type

  # ADLS Gen2. Required for Trino's `fs.azure.enabled` to address the
  # Iceberg warehouse over abfss://.
  is_hns_enabled = var.hierarchical_namespace_enabled

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # MUST stay true. This is the whole reason `medusa_storage_key` can exist:
  # Azure Medusa authenticates with a shared key, not workload identity.
  shared_access_key_enabled = true

  # The cell's node subnets are not enumerable from here and Omnistrate exposes no
  # service-endpoint hook, so the account stays reachable from the public endpoint
  # and is protected by RBAC + TLS. Tighten with network_rules once the cell's
  # subnet IDs are known.
  public_network_access_enabled = true

  blob_properties {
    # Blob versioning is NOT supported on hierarchical-namespace accounts; asking
    # for both is an apply-time error, so it follows the HNS switch.
    versioning_enabled  = !var.hierarchical_namespace_enabled
    change_feed_enabled = false

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = local.resource_group_name != ""
      error_message = "resource_group_name could not be determined. Pass resource_group_name (preferably {{ $netAttach.out.resource_group_name }}) or a full ARM vnet_id."
    }
  }
}

# ------------------------------------------------------------------------------
# Containers.
#   warehouse : Iceberg tables written by the AI workers + Qwen3.5-4B weights
#   medusa    : Cassandra backups, when Plan 1 is pointed at this account
#
# azurerm 5.x takes `storage_account_id`; the old `storage_account_name` argument
# is gone.
# ------------------------------------------------------------------------------
resource "azurerm_storage_container" "warehouse" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "medusa" {
  name                  = var.medusa_container_name
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

# ------------------------------------------------------------------------------
# Key Vault + key, the Azure stand-in for aws_kms_key.
#
# RBAC authorization (not access policies) is mandatory here: the identity stack
# grants the workload "Key Vault Crypto User" with an azurerm_role_assignment,
# and role assignments only take effect on a vault in RBAC mode.
#
# NOTE: this key is NOT wired as the storage account's customer-managed key.
# Storage-account CMK requires purge protection permanently enabled plus a
# user-assigned identity holding Key Vault Crypto Service Encryption User that
# exists BEFORE the account, a chicken-and-egg with the identity stack that
# depends on this one. The account uses Microsoft-managed keys; the vault key is
# published as `kms_key_id` for application-level envelope encryption, matching
# what the AWS stack emits.
# ------------------------------------------------------------------------------
resource "azurerm_key_vault" "main" {
  name                = local.key_vault_name
  location            = var.region
  resource_group_name = local.resource_group_name
  tenant_id           = local.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days

  public_network_access_enabled = true

  tags = local.common_tags
}

# The deploying BYOA service principal has ARM control-plane rights over the
# vault but no DATA-plane rights until it is granted them, creating a key
# without this fails with 403 Forbidden.
resource "azurerm_role_assignment" "deployer_crypto_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Azure RBAC is eventually consistent: the assignment above needs to reach the
# Key Vault data plane before the key create call, or the apply dies on a 403
# that a re-run would have fixed.
resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.deployer_crypto_officer]
  create_duration = var.rbac_propagation_delay
}

resource "azurerm_key_vault_key" "main" {
  name         = "dai-envelope-key"
  key_vault_id = azurerm_key_vault.main.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  tags = local.common_tags

  depends_on = [time_sleep.rbac_propagation]
}
