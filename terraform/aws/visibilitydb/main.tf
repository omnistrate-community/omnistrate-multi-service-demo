# ===========================================================================
#  Durable AI Platform, Plan 2, resource `visibilityDb`  (AWS)
# ===========================================================================
#
#  WHAT THIS STACK DOES
#    One RDS PostgreSQL 16 instance carrying two databases:
#      * temporal_visibility, Temporal's visibility store
#      * iceberg_catalog, Trino's Iceberg JDBC catalog
#    Both owned by the same role.
#
#  ------------------------------------------------------------------------
#  WHY THE OWNERSHIP MATTERS, AND HOW EACH DATABASE GETS CREATED
#  ------------------------------------------------------------------------
#  Temporal's visibility schema needs exactly two privileged things:
#  `CREATE EXTENSION btree_gin` and a `convert_ts` plpgsql function. btree_gin
#  declares trusted = true, so since PG13 a non-superuser can install it, but
#  only with CREATE on the database. A role holding merely CONNECT dies with
#  "permission denied for schema public". The role must OWN the database.
#
#  So the two databases are created two different ways:
#
#   1. temporal_visibility -> aws_db_instance.db_name.
#      RDS creates the instance's initial database owned by the master user.
#      No SQL connection, no extra provider, no network assumption. The
#      Temporal path, the one that must not fail, has zero moving parts.
#
#   2. iceberg_catalog -> cyrilgdn/postgresql.
#      aws_db_instance can only create one database, so the second one needs
#      SQL. The alternatives were weighed and rejected:
#        * a null_resource + local-exec psql: assumes a psql binary exists in
#          Omnistrate's OpenTofu runner image. Unverifiable, and it fails at
#          apply time rather than plan time.
#        * a Lambda-backed custom resource: a VPC-attached function, an
#          execution role and a deployment package, all to run one DDL
#          statement.
#        * folding the Iceberg catalog into temporal_visibility as a schema:
#          works, but interleaves Trino's catalog tables with Temporal's and
#          gives up per-database ownership.
#      The postgresql provider is declarative, participates in the same
#      apply/destroy lifecycle, and needs no binary that is not already a
#      provider plugin.
#
#      Its one requirement is that the OpenTofu runner can reach port 5432 in
#      the cell VPC. Omnistrate executes BYOA Terraform inside the customer's
#      deployment cell and netattach admits the whole VPC CIDR set, so this
#      holds, but see the note on the provider block below, and
#      `manage_pg_objects = false` is the escape hatch.
#  ------------------------------------------------------------------------
#
#  OMNISTRATE WIRING, variablesValuesFileOverride for the aws entry:
#
#      instance_id          = "{{ $sys.id }}"
#      region               = "{{ $sys.deploymentCell.region }}"
#      db_subnet_group_name = "{{ $netAttach.out.db_subnet_group_name }}"
#      db_security_group_id = "{{ $netAttach.out.db_security_group_id }}"
#
#  instance_class is left at its default. Wiring it to a customer input needs an
#  apiParameters entry on the visibilityDb service, which the plan does not
#  declare.
#
#  ...requires dependsOn: [netAttach] on the visibilityDb service, and:
#
#      requiredOutputs:
#        - key: pg_endpoint
#          exported: true
#        - key: pg_host
#          exported: true
#        - key: pg_port
#          exported: true
#        - key: pg_visibility_db
#          exported: true
#        - key: pg_iceberg_db
#          exported: true
#        - key: pg_user
#          exported: true
#        - key: pg_password
#          exported: false      # exported values land in result_params IN PLAINTEXT
#
#  IAM ACTIONS this stack needs in features.CUSTOM_TERRAFORM_POLICY.policies.aws:
#      rds:CreateDBInstance, rds:DeleteDBInstance, rds:ModifyDBInstance,
#      rds:DescribeDBInstances, rds:CreateDBParameterGroup,
#      rds:DeleteDBParameterGroup, rds:ModifyDBParameterGroup,
#      rds:DescribeDBParameterGroups, rds:DescribeDBParameters,
#      rds:DescribeDBEngineVersions, rds:AddTagsToResource,
#      rds:RemoveTagsFromResource, rds:ListTagsForResource,
#      rds:DescribeDBSubnetGroups, rds:DeleteDBInstanceAutomatedBackup,
#      logs:CreateLogGroup, logs:PutRetentionPolicy, logs:DescribeLogStreams,
#      ec2:DescribeSecurityGroups, ec2:DescribeVpcs, ec2:DescribeSubnets,
#      iam:CreateServiceLinkedRole (for rds.amazonaws.com)
#
#  There are no REPLACE_ME sentinels in this stack, every input comes from
#  $sys.* or from netAttach at deploy time.
# ===========================================================================

provider "aws" {
  region = var.region
}

locals {
  slug = trim(substr(lower(replace(var.instance_id, "/[^a-zA-Z0-9]+/", "-")), 0, 32), "-")
  name = "${var.name_prefix}-${local.slug}"

  engine_major = split(".", var.engine_version)[0]

  pg_password = var.pg_password != "" ? var.pg_password : random_password.pg.result

  tags = merge(
    {
      "Name"                       = local.name
      "app.kubernetes.io/part-of"  = "durable-ai-platform"
      "omnistrate.com/instance-id" = var.instance_id
      "omnistrate.com/component"   = "visibilitydb"
    },
    var.tags,
  )
}

# RDS rejects '/', '@', '"' and space in a master password. Alphanumeric-only
# sidesteps that and every downstream quoting question (the same string ends up
# in a Temporal YAML config, a Trino properties file and a JDBC URL).
resource "random_password" "pg" {
  length      = 32
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

# ---------------------------------------------------------------------------
# Parameter group
# ---------------------------------------------------------------------------

resource "aws_db_parameter_group" "this" {
  name        = local.name
  family      = "postgres${local.engine_major}"
  description = "Durable AI Platform visibility store parameters for ${var.instance_id}"

  # AWS ships rds.force_ssl = 1 in default.postgres15 and later. See the
  # force_ssl variable description for why this stack overrides it to 0.
  parameter {
    name         = "rds.force_ssl"
    value        = var.force_ssl ? "1" : "0"
    apply_method = "immediate"
  }

  # Anything slower than a second is worth seeing during a demo post-mortem.
  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier = local.name

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # RDS creates this database owned by the master user. That single fact is
  # what satisfies Temporal's CREATE EXTENSION btree_gin requirement.
  db_name  = var.pg_visibility_db
  username = var.pg_user
  password = local.pg_password
  port     = var.pg_port

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.storage_kms_key_id != "" ? var.storage_kms_key_id : null

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [var.db_security_group_id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = var.publicly_accessible
  multi_az               = var.multi_az

  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  apply_immediately           = true

  backup_retention_period  = var.backup_retention_period
  copy_tags_to_snapshot    = true
  delete_automated_backups = true

  # Both required for `terraform destroy` to succeed on instance delete.
  deletion_protection = var.deletion_protection
  skip_final_snapshot = true

  performance_insights_enabled    = var.performance_insights_enabled
  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = local.tags
}

# ---------------------------------------------------------------------------
# SQL-level objects
#
# Worth confirming: that Omnistrate's OpenTofu runner has a network path to port 5432
# inside the deployment cell VPC. Everything in this section depends on it.
# Confirm with one command against a live BYOA cell before the first demo:
#
#   kubectl -n <omnistrate-agent-namespace> get pods -o wide
#
#, if the terraform/tofu job pods run in the cell cluster they are inside the
# VPC and netattach's VPC-CIDR ingress already covers them. If instead the
# apply runs outside the customer VPC, set manage_pg_objects = false and create
# iceberg_catalog by hand (or point Trino's JDBC catalog at a schema inside
# temporal_visibility). Symptom if it is wrong: apply stalls on
# postgresql_database.iceberg and fails after connect_timeout.
# ---------------------------------------------------------------------------

provider "postgresql" {
  scheme    = "postgres"
  host      = aws_db_instance.this.address
  port      = aws_db_instance.this.port
  database  = "postgres" # RDS maintenance database
  username  = aws_db_instance.this.username
  password  = local.pg_password
  sslmode   = "require"
  superuser = false # the RDS master role is rds_superuser, not a real superuser

  connect_timeout = 60
  max_connections = 4
}

resource "postgresql_database" "iceberg" {
  count = var.manage_pg_objects ? 1 : 0

  name             = var.pg_iceberg_db
  owner            = var.pg_user
  encoding         = "UTF8"
  lc_collate       = var.pg_locale
  lc_ctype         = var.pg_locale
  template         = "template0"
  connection_limit = -1

  lifecycle {
    # lc_collate / lc_ctype are ForceNew in this provider, and RDS reports the
    # locale back in whichever spelling initdb used (en_US.UTF-8 vs en_US.utf8).
    # Without this, a cosmetic spelling difference would DROP and recreate the
    # Iceberg catalog database on the next apply.
    ignore_changes = [lc_collate, lc_ctype]
  }
}

# Temporal's own schema tool runs CREATE EXTENSION IF NOT EXISTS btree_gin at
# visibility schema v1.14, so this is belt and braces, but it fails loudly
# here, during terraform apply, instead of silently much later inside a Helm
# job, so a misconfiguration surfaces at apply time.
resource "postgresql_extension" "btree_gin" {
  count = var.manage_pg_objects ? 1 : 0

  name     = "btree_gin"
  database = var.pg_visibility_db

  # Temporal builds GIN indexes on top of this extension. A bare DROP EXTENSION
  # during `terraform destroy` would be refused while those indexes exist.
  drop_cascade = true

  depends_on = [aws_db_instance.this]
}
