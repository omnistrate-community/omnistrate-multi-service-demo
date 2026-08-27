# ==============================================================================
# Durable AI Platform / Plan 2 "Temporal AI Platform" / resource: netAttach
# Cloud: AZURE
# ==============================================================================
#
# WHAT THIS STACK DOES
#   Attaches to the deployment cell's EXISTING virtual network. It never creates
#   a VNet. It carves one subnet DELEGATED to
#   `Microsoft.DBforPostgreSQL/flexibleServers`, guards it with an NSG, and
#   creates the private DNS zone + VNet link that PostgreSQL Flexible Server
#   private access requires.
#
#   Azure has no `aws_db_subnet_group` and no `aws_security_group`. The two
#   required cross-cloud output keys are still emitted, mapped onto their
#   closest Azure analogues (see outputs.tf for the per-key rationale):
#       db_subnet_group_name -> the delegated subnet's NAME
#       db_security_group_id -> the NSG's ARM resource ID
#
# NO OPERATOR-SUPPLIED SENTINELS
#   Every value comes from Omnistrate templating. There is no REPLACE_ME in this
#   file. The only thing the demo operator must supply lives in the plan spec:
#   `gitConfiguration.repositoryUrl` and a pinned `reference`.
#
# PLAN-SPEC WIRING (paste into plans/plan2-temporal-ai-platform.yaml)
#
#   - name: netAttach
#     internal: true
#     terraformConfigurations:
#       configurationPerCloudProvider:
#         azure:
#           terraformPath: /terraform/azure/netattach
#           gitConfiguration:
#             reference: refs/tags/v1.0.0          # never refs/heads/main
#             repositoryUrl: <this repo>
#           variablesValuesFileOverride: |
#             instance_id     = "{{ $sys.id }}"
#             region          = "{{ $sys.deploymentCell.region }}"
#             subscription_id = "{{ $sys.deploymentCell.azure.subscriptionID }}"
#             tenant_id       = "{{ $sys.deploymentCell.azure.tenantID }}"
#             vnet_id         = "{{ $sys.deploymentCell.cloudProviderNetworkID }}"
#           requiredOutputs:
#             - key: db_subnet_group_name
#               exported: true
#             - key: db_security_group_id
#               exported: true
#
# ==============================================================================

# The provider block lives in the top-level .tf of THIS stack, one directory
# per cloud, no shared/root modules.
provider "azurerm" {
  features {}

  # Empty string -> null -> fall back to the ARM_* environment variables that the
  # Omnistrate Terraform runner exports for the BYOA service principal.
  subscription_id = var.subscription_id != "" ? var.subscription_id : null
  tenant_id       = var.tenant_id != "" ? var.tenant_id : null

  # A BYOA service principal is scoped to a resource group / subscription with no
  # rights to register resource providers. Leaving auto-registration on turns
  # every apply into an AuthorizationFailed on Microsoft.Network.
  resource_provider_registrations = "none"
}

locals {
  # ---------------------------------------------------------------------------
  # Name sanitisation.
  # Azure resource names are per-type constrained; the harshest is the storage
  # account (3-24, lowercase alphanumeric only) handled in ../storage. Here we
  # only need a stable, lowercase, hyphen-free slug. Strategy:
  #   1. strip every non-alphanumeric character and lowercase
  #   2. drop the redundant leading "instance" that Omnistrate IDs carry, so the
  #      entropy-bearing suffix survives truncation
  #   3. truncate (substr silently returns the whole string when it is shorter)
  # ---------------------------------------------------------------------------
  id_alnum   = lower(replace(var.instance_id, "/[^A-Za-z0-9]/", ""))
  id_trimmed = startswith(local.id_alnum, "instance") ? substr(local.id_alnum, 8, -1) : local.id_alnum
  name_slug  = substr(local.id_trimmed, 0, 20)

  # ---------------------------------------------------------------------------
  # VNet identification.
  # A full ARM ID splits to:
  #   ["", "subscriptions", <sub>, "resourceGroups", <rg>, "providers",
  #    "Microsoft.Network", "virtualNetworks", <name>]
  # index 4 = resource group, last element = name.
  # ---------------------------------------------------------------------------
  vnet_id_parts    = split("/", var.vnet_id)
  vnet_id_is_arm   = length(local.vnet_id_parts) >= 9
  parsed_vnet_name = local.vnet_id_is_arm ? element(local.vnet_id_parts, length(local.vnet_id_parts) - 1) : var.vnet_id
  parsed_vnet_rg   = local.vnet_id_is_arm ? local.vnet_id_parts[4] : ""

  vnet_name = local.parsed_vnet_name
  vnet_rg   = var.vnet_resource_group_name != "" ? var.vnet_resource_group_name : local.parsed_vnet_rg

  # The delegated subnet is a CHILD of the VNet, so it must live in the VNet's
  # resource group. Everything else in this stack follows it for coherence.
  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : local.vnet_rg

  # ---------------------------------------------------------------------------
  # Delegated-subnet CIDR.
  # Auto-carve the LAST /28 of the VNet's first address space. Deployment cells
  # allocate their node/pod subnets from the low end of the range, so the top
  # block is the least likely to collide. Override with var.db_subnet_cidr when
  # the cell's addressing says otherwise.
  # ---------------------------------------------------------------------------
  vnet_cidr        = data.azurerm_virtual_network.cell.address_space[0]
  vnet_prefix_len  = tonumber(split("/", local.vnet_cidr)[1])
  subnet_newbits   = max(0, var.db_subnet_prefix_length - local.vnet_prefix_len)
  subnet_lastindex = floor(pow(2, local.subnet_newbits)) - 1
  auto_subnet_cidr = cidrsubnet(local.vnet_cidr, local.subnet_newbits, local.subnet_lastindex)
  db_subnet_cidr   = var.db_subnet_cidr != "" ? var.db_subnet_cidr : local.auto_subnet_cidr

  # Private DNS zone name. Azure rejects a Flexible Server private DNS zone whose
  # name does not end in `.postgres.database.azure.com`.
  private_dns_zone_name = "${local.name_slug}.${var.private_dns_zone_suffix}"

  common_tags = merge(
    {
      omnistrate_instance_id = var.instance_id
      omnistrate_resource    = "netAttach"
      managed_by             = "omnistrate"
    },
    var.tags,
  )
}

# ------------------------------------------------------------------------------
# The cell's existing VNet, read, never created.
# ------------------------------------------------------------------------------
data "azurerm_virtual_network" "cell" {
  name                = local.vnet_name
  resource_group_name = local.vnet_rg

  lifecycle {
    precondition {
      condition     = local.vnet_rg != ""
      error_message = "Could not determine the VNet resource group. vnet_id was not a full ARM resource ID and vnet_resource_group_name was not set. Set vnet_resource_group_name explicitly in variablesValuesFileOverride."
    }
    precondition {
      condition     = local.vnet_name != ""
      error_message = "Could not determine the VNet name from vnet_id. Wire vnet_id to {{ $sys.deploymentCell.cloudProviderNetworkID }}."
    }
  }
}

# ------------------------------------------------------------------------------
# Delegated subnet for PostgreSQL Flexible Server (VNet-integrated / private).
#
# The delegation is mandatory: without it the Flexible Server create call fails
# with SubnetNotDelegated. `join/action` is the only action the service needs.
# ------------------------------------------------------------------------------
resource "azurerm_subnet" "db" {
  name                 = "snet-pg-${local.name_slug}"
  resource_group_name  = local.resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [local.db_subnet_cidr]

  # A delegated Flexible Server subnet must not have private-endpoint network
  # policies enforced against it.
  private_endpoint_network_policies = "Disabled"

  delegation {
    name = "postgresql-flexible-server"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# ------------------------------------------------------------------------------
# NSG, the closest Azure analogue to an AWS security group.
#
# In azurerm 5.x `security_rule` is a computed attribute on the NSG rather than a
# nested block, so rules are declared as standalone resources. Do not mix the two
# styles on one NSG: the inline form would fight these on every apply.
# ------------------------------------------------------------------------------
resource "azurerm_network_security_group" "db" {
  name                = "nsg-pg-${local.name_slug}"
  location            = var.region
  resource_group_name = local.resource_group_name
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "db_allow_postgres_from_vnet" {
  name                        = "allow-postgres-from-vnet"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.db.name

  priority                   = 100
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = tostring(var.db_port)
  source_address_prefix      = "VirtualNetwork"
  destination_address_prefix = "VirtualNetwork"
  description                = "Temporal visibility store + Trino Iceberg JDBC catalog reach PostgreSQL from cell workloads."
}

resource "azurerm_network_security_rule" "db_deny_internet_inbound" {
  name                        = "deny-internet-inbound"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.db.name

  priority                   = 4000
  direction                  = "Inbound"
  access                     = "Deny"
  protocol                   = "*"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "Internet"
  destination_address_prefix = "*"
  description                = "Belt and braces on top of the default DenyAllInBound rule."
}

resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.db.id
}

# ------------------------------------------------------------------------------
# Private DNS zone + VNet link.
#
# PostgreSQL Flexible Server private access resolves <server>.postgres.database.azure.com
# through a private DNS zone that must be linked to the VNet BEFORE the server is
# created. The visibilityDb stack consumes `private_dns_zone_id` and depends on
# this resource through `dependsOn: [netAttach]` in the plan spec.
# ------------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "pg" {
  name                = local.private_dns_zone_name
  resource_group_name = local.resource_group_name
  tags                = local.common_tags
}

# NOTE: azurerm 5.x dropped `resource_group_name` from this resource, the link's
# resource group is derived from `private_dns_zone_id`. Passing it is a hard
# "Unsupported argument" error, not a deprecation warning.
resource "azurerm_private_dns_zone_virtual_network_link" "pg" {
  name                 = "pgdnslink-${local.name_slug}"
  private_dns_zone_id  = azurerm_private_dns_zone.pg.id
  virtual_network_id   = data.azurerm_virtual_network.cell.id
  registration_enabled = false
  tags                 = local.common_tags
}
