# ---------------------------------------------------------------------------
# Durable AI Platform / Plan 2 / identityInfra / AWS / inputs
#
# Plain Terraform: no variable carries an Omnistrate template expression. Every
# value that comes from the platform is supplied by
# variablesValuesFileOverride in the plan spec. Defaults here are ordinary
# Terraform defaults and stay valid outside Omnistrate.
# ---------------------------------------------------------------------------

variable "instance_id" {
  description = "Omnistrate instance id ($sys.id). Part of the role name, which must be unique per account."
  type        = string
}

variable "region" {
  description = "AWS region of the deployment cell ($sys.deploymentCell.region). IAM is global; this only configures the provider."
  type        = string
}

variable "account_id" {
  description = "AWS account the deployment cell runs in ($sys.deploymentCell.aws.accountNumber). Used to build the OIDC provider ARN."
  type        = string
}

variable "oidc_issuer" {
  description = <<-EOT
    The EKS cluster's OIDC issuer, from `$sys.deploymentCell.oidcIssuerID`.

    Accepted in either form, with or without the `https://` scheme, because
    the two places it is needed want different forms: the IAM provider ARN wants
    the bare host+path, while the trust policy's `Condition` keys are prefixed
    with the bare form too. `local.oidc_host` below normalises it.

    Example bare form:
      oidc.eks.us-east-1.amazonaws.com/id/9AEF0C846C22DEAEFDDD1F98C6AB9FEA
  EOT
  type        = string

  validation {
    condition     = length(trimspace(var.oidc_issuer)) > 0
    error_message = "oidc_issuer must be set, without it the trust policy cannot be scoped and the role would be assumable by anything."
  }
}

variable "namespace" {
  description = <<-EOT
    Kubernetes namespace the instance's pods run in
    ($sys.deployment.resourceKubernetesNamespace). Omnistrate gives each
    instance its own namespace, so this is the primary tenancy boundary in the
    trust policy.
  EOT
  type        = string
}

variable "ksa_names" {
  description = <<-EOT
    Kubernetes service accounts inside `namespace` allowed to assume this role.

    Wire to the KSA Omnistrate provisions for the resource
    ($sys.deployment.kubernetesServiceAccountName).

    Open question, shared with the GCP module: whether Omnistrate issues
    ONE KSA per instance namespace or one per resource. If per-resource, the KSAs
    that vllmInference / trino / aiWorkers actually run as are different names
    and this binding will not cover them, producing an opaque
    `WebIdentityErr: AccessDenied` at first S3 call rather than a deploy failure.
    Confirm with `kubectl -n <instance-ns> get serviceaccounts` on a live
    instance and, if there is more than one, list them all from the plan spec.

    Listing a name that does not exist is harmless.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.ksa_names) > 0
    error_message = "ksa_names must contain at least one Kubernetes service account name."
  }
}

variable "name_prefix" {
  description = "Short prefix for created resource names. Keep it <= 10 characters."
  type        = string
  default     = "daip"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,10}$", var.name_prefix))
    error_message = "name_prefix must be 1-10 lowercase alphanumeric or hyphen characters."
  }
}

variable "bucket_name" {
  description = <<-EOT
    Wired from `{{ $storageInfra.out.bucket_name }}`. The bucket the workload
    reads model weights from and writes Iceberg data to.

    Empty skips the S3 statements entirely, which is only useful when applying
    this stack in isolation for a syntax check.
  EOT
  type        = string
  default     = ""
}

variable "kms_key_id" {
  description = <<-EOT
    Wired from `{{ $storageInfra.out.kms_key_id }}`. The CMK the bucket is
    encrypted with.

    Required whenever `bucket_name` is set and the bucket uses SSE-KMS: S3
    returns AccessDenied on GetObject if the caller cannot call kms:Decrypt,
    and that failure looks like a bucket-policy problem rather than a key
    problem. Empty omits the KMS statement.
  EOT
  type        = string
  default     = ""
}

variable "extra_policy_arns" {
  description = "Additional managed-policy ARNs to attach. Left empty by default; present so a demo can add read-only debugging policies without editing this module."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}
