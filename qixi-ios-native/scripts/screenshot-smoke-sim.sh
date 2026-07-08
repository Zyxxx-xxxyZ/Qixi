#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCREENSHOT_DIR="$NATIVE_DIR/artifacts/screenshots"

QIXI_APP_LANGUAGE="${QIXI_APP_LANGUAGE:-zh-Hans}" \
QIXI_SKIP_ONBOARDING="${QIXI_SKIP_ONBOARDING:-1}" \
  "$SCRIPT_DIR/screenshot-sim.sh" "$SCREENSHOT_DIR/latest-ipad-smoke.png"
python3 "$NATIVE_DIR/tests/inspect_screenshot.py" "$SCREENSHOT_DIR/latest-ipad-smoke.png"

QIXI_APP_LANGUAGE="${QIXI_APP_LANGUAGE:-zh-Hans}" \
QIXI_SKIP_ONBOARDING="${QIXI_SKIP_ONBOARDING:-1}" \
  "$SCRIPT_DIR/screenshot-iphone-sim.sh" "$SCREENSHOT_DIR/latest-iphone-smoke.png"

"$SCRIPT_DIR/performance-smoke-sim.sh"

echo "Native simulator screenshot smoke passed"
