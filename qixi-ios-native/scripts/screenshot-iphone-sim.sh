#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVICE="${QIXI_IPHONE_SIM_DEVICE:-iPhone 17 Pro Max}"
SCREENSHOT_PATH="${1:-$NATIVE_DIR/artifacts/screenshots/latest-iphone.png}"

QIXI_SIM_DEVICE="$DEVICE" \
  QIXI_APP_LANGUAGE="${QIXI_APP_LANGUAGE:-zh-Hans}" \
  QIXI_SKIP_ONBOARDING="${QIXI_SKIP_ONBOARDING:-1}" \
  QIXI_SCREENSHOT_AUTO_ROTATE=1 \
  "$SCRIPT_DIR/screenshot-sim.sh" "$SCREENSHOT_PATH"

python3 "$NATIVE_DIR/tests/inspect_screenshot.py" "$SCREENSHOT_PATH"
