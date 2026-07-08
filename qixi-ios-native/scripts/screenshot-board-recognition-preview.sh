#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

for language in zh-Hans zh-Hant en; do
  screenshot="$NATIVE_DIR/artifacts/screenshots/latest-ipad-board-recognition-preview-$language.png"
  QIXI_APP_LANGUAGE="$language" \
    QIXI_ANALYSIS_FIXTURE=board-recognition-preview \
    "$SCRIPT_DIR/screenshot-sim.sh" "$screenshot"
  python3 "$NATIVE_DIR/tests/inspect_board_recognition_preview_screenshot.py" "$screenshot"
done
