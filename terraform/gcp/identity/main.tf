// =============================================================================
//  Durable AI Platform, Plan 2 resource `identityInfra`  ::  GCP
// =============================================================================
//
//  WHAT THIS STACK DOES
//    Creates the Google service account the platform's pods act as, and binds
//    it to the instance's Kubernetes service account through GKE Workload
//    Identity, the GCP analogue of IRSA. No keys are ever created, downloaded
//    or stored: the whole point of Workload Identity is that
//    `google_service_account_key` does not appear anywhere in this file.
//
//    Also grants the roles the workload actually uses:
//      * bucket-scoped storage roles, vLLM streams the model checkpoint
//                                          from gs://, Trino reads and writes
//                                          the Iceberg warehouse
//      * roles/cloudsql.client (project), optional, for a Cloud SQL Auth Proxy
//                                          path; the direct private-IP path
//                                          needs no IAM
//
//    It does NOT need a KMS binding. With CMEK on GCS the principal that
//    encrypts and decrypts is the *GCS service agent*, not the caller, that
//    grant lives in the storage stack, next to the key it applies to.
//
//  THE BINDING, SPELLED OUT
//    member = "serviceAccount:<project>.svc.id.goog[<namespace>/<ksa>]"
//    role   = "roles/iam.workloadIdentityUser"
//    on     = the Google service account
//
//    and then the KSA carries the annotation
//      iam.gke.io/gcp-service-account: {{ $identityInfra.out.workload_identity_ref }}
//
//  Worth confirming
//    * That Omnistrate's GKE deployment cells are created with Workload
//      Identity enabled (`--workload-pool=<project>.svc.id.goog`). Without it
//      the binding is inert and every GCS call falls back to the node service
//      account. Confirm with:
//        gcloud container clusters describe <cell-cluster> \
//          --format='value(workloadIdentityConfig.workloadPool)'
//    * Whether Omnistrate lets a plan add annotations to the KSA it creates. If
//      not, the workaround is to have the charts declare their own service
//      account with the annotation and list those names in `ksa_names`.
//
//  SENTINELS THAT MUST BE REPLACED BEFORE USE
//    (none)
//
//  OMNISTRATE WIRING
//    - name: identityInfra
//      internal: true
//      dependsOn: [storageInfra, visibilityDb]
//      terraformConfigurations:
//        configurationPerCloudProvider:
//          gcp:
//            terraformPath: /terraform/gcp/identity
//            variablesValuesFileOverride: |
//              project_id  = "{{ $sys.deploymentCell.gcp.projectID }}"
//              region      = "{{ $sys.deploymentCell.region }}"
//              instance_id = "{{ $sys.id }}"
//              namespace   = "{{ $sys.deployment.resourceKubernetesNamespace }}"
//              ksa_names   = ["{{ $sys.deployment.kubernetesServiceAccountName }}", "ai-worker", "default"]
//              bucket_name = "{{ $storageInfra.out.bucket_name }}"
//            gitConfiguration:
//              reference: refs/tags/vX.Y.Z
//              repositoryUrl: https://github.com/<org>/omnistrate-platform-demo.git
//            requiredOutputs:
//              - key: workload_identity_ref
//                exported: false
//
//  OUTPUT CONTRACT (byte-identical across clouds)
//    workload_identity_ref
//
// =============================================================================

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  // Service account ids: 6-30 chars, ^[a-z]([-a-z0-9]*[a-z0-9])$. The "dai-"
  // prefix guarantees the leading letter and the 6-char floor; trim guarantees
  // the trailing alphanumeric after truncation.
  id_lower = lower(var.instance_id)
  id_clean = replace(local.id_lower, "/[^a-z0-9]+/", "-")
  sa_raw   = "dai-${local.id_clean}"
  sa_id    = trim(substr(local.sa_raw, 0, min(30, length(local.sa_raw))), "-")

  // GKE Workload Identity pool for the project. Fixed form, not configurable.
  workload_pool = "${var.project_id}.svc.id.goog"

  ksa_members = {
    for ksa in var.ksa_names :
    ksa => "serviceAccount:${local.workload_pool}[${var.namespace}/${ksa}]"
  }
}

// -----------------------------------------------------------------------------
// The Google service account the pods act as.
//
// create_ignore_already_exists handles the one genuinely ugly GCP behaviour
// here: a deleted service account is soft-deleted and its id stays reserved for
// 30 days. If an instance is torn down and an id-shaped collision ever occurs,
// this turns a hard 409 into an adopt.
// -----------------------------------------------------------------------------
resource "google_service_account" "workload" {
  account_id   = local.sa_id
  project      = var.project_id
  display_name = var.sa_display_name
  description  = "Workload identity for Durable AI Platform instance ${var.instance_id}"

  create_ignore_already_exists = true
}

// -----------------------------------------------------------------------------
// GKE Workload Identity: let the instance's KSA(s) impersonate the GSA.
// -----------------------------------------------------------------------------
resource "google_service_account_iam_member" "workload_identity" {
  for_each = local.ksa_members

  service_account_id = google_service_account.workload.name
  role               = "roles/iam.workloadIdentityUser"
  member             = each.value
}

// -----------------------------------------------------------------------------
// Bucket access. Bucket-scoped, additive (`_iam_member`, never `_iam_binding`
// or `_iam_policy`, those are authoritative and would wipe the bucket's other
// bindings, including the ones GCS itself relies on).
// -----------------------------------------------------------------------------
resource "google_storage_bucket_iam_member" "workload" {
  for_each = var.bucket_name == "" ? toset([]) : toset(var.bucket_roles)

  bucket = var.bucket_name
  role   = each.value
  member = google_service_account.workload.member
}

// -----------------------------------------------------------------------------
// Cloud SQL. Project-scoped because Cloud SQL exposes no instance-level IAM
// resource; additive for the same reason as above.
// -----------------------------------------------------------------------------
resource "google_project_iam_member" "cloudsql_client" {
  count = var.grant_cloudsql_client ? 1 : 0

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.workload.member
}
