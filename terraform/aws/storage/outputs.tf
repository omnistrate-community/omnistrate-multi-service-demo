# ---------------------------------------------------------------------------
# CROSS-CLOUD OUTPUT CONTRACT
#
# These key names are byte-identical in terraform/gcp/storage and
# terraform/azure/storage. Consumers reference them as
# {{ $storageInfra.out.<key> }} and never branch on cloud provider.
# Adding a key here obliges the GCP and Azure stacks to add it too.
# ---------------------------------------------------------------------------

output "bucket_uri" {
  description = "Scheme-qualified bucket root. AWS emits s3://, GCP emits gs://, Azure emits az://, all three are in vLLM's RunAI streamer SUPPORTED_SCHEMES, which is why one key works everywhere. Append /warehouse for Iceberg and /models for vLLM weights."
  value       = "s3://${aws_s3_bucket.this.bucket}"
}

output "bucket_name" {
  description = "Bare bucket name, no scheme. Feed to terraform/aws/identity as bucket_name."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_region" {
  description = "Region the bucket lives in. Trino's fs.native-s3 and the RunAI streamer both need it explicitly."
  value       = aws_s3_bucket.this.bucket_region
}

output "kms_key_id" {
  description = "Encryption key for the bucket. On AWS this is the CMK ARN, every AWS API that takes a KeyId also accepts the ARN, so the contract key stays honest. Feed to terraform/aws/identity as kms_key_id."
  value       = aws_kms_key.this.arn
}
