# ==============================================================================
# Durable AI Platform / Azure / netAttach / inputs
#
# Every variable is supplied by Omnistrate through
# `terraformConfigurations.configurationPerCloudProvider.azure.variablesValuesFileOverride`
# (see the header of main.tf for the exact block to paste into the plan spec).
# No variable carries a `{{ ... }}` default: templating inside .tf files would
# make the module un-validatable offline.
# ==============================================================================

variable "instance_id" {
  description = "Omnistrate instance identifier ({{ $sys.id }}). Included in every globally-unique Azure resource name."
  type        = string

  validation {
    condition     = length(var.instance_id) > 0
    error_message = "instance_id must not be empty; wire it to {{ $sys.id }}."
  }
}

variable "region" {
  description = "Azure location for created resources ({{ $sys.deploymentCell.region }}), e.g. eastus."
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID ({{ $sys.deploymentCell.azure.subscriptionID }}). Empty string falls back to the ARM_SUBSCRIPTION_ID the Omnistrate Terraform runner exports."
  type        = string
  default     = ""
}

variable "tenant_id" {
  description = "Azure tenant ID ({{ $sys.deploymentCell.azure.tenantID }}). Empty string falls back to ARM_TENANT_ID."
  type        = string
  default     = ""
}

variable "vnet_id" {
  description = <<-EOT
    The deployment cell's EXISTING virtual network ({{ $sys.deploymentCell.cloudProviderNetworkID }}).
    Expected to be the full ARM resource ID:
      /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>
    The VNet name and resource group are parsed out of it. If Omnistrate hands over a bare
    VNet name instead, set `vnet_resource_group_name` explicitly and this value is used as the name.
    Worth confirming: whether Omnistrate renders the full ARM ID or a bare name on Azure. Check with
    `omctl instance describe <id> -o json` on a live Azure BYOA cell before the first deploy.
  EOT
  type        = string
}

variable "vnet_resource_group_name" {
  description = "Override for the resource group holding the cell VNet. Empty string = parse it out of vnet_id."
  type        = string
  default     = ""
}

variable "resource_group_name" {
  description = "Resource group to create netAttach resources in. Empty string = same resource group as the cell VNet (required for the delegated subnet, which is a child of the VNet)."
  type        = string
  default     = ""
}

variable "db_subnet_cidr" {
  description = "CIDR for the PostgreSQL Flexible Server delegated subnet. Empty string = auto-carve the LAST block of the VNet address space at db_subnet_prefix_length (cells allocate from the low end, so the top of the range is the least likely to collide)."
  type        = string
  default     = ""
}

variable "db_subnet_prefix_length" {
  description = "Prefix length of the auto-carved delegated subnet. /28 is the Azure minimum for a Flexible Server delegated subnet."
  type        = number
  default     = 28

  validation {
    condition     = var.db_subnet_prefix_length >= 24 && var.db_subnet_prefix_length <= 28
    error_message = "db_subnet_prefix_length must be between 24 and 28 (28 is the Azure minimum size for a PostgreSQL Flexible Server delegated subnet)."
  }
}

variable "db_port" {
  description = "PostgreSQL port opened in the NSG."
  type        = number
  default     = 5432
}

variable "private_dns_zone_suffix" {
  description = "Suffix of the private DNS zone. Azure requires a PostgreSQL Flexible Server private DNS zone name to end with `.postgres.database.azure.com`."
  type        = string
  default     = "private.postgres.database.azure.com"
}

variable "tags" {
  description = "Extra tags merged onto every resource. Azure tag NAMES may not contain < > % & \\ ? /, do not use slash-style keys."
  type        = map(string)
  default     = {}
}
