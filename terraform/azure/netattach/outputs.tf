# ==============================================================================
# Durable AI Platform / Azure / netAttach / outputs
#
# OUTPUT KEY NAMES ARE BYTE-IDENTICAL ACROSS terraform/aws, terraform/gcp AND
# terraform/azure. That is the single decision that keeps the Helm layer
# cloud-agnostic: one `{{ $netAttach.out.<key> }}` reference, no branching.
# Where a concept has no Azure analogue the key is still emitted, mapped onto the
# nearest Azure resource, with the reasoning stated inline.
# ==============================================================================

# --- Cross-cloud contract keys -------------------------------------------------

output "db_security_group_id" {
  description = "AWS analogue: aws_security_group.id. Azure has no security groups; the NSG attached to the delegated database subnet plays exactly that role, so its ARM resource ID is emitted under the shared key."
  value       = azurerm_network_security_group.db.id
}

output "db_subnet_group_name" {
  description = "AWS analogue: aws_db_subnet_group.name. Azure PostgreSQL Flexible Server takes a single delegated SUBNET rather than a group of subnets, so the delegated subnet's name is emitted under the shared key."
  value       = azurerm_subnet.db.name
}

# --- Azure-only wiring keys ----------------------------------------------------
# These are consumed only by the Azure branch of `variablesValuesFileOverride`
# for the visibilityDb stack, which is already per-cloud. They are additive and
# never referenced from cloud-agnostic Helm chartValues.

output "db_subnet_id" {
  description = "AZURE-ONLY. ARM resource ID of the delegated subnet. Feeds azurerm_postgresql_flexible_server.delegated_subnet_id in the visibilitydb stack."
  value       = azurerm_subnet.db.id
}

output "db_subnet_cidr" {
  description = "AZURE-ONLY. CIDR actually allocated to the delegated subnet (auto-carved from the top of the VNet range unless overridden)."
  value       = local.db_subnet_cidr
}

output "private_dns_zone_id" {
  description = "AZURE-ONLY. ARM resource ID of the privatelink DNS zone. Feeds azurerm_postgresql_flexible_server.private_dns_zone_id in the visibilitydb stack."
  value       = azurerm_private_dns_zone.pg.id
}

output "private_dns_zone_name" {
  description = "AZURE-ONLY. Name of the privatelink DNS zone."
  value       = azurerm_private_dns_zone.pg.name
}

output "resource_group_name" {
  description = "AZURE-ONLY. Resource group every stack in this plan places resources into (derived from the cell VNet's ARM ID). Feed it to the storage / visibilitydb / identity stacks so all four agree."
  value       = local.resource_group_name
}

output "vnet_id" {
  description = "AZURE-ONLY. ARM resource ID of the cell VNet this instance attached to (echoed back canonically from the data source)."
  value       = data.azurerm_virtual_network.cell.id
}

output "vnet_name" {
  description = "AZURE-ONLY. Name of the cell VNet."
  value       = data.azurerm_virtual_network.cell.name
}

output "region" {
  description = "AZURE-ONLY. Azure location the networking was created in."
  value       = var.region
}
