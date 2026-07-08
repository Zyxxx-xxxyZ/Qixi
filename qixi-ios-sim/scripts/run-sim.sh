#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT_DIR/backend/qixi_backend.py" --host "${QIXI_SIM_HOST:-0.0.0.0}" --port "${QIXI_SIM_PORT:-8765}"
