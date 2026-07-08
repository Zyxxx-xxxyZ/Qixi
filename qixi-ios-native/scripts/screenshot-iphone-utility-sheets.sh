#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVICE="${QIXI_IPHONE_SIM_DEVICE:-iPhone 17 Pro Max}"

for language in zh-Hans zh-Hant en; do
  for sheet in camera import; do
    screenshot="$NATIVE_DIR/artifacts/screenshots/latest-iphone-$sheet-sheet-$language.png"
    QIXI_APP_LANGUAGE="$language" \
      QIXI_SIM_DEVICE="$DEVICE" \
      QIXI_SCREENSHOT_AUTO_ROTATE=1 \
      QIXI_OPEN_UTILITY_SHEET="$sheet" \
      "$SCRIPT_DIR/screenshot-sim.sh" "$screenshot"
    python3 "$NATIVE_DIR/tests/inspect_utility_sheet_screenshot.py" "$screenshot"
  done

  disabled_screenshot="$NATIVE_DIR/artifacts/screenshots/latest-iphone-sync-sheet-$language.png"
  QIXI_APP_LANGUAGE="$language" \
    QIXI_SIM_DEVICE="$DEVICE" \
    QIXI_SCREENSHOT_AUTO_ROTATE=1 \
    QIXI_OPEN_UTILITY_SHEET=sync \
    QIXI_ICLOUD_SYNC_ENABLED=0 \
    "$SCRIPT_DIR/screenshot-sim.sh" "$disabled_screenshot"
  python3 "$NATIVE_DIR/tests/inspect_utility_sheet_screenshot.py" "$disabled_screenshot" disabled

  enabled_screenshot="$NATIVE_DIR/artifacts/screenshots/latest-iphone-sync-enabled-sheet-$language.png"
  QIXI_APP_LANGUAGE="$language" \
    QIXI_SIM_DEVICE="$DEVICE" \
    QIXI_SCREENSHOT_AUTO_ROTATE=1 \
    QIXI_OPEN_UTILITY_SHEET=sync \
    QIXI_ICLOUD_SYNC_ENABLED=1 \
    "$SCRIPT_DIR/screenshot-sim.sh" "$enabled_screenshot"
  python3 "$NATIVE_DIR/tests/inspect_utility_sheet_screenshot.py" "$enabled_screenshot" enabled

  for status in synced error conflict; do
    status_screenshot="$NATIVE_DIR/artifacts/screenshots/latest-iphone-sync-$status-sheet-$language.png"
    QIXI_APP_LANGUAGE="$language" \
      QIXI_SIM_DEVICE="$DEVICE" \
      QIXI_SCREENSHOT_AUTO_ROTATE=1 \
      QIXI_OPEN_UTILITY_SHEET=sync \
      QIXI_ICLOUD_SYNC_ENABLED=1 \
      QIXI_SYNC_STATUS="$status" \
      "$SCRIPT_DIR/screenshot-sim.sh" "$status_screenshot"
    python3 "$NATIVE_DIR/tests/inspect_utility_sheet_screenshot.py" "$status_screenshot" "$status"
  done
done
