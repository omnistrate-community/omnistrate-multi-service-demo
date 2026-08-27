# =============================================================================
# Durable AI Platform, ai-worker
#
# Temporal worker for DocumentTriageWorkflow: one LLM call per activity against
# the in-cluster vLLM endpoint, per-document rows into Cassandra, and an Iceberg
# append into the object-store warehouse that Trino reads.
#
# Operator-supplied values (sentinels, replace before pushing):
#   REPLACE_ME_REGISTRY   your container registry, e.g.
#                         123456789012.dkr.ecr.us-east-1.amazonaws.com
#                         us-central1-docker.pkg.dev/<project>/durable-ai-platform
#                         <registry>.azurecr.io
#   (nothing else in this file needs editing, see README.md)
#
# Build (multi-arch, from THIS directory as the build context):
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -t REPLACE_ME_REGISTRY/ai-worker:0.1.0 --push .
#
# Every pin in requirements.txt publishes manylinux wheels for both x86_64 and
# aarch64, so `--only-binary=:all:` below is an assertion, not a preference:
# if a pin ever loses its wheel the build fails loudly here instead of silently
# needing a compiler in the image.
# =============================================================================

# --- build stage -------------------------------------------------------------
FROM python:3.12-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_ROOT_USER_ACTION=ignore \
    PYTHONDONTWRITEBYTECODE=1

# Self-contained virtualenv, copied wholesale into the runtime stage. Nothing
# from this stage other than /opt/venv survives, so pip's own metadata, build
# temporaries and the apt cache never reach the shipped image.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /build
COPY requirements.txt ./
RUN pip install --upgrade "pip==25.3" \
 && pip install --only-binary=:all: --requirement requirements.txt \
 && find /opt/venv -name '__pycache__' -type d -prune -exec rm -rf {} + \
 && find /opt/venv -name '*.pyc' -delete

# --- runtime stage -----------------------------------------------------------
FROM python:3.12-slim AS runtime

# Non-root, no login shell, no home-directory writes. 65532 is the conventional
# "nonroot" uid/gid (distroless), which keeps fsGroup arithmetic predictable if
# a PVC is ever attached.
RUN groupadd --system --gid 65532 app \
 && useradd  --system --uid 65532 --gid 65532 \
             --home-dir /app --no-create-home --shell /usr/sbin/nologin app

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONPATH=/app \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONFAULTHANDLER=1 \
    # The Temporal SDK's Rust core reads this on panic; without it a core panic
    # is a bare address with no frames, which is unhelpful at 2am.
    RUST_BACKTRACE=1 \
    # Ports the health server and the Prometheus exporter bind. Kept here as
    # well as in the chart so `docker run` alone behaves the same as the pod.
    HEALTH_PORT=8080 \
    METRICS_PORT=9090

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=65532:65532 worker.py main.py ./

# Byte-compile ahead of time so the first workflow task does not pay import
# cost, and so nothing needs to write to /app at runtime.
RUN python -m compileall -q /app && chmod -R a-w /app

USER 65532:65532

EXPOSE 8080 9090

# /healthz is served before Cassandra is dialled, /readyz only flips to 200 once
# the Temporal worker is polling, mirrors the chart's liveness/readiness split.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["python", "-c", "import os,urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:%s/healthz' % os.environ.get('HEALTH_PORT','8080'), timeout=4).status == 200 else 1)"]

ENTRYPOINT ["python", "/app/main.py"]
CMD ["worker"]
