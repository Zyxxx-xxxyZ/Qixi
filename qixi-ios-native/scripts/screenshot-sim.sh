#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NATIVE_DIR="$ROOT_DIR/qixi-ios-native"
PROJECT="$NATIVE_DIR/Qixi.xcodeproj"
SCHEME="Qixi"
BUNDLE_ID="com.qixi.localanalysis"
DERIVED_DATA="${QIXI_DERIVED_DATA:-/private/tmp/qixi-native-screenshot-derived}"
DEVICE_NAME="${QIXI_SIM_DEVICE:-iPad Pro 13-inch (M5)}"
SCREENSHOT_PATH="${1:-$NATIVE_DIR/artifacts/screenshots/latest-ipad.png}"
RAW_SCREENSHOT_PATH="${SCREENSHOT_PATH%.png}.raw.png"
APP_LANGUAGE="${QIXI_APP_LANGUAGE:-}"
SKIP_ONBOARDING="${QIXI_SKIP_ONBOARDING:-1}"
BACKEND_URL="${QIXI_BACKEND_URL:-}"
ANALYSIS_RUNTIME="${QIXI_ANALYSIS_RUNTIME:-}"
AUTO_ROTATE="${QIXI_SCREENSHOT_AUTO_ROTATE:-1}"
UTILITY_SHEET="${QIXI_OPEN_UTILITY_SHEET:-}"
IMPORT_SHEET_STATUS="${QIXI_IMPORT_SHEET_STATUS:-}"
HERMES_STATUS="${QIXI_HERMES_STATUS:-}"
ENGINE_ERROR="${QIXI_ENGINE_ERROR:-}"
AUTOMATION_SELECT_ENGINE="${QIXI_AUTOMATION_SELECT_ENGINE:-}"
ANALYSIS_FIXTURE="${QIXI_ANALYSIS_FIXTURE:-}"
SHOW_TERRITORY="${QIXI_SHOW_TERRITORY:-}"
LIFECYCLE_TOMBSTONE_ON_LAUNCH="${QIXI_LIFECYCLE_TOMBSTONE_ON_LAUNCH:-}"
SEED_NATIVE_ENGINE_TOMBSTONE="${QIXI_SEED_NATIVE_ENGINE_TOMBSTONE:-}"
ICLOUD_SYNC_ENABLED="${QIXI_ICLOUD_SYNC_ENABLED:-}"
SYNC_STATUS="${QIXI_SYNC_STATUS:-}"
METRICS_PATH="${QIXI_SCREENSHOT_METRICS_PATH:-}"
SEED_REAL_DEVICE_EVIDENCE_ARTIFACTS="${QIXI_SEED_REAL_DEVICE_EVIDENCE_ARTIFACTS:-}"
BUILD_MARKER="${QIXI_SCREENSHOT_BUILD_MARKER:-/tmp/qixi-native-screenshot-build-marker}"

resolve_xcodebuild() {
  local xcodebuild_path
  if ! xcodebuild_path="$(command -v xcodebuild)"; then
    echo "Simulator screenshot capture requires xcodebuild in PATH" >&2
    exit 2
  fi
  if [[ "$xcodebuild_path" != "/usr/bin/xcodebuild" ]]; then
    echo "Simulator screenshot capture requires xcodebuild to resolve to /usr/bin/xcodebuild, got $xcodebuild_path; do not shadow xcodebuild in PATH" >&2
    exit 2
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
      echo "Simulator screenshot app path must not contain parent-directory traversal: $path" >&2
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
      echo "Simulator screenshot app path must not contain symbolic links: $current" >&2
      exit 3
    fi
  done
}

prepare_output_artifact() {
  local path="$1"
  local label="$2"
  local parent
  reject_symlink_components "$path"
  parent="$(dirname "$path")"
  reject_symlink_components "$parent"
  mkdir -p "$parent"
  reject_symlink_components "$parent"
  if [[ -L "$path" ]]; then
    echo "Simulator screenshot $label target must not be a symbolic link: $path" >&2
    exit 3
  fi
  if [[ -e "$path" && ! -f "$path" ]]; then
    echo "Simulator screenshot $label target must be a regular file: $path" >&2
    exit 3
  fi
}

temporary_output_path() {
  local target="$1"
  local suffix="$2"
  local parent base candidate attempt
  parent="$(dirname "$target")"
  base="$(basename "$target")"
  for attempt in $(seq 0 99); do
    candidate="$parent/.$base.$$.$attempt.$suffix"
    reject_symlink_components "$candidate"
    if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  echo "Simulator screenshot could not allocate temporary output path for $target" >&2
  exit 3
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
      exit 3
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
      exit 3
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
      exit 3
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
    echo "Simulator screenshot build marker parent does not exist: $parent" >&2
    exit 3
  fi
  if [[ -e "$BUILD_MARKER" && ! -f "$BUILD_MARKER" ]]; then
    echo "Simulator screenshot build marker exists but is not a regular file: $BUILD_MARKER" >&2
    exit 3
  fi
  if [[ -L "$BUILD_MARKER" ]]; then
    echo "Simulator screenshot build marker must not be a symbolic link: $BUILD_MARKER" >&2
    exit 3
  fi
  python3 "$SCRIPT_DIR/protected_build_marker.py" "$BUILD_MARKER" "Simulator screenshot build marker" >/dev/null
}

validate_built_app() {
  local app_path="$1"
  local executable_path="$app_path/Qixi"
  local executable_mtime marker_mtime input_mtime executable_input_mtime bundle_mtime
  reject_symlink_components "$app_path"
  reject_symlink_components "$BUILD_MARKER"
  if [[ ! -d "$app_path" ]]; then
    echo "Built app not found at $app_path" >&2
    exit 3
  fi
  if [[ ! -f "$app_path/Info.plist" ]]; then
    echo "Built app is missing Info.plist: $app_path" >&2
    exit 3
  fi
  if [[ ! -f "$executable_path" || ! -s "$executable_path" ]]; then
    echo "Built app executable is missing or empty: $executable_path" >&2
    exit 3
  fi
  if [[ -L "$executable_path" ]]; then
    echo "Built app executable must not be a symbolic link: $executable_path" >&2
    exit 3
  fi
  if [[ ! -f "$BUILD_MARKER" ]]; then
    echo "Simulator screenshot build marker is missing before app validation: $BUILD_MARKER" >&2
    exit 3
  fi
  executable_mtime="$(file_mtime_epoch "$executable_path")" || {
    echo "Could not read built app executable mtime: $executable_path" >&2
    exit 3
  }
  marker_mtime="$(file_mtime_epoch "$BUILD_MARKER")" || {
    echo "Could not read simulator screenshot build marker mtime: $BUILD_MARKER" >&2
    exit 3
  }
  if (( executable_mtime < marker_mtime )); then
    executable_input_mtime="$(newest_executable_input_mtime_epoch)"
    input_mtime="$(newest_app_input_mtime_epoch)"
    bundle_mtime="$(newest_app_bundle_mtime_epoch "$app_path")"
    if (( executable_mtime < executable_input_mtime || bundle_mtime < input_mtime )); then
      echo "Built app executable is older than the screenshot build marker and the app bundle is older than app inputs; refusing stale app bundle: $executable_path" >&2
      exit 3
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

extract_launched_pid() {
  local launch_log="$1"
  python3 - "$launch_log" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
match = re.search(r":\s*(\d+)", text)
if match:
  print(match.group(1))
PY
}

require_launched_app_alive() {
  local pid="$1"
  local label="$2"
  local attempt
  local command_line=""
  if [[ -z "$pid" ]]; then
    echo "Simulator screenshot launch did not report a Qixi process id" >&2
    cat /tmp/qixi-native-screenshot-launch.log >&2 || true
    exit 4
  fi
  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    echo "Simulator screenshot launch reported a non-numeric Qixi process id: $pid" >&2
    cat /tmp/qixi-native-screenshot-launch.log >&2 || true
    exit 4
  fi
  for attempt in $(seq 1 20); do
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == *"/Qixi.app/Qixi"* ]]; then
      return
    fi
    sleep 0.1
  done
  if [[ -n "$command_line" ]]; then
    echo "Simulator screenshot observed a different process for Qixi pid $pid: $command_line" >&2
  else
    echo "Simulator screenshot Qixi app process exited before $label: pid=$pid" >&2
  fi
  cat /tmp/qixi-native-screenshot-launch.log >&2 || true
  exit 4
}

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Qixi.app"
if [[ "${QIXI_SCREENSHOT_VALIDATE_APP_ONLY:-0}" == "1" ]]; then
  validate_built_app "$APP_PATH"
  exit 0
fi

prepare_output_artifact "$SCREENSHOT_PATH" "cropped PNG"
prepare_output_artifact "$RAW_SCREENSHOT_PATH" "raw PNG"
RAW_CAPTURE_PATH="$(temporary_output_path "$RAW_SCREENSHOT_PATH" "capture.png")"
CROPPED_CAPTURE_PATH="$(temporary_output_path "$SCREENSHOT_PATH" "cropped.png")"
prepare_output_artifact "$RAW_CAPTURE_PATH" "raw temporary PNG"
prepare_output_artifact "$CROPPED_CAPTURE_PATH" "cropped temporary PNG"
if [[ -n "$METRICS_PATH" ]]; then
  prepare_output_artifact "$METRICS_PATH" "metrics JSON"
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
if [[ -n "$APP_LANGUAGE" ]]; then
  echo "Using app language: $APP_LANGUAGE"
fi
echo "Skip onboarding: $SKIP_ONBOARDING"
if [[ -n "$BACKEND_URL" ]]; then
  echo "Using backend URL: $BACKEND_URL"
fi
if [[ -n "$ANALYSIS_RUNTIME" ]]; then
  echo "Using analysis runtime: $ANALYSIS_RUNTIME"
fi
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light >/dev/null || true

prepare_build_marker
"$XCODEBUILD_BIN" \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >/tmp/qixi-native-screenshot-build.log

validate_built_app "$APP_PATH"
BUNDLE_ID="$(resolved_built_app_bundle_id "$APP_PATH")"
echo "Using bundle id: $BUNDLE_ID"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP_PATH"
if [[ -n "$SEED_NATIVE_ENGINE_TOMBSTONE" ]]; then
  data_container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
  qixi_dir="$data_container/Library/Application Support/Qixi"
  mkdir -p "$qixi_dir"
  python3 - "$qixi_dir/native-engine-tombstone.qixi-native" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = {
  "schemaVersion": 1,
  "kind": "qixi-native-katago-tombstone",
  "engine": "none",
  "state": "seeded restore smoke",
}
path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
PY
fi
if [[ -n "$SEED_REAL_DEVICE_EVIDENCE_ARTIFACTS" ]]; then
  data_container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
  qixi_dir="$data_container/Library/Application Support/Qixi"
  mkdir -p "$qixi_dir"
  printf 'simulator screenshot evidence placeholder\n' > "$qixi_dir/real-device-ipad-main.png"
  printf '{"source":"simulator smoke"}\n' > "$qixi_dir/real-device-instruments.json"
  printf 'simulator device log placeholder\n' > "$qixi_dir/real-device.log"
fi
launch_env=(SIMCTL_CHILD_QIXI_SKIP_ONBOARDING="$SKIP_ONBOARDING")
if [[ -n "$APP_LANGUAGE" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_APP_LANGUAGE="$APP_LANGUAGE")
fi
if [[ -n "$BACKEND_URL" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_BACKEND_URL="$BACKEND_URL")
fi
if [[ -n "$ANALYSIS_RUNTIME" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_ANALYSIS_RUNTIME="$ANALYSIS_RUNTIME")
fi
if [[ -n "$UTILITY_SHEET" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_OPEN_UTILITY_SHEET="$UTILITY_SHEET")
fi
if [[ -n "$IMPORT_SHEET_STATUS" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_IMPORT_SHEET_STATUS="$IMPORT_SHEET_STATUS")
fi
if [[ -n "$HERMES_STATUS" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_HERMES_STATUS="$HERMES_STATUS")
fi
if [[ -n "$ENGINE_ERROR" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_ENGINE_ERROR="$ENGINE_ERROR")
fi
if [[ -n "$AUTOMATION_SELECT_ENGINE" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_AUTOMATION_SELECT_ENGINE="$AUTOMATION_SELECT_ENGINE")
fi
if [[ -n "$ICLOUD_SYNC_ENABLED" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_ICLOUD_SYNC_ENABLED="$ICLOUD_SYNC_ENABLED")
fi
if [[ -n "$SYNC_STATUS" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_SYNC_STATUS="$SYNC_STATUS")
fi
if [[ -n "$ANALYSIS_FIXTURE" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_ANALYSIS_FIXTURE="$ANALYSIS_FIXTURE")
fi
if [[ -n "$SHOW_TERRITORY" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_SHOW_TERRITORY="$SHOW_TERRITORY")
fi
if [[ -n "$LIFECYCLE_TOMBSTONE_ON_LAUNCH" ]]; then
  launch_env+=(SIMCTL_CHILD_QIXI_LIFECYCLE_TOMBSTONE_ON_LAUNCH="$LIFECYCLE_TOMBSTONE_ON_LAUNCH")
fi
launch_args=()
if [[ -n "$LIFECYCLE_TOMBSTONE_ON_LAUNCH" ]]; then
  launch_args+=(--qixi-lifecycle-tombstone-on-launch "$LIFECYCLE_TOMBSTONE_ON_LAUNCH")
fi
for evidence_key in \
  QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_ANALYSIS \
  QIXI_REAL_DEVICE_EVIDENCE_OUTPUT \
  QIXI_REAL_DEVICE_RUN_ID \
  QIXI_REAL_DEVICE_RECORDED_AT \
  QIXI_REAL_DEVICE_IDIOM \
  QIXI_REAL_DEVICE_MODEL \
  QIXI_REAL_DEVICE_OS_VERSION \
  QIXI_REAL_DEVICE_SIMULATOR \
  QIXI_DEVICE_BACKEND_URL \
  QIXI_REAL_DEVICE_COLD_LAUNCH_MS \
  QIXI_REAL_DEVICE_VISUAL_READY_MS \
  QIXI_REAL_DEVICE_PEAK_RSS_MB \
  QIXI_REAL_DEVICE_POST_ANALYSIS_RSS_MB \
  QIXI_REAL_DEVICE_TARGET_REFRESH_HZ \
  QIXI_REAL_DEVICE_OBSERVED_REFRESH_HZ \
  QIXI_REAL_DEVICE_DROPPED_FRAME_PERCENT \
  QIXI_REAL_DEVICE_BACKGROUNDED_SECONDS \
  QIXI_REAL_DEVICE_AUTOSAVE_WRITTEN \
  QIXI_REAL_DEVICE_TOMBSTONE_WRITTEN \
  QIXI_REAL_DEVICE_RESTORED_LATEST_STATE \
  QIXI_REAL_DEVICE_CAMERA_RECOGNITION_TESTED \
  QIXI_REAL_DEVICE_ICLOUD_SYNC_TESTED \
  QIXI_REAL_DEVICE_MODEL_IMPORT_TESTED \
  QIXI_REAL_DEVICE_SCREENSHOT_ARTIFACT \
  QIXI_REAL_DEVICE_PERFORMANCE_ARTIFACT \
  QIXI_REAL_DEVICE_DEVICE_LOG_ARTIFACT; do
  if [[ -n "${!evidence_key:-}" ]]; then
    launch_env+=("SIMCTL_CHILD_${evidence_key}=${!evidence_key}")
  fi
done

launch_started_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
if [[ ${#launch_args[@]} -gt 0 ]]; then
  env "${launch_env[@]}" xcrun simctl launch "$UDID" "$BUNDLE_ID" "${launch_args[@]}" >/tmp/qixi-native-screenshot-launch.log
else
  env "${launch_env[@]}" xcrun simctl launch "$UDID" "$BUNDLE_ID" >/tmp/qixi-native-screenshot-launch.log
fi
launched_pid="$(extract_launched_pid /tmp/qixi-native-screenshot-launch.log)"
require_launched_app_alive "$launched_pid" "visual readiness wait"
launch_finished_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
sleep "${QIXI_SCREENSHOT_DELAY:-2}"
require_launched_app_alive "$launched_pid" "screenshot capture"
xcrun simctl io "$UDID" screenshot --mask ignored "$RAW_CAPTURE_PATH" >/dev/null
screenshot_finished_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"

RAW_CAPTURE_PATH="$RAW_CAPTURE_PATH" CROPPED_CAPTURE_PATH="$CROPPED_CAPTURE_PATH" RAW_SCREENSHOT_PATH="$RAW_SCREENSHOT_PATH" SCREENSHOT_PATH="$SCREENSHOT_PATH" AUTO_ROTATE="$AUTO_ROTATE" python3 - <<'PY'
import os
import pathlib
import stat
from PIL import Image, ImageChops

raw_capture_path = pathlib.Path(os.environ["RAW_CAPTURE_PATH"])
cropped_capture_path = pathlib.Path(os.environ["CROPPED_CAPTURE_PATH"])
raw_path = pathlib.Path(os.environ["RAW_SCREENSHOT_PATH"])
out_path = pathlib.Path(os.environ["SCREENSHOT_PATH"])
auto_rotate = os.environ.get("AUTO_ROTATE", "1") == "1"


def fail(message: str) -> None:
  raise SystemExit(f"Simulator screenshot capture failed: {message}")


def require_replace_target(path: pathlib.Path, label: str) -> None:
  try:
    existing = path.lstat()
  except FileNotFoundError:
    return
  if stat.S_ISLNK(existing.st_mode):
    fail(f"{label} target must not be a symbolic link: {path}")
  if not stat.S_ISREG(existing.st_mode):
    fail(f"{label} target must be a regular file: {path}")


def fsync_parent_directory(path: pathlib.Path, label: str) -> None:
  flags = os.O_RDONLY
  if hasattr(os, "O_DIRECTORY"):
    flags |= os.O_DIRECTORY
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
  parent_fd = os.open(path.parent, flags)
  try:
    os.fsync(parent_fd)
  except OSError as exc:
    fail(f"{label} could not fsync parent directory after atomic replace: {exc}")
  finally:
    os.close(parent_fd)


def replace_artifact(tmp_path: pathlib.Path, target: pathlib.Path, label: str) -> None:
  if tmp_path.is_symlink():
    fail(f"{label} temporary file must not be a symbolic link: {tmp_path}")
  if not tmp_path.is_file():
    fail(f"{label} temporary file must be a regular file: {tmp_path}")
  require_replace_target(target, label)
  os.replace(tmp_path, target)
  fsync_parent_directory(target, label)


try:
  image = Image.open(raw_capture_path).convert("RGB")
  black = Image.new("RGB", image.size, (0, 0, 0))
  diff = ImageChops.difference(image, black)
  bbox = diff.point(lambda value: 255 if value > 8 else 0).getbbox()
  if bbox is None:
    cropped = image
  else:
    cropped = image.crop(bbox)
  if auto_rotate and cropped.width < cropped.height:
    cropped = cropped.rotate(90, expand=True)
  cropped.save(cropped_capture_path)
  replace_artifact(raw_capture_path, raw_path, "raw screenshot artifact")
  replace_artifact(cropped_capture_path, out_path, "cropped screenshot artifact")
finally:
  for path in (raw_capture_path, cropped_capture_path):
    try:
      if path.exists() or path.is_symlink():
        path.unlink()
    except OSError:
      pass
PY

if [[ -n "$METRICS_PATH" ]]; then
  python3 - "$METRICS_PATH" "$UDID" "$BUNDLE_ID" "$SCREENSHOT_PATH" "$RAW_SCREENSHOT_PATH" "$launch_started_ms" "$launch_finished_ms" "$screenshot_finished_ms" <<'PY'
import json
import os
import pathlib
import re
import sys
import stat

metrics_path = pathlib.Path(sys.argv[1])
launch_log = pathlib.Path("/tmp/qixi-native-screenshot-launch.log").read_text(encoding="utf-8")
match = re.search(r":\s*(\d+)", launch_log)
payload = {
  "schemaVersion": 1,
  "simulatorUDID": sys.argv[2],
  "bundleIdentifier": sys.argv[3],
  "screenshotPath": sys.argv[4],
  "rawScreenshotPath": sys.argv[5],
  "launchStartedMs": int(sys.argv[6]),
  "launchFinishedMs": int(sys.argv[7]),
  "screenshotFinishedMs": int(sys.argv[8]),
  "launchCommandMs": int(sys.argv[7]) - int(sys.argv[6]),
  "visualReadyMs": int(sys.argv[8]) - int(sys.argv[6]),
  "pid": int(match.group(1)) if match else None,
}


def fail(message: str) -> None:
  raise SystemExit(f"Simulator screenshot metrics failed: {message}")


def require_replace_target(path: pathlib.Path) -> None:
  try:
    existing = path.lstat()
  except FileNotFoundError:
    return
  if stat.S_ISLNK(existing.st_mode):
    fail(f"metrics artifact target must not be a symbolic link: {path}")
  if not stat.S_ISREG(existing.st_mode):
    fail(f"metrics artifact target must be a regular file: {path}")


def fsync_parent_directory(path: pathlib.Path) -> None:
  flags = os.O_RDONLY
  if hasattr(os, "O_DIRECTORY"):
    flags |= os.O_DIRECTORY
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
  parent_fd = os.open(path.parent, flags)
  try:
    os.fsync(parent_fd)
  finally:
    os.close(parent_fd)


data = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
tmp_path = metrics_path.with_name(f".{metrics_path.name}.{os.getpid()}.tmp")
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
  flags |= os.O_NOFOLLOW
fd = None
try:
  fd = os.open(tmp_path, flags, 0o600)
  written = 0
  view = memoryview(data)
  while written < len(data):
    written += os.write(fd, view[written:])
  written_stat = os.fstat(fd)
  if not stat.S_ISREG(written_stat.st_mode):
    fail(f"metrics artifact temporary file must be regular: {tmp_path}")
  if written_stat.st_size != len(data):
    fail(f"metrics artifact byte count drift after writing: expected {len(data)} got {written_stat.st_size}")
  os.fsync(fd)
  os.close(fd)
  fd = None
  require_replace_target(metrics_path)
  os.replace(tmp_path, metrics_path)
  fsync_parent_directory(metrics_path)
except OSError as exc:
  fail(f"could not write metrics artifact atomically: {exc}")
finally:
  if fd is not None:
    os.close(fd)
  try:
    if tmp_path.exists() or tmp_path.is_symlink():
      tmp_path.unlink()
  except OSError:
    pass
PY
fi

echo "$SCREENSHOT_PATH"
