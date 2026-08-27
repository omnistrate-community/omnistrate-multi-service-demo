# ---------------------------------------------------------------------------
# CROSS-CLOUD OUTPUT CONTRACT
#
# These seven key names are byte-identical in terraform/gcp/visibilitydb and
# terraform/azure/visibilitydb. Consumers reference them as
# {{ $visibilityDb.out.<key> }} and never branch on cloud provider.
# Adding a key here obliges the GCP and Azure stacks to add it too.
# ---------------------------------------------------------------------------

output "pg_endpoint" {
  description = <<-EOT
    "host:port". This exact shape is mandatory, not stylistic: Temporal's SQL
    plugin config takes `connectAddr`, whose Go struct field is
    `ConnectAddr string \`validate:"nonzero"\``, there is no host/port pair to
    fall back on, despite what the chart's values file advertises.

    Built from address + port rather than aws_db_instance.endpoint so the shape
    is guaranteed by this file and not by an AWS attribute whose format could
    change. The two are equal today.

    Consumed as:
      server.config.persistence.datastores.visibility.sql.connectAddr:
        "{{ $visibilityDb.out.pg_endpoint }}"
  EOT
  value       = "${aws_db_instance.this.address}:${aws_db_instance.this.port}"
}

output "pg_host" {
  description = <<-EOT
    RDS DNS name, no port, e.g. daip-<slug>.abcdefgh.us-east-1.rds.amazonaws.com.
    A name, not an address: RDS re-points it on failover and on any
    modify-with-replacement, so nothing downstream should ever resolve it once
    and cache the result.
  EOT
  value       = aws_db_instance.this.address
}

output "pg_port" {
  description = <<-EOT
    Emitted as a number rather than a string. Everything under Temporal's
    `persistence.*` reaches the server through `toYaml` with quoting preserved,
    and a quoted port ("5432") kills the server with an unmarshal error at
    startup. Keeping the type numeric all the way through removes the chance of
    a stray quote surviving into the rendered ConfigMap.
  EOT
  value       = aws_db_instance.this.port
}

output "pg_visibility_db" {
  description = <<-EOT
    Database name for Temporal's visibility store (`sql.databaseName`).

    Read back off the instance rather than from var.pg_visibility_db because on
    AWS this database is the RDS *initial* database, created by RDS itself and
    therefore owned by the master role, which is precisely what makes
    `CREATE EXTENSION btree_gin` succeed for a non-superuser.
  EOT
  value       = aws_db_instance.this.db_name
}

output "pg_iceberg_db" {
  description = <<-EOT
    Database name backing Trino's Iceberg JDBC catalog
    (`iceberg.jdbc-catalog.connection-url`).

    When manage_pg_objects = false this stack does not create the database, but
    the key must still exist and still resolve, the plan spec lists it under
    requiredOutputs and an absent output fails the whole apply. The declared
    name is emitted in that case; creating it becomes a manual step.
  EOT
  value       = length(postgresql_database.iceberg) > 0 ? postgresql_database.iceberg[0].name : var.pg_iceberg_db
}

output "pg_user" {
  description = <<-EOT
    Role that owns both databases. Feeds `sql.user` and the Iceberg catalog's
    connection-user. On RDS this is the master user, which holds rds_superuser, not a true superuser, but it owns the initial database, and ownership is
    the privilege Temporal's schema tool actually requires.
  EOT
  value       = aws_db_instance.this.username
}

output "pg_password" {
  description = <<-EOT
    Password for `pg_user`.

    Marked sensitive so it is redacted from plan/apply logs. Do NOT list this
    key under `requiredOutputs` with `exported: true`: exported values land in
    `result_params` in plaintext and there is no per-entry export flag to stop
    them. It is consumed only as `{{ $visibilityDb.out.pg_password }}` inside
    chartValues on an `internal: true` resource, which never surfaces to the
    customer.
  EOT
  value       = local.pg_password
  sensitive   = true
}
