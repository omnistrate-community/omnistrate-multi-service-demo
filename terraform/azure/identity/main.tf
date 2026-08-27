# ---------------------------------------------------------------------------
# Durable AI Platform, Plan 2 / identityInfra / Azure
#
# Creates the user-assigned managed identity the instance's pods federate to,
# plus one federated credential per allowed Kubernetes service account.
#
# Scope note, so the asymmetry is not a surprise later: this module gives the
# PLAN 2 workloads (vLLM, Trino, aiWorkers, Temporal) keyless access to Blob
# storage, exactly as on AWS and GCP. It does NOT help Plan 1's Medusa backups, # Medusa requires AZURE_STORAGE_ACCOUNT in its environment and
# k8ssandra-operator overwrites the Medusa container spec wholesale, so Medusa
# on Azure takes a static storage key supplied as an apiParameter. That is a real
# limitation of the upstream operator, documented in README "known limitations",
# not something this module can fix.
#
# The provider block lives in this top-level file because Omnistrate requires it
# in the top-level .tf of each stack.
# ---------------------------------------------------------------------------

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  features {}
}

locals {
  # Normalise the issuer into the exact shape azurerm wants: scheme present,
  # exactly one trailing slash.
  issuer_bare = replace(replace(var.oidc_issuer, "https://", ""), "http://", "")
  issuer_url  = "https://${trimsuffix(local.issuer_bare, "/")}/"

  # User-assigned identity names allow alphanumerics, hyphens and underscores,
  # 3-128 characters. Truncate defensively.
  identity_name = substr("${var.name_prefix}-wi-${var.instance_id}", 0, 128)

  manage_blob      = length(trimspace(var.storage_account_id)) > 0
  manage_key_vault = length(trimspace(var.key_vault_id)) > 0

  # One federated credential per KSA, keyed by name so adding or removing a
  # service account does not churn the others.
  federated_subjects = {
    for ksa in var.ksa_names :
    ksa => "system:serviceaccount:${var.namespace}:${ksa}"
  }

  tags = merge(
    {
      "omnistrate.com/instance-id" = var.instance_id
      "app.kubernetes.io/part-of"  = "durable-ai-platform"
    },
    var.tags,
  )
}

resource "azurerm_user_assigned_identity" "workload" {
  name                = local.identity_name
  location            = var.region
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Federated credentials, one per service account.
#
# `audience` is the fixed AKS workload-identity audience. `subject` is what ties
# the credential to a single namespace + service account, which is the tenancy
# boundary in a shared deployment cell.
# ---------------------------------------------------------------------------
resource "azurerm_federated_identity_credential" "workload" {
  for_each = local.federated_subjects

  # azurerm 5.x renamed `parent_id` to `user_assigned_identity_id` and dropped
  # `resource_group_name` entirely (the RG is implied by the parent identity).
  # Verified against the provider schema, not the older published examples.
  name                      = substr("fed-${each.key}", 0, 120)
  user_assigned_identity_id = azurerm_user_assigned_identity.workload.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = local.issuer_url
  subject                   = each.value
}

# ---------------------------------------------------------------------------
# Role assignments
#
# Storage Blob Data Contributor at storage-account scope: read/write/delete
# blobs. Delete is required for Iceberg compaction and expire-snapshots, same as
# on AWS.
#
# Key Vault Crypto Service Encryption User: lets the identity use the CMK the
# container is encrypted with. Without it, blob reads fail with a 403 that reads
# like a container-permission problem.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "blob" {
  count = local.manage_blob ? 1 : 0

  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

resource "azurerm_role_assignment" "key_vault" {
  count = local.manage_key_vault ? 1 : 0

  scope                = var.key_vault_id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

# Absorb RBAC propagation before this resource reports success, see the
# rbac_propagation_delay variable for why this is load-bearing rather than
# defensive padding.
resource "time_sleep" "rbac_propagation" {
  count = (local.manage_blob || local.manage_key_vault) ? 1 : 0

  depends_on = [
    azurerm_role_assignment.blob,
    azurerm_role_assignment.key_vault,
  ]

  create_duration = var.rbac_propagation_delay
}
