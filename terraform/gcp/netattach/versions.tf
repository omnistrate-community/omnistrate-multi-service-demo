terraform {
  # OpenTofu is what actually runs inside Omnistrate. Keep the floor at a
  # version that has the `trim`/`min`/`can` builtins used in main.tf.
  required_version = ">= 1.6.0"

  # Omnistrate pins nothing, pin providers here or a silent provider upgrade
  # will change plan output between two instances of the same service plan.
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.50"
    }
  }

  # NEVER add a `backend` block. Omnistrate manages OpenTofu state in Kubernetes
  # secrets, one state per deployment, and strips any backend it finds.
}
