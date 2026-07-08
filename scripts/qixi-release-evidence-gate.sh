#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

fail() {
  echo "Release evidence gate failed: $*" >&2
  exit 1
}

run_step() {
  local name="$1"
  shift
  echo "==> $name"
  "$@"
}

require_xcodebuild_iphoneos() {
  local xcodebuild_path
  if ! xcodebuild_path="$(command -v xcodebuild)"; then
    fail "release evidence requires xcodebuild in PATH; scripts/qixi-quality-gate.sh must perform the native Xcode build instead of skipping it"
  fi
  if [[ "$xcodebuild_path" != "/usr/bin/xcodebuild" ]]; then
    fail "release evidence requires xcodebuild to resolve to /usr/bin/xcodebuild, got $xcodebuild_path; do not shadow xcodebuild in PATH"
  fi

  local sdk_output
  if ! sdk_output="$("$xcodebuild_path" -showsdks 2>&1)"; then
    fail "release evidence requires xcodebuild -showsdks to succeed before release validation: $sdk_output"
  fi
  if [[ "$sdk_output" != *iphoneos* ]]; then
    fail "release evidence requires xcodebuild -showsdks to report an iphoneos SDK before release validation"
  fi
}

cd "$ROOT_DIR"

if [[ -z "${QIXI_REAL_DEVICE_EVIDENCE:-}" ]]; then
  fail "QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json is required"
fi

if [[ "${QIXI_REAL_DEVICE_EXPECT_RUNTIME:-}" != "nativeInProcess" ]]; then
  fail "release evidence requires QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess; httpBridge evidence is only a development smoke and cannot prove App Store-ready fully on-device KataGo"
fi

if [[ -n "${QIXI_DEVICE_BACKEND_URL:-}" || -n "${QIXI_BACKEND_URL:-}" ]]; then
  fail "fully native evidence must not set QIXI_DEVICE_BACKEND_URL or QIXI_BACKEND_URL; omit backend transport entirely when QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess"
fi

if [[ -z "${QIXI_APPSTORE_ARCHIVE_PATH:-}" ]]; then
  fail "QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive is required"
fi

if [[ "${QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW:-0}" != "1" ]]; then
  fail "set QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW=1 after reviewing an archive/privacy report and App Store metadata"
fi

if [[ "${QIXI_SKIP_XCODEBUILD:-0}" != "0" ]]; then
  fail "release evidence must not set QIXI_SKIP_XCODEBUILD; release proof requires the native Xcode build inside scripts/qixi-quality-gate.sh"
fi

require_xcodebuild_iphoneos

# Validates QIXI_APPSTORE_ARCHIVE_PATH and archived PrivacyInfo.xcprivacy.
run_step "App Store archive preflight" \
  env QIXI_REQUIRE_APPSTORE_DISTRIBUTION_SIGNATURE=1 scripts/qixi-appstore-archive-preflight.sh

run_step "release evidence/archive identity match" \
  "$PYTHON_BIN" scripts/qixi_release_evidence_archive_match.py

run_step "real-device evidence preflight" \
  scripts/qixi-real-device-evidence-preflight.sh

run_step "App Store submission preflight" \
  env QIXI_APPSTORE_SUBMISSION=1 scripts/qixi-appstore-preflight.sh

run_step "native linked build preflight" \
  scripts/qixi-native-linked-build-preflight.sh

run_step "native release Xcode build preflight" \
  scripts/qixi-native-release-build-preflight.sh

run_step "iOS KataGo CMake preflight" \
  env QIXI_IOS_SDK=iphoneos QIXI_IOS_KATAGO_BUILD_TARGET=katago_core scripts/qixi-ios-katago-cmake-preflight.sh

echo "Skipping strict physical-device backend preflight because release evidence must be nativeInProcess"

run_step "full screenshot, iOS CMake, NativeRelease simulator, and real-model quality gate" \
  env QIXI_REQUIRE_TRACKED_FILE_AUDIT=1 QIXI_RUN_SCREENSHOTS=1 QIXI_RUN_IOS_KATAGO_CMAKE=1 QIXI_RUN_NATIVE_RELEASE_SIM=1 QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh

run_step "screenshot manifest artifact inspection" \
  "$PYTHON_BIN" qixi-ios-native/tests/inspect_screenshot_manifest_artifacts.py

echo "Qixi release evidence gate passed"
