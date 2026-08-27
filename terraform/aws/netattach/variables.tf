variable "instance_id" {
  description = "Omnistrate instance id ($sys.id). Included in every globally-scoped name so two instances in one cell never collide."
  type        = string

  validation {
    condition     = length(trimspace(var.instance_id)) > 0
    error_message = "instance_id must not be empty; wire it to {{ $sys.id }}."
  }
}

variable "region" {
  description = "AWS region of the deployment cell ($sys.deploymentCell.region)."
  type        = string
}

variable "vpc_id" {
  description = "ID of the deployment cell's EXISTING VPC ($sys.deploymentCell.cloudProviderNetworkID). This stack attaches to it; it never creates a VPC."
  type        = string

  validation {
    condition     = startswith(var.vpc_id, "vpc-")
    error_message = "vpc_id must be an existing VPC id of the form vpc-xxxxxxxx."
  }
}

variable "private_subnet_ids" {
  description = "Private subnet ids of the deployment cell ($sys.deploymentCell.privateSubnetIDs[i].id). RDS requires subnets in at least two Availability Zones."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "private_subnet_ids needs at least two subnets in two different Availability Zones (an RDS DB subnet group requirement)."
  }
}

variable "db_ingress_cidr_blocks" {
  description = "CIDR blocks allowed to reach PostgreSQL. Leave empty (the default) to derive every CIDR associated with the cell VPC, which is what covers EKS nodes on a secondary CIDR."
  type        = list(string)
  default     = []
}

variable "db_port" {
  description = "PostgreSQL port opened on the database security group."
  type        = number
  default     = 5432
}

variable "create_s3_gateway_endpoint" {
  description = "Create an S3 gateway VPC endpoint so Iceberg and vLLM model-weight traffic stays off the NAT gateway. The stack auto-skips route tables that already carry an S3 prefix-list route, so leaving this true is safe on a cell that already has one."
  type        = bool
  default     = true
}

variable "name_prefix" {
  description = "Short prefix for every created resource name. Keep it <= 10 characters."
  type        = string
  default     = "daip"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,9}$", var.name_prefix))
    error_message = "name_prefix must be 2-10 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }
}

variable "tags" {
  description = "Extra tags merged onto every taggable resource."
  type        = map(string)
  default     = {}
}
