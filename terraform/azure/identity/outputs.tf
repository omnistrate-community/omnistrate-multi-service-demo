# -----------------------------------------------------------------------------
# identityInfra (Azure), output contract.
# Exactly one key, spelled identically on aws/ and gcp/.
# -----------------------------------------------------------------------------

output "workload_identity_ref" {
  description = <<-EOT
    The single string the Kubernetes layer needs to assume this identity. Same
    key name on every cloud, with a different payload on each:

      AWS    IAM role ARN     -> annotation eks.amazonaws.com/role-arn
      GCP    GSA email        -> annotation iam.gke.io/gcp-service-account
      Azure  managed id       -> annotation azure.workload.identity/client-id   (this)
             client id           plus pod label azure.workload.identity/use: "true"

    So the Helm layer writes one templated annotation value,
    `{{ $identityInfra.out.workload_identity_ref }}`, and only the annotation
    KEY differs per cloud, a per-cloud chartValues line, not a per-cloud chart.

    Azure needs one extra thing the other two clouds do not: the pod LABEL
    `azure.workload.identity/use: "true"`, without which the mutating webhook
    never injects the token volume and the annotation is silently inert. Every
    chart in Plan 2 therefore sets that label on Azure. Forgetting it produces a
    pod that starts cleanly and fails only at the first storage call.
  EOT
  value       = azurerm_user_assigned_identity.workload.client_id
}

output "workload_identity_principal_id" {
  description = <<-EOT
    Object (principal) id of the managed identity.

    Not part of the cross-cloud contract, Azure-only, and present because it is
    what you need to grant any ADDITIONAL role by hand while debugging. The
    client_id above is what Kubernetes consumes; this is what the Azure control
    plane consumes.
  EOT
  value       = azurerm_user_assigned_identity.workload.principal_id
}
