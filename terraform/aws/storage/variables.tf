variable "instance_id" {
  description = "Omnistrate instance id ($sys.id). S3 bucket names are globally unique, so this must be part of the name."
  type        = string

  validation {
    condition     = length(trimspace(var.instance_id)) > 0
    error_message = "instance_id must not be empty; wire it to {{ $sys.id }}."
  }
}

variable "region" {
  description = "AWS region of the deployment cell ($sys.deploymentCell.region)."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix for every created resource name. Keep it <= 10 characters."
  type        = string
  default     = "daip"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,9}$", var.name_prefix))
    error_message = "name_prefix must be 2-10 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }
}

variable "bucket_name_override" {
  description = "Explicit bucket name. Leave empty to derive '<name_prefix>-<sanitized instance id>'."
  type        = string
  default     = ""

  validation {
    condition     = var.bucket_name_override == "" || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name_override))
    error_message = "bucket_name_override must be a legal S3 bucket name: 3-63 chars, lowercase, starting and ending alphanumeric."
  }
}

variable "force_destroy" {
  description = "Delete objects when the bucket is destroyed. True by default because Omnistrate runs `terraform destroy` on instance delete and a non-empty bucket would wedge the delete workflow."
  type        = bool
  default     = true
}

variable "versioning_enabled" {
  description = "Enable S3 object versioning on the warehouse bucket. Iceberg tolerates it and it protects the model weights from an accidental overwrite."
  type        = bool
  default     = true
}

variable "noncurrent_version_expiration_days" {
  description = "Days after which a noncurrent object version is deleted. Only meaningful when versioning_enabled is true."
  type        = number
  default     = 30
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Days after which an abandoned multipart upload is aborted. Model-weight uploads are multi-GiB and abort often."
  type        = number
  default     = 7
}

variable "kms_deletion_window_in_days" {
  description = "Waiting period before the CMK is actually deleted (7-30)."
  type        = number
  default     = 7

  validation {
    condition     = var.kms_deletion_window_in_days >= 7 && var.kms_deletion_window_in_days <= 30
    error_message = "kms_deletion_window_in_days must be between 7 and 30."
  }
}

variable "enable_key_rotation" {
  description = "Enable annual automatic rotation of the CMK."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged onto every taggable resource."
  type        = map(string)
  default     = {}
}
