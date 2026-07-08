#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMAKE_BIN="${CMAKE_BIN:-/opt/homebrew/bin/cmake}"
DEFAULT_IOS_DEPLOYMENT_TARGET="17.0"
DEFAULT_IOS_SDK="iphonesimulator"
DEFAULT_IOS_ARCH="arm64"
IOS_DEPLOYMENT_TARGET="${QIXI_IOS_DEPLOYMENT_TARGET:-$DEFAULT_IOS_DEPLOYMENT_TARGET}"
IOS_SDK="${QIXI_IOS_SDK:-$DEFAULT_IOS_SDK}"
IOS_ARCH="${QIXI_IOS_ARCH:-${QIXI_IOS_SIM_ARCH:-$DEFAULT_IOS_ARCH}}"
case "$IOS_SDK" in
  iphonesimulator)
    DEFAULT_SWIFT_TARGET="${DEFAULT_IOS_ARCH}-apple-ios${DEFAULT_IOS_DEPLOYMENT_TARGET}-simulator"
    SWIFT_TARGET="${QIXI_IOS_SWIFT_TARGET:-${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator}"
    EXPECTED_PLATFORM_NUMBER="7"
    EXPECTED_PLATFORM_LABEL="iOS Simulator"
    ;;
  iphoneos)
    DEFAULT_SWIFT_TARGET="${DEFAULT_IOS_ARCH}-apple-ios${DEFAULT_IOS_DEPLOYMENT_TARGET}"
    SWIFT_TARGET="${QIXI_IOS_SWIFT_TARGET:-${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}}"
    EXPECTED_PLATFORM_NUMBER="2"
    EXPECTED_PLATFORM_LABEL="iOS device"
    ;;
  *)
    echo "iOS KataGo CMake preflight failed: QIXI_IOS_SDK must be iphonesimulator or iphoneos, got $IOS_SDK" >&2
    exit 1
    ;;
esac
if [[ -z "${QIXI_IOS_DEPLOYMENT_TARGET:-}" && -z "${QIXI_IOS_ARCH:-}" && -z "${QIXI_IOS_SIM_ARCH:-}" && -z "${QIXI_IOS_SWIFT_TARGET:-}" ]]; then
  SWIFT_TARGET="$DEFAULT_SWIFT_TARGET"
fi
BUILD_TARGET="${QIXI_IOS_KATAGO_BUILD_TARGET:-katago_core}"
SAFE_BUILD_TARGET="${BUILD_TARGET//[^A-Za-z0-9_.-]/_}"
SAFE_IOS_SDK="${IOS_SDK//[^A-Za-z0-9_.-]/_}"
BUILD_DIR="${QIXI_IOS_KATAGO_CMAKE_BUILD_DIR:-/private/tmp/qixi-ios-katago-cmake-preflight-${SAFE_IOS_SDK}-${SAFE_BUILD_TARGET}-$$}"
LOG_FILE="${BUILD_DIR}.log"
SAFE_BUILD_DIR_PREFIX="qixi-ios-katago-cmake-preflight-"

fail() {
  echo "iOS KataGo CMake preflight failed: $*" >&2
  if [[ -f "$LOG_FILE" ]]; then
    echo "--- cmake output tail ---" >&2
    tail -80 "$LOG_FILE" >&2 || true
  fi
  exit 1
}

if [[ ! -x "$CMAKE_BIN" ]]; then
  fail "cmake was not found at $CMAKE_BIN"
fi

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

canonical_dirname() {
  local path="$1"
  local parent
  parent="$(dirname "$path")"
  if [[ ! -d "$parent" ]]; then
    fail "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR parent does not exist: $parent"
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
      fail "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR must not contain parent-directory traversal: $path"
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
      fail "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR must not contain symbolic links: $current"
    fi
  done
}

validate_build_dir() {
  if [[ -z "$BUILD_DIR" ]]; then
    fail "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR must not be empty"
  fi
  if [[ "$BUILD_DIR" != /* ]]; then
    fail "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR must be an absolute path under /private/tmp or /tmp"
  fi
  reject_symlink_components "$BUILD_DIR"
  local base parent_real
  base="$(basename "$BUILD_DIR")"
  if [[ "$base" != ${SAFE_BUILD_DIR_PREFIX}* ]]; then
    fail "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR basename must start with ${SAFE_BUILD_DIR_PREFIX}"
  fi
  parent_real="$(canonical_dirname "$BUILD_DIR")"
  case "$parent_real" in
    /private/tmp|/tmp)
      ;;
    *)
      fail "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR must stay directly under /private/tmp or /tmp, got $BUILD_DIR"
      ;;
  esac
  if [[ -e "$BUILD_DIR" && ! -d "$BUILD_DIR" ]]; then
    fail "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR exists but is not a directory: $BUILD_DIR"
  fi
}

artifact_for_target() {
  local artifact_override="${QIXI_IOS_KATAGO_ARTIFACT_PATH:-}"
  local artifact
  if [[ -n "$artifact_override" ]]; then
    if [[ "$artifact_override" == /* ]]; then
      artifact="$artifact_override"
    else
      artifact="$BUILD_DIR/$artifact_override"
    fi
    case "$artifact" in
      "$BUILD_DIR"/*)
        ;;
      *)
        fail "QIXI_IOS_KATAGO_ARTIFACT_PATH must stay inside the validated CMake build directory"
        ;;
    esac
    printf '%s\n' "$artifact"
    return 0
  fi

  case "$BUILD_TARGET" in
    katago_core)
      printf '%s\n' "$BUILD_DIR/libkatago_core.a"
      ;;
    KataGoSwift)
      printf '%s\n' "$BUILD_DIR/libKataGoSwift.a"
      ;;
    katago)
      if [[ -f "$BUILD_DIR/katago.app/katago" ]]; then
        printf '%s\n' "$BUILD_DIR/katago.app/katago"
      else
        printf '%s\n' "$BUILD_DIR/katago"
      fi
      ;;
    *)
      fail "QIXI_IOS_KATAGO_ARTIFACT_PATH must be set for custom build target $BUILD_TARGET"
      ;;
  esac
}

validate_built_artifact() {
  local artifact="$1"
  local lipo_bin otool_bin lipo_output otool_output arch
  reject_symlink_components "$artifact"
  if [[ ! -f "$artifact" ]]; then
    fail "built artifact was not produced for $BUILD_TARGET: $artifact"
  fi
  if [[ -L "$artifact" ]]; then
    fail "built artifact must not be a symbolic link: $artifact"
  fi

  lipo_bin="$(find_developer_tool lipo)" || fail "built artifact validation requires lipo or xcrun"
  if ! lipo_output="$("$lipo_bin" -info "$artifact" 2>&1)"; then
    fail "built artifact must be readable by lipo: $artifact: $lipo_output"
  fi
  IFS=';' read -r -a expected_arches <<< "$IOS_ARCH"
  for arch in "${expected_arches[@]}"; do
    [[ -z "$arch" ]] && continue
    if [[ "$lipo_output" != *"$arch"* ]]; then
      fail "built artifact missing expected architecture $arch for $IOS_SDK: $artifact: $lipo_output"
    fi
  done

  otool_bin="$(find_developer_tool otool)" || fail "built artifact validation requires otool or xcrun"
  if ! otool_output="$("$otool_bin" -l "$artifact" 2>&1)"; then
    fail "built artifact must be readable by otool: $artifact: $otool_output"
  fi
  if ! grep -Eq "LC_BUILD_VERSION|LC_VERSION_MIN_IPHONEOS" <<< "$otool_output"; then
    fail "built artifact is missing an iOS Mach-O build-version load command: $artifact"
  fi
  local platform_values unexpected_platforms
  platform_values="$(awk '/^[[:space:]]*platform[[:space:]]+/ { print $2 }' <<< "$otool_output")"
  unexpected_platforms="$(awk -v expected="$EXPECTED_PLATFORM_NUMBER" '/^[[:space:]]*platform[[:space:]]+/ { if ($2 != expected) print $2 }' <<< "$otool_output" | sort -u | tr '\n' ' ')"
  if [[ -n "$unexpected_platforms" ]]; then
    fail "built artifact must not contain object files for another Apple platform: $unexpected_platforms in $artifact"
  fi
  if [[ -z "$platform_values" ]] || ! grep -Eq "^[[:space:]]*platform[[:space:]]+${EXPECTED_PLATFORM_NUMBER}([[:space:]]|$)" <<< "$otool_output"; then
    fail "built artifact must target the $EXPECTED_PLATFORM_LABEL platform for $IOS_SDK, not another Apple platform: $artifact"
  fi
  if grep -Eq "^[[:space:]]*minos[[:space:]]+" <<< "$otool_output" &&
    ! grep -Eq "^[[:space:]]*minos[[:space:]]+${IOS_DEPLOYMENT_TARGET}([[:space:]]|$)" <<< "$otool_output"; then
    fail "built artifact did not preserve iOS deployment target minos $IOS_DEPLOYMENT_TARGET: $artifact"
  fi
}

validate_build_dir
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

set +e
"$CMAKE_BIN" \
  -G Ninja \
  -S "$ROOT_DIR/KataGo/cpp" \
  -B "$BUILD_DIR" \
  -DUSE_BACKEND=METAL \
  -DNO_GIT_REVISION=1 \
  -DKATAGO_METAL_ENABLE_COREML_CONVERSION=0 \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$IOS_SDK" \
  -DCMAKE_OSX_ARCHITECTURES="$IOS_ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
  -DCMAKE_Swift_COMPILER_TARGET="$SWIFT_TARGET" \
  >"$LOG_FILE" 2>&1
cmake_status=$?
set -e

if [[ $cmake_status -ne 0 ]]; then
  if grep -q "unable to load standard library for target '.*apple-macosx" "$LOG_FILE"; then
    fail "Swift was still targeting macOS; keep CMAKE_Swift_COMPILER_TARGET=$SWIFT_TARGET for iOS $IOS_SDK builds"
  fi
  if grep -q "Could NOT find Protobuf" "$LOG_FILE"; then
    fail "iOS configure unexpectedly touched Protobuf; KATAGO_METAL_ENABLE_COREML_CONVERSION=0 should keep katagocoreml out of the runtime build"
  fi
  fail "cmake configure did not complete for the iOS $IOS_SDK Metal build"
fi

if ! grep -q "CMAKE_Swift_COMPILER_TARGET:.*$SWIFT_TARGET" "$BUILD_DIR/CMakeCache.txt"; then
  fail "CMakeCache.txt did not preserve CMAKE_Swift_COMPILER_TARGET=$SWIFT_TARGET"
fi

"$CMAKE_BIN" --build "$BUILD_DIR" --target help >"${BUILD_DIR}.targets" 2>&1

if ! grep -q "^katago:" "${BUILD_DIR}.targets"; then
  fail "CMake did not expose the katago target for the iOS $IOS_SDK build"
fi
if ! grep -q "^${BUILD_TARGET}:" "${BUILD_DIR}.targets"; then
  fail "CMake did not expose requested build target ${BUILD_TARGET}"
fi

set +e
"$CMAKE_BIN" --build "$BUILD_DIR" --target "$BUILD_TARGET" -j "${QIXI_IOS_KATAGO_BUILD_JOBS:-4}" >>"$LOG_FILE" 2>&1
swift_status=$?
set -e

if [[ $swift_status -ne 0 ]]; then
  fail "$BUILD_TARGET did not compile for the iOS $IOS_SDK Metal build"
fi

BUILT_ARTIFACT="$(artifact_for_target)"
validate_built_artifact "$BUILT_ARTIFACT"

echo "iOS KataGo CMake preflight passed for $IOS_SDK target $BUILD_TARGET"
