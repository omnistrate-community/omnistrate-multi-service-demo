#!/usr/bin/env python3
"""Durable AI Platform, Temporal AI worker.

A document-triage pipeline where **every LLM call is its own Temporal activity**.

    DocumentTriageWorkflow
      └─ load_documents            (Cassandra read; synthesises a batch if the table is empty)
      └─ for each document, concurrently, in chunks of `concurrency`:
           ├─ classify_document    (one vLLM chat-completion, retried, heartbeated)
           └─ persist_classification (one Cassandra row)
      └─ write_analytics_batch     (one Iceberg append to the object-store warehouse)
      └─ finalize_batch            (Cassandra batch-summary row)

Why this shape is the demo:

*   `classify_document` is scheduled and completed **individually** in the workflow's event
    history. Kill the worker pod half-way through a 40-document batch and Temporal replays the
    history on a surviving pod: the documents already classified are *not* re-inferred, only the
    in-flight ones are retried. Each row in `triage_results` carries `worker_identity`, so after
    a kill you can literally `SELECT DISTINCT worker_identity` and watch the batch finish on a
    different pod.
*   `heartbeat_timeout` is 30 s, so a hard `kill -9` is detected in ~30 s instead of waiting out
    the 180 s start-to-close timeout, so recovery is quick rather than silent.
*   Results land in **both** stores the platform federates: per-document rows in Cassandra and an
    Iceberg table in the bucket. Trino joins them.

Entry point is `main.py` (this module must stay importable without side effects, the Temporal
workflow sandbox re-imports it, and a module named `__main__` cannot be re-imported cleanly).

    python main.py worker             # run the worker (the container's default command)
    python main.py bootstrap          # create the Cassandra keyspace/tables + Iceberg table
    python main.py submit --count 5   # start demo workflows

Configuration is 100 % environment variables, see `_Settings.from_env` and the Helm chart's
`values.yaml`, which is the authoritative list.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import logging
import os
import random
import re
import signal
import socket
import string
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable, Sequence

from temporalio import activity, workflow
from temporalio.client import Client
from temporalio.common import RetryPolicy, WorkflowIDReusePolicy
from temporalio.exceptions import ApplicationError, WorkflowAlreadyStartedError
from temporalio.runtime import PrometheusConfig, Runtime, TelemetryConfig
from temporalio.service import TLSConfig
from temporalio.worker import Worker

# The Temporal workflow sandbox re-imports this module for every workflow instance. These two
# packages are expensive and are only ever touched from activity code (which is NOT sandboxed),
# so mark them pass-through. pyarrow/pyiceberg are imported lazily inside IcebergWriter instead.
with workflow.unsafe.imports_passed_through():
    import openai
    from cassandra import ConsistencyLevel
    from cassandra.auth import PlainTextAuthProvider
    from cassandra.cluster import EXEC_PROFILE_DEFAULT, Cluster, ExecutionProfile, Session
    from cassandra.concurrent import execute_concurrent_with_args
    from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy
    from cassandra.query import dict_factory

LOG = logging.getLogger("aiworker")

# --------------------------------------------------------------------------------------------
# Domain vocabulary, kept small and closed so the model's output is checkable and Trino queries
# over `category` and `action` group cleanly in queries.
# --------------------------------------------------------------------------------------------

CATEGORIES: tuple[str, ...] = (
    "billing",
    "outage",
    "security",
    "performance",
    "data_loss",
    "feature_request",
    "documentation",
    "other",
)

ACTIONS: tuple[str, ...] = (
    "auto_resolve",
    "escalate_l2",
    "escalate_security",
    "page_oncall",
    "file_bug",
    "no_action",
)

SENTIMENTS: tuple[str, ...] = ("positive", "neutral", "negative")

SYSTEM_PROMPT = (
    "You are a support-ticket triage engine. You read one customer document and emit exactly one "
    "JSON object and nothing else, no prose, no markdown fence, no explanation.\n"
    "The JSON object must have exactly these keys:\n"
    '  "category":  one of ' + json.dumps(list(CATEGORIES)) + "\n"
    '  "severity":  integer 1 (cosmetic) to 5 (business down)\n'
    '  "sentiment": one of ' + json.dumps(list(SENTIMENTS)) + "\n"
    '  "summary":   one sentence, at most 240 characters\n'
    '  "action":    one of ' + json.dumps(list(ACTIONS)) + "\n"
)

_IDENT_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,47}$")
_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)
_JSON_RE = re.compile(r"\{.*\}", re.DOTALL)


class MalformedDocument(Exception):
    """Raised for input that no number of retries will fix."""


# --------------------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------------------


def _env(name: str, default: str = "") -> str:
    value = os.environ.get(name)
    return default if value is None or value == "" else value


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on", "y", "t")


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except ValueError as exc:  # pragma: no cover - configuration error
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except ValueError as exc:  # pragma: no cover - configuration error
        raise ValueError(f"{name} must be a number, got {raw!r}") from exc


def _validate_identifier(kind: str, value: str) -> str:
    """Cassandra identifiers are interpolated into CQL, so they are whitelisted, not escaped."""
    if not _IDENT_RE.match(value):
        raise ValueError(
            f"{kind} {value!r} is not a legal unquoted CQL identifier "
            "(letter first, then letters/digits/underscore, max 48 chars)"
        )
    return value


@dataclass
class _Settings:
    # -- Temporal ----------------------------------------------------------------------------
    temporal_address: str = "temporal-frontend:7233"
    temporal_namespace: str = "default"
    temporal_task_queue: str = "ai-triage"
    temporal_tls: bool = False
    temporal_api_key: str = ""

    # -- vLLM (OpenAI-compatible) ------------------------------------------------------------
    llm_base_url: str = "http://vllm-router-service:80/v1"
    llm_api_key: str = "EMPTY"
    llm_model: str = "Qwen/Qwen3.5-4B"
    llm_max_tokens: int = 384
    llm_temperature: float = 0.1
    llm_timeout_seconds: float = 120.0
    llm_json_mode: bool = True
    llm_disable_thinking: bool = False
    llm_stub: bool = False
    llm_stub_latency_ms: int = 0

    # -- Cassandra ---------------------------------------------------------------------------
    cassandra_contact_points: str = ""
    cassandra_port: int = 9042
    cassandra_datacenter: str = "dc1"
    cassandra_keyspace: str = "ai_platform"
    cassandra_username: str = "temporal"
    cassandra_password: str = ""
    cassandra_replication_factor: int = 3
    cassandra_consistency: str = "LOCAL_QUORUM"
    cassandra_request_timeout: float = 30.0
    cassandra_connect_timeout_seconds: float = 600.0

    # -- Iceberg / object store --------------------------------------------------------------
    iceberg_enabled: bool = True
    iceberg_warehouse_uri: str = ""
    iceberg_catalog_name: str = "iceberg"
    iceberg_namespace: str = "ai_platform"
    iceberg_table: str = "triage_results"
    iceberg_jdbc_uri: str = ""
    iceberg_pg_host_port: str = ""
    iceberg_pg_database: str = "iceberg_catalog"
    iceberg_pg_user: str = "temporal"
    iceberg_pg_password: str = ""
    iceberg_pg_sslmode: str = "require"
    iceberg_fileio_properties: str = "{}"
    object_store_region: str = ""
    azure_storage_account: str = ""

    # -- Worker runtime ----------------------------------------------------------------------
    max_concurrent_activities: int = 32
    max_concurrent_workflow_tasks: int = 64
    max_cached_workflows: int = 400
    graceful_shutdown_seconds: int = 0
    bootstrap_on_start: bool = False
    health_port: int = 8080
    metrics_enabled: bool = True
    metrics_port: int = 9090
    pod_name: str = ""
    log_level: str = "INFO"

    @property
    def identity(self) -> str:
        return self.pod_name or socket.gethostname()

    @property
    def contact_point_list(self) -> list[str]:
        return [h.strip() for h in self.cassandra_contact_points.split(",") if h.strip()]

    @property
    def sqlalchemy_uri(self) -> str:
        """SQLAlchemy URI for the Iceberg JDBC catalog (the same catalog Trino reads)."""
        if self.iceberg_jdbc_uri:
            return self.iceberg_jdbc_uri
        if not self.iceberg_pg_host_port:
            raise ValueError(
                "Iceberg is enabled but neither ICEBERG_JDBC_URI nor ICEBERG_PG_HOST_PORT is set"
            )
        host_port = self.iceberg_pg_host_port
        if ":" not in host_port:
            host_port = f"{host_port}:5432"
        from urllib.parse import quote_plus

        user = quote_plus(self.iceberg_pg_user)
        password = quote_plus(self.iceberg_pg_password)
        suffix = f"?sslmode={self.iceberg_pg_sslmode}" if self.iceberg_pg_sslmode else ""
        return f"postgresql+psycopg2://{user}:{password}@{host_port}/{self.iceberg_pg_database}{suffix}"

    @classmethod
    def from_env(cls) -> "_Settings":
        s = cls(
            temporal_address=_env("TEMPORAL_ADDRESS", "temporal-frontend:7233"),
            temporal_namespace=_env("TEMPORAL_NAMESPACE", "default"),
            temporal_task_queue=_env("TEMPORAL_TASK_QUEUE", "ai-triage"),
            temporal_tls=_env_bool("TEMPORAL_TLS", False),
            temporal_api_key=_env("TEMPORAL_API_KEY", ""),
            llm_base_url=_env("VLLM_BASE_URL", "http://vllm-router-service:80/v1"),
            llm_api_key=_env("VLLM_API_KEY", "EMPTY"),
            llm_model=_env("VLLM_MODEL", "Qwen/Qwen3.5-4B"),
            llm_max_tokens=_env_int("LLM_MAX_TOKENS", 384),
            llm_temperature=_env_float("LLM_TEMPERATURE", 0.1),
            llm_timeout_seconds=_env_float("LLM_TIMEOUT_SECONDS", 120.0),
            llm_json_mode=_env_bool("LLM_JSON_MODE", True),
            llm_disable_thinking=_env_bool("LLM_DISABLE_THINKING", False),
            llm_stub=_env_bool("LLM_STUB", False),
            llm_stub_latency_ms=_env_int("LLM_STUB_LATENCY_MS", 0),
            cassandra_contact_points=_env("CASSANDRA_CONTACT_POINTS", ""),
            cassandra_port=_env_int("CASSANDRA_PORT", 9042),
            cassandra_datacenter=_env("CASSANDRA_DATACENTER", "dc1"),
            cassandra_keyspace=_env("CASSANDRA_KEYSPACE", "ai_platform"),
            cassandra_username=_env("CASSANDRA_USERNAME", "temporal"),
            cassandra_password=_env("CASSANDRA_PASSWORD", ""),
            cassandra_replication_factor=_env_int("CASSANDRA_REPLICATION_FACTOR", 3),
            cassandra_consistency=_env("CASSANDRA_CONSISTENCY", "LOCAL_QUORUM").upper(),
            cassandra_request_timeout=_env_float("CASSANDRA_REQUEST_TIMEOUT_SECONDS", 30.0),
            cassandra_connect_timeout_seconds=_env_float("CASSANDRA_CONNECT_TIMEOUT_SECONDS", 600.0),
            iceberg_enabled=_env_bool("ICEBERG_ENABLED", True),
            iceberg_warehouse_uri=_env("ICEBERG_WAREHOUSE_URI", ""),
            iceberg_catalog_name=_env("ICEBERG_CATALOG_NAME", "iceberg"),
            iceberg_namespace=_env("ICEBERG_NAMESPACE", "ai_platform"),
            iceberg_table=_env("ICEBERG_TABLE", "triage_results"),
            iceberg_jdbc_uri=_env("ICEBERG_JDBC_URI", ""),
            iceberg_pg_host_port=_env("ICEBERG_PG_HOST_PORT", ""),
            iceberg_pg_database=_env("ICEBERG_PG_DATABASE", "iceberg_catalog"),
            iceberg_pg_user=_env("ICEBERG_PG_USER", "temporal"),
            iceberg_pg_password=_env("ICEBERG_PG_PASSWORD", ""),
            iceberg_pg_sslmode=_env("ICEBERG_PG_SSLMODE", "require"),
            iceberg_fileio_properties=_env("ICEBERG_FILEIO_PROPERTIES", "{}"),
            object_store_region=_env("OBJECT_STORE_REGION", _env("AWS_REGION", "")),
            azure_storage_account=_env("AZURE_STORAGE_ACCOUNT", ""),
            max_concurrent_activities=_env_int("WORKER_MAX_CONCURRENT_ACTIVITIES", 32),
            max_concurrent_workflow_tasks=_env_int("WORKER_MAX_CONCURRENT_WORKFLOW_TASKS", 64),
            max_cached_workflows=_env_int("WORKER_MAX_CACHED_WORKFLOWS", 400),
            graceful_shutdown_seconds=_env_int("WORKER_GRACEFUL_SHUTDOWN_SECONDS", 0),
            bootstrap_on_start=_env_bool("BOOTSTRAP_ON_START", False),
            health_port=_env_int("HEALTH_PORT", 8080),
            metrics_enabled=_env_bool("METRICS_ENABLED", True),
            metrics_port=_env_int("METRICS_PORT", 9090),
            pod_name=_env("POD_NAME", ""),
            log_level=_env("LOG_LEVEL", "INFO").upper(),
        )
        _validate_identifier("CASSANDRA_KEYSPACE", s.cassandra_keyspace)
        _validate_identifier("CASSANDRA_DATACENTER", s.cassandra_datacenter)
        _validate_identifier("ICEBERG_NAMESPACE", s.iceberg_namespace)
        _validate_identifier("ICEBERG_TABLE", s.iceberg_table)
        if s.cassandra_consistency not in ConsistencyLevel.name_to_value:
            raise ValueError(
                f"CASSANDRA_CONSISTENCY {s.cassandra_consistency!r} is not a driver consistency "
                f"level; expected one of {sorted(ConsistencyLevel.name_to_value)}"
            )
        return s


# --------------------------------------------------------------------------------------------
# Payloads. Plain dataclasses, the Temporal default JSON converter round-trips these natively
# in both directions as long as the fields are annotated.
# --------------------------------------------------------------------------------------------


@dataclass
class Document:
    batch_id: str
    doc_id: str
    title: str
    body: str
    source: str = "synthetic"
    tenant: str = "acme"


@dataclass
class Classification:
    batch_id: str
    doc_id: str
    workflow_id: str
    run_id: str
    category: str
    severity: int
    sentiment: str
    summary: str
    action: str
    model: str
    prompt_tokens: int
    completion_tokens: int
    latency_ms: int
    attempt: int
    worker_identity: str
    classified_at: str  # RFC3339 UTC


@dataclass
class TriageRequest:
    batch_id: str
    limit: int = 24
    model: str = ""
    concurrency: int = 8
    write_analytics: bool = True
    synthesize_if_empty: bool = True
    tenant: str = "acme"


@dataclass
class TriageReport:
    batch_id: str
    document_count: int
    succeeded: int
    failed: int
    categories: dict[str, int]
    avg_severity: float
    analytics_uri: str
    started_at: str
    finished_at: str
    cancelled: bool = False


# --------------------------------------------------------------------------------------------
# Synthetic corpus, used by `submit`, by the seed script, and by `load_documents` when the
# Cassandra table has nothing for the requested batch. Deterministic for a given (batch, index).
# --------------------------------------------------------------------------------------------

_TEMPLATES: tuple[tuple[str, str], ...] = (
    (
        "Checkout returns 503 for EU customers",
        "Since the {t} deploy every checkout call from our Frankfurt region returns 503 after "
        "roughly 30 seconds. Our own dashboards show the upstream connection pool saturating. "
        "This is costing us about {n} orders an hour and we need someone on it now.",
    ),
    (
        "Invoice {n} charged twice",
        "Invoice {n} was charged to the card on file twice within the same minute. The customer "
        "has already filed a chargeback. Please refund the duplicate and tell us how a duplicate "
        "capture is even possible on your side.",
    ),
    (
        "Possible credential leak in debug logs",
        "One of our engineers noticed that the {t} debug endpoint echoes the full Authorization "
        "header back into the response body when the request fails validation. We have rotated "
        "our keys but this looks like it affects every tenant, not just us.",
    ),
    (
        "p99 latency tripled after upgrade",
        "After upgrading to the {t} release our p99 read latency went from 40 ms to 130 ms with "
        "identical traffic. p50 is unchanged. We suspect a change to the connection pooling "
        "defaults. Happy to share flame graphs.",
    ),
    (
        "Rows missing after restore",
        "We restored yesterday's snapshot into the staging cluster and roughly {n} rows from the "
        "orders table are simply absent. The snapshot reported SUCCESS. We have not lost "
        "production data yet but we no longer trust the backup.",
    ),
    (
        "Please add a per-namespace rate limit",
        "We would really like to cap request rate per namespace rather than per account. Right "
        "now one noisy internal team can exhaust the whole quota. Not urgent, but it comes up in "
        "every planning meeting.",
    ),
    (
        "Docs for the {t} endpoint are wrong",
        "The reference page for the {t} endpoint still documents the v1 response envelope. The "
        "service actually returns the v2 shape. We lost half a day to this. The changelog does "
        "mention it, but the reference page does not.",
    ),
    (
        "Intermittent TLS handshake failures",
        "About one request in {n} fails the TLS handshake with an unexpected EOF. It clears on "
        "retry so it is not customer visible yet, but the error rate has been climbing all week "
        "and our retry budget is not infinite.",
    ),
    (
        "Cannot delete a stuck workflow",
        "A workflow has been in a running state for {n} hours with no progress and the terminate "
        "call returns 200 but changes nothing. The UI still lists it as running. We would like to "
        "understand whether this is a UI cache or a real stuck execution.",
    ),
    (
        "Billing plan downgrade did not take effect",
        "We downgraded from the enterprise tier on the {t} of last month and the invoice still "
        "shows the enterprise line item. Support ticket {n} has been open for two weeks with no "
        "reply. This is now a finance escalation on our side.",
    ),
)

_TOKENS: tuple[str, ...] = (
    "2026.4",
    "2026.5",
    "gateway",
    "ingest",
    "control-plane",
    "edge",
    "scheduler",
    "17th",
    "3rd",
    "storage",
)


def synthesize_documents(
    batch_id: str, count: int, tenant: str = "acme", start_index: int = 0
) -> list[Document]:
    """Deterministically generate `count` believable support documents for `batch_id`."""
    docs: list[Document] = []
    for i in range(start_index, start_index + count):
        seed = int(hashlib.sha256(f"{batch_id}:{i}".encode()).hexdigest()[:12], 16)
        rnd = random.Random(seed)
        title_tpl, body_tpl = _TEMPLATES[rnd.randrange(len(_TEMPLATES))]
        token = _TOKENS[rnd.randrange(len(_TOKENS))]
        number = rnd.randrange(11, 9999)
        docs.append(
            Document(
                batch_id=batch_id,
                doc_id=f"doc-{i:06d}",
                title=title_tpl.format(t=token, n=number),
                body=body_tpl.format(t=token, n=number),
                source="synthetic",
                tenant=tenant,
            )
        )
    return docs


# --------------------------------------------------------------------------------------------
# Cassandra
# --------------------------------------------------------------------------------------------

_DDL_KEYSPACE = (
    "CREATE KEYSPACE IF NOT EXISTS {ks} WITH replication = "
    "{{'class': 'NetworkTopologyStrategy', '{dc}': {rf}}}"
)

_DDL_DOCUMENTS = """
CREATE TABLE IF NOT EXISTS {ks}.documents (
    batch_id    text,
    doc_id      text,
    tenant      text,
    title       text,
    body        text,
    source      text,
    ingested_at timestamp,
    PRIMARY KEY ((batch_id), doc_id)
) WITH CLUSTERING ORDER BY (doc_id ASC)
"""

_DDL_RESULTS = """
CREATE TABLE IF NOT EXISTS {ks}.triage_results (
    batch_id          text,
    doc_id            text,
    workflow_id       text,
    run_id            text,
    category          text,
    severity          int,
    sentiment         text,
    summary           text,
    action            text,
    model             text,
    prompt_tokens     int,
    completion_tokens int,
    latency_ms        int,
    attempt           int,
    worker_identity   text,
    classified_at     timestamp,
    PRIMARY KEY ((batch_id), doc_id)
) WITH CLUSTERING ORDER BY (doc_id ASC)
"""

# categories is stored as a JSON string, not a CQL map<text,int>: the Trino Cassandra connector
# maps collections to opaque JSON-ish varchar anyway, so a text column is simply honest.
_DDL_SUMMARY = """
CREATE TABLE IF NOT EXISTS {ks}.batch_summary (
    batch_id        text PRIMARY KEY,
    workflow_id     text,
    run_id          text,
    document_count  int,
    succeeded       int,
    failed          int,
    categories_json text,
    avg_severity    double,
    analytics_uri   text,
    cancelled       boolean,
    started_at      timestamp,
    finished_at     timestamp
)
"""

_CQL_INSERT_DOCUMENT = (
    "INSERT INTO {ks}.documents "
    "(batch_id, doc_id, tenant, title, body, source, ingested_at) "
    "VALUES (?, ?, ?, ?, ?, ?, ?)"
)

_CQL_SELECT_DOCUMENTS = (
    "SELECT batch_id, doc_id, tenant, title, body, source FROM {ks}.documents "
    "WHERE batch_id = ? LIMIT ?"
)

_CQL_INSERT_RESULT = (
    "INSERT INTO {ks}.triage_results "
    "(batch_id, doc_id, workflow_id, run_id, category, severity, sentiment, summary, action, "
    " model, prompt_tokens, completion_tokens, latency_ms, attempt, worker_identity, "
    " classified_at) "
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
)

_CQL_INSERT_SUMMARY = (
    "INSERT INTO {ks}.batch_summary "
    "(batch_id, workflow_id, run_id, document_count, succeeded, failed, categories_json, "
    " avg_severity, analytics_uri, cancelled, started_at, finished_at) "
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
)


def _parse_rfc3339(value: str) -> datetime:
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


class CassandraStore:
    """Blocking Cassandra access. Every public method is called via `asyncio.to_thread`."""

    def __init__(self, settings: _Settings) -> None:
        self._s = settings
        self._cluster: Cluster | None = None
        self._session: Session | None = None
        self._prepared: dict[str, Any] | None = None
        self._lock = threading.Lock()

    # -- lifecycle ---------------------------------------------------------------------------

    def connect(self) -> None:
        if self._session is not None:
            return
        with self._lock:
            if self._session is not None:
                return
            hosts = self._s.contact_point_list
            if not hosts:
                raise ValueError("CASSANDRA_CONTACT_POINTS is empty")
            profile = ExecutionProfile(
                load_balancing_policy=TokenAwarePolicy(
                    DCAwareRoundRobinPolicy(local_dc=self._s.cassandra_datacenter)
                ),
                consistency_level=ConsistencyLevel.name_to_value[self._s.cassandra_consistency],
                request_timeout=self._s.cassandra_request_timeout,
                row_factory=dict_factory,
            )
            deadline = time.monotonic() + self._s.cassandra_connect_timeout_seconds
            delay = 2.0
            last: Exception | None = None
            while True:
                cluster = Cluster(
                    contact_points=hosts,
                    port=self._s.cassandra_port,
                    auth_provider=PlainTextAuthProvider(
                        username=self._s.cassandra_username,
                        password=self._s.cassandra_password,
                    ),
                    execution_profiles={EXEC_PROFILE_DEFAULT: profile},
                    connect_timeout=15.0,
                )
                try:
                    self._session = cluster.connect()
                    self._cluster = cluster
                    LOG.info(
                        "connected to Cassandra %s:%s (dc=%s, consistency=%s)",
                        ",".join(hosts),
                        self._s.cassandra_port,
                        self._s.cassandra_datacenter,
                        self._s.cassandra_consistency,
                    )
                    return
                except Exception as exc:  # noqa: BLE001 - retry every startup failure
                    last = exc
                    try:
                        cluster.shutdown()
                    except Exception:  # noqa: BLE001 - best effort
                        pass
                    if time.monotonic() >= deadline:
                        raise RuntimeError(
                            f"could not reach Cassandra at {','.join(hosts)}:{self._s.cassandra_port} "
                            f"within {self._s.cassandra_connect_timeout_seconds:.0f}s: {last}"
                        ) from last
                    LOG.warning("Cassandra not reachable yet (%s); retrying in %.0fs", exc, delay)
                    time.sleep(delay)
                    delay = min(delay * 1.6, 30.0)

    def close(self) -> None:
        with self._lock:
            if self._cluster is not None:
                try:
                    self._cluster.shutdown()
                finally:
                    self._cluster = None
                    self._session = None
                    self._prepared = None

    # -- schema ------------------------------------------------------------------------------

    def bootstrap(self) -> None:
        """Idempotent DDL. Safe to run repeatedly; run it from ONE place to avoid DDL races."""
        self.connect()
        assert self._session is not None
        ks = self._s.cassandra_keyspace
        self._session.execute(
            _DDL_KEYSPACE.format(
                ks=ks,
                dc=self._s.cassandra_datacenter,
                rf=self._s.cassandra_replication_factor,
            )
        )
        for ddl in (_DDL_DOCUMENTS, _DDL_RESULTS, _DDL_SUMMARY):
            self._session.execute(ddl.format(ks=ks))
        LOG.info("Cassandra keyspace %s and tables are present", ks)

    def _stmts(self) -> dict[str, Any]:
        if self._prepared is not None:
            return self._prepared
        with self._lock:
            if self._prepared is None:
                assert self._session is not None
                ks = self._s.cassandra_keyspace
                self._prepared = {
                    "insert_document": self._session.prepare(_CQL_INSERT_DOCUMENT.format(ks=ks)),
                    "select_documents": self._session.prepare(_CQL_SELECT_DOCUMENTS.format(ks=ks)),
                    "insert_result": self._session.prepare(_CQL_INSERT_RESULT.format(ks=ks)),
                    "insert_summary": self._session.prepare(_CQL_INSERT_SUMMARY.format(ks=ks)),
                }
        return self._prepared

    # -- data --------------------------------------------------------------------------------

    def upsert_documents(self, docs: Sequence[Document]) -> int:
        self.connect()
        assert self._session is not None
        stmt = self._stmts()["insert_document"]
        now = datetime.now(timezone.utc)
        params = [
            (d.batch_id, d.doc_id, d.tenant, d.title, d.body, d.source, now) for d in docs
        ]
        results = execute_concurrent_with_args(
            self._session, stmt, params, concurrency=64, raise_on_first_error=True
        )
        return sum(1 for ok, _ in results if ok)

    def load_documents(self, batch_id: str, limit: int) -> list[Document]:
        self.connect()
        assert self._session is not None
        rows = self._session.execute(self._stmts()["select_documents"], (batch_id, limit))
        return [
            Document(
                batch_id=row["batch_id"],
                doc_id=row["doc_id"],
                title=row["title"] or "",
                body=row["body"] or "",
                source=row["source"] or "cassandra",
                tenant=row["tenant"] or "acme",
            )
            for row in rows
        ]

    def insert_classification(self, c: Classification) -> None:
        self.connect()
        assert self._session is not None
        self._session.execute(
            self._stmts()["insert_result"],
            (
                c.batch_id,
                c.doc_id,
                c.workflow_id,
                c.run_id,
                c.category,
                c.severity,
                c.sentiment,
                c.summary,
                c.action,
                c.model,
                c.prompt_tokens,
                c.completion_tokens,
                c.latency_ms,
                c.attempt,
                c.worker_identity,
                _parse_rfc3339(c.classified_at),
            ),
        )

    def insert_classifications(self, rows: Sequence[Classification]) -> int:
        self.connect()
        assert self._session is not None
        stmt = self._stmts()["insert_result"]
        params = [
            (
                c.batch_id,
                c.doc_id,
                c.workflow_id,
                c.run_id,
                c.category,
                c.severity,
                c.sentiment,
                c.summary,
                c.action,
                c.model,
                c.prompt_tokens,
                c.completion_tokens,
                c.latency_ms,
                c.attempt,
                c.worker_identity,
                _parse_rfc3339(c.classified_at),
            )
            for c in rows
        ]
        results = execute_concurrent_with_args(
            self._session, stmt, params, concurrency=64, raise_on_first_error=True
        )
        return sum(1 for ok, _ in results if ok)

    def insert_summary(self, report: TriageReport, workflow_id: str, run_id: str) -> None:
        self.connect()
        assert self._session is not None
        self._session.execute(
            self._stmts()["insert_summary"],
            (
                report.batch_id,
                workflow_id,
                run_id,
                report.document_count,
                report.succeeded,
                report.failed,
                json.dumps(report.categories, sort_keys=True),
                report.avg_severity,
                report.analytics_uri,
                report.cancelled,
                _parse_rfc3339(report.started_at),
                _parse_rfc3339(report.finished_at),
            ),
        )


# --------------------------------------------------------------------------------------------
# Iceberg
# --------------------------------------------------------------------------------------------


def _arrow_schema():
    """Iceberg table shape. Imported lazily: pyarrow is ~1 s of import time."""
    import pyarrow as pa

    return pa.schema(
        [
            pa.field("batch_id", pa.string(), nullable=False),
            pa.field("doc_id", pa.string(), nullable=False),
            pa.field("workflow_id", pa.string(), nullable=True),
            pa.field("run_id", pa.string(), nullable=True),
            pa.field("category", pa.string(), nullable=True),
            pa.field("severity", pa.int32(), nullable=True),
            pa.field("sentiment", pa.string(), nullable=True),
            pa.field("summary", pa.string(), nullable=True),
            pa.field("action", pa.string(), nullable=True),
            pa.field("model", pa.string(), nullable=True),
            pa.field("prompt_tokens", pa.int32(), nullable=True),
            pa.field("completion_tokens", pa.int32(), nullable=True),
            pa.field("latency_ms", pa.int32(), nullable=True),
            pa.field("attempt", pa.int32(), nullable=True),
            pa.field("worker_identity", pa.string(), nullable=True),
            pa.field("classified_at", pa.timestamp("us", tz="UTC"), nullable=True),
        ]
    )


class IcebergWriter:
    """Appends rows to an Iceberg table in a JDBC catalog backed by the visibility Postgres.

    Trino reads the identical catalog with:

        connector.name=iceberg
        iceberg.catalog.type=jdbc
        iceberg.jdbc-catalog.connection-url=jdbc:postgresql://<pg>/iceberg_catalog
        iceberg.jdbc-catalog.catalog-name=<ICEBERG_CATALOG_NAME>
        iceberg.jdbc-catalog.default-warehouse-dir=<ICEBERG_WAREHOUSE_URI>

    Note: PyIceberg's `SqlCatalog` and Trino's JDBC catalog have not been run against
    one another *in this project*. Both implement the same Apache Iceberg `iceberg_tables`
    schema, and `iceberg.jdbc-catalog.catalog-name` must equal `ICEBERG_CATALOG_NAME` for the
    rows to be visible. Confirm with: write one batch, then
    `SELECT * FROM <catalog>.ai_platform.triage_results LIMIT 1` in Trino.
    """

    def __init__(self, settings: _Settings) -> None:
        self._s = settings
        self._catalog = None
        self._table = None
        self._lock = threading.Lock()

    def _file_io_properties(self) -> dict[str, str]:
        props: dict[str, str] = {}
        scheme = self._s.iceberg_warehouse_uri.split("://", 1)[0].lower()
        if scheme in ("s3", "s3a", "s3n") and self._s.object_store_region:
            # `s3.region`; credentials come from the pod's IRSA web-identity token via the
            # AWS SDK default chain inside pyarrow.fs.S3FileSystem.
            props["s3.region"] = self._s.object_store_region
        if scheme in ("abfs", "abfss", "wasb", "wasbs"):
            account = self._s.azure_storage_account
            if not account:
                # abfss://<container>@<account>.dfs.core.windows.net/<path>
                netloc = self._s.iceberg_warehouse_uri.split("://", 1)[-1].split("/", 1)[0]
                if "@" in netloc:
                    account = netloc.split("@", 1)[1].split(".", 1)[0]
            if account:
                props["adls.account-name"] = account
        extra = json.loads(self._s.iceberg_fileio_properties or "{}")
        if not isinstance(extra, dict):
            raise ValueError("ICEBERG_FILEIO_PROPERTIES must be a JSON object")
        props.update({str(k): str(v) for k, v in extra.items()})
        return props

    def _ensure(self):
        if self._table is not None:
            return self._table
        with self._lock:
            if self._table is not None:
                return self._table
            from pyiceberg.catalog.sql import SqlCatalog

            if not self._s.iceberg_warehouse_uri:
                raise ValueError("ICEBERG_ENABLED is true but ICEBERG_WAREHOUSE_URI is empty")
            warehouse = self._s.iceberg_warehouse_uri.rstrip("/")
            props: dict[str, str] = {
                "uri": self._s.sqlalchemy_uri,
                "warehouse": warehouse,
                "init_catalog_tables": "true",
            }
            props.update(self._file_io_properties())
            catalog = SqlCatalog(self._s.iceberg_catalog_name, **props)
            catalog.create_namespace_if_not_exists(self._s.iceberg_namespace)
            identifier = (self._s.iceberg_namespace, self._s.iceberg_table)
            self._table = catalog.create_table_if_not_exists(
                identifier=identifier,
                schema=_arrow_schema(),
                location=f"{warehouse}/{self._s.iceberg_namespace}/{self._s.iceberg_table}",
                properties={"write.parquet.compression-codec": "zstd"},
            )
            self._catalog = catalog
            LOG.info(
                "Iceberg table %s.%s ready at %s",
                self._s.iceberg_namespace,
                self._s.iceberg_table,
                self._table.location(),
            )
        return self._table

    def bootstrap(self) -> str:
        return self._ensure().location()

    def append(self, rows: Sequence[Classification], snapshot_properties: dict[str, str]) -> str:
        import pyarrow as pa

        table = self._ensure()
        schema = _arrow_schema()
        records = [
            {
                "batch_id": c.batch_id,
                "doc_id": c.doc_id,
                "workflow_id": c.workflow_id,
                "run_id": c.run_id,
                "category": c.category,
                "severity": int(c.severity),
                "sentiment": c.sentiment,
                "summary": c.summary,
                "action": c.action,
                "model": c.model,
                "prompt_tokens": int(c.prompt_tokens),
                "completion_tokens": int(c.completion_tokens),
                "latency_ms": int(c.latency_ms),
                "attempt": int(c.attempt),
                "worker_identity": c.worker_identity,
                "classified_at": _parse_rfc3339(c.classified_at),
            }
            for c in rows
        ]
        table.append(pa.Table.from_pylist(records, schema=schema), snapshot_properties=snapshot_properties)
        return table.location()


# --------------------------------------------------------------------------------------------
# LLM output parsing
# --------------------------------------------------------------------------------------------


def _clamp_choice(value: Any, allowed: Iterable[str], fallback: str) -> str:
    text = str(value or "").strip().lower().replace(" ", "_").replace("-", "_")
    allowed_set = set(allowed)
    if text in allowed_set:
        return text
    for candidate in allowed_set:
        if candidate in text:
            return candidate
    return fallback


def parse_classification_json(raw: str) -> dict[str, Any]:
    """Tolerantly extract the classification object from a chat completion.

    Handles: a bare JSON object, a ```json fence, a Qwen-style `<think>...</think>` preamble,
    and trailing prose. Raises ValueError if there is no object at all, which is *retryable*,
    because a second sample from the same model usually is well-formed.
    """
    text = _THINK_RE.sub("", raw or "").strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:]
        text = text.strip()
    try:
        obj = json.loads(text)
    except json.JSONDecodeError:
        match = _JSON_RE.search(text)
        if not match:
            raise ValueError(f"no JSON object in model output: {raw[:200]!r}")
        obj = json.loads(match.group(0))
    if not isinstance(obj, dict):
        raise ValueError(f"model output was not a JSON object: {raw[:200]!r}")

    try:
        severity = int(float(obj.get("severity", 3)))
    except (TypeError, ValueError):
        severity = 3
    summary = str(obj.get("summary", "") or "").strip()[:240]
    return {
        "category": _clamp_choice(obj.get("category"), CATEGORIES, "other"),
        "severity": max(1, min(5, severity)),
        "sentiment": _clamp_choice(obj.get("sentiment"), SENTIMENTS, "neutral"),
        "summary": summary or "(model returned no summary)",
        "action": _clamp_choice(obj.get("action"), ACTIONS, "no_action"),
    }


def stub_classification(doc: Document) -> tuple[dict[str, Any], int, int]:
    """Deterministic pseudo-LLM used by the seed loader (`LLM_STUB=true`).

    It is a real classifier in the sense that it is a pure function of the document, so seeded
    Cassandra rows and seeded Iceberg rows agree with each other and re-running the seed is a
    no-op. It is not a real classifier in the sense that no inference happens. The seed README
    says so explicitly, and nothing in the default path uses it.
    """
    digest = hashlib.sha256(f"{doc.batch_id}/{doc.doc_id}/{doc.title}".encode()).digest()
    category = CATEGORIES[digest[0] % len(CATEGORIES)]
    severity = 1 + (digest[1] % 5)
    sentiment = SENTIMENTS[digest[2] % len(SENTIMENTS)]
    action = ACTIONS[digest[3] % len(ACTIONS)]
    if category in ("outage", "data_loss") and severity >= 4:
        action = "page_oncall"
    elif category == "security":
        action = "escalate_security"
    first_sentence = doc.body.split(". ")[0].strip()
    summary = f"{doc.title.strip()}, {first_sentence}"[:240]
    prompt_tokens = 120 + (len(doc.body) // 4)
    completion_tokens = 40 + (digest[4] % 60)
    return (
        {
            "category": category,
            "severity": severity,
            "sentiment": sentiment,
            "summary": summary,
            "action": action,
        },
        prompt_tokens,
        completion_tokens,
    )


# --------------------------------------------------------------------------------------------
# Activities
# --------------------------------------------------------------------------------------------

ACTIVITY_LOAD_DOCUMENTS = "load_documents"
ACTIVITY_CLASSIFY_DOCUMENT = "classify_document"
ACTIVITY_PERSIST_CLASSIFICATION = "persist_classification"
ACTIVITY_WRITE_ANALYTICS = "write_analytics_batch"
ACTIVITY_FINALIZE_BATCH = "finalize_batch"


class TriageActivities:
    """Holds the long-lived Cassandra session, OpenAI client and Iceberg catalog handle."""

    def __init__(self, settings: _Settings) -> None:
        self.s = settings
        self.store = CassandraStore(settings)
        self.iceberg = IcebergWriter(settings)
        self._llm: openai.AsyncOpenAI | None = None

    @property
    def llm(self) -> "openai.AsyncOpenAI":
        if self._llm is None:
            self._llm = openai.AsyncOpenAI(
                base_url=self.s.llm_base_url,
                api_key=self.s.llm_api_key or "EMPTY",
                timeout=self.s.llm_timeout_seconds,
                max_retries=0,  # Temporal owns retry policy; do not double-retry underneath it.
            )
        return self._llm

    async def start(self) -> None:
        await asyncio.to_thread(self.store.connect)
        if self.s.bootstrap_on_start:
            await asyncio.to_thread(self.store.bootstrap)

    async def close(self) -> None:
        await asyncio.to_thread(self.store.close)
        if self._llm is not None:
            await self._llm.close()
            self._llm = None

    def registrations(self) -> list[Any]:
        return [
            self.load_documents,
            self.classify_document,
            self.persist_classification,
            self.write_analytics_batch,
            self.finalize_batch,
        ]

    # -- activity: load ----------------------------------------------------------------------

    @activity.defn(name=ACTIVITY_LOAD_DOCUMENTS)
    async def load_documents(self, req: TriageRequest) -> list[Document]:
        limit = max(1, min(req.limit, 1000))
        docs = await asyncio.to_thread(self.store.load_documents, req.batch_id, limit)
        if docs:
            activity.logger.info("loaded %d documents for batch %s", len(docs), req.batch_id)
            return docs
        if not req.synthesize_if_empty:
            return []
        docs = synthesize_documents(req.batch_id, limit, tenant=req.tenant)
        await asyncio.to_thread(self.store.upsert_documents, docs)
        activity.logger.info(
            "batch %s was empty; synthesised and stored %d documents", req.batch_id, len(docs)
        )
        return docs

    # -- activity: classify ------------------------------------------------------------------

    async def _heartbeat(self, detail: str) -> None:
        try:
            while True:
                activity.heartbeat(detail)
                await asyncio.sleep(5)
        except asyncio.CancelledError:
            return

    @activity.defn(name=ACTIVITY_CLASSIFY_DOCUMENT)
    async def classify_document(self, doc: Document, model: str) -> Classification:
        info = activity.info()
        if not (doc.body or "").strip():
            # No number of retries fixes an empty document, fail it permanently.
            raise ApplicationError(
                f"document {doc.doc_id} has an empty body",
                type=MalformedDocument.__name__,
                non_retryable=True,
            )
        model = model or self.s.llm_model
        started = time.monotonic()
        heart = asyncio.create_task(self._heartbeat(f"classifying {doc.doc_id}"))
        try:
            if self.s.llm_stub:
                if self.s.llm_stub_latency_ms > 0:
                    await asyncio.sleep(self.s.llm_stub_latency_ms / 1000.0)
                fields, prompt_tokens, completion_tokens = stub_classification(doc)
            else:
                kwargs: dict[str, Any] = {
                    "model": model,
                    "messages": [
                        {"role": "system", "content": SYSTEM_PROMPT},
                        {
                            "role": "user",
                            "content": (
                                f"Document id: {doc.doc_id}\n"
                                f"Tenant: {doc.tenant}\n"
                                f"Title: {doc.title}\n\n"
                                f"{doc.body}"
                            ),
                        },
                    ],
                    "temperature": self.s.llm_temperature,
                    "max_tokens": self.s.llm_max_tokens,
                }
                if self.s.llm_json_mode:
                    # vLLM implements this with its structured-outputs backend.
                    kwargs["response_format"] = {"type": "json_object"}
                if self.s.llm_disable_thinking:
                    # vLLM-specific passthrough for Qwen-style hybrid-reasoning chat templates.
                    kwargs["extra_body"] = {"chat_template_kwargs": {"enable_thinking": False}}
                response = await self.llm.chat.completions.create(**kwargs)
                content = (response.choices[0].message.content or "") if response.choices else ""
                fields = parse_classification_json(content)
                usage = getattr(response, "usage", None)
                prompt_tokens = int(getattr(usage, "prompt_tokens", 0) or 0)
                completion_tokens = int(getattr(usage, "completion_tokens", 0) or 0)
        finally:
            heart.cancel()

        latency_ms = int((time.monotonic() - started) * 1000)
        return Classification(
            batch_id=doc.batch_id,
            doc_id=doc.doc_id,
            workflow_id=info.workflow_id,
            run_id=info.workflow_run_id,
            category=fields["category"],
            severity=fields["severity"],
            sentiment=fields["sentiment"],
            summary=fields["summary"],
            action=fields["action"],
            model=model,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            latency_ms=latency_ms,
            attempt=info.attempt,
            worker_identity=self.s.identity,
            classified_at=datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        )

    # -- activity: persist -------------------------------------------------------------------

    @activity.defn(name=ACTIVITY_PERSIST_CLASSIFICATION)
    async def persist_classification(self, c: Classification) -> None:
        await asyncio.to_thread(self.store.insert_classification, c)

    # -- activity: analytics -----------------------------------------------------------------

    @activity.defn(name=ACTIVITY_WRITE_ANALYTICS)
    async def write_analytics_batch(self, batch_id: str, rows: list[Classification]) -> str:
        if not self.s.iceberg_enabled:
            activity.logger.info("ICEBERG_ENABLED=false; skipping analytics write")
            return ""
        if not rows:
            return ""
        info = activity.info()
        props = {
            "batch-id": batch_id,
            "temporal-workflow-id": info.workflow_id,
            "temporal-run-id": info.workflow_run_id,
            "worker-identity": self.s.identity,
        }
        location = await asyncio.to_thread(self.iceberg.append, rows, props)
        activity.logger.info("appended %d rows to %s", len(rows), location)
        return location

    # -- activity: finalize ------------------------------------------------------------------

    @activity.defn(name=ACTIVITY_FINALIZE_BATCH)
    async def finalize_batch(self, report: TriageReport) -> None:
        info = activity.info()
        await asyncio.to_thread(
            self.store.insert_summary, report, info.workflow_id, info.workflow_run_id
        )


# --------------------------------------------------------------------------------------------
# Workflow
# --------------------------------------------------------------------------------------------

_LOAD_RETRY = RetryPolicy(
    initial_interval=timedelta(seconds=1),
    backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=30),
    maximum_attempts=8,
)

# The interesting one: six attempts with jittered exponential backoff, and a permanent failure
# for input that can never succeed. This is the policy the demo points at.
_CLASSIFY_RETRY = RetryPolicy(
    initial_interval=timedelta(seconds=2),
    backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=30),
    maximum_attempts=6,
    non_retryable_error_types=[MalformedDocument.__name__],
)

_WRITE_RETRY = RetryPolicy(
    initial_interval=timedelta(seconds=2),
    backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=60),
    maximum_attempts=10,
)


@workflow.defn(name="DocumentTriageWorkflow")
class DocumentTriageWorkflow:
    def __init__(self) -> None:
        self._phase = "starting"
        self._total = 0
        self._completed = 0
        self._failed = 0
        self._cancel_requested = False

    # -- queries and signals, so the Temporal UI is interactive during the demo ---------------

    @workflow.query(name="progress")
    def progress(self) -> dict[str, Any]:
        return {
            "phase": self._phase,
            "total": self._total,
            "completed": self._completed,
            "failed": self._failed,
            "cancel_requested": self._cancel_requested,
        }

    @workflow.signal(name="cancel_remaining")
    def cancel_remaining(self) -> None:
        """Stop dispatching new documents but still finalise what is already done."""
        self._cancel_requested = True

    @workflow.run
    async def run(self, req: TriageRequest) -> TriageReport:
        started_at = workflow.now().astimezone(timezone.utc)
        self._phase = "loading"

        documents: list[Document] = await workflow.execute_activity(
            ACTIVITY_LOAD_DOCUMENTS,
            req,
            result_type=list[Document],
            start_to_close_timeout=timedelta(seconds=120),
            retry_policy=_LOAD_RETRY,
            summary=f"load batch {req.batch_id}",
        )
        self._total = len(documents)
        self._phase = "classifying"

        model = req.model or ""
        chunk_size = max(1, min(req.concurrency, 32))
        results: list[Classification] = []

        for offset in range(0, len(documents), chunk_size):
            if self._cancel_requested:
                workflow.logger.info("cancel_remaining received; stopping dispatch")
                break
            chunk = documents[offset : offset + chunk_size]
            outcomes = await asyncio.gather(
                *(self._triage_one(doc, model) for doc in chunk),
                return_exceptions=True,
            )
            for doc, outcome in zip(chunk, outcomes):
                if isinstance(outcome, BaseException):
                    self._failed += 1
                    workflow.logger.warning(
                        "document %s exhausted its retries: %s", doc.doc_id, outcome
                    )
                else:
                    self._completed += 1
                    results.append(outcome)

        self._phase = "analytics"
        analytics_uri = ""
        if req.write_analytics and results:
            analytics_uri = await workflow.execute_activity(
                ACTIVITY_WRITE_ANALYTICS,
                args=[req.batch_id, results],
                result_type=str,
                start_to_close_timeout=timedelta(minutes=10),
                retry_policy=_WRITE_RETRY,
                summary=f"append {len(results)} rows to Iceberg",
            )

        categories: dict[str, int] = {}
        severity_total = 0
        for c in results:
            categories[c.category] = categories.get(c.category, 0) + 1
            severity_total += c.severity
        avg_severity = round(severity_total / len(results), 3) if results else 0.0

        report = TriageReport(
            batch_id=req.batch_id,
            document_count=self._total,
            succeeded=len(results),
            failed=self._failed,
            categories=dict(sorted(categories.items())),
            avg_severity=avg_severity,
            analytics_uri=analytics_uri,
            started_at=started_at.isoformat(timespec="milliseconds"),
            finished_at=workflow.now().astimezone(timezone.utc).isoformat(timespec="milliseconds"),
            cancelled=self._cancel_requested,
        )

        self._phase = "finalizing"
        await workflow.execute_activity(
            ACTIVITY_FINALIZE_BATCH,
            report,
            start_to_close_timeout=timedelta(seconds=120),
            retry_policy=_WRITE_RETRY,
            summary=f"write batch_summary for {req.batch_id}",
        )
        self._phase = "done"
        return report

    async def _triage_one(self, doc: Document, model: str) -> Classification:
        """One document = one LLM activity + one Cassandra activity.

        Both are scheduled, retried and completed independently in the event history. That is
        the whole point: replay after a worker loss re-runs neither of them for the documents
        that already finished.
        """
        classification: Classification = await workflow.execute_activity(
            ACTIVITY_CLASSIFY_DOCUMENT,
            args=[doc, model],
            result_type=Classification,
            start_to_close_timeout=timedelta(seconds=180),
            heartbeat_timeout=timedelta(seconds=30),
            schedule_to_close_timeout=timedelta(minutes=20),
            retry_policy=_CLASSIFY_RETRY,
            summary=f"LLM triage {doc.doc_id}",
        )
        await workflow.execute_activity(
            ACTIVITY_PERSIST_CLASSIFICATION,
            classification,
            start_to_close_timeout=timedelta(seconds=60),
            retry_policy=_WRITE_RETRY,
            summary=f"Cassandra write {doc.doc_id}",
        )
        return classification


# --------------------------------------------------------------------------------------------
# Health endpoint, plain asyncio, no extra dependency. Backs the k8s probes.
# --------------------------------------------------------------------------------------------


async def _serve_health(port: int, state: dict[str, Any]) -> asyncio.AbstractServer:
    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            try:
                head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=5)
            except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError):
                return
            request_line = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
            parts = request_line.split(" ")
            path = parts[1] if len(parts) > 1 else "/"
            ready = bool(state.get("ready"))
            if path.startswith("/readyz"):
                status, body = ("200 OK" if ready else "503 Service Unavailable"), dict(state)
            elif path.startswith("/healthz") or path == "/":
                status, body = "200 OK", dict(state)
            else:
                status, body = "404 Not Found", {"error": "not found"}
            payload = json.dumps(body, default=str).encode()
            writer.write(
                f"HTTP/1.1 {status}\r\nContent-Type: application/json\r\n"
                f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode()
                + payload
            )
            await writer.drain()
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, asyncio.CancelledError):
                pass

    server = await asyncio.start_server(handle, host="0.0.0.0", port=port)
    LOG.info("health endpoint listening on :%d (/healthz, /readyz)", port)
    return server


# --------------------------------------------------------------------------------------------
# Client / worker wiring
# --------------------------------------------------------------------------------------------


def _build_runtime(settings: _Settings) -> Runtime | None:
    if not settings.metrics_enabled:
        return None
    return Runtime(
        telemetry=TelemetryConfig(
            metrics=PrometheusConfig(bind_address=f"0.0.0.0:{settings.metrics_port}"),
            global_tags={"service": "ai-worker"},
        )
    )


async def connect_client(settings: _Settings, runtime: Runtime | None = None) -> Client:
    tls: bool | TLSConfig = TLSConfig() if settings.temporal_tls else False
    return await Client.connect(
        settings.temporal_address,
        namespace=settings.temporal_namespace,
        tls=tls,
        api_key=settings.temporal_api_key or None,
        runtime=runtime,
        identity=settings.identity,
    )


def configure_logging(settings: _Settings) -> None:
    logging.basicConfig(
        level=getattr(logging, settings.log_level, logging.INFO),
        format="%(asctime)s %(levelname)-5s %(name)s %(message)s",
        stream=sys.stdout,
    )
    logging.getLogger("cassandra").setLevel(logging.WARNING)
    logging.getLogger("httpx").setLevel(logging.WARNING)


async def run_worker(settings: _Settings) -> None:
    configure_logging(settings)
    state: dict[str, Any] = {
        "ready": False,
        "identity": settings.identity,
        "task_queue": settings.temporal_task_queue,
        "namespace": settings.temporal_namespace,
        "model": settings.llm_model,
        "llm_stub": settings.llm_stub,
    }
    health = await _serve_health(settings.health_port, state)

    activities = TriageActivities(settings)
    await activities.start()

    runtime = _build_runtime(settings)
    client = await connect_client(settings, runtime)
    LOG.info(
        "connected to Temporal %s ns=%s queue=%s",
        settings.temporal_address,
        settings.temporal_namespace,
        settings.temporal_task_queue,
    )

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:  # pragma: no cover - non-POSIX
            pass

    worker = Worker(
        client,
        task_queue=settings.temporal_task_queue,
        workflows=[DocumentTriageWorkflow],
        activities=activities.registrations(),
        identity=settings.identity,
        max_concurrent_activities=settings.max_concurrent_activities,
        max_concurrent_workflow_tasks=settings.max_concurrent_workflow_tasks,
        max_cached_workflows=settings.max_cached_workflows,
        graceful_shutdown_timeout=timedelta(seconds=settings.graceful_shutdown_seconds),
    )

    try:
        async with worker:
            state["ready"] = True
            LOG.info("worker running; waiting for shutdown signal")
            await stop.wait()
            state["ready"] = False
            LOG.info("shutdown signal received; draining worker")
    finally:
        health.close()
        await health.wait_closed()
        await activities.close()
        LOG.info("worker stopped")


async def run_bootstrap(settings: _Settings, skip_iceberg: bool) -> None:
    configure_logging(settings)
    store = CassandraStore(settings)
    try:
        await asyncio.to_thread(store.bootstrap)
    finally:
        await asyncio.to_thread(store.close)
    if settings.iceberg_enabled and not skip_iceberg:
        writer = IcebergWriter(settings)
        location = await asyncio.to_thread(writer.bootstrap)
        LOG.info("Iceberg warehouse ready at %s", location)
    else:
        LOG.info("Iceberg bootstrap skipped")


async def run_submit(
    settings: _Settings,
    count: int,
    docs_per_workflow: int,
    concurrency: int,
    prefix: str,
    wait: bool,
) -> None:
    configure_logging(settings)
    client = await connect_client(settings)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    handles = []
    for i in range(count):
        batch_id = f"{prefix}-{stamp}-{i:04d}"
        handle = await client.start_workflow(
            DocumentTriageWorkflow.run,
            TriageRequest(
                batch_id=batch_id,
                limit=docs_per_workflow,
                model=settings.llm_model,
                concurrency=concurrency,
                write_analytics=True,
            ),
            id=f"triage-{batch_id}",
            task_queue=settings.temporal_task_queue,
            id_reuse_policy=WorkflowIDReusePolicy.REJECT_DUPLICATE,
            memo={"batch_id": batch_id, "documents": docs_per_workflow, "source": "submit"},
        )
        handles.append(handle)
        print(f"started {handle.id}")
    if wait:
        for handle in handles:
            report = await handle.result()
            print(
                f"{handle.id}: {report.succeeded}/{report.document_count} ok, "
                f"{report.failed} failed, analytics={report.analytics_uri or '-'}"
            )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ai-worker", description="Durable AI Platform Temporal worker"
    )
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("worker", help="run the Temporal worker (default)")

    boot = sub.add_parser("bootstrap", help="create Cassandra keyspace/tables and Iceberg table")
    boot.add_argument("--skip-iceberg", action="store_true")

    submit = sub.add_parser("submit", help="start demo triage workflows")
    submit.add_argument("--count", type=int, default=1)
    submit.add_argument("--docs", type=int, default=24, dest="docs_per_workflow")
    submit.add_argument("--concurrency", type=int, default=8)
    submit.add_argument("--prefix", default="demo")
    submit.add_argument("--wait", action="store_true")

    return parser


def cli(argv: Sequence[str] | None = None) -> int:
    args = build_arg_parser().parse_args(list(argv) if argv is not None else None)
    settings = _Settings.from_env()
    command = args.command or "worker"
    if command == "worker":
        asyncio.run(run_worker(settings))
    elif command == "bootstrap":
        asyncio.run(run_bootstrap(settings, skip_iceberg=args.skip_iceberg))
    elif command == "submit":
        asyncio.run(
            run_submit(
                settings,
                count=args.count,
                docs_per_workflow=args.docs_per_workflow,
                concurrency=args.concurrency,
                prefix=args.prefix,
                wait=args.wait,
            )
        )
    else:  # pragma: no cover - argparse rejects anything else
        raise SystemExit(f"unknown command {command!r}")
    return 0
