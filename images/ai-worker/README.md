# ai-worker

Temporal workers for the Durable AI Platform. Runs `DocumentTriageWorkflow`, in
which every model call is its own Temporal activity.

## How durability works here

`classify_document` is scheduled and completed individually in the workflow's
event history. If a worker pod is lost halfway through a 40-document batch,
Temporal replays the history on a surviving pod, and the documents already
classified are not re-inferred. Only the in-flight calls are retried.

Every row in `triage_results` carries `worker_identity`, so you can check which
pods handled a batch:

```sql
SELECT DISTINCT worker_identity FROM cassandra.ai_platform.triage_results
WHERE batch_id = '<batch>' ALLOW FILTERING;
```

`heartbeat_timeout` is 30s, so a lost worker is detected in around 30s rather
than after the 180s start-to-close timeout.

Results land in both stores the platform federates: per-document rows in
Cassandra, and an Iceberg append to the object-store warehouse, which Trino
queries together.

## Layout

| File | Purpose |
|---|---|
| `worker.py` | Workflow, activities, settings, CLI. ~1.6k lines. |
| `main.py` | Entry point, so that `worker.py` is never `__main__`. The Temporal sandbox re-imports the workflow's module per instance, and a `__main__` module cannot be re-imported cleanly. |
| `requirements.txt` | Pinned dependencies. Every pin ships manylinux wheels for both x86_64 and aarch64. |
| `Dockerfile` | Two-stage, non-root (65532), read-only rootfs, byte-compiled ahead of time. |
| `chart/` | Helm chart deployed by the `aiWorkers` resource in Plan 2. |

## CLI

```bash
python main.py worker             # run the worker (the image's default CMD)
python main.py bootstrap          # create the Cassandra keyspace/tables + Iceberg table
python main.py submit --count 5   # start triage workflows
```

`seed/seed-demo.sh` at the repo root drives `bootstrap` and `submit` as a
Kubernetes Job inside a live instance namespace, which is the usual way to load
sample data rather than running these by hand.

## Build and push

Replace `REPLACE_ME_REGISTRY` with your registry. Multi-arch is worth doing here, since
Graviton and Ampere node pools are common and every dependency has an aarch64
wheel.

```bash
cd images/ai-worker

# --- AWS ECR ---
REG=123456789012.dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "$REG"
aws ecr create-repository --repository-name ai-worker --region us-east-1 || true

# --- GCP Artifact Registry ---
# REG=us-central1-docker.pkg.dev/<project>/durable-ai-platform
# gcloud auth configure-docker us-central1-docker.pkg.dev

# --- Azure Container Registry ---
# REG=<registry>.azurecr.io
# az acr login --name <registry>

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t "$REG/ai-worker:0.1.0" \
  --push .
```

Then set `image.repository` in the `aiWorkers` resource of
`plans/plan2-temporal-ai-platform.yaml` to `$REG/ai-worker`, and `workerImageTag`
to the tag you pushed.

`--only-binary=:all:` in the Dockerfile makes the build fail loudly if a pin ever
loses its wheel, rather than quietly requiring a compiler in the shipped image.

## Configuration

All configuration is environment variables. `chart/values.yaml` is the
authoritative list and `worker._Settings.from_env` is the implementation. The
chart splits them in two:

- **ConfigMap** holds everything non-secret, so `kubectl get cm -o yaml` is safe
  to share.
- **Secret** holds `CASSANDRA_PASSWORD`, `ICEBERG_PG_PASSWORD` and the optional
  `TEMPORAL_API_KEY` and `VLLM_API_KEY`. Empty values are omitted rather than
  written as `""`, so an unset optional credential leaves the env var absent and
  the code's default applies.

The pod also gets `POD_NAME` from `metadata.name` via `fieldRef`, which becomes
`worker_identity` in the results table.

## Local run

Against your own Cassandra/Postgres/vLLM:

```bash
docker run --rm \
  -e TEMPORAL_ADDRESS=host.docker.internal:7233 \
  -e CASSANDRA_CONTACT_POINTS=host.docker.internal \
  -e CASSANDRA_PASSWORD=... \
  -e VLLM_BASE_URL=http://host.docker.internal:8000/v1 \
  "$REG/ai-worker:0.1.0" worker
```

`/healthz` answers before Cassandra is dialled, while `/readyz` returns 200 only
once the worker is polling the task queue. Splitting them keeps a brief Cassandra
outage from getting the pod killed and restarted.
