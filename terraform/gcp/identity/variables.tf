// -----------------------------------------------------------------------------
// identityInfra (GCP), inputs
//
// Plain portable Terraform. The variables with no default are supplied by the
// plan spec through `variablesValuesFileOverride`.
// -----------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project holding the workload identity pool, the bucket and the Cloud SQL instance. Wired from `$sys.deploymentCell.gcp.projectID`."
  type        = string
}

variable "region" {
  description = "Deployment cell region, from `$sys.deploymentCell.region`. Only used to configure the provider; IAM is global."
  type        = string
}

variable "instance_id" {
  description = "Omnistrate instance id, from `$sys.id`. Part of the service account id."
  type        = string
}

variable "namespace" {
  description = <<-EOT
    Kubernetes namespace the instance's pods run in, from
    `$sys.deployment.resourceKubernetesNamespace`. Omnistrate puts one namespace
    per instance and every resource of that instance lands in it.
  EOT
  type        = string
}

variable "ksa_names" {
  description = <<-EOT
    Kubernetes service accounts inside `namespace` that may impersonate the
    Google service account.

    Supplied from the plan spec via `variablesValuesFileOverride`, e.g.

      ksa_names = ["{{ $sys.deployment.kubernetesServiceAccountName }}", "default"]

    The list needs one entry per KSA the instance's pods actually run as, which
    in plan2 is three names:

      $sys.deployment.kubernetesServiceAccountName
                  the KSA Omnistrate provisions. vllmInference is pinned to it
                  through the chart's serviceAccountName value.
      ai-worker   the local ai-worker chart sets serviceAccount.create: true
                  with an empty name, so the name falls through to the release
                  name.
      default     the temporal and trino charts both ship
                  serviceAccount.create: false with an empty name, so their pods
                  use the namespace's default KSA.

    Confirm against a live instance with
    `kubectl -n <instance-ns> get serviceaccounts`.

    Adding a name that does not exist is harmless, an IAM member referencing a
    non-existent KSA principal is accepted and simply never used.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.ksa_names) > 0
    error_message = "ksa_names must contain at least one Kubernetes service account name."
  }
}

variable "bucket_name" {
  description = <<-EOT
    Wired from `{{ $storageInfra.out.bucket_name }}`. Bucket the workload reads
    model weights from and writes Iceberg data to. Empty skips the bucket
    bindings, which is only useful when testing this stack in isolation.
  EOT
  type        = string
  default     = ""
}

variable "grant_cloudsql_client" {
  description = <<-EOT
    Grant roles/cloudsql.client at project scope.

    Not strictly required by this design, Temporal and Trino both connect
    straight to the Cloud SQL private IP with a password, which needs no IAM at
    all. It is granted so that a Cloud SQL Auth Proxy sidecar or an
    `omctl`-driven debugging session works without a second Terraform round
    trip. Set false to keep the project IAM policy untouched.
  EOT
  type        = bool
  default     = true
}

variable "bucket_roles" {
  description = <<-EOT
    Bucket-scoped roles for the workload service account.

      roles/storage.objectAdmin        read/write/delete objects. Trino's
                                       Iceberg writer needs delete for
                                       compaction and expire-snapshots.
      roles/storage.legacyBucketReader grants storage.buckets.get. objectAdmin
                                       does NOT include it, and several clients
                                       (including bucket-existence probes in
                                       object-store filesystems) call it before
                                       the first read.
  EOT
  type        = list(string)
  default     = ["roles/storage.objectAdmin", "roles/storage.legacyBucketReader"]
}

variable "sa_display_name" {
  description = "Human-readable name shown in the IAM console."
  type        = string
  default     = "Durable AI Platform workload"
}
