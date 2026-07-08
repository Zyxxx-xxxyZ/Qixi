#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

for language in zh-Hans zh-Hant en; do
  for error in library-not-linked model-missing insufficient-memory local-network-denied; do
    screenshot="$NATIVE_DIR/artifacts/screenshots/latest-iphone-engine-error-$error-$language.png"
    QIXI_APP_LANGUAGE="$language" \
      QIXI_ENGINE_ERROR="$error" \
      "$SCRIPT_DIR/screenshot-iphone-sim.sh" "$screenshot"
    python3 "$NATIVE_DIR/tests/inspect_engine_error_screenshot.py" "$screenshot" "$error"
  done
done
