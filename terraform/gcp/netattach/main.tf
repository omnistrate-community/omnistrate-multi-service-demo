// =============================================================================
//  Durable AI Platform, Plan 2 resource `netAttach`  ::  GCP
// =============================================================================
//
//  WHAT THIS STACK DOES
//    Attaches the instance to the deployment cell's EXISTING VPC and makes that
//    VPC able to host a private-IP Cloud SQL instance:
//
//      1. google_compute_global_address        reserve a /20 for Google-managed
//                                              services (Private Service Access)
//      2. google_service_networking_connection peer the VPC with the
//                                              servicenetworking producer VPC
//      3. google_compute_firewall x2           ingress for the platform's ports,
//                                              egress to the managed-DB range
//
//    It does NOT create a network. Omnistrate hands us the cell's VPC in
//    `$sys.deploymentCell.cloudProviderNetworkID`; we attach to it.
//
//  SENTINELS THAT MUST BE REPLACED BEFORE USE
//    (none, every value is derived from $sys parameters or has a working
//    default. The Git tag in the plan spec's `gitConfiguration.reference` is
//    the only operator-supplied value, and it lives in the plan, not here.)
//
//  OMNISTRATE WIRING (plan spec, plan2-temporal-ai-platform.yaml)
//    - name: netAttach
//      internal: true
//      terraformConfigurations:
//        configurationPerCloudProvider:
//          gcp:
//            terraformPath: /terraform/gcp/netattach
//            variablesValuesFileOverride: |
//              project_id  = "{{ $sys.deploymentCell.gcp.projectID }}"
//              region      = "{{ $sys.deploymentCell.region }}"
//              network     = "{{ $sys.deploymentCell.cloudProviderNetworkID }}"
//              instance_id = "{{ $sys.id }}"
//            gitConfiguration:
//              reference: refs/tags/vX.Y.Z      # never refs/heads/main
//              repositoryUrl: https://github.com/<org>/omnistrate-platform-demo.git
//            requiredOutputs:
//              - key: db_subnet_group_name
//                exported: false
//              - key: db_security_group_id
//                exported: false
//
//  OUTPUT CONTRACT (byte-identical key names across aws/ gcp/ azure/)
//    db_security_group_id, db_subnet_group_name
//
// =============================================================================

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  // GCP compute resource names: ^[a-z]([-a-z0-9]*[a-z0-9])?$, <= 63 chars.
  // Omnistrate instance ids look like `instance-abc123xyz`; sanitise anyway so
  // a future id format cannot produce an illegal name.
  id_lower = lower(var.instance_id)
  id_clean = replace(local.id_lower, "/[^a-z0-9]+/", "-")
  id_slug  = trim(substr(local.id_clean, 0, min(40, length(local.id_clean))), "-")
  prefix   = "dai-${local.id_slug}"

  // `cloudProviderNetworkID` may arrive as a bare name, a partial URL or a full
  // self_link. Cloud SQL and Service Networking both want a partial URL or
  // self_link, so normalise here instead of guessing.
  network_self_link = can(regex("^(https://|projects/)", var.network)) ? var.network : "projects/${var.project_id}/global/networks/${var.network}"

  // Real CIDR of the reserved PSA block once it exists, else the caller-supplied
  // fallback. Never an empty list, an empty destination_ranges is rejected.
  db_destination_ranges = var.manage_psa_connection ? ["${google_compute_global_address.psa[0].address}/${var.psa_prefix_length}"] : var.private_service_access_cidrs
}

// -----------------------------------------------------------------------------
// 1. Private Service Access, the address block Google carves the managed
//    Cloud SQL instance out of. `address` is intentionally omitted so GCP
//    auto-allocates a free block instead of us colliding with the cell's
//    node/pod/service ranges.
// -----------------------------------------------------------------------------
resource "google_compute_global_address" "psa" {
  count = var.manage_psa_connection ? 1 : 0

  name          = "${local.prefix}-psa"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.psa_prefix_length
  network       = local.network_self_link
  description   = "Private Service Access range for Durable AI Platform instance ${var.instance_id}"
  labels        = var.labels
}

// -----------------------------------------------------------------------------
// 2. The peering itself.
//
//    deletion_policy = "ABANDON" is load-bearing, not cosmetic. Tearing down a
//    service networking connection while a Cloud SQL instance is still being
//    deleted fails, leaves the peering half-removed, and then blocks the NEXT
//    `tofu apply` on the same VPC. ABANDON drops it from state and leaves the
//    peering intact, which is the correct behaviour for a shared cell VPC that
//    outlives any single instance anyway.
//    (Verified against provider 6.50 schema: the attribute is `deletion_policy`
//    and the documented value is "ABANDON"; "REMOVE_PEERING" belongs to
//    google_compute_network_peering_routes_config, not to this resource.)
//
//    update_on_creation_fail = true turns "a connection already exists on this
//    network" from a hard failure into a PATCH, which is what makes a second
//    instance landing in the same cell converge.
// -----------------------------------------------------------------------------
resource "google_service_networking_connection" "psa" {
  count = var.manage_psa_connection ? 1 : 0

  network                 = local.network_self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa[0].name]

  deletion_policy         = "ABANDON"
  update_on_creation_fail = true
}

// -----------------------------------------------------------------------------
// 3a. Ingress for the platform's in-cluster ports.
//
//     No target_tags: GKE node pools created by Omnistrate carry cluster-managed
//     tags we do not control, so tag-targeting would silently match nothing.
//     Scoping is done by source range instead.
// -----------------------------------------------------------------------------
resource "google_compute_firewall" "internal" {
  name        = "${local.prefix}-allow-internal"
  project     = var.project_id
  network     = local.network_self_link
  description = "Durable AI Platform ${var.instance_id}: cell-internal service ports"

  direction     = "INGRESS"
  priority      = 1000
  source_ranges = var.allowed_source_ranges

  allow {
    protocol = "tcp"
    ports    = var.internal_tcp_ports
  }
}

// -----------------------------------------------------------------------------
// 3b. Egress to the managed-database range.
//
//     GCP's implied egress rule is already allow-all, so this rule changes
//     nothing by itself. It exists so that (a) the path Temporal's visibility
//     store depends on is declared rather than assumed, and (b) a customer who
//     has added a deny-all egress rule at a higher priority number still gets a
//     working platform. Its id is what we publish as `db_security_group_id`.
// -----------------------------------------------------------------------------
resource "google_compute_firewall" "db_access" {
  name        = "${local.prefix}-allow-db-egress"
  project     = var.project_id
  network     = local.network_self_link
  description = "Durable AI Platform ${var.instance_id}: egress to Cloud SQL private IP"

  direction          = "EGRESS"
  priority           = 900
  destination_ranges = local.db_destination_ranges

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
}
