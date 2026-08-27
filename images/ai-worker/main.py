#!/usr/bin/env python3
"""Container entry point for the Durable AI Platform Temporal worker.

This file exists so that `worker.py` is never the `__main__` module.

The Temporal Python SDK runs workflow code inside a sandbox that **re-imports the module the
workflow class was defined in** for every workflow instance. A module executed as `__main__`
cannot be re-imported under its real name without running its top-level code a second time,
which is how you get `Workflow class DocumentTriageWorkflow is already registered` and
subtly-duplicated activity registrations. Keeping the process entry point in a separate,
import-free module makes `worker` a normal, idempotently-importable module.

    python main.py worker             # run the Temporal worker (the image's default CMD)
    python main.py bootstrap          # create the Cassandra keyspace/tables + the Iceberg table
    python main.py submit --count 5   # start demo triage workflows

All configuration is environment variables; see `worker._Settings.from_env` and the Helm
chart's `values.yaml`.
"""

from __future__ import annotations

import sys

from worker import cli

if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
