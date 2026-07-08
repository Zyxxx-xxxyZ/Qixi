#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NATIVE_DIR="$ROOT_DIR/qixi-ios-native"
PROJECT="$NATIVE_DIR/Qixi.xcodeproj"
SCHEME="Qixi"
BUNDLE_ID="com.qixi.localanalysis"
DERIVED_DATA="${QIXI_DERIVED_DATA:-/private/tmp/qixi-native-run-derived}"
DEVICE_NAME="${QIXI_SIM_DEVICE:-iPad Pro 13-inch (M5)}"
BACKEND_URL="${QIXI_BACKEND_URL:-http://127.0.0.1:8765}"
ANALYSIS_RUNTIME="${QIXI_ANALYSIS_RUNTIME:-httpBridge}"
SKIP_ONBOARDING="${QIXI_SKIP_ONBOARDING:-1}"
APP_LANGUAGE="${QIXI_APP_LANGUAGE:-}"
OPEN_SIMULATOR="${QIXI_SIM_OPEN:-1}"
RESET_APP="${QIXI_SIM_RESET_APP:-0}"
CHECK_BACKEND="${QIXI_SIM_CHECK_BACKEND:-1}"
CONSOLE="${QIXI_SIM_RUN_CONSOLE:-0}"
BUILD_LOG="${QIXI_SIM_BUILD_LOG:-/tmp/qixi-native-run-build.log}"
BUILD_MARKER="${QIXI_SIM_BUILD_MARKER:-/tmp/qixi-native-run-build-marker}"

resolve_xcodebuild() {
  local xcodebuild_path
  if ! xcodebuild_path="$(command -v xcodebuild)"; then
    echo "Native simulator run requires xcodebuild in PATH" >&2
    exit 3
  fi
  if [[ "$xcodebuild_path" != "/usr/bin/xcodebuild" ]]; then
    echo "Native simulator run requires xcodebuild to resolve to /usr/bin/xcodebuild, got $xcodebuild_path; do not shadow xcodebuild in PATH" >&2
    exit 3
  fi
  printf '%s\n' "$xcodebuild_path"
}

reject_symlink_components() {
  local path="$1"
  local current=""
  local target expected_target
  if [[ "$path" == /* ]]; then
    current="/"
  fi
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ -z "$part" || "$part" == "." ]] && continue
    if [[ "$part" == ".." ]]; then
      echo "Native simulator app path must not contain parent-directory traversal: $path" >&2
      exit 3
    fi
    if [[ "$current" == "/" ]]; then
      current="/$part"
    elif [[ -z "$current" ]]; then
      current="$part"
    else
      current="$current/$part"
    fi
    if [[ -L "$current" ]]; then
      expected_target=""
      if [[ "$current" == "/var" ]]; then
        expected_target="/private/var"
      elif [[ "$current" == "/tmp" ]]; then
        expected_target="/private/tmp"
      elif [[ "$current" == "/etc" ]]; then
        expected_target="/private/etc"
      fi
      if [[ -n "$expected_target" ]]; then
        target="$(cd "$current" && pwd -P)"
        if [[ "$target" == "$expected_target" ]]; then
          continue
        fi
      fi
      echo "Native simulator app path must not contain symbolic links: $current" >&2
      exit 3
    fi
  done
}

file_mtime_epoch() {
  local path="$1"
  stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null
}

newest_app_input_mtime_epoch() {
  local newest=0
  local path
  local mtime
  while IFS= read -r -d '' path; do
    mtime="$(file_mtime_epoch "$path")" || {
      echo "Could not read app input mtime: $path" >&2
      exit 4
    }
    if (( mtime > newest )); then
      newest="$mtime"
    fi
  done < <(find "$PROJECT/project.pbxproj" "$NATIVE_DIR/Qixi" -type f -print0)
  printf '%s\n' "$newest"
}

newest_executable_input_mtime_epoch() {
  local newest=0
  local path
  local mtime
  while IFS= read -r -d '' path; do
    mtime="$(file_mtime_epoch "$path")" || {
      echo "Could not read executable input mtime: $path" >&2
      exit 4
    }
    if (( mtime > newest )); then
      newest="$mtime"
    fi
  done < <(find "$PROJECT/project.pbxproj" "$NATIVE_DIR/Qixi" -type f \( -name '*.swift' -o -name '*.mm' -o -name '*.cpp' -o -name '*.hpp' -o -name '*.h' -o -name 'project.pbxproj' \) -print0)
  printf '%s\n' "$newest"
}

newest_app_bundle_mtime_epoch() {
  local app_path="$1"
  local newest=0
  local path
  local mtime
  while IFS= read -r -d '' path; do
    mtime="$(file_mtime_epoch "$path")" || {
      echo "Could not read built app bundle mtime: $path" >&2
      exit 4
    }
    if (( mtime > newest )); then
      newest="$mtime"
    fi
  done < <(find "$app_path" -type f -print0)
  printf '%s\n' "$newest"
}

prepare_build_marker() {
  local parent
  reject_symlink_components "$BUILD_MARKER"
  parent="$(dirname "$BUILD_MARKER")"
  if [[ ! -d "$parent" ]]; then
    echo "Native simulator build marker parent does not exist: $parent" >&2
    exit 3
  fi
  if [[ -e "$BUILD_MARKER" && ! -f "$BUILD_MARKER" ]]; then
    echo "Native simulator build marker exists but is not a regular file: $BUILD_MARKER" >&2
    exit 3
  fi
  if [[ -L "$BUILD_MARKER" ]]; then
    echo "Native simulator build marker must not be a symbolic link: $BUILD_MARKER" >&2
    exit 3
  fi
  python3 "$SCRIPT_DIR/protected_build_marker.py" "$BUILD_MARKER" "Native simulator build marker" >/dev/null
}

validate_built_app() {
  local app_path="$1"
  local executable_path="$app_path/Qixi"
  local executable_mtime marker_mtime input_mtime executable_input_mtime bundle_mtime
  reject_symlink_components "$app_path"
  reject_symlink_components "$BUILD_MARKER"
  if [[ ! -d "$app_path" ]]; then
    echo "Built app not found at $app_path" >&2
    exit 4
  fi
  if [[ ! -f "$app_path/Info.plist" ]]; then
    echo "Built app is missing Info.plist: $app_path" >&2
    exit 4
  fi
  if [[ ! -f "$executable_path" || ! -s "$executable_path" ]]; then
    echo "Built app executable is missing or empty: $executable_path" >&2
    exit 4
  fi
  if [[ -L "$executable_path" ]]; then
    echo "Built app executable must not be a symbolic link: $executable_path" >&2
    exit 4
  fi
  if [[ ! -f "$BUILD_MARKER" ]]; then
    echo "Native simulator build marker is missing before app validation: $BUILD_MARKER" >&2
    exit 4
  fi
  executable_mtime="$(file_mtime_epoch "$executable_path")" || {
    echo "Could not read built app executable mtime: $executable_path" >&2
    exit 4
  }
  marker_mtime="$(file_mtime_epoch "$BUILD_MARKER")" || {
    echo "Could not read native simulator build marker mtime: $BUILD_MARKER" >&2
    exit 4
  }
  if (( executable_mtime < marker_mtime )); then
    executable_input_mtime="$(newest_executable_input_mtime_epoch)"
    input_mtime="$(newest_app_input_mtime_epoch)"
    bundle_mtime="$(newest_app_bundle_mtime_epoch "$app_path")"
    if (( executable_mtime < executable_input_mtime || bundle_mtime < input_mtime )); then
      echo "Built simulator app executable is older than the run build marker and the app bundle is older than app inputs; refusing stale app bundle: $executable_path" >&2
      exit 4
    fi
  fi
}

resolved_built_app_bundle_id() {
  local app_path="$1"
  local bundle_id
  if ! bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Info.plist" 2>/dev/null)"; then
    echo "Built app Info.plist is missing CFBundleIdentifier: $app_path/Info.plist" >&2
    exit 4
  fi
  if [[ -z "$bundle_id" ]]; then
    echo "Built app CFBundleIdentifier must not be empty: $app_path/Info.plist" >&2
    exit 4
  fi
  printf '%s\n' "$bundle_id"
}

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Qixi.app"
if [[ "${QIXI_SIM_VALIDATE_APP_ONLY:-0}" == "1" ]]; then
  validate_built_app "$APP_PATH"
  exit 0
fi

XCODEBUILD_BIN="$(resolve_xcodebuild)"

UDID="${QIXI_SIM_UDID:-}"
if [[ -z "$UDID" ]]; then
  UDID="$(
    DEVICE_NAME="$DEVICE_NAME" python3 - <<'PY'
import json
import os
import subprocess
import sys

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

print(f"No available simulator matching {target_name!r}", file=sys.stderr)
raise SystemExit(2)
PY
  )"
fi

echo "Using simulator: $UDID"
echo "Backend URL: $BACKEND_URL"
echo "Analysis runtime: $ANALYSIS_RUNTIME"
echo "Skip onboarding: $SKIP_ONBOARDING"
if [[ -n "$APP_LANGUAGE" ]]; then
  echo "App language: $APP_LANGUAGE"
fi

if [[ "$CHECK_BACKEND" == "1" ]]; then
  BACKEND_URL="$BACKEND_URL" python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

base_url = os.environ["BACKEND_URL"].rstrip("/")
try:
  with urllib.request.urlopen(base_url + "/api/status", timeout=2) as response:
    media_type = response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
    body = response.read(1024 * 1024 + 1)
except (OSError, urllib.error.URLError) as exc:
  print(f"warning: backend health check failed for {base_url}/api/status: {exc}", file=sys.stderr)
  print("warning: start qixi-ios-sim/backend/qixi_backend.py or set QIXI_SIM_CHECK_BACKEND=0 for UI-only runs", file=sys.stderr)
  raise SystemExit(0)

if media_type != "application/json":
  print(f"warning: backend health check returned {media_type or '(missing Content-Type)'}", file=sys.stderr)
  raise SystemExit(0)
if len(body) > 1024 * 1024:
  print("warning: backend health check response exceeded 1 MiB", file=sys.stderr)
  raise SystemExit(0)
try:
  payload = json.loads(body.decode("utf-8"))
except json.JSONDecodeError as exc:
  print(f"warning: backend health check returned invalid JSON: {exc}", file=sys.stderr)
  raise SystemExit(0)
if not isinstance(payload, dict):
  print("warning: backend health check did not return a JSON object", file=sys.stderr)
  raise SystemExit(0)
print(f"Backend health: {payload.get('status', 'unknown')}")
PY
fi

if [[ "$OPEN_SIMULATOR" == "1" ]]; then
  open -a Simulator >/dev/null 2>&1 || true
fi
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light >/dev/null || true

xcode_args=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -destination "platform=iOS Simulator,id=$UDID"
  -configuration Debug
  -derivedDataPath "$DERIVED_DATA"
  CODE_SIGNING_ALLOWED=NO
  build
)
prepare_build_marker
if [[ "${QIXI_XCODEBUILD_VERBOSE:-0}" == "1" ]]; then
  "$XCODEBUILD_BIN" "${xcode_args[@]}"
else
  if ! "$XCODEBUILD_BIN" -quiet "${xcode_args[@]}" >"$BUILD_LOG" 2>&1; then
    echo "xcodebuild failed; last 80 log lines from $BUILD_LOG:" >&2
    tail -80 "$BUILD_LOG" >&2 || true
    exit 3
  fi
fi

validate_built_app "$APP_PATH"
BUNDLE_ID="$(resolved_built_app_bundle_id "$APP_PATH")"
echo "Using bundle id: $BUNDLE_ID"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if [[ "$RESET_APP" == "1" ]]; then
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
xcrun simctl install "$UDID" "$APP_PATH"

launch_env=(
  SIMCTL_CHILD_QIXI_SKIP_ONBOARDING="$SKIP_ONBOARDING"
  SIMCTL_CHILD_QIXI_BACKEND_URL="$BACKEND_URL"
  SIMCTL_CHILD_QIXI_ANALYSIS_RUNTIME="$ANALYSIS_RUNTIME"
)
if [[ -n "$APP_LANGUAGE" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_APP_LANGUAGE="$APP_LANGUAGE")
fi
for optional_key in \
  QIXI_HERMES_STATUS \
  QIXI_ENGINE_ERROR \
  QIXI_ANALYSIS_FIXTURE \
  QIXI_SHOW_TERRITORY \
  QIXI_OPEN_UTILITY_SHEET \
  QIXI_IMPORT_SHEET_STATUS \
  QIXI_ICLOUD_SYNC_ENABLED \
  QIXI_SYNC_STATUS; do
  if [[ -n "${!optional_key:-}" ]]; then
    launch_env+=("SIMCTL_CHILD_${optional_key}=${!optional_key}")
  fi
done

launch_args=(launch --terminate-running-process "$UDID" "$BUNDLE_ID")
if [[ "$CONSOLE" == "1" ]]; then
  launch_args=(launch --console --terminate-running-process "$UDID" "$BUNDLE_ID")
fi
env "${launch_env[@]}" xcrun simctl "${launch_args[@]}"

echo "Launched Qixi on simulator $UDID"
echo "Set QIXI_SIM_RESET_APP=1 for a clean install, or QIXI_SIM_RUN_CONSOLE=1 to attach stdout/stderr."
