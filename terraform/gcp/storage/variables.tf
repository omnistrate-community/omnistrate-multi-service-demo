// -----------------------------------------------------------------------------
// storageInfra (GCP), inputs
//
// Plain portable Terraform. The variables with no default are supplied by the
// plan spec through `variablesValuesFileOverride`.
// -----------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project that owns the bucket and the KMS key ring. Wired from `$sys.deploymentCell.gcp.projectID`."
  type        = string
}

variable "region" {
  description = <<-EOT
    Deployment cell region, from `$sys.deploymentCell.region`. Used for BOTH the
    bucket location and the KMS key ring location, CMEK requires the key and the
    bucket to live in the same location, and a regional bucket with a
    multi-region key is rejected at create time.
  EOT
  type        = string
}

variable "instance_id" {
  description = "Omnistrate instance id, from `$sys.id`. Part of the globally-unique bucket name."
  type        = string
}

variable "storage_class" {
  description = "Bucket storage class. STANDARD is correct for model weights that are read on every pod cold start."
  type        = string
  default     = "STANDARD"
}

variable "force_destroy" {
  description = <<-EOT
    true so that deleting the Omnistrate instance actually succeeds. A bucket
    holding Iceberg data files and an 8.7 GiB model checkpoint will never be
    empty at destroy time, and `tofu destroy` on a non-empty bucket fails,
    which strands the instance in a DELETING state. Flip to false only for a
    long-lived environment where you accept manual cleanup.
  EOT
  type        = bool
  default     = true
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep noncurrent object versions before the lifecycle rule deletes them."
  type        = number
  default     = 14
}

variable "abort_incomplete_upload_days" {
  description = "Days before an abandoned resumable/multipart upload is reaped."
  type        = number
  default     = 7
}

variable "kms_rotation_period" {
  description = "Crypto key rotation period. 90 days, expressed in seconds as the API requires."
  type        = string
  default     = "7776000s"
}

variable "kms_protection_level" {
  description = "SOFTWARE or HSM. HSM costs more and is not needed for a demo."
  type        = string
  default     = "SOFTWARE"

  validation {
    condition     = contains(["SOFTWARE", "HSM"], var.kms_protection_level)
    error_message = "kms_protection_level must be SOFTWARE or HSM."
  }
}

variable "labels" {
  description = "Labels applied to the bucket and the crypto key."
  type        = map(string)
  default     = {}
}
