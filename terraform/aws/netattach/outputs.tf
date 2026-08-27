# ---------------------------------------------------------------------------
# CROSS-CLOUD OUTPUT CONTRACT
#
# These key names are byte-identical in terraform/gcp/netattach and
# terraform/azure/netattach. Consumers reference them as
# {{ $netAttach.out.<key> }} and never branch on cloud provider.
# Adding a key here obliges the GCP and Azure stacks to add it too.
# ---------------------------------------------------------------------------

output "db_security_group_id" {
  description = "Security group that admits PostgreSQL from the deployment cell. Feed to terraform/aws/visibilitydb as db_security_group_id."
  value       = aws_security_group.db.id
}

output "db_subnet_group_name" {
  description = "RDS DB subnet group spanning the cell's private subnets. Feed to terraform/aws/visibilitydb as db_subnet_group_name."
  value       = aws_db_subnet_group.this.name
}
