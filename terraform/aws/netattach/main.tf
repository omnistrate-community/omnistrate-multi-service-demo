# ===========================================================================
#  Durable AI Platform, Plan 2, resource `netAttach`  (AWS)
# ===========================================================================
#
#  WHAT THIS STACK DOES
#    Attaches to the deployment cell's EXISTING VPC. It creates NO VPC, NO
#    subnets and NO NAT gateway, only the three things the rest of Plan 2
#    needs in order to live inside that VPC:
#
#      1. an RDS DB subnet group over the cell's private subnets
#      2. a security group that admits PostgreSQL from the cell's node CIDRs
#      3. an S3 gateway VPC endpoint (skipped per-route-table when the cell
#         already has one, so it is safe to leave enabled)
#
#  OMNISTRATE WIRING, put this in the plan spec under
#  services[].terraformConfigurations.configurationPerCloudProvider.aws.variablesValuesFileOverride:
#
#      instance_id = "{{ $sys.id }}"
#      region      = "{{ $sys.deploymentCell.region }}"
#      vpc_id      = "{{ $sys.deploymentCell.cloudProviderNetworkID }}"
#      private_subnet_ids = [
#        "{{ $sys.deploymentCell.privateSubnetIDs[0].id }}",
#        "{{ $sys.deploymentCell.privateSubnetIDs[1].id }}",
#        "{{ $sys.deploymentCell.privateSubnetIDs[2].id }}"
#      ]
#
#  ...and declare the outputs this stack publishes:
#
#      requiredOutputs:
#        - key: db_security_group_id
#          exported: false
#        - key: db_subnet_group_name
#          exported: false
#
#  IAM ACTIONS this stack needs in features.CUSTOM_TERRAFORM_POLICY.policies.aws:
#      ec2:CreateSecurityGroup, ec2:DeleteSecurityGroup, ec2:DescribeSecurityGroups,
#      ec2:DescribeSecurityGroupRules, ec2:AuthorizeSecurityGroupIngress,
#      ec2:AuthorizeSecurityGroupEgress, ec2:RevokeSecurityGroupIngress,
#      ec2:RevokeSecurityGroupEgress, ec2:DescribeVpcs, ec2:DescribeSubnets,
#      ec2:DescribeRouteTables, ec2:DescribeVpcEndpoints, ec2:DescribeVpcEndpointServices,
#      ec2:DescribeManagedPrefixLists, ec2:GetManagedPrefixListEntries,
#      ec2:CreateVpcEndpoint, ec2:DeleteVpcEndpoints, ec2:ModifyVpcEndpoint,
#      ec2:CreateTags, ec2:DeleteTags,
#      rds:CreateDBSubnetGroup, rds:DeleteDBSubnetGroup, rds:DescribeDBSubnetGroups,
#      rds:AddTagsToResource, rds:ListTagsForResource
#
#  There are no REPLACE_ME sentinels in this stack, every input comes from
#  $sys.* at deploy time.
# ===========================================================================

provider "aws" {
  region = var.region
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

locals {
  # $sys.id is already url-safe, but never assume: fold anything that is not
  # [a-zA-Z0-9] to a hyphen, lowercase it, cap it, and strip edge hyphens so the
  # result is legal as an S3 bucket / RDS identifier / security group name.
  slug = trim(substr(lower(replace(var.instance_id, "/[^a-zA-Z0-9]+/", "-")), 0, 32), "-")
  name = "${var.name_prefix}-${local.slug}"

  # Every CIDR associated with the cell VPC, not just the primary one. EKS
  # clusters using custom networking put their nodes/pods on a secondary CIDR
  # (commonly 100.64.0.0/16); allowing only .cidr_block would silently exclude
  # them and every Temporal/Trino connection would time out.
  vpc_cidr_blocks = distinct(concat(
    [data.aws_vpc.this.cidr_block],
    [for a in data.aws_vpc.this.cidr_block_associations : a.cidr_block],
  ))

  db_ingress_cidrs = length(var.db_ingress_cidr_blocks) > 0 ? var.db_ingress_cidr_blocks : local.vpc_cidr_blocks

  tags = merge(
    {
      "Name"                       = local.name
      "app.kubernetes.io/part-of"  = "durable-ai-platform"
      "omnistrate.com/instance-id" = var.instance_id
      "omnistrate.com/component"   = "netattach"
    },
    var.tags,
  )
}

# ---------------------------------------------------------------------------
# RDS DB subnet group over the cell's private subnets
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name        = local.name
  description = "Durable AI Platform visibility database subnets for ${var.instance_id}"
  subnet_ids  = var.private_subnet_ids

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Security group: PostgreSQL from the cell's node CIDRs only
# ---------------------------------------------------------------------------

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "Durable AI Platform PostgreSQL access for ${var.instance_id}"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { "Name" = "${local.name}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

# One rule per CIDR. aws_vpc_security_group_ingress_rule (rather than inline
# `ingress` blocks) so adding a CIDR does not churn the whole rule set.
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = toset(local.db_ingress_cidrs)

  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from deployment cell CIDR ${each.value}"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = var.db_port
  to_port           = var.db_port

  tags = local.tags
}

# RDS never initiates outbound connections for this workload, but an SG created
# by Terraform has its default allow-all egress removed. Leaving zero egress
# rules breaks nothing today and confuses everyone tomorrow, so state it.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.db.id
  description       = "Allow all egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = local.tags
}

# ---------------------------------------------------------------------------
# S3 gateway VPC endpoint
#
# A gateway endpoint works by installing a prefix-list route into route tables.
# If a route table already has a route to the S3 managed prefix list, adding a
# second endpoint to that same table fails hard with RouteAlreadyExists. Cells
# frequently ship with an S3 gateway endpoint already in place, so we associate
# only the route tables that do NOT already have that route, and create nothing
# at all when every table is already covered.
# ---------------------------------------------------------------------------

data "aws_vpc_endpoint_service" "s3" {
  count = var.create_s3_gateway_endpoint ? 1 : 0

  service      = "s3"
  service_type = "Gateway"
}

data "aws_ec2_managed_prefix_list" "s3" {
  count = var.create_s3_gateway_endpoint ? 1 : 0

  name = "com.amazonaws.${var.region}.s3"
}

data "aws_route_tables" "vpc" {
  count = var.create_s3_gateway_endpoint ? 1 : 0

  vpc_id = var.vpc_id
}

data "aws_route_table" "each" {
  for_each = var.create_s3_gateway_endpoint ? toset(data.aws_route_tables.vpc[0].ids) : toset([])

  route_table_id = each.value
}

locals {
  s3_prefix_list_id = var.create_s3_gateway_endpoint ? data.aws_ec2_managed_prefix_list.s3[0].id : ""

  s3_unrouted_route_table_ids = sort([
    for rt_id, rt in data.aws_route_table.each : rt_id
    if !contains([for r in rt.routes : r.destination_prefix_list_id], local.s3_prefix_list_id)
  ])

  create_s3_endpoint = var.create_s3_gateway_endpoint && length(local.s3_unrouted_route_table_ids) > 0
}

resource "aws_vpc_endpoint" "s3" {
  count = local.create_s3_endpoint ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = data.aws_vpc_endpoint_service.s3[0].service_name
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.s3_unrouted_route_table_ids

  tags = merge(local.tags, { "Name" = "${local.name}-s3" })
}
