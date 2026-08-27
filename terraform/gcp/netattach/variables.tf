// -----------------------------------------------------------------------------
// netAttach (GCP), inputs
//
// Every default is an Omnistrate template string. Omnistrate substitutes the
// `{{ ... }}` text in-place BEFORE OpenTofu ever parses the file, so these
// defaults are simultaneously (a) valid HCL for local `tofu validate` and
// (b) the live wiring at deploy time. Anything you want to override per-cloud
// can also be pushed in from the plan spec via `variablesValuesFileOverride`.
// -----------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project that owns the deployment cell's VPC."
  type        = string
  default     = "{{ $sys.deploymentCell.gcp.projectID }}"
}

variable "region" {
  description = "Deployment cell region, e.g. us-central1."
  type        = string
  default     = "{{ $sys.deploymentCell.region }}"
}

variable "network" {
  description = <<-EOT
    The deployment cell's EXISTING VPC. Accepts either a bare network name
    ("my-vpc"), a partial URL ("projects/p/global/networks/my-vpc") or a full
    self_link, main.tf normalises all three. We attach to this network; we
    never create one.
  EOT
  type        = string
  default     = "{{ $sys.deploymentCell.cloudProviderNetworkID }}"
}

variable "instance_id" {
  description = "Omnistrate instance id. Present in every globally-scoped name."
  type        = string
  default     = "{{ $sys.id }}"
}

variable "manage_psa_connection" {
  description = <<-EOT
    Whether THIS instance owns the Private Service Access (PSA) peering to
    servicenetworking.googleapis.com on the cell VPC.

    OPERATIONAL HAZARD: `google_service_networking_connection` is effectively a
    singleton per (network, service) pair. Omnistrate packs many instances of
    many plans into ONE deployment cell, and therefore one VPC. The first
    instance in a cell must create the connection; every later instance in the
    SAME cell must NOT (it would PATCH the shared connection and drop the
    earlier instances' reserved ranges).

    Defaults to true because `update_on_creation_fail = true` makes the common
    case converge. If you are intentionally stacking several platform instances
    in one cell, set this false on instances 2..n via
    `variablesValuesFileOverride` and leave `existing_psa_range_name` empty, Cloud SQL will then pick any free range inside the shared connection.
  EOT
  type        = bool
  default     = true
}

variable "existing_psa_range_name" {
  description = <<-EOT
    Name of a pre-existing PSA allocated range to hand downstream when
    `manage_psa_connection = false`. Empty is a valid and safe value: Cloud SQL
    omits `allocated_ip_range` and GCP picks a free range from the connection.
  EOT
  type        = string
  default     = ""
}

variable "psa_prefix_length" {
  description = <<-EOT
    Size of the address block reserved for Google-managed services (Cloud SQL
    private IP). /20 = 4096 addresses, comfortably more than the handful of
    Cloud SQL instances a cell will hold. Google requires /24 or larger.
  EOT
  type        = number
  default     = 20

  validation {
    condition     = var.psa_prefix_length >= 16 && var.psa_prefix_length <= 24
    error_message = "psa_prefix_length must be between 16 and 24."
  }
}

variable "allowed_source_ranges" {
  description = <<-EOT
    Ingress sources permitted to reach the platform's in-cluster ports.
    Defaults to RFC1918 rather than `{{ $sys.deploymentCell.cidrRange }}`
    by design: cidrRange is not among the documented $sys parameters, and an
    unresolved template string would be rejected by the Compute API as an
    invalid CIDR. Narrow it from the plan spec once you have confirmed the
    parameter resolves in your account.
  EOT
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

variable "internal_tcp_ports" {
  description = <<-EOT
    TCP ports opened between cell-internal sources. GKE already installs
    allow-all-internal rules for its own pod/node CIDRs; this rule is the
    explicit, auditable statement of what the platform actually needs and
    covers cross-subnet or shared-VPC topologies where those defaults are
    narrower.

      7233-7239  Temporal frontend / history / matching / worker / internal
      8080       Temporal Web UI, Trino coordinator
      8000       vllm-stack router
      8001       vllm-stack serving engine
      9042       Cassandra CQL (Plan 1)
      5432       PostgreSQL
      9090       Prometheus scrape targets
  EOT
  type        = list(string)
  default     = ["5432", "7233-7239", "8000-8001", "8080", "9042", "9090"]
}

variable "private_service_access_cidrs" {
  description = <<-EOT
    Egress destinations for managed-database traffic when this instance does
    not own the PSA connection (`manage_psa_connection = false`). Ignored
    otherwise, the reserved range's real CIDR is used instead.
  EOT
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

variable "labels" {
  description = "Labels applied to labelable resources in this stack."
  type        = map(string)
  default     = {}
}
