#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

for language in zh-Hans zh-Hant en; do
  for engine in b6 b18nbt b28nbt; do
    screenshot="$NATIVE_DIR/artifacts/screenshots/latest-ipad-engine-$engine-$language.png"
    QIXI_APP_LANGUAGE="$language" \
    QIXI_AUTOMATION_SELECT_ENGINE="$engine" \
    QIXI_SKIP_ONBOARDING=1 \
      "$SCRIPT_DIR/screenshot-sim.sh" "$screenshot"
    python3 "$NATIVE_DIR/tests/inspect_screenshot.py" "$screenshot"
  done
done
