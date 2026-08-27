# ==============================================================================
# Durable AI Platform / Azure / storageInfra / outputs
#
# OUTPUT KEY NAMES ARE BYTE-IDENTICAL ACROSS terraform/aws, terraform/gcp AND
# terraform/azure.
# ==============================================================================

# --- Cross-cloud contract keys -------------------------------------------------

output "bucket_uri" {
  description = <<-EOT
    Object-store URI of the primary container, in the scheme vLLM's RunAI model
    streamer understands. vLLM's SUPPORTED_SCHEMES is exactly
    ["s3://", "gs://", "az://"], so this key is `s3://<bucket>` on AWS,
    `gs://<bucket>` on GCP and `az://<container>` here. The account name is not
    part of an az:// URI, the streamer reads it from AZURE_STORAGE_ACCOUNT, which
    is why `storage_account_name` is also exported.
    Trino's native Azure filesystem uses a DIFFERENT form; see bucket_uri_abfss.
  EOT
  value       = "az://${azurerm_storage_container.warehouse.name}"
}

output "bucket_name" {
  description = "AWS analogue: the S3 bucket name. On Azure the addressable namespace is the CONTAINER (the account is the credential boundary), so the container name is emitted under the shared key. Medusa's `bucket_name` setting takes this value too."
  value       = azurerm_storage_container.warehouse.name
}

output "bucket_region" {
  description = "Azure location the storage account lives in."
  value       = azurerm_storage_account.main.location
}

output "kms_key_id" {
  description = "AWS analogue: aws_kms_key.id. The Key Vault key's VERSIONLESS ID, the stable identifier that survives key rotation, which is the semantic a KMS key ID carries."
  value       = azurerm_key_vault_key.main.versionless_id
}

# --- Azure Medusa credentials (the honest asymmetry) ---------------------------

output "medusa_storage_account" {
  description = "Storage account name for Cassandra/Medusa on Azure. Medusa's azure_blobs backend reads it from AZURE_STORAGE_ACCOUNT and cannot use workload identity, so it must be handed over explicitly."
  value       = azurerm_storage_account.main.name
}

output "medusa_storage_key" {
  description = "Long-lived primary access key for the storage account. AZURE-ONLY, and the one place this design is not keyless: Medusa on Azure authenticates with a shared key held in a Kubernetes Secret (medusa.storageProperties.storageSecretRef.name). AWS uses IRSA and GCP uses Workload Identity with no secret at all."
  value       = azurerm_storage_account.main.primary_access_key
  sensitive   = true
}

output "medusa_container" {
  description = "AZURE-ONLY. Container reserved for Medusa backups, kept separate from the Iceberg warehouse."
  value       = azurerm_storage_container.medusa.name
}

# --- Azure-only wiring keys ----------------------------------------------------

output "bucket_uri_abfss" {
  description = "AZURE-ONLY. abfss:// form of the primary container, which is what Trino's `fs.native-azure.enabled` filesystem and the Iceberg warehouse location require. On AWS/GCP the single bucket_uri serves both consumers; on Azure the vLLM scheme (az://) and the Hadoop/Trino scheme (abfss://) genuinely differ, so both are published rather than pretending one form works everywhere."
  value       = "abfss://${azurerm_storage_container.warehouse.name}@${azurerm_storage_account.main.name}.dfs.core.windows.net"
}

output "storage_account_name" {
  description = "AZURE-ONLY. Storage account name (sanitised from instance_id: lowercase alphanumeric, <= 24 chars). Set as AZURE_STORAGE_ACCOUNT for vLLM's runai streamer."
  value       = azurerm_storage_account.main.name
}

output "storage_account_id" {
  description = "AZURE-ONLY. ARM resource ID of the storage account. Feeds the Storage Blob Data Contributor role assignment scope in the identity stack."
  value       = azurerm_storage_account.main.id
}

output "bucket_endpoint" {
  description = "AZURE-ONLY. Primary blob service endpoint, e.g. https://<account>.blob.core.windows.net/."
  value       = azurerm_storage_account.main.primary_blob_endpoint
}

output "bucket_dfs_endpoint" {
  description = "AZURE-ONLY. Primary ADLS Gen2 (DFS) endpoint."
  value       = azurerm_storage_account.main.primary_dfs_endpoint
}

output "key_vault_id" {
  description = "AZURE-ONLY. ARM resource ID of the Key Vault. Feeds the Key Vault Crypto User role assignment scope in the identity stack."
  value       = azurerm_key_vault.main.id
}

output "key_vault_uri" {
  description = "AZURE-ONLY. Data-plane URI of the Key Vault."
  value       = azurerm_key_vault.main.vault_uri
}

output "key_vault_name" {
  description = "AZURE-ONLY. Key Vault name."
  value       = azurerm_key_vault.main.name
}
