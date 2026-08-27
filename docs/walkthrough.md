# Walkthrough

A guided tour of a running deployment, starting from two instances created as described in the
[README](../README.md). See [architecture.md](architecture.md) for how the pieces fit together.

## Load the sample data

The workers ship with a document-triage workflow and a generator, so a fresh instance can be filled
with realistic history rather than sitting empty:

```bash
omctl deployment-cell update-kubeconfig <cell-id>
./seed/seed-demo.sh --namespace <platform-instance-id> --workflows 200
```

Two hundred workflows at twenty-four documents each runs roughly forty-eight hundred model calls
through vLLM and takes a while, so it is worth starting well before you want to look at the results.
The script creates the Cassandra keyspace and the Iceberg table on first run and is safe to run again
to add more history.

The GPU tier takes six to sixteen minutes to come up from a cold node pool and around two minutes once
the model is cached on its volume, so the first batch will be slower than the rest.

## Trace an infrastructure value into a running pod

The platform plan never hard-codes a database endpoint. To see the whole path, start with the Terraform
output:

```bash
grep -A3 'output "pg_endpoint"' terraform/aws/visibilitydb/outputs.tf
```

Find where the plan consumes it:

```bash
grep -n 'pg_endpoint' plans/plan2-temporal-ai-platform.yaml
```

Then read what the running Temporal server actually got:

```bash
kubectl -n <platform-instance-id> get cm temporal -o yaml | grep -A2 connectAddr
```

The same value appears in all three places, and the only reference in the plan is
`{{ $visibilityDb.out.pg_endpoint }}`. The Terraform module and the Helm release never learn about
each other directly.

## Query across both stores

Port-forward Trino and open a shell:

```bash
kubectl -n <platform-instance-id> port-forward svc/trino 8080:8080
```

The per-document results live in Cassandra and the aggregates live in Iceberg on object storage, so a
single query can join live event history against summarised output:

```sql
SELECT r.status, count(*) AS documents, avg(a.mean_latency_ms) AS avg_latency
FROM cassandra.ai_platform.triage_results r
JOIN iceberg.triage.triage_analytics a ON a.batch_id = r.batch_id
GROUP BY r.status
ORDER BY documents DESC;
```

Both catalogs are configured in the plan spec, pointed at the Cassandra instance and the bucket that
the Terraform layer provisioned.

## Watch a workflow survive a worker failure

Every model call is a separate Temporal activity, and every result row records which worker produced
it. Start a batch:

```bash
kubectl -n <platform-instance-id> exec deploy/ai-worker -- \
  python main.py submit --count 1 --docs 40
```

While it is running, delete one of the worker pods:

```bash
kubectl -n <platform-instance-id> delete pod -l app.kubernetes.io/name=ai-worker --field-selector status.phase=Running | head -1
```

Activity heartbeats are set to thirty seconds, so the loss is detected without waiting out the
start-to-close timeout, and the workflow continues on a surviving pod. Afterwards the batch shows more
than one worker:

```sql
SELECT DISTINCT worker_identity
FROM cassandra.ai_platform.triage_results
WHERE batch_id = '<batch>' ALLOW FILTERING;
```

The documents classified before the deletion are not reprocessed. Only the calls that were in flight
are retried.

## Back up and restore Cassandra

Backup and restore are instance actions on the Managed Cassandra plan rather than scripts you run
yourself:

```bash
omctl instance backup <cassandra-instance-id> --wait
omctl instance list-backups <cassandra-instance-id>
```

Medusa writes to the bucket nominated when the instance was created, under a prefix named for the
instance, so the objects are visible from the cloud console. Restoring creates a new cluster seeded
from a chosen snapshot:

```bash
omctl instance restore <cassandra-instance-id> --snapshot-id <snapshot> --wait
```

A repair is also exposed as an action, which is the common day-two operation after a node replacement:

```bash
omctl instance action <cassandra-instance-id> --verb repair --param repairKeyspace=temporal
```

## Deploy the same specs to another cloud

Nothing in the Helm layer is cloud-specific, so a second instance on a different provider comes from
the same plan:

```bash
omctl instance create \
  --service "Durable AI Platform" --environment Dev --plan "Temporal AI Platform" \
  --resource temporalServer \
  --cloud-provider azure --region eastus \
  --customer-account-id <azure-account-config-id> \
  --param-file platform.json --wait
```

The Terraform modules differ underneath, since each cloud has its own storage, database and identity
primitives, but they publish the same output keys and the plan consumes them identically.

## Scale the parts independently

Each tier is its own resource, so changing one leaves the others alone:

```bash
# more workers, same Temporal control plane
omctl instance modify <platform-instance-id> --param workerReplicas=12

# more Cassandra nodes, on the other instance entirely
omctl instance modify <cassandra-instance-id> --param clusterSize=6
```

## Common questions

**Why Cassandra rather than PostgreSQL for Temporal?** Temporal writes a row per workflow state
transition, so a thousand concurrent workflows at fifty steps each is roughly fifty thousand
append-only writes with no joins. The searchable visibility index is a separate store and does sit on
PostgreSQL, which is why the architecture shows both.

**Why two subscriptions rather than one?** Managed Cassandra stands on its own, and a customer who
wants only a Cassandra cluster can subscribe to just that. The platform is a second offering built on
top of it.

**What happens if the Cassandra instance is deleted?** Temporal loses its persistence layer and the
platform instance goes unhealthy. Deletion protection is enabled on the Cassandra plan for that reason.

**How is the GPU billed?** GPU is one of the metered dimensions on the platform plan, alongside CPU,
memory, storage and replicas. Single-GPU instance types keep a pod's request equal to a whole billable
unit.

**Where does usage show up?** Metering is hourly and invoices are generated monthly, so usage appears
in the customer portal within the hour and on an invoice at period close. `enablePaywall` gates
instance creation on a payment method existing, which takes effect immediately.
