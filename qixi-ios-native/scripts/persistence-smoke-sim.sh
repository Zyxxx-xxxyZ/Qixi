#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVICE_NAME="${QIXI_SIM_DEVICE:-iPad Pro 13-inch (M5)}"
DERIVED_DATA="${QIXI_DERIVED_DATA:-/private/tmp/qixi-native-screenshot-derived}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Qixi.app"

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

UDID="${QIXI_SIM_UDID:-}"
if [[ -z "$UDID" ]]; then
  UDID="$(
    DEVICE_NAME="$DEVICE_NAME" python3 - <<'PY'
import json
import os
import subprocess

target_name = os.environ["DEVICE_NAME"]
payload = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
devices = [device for runtime in payload["devices"].values() for device in runtime]
booted = [device for device in devices if device["name"] == target_name and device["state"] == "Booted"]
if booted:
  print(booted[0]["udid"])
  raise SystemExit(0)
matching = [device for device in devices if device["name"] == target_name]
if matching:
  print(matching[0]["udid"])
  raise SystemExit(0)
ipads = [device for device in devices if device["name"].startswith("iPad")]
if ipads:
  print(ipads[0]["udid"])
  raise SystemExit(0)
raise SystemExit(f"No available simulator matching {target_name!r}")
PY
  )"
fi

screenshot="$NATIVE_DIR/artifacts/screenshots/latest-ipad-persistence.png"
LIFECYCLE_REASON="${QIXI_LIFECYCLE_TOMBSTONE_ON_LAUNCH:-automation.lifecycle}"
ANALYSIS_RUNTIME="${QIXI_ANALYSIS_RUNTIME:-nativeInProcess}"
QIXI_SIM_UDID="$UDID" \
QIXI_APP_LANGUAGE="${QIXI_APP_LANGUAGE:-en}" \
QIXI_ANALYSIS_RUNTIME="$ANALYSIS_RUNTIME" \
QIXI_LIFECYCLE_TOMBSTONE_ON_LAUNCH="$LIFECYCLE_REASON" \
QIXI_SEED_NATIVE_ENGINE_TOMBSTONE="${QIXI_SEED_NATIVE_ENGINE_TOMBSTONE:-1}" \
QIXI_SCREENSHOT_DELAY="${QIXI_SCREENSHOT_DELAY:-3}" \
  "$SCRIPT_DIR/screenshot-sim.sh" "$screenshot" >/tmp/qixi-native-persistence-screenshot.log

python3 "$NATIVE_DIR/tests/inspect_screenshot.py" "$screenshot"

bundle_id="$(resolved_built_app_bundle_id "$APP_PATH")"
container="$(xcrun simctl get_app_container "$UDID" "$bundle_id" data)"
snapshot="$container/Library/Application Support/Qixi/autosave.qixi-state.json"
backup_snapshot="$container/Library/Application Support/Qixi/autosave.qixi-state.backup.json"
tombstone="$container/Library/Application Support/Qixi/lifecycle-tombstone.qixi-state.json"
engine_tombstone="$container/Library/Application Support/Qixi/native-engine-tombstone.qixi-native"
engine_export_audit="$container/Library/Application Support/Qixi/native-engine-tombstone.export.json"
engine_restore_audit="$container/Library/Application Support/Qixi/native-engine-tombstone.restore.json"
sync_fallback="$container/Library/Application Support/Qixi/SyncFallback/autosave.qixi-state.json"
python3 - "$snapshot" "$backup_snapshot" "$tombstone" "$engine_tombstone" "$engine_export_audit" "$engine_restore_audit" "$sync_fallback" "$LIFECYCLE_REASON" "$ANALYSIS_RUNTIME" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
backup = pathlib.Path(sys.argv[2])
tombstone = pathlib.Path(sys.argv[3])
engine_tombstone = pathlib.Path(sys.argv[4])
engine_export_audit = pathlib.Path(sys.argv[5])
engine_restore_audit = pathlib.Path(sys.argv[6])
sync_fallback = pathlib.Path(sys.argv[7])
expected_lifecycle_reason = sys.argv[8]
analysis_runtime = sys.argv[9]
assert path.exists(), f"snapshot missing: {path}"
payload = json.loads(path.read_text(encoding="utf-8"))
expected = {
  "schemaVersion",
  "savedAt",
  "saveReason",
  "selectedEngine",
  "currentPly",
  "mainLine",
  "komi",
  "showTerritory",
  "analysisByEngine",
}
missing = expected - payload.keys()
assert not missing, f"snapshot missing keys: {sorted(missing)}"
assert payload["schemaVersion"] == 1
assert payload["saveReason"] == expected_lifecycle_reason
assert payload["selectedEngine"] == "none"
assert isinstance(payload["mainLine"], list) and len(payload["mainLine"]) >= payload["currentPly"]
assert "rootNoise" not in payload
assert backup.exists(), f"backup snapshot missing: {backup}"
backup_payload = json.loads(backup.read_text(encoding="utf-8"))
assert backup_payload == payload
print(f"Backup snapshot smoke passed: {backup}")
assert tombstone.exists(), f"lifecycle tombstone missing: {tombstone}"
tombstone_payload = json.loads(tombstone.read_text(encoding="utf-8"))
assert tombstone_payload["schemaVersion"] == 1
assert tombstone_payload["reason"] == expected_lifecycle_reason
assert tombstone_payload["snapshotFilename"] == "autosave.qixi-state.json"
assert tombstone_payload["snapshotSavedAt"] == payload["savedAt"]
assert tombstone_payload["selectedEngine"] == payload["selectedEngine"]
assert tombstone_payload["currentPly"] == payload["currentPly"]
assert tombstone_payload["mainLineCount"] == len(payload["mainLine"])
if analysis_runtime.lower().replace("-", "").replace("_", "") in {"native", "nativeinprocess", "inprocess", "ipadnative"}:
  assert tombstone_payload["engineTombstoneFilename"] == "native-engine-tombstone.qixi-native"
  assert engine_tombstone.exists(), f"native engine tombstone missing: {engine_tombstone}"
  engine_tombstone_payload = json.loads(engine_tombstone.read_text(encoding="utf-8"))
  assert engine_tombstone_payload["schemaVersion"] == 1
  assert engine_tombstone_payload["kind"] == "qixi-native-katago-tombstone"
  assert engine_tombstone_payload["engine"] == "none"
  print(f"Native engine tombstone smoke passed: {engine_tombstone}")
  assert engine_export_audit.exists(), f"native engine tombstone export audit missing: {engine_export_audit}"
  engine_export_payload = json.loads(engine_export_audit.read_text(encoding="utf-8"))
  assert engine_export_payload["schemaVersion"] == 1
  assert engine_export_payload["tombstoneFilename"] == "native-engine-tombstone.qixi-native"
  assert engine_export_payload["engine"] == "none"
  assert engine_export_payload["reason"] == expected_lifecycle_reason
  assert isinstance(engine_export_payload["exportedAt"], str) and engine_export_payload["exportedAt"]
  print(f"Native engine tombstone export smoke passed: {engine_export_audit}")
  assert engine_restore_audit.exists(), f"native engine tombstone restore audit missing: {engine_restore_audit}"
  engine_restore_payload = json.loads(engine_restore_audit.read_text(encoding="utf-8"))
  assert engine_restore_payload["schemaVersion"] == 2
  assert engine_restore_payload["tombstoneFilename"] == "native-engine-tombstone.qixi-native"
  assert engine_restore_payload["engine"] == "none"
  assert isinstance(engine_restore_payload["restoredAt"], str) and engine_restore_payload["restoredAt"]
  print(f"Native engine tombstone restore smoke passed: {engine_restore_audit}")
print(f"Lifecycle tombstone smoke passed: {tombstone}")
if sync_fallback.exists():
  sync_payload = json.loads(sync_fallback.read_text(encoding="utf-8"))
  assert sync_payload["schemaVersion"] == payload["schemaVersion"]
  assert sync_payload["selectedEngine"] == payload["selectedEngine"]
  assert "rootNoise" not in sync_payload
  print(f"Sync fallback smoke passed: {sync_fallback}")
else:
  print("Sync fallback not present; app may have resolved an iCloud ubiquity container.")
print(f"Persistence smoke passed: {path}")
PY
