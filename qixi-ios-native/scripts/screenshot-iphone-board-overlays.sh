#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVICE="${QIXI_IPHONE_SIM_DEVICE:-iPhone 17 Pro Max}"

for language in zh-Hans zh-Hant en; do
  screenshot="$NATIVE_DIR/artifacts/screenshots/latest-iphone-board-overlays-$language.png"
  QIXI_APP_LANGUAGE="$language" \
    QIXI_SIM_DEVICE="$DEVICE" \
    QIXI_SCREENSHOT_AUTO_ROTATE=1 \
    QIXI_ANALYSIS_FIXTURE=board-overlays \
    QIXI_SHOW_TERRITORY=1 \
    "$SCRIPT_DIR/screenshot-sim.sh" "$screenshot"
  python3 "$NATIVE_DIR/tests/inspect_board_overlay_screenshot.py" "$screenshot"
done
