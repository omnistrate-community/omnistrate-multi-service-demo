# -----------------------------------------------------------------------------
# identityInfra (AWS), output contract.
# Exactly one key, spelled identically on gcp/ and azure/.
# -----------------------------------------------------------------------------

output "workload_identity_ref" {
  description = <<-EOT
    The single string the Kubernetes layer needs to assume this identity. Same
    key name on every cloud, with a different payload on each:

      AWS    IAM role ARN     -> annotation eks.amazonaws.com/role-arn        (this)
      GCP    GSA email        -> annotation iam.gke.io/gcp-service-account
      Azure  managed id       -> annotation azure.workload.identity/client-id
             client id           plus pod label azure.workload.identity/use: "true"

    So the Helm layer writes one templated annotation value,
    `{{ $identityInfra.out.workload_identity_ref }}`, and only the annotation
    KEY differs per cloud, a per-cloud chartValues line, not a per-cloud chart.
  EOT
  value       = aws_iam_role.workload.arn
}
