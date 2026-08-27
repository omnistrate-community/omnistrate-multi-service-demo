# ==============================================================================
# Durable AI Platform / Azure / visibilityDb / outputs
#
# OUTPUT KEY NAMES ARE BYTE-IDENTICAL ACROSS terraform/aws, terraform/gcp AND
# terraform/azure. Consumers reference them as {{ $visibilityDb.out.<key> }} and
# never branch on cloud provider.
# ==============================================================================

output "pg_endpoint" {
  description = <<-EOT
    "host:port". This exact shape is mandatory, not stylistic: Temporal's SQL
    plugin config takes `connectAddr`, whose Go struct field is
    `ConnectAddr string \`validate:"nonzero"\``, there is no host/port pair to
    fall back on, despite what the chart's values file advertises.

    The host half is the Flexible Server FQDN
    (<server>.postgres.database.azure.com). Because the server is VNet-integrated
    and private_dns_zone_id points at a zone already linked to the cell VNet,
    that name resolves to the private address from inside the cell and nowhere
    else.

    Consumed as:
      server.config.persistence.datastores.visibility.sql.connectAddr:
        "{{ $visibilityDb.out.pg_endpoint }}"
  EOT
  value       = "${azurerm_postgresql_flexible_server.main.fqdn}:${var.pg_port}"
}

output "pg_host" {
  description = <<-EOT
    Flexible Server FQDN, no port. Azure publishes no stable private IP for a
    VNet-integrated server, the address is an implementation detail of the
    delegated subnet, so the DNS name is the only durable handle.
  EOT
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "pg_port" {
  description = <<-EOT
    Emitted as a number rather than a string. Everything under Temporal's
    `persistence.*` reaches the server through `toYaml` with quoting preserved,
    and a quoted port ("5432") kills the server with an unmarshal error at
    startup. Keeping the type numeric all the way through removes the chance of
    a stray quote surviving into the rendered ConfigMap.

    Azure Flexible Server is always 5432 and the port is not configurable, so
    this is var.pg_port rather than an attribute of the server resource.
  EOT
  value       = var.pg_port
}

output "pg_visibility_db" {
  description = "Database name for Temporal's visibility store (`sql.databaseName`). The chart's DATASTORE key must be exactly `visibility`; this is the database that datastore connects to."
  value       = azurerm_postgresql_flexible_server_database.visibility.name
}

output "pg_iceberg_db" {
  description = "Database name backing Trino's Iceberg JDBC catalog (`iceberg.jdbc-catalog.connection-url`). Second database on the same server, which is what lets the design skip an entire REST-catalog tier."
  value       = azurerm_postgresql_flexible_server_database.iceberg.name
}

output "pg_user" {
  description = <<-EOT
    Role that owns both databases. Feeds `sql.user` and the Iceberg catalog's
    connection-user.

    On Azure this is also the Flexible Server administrator login, see the
    ownership note in main.tf. Unlike the retired Single Server, Flexible Server
    logins carry NO `@servername` suffix, so this value is used verbatim in
    every connection string.
  EOT
  value       = azurerm_postgresql_flexible_server.main.administrator_login
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

    Echoed straight back from the input: unlike AWS and GCP, this stack does not
    generate a password, because Azure's administrator password is set at server
    creation and the plan already collects it as `{{ $var.visibilityPassword }}`.
  EOT
  value       = var.pg_password
  sensitive   = true
}
