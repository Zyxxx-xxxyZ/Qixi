#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NATIVE_DIR="$ROOT_DIR/qixi-ios-native"
PROJECT="$NATIVE_DIR/Qixi.xcodeproj"
SCHEME="Qixi"
BUNDLE_ID="com.qixi.localanalysis"
DEVICE_NAME="${QIXI_NATIVE_RELEASE_SIM_DEVICE:-iPad Pro 13-inch (M5)}"
CMAKE_BUILD_DIR="${QIXI_NATIVE_RELEASE_SIM_CMAKE_BUILD_DIR:-/private/tmp/qixi-ios-katago-cmake-preflight-iphonesimulator-katago-core-native-release-sim}"
DERIVED_DATA="${QIXI_NATIVE_RELEASE_SIM_DERIVED_DATA:-/private/tmp/qixi-native-release-sim-smoke-derived}"
BUILD_LOG="${QIXI_NATIVE_RELEASE_SIM_BUILD_LOG:-/tmp/qixi-native-release-sim-smoke-build.log}"
LAUNCH_LOG="${QIXI_NATIVE_RELEASE_SIM_LAUNCH_LOG:-/tmp/qixi-native-release-sim-smoke-launch.log}"
BUILD_MARKER="${QIXI_NATIVE_RELEASE_SIM_BUILD_MARKER:-/tmp/qixi-native-release-sim-smoke-build-marker}"
SCREENSHOT_PATH="${QIXI_NATIVE_RELEASE_SIM_SCREENSHOT:-$NATIVE_DIR/artifacts/screenshots/latest-native-release-sim-smoke.png}"
CONTENT_SCREENSHOT_PATH="${QIXI_NATIVE_RELEASE_SIM_CONTENT_SCREENSHOT:-/tmp/qixi-native-release-sim-smoke-content.png}"
APP_LANGUAGE="${QIXI_APP_LANGUAGE:-zh-Hans}"
CORE_LIBRARY="$CMAKE_BUILD_DIR/libkatago_core.a"
SWIFT_SIDECAR="$CMAKE_BUILD_DIR/libKataGoSwift.a"
EXPECTED_SIMULATOR_PLATFORM_NUMBER="7"
EXPECTED_SIMULATOR_PLATFORM_LABEL="iOS Simulator"
EXPECTED_SIMULATOR_ARCHES="${QIXI_IOS_ARCH:-${QIXI_IOS_SIM_ARCH:-arm64}}"

fail() {
  echo "NativeRelease simulator smoke failed: $*" >&2
  exit 2
}

reject_inherited_environment() {
  local forbidden_keys=(
    QIXI_BACKEND_URL
    QIXI_DEVICE_BACKEND_URL
    QIXI_ANALYSIS_RUNTIME
    SIMCTL_CHILD_QIXI_BACKEND_URL
    SIMCTL_CHILD_QIXI_DEVICE_BACKEND_URL
    SIMCTL_CHILD_QIXI_ANALYSIS_RUNTIME
  )
  local key
  for key in "${forbidden_keys[@]}"; do
    if [[ -n "${!key:-}" ]]; then
      fail "inherited $key is forbidden; NativeRelease simulator smoke must launch without backend or runtime override environment"
    fi
  done
}

find_developer_tool() {
  if command -v "$1" >/dev/null 2>&1; then
    command -v "$1"
    return 0
  fi
  if command -v xcrun >/dev/null 2>&1; then
    xcrun --find "$1" 2>/dev/null
    return $?
  fi
  return 1
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
      fail "NativeRelease simulator artifact path must not contain parent-directory traversal: $path"
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
      fail "built simulator artifact path must not contain symbolic links: $current"
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
    fail "NativeRelease simulator $label target must not be a symbolic link: $path"
  fi
  if [[ -e "$path" && ! -f "$path" ]]; then
    fail "NativeRelease simulator $label target must be a regular file: $path"
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
  fail "NativeRelease simulator could not allocate temporary output path for $target"
}

cleanup_native_release_temp_outputs() {
  if [[ -n "${SCREENSHOT_CAPTURE_PATH:-}" ]]; then
    rm -f "$SCREENSHOT_CAPTURE_PATH" 2>/dev/null || true
  fi
  if [[ -n "${CONTENT_CAPTURE_PATH:-}" ]]; then
    rm -f "$CONTENT_CAPTURE_PATH" 2>/dev/null || true
  fi
}

file_mtime_epoch() {
  local path="$1"
  stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null
}

prepare_build_marker() {
  local parent
  reject_symlink_components "$BUILD_MARKER"
  parent="$(dirname "$BUILD_MARKER")"
  if [[ ! -d "$parent" ]]; then
    fail "NativeRelease simulator build marker parent does not exist: $parent"
  fi
  if [[ -e "$BUILD_MARKER" && ! -f "$BUILD_MARKER" ]]; then
    fail "NativeRelease simulator build marker exists but is not a regular file: $BUILD_MARKER"
  fi
  if [[ -L "$BUILD_MARKER" ]]; then
    fail "NativeRelease simulator build marker must not be a symbolic link: $BUILD_MARKER"
  fi
  python3 "$SCRIPT_DIR/protected_build_marker.py" "$BUILD_MARKER" "NativeRelease simulator build marker" >/dev/null
}

validate_native_release_sim_artifact() {
  local artifact="$1"
  local label="$2"
  local artifact_mtime marker_mtime lipo_bin otool_bin lipo_output otool_output arch

  reject_symlink_components "$artifact"
  if [[ ! -f "$artifact" ]]; then
    fail "built simulator artifact was not produced: $label: $artifact"
  fi
  if [[ -L "$artifact" ]]; then
    fail "built simulator artifact must not be a symbolic link: $label: $artifact"
  fi
  if [[ ! -s "$artifact" ]]; then
    fail "built simulator artifact must be non-empty: $label: $artifact"
  fi

  reject_symlink_components "$BUILD_MARKER"
  if [[ ! -f "$BUILD_MARKER" ]]; then
    fail "NativeRelease simulator build marker is missing: $BUILD_MARKER"
  fi
  artifact_mtime="$(file_mtime_epoch "$artifact")" || fail "could not read mtime for built simulator artifact: $artifact"
  marker_mtime="$(file_mtime_epoch "$BUILD_MARKER")" || fail "could not read mtime for NativeRelease simulator build marker: $BUILD_MARKER"
  if (( artifact_mtime < marker_mtime )); then
    fail "$label is older than NativeRelease simulator build marker; refusing stale artifact: $artifact"
  fi

  lipo_bin="$(find_developer_tool lipo)" || fail "built simulator artifact validation requires lipo or xcrun"
  if ! lipo_output="$("$lipo_bin" -info "$artifact" 2>&1)"; then
    fail "built simulator artifact must be readable by lipo: $label: $artifact: $lipo_output"
  fi
  IFS=';' read -r -a expected_arches <<< "$EXPECTED_SIMULATOR_ARCHES"
  for arch in "${expected_arches[@]}"; do
    [[ -z "$arch" ]] && continue
    if [[ "$lipo_output" != *"$arch"* ]]; then
      fail "built simulator artifact missing expected architecture $arch: $label: $artifact: $lipo_output"
    fi
  done

  otool_bin="$(find_developer_tool otool)" || fail "built simulator artifact validation requires otool or xcrun"
  if ! otool_output="$("$otool_bin" -l "$artifact" 2>&1)"; then
    fail "built simulator artifact must be readable by otool: $label: $artifact: $otool_output"
  fi
  if ! grep -Eq "LC_BUILD_VERSION|LC_VERSION_MIN_IPHONEOS" <<< "$otool_output"; then
    fail "built simulator artifact is missing an iOS Mach-O build-version load command: $label: $artifact"
  fi

  local platform_values unexpected_platforms
  platform_values="$(awk '/^[[:space:]]*platform[[:space:]]+/ { print $2 }' <<< "$otool_output")"
  unexpected_platforms="$(awk -v expected="$EXPECTED_SIMULATOR_PLATFORM_NUMBER" '/^[[:space:]]*platform[[:space:]]+/ { if ($2 != expected) print $2 }' <<< "$otool_output" | sort -u | tr '\n' ' ')"
  if [[ -n "$unexpected_platforms" ]]; then
    fail "built simulator artifact must not contain object files for another Apple platform: $unexpected_platforms in $label: $artifact"
  fi
  if [[ -z "$platform_values" ]] || ! grep -Eq "^[[:space:]]*platform[[:space:]]+${EXPECTED_SIMULATOR_PLATFORM_NUMBER}([[:space:]]|$)" <<< "$otool_output"; then
    fail "built simulator artifact must target the $EXPECTED_SIMULATOR_PLATFORM_LABEL platform, not another Apple platform: $label: $artifact"
  fi
}

validate_native_release_sim_artifacts() {
  validate_native_release_sim_artifact "$CORE_LIBRARY" "libkatago_core.a"
  validate_native_release_sim_artifact "$SWIFT_SIDECAR" "libKataGoSwift.a"
  echo "NativeRelease simulator KataGo artifacts passed: libkatago_core.a and libKataGoSwift.a"
}

validate_native_release_sim_executable() {
  local executable="$1"
  local executable_mtime marker_mtime lipo_bin otool_bin lipo_output otool_output arch

  reject_symlink_components "$executable"
  if [[ ! -f "$executable" ]]; then
    fail "NativeRelease simulator app executable was not produced: $executable"
  fi
  if [[ -L "$executable" ]]; then
    fail "NativeRelease simulator app executable must not be a symbolic link: $executable"
  fi
  if [[ ! -s "$executable" ]]; then
    fail "NativeRelease simulator app executable must be non-empty: $executable"
  fi

  reject_symlink_components "$BUILD_MARKER"
  if [[ ! -f "$BUILD_MARKER" ]]; then
    fail "NativeRelease simulator build marker is missing before app executable validation: $BUILD_MARKER"
  fi
  executable_mtime="$(file_mtime_epoch "$executable")" || fail "could not read mtime for NativeRelease simulator app executable: $executable"
  marker_mtime="$(file_mtime_epoch "$BUILD_MARKER")" || fail "could not read mtime for NativeRelease simulator build marker: $BUILD_MARKER"
  if (( executable_mtime < marker_mtime )); then
    fail "NativeRelease simulator app executable is older than the build marker; refusing stale app bundle: $executable"
  fi

  lipo_bin="$(find_developer_tool lipo)" || fail "NativeRelease simulator app executable validation requires lipo or xcrun"
  if ! lipo_output="$("$lipo_bin" -info "$executable" 2>&1)"; then
    fail "NativeRelease simulator app executable must be readable by lipo: $executable: $lipo_output"
  fi
  IFS=';' read -r -a expected_arches <<< "$EXPECTED_SIMULATOR_ARCHES"
  for arch in "${expected_arches[@]}"; do
    [[ -z "$arch" ]] && continue
    if [[ "$lipo_output" != *"$arch"* ]]; then
      fail "NativeRelease simulator app executable missing expected architecture $arch: $executable: $lipo_output"
    fi
  done

  otool_bin="$(find_developer_tool otool)" || fail "NativeRelease simulator app executable validation requires otool or xcrun"
  if ! otool_output="$("$otool_bin" -l "$executable" 2>&1)"; then
    fail "NativeRelease simulator app executable must be readable by otool: $executable: $otool_output"
  fi
  if ! grep -Eq "LC_BUILD_VERSION|LC_VERSION_MIN_IPHONEOS" <<< "$otool_output"; then
    fail "NativeRelease simulator app executable is missing an iOS Mach-O build-version load command: $executable"
  fi

  local platform_values unexpected_platforms
  platform_values="$(awk '/^[[:space:]]*platform[[:space:]]+/ { print $2 }' <<< "$otool_output")"
  unexpected_platforms="$(awk -v expected="$EXPECTED_SIMULATOR_PLATFORM_NUMBER" '/^[[:space:]]*platform[[:space:]]+/ { if ($2 != expected) print $2 }' <<< "$otool_output" | sort -u | tr '\n' ' ')"
  if [[ -n "$unexpected_platforms" ]]; then
    fail "NativeRelease simulator app executable must not contain load commands for another Apple platform: $unexpected_platforms in $executable"
  fi
  if [[ -z "$platform_values" ]] || ! grep -Eq "^[[:space:]]*platform[[:space:]]+${EXPECTED_SIMULATOR_PLATFORM_NUMBER}([[:space:]]|$)" <<< "$otool_output"; then
    fail "NativeRelease simulator app executable must target the $EXPECTED_SIMULATOR_PLATFORM_LABEL platform, not another Apple platform: $executable"
  fi
  echo "NativeRelease simulator app executable passed: $EXPECTED_SIMULATOR_PLATFORM_LABEL $EXPECTED_SIMULATOR_ARCHES"
}

reject_inherited_environment

if [[ "${QIXI_NATIVE_RELEASE_SIM_VALIDATE_ONLY:-0}" == "1" ]]; then
  validate_native_release_sim_artifacts
  exit 0
fi

prepare_output_artifact "$SCREENSHOT_PATH" "full screenshot PNG"
prepare_output_artifact "$CONTENT_SCREENSHOT_PATH" "content screenshot PNG"
SCREENSHOT_CAPTURE_PATH="$(temporary_output_path "$SCREENSHOT_PATH" "capture.png")"
CONTENT_CAPTURE_PATH="$(temporary_output_path "$CONTENT_SCREENSHOT_PATH" "content.png")"
prepare_output_artifact "$SCREENSHOT_CAPTURE_PATH" "full screenshot temporary PNG"
prepare_output_artifact "$CONTENT_CAPTURE_PATH" "content screenshot temporary PNG"
trap cleanup_native_release_temp_outputs EXIT

UDID="${QIXI_NATIVE_RELEASE_SIM_UDID:-${QIXI_SIM_UDID:-}}"
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
echo "Building simulator KataGo artifact: $CMAKE_BUILD_DIR"
prepare_build_marker
QIXI_IOS_SDK=iphonesimulator \
QIXI_IOS_KATAGO_CMAKE_BUILD_DIR="$CMAKE_BUILD_DIR" \
  "$ROOT_DIR/scripts/qixi-ios-katago-cmake-preflight.sh"
validate_native_release_sim_artifacts

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light >/dev/null || true

xcode_args=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration NativeRelease
  -destination "platform=iOS Simulator,id=$UDID"
  -derivedDataPath "$DERIVED_DATA"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  "QIXI_KATAGO_IOS_LIBRARY=$CORE_LIBRARY"
  "QIXI_KATAGO_IOS_LIBRARY_DIR=$CMAKE_BUILD_DIR"
  build
)
if ! /usr/bin/xcodebuild -quiet "${xcode_args[@]}" >"$BUILD_LOG" 2>&1; then
  echo "NativeRelease simulator xcodebuild failed; last 80 log lines from $BUILD_LOG:" >&2
  tail -80 "$BUILD_LOG" >&2 || true
  exit 3
fi

APP_PATH="$DERIVED_DATA/Build/Products/NativeRelease-iphonesimulator/Qixi.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "NativeRelease simulator app was not produced: $APP_PATH" >&2
  exit 4
fi
APP_EXECUTABLE="$APP_PATH/Qixi"

APP_PATH="$APP_PATH" python3 - <<'PY'
import os
import pathlib
import plistlib
import sys

app_path = pathlib.Path(os.environ["APP_PATH"])
info_path = app_path / "Info.plist"
executable_path = app_path / "Qixi"
for path, label in ((info_path, "Info.plist"), (executable_path, "executable")):
  if not path.exists() or not path.is_file():
    print(f"NativeRelease simulator smoke failed: missing {label}: {path}", file=sys.stderr)
    raise SystemExit(5)

info = plistlib.loads(info_path.read_bytes())
if info.get("QixiAnalysisRuntime") != "nativeInProcess":
  print("NativeRelease simulator smoke failed: app must default to nativeInProcess", file=sys.stderr)
  raise SystemExit(5)
if "QixiBackendBaseURL" in info:
  print("NativeRelease simulator smoke failed: app must not ship QixiBackendBaseURL", file=sys.stderr)
  raise SystemExit(5)
if "iPhoneSimulator" not in info.get("CFBundleSupportedPlatforms", []):
  print("NativeRelease simulator smoke failed: app must target iPhoneSimulator", file=sys.stderr)
  raise SystemExit(5)

binary = executable_path.read_bytes()
for token in (
  b"Native KataGo is not linked into this build.",
  b"PlaceholderNativeKataGoEngine",
  b"BackendClient",
  b"HTTPBridgeAnalysisService",
  b"Qixi HTTP bridge response",
  b"QixiBackendBaseURL",
  b"qixi.backendBaseURL",
  b"QIXI_ANALYSIS_RUNTIME",
  b"QIXI_BACKEND_URL",
  b"QIXI_DEVICE_BACKEND_URL",
  b"http://127.0.0.1:8765",
  b"127.0.0.1:8765",
  b"localhost:8765",
):
  if token in binary:
    print(
      f"NativeRelease simulator smoke failed: executable contains forbidden bridge string {token.decode()}",
      file=sys.stderr,
    )
    raise SystemExit(5)
PY
validate_native_release_sim_executable "$APP_EXECUTABLE"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP_PATH"
SIMCTL_CHILD_QIXI_SKIP_ONBOARDING=1 \
SIMCTL_CHILD_QIXI_APP_LANGUAGE="$APP_LANGUAGE" \
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >"$LAUNCH_LOG"
APP_PID="$(
  BUNDLE_ID="$BUNDLE_ID" LAUNCH_LOG="$LAUNCH_LOG" python3 - <<'PY'
import os
import pathlib
import re
import sys

bundle_id = os.environ["BUNDLE_ID"]
text = pathlib.Path(os.environ["LAUNCH_LOG"]).read_text(encoding="utf-8", errors="replace")
match = re.search(rf"^{re.escape(bundle_id)}:\s*(\d+)\s*$", text, re.MULTILINE)
if not match:
  print(f"could not parse launched app pid from simctl output: {text!r}", file=sys.stderr)
  raise SystemExit(1)
pid = int(match.group(1))
if pid <= 0:
  print(f"invalid launched app pid: {pid}", file=sys.stderr)
  raise SystemExit(1)
print(pid)
PY
)" || fail "could not verify NativeRelease simulator launch pid"
sleep 2
if ! xcrun simctl spawn "$UDID" /bin/kill -0 "$APP_PID" >/dev/null 2>&1; then
  tail -40 "$LAUNCH_LOG" >&2 || true
  fail "launched app process $APP_PID is not running before screenshot"
fi
xcrun simctl io "$UDID" screenshot --mask ignored "$SCREENSHOT_CAPTURE_PATH" >/dev/null

SCREENSHOT_PATH="$SCREENSHOT_PATH" CONTENT_SCREENSHOT_PATH="$CONTENT_SCREENSHOT_PATH" SCREENSHOT_CAPTURE_PATH="$SCREENSHOT_CAPTURE_PATH" CONTENT_CAPTURE_PATH="$CONTENT_CAPTURE_PATH" python3 - <<'PY'
from PIL import Image, ImageStat
import os
import pathlib
import sys
import stat as stat_module

path = pathlib.Path(os.environ["SCREENSHOT_PATH"])
content_path = pathlib.Path(os.environ["CONTENT_SCREENSHOT_PATH"])
capture_path = pathlib.Path(os.environ["SCREENSHOT_CAPTURE_PATH"])
content_capture_path = pathlib.Path(os.environ["CONTENT_CAPTURE_PATH"])


def fail(message: str, code: int = 6) -> None:
  print(f"NativeRelease simulator smoke failed: {message}", file=sys.stderr)
  raise SystemExit(code)


def require_replace_target(target: pathlib.Path, label: str) -> None:
  try:
    existing = target.lstat()
  except FileNotFoundError:
    return
  if stat_module.S_ISLNK(existing.st_mode):
    fail(f"{label} target must not be a symbolic link: {target}")
  if not stat_module.S_ISREG(existing.st_mode):
    fail(f"{label} target must be a regular file: {target}")


def fsync_parent_directory(target: pathlib.Path, label: str) -> None:
  parent = target.parent
  allowed_aliases = {
    pathlib.Path("/var"): pathlib.Path("/private/var"),
    pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
    pathlib.Path("/etc"): pathlib.Path("/private/etc"),
  }
  for alias, resolved_alias in allowed_aliases.items():
    try:
      suffix = parent.relative_to(alias)
    except ValueError:
      continue
    try:
      if alias.is_symlink() and alias.resolve(strict=True) == resolved_alias:
        parent = resolved_alias / suffix
    except OSError:
      pass
    break
  flags = os.O_RDONLY
  if hasattr(os, "O_DIRECTORY"):
    flags |= os.O_DIRECTORY
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
  parent_fd = os.open(parent, flags)
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


image = Image.open(capture_path).convert("RGB")
width, height = image.size
if width < 1000 or height < 1000:
  fail(f"screenshot too small: {width}x{height}")

pixels = image.load()
left, top, right, bottom = width, height, -1, -1
nonblack = 0
for y in range(height):
  for x in range(width):
    red, green, blue = pixels[x, y]
    if max(red, green, blue) > 32:
      nonblack += 1
      left = min(left, x)
      top = min(top, y)
      right = max(right, x)
      bottom = max(bottom, y)

if nonblack < width * height * 0.25:
  fail("screenshot is mostly black")
content_width = right - left + 1
content_height = bottom - top + 1
if content_width <= content_height:
  fail(f"visible app content is not landscape: {content_width}x{content_height}")

content = image.crop((left, top, right + 1, bottom + 1))
content.save(content_capture_path)
content_stat = ImageStat.Stat(content)
if sum(content_stat.var) < 100:
  fail("visible app content has too little visual detail")

replace_artifact(capture_path, path, "NativeRelease full screenshot artifact")
replace_artifact(content_capture_path, content_path, "NativeRelease content screenshot artifact")

print(
  "NativeRelease simulator screenshot passed: "
  f"frame={width}x{height} content={content_width}x{content_height}"
)
PY

python3 "$NATIVE_DIR/tests/inspect_screenshot.py" "$CONTENT_SCREENSHOT_PATH"

echo "NativeRelease simulator smoke passed"
