// -----------------------------------------------------------------------------
// netAttach (GCP), output contract.
//
// These two key names exist because AWS needs them. Keeping them present, with
// the same spelling, on GCP and Azure is the single decision that lets the Helm
// layer and the plan spec reference `{{ $netAttach.out.<key> }}` with no
// per-cloud branching. Emit exactly these; no extras.
// -----------------------------------------------------------------------------

output "db_security_group_id" {
  description = <<-EOT
    GCP has no security group. The closest analogue is a VPC firewall rule:
    network-scoped rather than attachable to an instance, so nothing downstream
    can "assign" it the way `visibilitydb` on AWS assigns an aws_security_group
    to aws_db_instance. We publish the rule's fully-qualified id so the key
    exists, resolves to something real and greppable in the customer's project,
    and keeps the plan spec identical across clouds.

    On GCP this value is informational: Cloud SQL private-IP reachability is
    established by the Private Service Access peering above, not by this rule.
  EOT
  value       = google_compute_firewall.db_access.id
}

output "db_subnet_group_name" {
  description = <<-EOT
    GCP has no DB subnet group. The functional equivalent for a private-IP
    Cloud SQL instance is the *allocated IP range* of the Private Service
    Access peering, it is exactly what decides which addresses the managed
    instance is carved out of, and Cloud SQL consumes it by name via
    `settings.ip_configuration.allocated_ip_range`. So this key is not a
    placeholder here; visibilitydb genuinely reads it.

    Empty string is a valid value (see `manage_psa_connection`): visibilitydb
    then omits allocated_ip_range and GCP picks any free range in the
    connection.
  EOT
  value       = var.manage_psa_connection ? google_compute_global_address.psa[0].name : var.existing_psa_range_name
}
