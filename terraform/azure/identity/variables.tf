# ---------------------------------------------------------------------------
# Durable AI Platform / Plan 2 / identityInfra / Azure / inputs
# ---------------------------------------------------------------------------

variable "instance_id" {
  description = "Omnistrate instance id ($sys.id). Part of the managed-identity name."
  type        = string
}

variable "region" {
  description = "Azure region of the deployment cell ($sys.deploymentCell.region)."
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription of the deployment cell ($sys.deploymentCell.azure.subscriptionID)."
  type        = string
}

variable "tenant_id" {
  description = "Entra tenant ($sys.deploymentCell.azure.tenantID)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create the identity in. Wired from `{{ $netAttach.out.resource_group_name }}` so the identity shares the instance's lifecycle."
  type        = string
}

variable "oidc_issuer" {
  description = <<-EOT
    The AKS cluster's OIDC issuer URL, from `$sys.deploymentCell.oidcIssuerID`.

    Azure differs from AWS here: `azurerm_federated_identity_credential.issuer`
    wants the FULL URL including the `https://` scheme, and AKS issuer URLs
    carry a trailing slash. `local.issuer_url` below normalises whatever form
    arrives into that shape rather than trusting the caller.

    Example:
      https://eastus.oic.prod-aks.azure.com/<tenant-guid>/<cluster-guid>/
  EOT
  type        = string

  validation {
    condition     = length(trimspace(var.oidc_issuer)) > 0
    error_message = "oidc_issuer must be set, without it the federated credential cannot be created."
  }
}

variable "namespace" {
  description = "Kubernetes namespace the instance's pods run in ($sys.deployment.resourceKubernetesNamespace)."
  type        = string
}

variable "ksa_names" {
  description = <<-EOT
    Kubernetes service accounts inside `namespace` allowed to federate to this
    identity.

    Azure imposes a structural cost the other two clouds do not: a federated
    identity credential holds exactly ONE subject, so N service accounts means N
    separate credential resources (created with for_each below), not one
    credential with a list. There is also a hard limit of 20 federated
    credentials per managed identity.

    Open question, shared with the AWS and GCP modules: whether
    Omnistrate issues one KSA per instance namespace or one per resource.
    Confirm with `kubectl -n <instance-ns> get serviceaccounts`.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.ksa_names) > 0 && length(var.ksa_names) <= 20
    error_message = "ksa_names must contain between 1 and 20 names (Azure allows at most 20 federated credentials per managed identity)."
  }
}

variable "name_prefix" {
  description = "Short prefix for created resource names. Keep it <= 10 characters."
  type        = string
  default     = "daip"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,10}$", var.name_prefix))
    error_message = "name_prefix must be 1-10 lowercase alphanumeric or hyphen characters."
  }
}

variable "storage_account_id" {
  description = <<-EOT
    Wired from `{{ $storageInfra.out.storage_account_id }}`. Scope for the
    Storage Blob Data Contributor assignment.

    Empty skips the blob role assignment, only useful for an isolated syntax
    check.
  EOT
  type        = string
  default     = ""
}

variable "key_vault_id" {
  description = <<-EOT
    Wired from `{{ $storageInfra.out.key_vault_id }}`. Scope for the Key Vault
    Crypto User assignment, needed when the container is encrypted with a
    customer-managed key.

    Empty skips the Key Vault role assignment.
  EOT
  type        = string
  default     = ""
}

variable "rbac_propagation_delay" {
  description = <<-EOT
    How long to wait after creating role assignments before declaring this stack
    done.

    Azure RBAC is eventually consistent, typically a few
    seconds but occasionally minutes, and a workload pod that starts too early
    gets an opaque 403 from Blob storage. Because Omnistrate deploys the Helm
    layers as soon as this Terraform resource reports success, the wait belongs
    here, the alternative is a demo that fails intermittently at the first
    model-weight read.
  EOT
  type        = string
  default     = "60s"
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}
