#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KATAGO_BIN="${KATAGO_BIN:-$ROOT/KataGo/cpp/build-persistent-mcts/katago}"

python3 "$ROOT/scripts/qixi_persistent_mcts_architecture_audit.py"
python_status=$?

if [[ ! -x "$KATAGO_BIN" ]]; then
  echo "Missing KataGo executable for C++ audit: $KATAGO_BIN" >&2
  echo "Build it first, for example: cmake --build '$ROOT/KataGo/cpp/build-persistent-mcts' --target katago" >&2
  cxx_status=2
else
  "$KATAGO_BIN" runpersistentmctsaudittests
  cxx_status=$?
fi

if [[ "$python_status" -ne 0 || "$cxx_status" -ne 0 ]]; then
  echo "Persistent MCTS audit failed: architecture_status=$python_status cxx_status=$cxx_status" >&2
  exit 1
fi

echo "Persistent MCTS audit passed."
