#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

for language in zh-Hans zh-Hant en; do
  screenshot="$NATIVE_DIR/artifacts/screenshots/latest-ipad-onboarding-$language.png"
  QIXI_APP_LANGUAGE="$language" "$SCRIPT_DIR/screenshot-onboarding-sim.sh" "$screenshot"
done
