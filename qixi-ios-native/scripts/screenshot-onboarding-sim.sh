#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCREENSHOT_PATH="${1:-$NATIVE_DIR/artifacts/screenshots/latest-ipad-onboarding.png}"

QIXI_SKIP_ONBOARDING=0 \
QIXI_APP_LANGUAGE="${QIXI_APP_LANGUAGE:-en}" \
  "$SCRIPT_DIR/screenshot-sim.sh" "$SCREENSHOT_PATH"

python3 "$NATIVE_DIR/tests/inspect_onboarding_screenshot.py" "$SCREENSHOT_PATH"
