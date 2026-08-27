// =============================================================================
//  Durable AI Platform, Plan 2 resource `storageInfra`  ::  GCP
// =============================================================================
//
//  WHAT THIS STACK DOES
//    One CMEK-encrypted GCS bucket that holds two things:
//      * the Iceberg warehouse Trino writes results into
//      * the vLLM model weights (`gs://<bucket>/models/...`, streamed by the
//        RunAI model streamer, SUPPORTED_SCHEMES includes "gs://")
//    plus the KMS key ring and crypto key that encrypt it.
//
//    Uniform bucket-level access is ON: object ACLs are disabled entirely, so
//    the only way in is IAM. That matters because `identityInfra` grants the
//    workload's service account bucket-scoped IAM roles, and legacy ACLs would
//    silently widen that.
//
//  SENTINELS THAT MUST BE REPLACED BEFORE USE
//    (none)
//
//  OMNISTRATE WIRING
//    - name: storageInfra
//      internal: true
//      dependsOn: [netAttach]
//      terraformConfigurations:
//        configurationPerCloudProvider:
//          gcp:
//            terraformPath: /terraform/gcp/storage
//            gitConfiguration:
//              reference: refs/tags/vX.Y.Z
//              repositoryUrl: https://github.com/<org>/omnistrate-platform-demo.git
//            requiredOutputs:
//              - key: bucket_uri
//                exported: true
//              - key: bucket_name
//                exported: true
//              - key: bucket_region
//                exported: false
//              - key: kms_key_id
//                exported: false
//
//  OUTPUT CONTRACT (byte-identical across clouds)
//    bucket_uri, bucket_name, bucket_region, kms_key_id
//
//  TEARDOWN NOTE
//    Google does not permit deleting a KMS key ring, ever. `tofu destroy`
//    removes it from state and leaves the ring in the project. Because the ring
//    name embeds $sys.id, the next instance gets a fresh name and never
//    collides, but a destroy/re-apply of the SAME instance id would hit
//    "already exists". That path does not occur in Omnistrate (ids are unique
//    per instance) and is called out here so nobody is surprised by the
//    leftover rings in the customer project.
//
// =============================================================================

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  // GCS bucket names are GLOBALLY unique across all of Google Cloud, 3-63 chars,
  // lowercase letters/digits/hyphens/underscores/dots, must start and end
  // alphanumeric. Folding the project id in is what makes collisions with an
  // unrelated Google customer impossible in practice.
  bucket_raw   = lower("dai-${var.instance_id}-${var.project_id}")
  bucket_clean = replace(local.bucket_raw, "/[^a-z0-9-]+/", "-")
  bucket_name  = trim(substr(local.bucket_clean, 0, min(63, length(local.bucket_clean))), "-")

  // KMS names: 1-63 chars, [a-zA-Z0-9_-]. Project-scoped, so no global
  // uniqueness requirement, instance id alone is enough.
  key_raw   = lower("dai-${var.instance_id}")
  key_clean = replace(local.key_raw, "/[^a-z0-9-]+/", "-")
  key_slug  = trim(substr(local.key_clean, 0, min(50, length(local.key_clean))), "-")
}

// -----------------------------------------------------------------------------
// KMS: one key ring per instance, one crypto key inside it.
// -----------------------------------------------------------------------------
resource "google_kms_key_ring" "this" {
  name     = "${local.key_slug}-ring"
  project  = var.project_id
  location = var.region
}

resource "google_kms_crypto_key" "this" {
  name            = "${local.key_slug}-gcs"
  key_ring        = google_kms_key_ring.this.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = var.kms_rotation_period
  labels          = var.labels

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = var.kms_protection_level
  }
}

// -----------------------------------------------------------------------------
// CMEK prerequisite that is easy to miss: the GCS *service agent*
// (service-<projectNumber>@gs-project-accounts.iam.gserviceaccount.com), not the
// workload, is the principal that encrypts and decrypts objects. Without this
// binding the bucket create fails outright with
// "permission denied on Cloud KMS key". The explicit depends_on forces the IAM
// grant to land before the bucket is attempted, IAM propagation is eventually
// consistent, and ordering is the only lever we have.
// -----------------------------------------------------------------------------
data "google_storage_project_service_account" "gcs" {
  project = var.project_id
}

resource "google_kms_crypto_key_iam_member" "gcs_agent" {
  crypto_key_id = google_kms_crypto_key.this.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

// -----------------------------------------------------------------------------
// The bucket.
// -----------------------------------------------------------------------------
resource "google_storage_bucket" "this" {
  name          = local.bucket_name
  project       = var.project_id
  location      = var.region
  storage_class = var.storage_class
  force_destroy = var.force_destroy
  labels        = var.labels

  // No object ACLs. IAM only.
  uniform_bucket_level_access = true

  // Belt and braces on top of UBLA: refuses any allUsers/allAuthenticatedUsers
  // binding even if someone adds one later.
  public_access_prevention = "enforced"

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.this.id
  }

  // Iceberg rewrites manifests constantly; without this the noncurrent versions
  // accumulate forever and the demo bucket quietly becomes the biggest line on
  // the bill.
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      with_state                 = "ARCHIVED"
      days_since_noncurrent_time = var.noncurrent_version_retention_days
    }
  }

  lifecycle_rule {
    action {
      type = "AbortIncompleteMultipartUpload"
    }
    condition {
      age = var.abort_incomplete_upload_days
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_agent]
}
