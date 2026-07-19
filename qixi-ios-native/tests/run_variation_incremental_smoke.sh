#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${TMPDIR:-/tmp}/qixi-variation-incremental-smoke"

swiftc \
  "$NATIVE_DIR/Qixi/L10n.swift" \
  "$NATIVE_DIR/Qixi/QixiModels.swift" \
  "$NATIVE_DIR/Qixi/CandidatePalette.swift" \
  "$NATIVE_DIR/Qixi/QixiAnalyzeDisplay.swift" \
  "$SCRIPT_DIR/variation_incremental_smoke_shims.swift" \
  "$NATIVE_DIR/Qixi/QixiAnalysisService.swift" \
  "$NATIVE_DIR/Qixi/QixiVariationModel.swift" \
  "$SCRIPT_DIR/variation_incremental_smoke.swift" \
  -o "$OUT"

"$OUT"
