#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCREENSHOT_PATH="$NATIVE_DIR/artifacts/screenshots/latest-ipad-real-device-evidence-negative.png"
LEGACY_SCREENSHOT_PATH="$NATIVE_DIR/artifacts/screenshots/latest-ipad-real-device-evidence-negative-legacy.png"
DERIVED_DATA="${QIXI_DERIVED_DATA:-/private/tmp/qixi-native-screenshot-derived}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Qixi.app"
BACKEND_ORIGIN="http://192.168.1.23:8765"

resolved_built_app_bundle_id() {
  local app_path="$1"
  local bundle_id
  if ! bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Info.plist" 2>/dev/null)"; then
    echo "Built app Info.plist is missing CFBundleIdentifier: $app_path/Info.plist" >&2
    exit 2
  fi
  if [[ -z "$bundle_id" ]]; then
    echo "Built app CFBundleIdentifier must not be empty: $app_path/Info.plist" >&2
    exit 2
  fi
  printf '%s\n' "$bundle_id"
}

validate_latest_failed_audit() {
  local expected_key="$1"

  local udid="${QIXI_SIM_UDID:-}"
  if [[ -z "$udid" ]]; then
    udid="$(python3 - <<'PY'
import json
import subprocess

payload = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
devices = [device for runtime in payload["devices"].values() for device in runtime]
booted = [device for device in devices if device["state"] == "Booted" and device["name"].startswith("iPad")]
if booted:
  print(booted[0]["udid"])
  raise SystemExit(0)
raise SystemExit("No booted iPad simulator found after screenshot smoke")
PY
    )"
  fi

  local container
  local bundle_id
  bundle_id="$(resolved_built_app_bundle_id "$APP_PATH")"
  container="$(xcrun simctl get_app_container "$udid" "$bundle_id" data)"
  local evidence="$container/Library/Application Support/Qixi/real-device-evidence.qixi-release.json"
  local audit="$container/Library/Application Support/Qixi/real-device-evidence.export.json"

  python3 - "$evidence" "$audit" "$expected_key" <<'PY'
import json
import pathlib
import sys

evidence = pathlib.Path(sys.argv[1])
audit = pathlib.Path(sys.argv[2])
expected_key = sys.argv[3]
assert not evidence.exists(), f"simulator must not produce release-valid real-device evidence: {evidence}"
assert audit.exists(), f"real-device evidence failure audit missing: {audit}"
payload = json.loads(audit.read_text(encoding="utf-8"))
assert payload["schemaVersion"] == 1
assert payload["status"] == "failed"
assert payload["evidenceFilename"] == "real-device-evidence.qixi-release.json"
error = payload.get("error") or ""
assert (
  "backend transport environment" in error
  and expected_key in error
), error
print(f"Simulator real-device evidence negative smoke passed for {expected_key}: {audit}")
PY
}

run_negative_case() {
  local label="$1"
  local screenshot_path="$2"
  local backend_key="$3"
  local run_id="$4"
  local log_path="/tmp/qixi-real-device-evidence-negative-${label}-screenshot.log"
  local device_backend_url=""
  local legacy_backend_url=""
  if [[ "$backend_key" == "QIXI_DEVICE_BACKEND_URL" ]]; then
    device_backend_url="$BACKEND_ORIGIN"
  else
    legacy_backend_url="$BACKEND_ORIGIN"
  fi

  QIXI_APP_LANGUAGE="${QIXI_APP_LANGUAGE:-en}" \
  QIXI_SKIP_ONBOARDING=1 \
  QIXI_ANALYSIS_RUNTIME=nativeInProcess \
  QIXI_ANALYSIS_FIXTURE=real-device-evidence \
  QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_ANALYSIS=1 \
  QIXI_SEED_REAL_DEVICE_EVIDENCE_ARTIFACTS=1 \
  QIXI_DEVICE_BACKEND_URL="$device_backend_url" \
  QIXI_BACKEND_URL="$legacy_backend_url" \
  QIXI_REAL_DEVICE_RUN_ID="$run_id" \
  QIXI_REAL_DEVICE_RECORDED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  QIXI_REAL_DEVICE_COLD_LAUNCH_MS=900 \
  QIXI_REAL_DEVICE_VISUAL_READY_MS=1400 \
  QIXI_REAL_DEVICE_PEAK_RSS_MB=620 \
  QIXI_REAL_DEVICE_POST_ANALYSIS_RSS_MB=590 \
  QIXI_REAL_DEVICE_TARGET_REFRESH_HZ=120 \
  QIXI_REAL_DEVICE_OBSERVED_REFRESH_HZ=118 \
  QIXI_REAL_DEVICE_DROPPED_FRAME_PERCENT=1.2 \
  QIXI_REAL_DEVICE_BACKGROUNDED_SECONDS=30 \
  QIXI_REAL_DEVICE_AUTOSAVE_WRITTEN=1 \
  QIXI_REAL_DEVICE_TOMBSTONE_WRITTEN=1 \
  QIXI_REAL_DEVICE_RESTORED_LATEST_STATE=1 \
  QIXI_REAL_DEVICE_CAMERA_RECOGNITION_TESTED=1 \
  QIXI_REAL_DEVICE_ICLOUD_SYNC_TESTED=1 \
  QIXI_REAL_DEVICE_MODEL_IMPORT_TESTED=1 \
  QIXI_REAL_DEVICE_SCREENSHOT_ARTIFACT=real-device-ipad-main.png \
  QIXI_REAL_DEVICE_PERFORMANCE_ARTIFACT=real-device-instruments.json \
  QIXI_REAL_DEVICE_DEVICE_LOG_ARTIFACT=real-device.log \
    "$SCRIPT_DIR/screenshot-sim.sh" "$screenshot_path" >"$log_path"

  python3 "$NATIVE_DIR/tests/inspect_screenshot.py" "$screenshot_path"
  validate_latest_failed_audit "$backend_key"
}

run_negative_case \
  "device-backend-url" \
  "$SCREENSHOT_PATH" \
  "QIXI_DEVICE_BACKEND_URL" \
  "00000000-0000-4000-8000-000000000001"

run_negative_case \
  "legacy-backend-url" \
  "$LEGACY_SCREENSHOT_PATH" \
  "QIXI_BACKEND_URL" \
  "00000000-0000-4000-8000-000000000002"
