// -----------------------------------------------------------------------------
// visibilityDb (GCP), output contract.
// Exactly seven keys, spelled identically on aws/ and azure/.
// -----------------------------------------------------------------------------

output "pg_endpoint" {
  description = <<-EOT
    "host:port". This exact shape is mandatory, not stylistic: Temporal's SQL
    plugin config takes `connectAddr`, whose Go struct field is
    `ConnectAddr string \`validate:"nonzero"\``, there is no host/port pair to
    fall back on, despite what the chart's values file advertises.

    Consumed as:
      server.config.persistence.datastores.visibility.sql.connectAddr:
        "{{ $visibilityDb.out.pg_endpoint }}"
  EOT
  value       = "${google_sql_database_instance.this.private_ip_address}:${local.pg_port}"
}

output "pg_host" {
  description = <<-EOT
    Private IP of the Cloud SQL instance, no port. Cloud SQL private-IP
    instances have no stable DNS name in the customer VPC by default, so the
    allocated address is the address. It is stable for the life of the instance.
  EOT
  value       = google_sql_database_instance.this.private_ip_address
}

output "pg_port" {
  description = <<-EOT
    Emitted as a number rather than a string. Everything under Temporal's
    `persistence.*` reaches the server through `toYaml` with quoting preserved,
    and a quoted port ("5432") kills the server with an unmarshal error at
    startup. Keeping the type numeric all the way through removes the chance of
    a stray quote surviving into the rendered ConfigMap.
  EOT
  value       = local.pg_port
}

output "pg_visibility_db" {
  description = "Database name for Temporal's visibility store (`sql.databaseName`)."
  value       = google_sql_database.visibility.name
}

output "pg_iceberg_db" {
  description = "Database name backing Trino's Iceberg JDBC catalog (`iceberg.jdbc-catalog.connection-url`)."
  value       = google_sql_database.iceberg.name
}

output "pg_user" {
  description = "Role that owns both databases. Feeds `sql.user` and the Iceberg catalog's connection-user."
  value       = google_sql_user.app.name
}

output "pg_password" {
  description = <<-EOT
    Password for `pg_user`.

    Marked sensitive so it is redacted from plan/apply logs. Do NOT list this
    key under `requiredOutputs` with `exported: true`: exported values land in
    `result_params` in plaintext and there is no per-entry export flag to stop
    them. It is consumed as `{{ $visibilityDb.out.pg_password }}` in
    temporalServer's chartValues and in trino's layeredChartValues, and chart
    values are not surfaced to the customer.
  EOT
  value       = local.pg_password
  sensitive   = true
}
