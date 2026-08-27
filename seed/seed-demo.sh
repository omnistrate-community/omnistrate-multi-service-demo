#!/usr/bin/env bash
# =============================================================================
# Durable AI Platform: load sample workflow history into a running instance.
#
# A fresh instance has an empty Temporal UI and empty Trino tables. This script
# fills both by driving the worker image's own `bootstrap` and `submit`
# subcommands, so there is no duplicate schema or insert logic to keep in step.
#
# It runs as a Kubernetes Job inside the instance namespace, which is where the
# Cassandra, vLLM and Postgres endpoints resolve. It needs permission to create
# a Job in that one namespace and nothing more.
#
# Idempotent: `bootstrap` uses CREATE ... IF NOT EXISTS and every submitted
# workflow gets a unique id, so running it again adds history.
#
#   ./seed-demo.sh --namespace <instance-id>                 # defaults: 40 workflows
#   ./seed-demo.sh -n instance-abc123 --workflows 200 --docs 24
#   ./seed-demo.sh -n instance-abc123 --skip-bootstrap       # history only
#   ./seed-demo.sh -n instance-abc123 --dry-run              # print the Job, apply nothing
#
# 200 workflows x 24 documents is around 4,800 model calls through vLLM, so
# allow time for it to finish before querying the results.
# =============================================================================
set -euo pipefail

NAMESPACE=""
WORKFLOWS=40
DOCS=24
CONCURRENCY=8
PREFIX="seed"
SKIP_BOOTSTRAP=0
DRY_RUN=0
IMAGE=""
TIMEOUT="1800s"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)   NAMESPACE="${2:-}"; shift 2 ;;
    --workflows)      WORKFLOWS="${2:-}"; shift 2 ;;
    --docs)           DOCS="${2:-}"; shift 2 ;;
    --concurrency)    CONCURRENCY="${2:-}"; shift 2 ;;
    --prefix)         PREFIX="${2:-}"; shift 2 ;;
    --image)          IMAGE="${2:-}"; shift 2 ;;
    --timeout)        TIMEOUT="${2:-}"; shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage ;;
    *)                die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$NAMESPACE" ]] || die "--namespace is required (it is the Omnistrate instance id)"
command -v kubectl >/dev/null || die "kubectl not found on PATH"

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || die "namespace '$NAMESPACE' not found. Check the instance id, and that your kubeconfig points at the right deployment cell (omctl deployment-cell update-kubeconfig <cell>)"

# ---------------------------------------------------------------------------
# Reuse the running worker Deployment's own pod spec as the source of truth for
# image, env and service account, so the Job reaches the same Cassandra, vLLM
# and Postgres the workers do, with the same credentials, and this script never
# needs to know any of them.
# ---------------------------------------------------------------------------
DEPLOY=$(kubectl -n "$NAMESPACE" get deploy \
  -l app.kubernetes.io/name=ai-worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$DEPLOY" ]] \
  || die "no ai-worker Deployment in namespace '$NAMESPACE'. Wait for the instance to finish deploying, then retry."

if [[ -z "$IMAGE" ]]; then
  IMAGE=$(kubectl -n "$NAMESPACE" get deploy "$DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')
fi
SA=$(kubectl -n "$NAMESPACE" get deploy "$DEPLOY" \
  -o jsonpath='{.spec.template.spec.serviceAccountName}')
CM=$(kubectl -n "$NAMESPACE" get deploy "$DEPLOY" \
  -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}')
SECRET=$(kubectl -n "$NAMESPACE" get deploy "$DEPLOY" \
  -o jsonpath='{.spec.template.spec.containers[0].envFrom[1].secretRef.name}')

[[ -n "$CM" && -n "$SECRET" ]] \
  || die "could not read the worker's configMapRef/secretRef from deploy/$DEPLOY. Has the chart layout changed?"

JOB="ai-seed-$(date +%s)"

# Two containers, ordered: bootstrap must finish before submit starts, which is
# what initContainers give us for free.
BOOTSTRAP_INIT=""
if [[ "$SKIP_BOOTSTRAP" -eq 0 ]]; then
  BOOTSTRAP_INIT=$(cat <<EOF
      initContainers:
        - name: bootstrap
          image: ${IMAGE}
          args: ["bootstrap"]
          envFrom:
            - configMapRef: {name: ${CM}}
            - secretRef: {name: ${SECRET}}
          volumeMounts:
            - {name: tmp, mountPath: /tmp}
EOF
)
fi

MANIFEST=$(cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ai-worker-seed
    app.kubernetes.io/part-of: durable-ai-platform
spec:
  backoffLimit: 2
  # Clean up on its own so repeated seeding does not litter the namespace.
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ai-worker-seed
      # No omnistrate.com/include-customer-billing label here. This Job loads
      # sample data and is not part of the metered workload, so billing it
      # would overstate usage.
    spec:
      restartPolicy: Never
      serviceAccountName: ${SA}
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
${BOOTSTRAP_INIT}
      containers:
        - name: submit
          image: ${IMAGE}
          args:
            - "submit"
            - "--count"
            - "${WORKFLOWS}"
            - "--docs"
            - "${DOCS}"
            - "--concurrency"
            - "${CONCURRENCY}"
            - "--prefix"
            - "${PREFIX}"
            - "--wait"
          envFrom:
            - configMapRef: {name: ${CM}}
            - secretRef: {name: ${SECRET}}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          resources:
            requests: {cpu: 200m, memory: 512Mi}
            limits: {cpu: "2", memory: 2Gi}
          volumeMounts:
            - {name: tmp, mountPath: /tmp}
      volumes:
        - name: tmp
          emptyDir: {}
EOF
)

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s\n' "$MANIFEST"
  exit 0
fi

cat <<SUMMARY
Loading sample data into ${NAMESPACE}
  image        ${IMAGE}
  workflows    ${WORKFLOWS} x ${DOCS} documents  (~$((WORKFLOWS * DOCS)) LLM calls)
  bootstrap    $([[ "$SKIP_BOOTSTRAP" -eq 1 ]] && echo "skipped" || echo "yes")
  job          ${JOB}

SUMMARY

printf '%s\n' "$MANIFEST" | kubectl apply -f -

echo "Waiting for completion (timeout ${TIMEOUT}); Ctrl-C is safe, the Job keeps running."
kubectl -n "$NAMESPACE" wait --for=condition=complete "job/${JOB}" --timeout="$TIMEOUT" &
WAIT_OK=$!
kubectl -n "$NAMESPACE" wait --for=condition=failed "job/${JOB}" --timeout="$TIMEOUT" &
WAIT_FAIL=$!

# Whichever condition lands first decides the outcome.
if wait -n "$WAIT_OK" "$WAIT_FAIL"; then :; fi
kill "$WAIT_OK" "$WAIT_FAIL" 2>/dev/null || true

if kubectl -n "$NAMESPACE" get "job/${JOB}" \
     -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | grep -q True; then
  echo
  echo "Sample data loaded."
  echo "  Temporal UI : kubectl -n ${NAMESPACE} port-forward svc/temporal-web 8080:8080"
  echo "  Trino       : kubectl -n ${NAMESPACE} port-forward svc/trino 8081:8080"
  echo
  echo "  A query spanning both stores:"
  echo "    SELECT status, count(*) FROM cassandra.ai_platform.triage_results GROUP BY status;"
  echo "    SELECT * FROM iceberg.triage.triage_analytics ORDER BY batch_started DESC LIMIT 20;"
else
  echo
  echo "Sample data load did not complete. Logs:" >&2
  kubectl -n "$NAMESPACE" logs "job/${JOB}" --all-containers --tail=60 >&2 || true
  exit 1
fi
