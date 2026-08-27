# Architecture

![Durable AI Platform architecture](architecture.png)

## Two offerings

**Managed Cassandra** delivers a multi-rack Apache Cassandra cluster with a full lifecycle: create,
scale, stop, start, back up, restore, repair, and recover a failed node. It runs on the k8ssandra
operator, backs up to a bucket the customer nominates, and can be subscribed to on its own.

**Temporal AI Platform** delivers a durable AI workflow engine: Temporal for orchestration, vLLM
serving a Qwen model on a GPU node, Trino for querying results, and a managed PostgreSQL and object
store provisioned alongside. It uses a Managed Cassandra instance as its persistence layer.

Both provision into the customer's own AWS, GCP or Azure account, and both are metered.

## The workload

Document triage. A batch of documents is classified one model call at a time, each call a separate
Temporal activity with its own retry policy. Results land per-document in Cassandra and as an Iceberg
aggregate in object storage, which Trino queries together.

The durability is the feature. Kill a worker halfway through a batch and the documents already
classified are not re-inferred; the batch resumes on another pod and every result row records which
worker produced it.

## What each layer contributes

**Managed Cassandra** holds Temporal's workflow history, shards and mutable state, spread across one
rack per availability zone. Temporal writes a row per state transition rather than per workflow, so the
store sees a high volume of append-only writes with no joins.

**PostgreSQL 16** holds Temporal's searchable visibility index, and a second database on the same
instance backs Trino's Iceberg catalog.

**Object storage** holds three things: the Iceberg warehouse Trino reads, the model weights vLLM
streams at startup, and the Medusa backups from the Cassandra side.

**vLLM** serves `Qwen/Qwen3.5-4B` on a single GPU, streaming weights from the bucket rather than
pulling from Hugging Face at pod start.

**Trino** federates the two stores, so one query joins live Cassandra event history against the
Iceberg results.

## Using them together

A customer creates a Managed Cassandra instance, then supplies four values when creating the platform
instance:

| Parameter | Value |
| --- | --- |
| `cassandraHost` | `<instance-id>-dc1-service.<namespace>.svc.cluster.local` |
| `cassandraPort` | `9042` |
| `cassandraDatacenter` | `dc1` |
| `cassandraPassword` | the password they chose when creating the Cassandra instance |

The first three appear on the instance detail page. The password is the one they set on the Cassandra
instance.

Instances in the same deployment cell share a cluster and a cell-wide DNS zone, so the platform reaches
Cassandra over in-cluster CQL. Creating both against the same VPC with
`cloud_provider_native_network_id` makes that independent of cell placement.

## Resources

Managed Cassandra is one resource: a `K8ssandraCluster` with nine lifecycle verbs and a customer-facing
`repair` action, with the operator and its CRDs installed through `helmChartDependencies`.

The platform is nine. Four Terraform stacks run first, attaching to the cell's network and provisioning
the bucket, the PostgreSQL instance and the workload identity. Five Helm releases follow: a schema job,
the Temporal server, vLLM, the AI workers and Trino.

## Across the three clouds

The Terraform output keys are spelled identically on AWS, GCP and Azure, so the Helm layer references
`{{ $storageInfra.out.bucket_uri }}` once and deploys unchanged to all three.

| Layer | AWS | GCP | Azure |
| --- | --- | --- | --- |
| storage | `aws_s3_bucket`, `aws_kms_key` | `google_storage_bucket`, `google_kms_crypto_key` | `azurerm_storage_account`, `azurerm_key_vault_key` |
| database | `aws_db_instance` | `google_sql_database_instance` | `azurerm_postgresql_flexible_server` |
| identity | `aws_iam_role`, IRSA | `google_service_account`, Workload Identity | `azurerm_user_assigned_identity`, federated credential |

Azure has two specifics. Medusa authenticates to Blob storage with a storage account key, the only
long-lived credential in the design, where AWS and GCP use federated identity with nothing stored. And
`btree_gin` needs allow-listing in `azure.extensions` before Temporal's visibility schema applies, which
the Terraform module handles.

## Before the first deployment

cert-manager and the k8ssandra operator install as deployment cell amenities, cert-manager first, on
every cell that can host a Cassandra instance.

GPU quota needs arranging in advance, since all three clouds ship new accounts at zero and the increase
goes through support. The node pool serving vLLM should use single-GPU instance types, which keeps a
pod's GPU request equal to a whole billable unit.

The GPU tier takes six to sixteen minutes to come up from a cold node pool and around two minutes warm.

## Billing

Both offerings meter against built-in dimensions, configured as a pricing block rather than in code.
Managed Cassandra bills CPU, memory, storage and replicas; the platform adds GPU.

Metering is hourly and invoicing monthly, so usage accumulated overnight appears in the customer portal
alongside a draft invoice from a previous period. `enablePaywall` blocks instance creation until a
payment method exists, and that responds immediately.
