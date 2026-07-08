#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PROJECT="$ROOT_DIR/qixi-ios-native/Qixi.xcodeproj"
SCHEME="Qixi"
CONFIGURATION="NativeRelease"
DESTINATION="${QIXI_NATIVE_RELEASE_DESTINATION:-generic/platform=iOS}"
DERIVED_DATA="${QIXI_NATIVE_RELEASE_DERIVED_DATA:-/private/tmp/qixi-native-release-build-preflight-$$}"
BUILD_LOG="${DERIVED_DATA}.log"
APP_PATH="${QIXI_NATIVE_RELEASE_APP_PATH:-$DERIVED_DATA/Build/Products/NativeRelease-iphoneos/Qixi.app}"
SAFE_DERIVED_DATA_PREFIX="qixi-native-release-build-preflight-"
ARTIFACT_VALIDATION_ONLY="${QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_ARTIFACT_VALIDATION_ONLY:-0}"
TESTING_MODE="${QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_TESTING:-0}"

fail() {
  echo "Native release build preflight failed: $*" >&2
  if [[ -f "$BUILD_LOG" ]]; then
    echo "--- xcodebuild output tail ---" >&2
    tail -80 "$BUILD_LOG" >&2 || true
  fi
  exit 1
}

require_xcodebuild_iphoneos() {
  local xcodebuild_path
  if ! xcodebuild_path="$(command -v xcodebuild)"; then
    fail "native release build requires xcodebuild in PATH"
  fi
  if [[ "$xcodebuild_path" != "/usr/bin/xcodebuild" ]]; then
    fail "native release build requires xcodebuild to resolve to /usr/bin/xcodebuild, got $xcodebuild_path; do not shadow xcodebuild in PATH"
  fi

  local sdk_output
  if ! sdk_output="$("$xcodebuild_path" -showsdks 2>&1)"; then
    fail "native release build requires xcodebuild -showsdks to succeed: $sdk_output"
  fi
  if [[ "$sdk_output" != *iphoneos* ]]; then
    fail "native release build requires xcodebuild -showsdks to report an iphoneos SDK"
  fi
}

canonical_dirname() {
  local path="$1"
  local parent
  parent="$(dirname "$path")"
  if [[ ! -d "$parent" ]]; then
    fail "QIXI_NATIVE_RELEASE_DERIVED_DATA parent does not exist: $parent"
  fi
  (cd "$parent" && pwd -P)
}

reject_symlink_components() {
  local path="$1"
  local current=""
  local target
  if [[ "$path" == /* ]]; then
    current="/"
  fi
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ -z "$part" || "$part" == "." ]] && continue
    if [[ "$part" == ".." ]]; then
      fail "QIXI_NATIVE_RELEASE_DERIVED_DATA must not contain parent-directory traversal: $path"
    fi
    if [[ "$current" == "/" ]]; then
      current="/$part"
    elif [[ -z "$current" ]]; then
      current="$part"
    else
      current="$current/$part"
    fi
    if [[ -L "$current" ]]; then
      if [[ "$current" == "/tmp" ]]; then
        target="$(cd "$current" && pwd -P)"
        if [[ "$target" == "/private/tmp" ]]; then
          continue
        fi
      fi
      fail "QIXI_NATIVE_RELEASE_DERIVED_DATA must not contain symbolic links: $current"
    fi
  done
}

validate_derived_data() {
  if [[ -z "$DERIVED_DATA" ]]; then
    fail "QIXI_NATIVE_RELEASE_DERIVED_DATA must not be empty"
  fi
  if [[ "$DERIVED_DATA" != /* ]]; then
    fail "QIXI_NATIVE_RELEASE_DERIVED_DATA must be an absolute path under /private/tmp or /tmp"
  fi
  reject_symlink_components "$DERIVED_DATA"
  local base parent_real
  base="$(basename "$DERIVED_DATA")"
  if [[ "$base" != ${SAFE_DERIVED_DATA_PREFIX}* ]]; then
    fail "QIXI_NATIVE_RELEASE_DERIVED_DATA basename must start with ${SAFE_DERIVED_DATA_PREFIX}"
  fi
  parent_real="$(canonical_dirname "$DERIVED_DATA")"
  case "$parent_real" in
    /private/tmp|/tmp)
      ;;
    *)
      fail "QIXI_NATIVE_RELEASE_DERIVED_DATA must stay directly under /private/tmp or /tmp, got $DERIVED_DATA"
      ;;
  esac
  if [[ -e "$DERIVED_DATA" && ! -d "$DERIVED_DATA" ]]; then
    fail "QIXI_NATIVE_RELEASE_DERIVED_DATA exists but is not a directory: $DERIVED_DATA"
  fi
}

cd "$ROOT_DIR"

if [[ "$ARTIFACT_VALIDATION_ONLY" == "1" ]]; then
  if [[ "$TESTING_MODE" != "1" ]]; then
    fail "QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_ARTIFACT_VALIDATION_ONLY may only be used with QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_TESTING=1"
  fi
else
  require_xcodebuild_iphoneos
  validate_derived_data
  scripts/qixi-native-linked-build-preflight.sh

  xcode_settings=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
  )
  for key in KATAGO_CPP_INCLUDE_DIR QIXI_KATAGO_IOS_XCFRAMEWORK QIXI_KATAGO_IOS_LIBRARY QIXI_KATAGO_IOS_LIBRARY_DIR; do
    if [[ -n "${!key:-}" ]]; then
      xcode_settings+=("$key=${!key}")
    fi
  done

  if ! /usr/bin/xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    "${xcode_settings[@]}" \
    build >"$BUILD_LOG" 2>&1; then
    fail "xcodebuild NativeRelease failed"
  fi
fi

APP_PATH="$APP_PATH" PYTHON_BIN="$PYTHON_BIN" "$PYTHON_BIN" - <<'PY'
from __future__ import annotations

import os
import pathlib
import plistlib
import stat as stat_module
import subprocess
import sys
import tempfile

APP_PATH = pathlib.Path(os.environ["APP_PATH"])
PLIST_MAX_BYTES = 1 * 1024 * 1024
EXECUTABLE_MAX_BYTES = 256 * 1024 * 1024
FORBIDDEN_EXECUTABLE_STRINGS = (
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
)


def fail(message: str) -> None:
  print(f"Native release build preflight failed: {message}", file=sys.stderr)
  raise SystemExit(1)


def opened_regular_file_stat(handle, path: pathlib.Path, label: str) -> os.stat_result:
  try:
    opened_stat = os.fstat(handle.fileno())
  except OSError as exc:
    fail(f"{label} could not be inspected after opening: {path}: {exc}")
  if not stat_module.S_ISREG(opened_stat.st_mode):
    fail(f"{label} must be a regular file after opening: {path}")
  return opened_stat


def is_allowed_platform_symlink_alias(path: pathlib.Path) -> bool:
  if sys.platform != "darwin":
    return False
  allowed_aliases = {
    pathlib.Path("/var"): pathlib.Path("/private/var"),
    pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
    pathlib.Path("/etc"): pathlib.Path("/private/etc"),
  }
  expected_target = allowed_aliases.get(path)
  if expected_target is None:
    return False
  try:
    return path.resolve(strict=True) == expected_target
  except OSError:
    return False


def reject_symlink_components(path: pathlib.Path, label: str) -> None:
  current = pathlib.Path(path.anchor) if path.anchor else pathlib.Path()
  for part in path.parts:
    if part == path.anchor or not part:
      continue
    current = current / part
    if current.is_symlink() and not is_allowed_platform_symlink_alias(current):
      fail(f"{label} must not contain symbolic links: {current}")


def validate_regular_file(path: pathlib.Path, label: str) -> None:
  reject_symlink_components(path, label)
  if not path.exists():
    fail(f"{label} does not exist: {path}")
  if not path.is_file():
    fail(f"{label} is not a regular file: {path}")


def validate_directory(path: pathlib.Path, label: str) -> None:
  reject_symlink_components(path, label)
  if not path.exists():
    fail(f"{label} does not exist: {path}")
  if not path.is_dir():
    fail(f"{label} is not a directory: {path}")


def bounded_bytes(path: pathlib.Path, label: str, max_bytes: int) -> bytes:
  validate_regular_file(path, label)
  try:
    size = path.stat().st_size
  except OSError as exc:
    fail(f"{label} could not be statted: {path}: {exc}")
  if size > max_bytes:
    fail(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {path}")
  try:
    with path.open("rb") as handle:
      opened_stat = opened_regular_file_stat(handle, path, label)
      if opened_stat.st_size > max_bytes:
        fail(f"{label} exceeds bounded size of {max_bytes} bytes after opening: {path}")
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    fail(f"{label} could not be read: {path}: {exc}")
  if len(data) > max_bytes:
    fail(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {path}")
  return data


def selftest_opened_descriptor_recheck() -> None:
  with tempfile.TemporaryDirectory() as raw_dir:
    directory = pathlib.Path(raw_dir)
    fd = os.open(directory, os.O_RDONLY)
    try:
      class DirectoryHandle:
        def fileno(self) -> int:
          return fd

      opened_regular_file_stat(DirectoryHandle(), directory / "Info.plist", "NativeRelease app Info.plist")
    finally:
      os.close(fd)
  fail("opened descriptor self-test did not reject a directory descriptor")


if os.environ.get("QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR") == "1":
  selftest_opened_descriptor_recheck()


def developer_tool(name: str) -> str:
  for candidate in (f"/usr/bin/{name}", f"/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/{name}"):
    if pathlib.Path(candidate).exists():
      return candidate
  xcrun = pathlib.Path("/usr/bin/xcrun")
  if xcrun.exists():
    result = subprocess.run([str(xcrun), "--find", name], text=True, capture_output=True, check=False)
    if result.returncode == 0 and result.stdout.strip():
      return result.stdout.strip()
  fail(f"native release build validation requires {name}")


validate_directory(APP_PATH, "NativeRelease app bundle")
info_path = APP_PATH / "Info.plist"
try:
  info = plistlib.loads(bounded_bytes(info_path, "NativeRelease app Info.plist", PLIST_MAX_BYTES))
except Exception as exc:
  fail(f"NativeRelease app Info.plist could not be parsed: {exc}")
if not isinstance(info, dict):
  fail("NativeRelease app Info.plist must be a dictionary")

if info.get("QixiAnalysisRuntime") != "nativeInProcess":
  fail("NativeRelease app must default QixiAnalysisRuntime to nativeInProcess")
if "QixiBackendBaseURL" in info:
  fail("NativeRelease app must not ship QixiBackendBaseURL")
supported_platforms = info.get("CFBundleSupportedPlatforms", [])
if "iPhoneOS" not in supported_platforms:
  fail("NativeRelease app CFBundleSupportedPlatforms must include iPhoneOS")

executable_name = info.get("CFBundleExecutable")
if not isinstance(executable_name, str) or not executable_name:
  fail("NativeRelease app Info.plist must contain CFBundleExecutable")
executable_path = APP_PATH / executable_name
executable = bounded_bytes(executable_path, "NativeRelease app executable", EXECUTABLE_MAX_BYTES)
for forbidden in FORBIDDEN_EXECUTABLE_STRINGS:
  if forbidden in executable:
    fail(f"NativeRelease app executable must not contain development bridge or placeholder string: {forbidden.decode('utf-8')}")

lipo = developer_tool("lipo")
lipo_result = subprocess.run([lipo, "-info", str(executable_path)], text=True, capture_output=True, check=False)
lipo_output = f"{lipo_result.stdout}\n{lipo_result.stderr}".strip()
if lipo_result.returncode != 0:
  fail(f"NativeRelease app executable must be readable by lipo: {lipo_output}")
if "arm64" not in lipo_output:
  fail(f"NativeRelease app executable must contain arm64: {lipo_output}")

otool = developer_tool("otool")
otool_result = subprocess.run([otool, "-l", str(executable_path)], text=True, capture_output=True, check=False)
otool_output = f"{otool_result.stdout}\n{otool_result.stderr}".strip()
if otool_result.returncode != 0:
  fail(f"NativeRelease app executable must be readable by otool: {otool_output}")
normalized = otool_output.lower()
if "lc_version_min_iphoneos" not in normalized and "platform 2" not in normalized and "platform ios" not in normalized:
  fail("NativeRelease app executable must target the iOS device platform")

print("NativeRelease build artifact validation passed")
PY

echo "Native release build preflight passed"
