#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
NODE_BIN="${NODE_BIN:-node}"
DERIVED_DATA="${QIXI_DERIVED_DATA:-/private/tmp/qixi-quality-derived}"
XCODE_DESTINATION="${QIXI_XCODE_DESTINATION:-generic/platform=iOS Simulator}"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

run_step() {
  local name="$1"
  shift
  echo "==> $name"
  "$@"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

quality_xcodebuild_path() {
  local xcodebuild_path
  if ! xcodebuild_path="$(command -v xcodebuild)"; then
    return 1
  fi
  if [[ "$xcodebuild_path" != "/usr/bin/xcodebuild" ]]; then
    echo "Quality gate native Xcode build requires xcodebuild to resolve to /usr/bin/xcodebuild, got $xcodebuild_path; do not shadow xcodebuild in PATH" >&2
    return 2
  fi
  printf '%s\n' "$xcodebuild_path"
}

cleanup_recoverable_xcode_ui_state() {
  find qixi-ios-native/Qixi.xcodeproj -name "*.xcuserstate" -type f -delete 2>/dev/null || true
}

cleanup_recoverable_python_bytecode() {
  find scripts tests qixi-ios-native qixi-ios-sim \
    \( -name "__pycache__" -type d -prune -exec rm -rf {} + \) -o \
    \( -name "*.pyc" -type f -delete \) 2>/dev/null || true
}

cleanup_recoverable_macos_metadata() {
  find . \
    \( -path "./.git" -o -path "./KataGo/.git" \) -prune -o \
    \( -name ".DS_Store" -type f -delete \) 2>/dev/null || true
}

cleanup_recoverable_tool_caches() {
  find . \
    \( -path "./.git" -o -path "./KataGo/.git" \) -prune -o \
    \( \
      -name ".pytest_cache" -o \
      -name ".mypy_cache" -o \
      -name ".ruff_cache" \
    \) -type d -prune -exec rm -rf {} + 2>/dev/null || true
  find . \
    \( -path "./.git" -o -path "./KataGo/.git" \) -prune -o \
    \( \
      -name ".coverage" -o \
      -name "coverage.xml" -o \
      -name "npm-debug.log*" -o \
      -name "yarn-debug.log*" -o \
      -name "yarn-error.log*" -o \
      -name "pnpm-debug.log*" \
    \) -type f -delete 2>/dev/null || true
}

cleanup_recoverable_generated_state() {
  cleanup_recoverable_xcode_ui_state
  cleanup_recoverable_python_bytecode
  cleanup_recoverable_macos_metadata
  cleanup_recoverable_tool_caches
}

cd "$ROOT_DIR"
trap cleanup_recoverable_generated_state EXIT

run_step "project quality contract" "$PYTHON_BIN" tests/test_project_quality_contract.py
run_step "quality gate skip audit contract" "$PYTHON_BIN" tests/test_quality_gate_skip_audit.py
run_step "changed-surface gate contract" "$PYTHON_BIN" tests/test_changed_surface_gate.py
run_step "device run preflight contract" "$PYTHON_BIN" tests/test_device_run_preflight.py
run_step "device signing doctor contract" "$PYTHON_BIN" tests/test_device_signing_doctor.py
run_step "device bridge smoke contract" "$PYTHON_BIN" tests/test_device_bridge_smoke.py
run_step "device bridge smoke artifact inspector contract" "$PYTHON_BIN" tests/test_device_bridge_smoke_inspector.py
run_step "position identity fixture contract" "$PYTHON_BIN" tests/test_position_identity_fixture_validator.py
run_step "repository hygiene contract" "$PYTHON_BIN" tests/test_repo_hygiene_preflight.py
run_step "backend contract" "$PYTHON_BIN" qixi-ios-sim/tests/test_backend_contract.py
run_step "real-model artifact inspector contract" "$PYTHON_BIN" qixi-ios-sim/tests/test_real_model_artifact_inspector.py
run_step "real-model integration response parser contract" "$PYTHON_BIN" qixi-ios-sim/tests/test_real_model_integration_response_parser.py

if command_exists "$NODE_BIN"; then
  run_step "web simulator UI contract" "$NODE_BIN" qixi-ios-sim/tests/ui_contract.mjs
else
  echo "Skipping web simulator UI contract: node not found"
fi

run_step "native frontend contract" "$PYTHON_BIN" qixi-ios-native/tests/test_frontend_contract.py
run_step "native localization contract" "$PYTHON_BIN" qixi-ios-native/tests/test_localization_contract.py
run_step "native protected build marker contract" "$PYTHON_BIN" qixi-ios-native/tests/test_protected_build_marker.py
run_step "native board geometry detector contract" "$PYTHON_BIN" qixi-ios-native/tests/test_board_geometry_detector.py
run_step "native utility sheet screenshot inspector contract" "$PYTHON_BIN" qixi-ios-native/tests/test_utility_sheet_screenshot_inspector.py
run_step "native screenshot manifest artifact inspector contract" "$PYTHON_BIN" qixi-ios-native/tests/test_screenshot_manifest_artifact_inspector.py
run_step "native screenshot environment artifact inspector contract" "$PYTHON_BIN" qixi-ios-native/tests/test_screenshot_environment_inspector.py
run_step "native screenshot review board contract" "$PYTHON_BIN" qixi-ios-native/tests/test_screenshot_review_board.py
run_step "native screenshot coverage manifest" "$PYTHON_BIN" qixi-ios-native/tests/test_screenshot_coverage_manifest.py
run_step "native SGF parser smoke" qixi-ios-native/tests/run_sgf_parser_smoke.sh
run_step "native board legality crosscheck smoke" qixi-ios-native/tests/run_board_legality_crosscheck.sh
run_step "native board recognition smoke" qixi-ios-native/tests/run_board_recognition_smoke.sh
run_step "native variation tree layout smoke" qixi-ios-native/tests/run_variation_tree_layout_smoke.sh
run_step "native variation incremental smoke" qixi-ios-native/tests/run_variation_incremental_smoke.sh
run_step "native analysis service smoke" qixi-ios-native/tests/run_analysis_service_smoke.sh
run_step "native in-process contract preflight" scripts/qixi-native-inprocess-contract-preflight.sh
run_step "native KataGo adapter compile probe" qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh
run_step "native model preflight" scripts/qixi-native-model-preflight.sh
run_step "physical-device run preflight" scripts/qixi-device-run-preflight.sh
run_step "real-device evidence preflight contract" "$PYTHON_BIN" tests/test_real_device_evidence_preflight.py
run_step "real-device evidence template contract" "$PYTHON_BIN" tests/test_real_device_evidence_template.py
run_step "real-device run-kit preflight contract" "$PYTHON_BIN" tests/test_real_device_run_kit_preflight.py
run_step "release evidence archive match contract" "$PYTHON_BIN" tests/test_release_evidence_archive_match.py
run_step "clean recoverable generated state" cleanup_recoverable_generated_state
run_step "repository hygiene preflight" scripts/qixi-repo-hygiene-preflight.sh
run_step "native persistence and sync smoke" qixi-ios-native/tests/run_persistence_sync_smoke.sh
run_step "app store preflight" scripts/qixi-appstore-preflight.sh

if [[ "${QIXI_SKIP_XCODEBUILD:-0}" == "1" ]]; then
  echo "Skipping native Xcode build because QIXI_SKIP_XCODEBUILD=1"
elif xcodebuild_bin="$(quality_xcodebuild_path)"; then
  xcode_args=(
    -project qixi-ios-native/Qixi.xcodeproj
    -scheme Qixi
    -destination "$XCODE_DESTINATION"
    -configuration Debug
    -derivedDataPath "$DERIVED_DATA"
    CODE_SIGNING_ALLOWED=NO
    build
  )
  if [[ "${QIXI_XCODEBUILD_VERBOSE:-0}" != "1" ]]; then
    xcode_args=(-quiet "${xcode_args[@]}")
  fi
  run_step "native Xcode build" "$xcodebuild_bin" "${xcode_args[@]}"
else
  xcodebuild_status=$?
  if [[ $xcodebuild_status -eq 1 ]]; then
    echo "Skipping native Xcode build: xcodebuild not found"
  else
    exit "$xcodebuild_status"
  fi
fi

if [[ "${QIXI_RUN_SCREENSHOT_SMOKE:-0}" == "1" || "${QIXI_RUN_SCREENSHOTS:-0}" == "1" ]]; then
  screenshot_environment_artifact="${QIXI_SCREENSHOT_DOCTOR_ARTIFACT:-qixi-ios-native/artifacts/screenshots/screenshot-environment.json}"
  export QIXI_SCREENSHOT_ENVIRONMENT_MIN_MTIME_EPOCH="$("$PYTHON_BIN" - <<'PY'
import time
print(f"{time.time() - 1.0:.6f}")
PY
)"
  run_step "native simulator screenshot environment doctor" qixi-ios-native/scripts/screenshot-environment-doctor.sh
  run_step "native simulator screenshot environment artifact inspection" "$PYTHON_BIN" qixi-ios-native/tests/inspect_screenshot_environment.py "$screenshot_environment_artifact"
fi

if [[ "${QIXI_RUN_IOS_KATAGO_CMAKE:-0}" == "1" ]]; then
  run_step "iOS KataGo CMake preflight (simulator)" scripts/qixi-ios-katago-cmake-preflight.sh
  run_step "iOS KataGo CMake preflight (device)" env QIXI_IOS_SDK=iphoneos scripts/qixi-ios-katago-cmake-preflight.sh
else
  echo "Skipping iOS KataGo CMake preflight. Set QIXI_RUN_IOS_KATAGO_CMAKE=1 to enable."
fi

if [[ "${QIXI_RUN_NATIVE_RELEASE_SIM:-0}" == "1" ]]; then
  run_step "native release simulator smoke" qixi-ios-native/scripts/native-release-sim-smoke.sh
else
  echo "Skipping native release simulator smoke. Set QIXI_RUN_NATIVE_RELEASE_SIM=1 to enable."
fi

if [[ "${QIXI_RUN_DEVICE_BRIDGE_PLAN:-0}" == "1" ]]; then
  export QIXI_DEVICE_BRIDGE_ARTIFACT_MIN_MTIME_EPOCH="$("$PYTHON_BIN" - <<'PY'
import time
print(f"{time.time() - 1.0:.6f}")
PY
)"
  run_step "physical-device bridge plan" env QIXI_DEVICE_BRIDGE_PLAN_ONLY=1 scripts/qixi-device-bridge-smoke.sh
  run_step "physical-device bridge plan inspection" scripts/qixi-device-bridge-plan-inspect.sh
else
  echo "Skipping physical-device bridge plan. Set QIXI_RUN_DEVICE_BRIDGE_PLAN=1 to enable."
fi

if [[ "${QIXI_RUN_DEVICE_BRIDGE_SMOKE:-0}" == "1" ]]; then
  export QIXI_DEVICE_BRIDGE_ARTIFACT_MIN_MTIME_EPOCH="$("$PYTHON_BIN" - <<'PY'
import time
print(f"{time.time() - 1.0:.6f}")
PY
)"
  run_step "physical-device bridge smoke" scripts/qixi-device-bridge-smoke.sh
  run_step "physical-device bridge smoke artifact inspection" scripts/qixi-device-bridge-smoke-inspect.sh
else
  echo "Skipping physical-device bridge smoke. Set QIXI_RUN_DEVICE_BRIDGE_SMOKE=1 to enable."
fi

if [[ "${QIXI_RUN_DEVICE_BRIDGE_FAILURE_INSPECT:-0}" == "1" ]]; then
  bridge_failure_artifact="${QIXI_DEVICE_BRIDGE_FAILURE_ARTIFACT:-qixi-ios-native/artifacts/device-bridge/latest-device-bridge-failure.json}"
  run_step "physical-device bridge failure inspection" scripts/qixi-device-bridge-failure-inspect.sh "$bridge_failure_artifact"
else
  echo "Skipping physical-device bridge failure inspection. Set QIXI_RUN_DEVICE_BRIDGE_FAILURE_INSPECT=1 to enable."
fi

if [[ "${QIXI_RUN_SCREENSHOT_SMOKE:-0}" == "1" ]]; then
  run_step "native simulator screenshot smoke" qixi-ios-native/scripts/screenshot-smoke-sim.sh
else
  echo "Skipping simulator screenshot smoke. Set QIXI_RUN_SCREENSHOT_SMOKE=1 to enable."
fi

if [[ "${QIXI_RUN_SCREENSHOTS:-0}" == "1" ]]; then
  export QIXI_SCREENSHOT_MANIFEST_MIN_MTIME_EPOCH="$("$PYTHON_BIN" - <<'PY'
import time
print(f"{time.time() - 1.0:.6f}")
PY
)"
  run_step "native onboarding all-locale screenshot inspection" qixi-ios-native/scripts/screenshot-onboarding-all-locales.sh
  run_step "native all-locale screenshot inspection" qixi-ios-native/scripts/screenshot-all-locales.sh
  run_step "native engine selection screenshot inspection" qixi-ios-native/scripts/screenshot-engine-selection.sh
  run_step "native board overlay screenshot inspection" qixi-ios-native/scripts/screenshot-board-overlays.sh
  run_step "native board recognition preview screenshot inspection" qixi-ios-native/scripts/screenshot-board-recognition-preview.sh
  run_step "native board capture replay screenshot inspection" qixi-ios-native/scripts/screenshot-board-capture-replay.sh
  run_step "native Hermes status screenshot inspection" qixi-ios-native/scripts/screenshot-hermes-statuses.sh
  run_step "native iPhone all-locale screenshot inspection" qixi-ios-native/scripts/screenshot-iphone-all-locales.sh
  run_step "native iPhone engine selection screenshot inspection" qixi-ios-native/scripts/screenshot-iphone-engine-selection.sh
  run_step "native iPhone onboarding screenshot inspection" qixi-ios-native/scripts/screenshot-iphone-onboarding-all-locales.sh
  run_step "native iPhone engine error screenshot inspection" qixi-ios-native/scripts/screenshot-iphone-engine-errors.sh
  run_step "native iPhone board overlay screenshot inspection" qixi-ios-native/scripts/screenshot-iphone-board-overlays.sh
  run_step "native iPhone board capture replay screenshot inspection" qixi-ios-native/scripts/screenshot-iphone-board-capture-replay.sh
  run_step "native iPhone board recognition preview screenshot inspection" qixi-ios-native/scripts/screenshot-iphone-board-recognition-preview.sh
  run_step "native utility sheet screenshot inspection" qixi-ios-native/scripts/screenshot-utility-sheets.sh
  run_step "native iPhone utility sheet screenshot inspection" qixi-ios-native/scripts/screenshot-iphone-utility-sheets.sh
  run_step "native real-device evidence negative simulator smoke" qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh
  run_step "native persistence simulator smoke" qixi-ios-native/scripts/persistence-smoke-sim.sh
  run_step "native simulator performance smoke" qixi-ios-native/scripts/performance-smoke-sim.sh
  run_step "native screenshot manifest artifact inspection" "$PYTHON_BIN" qixi-ios-native/tests/inspect_screenshot_manifest_artifacts.py
  export QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH="$("$PYTHON_BIN" - <<'PY'
import time
print(f"{time.time() - 1.0:.6f}")
PY
)"
  run_step "native screenshot review board generation" "$PYTHON_BIN" qixi-ios-native/scripts/build_screenshot_review_board.py
  run_step "native screenshot review board artifact inspection" "$PYTHON_BIN" qixi-ios-native/tests/inspect_screenshot_review_board.py
else
  echo "Skipping simulator screenshot/persistence smoke. Set QIXI_RUN_SCREENSHOTS=1 to enable."
fi

if [[ "${QIXI_RUN_REAL_MODELS:-0}" == "1" ]]; then
  export QIXI_REAL_MODEL_ARTIFACT_MIN_MTIME_EPOCH="$("$PYTHON_BIN" - <<'PY'
import time
print(f"{time.time() - 1.0:.6f}")
PY
)"
  run_step "real b6 backend integration" "$PYTHON_BIN" qixi-ios-sim/tests/integration_real_b6.py
  run_step "real b6/b18/b28 backend integration" "$PYTHON_BIN" qixi-ios-sim/tests/integration_all_models.py
  run_step "real-model integration artifact inspection" "$PYTHON_BIN" qixi-ios-sim/tests/inspect_real_model_integration_artifact.py
else
  echo "Skipping real-model integrations. Set QIXI_RUN_REAL_MODELS=1 to enable."
fi

echo "Qixi quality gate passed"
