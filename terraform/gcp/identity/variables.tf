// -----------------------------------------------------------------------------
// identityInfra (GCP), inputs
// -----------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project holding the workload identity pool, the bucket and the Cloud SQL instance."
  type        = string
  default     = "{{ $sys.deploymentCell.gcp.projectID }}"
}

variable "region" {
  description = "Deployment cell region. Only used to configure the provider; IAM is global."
  type        = string
  default     = "{{ $sys.deploymentCell.region }}"
}

variable "instance_id" {
  description = "Omnistrate instance id, part of the service account id."
  type        = string
  default     = "{{ $sys.id }}"
}

variable "namespace" {
  description = <<-EOT
    Kubernetes namespace the instance's pods run in. Omnistrate puts one
    namespace per instance and every resource of that instance lands in it.
  EOT
  type        = string
  default     = "{{ $sys.deployment.resourceKubernetesNamespace }}"
}

variable "ksa_names" {
  description = <<-EOT
    Kubernetes service accounts inside `namespace` that may impersonate the
    Google service account.

    Default is the single KSA Omnistrate provisions for this resource
    (`$sys.deployment.kubernetesServiceAccountName`).

    Open question: whether Omnistrate issues one KSA per instance namespace or one
    per resource. If it is per-resource, the KSA that vllmInference / trino /
    aiWorkers actually run as is a different name and the binding below will
    not cover them. Confirm with
    `kubectl -n <instance-ns> get serviceaccounts` on a live instance; if there
    is more than one, list them all here from the plan spec via
    `variablesValuesFileOverride`, e.g.

      ksa_names = ["{{ $sys.deployment.kubernetesServiceAccountName }}", "default"]

    Adding a name that does not exist is harmless, an IAM member referencing a
    non-existent KSA principal is accepted and simply never used.
  EOT
  type        = list(string)
  default     = ["{{ $sys.deployment.kubernetesServiceAccountName }}"]

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
