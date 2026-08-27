# ---------------------------------------------------------------------------
# Durable AI Platform, Plan 2 / visibilityDb / AWS
#
# Versions are pinned here because the platform does not pin them, and the
# engine that runs these files is OpenTofu.
# No `backend` block anywhere in this repository. Omnistrate stores state in
# Kubernetes secrets and strips any backend it finds.
#
# cyrilgdn/postgresql is here to create the SECOND database (the Iceberg JDBC
# catalog) with the correct owner. See the justification block at the top of
# main.tf.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.25"
    }
  }
}
