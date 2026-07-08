#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${TMPDIR:-/tmp}/qixi-sgf-parser-smoke"

swiftc \
  "$NATIVE_DIR/Qixi/L10n.swift" \
  "$NATIVE_DIR/Qixi/QixiModels.swift" \
  "$NATIVE_DIR/Qixi/QixiSGFParser.swift" \
  "$SCRIPT_DIR/sgf_parser_smoke.swift" \
  -o "$OUT"

"$OUT"
