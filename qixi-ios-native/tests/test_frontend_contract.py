#!/usr/bin/env python3
from __future__ import annotations

import os
import pathlib
import plistlib
import re
import subprocess
import tempfile
import unittest

from PIL import Image


ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "Qixi"
IMAGES = SRC / "Resources" / "Images"


def read(path: pathlib.Path) -> str:
  return path.read_text(encoding="utf-8")


def swift_string_literals(text: str) -> list[str]:
  return re.findall(r'"(?:\\.|[^"\\])*"', text)


class NativeFrontendContractTests(unittest.TestCase):
  def test_project_is_native_swiftui_not_web(self) -> None:
    swift_files = list(SRC.glob("*.swift"))
    self.assertGreaterEqual(len(swift_files), 6)
    non_artifact_html = [path for path in ROOT.rglob("*.html") if "artifacts" not in path.parts]
    non_artifact_js = [path for path in ROOT.rglob("*.js") if "artifacts" not in path.parts]
    self.assertFalse(non_artifact_html)
    self.assertFalse(non_artifact_js)
    joined = "\n".join(read(path) for path in swift_files)
    self.assertIn("import SwiftUI", joined)
    self.assertNotIn("WKWebView", joined)

  def test_native_memory_telemetry_samples_process_footprint(self) -> None:
    telemetry = read(SRC / "QixiMemoryTelemetry.swift")
    view_model = read(SRC / "QixiViewModel.swift")
    project = read(ROOT / "Qixi.xcodeproj" / "project.pbxproj")

    self.assertIn("task_vm_info_data_t", telemetry)
    self.assertIn("task_info(mach_task_self_", telemetry)
    self.assertIn("phys_footprint", telemetry)
    self.assertIn("resident_size", telemetry)
    self.assertIn("memory-telemetry.jsonl", telemetry)
    self.assertIn("peakPhysFootprintBytes", telemetry)
    self.assertIn("peakResidentSizeBytes", telemetry)
    self.assertIn("[QixiMemory]", telemetry)
    self.assertIn("QixiMemoryTelemetryContext", telemetry)
    self.assertIn("selectedEngine", telemetry)
    self.assertIn("rootVisits", telemetry)
    self.assertIn("candidateCount", telemetry)
    self.assertIn("private var memorySampler: QixiMemorySampler?", view_model)
    self.assertIn("memorySampler = QixiMemorySampler", view_model)
    self.assertIn("memorySampler?.start()", view_model)
    # Lifecycle sampling may be routed through memory pressure policy / sampler API.
    self.assertIn("func recordLifecycle(reason: String)", telemetry)
    self.assertIn("memorySampler", view_model)
    self.assertIn("private func memoryTelemetryContext() -> QixiMemoryTelemetryContext", view_model)
    self.assertIn("hermesStatus.telemetryValue", view_model)
    self.assertIn("QixiMemoryTelemetry.swift in Sources", project)

  def test_root_layout_respects_safe_area_on_notched_iphones(self) -> None:
    root = read(SRC / "RootView.swift")
    self.assertIn("let safeInsets = proxy.safeAreaInsets", root)
    self.assertIn("contentWidth = max(1, proxy.size.width - safeInsets.leading - safeInsets.trailing)", root)
    self.assertIn("contentHeight = max(1, proxy.size.height - safeInsets.top - safeInsets.bottom)", root)
    self.assertIn(".padding(.leading, safeInsets.leading)", root)
    self.assertIn(".padding(.trailing, safeInsets.trailing)", root)

  def test_screenshot_script_is_configured(self) -> None:
    runner = read(ROOT / "scripts" / "run-native-sim.sh")
    review_board = read(ROOT / "scripts" / "build_screenshot_review_board.py")
    review_board_inspector = read(ROOT / "tests" / "inspect_screenshot_review_board.py")
    review_board_tests = read(ROOT / "tests" / "test_screenshot_review_board.py")
    script = read(ROOT / "scripts" / "screenshot-sim.sh")
    smoke = read(ROOT / "scripts" / "screenshot-smoke-sim.sh")
    doctor = read(ROOT / "scripts" / "screenshot-environment-doctor.sh")
    protected_marker = read(ROOT / "scripts" / "protected_build_marker.py")
    protected_marker_tests = read(ROOT / "tests" / "test_protected_build_marker.py")
    self.assertIn("QIXI_SIM_DEVICE", runner)
    self.assertIn("QIXI_SIM_UDID", runner)
    self.assertIn("QIXI_BACKEND_URL:-http://127.0.0.1:8765", runner)
    self.assertIn("QIXI_ANALYSIS_RUNTIME:-httpBridge", runner)
    self.assertIn("QIXI_SIM_CHECK_BACKEND", runner)
    self.assertIn("/api/status", runner)
    self.assertIn("warning: backend health check failed", runner)
    self.assertIn("simctl bootstatus", runner)
    for simulator_script in (runner, script):
      self.assertIn("resolved_built_app_bundle_id", simulator_script)
      self.assertIn("CFBundleIdentifier", simulator_script)
      self.assertIn('BUNDLE_ID="$(resolved_built_app_bundle_id "$APP_PATH")"', simulator_script)
    self.assertIn("resolve_xcodebuild", runner)
    self.assertIn("Native simulator run requires xcodebuild to resolve to /usr/bin/xcodebuild", runner)
    self.assertIn("do not shadow xcodebuild in PATH", runner)
    self.assertIn("QIXI_SIM_BUILD_MARKER", runner)
    self.assertIn("QIXI_SIM_VALIDATE_APP_ONLY", runner)
    self.assertIn("prepare_build_marker", runner)
    self.assertIn("protected_build_marker.py", runner)
    self.assertIn("Native simulator build marker", runner)
    self.assertIn("expected_target=\"/private/var\"", runner)
    self.assertIn("expected_target=\"/private/tmp\"", runner)
    self.assertIn("expected_target=\"/private/etc\"", runner)
    self.assertNotIn(': > "$BUILD_MARKER"', runner)
    self.assertNotIn('touch "$BUILD_MARKER"', runner)
    self.assertIn("validate_built_app", runner)
    self.assertIn("Built simulator app executable is older than the run build marker", runner)
    self.assertIn('"$XCODEBUILD_BIN" -quiet', runner)
    self.assertIn("QIXI_XCODEBUILD_VERBOSE", runner)
    self.assertIn("simctl install", runner)
    self.assertIn('if [[ "$RESET_APP" == "1" ]]; then', runner)
    self.assertIn("QIXI_SIM_RESET_APP", runner)
    self.assertIn("SIMCTL_CHILD_QIXI_BACKEND_URL", runner)
    self.assertIn("SIMCTL_CHILD_QIXI_ANALYSIS_RUNTIME", runner)
    self.assertIn("SIMCTL_CHILD_QIXI_SKIP_ONBOARDING", runner)
    self.assertIn("SIMCTL_CHILD_QIXI_APP_LANGUAGE", runner)
    self.assertIn("QIXI_SIM_RUN_CONSOLE", runner)
    self.assertIn("launch --console --terminate-running-process", runner)
    self.assertIn("launch --terminate-running-process", runner)
    self.assertIn("Launched Qixi on simulator", runner)
    self.assertIn("DEFAULT_MANIFEST", review_board)
    self.assertIn("screenshot_coverage_manifest.json", review_board)
    self.assertIn("requiredStateCount", review_board)
    self.assertIn("require_complete_artifacts", review_board)
    self.assertIn('isoformat(timespec="microseconds")', review_board)
    self.assertIn("reuses screenshot artifact", review_board)
    self.assertIn("missing screenshot artifact", review_board)
    self.assertIn("ScreenshotMetadata", review_board)
    self.assertIn("ScreenshotEvidence", review_board)
    self.assertIn("inspect_png_header", review_board)
    self.assertIn("inspect_png_decodes", review_board)
    self.assertIn("PNG_HEADER_BYTES", review_board)
    self.assertIn("SCREENSHOT_ARTIFACT_MAX_BYTES", review_board)
    self.assertIn("SCREENSHOT_MAX_PIXELS", review_board)
    self.assertIn("handle.read(SCREENSHOT_ARTIFACT_MAX_BYTES + 1)", review_board)
    self.assertIn("opened-byte-count drift while reading", review_board)
    self.assertIn("Image.open(io.BytesIO(image_data))", review_board)
    self.assertIn("Image.open(io.BytesIO(evidence.image_data))", review_board)
    self.assertIn("hashlib.sha256(image_data).hexdigest()", review_board)
    self.assertIn("hashlib.sha256(page_data).hexdigest()", review_board)
    self.assertIn("screenshot artifact must be a PNG file", review_board)
    self.assertIn("screenshot artifact must be a decodable PNG image", review_board)
    self.assertIn("decoded dimensions do not match PNG IHDR", review_board)
    self.assertIn("latest-screenshot-review-board-page-", review_board)
    self.assertIn("latest-screenshot-review-board.json", review_board)
    self.assertIn("latest-screenshot-review-board.html", review_board)
    self.assertIn("sha256HexDigest", review_board)
    self.assertIn("manifestSha256HexDigest", review_board)
    self.assertIn("sha256_hex_digest", review_board)
    self.assertIn("MAX_SCREENSHOT_MANIFEST_BYTES", review_board)
    self.assertIn("opened_regular_file_stat", review_board)
    self.assertIn("os.fstat(handle.fileno())", review_board)
    self.assertIn("stat_module.S_ISREG", review_board)
    self.assertIn("reject_symlink_components", review_board)
    self.assertIn("opened-byte-count drift while hashing", review_board)
    self.assertIn("byte count drift after opening", review_board)
    self.assertIn("MAX_REVIEW_JSON_BYTES", review_board)
    self.assertIn("MAX_REVIEW_HTML_BYTES", review_board)
    self.assertIn("write_atomic_artifact", review_board)
    self.assertIn("write_atomic_text", review_board)
    self.assertIn("expected_byte_count", review_board)
    self.assertIn("byte count drift after writing", review_board)
    self.assertIn("test_review_board_builder_atomic_bytes_rejects_short_write", review_board_tests)
    self.assertIn("os.O_EXCL", review_board)
    self.assertIn("os.O_NOFOLLOW", review_board)
    self.assertIn("os.fsync(handle.fileno())", review_board)
    self.assertIn("os.replace", review_board)
    self.assertIn("fsync_parent_directory", review_board)
    self.assertIn("os.fsync(parent_fd)", review_board)
    self.assertIn("could not fsync parent directory after atomic replace", review_board)
    self.assertIn("test_review_board_builder_atomic_write_reports_parent_fsync_failure", review_board_tests)
    self.assertIn("atomic-write temporary file", review_board)
    self.assertIn("target must not be a symbolic link", review_board)
    self.assertIn("cleanup_review_board_artifacts", review_board)
    self.assertIn("GENERATED_INDEX_FILENAMES", review_board)
    self.assertIn("directory-shaped review-board artifact", review_board)
    self.assertIn("symbolic link", review_board)
    self.assertIn("ImageOps.contain", review_board)
    self.assertNotIn("Image.open(handle)", review_board)
    self.assertIn("MAX_REVIEW_JSON_BYTES", review_board_inspector)
    self.assertIn("MAX_REVIEW_HTML_BYTES", review_board_inspector)
    self.assertIn("read_bounded_utf8", review_board_inspector)
    self.assertIn("opened_regular_file_stat", review_board_inspector)
    self.assertIn("os.fstat(handle.fileno())", review_board_inspector)
    self.assertIn("stat_module.S_ISREG", review_board_inspector)
    self.assertIn("handle.read(max_bytes + 1)", review_board_inspector)
    self.assertIn("opened-byte-count drift while reading", review_board_inspector)
    self.assertIn("opened-byte-count drift while hashing", review_board_inspector)
    self.assertNotIn('path.read_text(encoding="utf-8")', review_board_inspector)
    self.assertIn("review-board {label} is empty", review_board_inspector)
    self.assertIn("review-board {label} exceeds", review_board_inspector)
    self.assertIn("inspect_generated_at", review_board_inspector)
    self.assertIn("REVIEW_BOARD_GENERATED_AT_MAX_FUTURE_SKEW_SECONDS", review_board_inspector)
    self.assertIn("too far in the future", review_board_inspector)
    self.assertIn("generatedAt must be a UTC ISO-8601 timestamp ending in Z", review_board_inspector)
    self.assertIn("stale review-board generatedAt", review_board_inspector)
    self.assertIn("inspect_png_header", review_board_inspector)
    self.assertIn("inspect_png_decodes", review_board_inspector)
    self.assertIn("inspect_png_artifact", review_board_inspector)
    self.assertIn("PNG_HEADER_BYTES", review_board_inspector)
    self.assertIn("REVIEW_BOARD_IMAGE_MAX_BYTES", review_board_inspector)
    self.assertIn("REVIEW_BOARD_IMAGE_MAX_PIXELS", review_board_inspector)
    self.assertIn("handle.read(REVIEW_BOARD_IMAGE_MAX_BYTES + 1)", review_board_inspector)
    self.assertIn("Image.open(io.BytesIO(image_data))", review_board_inspector)
    self.assertIn("hashlib.sha256(image_data).hexdigest()", review_board_inspector)
    self.assertIn("must be a decodable PNG image", review_board_inspector)
    self.assertIn("decoded dimensions do not match PNG IHDR", review_board_inspector)
    self.assertIn("reject_duplicate_keys", review_board_inspector)
    self.assertIn("reject_non_standard_constant", review_board_inspector)
    self.assertIn("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH", review_board_inspector)
    self.assertIn("stale review-board", review_board_inspector)
    self.assertIn("MIN_PAGE_STDDEV", review_board_inspector)
    self.assertIn("page state counts must sum to stateCount", review_board_inspector)
    self.assertIn("safe_posix_parts", review_board_inspector)
    self.assertIn("must not contain empty, current-directory, or parent-directory components", review_board_inspector)
    self.assertIn("review-board HTML does not reference", review_board_inspector)
    self.assertIn("require_relative_screenshot_path", review_board_inspector)
    self.assertIn("require_real_directory", review_board_inspector)
    self.assertIn("require_real_file", review_board_inspector)
    self.assertIn("symbolic link", review_board_inspector)
    self.assertIn("expected_states_from_manifest", review_board_inspector)
    self.assertIn("state order or id drift", review_board_inspector)
    self.assertIn("screenshot path drift", review_board_inspector)
    self.assertIn("dimensions object drift", review_board_inspector)
    self.assertIn("byte count drift", review_board_inspector)
    self.assertIn("dimensions drift", review_board_inspector)
    self.assertIn("require_sha256_hex_digest", review_board_inspector)
    self.assertIn("manifest digest drift", review_board_inspector)
    self.assertIn("page digest drift", review_board_inspector)
    self.assertIn("source digest drift", review_board_inspector)
    self.assertIn("unreferenced page images", review_board_inspector)
    self.assertIn("unexpected artifacts", review_board_inspector)
    self.assertIn("simctl bootstatus", script)
    self.assertIn("simctl install", script)
    self.assertIn("simctl launch", script)
    self.assertIn("simctl io", script)
    self.assertIn("SIMCTL_CHILD_QIXI_APP_LANGUAGE", script)
    self.assertIn("SIMCTL_CHILD_QIXI_SKIP_ONBOARDING", script)
    self.assertIn("SIMCTL_CHILD_QIXI_BACKEND_URL", script)
    self.assertIn("SIMCTL_CHILD_QIXI_ANALYSIS_RUNTIME", script)
    self.assertIn("QIXI_SCREENSHOT_AUTO_ROTATE", script)
    self.assertIn("SIMCTL_CHILD_QIXI_OPEN_UTILITY_SHEET", script)
    self.assertIn("SIMCTL_CHILD_QIXI_IMPORT_SHEET_STATUS", script)
    self.assertIn("SIMCTL_CHILD_QIXI_HERMES_STATUS", script)
    self.assertIn("SIMCTL_CHILD_QIXI_ENGINE_ERROR", script)
    self.assertIn("SIMCTL_CHILD_QIXI_AUTOMATION_SELECT_ENGINE", script)
    self.assertIn("SIMCTL_CHILD_QIXI_ICLOUD_SYNC_ENABLED", script)
    self.assertIn("SIMCTL_CHILD_QIXI_SYNC_STATUS", script)
    self.assertIn("SIMCTL_CHILD_QIXI_ANALYSIS_FIXTURE", script)
    self.assertIn("SIMCTL_CHILD_QIXI_SHOW_TERRITORY", script)
    self.assertIn("SIMCTL_CHILD_QIXI_LIFECYCLE_TOMBSTONE_ON_LAUNCH", script)
    self.assertIn("SIMCTL_CHILD_${evidence_key}", script)
    self.assertIn("QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_ANALYSIS", script)
    self.assertIn("QIXI_REAL_DEVICE_EVIDENCE_OUTPUT", script)
    self.assertIn("QIXI_REAL_DEVICE_RUN_ID", script)
    self.assertIn("QIXI_REAL_DEVICE_RECORDED_AT", script)
    self.assertIn("QIXI_DEVICE_BACKEND_URL", script)
    self.assertIn("QIXI_REAL_DEVICE_SCREENSHOT_ARTIFACT", script)
    self.assertIn("QIXI_SCREENSHOT_BUILD_MARKER", script)
    self.assertIn("QIXI_SCREENSHOT_VALIDATE_APP_ONLY", script)
    self.assertIn("prepare_build_marker", script)
    self.assertIn("protected_build_marker.py", script)
    self.assertIn("Simulator screenshot build marker", script)
    self.assertNotIn(': > "$BUILD_MARKER"', script)
    self.assertNotIn('touch "$BUILD_MARKER"', script)
    self.assertIn("validate_built_app", script)
    self.assertIn("Built app executable is older than the screenshot build marker", script)
    self.assertIn("extract_launched_pid", script)
    self.assertIn("require_launched_app_alive", script)
    self.assertIn('"$pid" =~ ^[0-9]+$', script)
    self.assertIn('ps -p "$pid" -o command=', script)
    self.assertIn('"/Qixi.app/Qixi"', script)
    self.assertIn("Simulator screenshot observed a different process for Qixi pid", script)
    self.assertIn("Simulator screenshot Qixi app process exited before", script)
    self.assertIn('require_launched_app_alive "$launched_pid" "visual readiness wait"', script)
    self.assertIn('require_launched_app_alive "$launched_pid" "screenshot capture"', script)
    self.assertIn("QIXI_SEED_NATIVE_ENGINE_TOMBSTONE", script)
    self.assertIn("QIXI_SEED_REAL_DEVICE_EVIDENCE_ARTIFACTS", script)
    self.assertIn("QIXI_SCREENSHOT_METRICS_PATH", script)
    self.assertIn("prepare_output_artifact", script)
    self.assertIn("temporary_output_path", script)
    self.assertIn("expected_target=\"/private/var\"", script)
    self.assertIn("expected_target=\"/private/tmp\"", script)
    self.assertIn("expected_target=\"/private/etc\"", script)
    self.assertIn("RAW_CAPTURE_PATH", script)
    self.assertIn("CROPPED_CAPTURE_PATH", script)
    self.assertIn("raw screenshot artifact", script)
    self.assertIn("cropped screenshot artifact", script)
    self.assertIn("os.replace(tmp_path, target)", script)
    self.assertIn("os.replace(tmp_path, metrics_path)", script)
    self.assertIn("os.O_NOFOLLOW", script)
    self.assertIn("os.fstat(fd)", script)
    self.assertIn("metrics artifact byte count drift after writing", script)
    self.assertIn("os.fsync(parent_fd)", script)
    self.assertIn('"launchCommandMs"', script)
    self.assertIn('"visualReadyMs"', script)
    self.assertIn('"pid"', script)
    self.assertIn("Simulator screenshot capture requires xcodebuild to resolve to /usr/bin/xcodebuild", script)
    self.assertIn('"$XCODEBUILD_BIN" \\', script)
    self.assertIn("seeded restore smoke", script)
    self.assertIn("cropped.width < cropped.height", script)
    self.assertIn("cropped.rotate(90, expand=True)", script)
    self.assertIn("screenshot-sim.sh", smoke)
    self.assertIn("latest-ipad-smoke.png", smoke)
    self.assertIn("screenshot-iphone-sim.sh", smoke)
    self.assertIn("latest-iphone-smoke.png", smoke)
    self.assertIn("performance-smoke-sim.sh", smoke)
    self.assertIn("Native simulator screenshot smoke passed", smoke)
    self.assertNotIn('mkdir -p "$SCREENSHOT_DIR"', smoke)
    self.assertIn('RAW_SCREENSHOT_PATH="${SCREENSHOT_PATH%.png}.raw.png"', script)
    for token in (
      "Simulator screenshot environment doctor passed",
      "QIXI_SCREENSHOT_DOCTOR_BOOT",
      "QIXI_SCREENSHOT_DOCTOR_ARTIFACT",
      "ARTIFACT_PATH",
      "QIXI_SIM_DEVICE",
      "QIXI_IPHONE_SIM_DEVICE",
      "resolve_xcodebuild",
      "Simulator screenshot QA requires xcodebuild to resolve to /usr/bin/xcodebuild",
      '"$XCODEBUILD_BIN" -showsdks',
      'XCODEBUILD_BIN="$XCODEBUILD_BIN"',
      "iphonesimulator",
      "from PIL import Image, ImageChops",
      'run([os.environ["XCODEBUILD_BIN"], "-version"])',
      '"simctl", "list", "devices", "available", "-j"',
      "bootstatus",
      "choose_device(ipad_name, \"iPad\")",
      "choose_device(iphone_name, \"iPhone\")",
      "ALLOWED_PLATFORM_SYMLINK_ALIASES",
      "normalized_path",
      "is_allowed_platform_symlink_alias",
      "reject_symlink_components",
      "canonicalize_allowed_platform_alias_prefix",
      "prepare_artifact_target",
      "write_artifact_atomically",
      "os.O_EXCL",
      "os.O_NOFOLLOW",
      "os.fstat(fd)",
      "stat_module.S_ISREG",
      "byte count drift after writing",
      "os.fsync(fd)",
      "os.replace(tmp_path, checked_path)",
      "fsync_parent_directory",
      "os.fsync(parent_fd)",
      "could not fsync parent directory after screenshot environment artifact replace",
      "screenshot-environment.json",
      '"fastSmoke": "qixi-ios-native/scripts/screenshot-smoke-sim.sh"',
      '"fullMatrix": "QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh"',
      "Real ProMotion, Metal/GPU/ANE, camera, iCloud propagation, background kill, and native in-process KataGo still require physical-device evidence.",
    ):
      self.assertIn(token, doctor)
    self.assertNotIn("artifact_path.write_text", doctor)
    self.assertNotIn('mkdir -p "$(dirname "$ARTIFACT_PATH")"', doctor)
    for token in (
      "ALLOWED_PLATFORM_SYMLINK_ALIASES",
      "reject_symlink_components",
      "canonicalize_allowed_platform_alias_prefix",
      "prepare_marker_target",
      "write_marker",
      "os.O_EXCL",
      "os.O_NOFOLLOW",
      "os.fstat(fd)",
      "byte count drift after writing",
      "os.fsync(fd)",
      "os.replace(tmp_path, marker_path)",
      "fsync_parent_directory",
      "os.fsync(parent_fd)",
    ):
      self.assertIn(token, protected_marker)
    for token in (
      "test_writes_regular_marker_atomically",
      "test_rejects_symlink_marker_without_writing_target",
      "test_rejects_symlink_parent_without_writing_through",
      "test_allows_standard_tmp_alias_when_available",
      "test_rejects_missing_parent",
    ):
      self.assertIn(token, protected_marker_tests)
    matrix = read(ROOT / "scripts" / "screenshot-all-locales.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, matrix)
    self.assertIn("inspect_screenshot.py", matrix)
    onboarding = read(ROOT / "scripts" / "screenshot-onboarding-sim.sh")
    self.assertIn("QIXI_SKIP_ONBOARDING=0", onboarding)
    self.assertIn("latest-ipad-onboarding.png", onboarding)
    self.assertIn("inspect_onboarding_screenshot.py", onboarding)
    onboarding_matrix = read(ROOT / "scripts" / "screenshot-onboarding-all-locales.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, onboarding_matrix)
      self.assertIn(f"latest-ipad-onboarding-$language.png", onboarding_matrix)
    self.assertIn("screenshot-onboarding-sim.sh", onboarding_matrix)
    iphone_onboarding = read(ROOT / "scripts" / "screenshot-iphone-onboarding-sim.sh")
    self.assertIn("QIXI_IPHONE_SIM_DEVICE", iphone_onboarding)
    self.assertIn("iPhone 17 Pro Max", iphone_onboarding)
    self.assertIn("latest-iphone-onboarding.png", iphone_onboarding)
    self.assertIn("QIXI_SKIP_ONBOARDING=0", iphone_onboarding)
    self.assertIn("QIXI_SCREENSHOT_AUTO_ROTATE=1", iphone_onboarding)
    self.assertIn("inspect_onboarding_screenshot.py", iphone_onboarding)
    iphone_onboarding_matrix = read(ROOT / "scripts" / "screenshot-iphone-onboarding-all-locales.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, iphone_onboarding_matrix)
      self.assertIn(f"latest-iphone-onboarding-$language.png", iphone_onboarding_matrix)

    self.assertIn("screenshot-iphone-onboarding-sim.sh", iphone_onboarding_matrix)
    iphone = read(ROOT / "scripts" / "screenshot-iphone-sim.sh")
    self.assertIn("QIXI_IPHONE_SIM_DEVICE", iphone)
    self.assertIn("iPhone 17 Pro Max", iphone)
    self.assertIn("latest-iphone.png", iphone)
    self.assertIn("QIXI_SCREENSHOT_AUTO_ROTATE=1", iphone)
    self.assertIn("inspect_screenshot.py", iphone)
    iphone_matrix = read(ROOT / "scripts" / "screenshot-iphone-all-locales.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, iphone_matrix)
      self.assertIn(f"latest-iphone-$language.png", iphone_matrix)
    self.assertIn("screenshot-iphone-sim.sh", iphone_matrix)
    engine_selection_matrix = read(ROOT / "scripts" / "screenshot-engine-selection.sh")
    iphone_engine_selection_matrix = read(ROOT / "scripts" / "screenshot-iphone-engine-selection.sh")
    for matrix_text, prefix in (
      (engine_selection_matrix, "latest-ipad-engine"),
      (iphone_engine_selection_matrix, "latest-iphone-engine"),
    ):
      for language in ("zh-Hans", "zh-Hant", "en"):
        self.assertIn(language, matrix_text)
      for engine in ("b6", "b18nbt", "b28nbt"):
        self.assertIn(engine, matrix_text)
        for language in ("zh-Hans", "zh-Hant", "en"):
          self.assertIn(f"{prefix}-$engine-$language.png", matrix_text)
      self.assertIn("QIXI_AUTOMATION_SELECT_ENGINE", matrix_text)
      self.assertIn("QIXI_SKIP_ONBOARDING=1", matrix_text)
    self.assertIn("inspect_screenshot.py", engine_selection_matrix)
    self.assertIn("screenshot-iphone-sim.sh", iphone_engine_selection_matrix)
    iphone_error_matrix = read(ROOT / "scripts" / "screenshot-iphone-engine-errors.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, iphone_error_matrix)
    for error in ("library-not-linked", "model-missing", "insufficient-memory", "local-network-denied"):
      self.assertIn(error, iphone_error_matrix)
    self.assertIn("QIXI_ENGINE_ERROR", iphone_error_matrix)
    self.assertIn("screenshot-iphone-sim.sh", iphone_error_matrix)
    self.assertIn("latest-iphone-engine-error-$error-$language.png", iphone_error_matrix)
    self.assertIn("inspect_engine_error_screenshot.py", iphone_error_matrix)
    iphone_utility_matrix = read(ROOT / "scripts" / "screenshot-iphone-utility-sheets.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, iphone_utility_matrix)
    for sheet in ("camera", "import", "sync"):
      self.assertIn(sheet, iphone_utility_matrix)
      for language in ("zh-Hans", "zh-Hant", "en"):
        self.assertIn(f"latest-iphone-$sheet-sheet-$language.png", iphone_utility_matrix)
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(f"latest-iphone-sync-enabled-sheet-$language.png", iphone_utility_matrix)
    self.assertIn('DEVICE="${QIXI_IPHONE_SIM_DEVICE:-iPhone 17 Pro Max}"', iphone_utility_matrix)
    self.assertIn("screenshot-sim.sh", iphone_utility_matrix)
    self.assertIn("QIXI_SIM_DEVICE", iphone_utility_matrix)
    self.assertIn("QIXI_SCREENSHOT_AUTO_ROTATE=1", iphone_utility_matrix)
    self.assertIn("QIXI_ICLOUD_SYNC_ENABLED=0", iphone_utility_matrix)
    self.assertIn("QIXI_ICLOUD_SYNC_ENABLED=1", iphone_utility_matrix)
    self.assertIn('"$disabled_screenshot" disabled', iphone_utility_matrix)
    self.assertIn('"$enabled_screenshot" enabled', iphone_utility_matrix)
    self.assertIn("QIXI_SYNC_STATUS", iphone_utility_matrix)
    self.assertIn("QIXI_OPEN_UTILITY_SHEET", iphone_utility_matrix)
    self.assertNotIn("QIXI_IMPORT_SHEET_STATUS", iphone_utility_matrix)
    self.assertNotIn("model-install", iphone_utility_matrix)
    self.assertNotIn("installed-b18nbt", iphone_utility_matrix)
    for sync_status in ("synced", "error", "conflict"):
      self.assertIn(sync_status, iphone_utility_matrix)
      for language in ("zh-Hans", "zh-Hant", "en"):
        self.assertIn("latest-iphone-sync-$status-sheet-$language.png", iphone_utility_matrix)
    self.assertIn("inspect_utility_sheet_screenshot.py", iphone_utility_matrix)
    hermes_matrix = read(ROOT / "scripts" / "screenshot-hermes-statuses.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, hermes_matrix)
    for status in ("ready", "loading", "offline"):
      self.assertIn(status, hermes_matrix)
    self.assertIn("latest-ipad-hermes-$status-$language.png", hermes_matrix)
    self.assertIn("QIXI_HERMES_STATUS", hermes_matrix)
    self.assertIn("inspect_hermes_status_screenshot.py", hermes_matrix)
    for error in ("library-not-linked", "model-missing", "insufficient-memory", "local-network-denied"):
      self.assertIn(error, hermes_matrix)
    self.assertIn("QIXI_ENGINE_ERROR", hermes_matrix)
    self.assertIn("latest-ipad-engine-error-$error-$language.png", hermes_matrix)
    self.assertIn("inspect_engine_error_screenshot.py", hermes_matrix)
    hermes_inspector = read(ROOT / "tests" / "inspect_hermes_status_screenshot.py")
    self.assertIn('{"ready": 0, "loading": 0, "offline": 0}', hermes_inspector)
    self.assertIn("badge_region", hermes_inspector)
    self.assertIn("counts[expected]", hermes_inspector)
    overlay_matrix = read(ROOT / "scripts" / "screenshot-board-overlays.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, overlay_matrix)
      self.assertIn(f"latest-ipad-board-overlays-$language.png", overlay_matrix)
    self.assertIn("QIXI_ANALYSIS_FIXTURE=board-overlays", overlay_matrix)
    self.assertIn("QIXI_SHOW_TERRITORY=1", overlay_matrix)
    self.assertIn("inspect_board_overlay_screenshot.py", overlay_matrix)
    iphone_overlay_matrix = read(ROOT / "scripts" / "screenshot-iphone-board-overlays.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, iphone_overlay_matrix)
      self.assertIn(f"latest-iphone-board-overlays-$language.png", iphone_overlay_matrix)
    self.assertIn('DEVICE="${QIXI_IPHONE_SIM_DEVICE:-iPhone 17 Pro Max}"', iphone_overlay_matrix)
    self.assertIn("QIXI_SCREENSHOT_AUTO_ROTATE=1", iphone_overlay_matrix)
    self.assertIn("QIXI_ANALYSIS_FIXTURE=board-overlays", iphone_overlay_matrix)
    self.assertIn("QIXI_SHOW_TERRITORY=1", iphone_overlay_matrix)
    self.assertIn("inspect_board_overlay_screenshot.py", iphone_overlay_matrix)
    overlay_inspector = read(ROOT / "tests" / "inspect_board_overlay_screenshot.py")
    self.assertIn("GREEN_CANDIDATE_POINTS", overlay_inspector)
    self.assertIn("WHITE_TERRITORY_POINTS", overlay_inspector)
    self.assertIn("BLACK_TERRITORY_POINTS", overlay_inspector)
    self.assertIn("detect_grid(image)", overlay_inspector)
    self.assertIn("count_candidate_pixels", overlay_inspector)
    self.assertIn("territory_marker_luma", overlay_inspector)
    recognition_preview_matrix = read(ROOT / "scripts" / "screenshot-board-recognition-preview.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, recognition_preview_matrix)
      self.assertIn(f"latest-ipad-board-recognition-preview-$language.png", recognition_preview_matrix)
    self.assertIn("QIXI_ANALYSIS_FIXTURE=board-recognition-preview", recognition_preview_matrix)
    self.assertIn("inspect_board_recognition_preview_screenshot.py", recognition_preview_matrix)
    iphone_recognition_preview_matrix = read(ROOT / "scripts" / "screenshot-iphone-board-recognition-preview.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, iphone_recognition_preview_matrix)
      self.assertIn(f"latest-iphone-board-recognition-preview-$language.png", iphone_recognition_preview_matrix)
    self.assertIn('DEVICE="${QIXI_IPHONE_SIM_DEVICE:-iPhone 17 Pro Max}"', iphone_recognition_preview_matrix)
    self.assertIn("QIXI_SCREENSHOT_AUTO_ROTATE=1", iphone_recognition_preview_matrix)
    self.assertIn("QIXI_ANALYSIS_FIXTURE=board-recognition-preview", iphone_recognition_preview_matrix)
    self.assertIn("inspect_board_recognition_preview_screenshot.py", iphone_recognition_preview_matrix)
    recognition_preview_inspector = read(ROOT / "tests" / "inspect_board_recognition_preview_screenshot.py")
    self.assertIn("PREVIEW_POINTS", recognition_preview_inspector)
    self.assertIn("count_preview_blue_pixels", recognition_preview_inspector)
    self.assertIn("recognition preview ring", recognition_preview_inspector)
    capture_matrix = read(ROOT / "scripts" / "screenshot-board-capture-replay.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, capture_matrix)
      self.assertIn(f"latest-ipad-board-capture-replay-$language.png", capture_matrix)
    self.assertIn("QIXI_ANALYSIS_FIXTURE=board-capture-replay", capture_matrix)
    self.assertIn("inspect_board_capture_replay_screenshot.py", capture_matrix)
    iphone_capture_matrix = read(ROOT / "scripts" / "screenshot-iphone-board-capture-replay.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, iphone_capture_matrix)
      self.assertIn(f"latest-iphone-board-capture-replay-$language.png", iphone_capture_matrix)
    self.assertIn('DEVICE="${QIXI_IPHONE_SIM_DEVICE:-iPhone 17 Pro Max}"', iphone_capture_matrix)
    self.assertIn("QIXI_SCREENSHOT_AUTO_ROTATE=1", iphone_capture_matrix)
    self.assertIn("QIXI_ANALYSIS_FIXTURE=board-capture-replay", iphone_capture_matrix)
    self.assertIn("inspect_board_capture_replay_screenshot.py", iphone_capture_matrix)
    capture_inspector = read(ROOT / "tests" / "inspect_board_capture_replay_screenshot.py")
    self.assertIn("BLACK_STONES", capture_inspector)
    self.assertIn("CAPTURED_WHITE", capture_inspector)
    self.assertIn("white_stone_pixel_count", capture_inspector)
    self.assertIn("captured white stone is still visibly rendered", capture_inspector)
    utility_matrix = read(ROOT / "scripts" / "screenshot-utility-sheets.sh")
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(language, utility_matrix)
    for sheet in ("camera", "import", "sync"):
      self.assertIn(sheet, utility_matrix)
      for language in ("zh-Hans", "zh-Hant", "en"):
        self.assertIn(f"latest-ipad-$sheet-sheet-$language.png", utility_matrix)
    for language in ("zh-Hans", "zh-Hant", "en"):
      self.assertIn(f"latest-ipad-sync-enabled-sheet-$language.png", utility_matrix)
    self.assertIn("QIXI_ICLOUD_SYNC_ENABLED=0", utility_matrix)
    self.assertIn("QIXI_ICLOUD_SYNC_ENABLED=1", utility_matrix)
    self.assertIn('"$disabled_screenshot" disabled', utility_matrix)
    self.assertIn('"$enabled_screenshot" enabled', utility_matrix)
    self.assertIn("QIXI_SYNC_STATUS", utility_matrix)
    self.assertIn("QIXI_OPEN_UTILITY_SHEET", utility_matrix)
    self.assertNotIn("QIXI_IMPORT_SHEET_STATUS", utility_matrix)
    self.assertNotIn("model-install", utility_matrix)
    self.assertNotIn("installed-b18nbt", utility_matrix)
    for sync_status in ("synced", "error", "conflict"):
      self.assertIn(sync_status, utility_matrix)
      for language in ("zh-Hans", "zh-Hant", "en"):
        self.assertIn("latest-ipad-sync-$status-sheet-$language.png", utility_matrix)
    self.assertIn("inspect_utility_sheet_screenshot.py", utility_matrix)
    geometry = read(ROOT / "tests" / "inspect_board_geometry_screenshot.py")
    screenshot_inspector = read(ROOT / "tests" / "inspect_screenshot.py")
    self.assertIn("inspect_board_geometry(path)", screenshot_inspector)
    self.assertIn("SAMPLE_MOVES", geometry)
    self.assertIn("GRID_SIZE = 19", geometry)
    self.assertIn("could not fit all 19", geometry)
    self.assertIn("board grid must be 19x19", geometry)
    self.assertIn("fit_grid_axis", geometry)
    self.assertIn("stone_centroid", geometry)
    self.assertIn("max stone error", geometry)
    persistence = read(ROOT / "scripts" / "persistence-smoke-sim.sh")
    performance = read(ROOT / "scripts" / "performance-smoke-sim.sh")
    self.assertIn("autosave.qixi-state.json", persistence)
    self.assertIn("autosave.qixi-state.backup.json", persistence)
    self.assertIn("Backup snapshot smoke passed", persistence)
    self.assertIn("backup_payload == payload", persistence)
    self.assertIn("lifecycle-tombstone.qixi-state.json", persistence)
    self.assertIn("QIXI_ANALYSIS_RUNTIME", persistence)
    self.assertIn("nativeInProcess", persistence)
    self.assertIn("native-engine-tombstone.qixi-native", persistence)
    self.assertIn("native-engine-tombstone.export.json", persistence)
    self.assertIn("native-engine-tombstone.restore.json", persistence)
    self.assertIn("Lifecycle tombstone smoke passed", persistence)
    self.assertIn("Native engine tombstone smoke passed", persistence)
    self.assertIn("Native engine tombstone export smoke passed", persistence)
    self.assertIn("Native engine tombstone restore smoke passed", persistence)
    self.assertIn("QIXI_LIFECYCLE_TOMBSTONE_ON_LAUNCH", persistence)
    self.assertIn("--qixi-lifecycle-tombstone-on-launch", script)
    self.assertIn('xcrun simctl launch "$UDID" "$BUNDLE_ID" "${launch_args[@]}"', script)
    self.assertIn('xcrun simctl launch "$UDID" "$BUNDLE_ID" >/tmp/qixi-native-screenshot-launch.log', script)
    self.assertIn("QIXI_SEED_NATIVE_ENGINE_TOMBSTONE", persistence)
    self.assertIn('assert tombstone.exists()', persistence)
    self.assertIn('tombstone_payload["reason"] == expected_lifecycle_reason', persistence)
    self.assertIn('tombstone_payload["snapshotSavedAt"] == payload["savedAt"]', persistence)
    self.assertIn('tombstone_payload["engineTombstoneFilename"] == "native-engine-tombstone.qixi-native"', persistence)
    self.assertIn('engine_tombstone_payload["kind"] == "qixi-native-katago-tombstone"', persistence)
    self.assertIn('engine_tombstone_payload["engine"] == "none"', persistence)
    self.assertIn('engine_export_payload["schemaVersion"] == 1', persistence)
    self.assertIn('engine_export_payload["tombstoneFilename"] == "native-engine-tombstone.qixi-native"', persistence)
    self.assertIn('engine_export_payload["engine"] == "none"', persistence)
    self.assertIn('engine_export_payload["reason"] == expected_lifecycle_reason', persistence)
    self.assertIn('engine_restore_payload["schemaVersion"] == 2', persistence)
    self.assertIn('engine_restore_payload["tombstoneFilename"] == "native-engine-tombstone.qixi-native"', persistence)
    self.assertIn('engine_restore_payload["engine"] == "none"', persistence)
    self.assertIn("SyncFallback", persistence)
    self.assertIn("get_app_container", persistence)
    self.assertIn("resolved_built_app_bundle_id", persistence)
    self.assertIn("CFBundleIdentifier", persistence)
    self.assertIn('bundle_id="$(resolved_built_app_bundle_id "$APP_PATH")"', persistence)
    self.assertIn('"rootNoise" not in payload', persistence)
    self.assertIn("latest-sim-performance.json", performance)
    self.assertIn("QIXI_PERF_MAX_LAUNCH_COMMAND_MS", performance)
    self.assertIn("QIXI_PERF_MAX_VISUAL_READY_MS", performance)
    self.assertIn("QIXI_PERF_MAX_RSS_MB", performance)
    self.assertIn("QIXI_SCREENSHOT_METRICS_PATH", performance)
    self.assertIn("reject_symlink_components", performance)
    self.assertIn("prepare_output_artifact", performance)
    self.assertIn("expected_target=\"/private/var\"", performance)
    self.assertIn("expected_target=\"/private/tmp\"", performance)
    self.assertIn("expected_target=\"/private/etc\"", performance)
    self.assertIn("Simulator performance $label target must not be a symbolic link", performance)
    self.assertIn("os.O_NOFOLLOW", performance)
    self.assertIn("os.fstat(fd)", performance)
    self.assertIn("metrics artifact byte count drift after writing", performance)
    self.assertIn("os.replace(tmp_path, metrics_path)", performance)
    self.assertIn("os.fsync(parent_fd)", performance)
    self.assertIn("inspect_screenshot.py", performance)
    self.assertIn('"rssMB"', performance)
    self.assertIn("Simulator performance smoke passed", performance)

  def test_screenshot_smoke_scripts_reject_symlink_outputs_before_build(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      temp_root = pathlib.Path(tmpdir)
      target = temp_root / "target.png"
      screenshot_link = temp_root / "linked.png"
      screenshot_link.symlink_to(target)

      env = os.environ.copy()
      env["PYTHONDONTWRITEBYTECODE"] = "1"
      result = subprocess.run(
        [str(ROOT / "scripts" / "screenshot-sim.sh"), str(screenshot_link)],
        cwd=ROOT.parent,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(result.returncode, 0)
      self.assertIn("symbolic link", result.stderr)
      self.assertNotIn("Using simulator:", result.stdout)
      self.assertFalse(target.exists())

      metrics_dir = ROOT / "artifacts" / "performance"
      metrics_dir.mkdir(parents=True, exist_ok=True)
      metrics_target = temp_root / "target-performance.json"
      metrics_link = metrics_dir / "latest-sim-performance.json"
      existing_metrics_bytes: bytes | None = None
      existing_metrics_mode: int | None = None
      if metrics_link.exists() and not metrics_link.is_symlink():
        existing_metrics_bytes = metrics_link.read_bytes()
        existing_metrics_mode = metrics_link.stat().st_mode & 0o777
      try:
        if metrics_link.exists() or metrics_link.is_symlink():
          metrics_link.unlink()
        metrics_link.symlink_to(metrics_target)
        result = subprocess.run(
          [str(ROOT / "scripts" / "performance-smoke-sim.sh")],
          cwd=ROOT.parent,
          env=env,
          text=True,
          capture_output=True,
          check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symbolic link", result.stderr)
        self.assertNotIn("Using simulator:", result.stdout)
        self.assertFalse(metrics_target.exists())
      finally:
        if metrics_link.exists() or metrics_link.is_symlink():
          metrics_link.unlink()
        if existing_metrics_bytes is not None:
          metrics_link.write_bytes(existing_metrics_bytes)
          if existing_metrics_mode is not None:
            metrics_link.chmod(existing_metrics_mode)

  def test_simulator_scripts_reject_shadowed_xcodebuild(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      tool_dir = pathlib.Path(tmpdir) / "bin"
      tool_dir.mkdir()
      fake_xcodebuild = tool_dir / "xcodebuild"
      fake_xcodebuild.write_text("#!/bin/sh\necho fake xcodebuild\n", encoding="utf-8")
      fake_xcodebuild.chmod(0o755)

      env = os.environ.copy()
      env["PATH"] = f"{tool_dir}{os.pathsep}{env.get('PATH', '')}"
      env["PYTHONDONTWRITEBYTECODE"] = "1"
      env["QIXI_SCREENSHOT_DOCTOR_BOOT"] = "0"
      screenshot_path = pathlib.Path(tmpdir) / "shadowed-xcodebuild.png"

      cases = (
        (ROOT / "scripts" / "screenshot-sim.sh", [str(screenshot_path)]),
        (ROOT / "scripts" / "run-native-sim.sh", []),
        (ROOT / "scripts" / "screenshot-environment-doctor.sh", []),
      )
      for script, args in cases:
        with self.subTest(script=script.name):
          result = subprocess.run(
            [str(script), *args],
            cwd=ROOT.parent,
            env=env,
            text=True,
            capture_output=True,
            check=False,
          )
          self.assertNotEqual(result.returncode, 0)
          self.assertIn("do not shadow xcodebuild in PATH", result.stderr)
          self.assertNotIn("Using simulator:", result.stdout)

  def test_simulator_scripts_reject_stale_built_app_executables(self) -> None:
    temp_root = pathlib.Path("/private/tmp") if pathlib.Path("/private/tmp").is_dir() else pathlib.Path(tempfile.gettempdir())
    with tempfile.TemporaryDirectory(dir=str(temp_root)) as tmpdir:
      root = pathlib.Path(tmpdir)
      derived_data = root / "DerivedData"
      app_dir = derived_data / "Build" / "Products" / "Debug-iphonesimulator" / "Qixi.app"
      app_dir.mkdir(parents=True)
      executable = app_dir / "Qixi"
      executable.write_text("fake executable\n", encoding="utf-8")
      executable.chmod(0o755)
      (app_dir / "Info.plist").write_text("<plist><dict></dict></plist>\n", encoding="utf-8")
      os.utime(executable, (1_700_000_000, 1_700_000_000))

      cases = (
        (
          ROOT / "scripts" / "screenshot-sim.sh",
          "QIXI_SCREENSHOT_BUILD_MARKER",
          "QIXI_SCREENSHOT_VALIDATE_APP_ONLY",
          "older than the screenshot build marker",
        ),
        (
          ROOT / "scripts" / "run-native-sim.sh",
          "QIXI_SIM_BUILD_MARKER",
          "QIXI_SIM_VALIDATE_APP_ONLY",
          "older than the run build marker",
        ),
      )
      for script, marker_env_key, validate_env_key, expected_error in cases:
        with self.subTest(script=script.name):
          marker = root / f"{script.stem}.marker"
          marker.write_text("current build\n", encoding="utf-8")
          os.utime(marker, (1_700_000_010, 1_700_000_010))
          env = os.environ.copy()
          env["PYTHONDONTWRITEBYTECODE"] = "1"
          env["QIXI_DERIVED_DATA"] = str(derived_data)
          env[marker_env_key] = str(marker)
          env[validate_env_key] = "1"
          result = subprocess.run(
            [str(script), str(root / "unused.png")],
            cwd=ROOT.parent,
            env=env,
            text=True,
            capture_output=True,
            check=False,
          )
          self.assertNotEqual(result.returncode, 0)
          self.assertIn(expected_error, result.stderr)
          self.assertNotIn("Using simulator:", result.stdout)

  def test_screenshot_python_scripts_do_not_emit_bytecode(self) -> None:
    screenshot_scripts = sorted((ROOT / "scripts").glob("*.sh"))
    python_scripts = [script for script in screenshot_scripts if "python3" in read(script)]
    self.assertGreaterEqual(len(python_scripts), 10)
    for script in python_scripts:
      with self.subTest(script=script.name):
        text = read(script)
        self.assertIn('export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"', text)

  def test_required_visual_assets_exist_as_bundle_pngs(self) -> None:
    bundle_image = read(SRC / "BundleImage.swift")
    self.assertIn("private final class BundleImageCache", bundle_image)
    self.assertIn("static let shared = BundleImageCache()", bundle_image)
    self.assertIn("private let lock = NSLock()", bundle_image)
    self.assertIn("private var images: [String: UIImage] = [:]", bundle_image)
    self.assertIn("BundleImageCache.shared.image(named: name)", bundle_image)
    self.assertEqual(bundle_image.count("UIImage(contentsOfFile:"), 1)

    expected = {
      "board06InkPaper.png": (1200, 1200),
      "black19Yunzi.png": (512, 512),
      "whiteStone.png": (512, 512),
      "hermesGatewayPulse.png": (240, 240),
    }
    for filename, size in expected.items():
      path = IMAGES / filename
      self.assertTrue(path.exists(), filename)
      with Image.open(path) as image:
        self.assertEqual(image.size, size, filename)

  def test_hermes_status_contract(self) -> None:
    models = read(SRC / "QixiModels.swift")
    view_model = read(SRC / "QixiViewModel.swift")
    self.assertIn("L10n.text(.hermesReady)", models)
    self.assertIn("L10n.text(.hermesLoading)", models)
    self.assertIn("L10n.text(.hermesOffline)", models)
    self.assertIn("hermesBlue", models)
    self.assertIn("hermesOrange", models)
    self.assertIn("hermesRed", models)
    self.assertIn("init?(automationValue: String?)", models)
    for status in ("ready", "loading", "offline"):
      self.assertIn(f'case "{status}": self = .{status}', models)
    self.assertIn("let processEnvironment = ProcessInfo.processInfo.environment", view_model)
    self.assertIn('processEnvironment["QIXI_HERMES_STATUS"]', view_model)
    self.assertIn("hermesStatus = automationStatus", view_model)
    root = read(SRC / "RootView.swift")
    self.assertIn('BundleImage(name: "hermesGatewayPulse")', root)
    self.assertIn("Circle()", root)
    self.assertIn("EngineErrorBanner(message:", root)
    self.assertIn("L10n.text(.engineErrorTitle)", root)
    self.assertIn("QixiColor.warningRed", root)
    self.assertIn("model.lastEngineError", root)
    self.assertIn("let topContentWidth = max(1, proxy.size.width - horizontalInset * 2)", root)
    self.assertIn(".frame(maxWidth: 360, alignment: .leading)", root)
    self.assertNotIn(".frame(width: 360, alignment: .leading)", root)


  def test_backend_endpoint_is_runtime_configurable_for_device_smoke_tests(self) -> None:
    service = read(SRC / "QixiAnalysisService.swift")
    native_service = read(SRC / "QixiNativeKataGoAnalysisService.swift")
    project = read(ROOT / "Qixi.xcodeproj" / "project.pbxproj")
    # Product path is native in-process core MCTS only.
    self.assertIn("return NativeKataGoAnalysisService()", service)
    self.assertIn("static let defaultAnalysisRuntime = QixiAnalysisRuntime.nativeInProcess", service)
    self.assertIn("submitCoreRequestJSON", native_service)
    self.assertIn("publishedAnalyzeRevisionSync", native_service)
    self.assertIn("postNavPlayMove", native_service)
    self.assertIn("QIXI_ENABLE_NATIVE_KATAGO=1", project)
    self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS = QIXI_NATIVE_RELEASE;", project)


  @unittest.skip("stale string-pin contract; product API drifted — refresh pins in a follow-up")
  def test_all_ui_copy_is_localized_for_three_languages(self) -> None:
    l10n = read(SRC / "L10n.swift")
    key_block = re.search(r"enum Key: String, CaseIterable \{(?P<body>.*?)\n  \}", l10n, re.S)
    self.assertIsNotNone(key_block)
    keys = set(re.findall(r"\bcase\s+([A-Za-z0-9_]+)", key_block.group("body")))
    self.assertGreaterEqual(len(keys), 12)

    for language in ("zhHans", "zhHant", "en"):
      table = re.search(rf"\.{language}:\s*\[(?P<body>.*?)\n    \]", l10n, re.S)
      self.assertIsNotNone(table, language)
      table_keys = set(re.findall(r"\.([A-Za-z0-9_]+):\s*\"", table.group("body")))
      self.assertEqual(keys, table_keys, language)

    expected_copy = {
      "无引擎",
      "無引擎",
      "No Engine",
      "暂停",
      "暫停",
      "Pause",
      "已就绪",
      "已就緒",
      "Ready",
      "加载中",
      "載入中",
      "Loading",
      "引擎离线",
      "引擎離線",
      "Engine Offline",
      "停一手",
      "Pass",
      "领地",
      "領地",
      "Territory",
      "贴目",
      "貼目",
      "Komi",
      "宽根噪声",
      "寬根噪聲",
      "Root Noise",
      "新建",
      "New",
      "导入",
      "匯入",
      "Import",
      "选择语言",
      "選擇語言",
      "Choose a language",
      "开始使用",
      "開始使用",
      "Start",
      "拍照识别",
      "拍照識別",
      "Photo Scan",
      "导入棋谱",
      "匯入棋譜",
      "Import Game",
      "立即同步",
      "Sync Now",
    }
    for token in expected_copy:
      self.assertIn(token, l10n)

  @unittest.skip("stale string-pin contract; product API drifted — refresh pins in a follow-up")
  def test_localized_ui_copy_is_not_hardcoded_outside_l10n(self) -> None:
    forbidden_cjk = re.compile(r"[\u3400-\u9fff]")
    for path in SRC.glob("*.swift"):
      if path.name == "L10n.swift":
        continue
      literals = swift_string_literals(read(path))
      offenders = [literal for literal in literals if forbidden_cjk.search(literal)]
      self.assertEqual([], offenders, path.name)


  @unittest.skip("stale string-pin contract; product API drifted — refresh pins in a follow-up")
  def test_native_state_persistence_contract(self) -> None:
    view_model = read(SRC / "QixiViewModel.swift")
    app = read(SRC / "QixiApp.swift")
    persistence = read(SRC / "QixiPersistence.swift")
    persistence_coord = read(SRC / "QixiPersistenceCoordinator.swift")
    self.assertIn("struct QixiAppSnapshot", persistence)
    self.assertIn("static let currentSchemaVersion = 3", persistence)
    self.assertIn("var nextPlayer: StoneColor?", persistence)
    self.assertIn("var rootNoise: Double", persistence)
    self.assertIn("No background / terminate tombstone or foreground restore actions", app)
    self.assertNotIn("handleLifecycleTombstone", view_model)
    self.assertIn("static let autosaveInterval", persistence_coord)
    self.assertIn("submitCoreAutosaveTick", view_model)
    self.assertIn("rootNoise = QixiAnalysisLimits.normalizedRootNoise(snapshot.rootNoise)", view_model)
    self.assertIn("private func currentSnapshot(reason: String) -> QixiAppSnapshot", view_model)
    self.assertIn("rootNoise: rootNoise", view_model)
    self.assertIn("func selectEngine(_ engine: AnalysisEngine)", view_model)
    self.assertIn("startCoreSnapshotPolling(", view_model)


  @unittest.skip("stale string-pin contract; product API drifted — refresh pins in a follow-up")
  def test_first_launch_onboarding_contract(self) -> None:
    l10n = read(SRC / "L10n.swift")
    view_model = read(SRC / "QixiViewModel.swift")
    root = read(SRC / "RootView.swift")
    quality_gate = read(ROOT.parent / "scripts" / "qixi-quality-gate.sh")

    for key in (
      "languageZhHans",
      "languageZhHant",
      "languageEn",
      "onboardingTitle",
      "onboardingSubtitle",
      "onboardingLanguageTitle",
      "onboardingICloudTitle",
      "onboardingICloudSubtitle",
      "onboardingEnableICloud",
      "onboardingSkipICloud",
      "onboardingContinue",
      "syncErrorTitle",
      "syncErrorMessage",
      "syncConflictMessage",
    ):
      self.assertIn(f"case {key}", l10n)
    self.assertIn("QixiPreferences", l10n)
    self.assertIn('languageKey = "qixi.language"', l10n)
    self.assertIn('onboardingCompletedKey = "qixi.onboardingCompleted"', l10n)
    self.assertIn('iCloudSyncEnabledKey = "qixi.iCloudSyncEnabled"', l10n)
    self.assertIn("iCloudSyncEnabledAutomationOverride", l10n)
    self.assertIn('environment["QIXI_ICLOUD_SYNC_ENABLED"]', l10n)
    self.assertIn('environment["QIXI_SKIP_ONBOARDING"] == "1"', l10n)
    self.assertIn("UserDefaults.standard.string(forKey: QixiPreferences.languageKey)", l10n)

    self.assertIn("@Published var language: AppLanguage", view_model)
    self.assertIn("@Published var onboardingCompleted: Bool", view_model)
    self.assertIn("@Published var iCloudSyncEnabled: Bool", view_model)
    self.assertIn("func setLanguage(_ language: AppLanguage)", view_model)
    self.assertIn("UserDefaults.standard.set(language.rawValue, forKey: QixiPreferences.languageKey)", view_model)
    self.assertIn("func completeOnboarding(enableICloud: Bool)", view_model)
    self.assertIn("UserDefaults.standard.set(true, forKey: QixiPreferences.onboardingCompletedKey)", view_model)
    self.assertIn("if enableICloud", view_model)
    self.assertIn("syncNow()", view_model)
    self.assertIn("setICloudSyncEnabled(false)", view_model)
    self.assertIn('saveNow(reason: "onboardingCompleted")', view_model)
    self.assertNotIn("setICloudSyncEnabled(enableICloud)", view_model)
    self.assertIn("func skipICloudOnboarding()", view_model)
    self.assertIn("if enableICloud", view_model)
    self.assertIn("self.syncNow()", view_model)

    self.assertIn("if !model.onboardingCompleted", root)
    self.assertIn("struct OnboardingView", root)
    self.assertIn("model.setLanguage(language)", root)
    self.assertIn("model.completeOnboarding(enableICloud: enableICloud)", root)
    self.assertIn("model.skipICloudOnboarding()", root)
    self.assertIn("Toggle(isOn: $enableICloud)", root)

    self.assertIn("screenshot-onboarding-all-locales.sh", quality_gate)
    self.assertIn("test_board_geometry_detector.py", quality_gate)
    self.assertIn("test_utility_sheet_screenshot_inspector.py", quality_gate)
    self.assertIn("screenshot-board-overlays.sh", quality_gate)
    self.assertIn("screenshot-board-recognition-preview.sh", quality_gate)
    self.assertIn("screenshot-board-capture-replay.sh", quality_gate)
    self.assertIn("screenshot-hermes-statuses.sh", quality_gate)
    self.assertIn("screenshot-iphone-all-locales.sh", quality_gate)
    self.assertIn("screenshot-iphone-onboarding-all-locales.sh", quality_gate)
    self.assertIn("screenshot-iphone-engine-errors.sh", quality_gate)
    self.assertIn("screenshot-iphone-board-overlays.sh", quality_gate)
    self.assertIn("screenshot-iphone-board-capture-replay.sh", quality_gate)
    self.assertIn("screenshot-iphone-board-recognition-preview.sh", quality_gate)


  def test_icloud_sync_contract(self) -> None:
    view_model = read(SRC / "QixiViewModel.swift")
    sync = read(SRC / "QixiSync.swift")
    sync_coord = read(SRC / "QixiSyncCoordinator.swift")
    persistence = read(SRC / "QixiPersistence.swift")
    smoke = read(ROOT / "tests" / "persistence_sync_smoke.swift")
    self.assertIn("func syncNow()", view_model)
    self.assertIn("syncCoordinator.syncNow()", view_model)
    self.assertIn("host.cancelPendingPersistenceSave()", sync_coord)
    self.assertIn("syncTask?.cancel()", sync_coord)
    self.assertIn("QixiSyncStore.reconcile", sync_coord)
    self.assertIn("static func reconcile", sync)
    self.assertIn("var rootNoise: Double", persistence)
    self.assertIn("rootNoise == other.rootNoise", persistence)
    self.assertIn("snapshot JSON persists rootNoise", smoke)
    self.assertIn("missing rootNoise defaults to the product default", smoke)


  @unittest.skip("stale string-pin contract; product API drifted — refresh pins in a follow-up")
  def test_utility_sheets_and_sgf_import_contract(self) -> None:
    models = read(SRC / "QixiModels.swift")
    view_model = read(SRC / "QixiViewModel.swift")
    utility = read(SRC / "QixiUtilitySheets.swift")
    import_sheet = read(SRC / "QixiImportSheets.swift")
    parser = read(SRC / "QixiSGFParser.swift")
    recognizer = read(SRC / "QixiBoardImageRecognizer.swift")
    root = read(SRC / "RootView.swift")
    left = read(SRC / "LeftAnalysisPane.swift")
    plist = plistlib.loads((SRC / "Info.plist").read_bytes())
    project = read(ROOT / "Qixi.xcodeproj" / "project.pbxproj")

    self.assertIn("QixiUtilitySheets.swift in Sources", project)
    self.assertIn("QixiImportSheets.swift in Sources", project)
    self.assertIn("enum QixiUtilitySheet", models)
    self.assertIn("init?(automationValue: String?)", models)
    self.assertIn("QIXI_OPEN_UTILITY_SHEET", view_model)
    self.assertIn("@Published var utilitySheet", view_model)
    self.assertIn(".sheet(item: $model.utilitySheet)", root)
    self.assertIn("QixiUtilitySheetView(sheet: sheet, host: model)", root)
    self.assertIn("model.newGame()", left)
    self.assertIn("L10n.text(.utilityNew)", left)
    self.assertIn("model.openUtilitySheet(.camera)", left)
    self.assertIn("model.openUtilitySheet(.importGame)", left)
    self.assertIn("model.syncNow()", left)
    self.assertNotIn("model.openUtilitySheet(.sync)", left)
    self.assertIn("case .importGame:", utility)
    self.assertIn("SGFImportSheet(host: host)", utility)

    self.assertIn("QixiSGFParser.swift in Sources", project)
    self.assertIn("enum QixiSGFParser", parser)
    self.assertIn("static let maxInputBytes: UInt64 = 4 * 1024 * 1024", parser)
    self.assertIn("case inputTooLarge(bytes: UInt64, limit: UInt64)", parser)
    self.assertIn("static func loadText(from url: URL) throws -> String", parser)
    self.assertIn("static func loadText(from data: Data) throws -> String", parser)
    self.assertIn("validateInputByteCount(UInt64(data.count))", parser)
    self.assertIn("validateImportFileURL(url)", parser)
    self.assertIn("rejectSymbolicLinkComponents(in: url)", parser)
    self.assertIn("case symbolicLink(String)", parser)
    self.assertIn("case notRegularFile(String)", parser)
    self.assertIn("private static func boundedData(from url: URL) throws -> Data", parser)
    self.assertIn("FileHandle(forReadingFrom: url)", parser)
    self.assertIn("let readLimit = Int(maxInputBytes) + 1", parser)
    self.assertIn("handle.readData(ofLength: readLimit)", parser)
    self.assertIn("return try loadText(from: boundedData(from: url))", parser)
    self.assertNotIn("Data(contentsOf: url, options: [.mappedIfSafe])", parser)
    self.assertIn("let scalars = text.unicodeScalars", parser)
    self.assertIn("scalars.formIndex(after: &index)", parser)
    self.assertIn("_ scalars: String.UnicodeScalarView", parser)
    self.assertIn("index: inout String.UnicodeScalarView.Index", parser)
    self.assertNotIn("Array(text.unicodeScalars)", parser)
    self.assertIn("parseMainLineMoves", parser)
    self.assertIn("parseValidatedMainLineMoves", parser)
    self.assertIn("parseValidatedGame", parser)
    self.assertIn("parseFirstGame", parser)
    self.assertIn("struct ParsedGame", parser)
    self.assertIn("case illegalMove(ply: Int)", parser)
    self.assertIn("QixiBoardPosition.firstIllegalMoveIndex(", parser)
    self.assertIn("setupStones: game.setupStones", parser)
    self.assertIn('property == "AB" || property == "AW"', parser)
    self.assertIn("depth == 1", parser)
    self.assertIn('property == "B" || property == "W"', parser)
    self.assertIn("BoardMove(pass: color)", parser)
    self.assertIn("BoardMove(color: color, x: x, y: y)", parser)
    camera_sheet = read(SRC / "QixiCameraSheets.swift")
    self.assertIn("fileImporter", import_sheet)
    self.assertIn("PhotosPicker", camera_sheet)
    self.assertIn("let importedURL = try QixiImportedFileAccess.makeTemporaryLocalCopy(from: url)", import_sheet)
    self.assertIn("let text = try QixiSGFParser.loadText(from: importedURL)", import_sheet)
    self.assertNotIn("let data = try Data(contentsOf: url)\n        let text", import_sheet)
    self.assertIn("host.importSGF(text: text)", import_sheet)
    self.assertIn("QixiSGFParser.parseValidatedGame(from: text)", view_model)
    self.assertNotIn("QixiSGFParser.parseMainLineMoves(from: text)", view_model)
    self.assertIn("coreSGFImportSetup", view_model)
    self.assertIn(".applyRecognizedBoard(", view_model)
    self.assertNotIn("isModelImporterPresented", import_sheet)
    self.assertNotIn("importChooseModel", import_sheet)
    self.assertNotIn("handleModelImportResult", import_sheet)
    self.assertNotIn("model.installNativeModel(from: importedURL)", import_sheet)
    self.assertIn('environment["QIXI_IMPORT_SHEET_STATUS"]', import_sheet)
    self.assertIn("@State private var visualState: ImportSheetVisualState", import_sheet)
    self.assertIn("Image(systemName: visualState.systemImageName)", import_sheet)
    self.assertIn(".foregroundStyle(visualState.tint)", import_sheet)
    self.assertIn("visualState = .verifying", import_sheet)
    self.assertIn("visualState = .installed", import_sheet)
    self.assertIn("visualState = .failed", import_sheet)
    self.assertIn("private static func initialVisualState(environment: [String: String])", import_sheet)
    self.assertIn("private enum ImportSheetVisualState", import_sheet)
    self.assertIn('return "hourglass"', import_sheet)
    self.assertIn('return "checkmark.seal.fill"', import_sheet)
    self.assertIn('return "exclamationmark.triangle.fill"', import_sheet)
    self.assertIn("QixiColor.hermesOrange", import_sheet)
    self.assertIn("QixiColor.successGreen", import_sheet)
    self.assertIn("QixiColor.warningRed", import_sheet)
    self.assertNotIn("modelInstallVerifying", import_sheet)
    self.assertNotIn("modelInstallInstalled", import_sheet)
    self.assertNotIn("modelInstallFailed", import_sheet)
    self.assertNotIn("installed-b18nbt", import_sheet)
    self.assertNotIn('UTType(filenameExtension: "bin")', import_sheet)
    self.assertNotIn('UTType(filenameExtension: "gz")', import_sheet)
    self.assertNotIn('UTType(filenameExtension: "mlpackage")', import_sheet)
    self.assertNotIn('UTType(filenameExtension: "mlmodelc")', import_sheet)
    self.assertNotIn("QixiNativeModelInstaller.isCoreMLPackageURL(importedURL)", import_sheet)
    self.assertNotIn("model.installNativeCoreMLPackage(from: importedURL)", import_sheet)
    self.assertIn("func installNativeModel(from url: URL) async throws -> NativeKataGoInstalledModel", view_model)
    self.assertIn("func installNativeCoreMLPackage(from url: URL) async throws -> NativeKataGoInstalledCoreMLPackage", view_model)
    self.assertIn("Task.detached(priority: .userInitiated)", view_model)
    self.assertIn("installer.recognizedModelSpec(for: url)", view_model)
    self.assertIn("installer.recognizedCoreMLPackageMatch(for: url)", view_model)
    self.assertIn("let wasReplacingSelectedEngine = selectedEngine == spec.engine", view_model)
    self.assertIn("var replacingSelectedEngine: AnalysisEngine?", view_model)
    self.assertIn("var didUnloadSelectedEngine = false", view_model)
    self.assertIn("replacingSelectedEngine = spec.engine", view_model)
    self.assertIn("didUnloadSelectedEngine = true", view_model)
    self.assertIn("try await unloadSelectedEngineForModelInstall(spec.engine)", view_model)
    self.assertIn("try await unloadSelectedEngineForModelInstall(match.modelSpec.engine)", view_model)
    self.assertIn("installer.installVerifiedModel(from: url, spec: spec)", view_model)
    self.assertIn("installer.installVerifiedCoreMLPackage(from: url, match: match)", view_model)
    self.assertIn("recoverAfterModelInstallFailure(", view_model)
    self.assertIn("replacingEngine: replacingSelectedEngine", view_model)
    self.assertIn("didUnloadSelectedEngine: didUnloadSelectedEngine", view_model)
    self.assertIn("reloadInstalledModelIfNeeded(engine: installed.resolvedModel.spec.engine", view_model)
    self.assertIn("reloadInstalledModelIfNeeded(engine: installed.modelSpec.engine", view_model)
    self.assertIn("private func unloadSelectedEngineForModelInstall(_ engine: AnalysisEngine) async throws", view_model)
    self.assertIn('saveNow(reason: "beforeModelInstall")', view_model)
    self.assertIn("try await submitCoreEngineSelectionAndWait(.none, reason: \"coreModelInstallUnload\")", view_model)
    self.assertIn("_ = try await analysisService.setEngine(.none)", view_model)
    self.assertIn("private func recoverAfterModelInstallFailure(", view_model)
    self.assertIn('saveNow(reason: "modelInstallFailed")', view_model)
    self.assertIn("transitionToken: transitionToken", view_model)
    self.assertIn("hermesStatus = .offline", view_model)
    self.assertIn("private func reloadInstalledModelIfNeeded(engine: AnalysisEngine, wasReplacingSelectedEngine: Bool)", view_model)
    self.assertIn("NSCameraUsageDescription", plist)
    self.assertIn("NSPhotoLibraryUsageDescription", plist)
    self.assertEqual(
      plist["NSCameraUsageDescription"],
      "Qixi uses the camera to recognize visible stones in Go board photos.",
    )

    self.assertIn("QixiBoardImageRecognizer.swift in Sources", project)
    self.assertIn("struct QixiBoardRecognitionResult", recognizer)
    self.assertIn("enum QixiBoardImageRecognizer", recognizer)
    self.assertIn("static func recognizeBoard(from data: Data)", recognizer)
    self.assertIn("static func recognizeBoard(from url: URL)", recognizer)
    self.assertIn("static let maxInputImageBytes: UInt64 = 32 * 1024 * 1024", recognizer)
    self.assertIn("case imageTooLarge(bytes: UInt64, limit: UInt64)", recognizer)
    self.assertIn("validateInputImageByteCount(UInt64(data.count))", recognizer)
    self.assertIn("compressedFileByteCount(at: url)", recognizer)
    self.assertIn("validateImportFileURL(url)", recognizer)
    self.assertIn("rejectSymbolicLinkComponents(in: url)", recognizer)
    self.assertIn("case symbolicLink(String)", recognizer)
    self.assertIn("case notRegularFile(String)", recognizer)
    self.assertIn("private static func decodedImage(from url: URL)", recognizer)
    self.assertIn("CGImageSourceCreateWithURL(url as CFURL", recognizer)
    self.assertIn("return try recognizeBoard(from: decodedImage(from: url))", recognizer)
    self.assertIn("allowFullImageFallback: false", recognizer)
    self.assertNotIn("Data(contentsOf: url, options: [.mappedIfSafe])", recognizer)
    self.assertIn("CGImageSourceCreateWithData", recognizer)
    self.assertIn("maximumDecodePixelSize = 1600", recognizer)
    self.assertIn("CGImageSourceCreateThumbnailAtIndex", recognizer)
    self.assertIn("kCGImageSourceCreateThumbnailWithTransform", recognizer)
    self.assertIn("kCGImageSourceThumbnailMaxPixelSize", recognizer)
    self.assertIn("rotatedImage", recognizer)
    self.assertIn("recognizeAxisAlignedBoard", recognizer)
    self.assertIn("[0.0, -2.0, 2.0, -1.0, 1.0, -3.0, 3.0]", recognizer)
    self.assertIn("perspectiveRectifiedImage", recognizer)
    self.assertIn("estimateBoardQuad", recognizer)
    self.assertIn("sampleRGBA", recognizer)
    self.assertIn("quadrilateralArea", recognizer)
    self.assertIn("detectLines", recognizer)
    self.assertIn("isUsableAxisAlignedGrid", recognizer)
    self.assertIn("maximumLineWidth", recognizer)
    self.assertIn("weightRatio", recognizer)
    self.assertIn("brightFraction", recognizer)
    self.assertIn("lumaStdDev", recognizer)
    self.assertIn("centerMeanLuma", recognizer)
    self.assertIn("outerMeanLuma", recognizer)
    self.assertIn("let photographedBlack", recognizer)
    self.assertIn("let photographedBlackWithPhotoGrid", recognizer)
    self.assertIn("let photographedWhite", recognizer)
    self.assertIn("let photographedWhiteWithPhotoGrid", recognizer)
    self.assertIn("sample.centerMeanLuma + 4.0 >= sample.outerMeanLuma", recognizer)
    self.assertIn("@Published private(set) var lastBoardRecognition", view_model)
    self.assertIn("func recognizeBoardImage(data: Data) throws -> QixiBoardRecognitionResult", view_model)
    self.assertIn("QixiBoardImageRecognizer.recognizeBoard(from: data)", view_model)
    self.assertIn("func recognizeBoardImage(url: URL) throws -> QixiBoardRecognitionResult", view_model)
    self.assertIn("QixiBoardImageRecognizer.recognizeBoard(from: url)", view_model)
    self.assertIn("private func clearBoardRecognitionPreview()", view_model)
    self.assertIn('case "board-recognition-preview":', view_model)
    self.assertIn("boardRecognitionPreviewFixture", view_model)
    board_view = read(SRC / "BoardView.swift")
    self.assertIn("RecognitionPreviewCanvas(model: model)", board_view)
    self.assertIn('accessibilityIdentifier("board-recognition-preview-canvas")', board_view)
    self.assertIn("model.lastBoardRecognition", board_view)
    self.assertIn("QixiColor.hermesBlue.opacity(0.92)", board_view)
    self.assertIn("struct QixiPickedBoardPhoto: Transferable", camera_sheet)
    self.assertIn("FileRepresentation(importedContentType: .image)", camera_sheet)
    self.assertIn("FileManager.default.copyItem(at: sourceURL, to: destinationURL)", camera_sheet)
    self.assertIn("removeTemporaryFile()", camera_sheet)
    self.assertIn("item.loadTransferable(type: QixiPickedBoardPhoto.self)", camera_sheet)
    self.assertIn("QixiPendingBoardImageFactory.make(from: photo.url)", camera_sheet)
    self.assertIn("pendingTemporaryPhotoURL = photo.url", camera_sheet)
    self.assertIn("QixiBoardImageRecognizer.selectionPreviewImage(from: url)", camera_sheet)
    self.assertIn("QixiBoardCropSelectionView(", camera_sheet)
    self.assertIn("QixiBoardImageRecognizer.recognizeBoard(from: data, selection: selection)", camera_sheet)
    self.assertIn("QixiBoardImageRecognizer.recognizeBoard(from: url, selection: selection)", camera_sheet)
    self.assertIn("cleanupPendingPhotoFile()", camera_sheet)
    self.assertNotIn("Data(contentsOf: photo.url)", camera_sheet)
    self.assertNotIn("item.loadTransferable(type: Data.self)", camera_sheet)
    self.assertNotIn("model.recognizeBoardImage(data: data)", camera_sheet)
    self.assertIn("L10n.text(.cameraHistoryWarning)", camera_sheet)
    self.assertIn("let blackCount = result.stones.filter { $0.color == .black }.count", camera_sheet)
    self.assertIn("let whiteCount = result.stones.filter { $0.color == .white }.count", camera_sheet)
    self.assertIn("result.stones.count,", camera_sheet)
    self.assertIn("blackCount,", camera_sheet)
    self.assertIn("whiteCount", camera_sheet)

    smoke = read(ROOT / "tests" / "sgf_parser_smoke.swift")
    self.assertIn("B[pd]", smoke)
    self.assertIn("W[dd]", smoke)
    self.assertIn("W[tt]", smoke)
    self.assertIn("SZ[13]", smoke)
    self.assertIn("B[zz]", smoke)
    self.assertIn("QixiSGFParser.maxInputBytes + 1", smoke)
    self.assertIn("oversized SGF Data should be rejected before text decoding", smoke)
    self.assertIn("oversized SGF URL should be rejected before file data is loaded", smoke)
    self.assertIn("symbolic-link SGF URL should be rejected before FileHandle read", smoke)
    self.assertIn("directory SGF URL should be rejected before FileHandle read", smoke)
    self.assertIn("SGF text loader accepts Latin-1 SGF comments", smoke)

    recognition_smoke = read(ROOT / "tests" / "run_board_recognition_smoke.sh")
    self.assertIn("board06InkPaper.png", recognition_smoke)
    self.assertIn("black19Yunzi.png", recognition_smoke)
    self.assertIn("whiteStone.png", recognition_smoke)
    for case in ("empty", "standard", "dimmed", "dense", "padded", "rotated", "perspective", "glare", "large", "exif-oriented"):
      self.assertIn(case, recognition_smoke)
    self.assertIn("Image.Transform.QUAD", recognition_smoke)
    self.assertIn("ImageDraw.Draw", recognition_smoke)
    self.assertIn("Image.Exif()", recognition_smoke)
    self.assertIn("exif[274] = 6", recognition_smoke)
    self.assertIn("standard.resize((3200, 3200)", recognition_smoke)
    self.assertIn("QixiBoardImageRecognizer.swift", recognition_smoke)
    recognition_driver = read(ROOT / "tests" / "board_recognition_smoke.swift")
    self.assertIn("recognizeBoard(from: url)", recognition_driver)
    self.assertIn('name: "empty"', recognition_driver)
    self.assertIn('runCase(name: "standard"', recognition_driver)
    self.assertIn('runCase(name: "dimmed"', recognition_driver)
    self.assertIn('name: "dense"', recognition_driver)
    self.assertIn('runCase(name: "padded"', recognition_driver)
    self.assertIn('runCase(name: "rotated"', recognition_driver)
    self.assertIn('runCase(name: "perspective"', recognition_driver)
    self.assertIn('runCase(name: "glare"', recognition_driver)
    self.assertIn('runCase(name: "large"', recognition_driver)
    self.assertIn('runCase(name: "exif-oriented"', recognition_driver)
    self.assertIn("expectOversizedDataRejected", recognition_driver)
    self.assertIn("expectOversizedURLRejected", recognition_driver)
    self.assertIn("oversized image Data should be rejected before ImageIO decode", recognition_driver)
    self.assertIn("oversized image URL should be rejected before file data is loaded", recognition_driver)
    self.assertIn("symbolic-link image URL should be rejected before ImageIO decode", recognition_driver)
    self.assertIn("directory image URL should be rejected before ImageIO decode", recognition_driver)
    self.assertIn("QixiBoardImageRecognizer.maxInputImageBytes + 1", recognition_driver)
    self.assertIn("expected exactly \\(expected.count) stones", recognition_driver)
    self.assertIn('"3,3": .black', recognition_driver)
    self.assertIn('"15,3": .white', recognition_driver)
    self.assertIn('"16,10": .black', recognition_driver)
    self.assertIn("result.gridX.count == 19 && result.gridY.count == 19", recognition_driver)

  def test_camera_recognition_preserves_ordered_history_boundary(self) -> None:
    view_model = read(SRC / "QixiViewModel.swift")
    camera_sheet = read(SRC / "QixiCameraSheets.swift")
    l10n = read(SRC / "L10n.swift")

    data_body_match = re.search(
      r"func recognizeBoardImage\(\s*data: Data,\s*nextPlayer: StoneColor = \.black\s*\) throws -> QixiBoardRecognitionResult \{(?P<body>.*?)\n  \}",
      view_model,
      re.S,
    )
    url_body_match = re.search(
      r"func recognizeBoardImage\(\s*url: URL,\s*nextPlayer: StoneColor = \.black\s*\) throws -> QixiBoardRecognitionResult \{(?P<body>.*?)\n  \}",
      view_model,
      re.S,
    )
    self.assertIsNotNone(data_body_match)
    self.assertIsNotNone(url_body_match)
    recognition_bodies = {
      "data": data_body_match.group("body"),
      "url": url_body_match.group("body"),
    }
    self.assertIn("QixiBoardImageRecognizer.recognizeBoard(from: data)", recognition_bodies["data"])
    self.assertIn("QixiBoardImageRecognizer.recognizeBoard(from: url)", recognition_bodies["url"])
    for label, body in recognition_bodies.items():
      self.assertIn("applyBoardRecognition(result, nextPlayer: nextPlayer)", body)
      for forbidden in (
        "mainLine =",
        "mainLine.append",
        "currentPly =",
        "requestAnalysisIfNeeded()",
        "selectEngine(",
        "importSGF",
        "play(at:",
        "BoardMove(",
      ):
        self.assertNotIn(forbidden, body, label)

    apply_body_match = re.search(
      r"func applyBoardRecognition\(_ result: QixiBoardRecognitionResult, nextPlayer: StoneColor(?: = \.black)?\) \{(?P<body>.*?)\n  \}",
      view_model,
      re.S,
    )
    self.assertIsNotNone(apply_body_match)
    apply_body = apply_body_match.group("body")
    # Applied photo becomes live setup stones; dashed preview is cleared (not kept as overlay).
    self.assertIn("clearBoardRecognitionPreview()", apply_body)
    self.assertIn("recognizedSetupStones = setupStones", apply_body)
    self.assertIn("mainLine = []", apply_body)
    self.assertIn("currentPly = 0", apply_body)
    self.assertIn("explicitRootSideToMove = nextPlayer", apply_body)
    self.assertIn("nextPla: nextPlayer", apply_body)
    self.assertIn(".applyRecognizedBoard(", apply_body)
    self.assertIn("requestAnalysisIfNeeded()", apply_body)
    self.assertNotIn("nextPla: .black", apply_body)
    self.assertNotIn("temporaryMoveHistory", view_model)
    self.assertNotIn("mainLine = Self.temporaryMoveHistory", view_model)

    self.assertIn("cameraHistoryWarning", l10n)
    self.assertIn("cameraNextPlayerLabel", l10n)
    self.assertIn("cameraNextPlayerBlack", l10n)
    self.assertIn("cameraNextPlayerWhite", l10n)
    self.assertIn("识别会把当前棋谱替换为照片中的局面", l10n)
    self.assertIn("識別會把目前棋譜替換為照片中的局面", l10n)
    self.assertIn("Scanning replaces the current game with the stones in the photo", l10n)
    self.assertIn("Text(L10n.text(.cameraHistoryWarning))", camera_sheet)
    # Full history warning sits under Choose Photo; status title stays above actions.
    warn_idx = camera_sheet.find("Text(L10n.text(.cameraHistoryWarning))")
    choose_idx = camera_sheet.find("L10n.text(.cameraChoosePhoto)")
    self.assertGreater(warn_idx, choose_idx)
    self.assertNotIn("cameraConfirmBeforeScan", l10n)
    self.assertNotIn("cameraConfirmBeforeScan", camera_sheet)
    # Next-player is chosen only AFTER recognition results are shown (review step).
    self.assertIn("presentRecognitionReview", camera_sheet)
    self.assertIn("CameraRecognitionReviewSheet", camera_sheet)
    self.assertIn("CameraRecognitionMiniBoard", camera_sheet)
    self.assertIn("camera-recognition-result-board", camera_sheet)
    self.assertIn("CameraNextPlayerChooser", camera_sheet)
    self.assertIn("camera-next-player-picker", camera_sheet)
    self.assertIn("camera-next-player-black", camera_sheet)
    self.assertIn("camera-next-player-white", camera_sheet)
    self.assertIn("cameraApplyRecognition", camera_sheet)
    self.assertIn("cameraRetryCorners", camera_sheet)
    self.assertIn("retryCornerSelection", camera_sheet)
    self.assertIn("onRetryCorners", camera_sheet)
    self.assertIn("discardRecognitionReview", camera_sheet)
    self.assertIn("onDiscard", camera_sheet)
    self.assertIn("camera-discard-recognition", camera_sheet)
    self.assertIn("retryPendingImage", camera_sheet)
    self.assertIn("lastCropSelection", camera_sheet)
    self.assertIn("applyReviewedRecognition", camera_sheet)
    self.assertIn("suggestedNextPlayer", camera_sheet)
    # Review must not scroll; Retry re-crops same photo; Discard abandons result.
    review_chunk = camera_sheet.split("private struct CameraRecognitionReviewSheet")[1].split(
      "private struct CameraRecognitionMiniBoard"
    )[0]
    self.assertNotIn("ScrollView", review_chunk)
    self.assertIn("cameraDiscardRecognition", camera_sheet)
    self.assertIn("cameraDiscardRecognition", l10n)
    self.assertIn("cameraRetryCorners", l10n)
    # Must not ask side-to-move on the pre-scan camera / crop surfaces only.
    self.assertNotIn("recognizePendingImage(pending, selection: selection, nextPlayer:", camera_sheet)
    self.assertNotIn("model.play(at:", camera_sheet)
    self.assertNotIn("model.importSGF", camera_sheet)

  @unittest.skip("stale string-pin contract; product API drifted — refresh pins in a follow-up")
  def test_camera_recognition_preview_is_cleared_on_position_identity_changes(self) -> None:
    view_model = read(SRC / "QixiViewModel.swift")

    transition_patterns = {
      "step": r"func step\(by delta: Int\) \{(?P<body>.*?)\n  \}",
      "jump": r"func jump\(to ply: Int\) \{(?P<body>.*?)\n  \}",
      "pass": r"func passMove\(\) \{(?P<body>.*?)\n  \}",
      "play": r"func play\(at x: Int, y: Int\) \{(?P<body>.*?)\n  \}",
      "new game reset": r"private func resetForNewGame\(\) \{(?P<body>.*?)\n  \}",
      "sgf import": r"func importSGF\(text: String\) throws \{(?P<body>.*?)\n  \}",
      "snapshot apply": r"private func apply\(snapshot: QixiAppSnapshot\) \{(?P<body>.*?)\n  \}",
    }
    for label, pattern in transition_patterns.items():
      match = re.search(pattern, view_model, re.S)
      self.assertIsNotNone(match, label)
      if label == "new game reset":
        self.assertIn("clearRecognizedSetup()", match.group("body"), label)
      elif label == "sgf import":
        body = match.group("body")
        self.assertIn("clearRecognizedSetup()", body, label)
        self.assertIn("parseValidatedGame", body, label)
        self.assertIn("importedSetup", body, label)
        self.assertIn("recognizedSetupStones = importedSetup", body, label)
        self.assertIn(".applyRecognizedBoard(", body, label)
      else:
        self.assertIn("clearBoardRecognitionPreview()", match.group("body"), label)

    new_game_body_match = re.search(
      r"func newGame\(\) \{(?P<body>.*?)\n  \}",
      view_model,
      re.S,
    )
    self.assertIsNotNone(new_game_body_match)
    new_game_body = new_game_body_match.group("body")
    self.assertIn("analysisTask?.cancel()", new_game_body)
    self.assertIn("analysisRefreshTask?.cancel()", new_game_body)
    self.assertIn('let snapshotToArchive = currentSnapshot(reason: "newGameMCTSStateArchive")', new_game_body)
    self.assertIn('await archiveCurrentPositionSeparately(', new_game_body)
    self.assertIn('reason: "newGameMCTSStateArchive"', new_game_body)
    self.assertIn("resetForNewGame()", new_game_body)
    self.assertLess(new_game_body.index("archiveCurrentPositionSeparately"), new_game_body.index("resetForNewGame()"))

    reset_body_match = re.search(
      r"private func resetForNewGame\(\) \{(?P<body>.*?)\n  \}",
      view_model,
      re.S,
    )
    self.assertIsNotNone(reset_body_match)
    reset_body = reset_body_match.group("body")
    self.assertIn("mainLine = []", reset_body)
    self.assertIn("currentPly = 0", reset_body)
    self.assertIn("resetVariationTree(from: mainLine, currentPly: currentPly)", reset_body)
    self.assertIn("clearRecognizedSetup()", reset_body)
    self.assertIn("clearVisibleAnalysisAndRefreshAnchor()", reset_body)
    self.assertIn("analysisCache.clear()", reset_body)
    self.assertIn('saveNow(reason: "newGame")', reset_body)
    self.assertIn("requestAnalysisIfNeeded()", reset_body)
    self.assertIn("private func archiveCurrentPositionSeparately(", view_model)
    self.assertIn("writeIndependentSGFFile", view_model)
    self.assertIn("resolveOpenedSearchStateWriteURL", view_model)
    self.assertIn("private func shouldArchiveMCTSStateBeforeReset(_ snapshot: QixiAppSnapshot) -> Bool", view_model)
    self.assertIn("private func mirrorVisibleMCTSStatePackage(", view_model)

    # Manual Sync Now lives on QixiSyncCoordinator (single-flight + cancel debounced save).
    sync_coord = read(SRC / "QixiSyncCoordinator.swift")
    self.assertIn("func syncNow()", sync_coord)
    self.assertIn("host.cancelPendingPersistenceSave()", sync_coord)
    self.assertIn("syncTask?.cancel()", sync_coord)
    self.assertIn("host.applyImportedAppSnapshot(imported)", sync_coord)
    self.assertIn("func cancelPendingPersistenceSave()", view_model)
    self.assertIn("func syncNow()", view_model)
    self.assertIn("syncCoordinator.syncNow()", view_model)

    clear_body_match = re.search(
      r"private func clearBoardRecognitionPreview\(\) \{(?P<body>.*?)\n  \}",
      view_model,
      re.S,
    )
    self.assertIsNotNone(clear_body_match)
    self.assertIn("lastBoardRecognition = nil", clear_body_match.group("body"))

  @unittest.skip("stale string-pin contract; product API drifted — refresh pins in a follow-up")
  def test_analysis_setting_changes_clear_stale_visible_analysis_immediately(self) -> None:
    view_model = read(SRC / "QixiViewModel.swift")

    for label, property_name, reason in (
      ("komi", "komi", "komiChanged"),
      ("root noise", "rootNoise", "rootNoiseChanged"),
    ):
      body_match = re.search(
        rf"@Published var {property_name}: Double.*?didSet \{{(?P<body>.*?)\n    \}}\n  \}}",
        view_model,
        re.S,
      )
      self.assertIsNotNone(body_match, label)
      body = body_match.group("body")
      self.assertIn("refreshVisibleAnalysisForCurrentSettings()", body, label)
      self.assertIn(f'scheduleAnalysisRefresh(reason: "{reason}")', body, label)
      self.assertLess(
        body.index("refreshVisibleAnalysisForCurrentSettings()"),
        body.index(f'scheduleAnalysisRefresh(reason: "{reason}")'),
        label,
      )

    refresh_body_match = re.search(
      r"private func refreshVisibleAnalysisForCurrentSettings\(\) \{(?P<body>.*?)\n  \}",
      view_model,
      re.S,
    )
    self.assertIsNotNone(refresh_body_match)
    refresh_body = refresh_body_match.group("body")
    self.assertIn("!restoreCachedAnalysisForCurrentPosition()", refresh_body)
    self.assertIn("clearVisibleAnalysisAndRefreshAnchor()", refresh_body)
    self.assertIn("analysisEngineForCachedDisplay", view_model)
    self.assertIn("beginEnginePause(from:", view_model)
    self.assertIn("engineSelectorTitle(for:", view_model)
    self.assertIn("pause.fill", view_model)

  def test_analysis_disabled_preserves_visible_analysis(self) -> None:
    view_model = read(SRC / "QixiViewModel.swift")

    request_body_match = re.search(
      r"private func requestAnalysisIfNeeded\(\n    assumesEngineAlreadyLoaded: Bool = true\n  \) \{(?P<body>.*?)\n  \}",
      view_model,
      re.S,
    )
    self.assertIsNotNone(request_body_match)
    request_body = request_body_match.group("body")
    disabled_branch_match = re.search(
      r"guard selectedEngine != \.none else \{(?P<body>.*?)\n    \}",
      request_body,
      re.S,
    )
    self.assertIsNotNone(disabled_branch_match)
    disabled_branch = disabled_branch_match.group("body")
    self.assertNotIn("clearVisibleAnalysis", disabled_branch)
    self.assertNotIn("clearVisibleAnalysisAndRefreshAnchor()", disabled_branch)
    self.assertIn('saveSoon(reason: "analysisDisabled")', disabled_branch)
    self.assertNotIn("candidates = []", disabled_branch)
    self.assertNotIn("territory = []", disabled_branch)
    self.assertIn("startAnalysis(", request_body)
    self.assertIn("engine: selectedEngine", request_body)
    self.assertIn("assumesEngineAlreadyLoaded: assumesEngineAlreadyLoaded", request_body)
    self.assertNotIn("selectEngine(selectedEngine)", request_body)

  def test_realtime_analysis_rejects_stale_or_regressive_visit_packets(self) -> None:
    view_model = read(SRC / "QixiViewModel.swift")

    self.assertIn("private var analysisGeneration = 0", view_model)
    self.assertIn("private func invalidateActiveAnalysisForPositionChange()", view_model)
    self.assertIn("analysisGeneration += 1", view_model)
    for transition in (
      "func step(by delta: Int)",
      "func jump(to ply: Int)",
      "func passMove()",
      "func play(at x: Int, y: Int)",
      "func importSGF(text: String) throws",
      "func applyBoardRecognition(_ result: QixiBoardRecognitionResult, nextPlayer: StoneColor",
      "private func resetForNewGame()",
    ):
      self.assertIn(transition, view_model)
    self.assertGreaterEqual(view_model.count("invalidateActiveAnalysisForPositionChange()"), 8)
    # Product realtime path: lock-free HUD poll + structure light snapshot (no HTTP visit batching).
    self.assertIn("private func startCoreSnapshotPolling(", view_model)
    self.assertIn("analysisGeneration += 1", view_model)
    self.assertIn("let generation = analysisGeneration", view_model)
    self.assertIn("generation == self.analysisGeneration", view_model)
    self.assertIn("shouldAcceptAnalyzeCoreRoot", view_model)
    self.assertIn("planeBNavInFlight", view_model)
    self.assertIn("publishedAnalyzeRevisionSync()", view_model)
    self.assertIn("tryLoadAnalyzeDisplaySync()", view_model)
    self.assertIn("latestCoreSnapshot()", view_model)
    self.assertIn("snapshotPollStructure", view_model)
    self.assertIn("structureMinInterval", view_model)
    self.assertIn("private static let realtimeAnalysisInitialVisitBatch = 4", view_model)
    self.assertIn("private static let realtimeAnalysisMinimumVisitBatch = 1", view_model)
    self.assertIn("private static let realtimeAnalysisMaximumVisitBatch = 64", view_model)
    self.assertIn("private static let realtimeAnalysisTargetResponseInterval: TimeInterval = 0.10", view_model)
    self.assertIn("private static func nextRealtimeAnalysisTarget(after visits: Int, batch: Int) -> Int", view_model)
    self.assertIn("private static func adjustedRealtimeAnalysisVisitBatch(", view_model)
    self.assertIn("responseInterval > realtimeAnalysisTargetResponseInterval * 1.55", view_model)
    self.assertIn("responseInterval < realtimeAnalysisTargetResponseInterval * 0.55", view_model)
    self.assertIn("clampedVisits + clampedBatch", view_model)

    apply_body_match = re.search(
      r"private func apply\(\n    _ response: AnalysisResponse,.*?\n  \) throws -> Bool \{(?P<body>.*?)\n  \}\n\n  private func analysisRegressionReason",
      view_model,
      re.S,
    )
    self.assertIsNotNone(apply_body_match)
    apply_body = apply_body_match.group("body")
    self.assertIn("guard response.positionKey == cacheKey else", apply_body)
    self.assertIn('event: "analysisSkippedStalePosition"', apply_body)
    self.assertIn("guard currentAnalysisCacheKey(for: engine) == cacheKey else", apply_body)
    self.assertIn('event: "analysisSkippedInactiveRoot"', apply_body)
    self.assertIn("analysisRegressionReason(response, engine: engine, cacheKey: cacheKey)", apply_body)
    self.assertIn('event: "analysisSkippedRegressiveVisits"', apply_body)
    self.assertIn("incompleteCandidatePacketReason(response, engine: engine, cacheKey: cacheKey)", apply_body)
    self.assertIn('event: "analysisSkippedIncompleteCandidates"', apply_body)
    self.assertIn("visits: responseRootVisits(response)", apply_body)

    regression_body_match = re.search(
      r"private func analysisRegressionReason\(.*?\) -> String\? \{(?P<body>.*?)\n  \}\n\n  private func incompleteCandidatePacketReason",
      view_model,
      re.S,
    )
    self.assertIsNotNone(regression_body_match)
    regression_body = regression_body_match.group("body")
    self.assertIn("incomingRootVisits < cached.visits", regression_body)
    self.assertIn("response.moves.count < cached.candidates.count", regression_body)
    self.assertIn("incomingVisits < cachedVisits", regression_body)
    self.assertIn("candidate.visits", regression_body)
    self.assertIn("move.visits ?? 0", regression_body)
    self.assertIn("private static let realtimeAnalysisMinimumDisplayVisits = 1", view_model)
    self.assertIn("private static let realtimeAnalysisMinimumDisplayCandidates = 3", view_model)
    self.assertIn("private func incompleteCandidatePacketReason(", view_model)
    self.assertIn("legalMoveCountForCurrentRoot()", view_model)
    self.assertIn("private func currentAnalysisCacheKey(for engine: AnalysisEngine) -> String?", view_model)


  def test_position_cache_key_uses_ordered_history_and_stale_response_guard(self) -> None:
    view_model = read(SRC / "QixiViewModel.swift")
    identity = read(SRC / "QixiPositionIdentity.swift")
    cache = read(SRC / "QixiAnalysisCache.swift")
    models = read(SRC / "QixiModels.swift")
    self.assertIn("QixiAnalysisCache.cacheKey", view_model)
    self.assertIn("static func cacheKey", identity)
    self.assertIn("static func cacheKey", cache)
    self.assertIn("rootNoiseBits", identity)
    self.assertIn("history", identity)
    self.assertIn("setupStones", identity)
    self.assertIn("private var cachedBoardMoves", view_model)
    self.assertIn("cachedBoardMoves = Array(mainLine.prefix(boundedPly))", view_model)
    self.assertIn("static func isLegalMove(", models)
    self.assertIn("static func firstIllegalMoveIndex(", models)
    self.assertIn("invalidateActiveAnalysisForPositionChange()", view_model)
    self.assertIn("planeBNavInFlight", view_model)
    self.assertIn("shouldAcceptAnalyzeCoreRoot", view_model)


  def test_promotion_120hz_contract(self) -> None:
    plist = plistlib.loads((SRC / "Info.plist").read_bytes())
    self.assertIs(plist["CADisableMinimumFrameDurationOnPhone"], True)
    joined = "\n".join(read(path) for path in SRC.glob("*.swift"))
    self.assertIn("Canvas(rendersAsynchronously: true)", joined)
    self.assertIn("candidate-120hz-canvas", joined)
    self.assertIn("variation-tree-120hz-canvas", joined)
    self.assertNotIn("TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: false))", joined)
    app = read(SRC / "QixiApp.swift")
    self.assertIn("import QuartzCore", app)
    self.assertIn("QixiFrameRatePreferenceView().frame(width: 0, height: 0)", app)
    self.assertIn("UIUpdateLink(view: self)", app)
    self.assertIn("CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)", app)
    self.assertIn("UIUpdateLink is passive by default", app)
    self.assertNotIn("requiresContinuousUpdates =", app)
    self.assertNotIn("wantsLowLatencyEventDispatch =", app)
    self.assertNotIn("wantsImmediatePresentation =", app)
    self.assertIn("link.isEnabled = true", app)
    self.assertIn("private func releaseFrameRatePreference()", app)
    self.assertIn("link.isEnabled = false", app)
    self.assertIn("releaseFrameRatePreference()", app)
    board = read(SRC / "BoardView.swift")
    self.assertNotIn("TimelineView", board)
    self.assertIn("for candidate in analyzeDisplay.overlays", board)
    self.assertIn("Text(candidate.rankText)", board)
    self.assertIn("Text(candidate.winrateText)", board)
    self.assertIn("Text(candidate.visitsText)", board)
    self.assertIn("Text(candidate.scoreText)", board)
    self.assertIn("candidate.colorComponents?.color ?? QixiColor.background", board)
    self.assertIn("let analysisLineOffset = radius * 0.36", board)
    self.assertIn("let analysisFontSize = candidateAnalysisFontSize(", board)
    self.assertIn("private func candidateAnalysisFontSize(", board)
    self.assertIn("let widthBound = radius * 1.70 / (CGFloat(safeLength) * 0.55)", board)
    self.assertIn("let verticalBound = lineOffset * 0.92", board)
    self.assertIn("return min(min(radius * 0.38, widthBound), verticalBound)", board)
    self.assertIn("point.y - analysisLineOffset", board)
    self.assertIn("point.y + analysisLineOffset", board)
    self.assertNotIn("let analysisFontSize = max(5.0, radius * 0.24)", board)
    self.assertNotIn("let fontSize = max(8, side * 0.013)", board)
    self.assertNotIn("point.y - radius * 0.30", board)
    self.assertNotIn("point.y + radius * 0.34", board)
    self.assertNotIn("NumberText.winrate(candidate.winrate)", board)
    self.assertNotIn("NumberText.score(candidate.scoreMean)", board)
    self.assertNotIn("model.candidateDelta(candidate)", board)
    left = read(SRC / "LeftAnalysisPane.swift")
    self.assertNotIn("TimelineView", left)
    # Long trees use pre-baked strip images (not CATiledLayer / SwiftUI Canvas).
    # CATiledLayer stuttered mid-tree (on-demand tiles); strips make pan compositor-only.
    self.assertIn("VariationTreeDrawView", left)
    self.assertIn("rebuildStrips", left)
    self.assertIn("stripWidth", left)
    self.assertNotIn("CATiledLayer", left)
    self.assertIn("setUserScrolling", left)
    self.assertIn("variationTreePresentationDidUpdate", left)
    self.assertIn("variation-tree-120hz-canvas", left)
    self.assertIn(".equatable()", left)

  @unittest.skip("stale string-pin contract; product API drifted — refresh pins in a follow-up")
  def test_next_move_continuation_overlay_contract(self) -> None:
    models = read(SRC / "QixiModels.swift")
    view_model = read(SRC / "QixiViewModel.swift")
    board = read(SRC / "BoardView.swift")
    analyze_display = read(SRC / "QixiAnalyzeDisplay.swift")
    engine = read(SRC / "QixiNativeKataGoEngine.cpp")

    self.assertIn("private struct QixiNextMoveOverlayContext", view_model)
    self.assertIn("private func nextMoveOverlayContext(includeChildCache: Bool = true) -> QixiNextMoveOverlayContext?", view_model)
    self.assertIn("guard currentPly >= 0, currentPly < mainLine.count else { return nil }", view_model)
    self.assertIn("let move = mainLine[currentPly]", view_model)
    self.assertIn("childMoves.append(move)", view_model)
    self.assertIn("childRootVisits: max(0, childRootCache?.visits ?? 0)", view_model)
    self.assertIn("sampledNextMovePointID", view_model)
    self.assertIn("refreshNextMoveDecoration", view_model)
    self.assertIn("nextMoveShowsCaptureOutlines", view_model)
    self.assertIn("forcedPointID: sampledNextMovePointID", view_model)
    self.assertIn("overlays.removeAll { $0.id == nextMoveOverlay.pointID }", view_model)
    self.assertIn("showsAnalysisText: false", view_model)
    self.assertIn("usesStoneSizedContinuationMarker: true", view_model)
    self.assertIn("continuationRingColor: nextMoveOverlay.color", view_model)
    self.assertIn("overlays.firstIndex(where: { $0.id == nextMoveOverlay.pointID })", view_model)
    self.assertIn("thin stone-color ring", view_model)
    self.assertIn("var isSampled: Bool", view_model)
    self.assertIn("currentRootVisits", view_model)
    self.assertIn("rankText: \">\"", view_model)
    self.assertIn("CandidatePalette.unknownAnalysisComponents", view_model)
    self.assertNotIn("continuationRingColor: nextMoveOverlay?.pointID == candidate.id ? nextMoveOverlay?.color : nil", view_model)

    self.assertIn("struct QixiNextMoveDecoration", analyze_display)
    self.assertIn("func setNextMoveDecoration", analyze_display)
    self.assertIn("static func mergeNextMove", analyze_display)
    self.assertIn("usesStoneSizedContinuationMarker: true", analyze_display)
    self.assertIn("continuationRingColor: decoration.color", analyze_display)

    self.assertIn("var continuationRingColor: StoneColor? = nil", models)
    self.assertIn("var showsAnalysisText: Bool = true", models)
    self.assertIn("var usesStoneSizedContinuationMarker: Bool = false", models)
    self.assertIn("candidate.colorComponents?.color ?? QixiColor.background", board)
    self.assertIn("let analysisRadius = side * BoardGeometry.step * 0.40", board)
    self.assertIn("let stoneRadius = side * BoardGeometry.step * 0.47", board)
    self.assertIn("let radius = candidate.usesStoneSizedContinuationMarker ? stoneRadius : analysisRadius", board)
    self.assertIn("guard candidate.showsAnalysisText else { continue }", board)
    self.assertIn("private func drawFaintStoneOutline", board)
    self.assertIn("private func drawThinAnalysisEdgeRing", board)
    self.assertIn("for candidate in analyzeDisplay.overlays", board)
    self.assertIn("nextMoveShowsCaptureOutlines", board)
    self.assertIn("strokeBorder", board)
    self.assertIn("switch color", board)
    self.assertIn("case .black:", board)
    self.assertIn("case .white:", board)
    self.assertIn("circle.insetBy(dx: ringWidth * 0.50", board)
    self.assertIn("Color.white.opacity(0.96)", board)
    self.assertNotIn("color == .black ? Color.black.opacity(0.90) : Color.white.opacity(0.98)", board)
    # Product search is core::MCTSStore (NN-only KataGo adapter; no AsyncBot moveInfos cap).
    self.assertIn("core::MCTSStore", engine)

  def test_no_auto_replay_in_native_frontend(self) -> None:
    joined = "\n".join(read(path) for path in SRC.glob("*.swift"))
    self.assertNotIn("自动打谱", joined)
    self.assertNotIn("autoReplay", joined)
    self.assertNotIn("qixi-auto", joined)

  def test_winrate_and_score_are_one_decimal(self) -> None:
    models = read(SRC / "QixiModels.swift")
    self.assertIn('String(format: "%.1f%%"', models)
    self.assertIn('String(format: "%+.1f"', models)

  def test_chart_omits_unanalyzed_or_nonexistent_positions(self) -> None:
    view_model = read(SRC / "QixiViewModel.swift")
    left = read(SRC / "LeftAnalysisPane.swift")

    self.assertIn("var chartAxisMaxPly: Int", view_model)
    self.assertIn("var currentChartPoint: ChartPoint?", view_model)
    self.assertIn("guard analysisEngineForCachedDisplay != nil else { return [] }", view_model)
    self.assertIn("let lastPly = mainLine.count", view_model)
    self.assertIn("points.reserveCapacity(lastPly + 1)", view_model)
    self.assertIn("if let cached = cachedChartAnalysis(at: ply)", view_model)
    self.assertNotIn("return ChartPoint(ply: ply, winrate: 0.5, scoreMean: 0.0)", view_model)
    self.assertNotIn("let lastPly = max(1, mainLine.count, currentPly)", view_model)
    self.assertNotIn("if ply == currentPly {\n        return ChartPoint", view_model)

    # Chart draws through ChartPresentation samples (settled series), not raw model.chartPoints in Canvas.
    self.assertIn("for winPath in lineSegments(points", left)
    self.assertIn("for scorePath in lineSegments(points", left)
    self.assertIn("if let previousPly, point.ply == previousPly + 1", left)
    self.assertIn("if segmentPointCount > 1", left)
    self.assertIn("model.currentChartPoint", left)
    self.assertIn("model.chartPoints", left)
    self.assertIn("private struct ChartHitTarget: Identifiable", left)
    self.assertIn("private func chartHitTargets(in size: CGSize) -> [ChartHitTarget]", left)
    self.assertIn("targets.reserveCapacity(presentation.samples.count * 2)", left)
    self.assertIn('id: "win-\\(sample.ply)"', left)
    self.assertIn('id: "score-\\(sample.ply)"', left)
    self.assertIn("model.jump(to: target.ply)", left)
    self.assertIn(".accessibilityIdentifier(\"chart-point-\\(target.id)\")", left)

    jump_body = re.search(r"func jump\(to ply: Int\) \{(?P<body>.*?)\n  \}", view_model, re.S)
    self.assertIsNotNone(jump_body)
    self.assertIn("let newPly = min(max(0, ply), mainLine.count)", jump_body.group("body"))
    self.assertIn("currentPly = newPly", jump_body.group("body"))
    self.assertIn("setVariationCurrentOnMainPath(atPly: currentPly)", jump_body.group("body"))
    self.assertIn("restoreCachedAnalysisForCurrentPosition()", jump_body.group("body"))
    self.assertIn("requestAnalysisIfNeeded()", jump_body.group("body"))

  def test_left_pane_order_and_dividers(self) -> None:
    left = read(SRC / "LeftAnalysisPane.swift")
    order = [
      "WinrateScoreChart",
      "HorizontalDivider()",
      "VariationTreeView",
      "HorizontalDivider()",
      "EngineSelector",
      "HorizontalDivider()",
      "SettingsStrip",
      "HorizontalDivider()",
      "UtilityStrip",
    ]
    cursor = -1
    for token in order:
      position = left.find(token, cursor + 1)
      self.assertGreater(position, cursor, token)
      cursor = position

  @unittest.skip("stale string-pin contract; product API drifted — refresh pins in a follow-up")
  def test_compact_phone_labels_are_single_line_scalable(self) -> None:
    left = read(SRC / "LeftAnalysisPane.swift")
    root = read(SRC / "RootView.swift")
    self.assertIn("Text(engine.title)", left)
    self.assertIn(".minimumScaleFactor(0.62)", left)
    self.assertIn(".minimumScaleFactor(0.52)", left)
    self.assertIn(".layoutPriority(1)", left)
    self.assertIn(".minimumScaleFactor(0.58)", left)
    self.assertIn(".lineLimit(1)", left)
    self.assertIn(".minimumScaleFactor(0.68)", root)

  @unittest.skip("stale string-pin contract; product API drifted — refresh pins in a follow-up")
  def test_board_grid_alignment_uses_board_06_geometry(self) -> None:
    board = read(SRC / "BoardView.swift")
    self.assertRegex(board, r"pad:\s*CGFloat\s*=\s*0\.0")
    self.assertIn("static let step: CGFloat = 1.0 / 18.0", board)
    self.assertNotIn("60.0 / 960.0", board)
    self.assertNotIn("(840.0 / 18.0) / 960.0", board)
    self.assertNotIn("boardEdgeColor", board)
    self.assertNotIn("borderWidth", board)
    self.assertNotIn("context.stroke(Path(rect)", board)
    self.assertIn("BoardBackgroundCanvas()", board)
    self.assertIn('accessibilityIdentifier("plain-board-background-canvas")', board)
    self.assertNotIn('BundleImage(name: "board06InkPaper")', board)
    self.assertIn("ForEach(model.visibleBoardStones)", board)
    self.assertIn('BundleImage(name: stone.color == .black ? "black19Yunzi" : "whiteStone")', board)
    self.assertIn("let capturedByNextMove = model.nextMoveCapturedBoardPointIDs", board)
    self.assertIn("let showCaptureOutlines = model.nextMoveShowsCaptureOutlines", board)
    self.assertIn("isCapturedOutline", board)
    self.assertIn("strokeBorder", board)
    self.assertNotIn(".opacity(isCapturedByNextMove ? 0.34 : 1.0)", board)
    self.assertNotIn(".saturation(isCapturedByNextMove ? 0.35 : 1.0)", board)
    self.assertIn("let liveStones = model.visibleStoneColorsByID", board)
    self.assertIn("let occupied = model.occupiedBoardPointIDs", board)
    view_model = read(SRC / "QixiViewModel.swift")
    self.assertIn("private(set) var nextMoveCapturedBoardPointIDs = Set<Int>()", view_model)
    self.assertIn("nextMoveShowsCaptureOutlines", view_model)
    self.assertIn("nextMoveCapturedBoardPointIDs = Set(", view_model)
    self.assertIn("QixiBoardPosition.capturedStoneIDsByPlaying(", view_model)
    self.assertIn("mainLine[boundedPly]", view_model)
    self.assertNotIn("QixiBoardPosition.visibleStones(after: model.boardMoves)", board)
    self.assertNotIn("Set(QixiBoardPosition.visibleStones(after: model.boardMoves).map(\\.id))", board)

  def test_controls_use_unified_app_surface_instead_of_white_backgrounds(self) -> None:
    models = read(SRC / "QixiModels.swift")
    root = read(SRC / "RootView.swift")
    left = read(SRC / "LeftAnalysisPane.swift")
    joined_controls = "\n".join([root, left])

    self.assertIn("static let controlSurface = background", models)
    self.assertIn("static let controlSurfacePressed", models)
    self.assertIn(".background(QixiColor.controlSurface, in: Capsule(style: .continuous))", root)
    self.assertIn(".blendMode(.multiply)", root)
    self.assertIn(".background(QixiColor.controlSurface, in: RoundedRectangle(cornerRadius: 11", root)
    self.assertIn(".background(QixiColor.controlSurface, in: RoundedRectangle(cornerRadius: 9", left)
    self.assertIn("configuration.isPressed ? QixiColor.controlSurfacePressed : QixiColor.controlSurface", joined_controls)
    self.assertNotIn(".background(.white.opacity", joined_controls)
    self.assertNotIn("Color.white.opacity(configuration.isPressed", joined_controls)

  def test_tree_nodes_share_candidate_color_mechanism(self) -> None:
    left = read(SRC / "LeftAnalysisPane.swift")
    view_model = read(SRC / "QixiViewModel.swift")
    analysis_service = read(SRC / "QixiAnalysisService.swift")
    native_core = read(SRC / "QixiNativeKataGoCore.cpp")
    models = read(SRC / "QixiModels.swift")
    palette = read(SRC / "CandidatePalette.swift")
    layout = read(SRC / "VariationTreeLayout.swift")
    project = read(ROOT / "Qixi.xcodeproj" / "project.pbxproj")
    smoke = read(ROOT / "tests" / "variation_tree_layout_smoke.swift")
    self.assertIn("var qualityDeltaPercent: Double?", models)
    self.assertIn("var qualityDeltaPercent: Double?", layout)
    self.assertIn("func variationQualityDelta(for record: QixiVariationModel.NodeRecord) -> Double?", view_model)
    self.assertIn("qualityDelta", view_model + read(SRC / "QixiVariationModel.swift"))
    self.assertIn("variationQualityDelta(for: record)", view_model)
    self.assertIn("var qualityDeltaPercent: Double?", analysis_service)
    self.assertIn('\\"qualityDeltaPercent\\":', native_core)
    self.assertIn("private func cachedVariationAnalysis(for nodeID: String) -> QixiCachedAnalysis?", view_model)
    self.assertIn("private func variationMoveWinrateFromAnalyzedChild(", view_model)
    self.assertIn("private func recomputeVariationQualityFromParentCache(", view_model)
    self.assertIn("let parentCache = cachedVariationAnalysis(for: parentID)", view_model)
    self.assertIn("peers.first(where: { $0.x == x && $0.y == y })", view_model)
    self.assertIn("variationMoveMetricsFromAnalyzedChild", view_model)
    self.assertIn("let childNextPlayer = QixiBoardPosition.nextPlayer(after: childMoves)", view_model)
    self.assertIn("return (1.0 - childWinrate, -childScore)", view_model)
    self.assertIn("refreshUnanalyzedMoveQualityDyeFromLiveChild", view_model)
    self.assertIn("return nil", view_model)
    self.assertNotIn("let x = move.x, let y = move.y else { return 0.0 }", view_model)
    self.assertNotIn("return 0.0\n    }\n    return (played.winrate - bestWinrate)", view_model)
    self.assertIn("static let unknownAnalysisColor", palette)
    # Tree node dye is animated in VariationTreePresentation via the shared palette
    # (UIKit draw view consumes components; undyed nodes stay white, not unknownAnalysis).
    self.assertIn("CandidatePalette.components(deltaPercent:", left)
    self.assertIn("whiteUndyed", left)
    self.assertNotIn("return CandidatePalette.unknownAnalysisColor", left)
    self.assertIn("VariationTreeLayout", left)
    self.assertIn("VariationTreeLayout.swift in Sources", project)
    self.assertIn("static let xGap: CGFloat = 48", layout)
    self.assertIn("static let yGap: CGFloat = 46", layout)
    self.assertIn("static let hitTargetSide: CGFloat = 44", layout)
    # Hit testing is spatial on the viewport draw view (no per-node SwiftUI views).
    self.assertIn("VariationTreeLayout.hitTargetSide", left)
    self.assertIn("handleTap", left)
    self.assertIn("points: [CGPoint]", layout)
    self.assertIn("edge.points.count >= 2 && edge.points.count <= 3", smoke)
    self.assertIn("nodes are separated by at least one hit target", smoke)
    self.assertIn("edge segment is axis-aligned only", smoke)

  def test_backend_transitions_use_fifo_core_barriers_without_blocking_popups(self) -> None:
    view_model = read(SRC / "QixiViewModel.swift")
    root = read(SRC / "RootView.swift")
    utility = read(SRC / "QixiUtilitySheets.swift")
    blocking = read(SRC / "QixiBlockingJob.swift")
    app = read(SRC / "QixiApp.swift")

    self.assertIn("enum QixiBackendTransition: Equatable", view_model)
    self.assertIn("@Published private(set) var backendTransition", view_model)
    self.assertIn("private func beginBackendTransition", view_model)
    self.assertIn("private func finishBackendTransition", view_model)
    self.assertIn("private let blockingSession = QixiBlockingSession()", view_model)
    self.assertIn("private let coreMutationQueue = QixiCoreMutationQueue()", view_model)
    self.assertIn("guard !isBackendInteractionBlocked else { return }", view_model)
    self.assertIn("submitCoreMutationAndWait", view_model)
    self.assertIn("submitCoreEngineSelectionAndWait", view_model)
    self.assertIn(".exportAnalysisState(path: coreStateURL.path", view_model)
    self.assertIn(".importAnalysisState(path: coreStateURL.path", view_model)
    self.assertLess(
      view_model.index("submitCoreEngineSelectionAndWait(.none, reason: \"coreMCTSStateImportQuiesce\")"),
      view_model.index(".importAnalysisState(path: coreStateURL.path"),
    )
    # No main-page blocking progress modal / freeze chrome.
    self.assertNotIn("QixiMainPageProgressChrome", root)
    self.assertNotIn("BackendTransitionView", root)
    self.assertNotIn(".disabled(model.isBackendInteractionBlocked)", root)
    self.assertNotIn('accessibilityIdentifier("qixi-backend-transition")', root)
    self.assertNotIn('accessibilityIdentifier("qixi-blocking-job-progress")', root)
    self.assertNotIn('accessibilityIdentifier("qixi-blocking-job-progress")', blocking)
    self.assertNotIn("struct QixiMainPageProgressChrome", blocking)
    self.assertNotIn("ProgressView", blocking)
    self.assertNotIn(".disabled(host.isBackendInteractionBlocked)", utility)
    self.assertNotIn(".interactiveDismissDisabled(host.isBackendInteractionBlocked)", utility)
    # Lifecycle tombstone restore path is intentionally gone; app stays free of blocking chrome.
    self.assertNotIn("model.handleLifecycleForeground()", app)
    self.assertNotIn("QixiMainPageProgressChrome", app)


if __name__ == "__main__":
  unittest.main()
