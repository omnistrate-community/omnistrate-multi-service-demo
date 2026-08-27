// -----------------------------------------------------------------------------
// storageInfra (GCP), output contract.
// Exactly four keys, spelled identically on aws/ and azure/.
// -----------------------------------------------------------------------------

output "bucket_uri" {
  description = <<-EOT
    Scheme-qualified bucket root. This is the value the Helm layer actually
    consumes with no branching:
      * vLLM   `modelURL: {{ $storageInfra.out.bucket_uri }}/models/Qwen3.5-4B`
               with `--load-format runai_streamer` (RunAI streamer's
               SUPPORTED_SCHEMES covers s3://, gs:// and az://)
      * Trino  `iceberg.warehouse={{ $storageInfra.out.bucket_uri }}/warehouse`
    Only the scheme differs per cloud, which is precisely why the *key* must not.
  EOT
  value       = "gs://${google_storage_bucket.this.name}"
}

output "bucket_name" {
  description = "Bare bucket name, for IAM bindings and for clients that take a name rather than a URI."
  value       = google_storage_bucket.this.name
}

output "bucket_region" {
  description = <<-EOT
    Bucket location, lowercased. GCS reports `location` upper-cased
    ("US-CENTRAL1"); every client that wants a region wants it lowercase, and
    the AWS module emits a lowercase region, so normalise here rather than
    forcing the consumer to know which cloud it is on.
  EOT
  value       = lower(google_storage_bucket.this.location)
}

output "kms_key_id" {
  description = <<-EOT
    Fully-qualified crypto key resource id
    (projects/P/locations/L/keyRings/R/cryptoKeys/K). GCP's analogue of a KMS
    key ARN: the string every GCP API accepts to identify the key.
  EOT
  value       = google_kms_crypto_key.this.id
}
