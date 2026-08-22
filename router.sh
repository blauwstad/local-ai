#!/bin/bash
# Model router on :8090 — advertises both builds, swaps the engine on demand.
# The engine (:8081) serves one model at a time; this makes that switchable from a UI.
set -euo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate
mkdir -p logs
exec .venv/bin/python router.py
