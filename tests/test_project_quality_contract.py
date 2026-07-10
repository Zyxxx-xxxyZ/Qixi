#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import datetime
import pathlib
import plistlib
import re
import os
import json
import shutil
import struct
import subprocess
import tempfile
import unittest
import zlib


ROOT = pathlib.Path(__file__).resolve().parents[1]


def hermetic_qixi_env(**overrides: str) -> dict[str, str]:
  env = {
    key: value
    for key, value in os.environ.items()
    if not (key.startswith("QIXI_") or key.startswith("SIMCTL_CHILD_QIXI_"))
  }
  env.update(overrides)
  return env


def read(path: pathlib.Path) -> str:
  return path.read_text(encoding="utf-8")


def png_with_dimensions(width: int, height: int) -> bytes:
  def chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)

  background = 0xE2
  grid_color = 0x28
  star_color = 0x18
  grid_margin_x = max(20, width // 12)
  grid_margin_y = max(20, height // 12)
  grid_span_x = max(1, width - 2 * grid_margin_x)
  grid_span_y = max(1, height - 2 * grid_margin_y)
  verticals = {
    round(grid_margin_x + grid_span_x * index / 18)
    for index in range(19)
  }
  horizontals = {
    round(grid_margin_y + grid_span_y * index / 18)
    for index in range(19)
  }
  star_points = {
    (
      round(grid_margin_x + grid_span_x * x / 18),
      round(grid_margin_y + grid_span_y * y / 18),
    )
    for x in (3, 9, 15)
    for y in (3, 9, 15)
  }
  rows: list[bytes] = []
  for y in range(height):
    row = bytearray()
    for x in range(width):
      value = background
      if x in verticals or y in horizontals:
        value = grid_color
      if any((x - sx) ** 2 + (y - sy) ** 2 <= 16 for sx, sy in star_points):
        value = star_color
      row.append(value)
    rows.append(b"\x00" + bytes(row))
  scanlines = b"".join(rows)
  return (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(scanlines, level=1))
    + chunk(b"IEND", b"")
  )


def artifact_metadata(path: pathlib.Path) -> dict[str, object]:
  return {
    "byteCount": path.stat().st_size,
    "sha256HexDigest": hashlib.sha256(path.read_bytes()).hexdigest(),
  }


def write_sparse_file(path: pathlib.Path, byte_count: int) -> None:
  with path.open("wb") as handle:
    handle.seek(byte_count - 1)
    handle.write(b"\0")


def write_minimal_native_model_preflight_root(root: pathlib.Path, registry_source: str | None = None) -> None:
  qixi_dir = root / "qixi-ios-native" / "Qixi"
  qixi_dir.mkdir(parents=True)
  (root / "qixi-ios-native" / "Qixi.xcodeproj").mkdir(parents=True)
  (root / "docs").mkdir()
  (root / "KataGo" / "cpp" / "tests" / "models").mkdir(parents=True)
  registry = registry_source or """
enum QixiNativeModelRegistry {
  static func spec(for engine: AnalysisEngine) -> NativeKataGoModelSpec? {
    switch engine {
    case .b6:
      return NativeKataGoModelSpec(
        engine: engine,
        resourceName: "g170-b6c96-s175395328-d26788732.bin.gz",
        expectedByteCount: 3827339,
        sha256HexDigest: "f5d32604e3675c480c7c8f6aa579a1ea857135628a0afccc8fa56330fbacd38d",
        minimumMemoryMB: 256,
        recommendedMemoryMB: 512,
        maximumMemoryMB: 768
      )
    default:
      return nil
    }
  }
}
"""
  (qixi_dir / "QixiNativeModelRegistry.swift").write_text(registry, encoding="utf-8")
  for filename in (
    "QixiNativeModelIntegrity.swift",
    "QixiNativeModelInstaller.swift",
    "QixiNativeModelInstallReceipt.swift",
  ):
    (qixi_dir / filename).write_text("// minimal test fixture\n", encoding="utf-8")
  (root / "qixi-ios-native" / "Qixi.xcodeproj" / "project.pbxproj").write_text(
    "// minimal test fixture\n",
    encoding="utf-8",
  )
  (root / "docs" / "native-katago-integration.md").write_text(
    "g170-b6c96-s175395328-d26788732.bin.gz\n",
    encoding="utf-8",
  )


def write_minimal_appstore_preflight_root(root: pathlib.Path) -> None:
  qixi_dir = root / "qixi-ios-native" / "Qixi"
  project_dir = root / "qixi-ios-native" / "Qixi.xcodeproj"
  qixi_dir.mkdir(parents=True)
  project_dir.mkdir(parents=True)
  (project_dir / "project.pbxproj").write_text(
    """
PrivacyInfo.xcprivacy in Resources
PrivacyInfo.xcprivacy
TARGETED_DEVICE_FAMILY = "1,2";
SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
SUPPORTS_MACCATALYST = NO;
SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;
MARKETING_VERSION = 1.0;
CURRENT_PROJECT_VERSION = 1;
QIXI_ENABLE_NATIVE_KATAGO=1
100000000000000000000B01 /* Debug */ = {
  isa = XCBuildConfiguration;
  buildSettings = {
    PRODUCT_NAME = "$(TARGET_NAME)";
    SWIFT_OBJC_BRIDGING_HEADER = "Qixi/Qixi-Bridging-Header.h";
  };
  name = Debug;
};
100000000000000000000B02 /* Release */ = {
  isa = XCBuildConfiguration;
  buildSettings = {
    PRODUCT_NAME = "$(TARGET_NAME)";
    SWIFT_OBJC_BRIDGING_HEADER = "Qixi/Qixi-Bridging-Header.h";
  };
  name = Release;
};
100000000000000000000B03 /* NativeRelease */ = {
  isa = XCBuildConfiguration;
  buildSettings = {
    PRODUCT_NAME = "$(TARGET_NAME)";
    SWIFT_OBJC_BRIDGING_HEADER = "Qixi/Qixi-Bridging-Header.h";
    SWIFT_ACTIVE_COMPILATION_CONDITIONS = QIXI_NATIVE_RELEASE;
    OTHER_SWIFT_FLAGS = (
      "$(inherited)",
      "-D",
      QIXI_NATIVE_RELEASE,
    );
    EXCLUDED_SOURCE_FILE_NAMES = (
      BackendClient.swift,
      QixiHTTPBridgeAnalysisService.swift,
    );
  };
  name = NativeRelease;
};
""",
    encoding="utf-8",
  )
  info: dict[str, object] = {
    "CFBundleDisplayName": "Qixi",
    "NSCameraUsageDescription": "Camera access is used to recognize a Go board.",
    "NSPhotoLibraryUsageDescription": "Photo access is used to import a Go board image.",
    "NSLocalNetworkUsageDescription": "Local network access is used for development backend smoke tests.",
    "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "ITSAppUsesNonExemptEncryption": False,
    "LSRequiresIPhoneOS": True,
    "UIRequiresFullScreen": True,
    "CADisableMinimumFrameDurationOnPhone": True,
    "UISupportedInterfaceOrientations": [
      "UIInterfaceOrientationLandscapeLeft",
      "UIInterfaceOrientationLandscapeRight",
    ],
    "UISupportedInterfaceOrientations~ipad": [
      "UIInterfaceOrientationLandscapeLeft",
      "UIInterfaceOrientationLandscapeRight",
    ],
    "QixiAnalysisRuntime": "httpBridge",
    "QixiBackendBaseURL": "http://127.0.0.1:8765",
  }
  with (qixi_dir / "Info.plist").open("wb") as plist_file:
    plistlib.dump(info, plist_file)
  native_release_info = dict(info)
  native_release_info["QixiAnalysisRuntime"] = "nativeInProcess"
  native_release_info.pop("QixiBackendBaseURL", None)
  with (qixi_dir / "NativeReleaseInfo.plist").open("wb") as plist_file:
    plistlib.dump(native_release_info, plist_file)
  entitlements = {
    "com.apple.developer.icloud-container-identifiers": ["iCloud.com.qixi.localanalysis"],
    "com.apple.developer.ubiquity-container-identifiers": ["iCloud.com.qixi.localanalysis"],
    "com.apple.developer.icloud-services": ["CloudDocuments"],
  }
  with (qixi_dir / "Qixi.entitlements").open("wb") as plist_file:
    plistlib.dump(entitlements, plist_file)
  privacy = {
    "NSPrivacyTracking": False,
    "NSPrivacyTrackingDomains": [],
    "NSPrivacyCollectedDataTypes": [],
    "NSPrivacyAccessedAPITypes": [
      {
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
        "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
      }
    ],
  }
  with (qixi_dir / "PrivacyInfo.xcprivacy").open("wb") as plist_file:
    plistlib.dump(privacy, plist_file)
  (qixi_dir / "QixiNativeKataGoEngine.cpp").write_text(
    """
#if QIXI_ENABLE_NATIVE_KATAGO
class LinkedNativeKataGoEngine final {};
#endif
#if !QIXI_ENABLE_NATIVE_KATAGO
class PlaceholderNativeKataGoEngine final {};
const char *diagnostic = "Native KataGo is not linked into this build.";
#endif
auto factory() {
#if QIXI_ENABLE_NATIVE_KATAGO
  return std::make_unique<LinkedNativeKataGoEngine>();
#else
  return std::make_unique<PlaceholderNativeKataGoEngine>();
#endif
}
""",
    encoding="utf-8",
  )
  (qixi_dir / "QixiApp.swift").write_text(
    "import Foundation\nlet defaults = UserDefaults.standard\n",
    encoding="utf-8",
  )


def refresh_artifact_metadata(artifacts: list[dict[str, object]], base_dir: pathlib.Path, kind: str) -> None:
  for artifact in artifacts:
    if artifact["kind"] == kind:
      artifact.update(artifact_metadata(base_dir / str(artifact["path"])))
      return
  raise AssertionError(f"missing artifact kind {kind}")


def isoformat_z(value: datetime.datetime) -> str:
  return value.astimezone(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def minimal_arm64_macho_execute(platform: int = 2, filetype: int = 2, cputype: int = 0x0100000C) -> bytes:
  build_version_command_size = 24
  header = struct.pack(
    "<IiiIIIII",
    0xFEEDFACF,
    cputype,
    0,
    filetype,
    1,
    build_version_command_size,
    0,
    0,
  )
  build_version = struct.pack(
    "<IIIIII",
    0x32,
    build_version_command_size,
    platform,
    17 << 16,
    26 << 16,
    0,
  )
  return header + build_version


def compile_and_sign_minimal_ios_app(app: pathlib.Path, scratch_dir: pathlib.Path) -> None:
  source = scratch_dir / "qixi_minimal_main.c"
  source.write_text(
    "int main(int argc, char **argv) { return argc > 0 ? 0 : 1; }\n",
    encoding="utf-8",
  )
  executable = app / "Qixi"
  subprocess.run(
    [
      "xcrun",
      "--sdk",
      "iphoneos",
      "clang",
      "-target",
      "arm64-apple-ios17.0",
      "-miphoneos-version-min=17.0",
      str(source),
      "-o",
      str(executable),
    ],
    cwd=ROOT,
    text=True,
    capture_output=True,
    check=True,
  )
  executable.chmod(0o755)
  subprocess.run(
    ["codesign", "--force", "--sign", "-", "--entitlements", str(write_minimal_archive_entitlements(scratch_dir)), str(app)],
    cwd=ROOT,
    text=True,
    capture_output=True,
    check=True,
  )


def write_minimal_archive_entitlements(directory: pathlib.Path, include_icloud: bool = True) -> pathlib.Path:
  entitlements: dict[str, object] = {
    "application-identifier": "QIXI123456.com.qixi.localanalysis",
    "com.apple.developer.team-identifier": "QIXI123456",
    "get-task-allow": False,
  }
  if include_icloud:
    entitlements.update(
      {
        "com.apple.developer.icloud-container-identifiers": ["iCloud.com.qixi.localanalysis"],
        "com.apple.developer.ubiquity-container-identifiers": ["iCloud.com.qixi.localanalysis"],
        "com.apple.developer.icloud-services": ["CloudDocuments"],
      }
    )
  entitlement_path = directory / "Qixi.entitlements"
  with entitlement_path.open("wb") as plist_file:
    plistlib.dump(entitlements, plist_file)
  return entitlement_path


def write_minimal_appstore_archive(directory: pathlib.Path) -> pathlib.Path:
  archive = directory / "Qixi.xcarchive"
  app = archive / "Products" / "Applications" / "Qixi.app"
  app.mkdir(parents=True)
  with (archive / "Info.plist").open("wb") as plist_file:
    plistlib.dump(
      {
        "ArchiveVersion": 2,
        "ApplicationProperties": {
          "ApplicationPath": "Applications/Qixi.app",
          "CFBundleIdentifier": "com.qixi.localanalysis",
          "CFBundleShortVersionString": "1.0",
          "CFBundleVersion": "1",
          "SigningIdentity": "Apple Distribution: Qixi Test",
          "Team": "QIXI123456",
        },
        "CreationDate": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0),
        "Name": "Qixi",
        "SchemeName": "Qixi",
      },
      plist_file,
    )
  with (app / "Info.plist").open("wb") as plist_file:
    plistlib.dump(
      {
        "CADisableMinimumFrameDurationOnPhone": True,
        "CFBundleDisplayName": "棋析",
        "CFBundleIdentifier": "com.qixi.localanalysis",
        "CFBundleExecutable": "Qixi",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "CFBundleVersion": "1",
        "DTPlatformName": "iphoneos",
        "DTSDKName": "iphoneos26.0",
        "ITSAppUsesNonExemptEncryption": False,
        "LSRequiresIPhoneOS": True,
        "MinimumOSVersion": "17.0",
        "NSAppTransportSecurity": {
          "NSAllowsLocalNetworking": True,
        },
        "NSCameraUsageDescription": "Qixi uses the camera to recognize visible stones in Go board photos.",
        "NSLocalNetworkUsageDescription": "Qixi connects to the local analysis backend during development and device testing.",
        "NSPhotoLibraryUsageDescription": "Qixi imports Go board photos and SGF files selected by the user.",
        "UIRequiresFullScreen": True,
        "UIDeviceFamily": [1, 2],
        "QixiAnalysisRuntime": "nativeInProcess",
        "UISupportedInterfaceOrientations": [
          "UIInterfaceOrientationLandscapeLeft",
          "UIInterfaceOrientationLandscapeRight",
        ],
        "UISupportedInterfaceOrientations~ipad": [
          "UIInterfaceOrientationLandscapeLeft",
          "UIInterfaceOrientationLandscapeRight",
        ],
      },
      plist_file,
    )
  with (app / "PrivacyInfo.xcprivacy").open("wb") as plist_file:
    plistlib.dump(
      {
        "NSPrivacyAccessedAPITypes": [
          {
            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
            "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
          }
        ],
        "NSPrivacyCollectedDataTypes": [],
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
      },
      plist_file,
    )
  compile_and_sign_minimal_ios_app(app, directory)
  return archive


class ProjectQualityContractTests(unittest.TestCase):
  def test_quality_gate_runs_current_core_tests(self) -> None:
    script = read(ROOT / "scripts" / "qixi-quality-gate.sh")
    required = [
      "tests/test_project_quality_contract.py",
      "tests/test_quality_gate_skip_audit.py",
      "tests/test_changed_surface_gate.py",
      "tests/test_device_run_preflight.py",
      "tests/test_device_signing_doctor.py",
      "tests/test_device_bridge_smoke.py",
      "tests/test_device_bridge_smoke_inspector.py",
      "tests/test_position_identity_fixture_validator.py",
      "tests/test_repo_hygiene_preflight.py",
      "tests/test_real_device_evidence_preflight.py",
      "tests/test_real_device_evidence_template.py",
      "tests/test_real_device_run_kit_preflight.py",
      "tests/test_release_evidence_archive_match.py",
      "qixi-ios-sim/tests/test_backend_contract.py",
      "qixi-ios-sim/tests/test_real_model_artifact_inspector.py",
      "qixi-ios-sim/tests/ui_contract.mjs",
      "qixi-ios-native/tests/test_frontend_contract.py",
      "qixi-ios-native/tests/test_localization_contract.py",
      "qixi-ios-native/tests/test_protected_build_marker.py",
      "qixi-ios-native/tests/test_utility_sheet_screenshot_inspector.py",
      "qixi-ios-native/tests/test_screenshot_manifest_artifact_inspector.py",
      "qixi-ios-native/tests/test_screenshot_environment_inspector.py",
      "qixi-ios-native/tests/test_screenshot_review_board.py",
      "qixi-ios-native/tests/test_screenshot_coverage_manifest.py",
      "qixi-ios-native/tests/run_sgf_parser_smoke.sh",
      "qixi-ios-native/tests/run_board_legality_crosscheck.sh",
      "qixi-ios-native/tests/run_board_recognition_smoke.sh",
      "qixi-ios-native/tests/run_variation_tree_layout_smoke.sh",
      "qixi-ios-native/tests/run_analysis_service_smoke.sh",
      "scripts/qixi-native-inprocess-contract-preflight.sh",
      "qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh",
      "scripts/qixi-native-model-preflight.sh",
      "scripts/qixi-device-run-preflight.sh",
      "scripts/qixi-repo-hygiene-preflight.sh",
      "qixi-ios-native/tests/run_persistence_sync_smoke.sh",
      "scripts/qixi-appstore-preflight.sh",
      "qixi-ios-native/Qixi.xcodeproj",
      "quality_xcodebuild_path",
      "Quality gate native Xcode build requires xcodebuild to resolve to /usr/bin/xcodebuild",
      "do not shadow xcodebuild in PATH",
      "run_step \"native Xcode build\" \"$xcodebuild_bin\"",
      "QIXI_RUN_SCREENSHOT_SMOKE",
      "qixi-ios-native/scripts/screenshot-environment-doctor.sh",
      'screenshot_environment_artifact="${QIXI_SCREENSHOT_DOCTOR_ARTIFACT:-qixi-ios-native/artifacts/screenshots/screenshot-environment.json}"',
      "QIXI_SCREENSHOT_ENVIRONMENT_MIN_MTIME_EPOCH",
      'qixi-ios-native/tests/inspect_screenshot_environment.py "$screenshot_environment_artifact"',
      "qixi-ios-native/scripts/screenshot-smoke-sim.sh",
      "QIXI_RUN_SCREENSHOTS",
      "qixi-ios-native/scripts/screenshot-onboarding-all-locales.sh",
      "qixi-ios-native/scripts/screenshot-all-locales.sh",
      "qixi-ios-native/scripts/screenshot-iphone-all-locales.sh",
      "qixi-ios-native/scripts/screenshot-utility-sheets.sh",
      "qixi-ios-native/scripts/screenshot-iphone-utility-sheets.sh",
      "qixi-ios-native/scripts/persistence-smoke-sim.sh",
      "qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh",
      "qixi-ios-native/scripts/performance-smoke-sim.sh",
      "qixi-ios-native/scripts/build_screenshot_review_board.py",
      "qixi-ios-native/tests/inspect_screenshot_review_board.py",
      "QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH",
      "QIXI_RUN_IOS_KATAGO_CMAKE",
      "scripts/qixi-ios-katago-cmake-preflight.sh",
      "QIXI_IOS_SDK=iphoneos",
      "QIXI_RUN_NATIVE_RELEASE_SIM",
      "QIXI_RUN_DEVICE_BRIDGE_PLAN",
      "QIXI_DEVICE_BRIDGE_PLAN_ONLY=1",
      "scripts/qixi-device-bridge-plan-inspect.sh",
      "QIXI_RUN_DEVICE_BRIDGE_SMOKE",
      "QIXI_RUN_DEVICE_BRIDGE_FAILURE_INSPECT",
      "QIXI_DEVICE_BRIDGE_FAILURE_ARTIFACT",
      "scripts/qixi-device-bridge-failure-inspect.sh",
      "qixi-ios-native/scripts/native-release-sim-smoke.sh",
      "QIXI_RUN_REAL_MODELS",
      "qixi-ios-sim/tests/integration_real_b6.py",
      "qixi-ios-sim/tests/integration_all_models.py",
    ]
    for token in required:
      self.assertIn(token, script)
    self.assertLess(
      script.index("qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh"),
      script.index("qixi-ios-native/tests/inspect_screenshot_manifest_artifacts.py"),
    )
    self.assertLess(
      script.index("qixi-ios-native/scripts/persistence-smoke-sim.sh"),
      script.index("qixi-ios-native/tests/inspect_screenshot_manifest_artifacts.py"),
    )
    self.assertLess(
      script.index("qixi-ios-native/scripts/performance-smoke-sim.sh"),
      script.index("qixi-ios-native/tests/inspect_screenshot_manifest_artifacts.py"),
    )
    self.assertLess(
      script.index("qixi-ios-native/tests/inspect_screenshot_manifest_artifacts.py"),
      script.index("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH"),
    )
    self.assertLess(
      script.index("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH"),
      script.index("qixi-ios-native/scripts/build_screenshot_review_board.py"),
    )
    self.assertLess(
      script.index("qixi-ios-native/scripts/build_screenshot_review_board.py"),
      script.index("qixi-ios-native/tests/inspect_screenshot_review_board.py"),
    )
    self.assertLess(
      script.index("qixi-ios-native/scripts/screenshot-environment-doctor.sh"),
      script.index("qixi-ios-native/tests/inspect_screenshot_environment.py"),
    )
    self.assertLess(
      script.index("qixi-ios-native/tests/inspect_screenshot_environment.py"),
      script.index("qixi-ios-native/scripts/screenshot-smoke-sim.sh"),
    )
    self.assertLess(
      script.index("qixi-ios-native/tests/inspect_screenshot_environment.py"),
      script.index("qixi-ios-native/scripts/screenshot-onboarding-all-locales.sh"),
    )
    for path in (
      ROOT / "qixi-ios-native" / "tests" / "test_screenshot_coverage_manifest.py",
      ROOT / "qixi-ios-native" / "tests" / "inspect_screenshot_manifest_artifacts.py",
      ROOT / "qixi-ios-native" / "tests" / "test_localization_contract.py",
    ):
      self.assertIn("screenshot_manifest_json", read(path))
    artifact_inspector = read(ROOT / "qixi-ios-native" / "tests" / "inspect_screenshot_manifest_artifacts.py")
    artifact_inspector_tests = read(ROOT / "qixi-ios-native" / "tests" / "test_screenshot_manifest_artifact_inspector.py")
    environment_inspector = read(ROOT / "qixi-ios-native" / "tests" / "inspect_screenshot_environment.py")
    environment_inspector_tests = read(ROOT / "qixi-ios-native" / "tests" / "test_screenshot_environment_inspector.py")
    environment_doctor = read(ROOT / "qixi-ios-native" / "scripts" / "screenshot-environment-doctor.sh")
    manifest_json = read(ROOT / "qixi-ios-native" / "tests" / "screenshot_manifest_json.py")
    protected_marker = read(ROOT / "qixi-ios-native" / "scripts" / "protected_build_marker.py")
    protected_marker_tests = read(ROOT / "qixi-ios-native" / "tests" / "test_protected_build_marker.py")
    run_native_sim = read(ROOT / "qixi-ios-native" / "scripts" / "run-native-sim.sh")
    review_board = read(ROOT / "qixi-ios-native" / "scripts" / "build_screenshot_review_board.py")
    review_board_inspector = read(ROOT / "qixi-ios-native" / "tests" / "inspect_screenshot_review_board.py")
    review_board_tests = read(ROOT / "qixi-ios-native" / "tests" / "test_screenshot_review_board.py")
    screenshot_sim = read(ROOT / "qixi-ios-native" / "scripts" / "screenshot-sim.sh")
    screenshot_smoke = read(ROOT / "qixi-ios-native" / "scripts" / "screenshot-smoke-sim.sh")
    performance_smoke = read(ROOT / "qixi-ios-native" / "scripts" / "performance-smoke-sim.sh")
    for token in (
      "inspect_declared_scripts",
      "inspect_declared_inspector",
      "declared_screenshot_path",
      "missing screenshot script",
      "screenshot script is not a file",
      "screenshot script is not executable",
      "screenshot artifact must not be a symbolic link",
      "inspect_png_header",
      "inspect_png_decodes",
      "PNG_HEADER_BYTES",
      "SCREENSHOT_ARTIFACT_MAX_BYTES",
      "SCREENSHOT_MAX_PIXELS",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "handle.read(SCREENSHOT_ARTIFACT_MAX_BYTES + 1)",
      "opened-byte-count drift while reading",
      "Image.open(io.BytesIO(image_data))",
      "screenshot artifact must be a PNG file",
      "screenshot artifact must have a valid PNG IHDR",
      "screenshot artifact must be a decodable PNG image",
      "decoded dimensions do not match PNG IHDR",
      "too large for bounded visual inspection",
      "inspector must not be a symbolic link",
      "required_prefix",
      "required_suffix",
    ):
      self.assertIn(token, artifact_inspector)
    for token in (
      "DriftHandle",
      "test_manifest_artifact_inspector_rejects_screenshot_byte_count_drift",
      "opened-byte-count drift while reading",
      "test_manifest_artifact_inspector_decodes_same_bounded_bytes",
      "self.assertIsInstance(opened_from[0], io.BytesIO)",
    ):
      self.assertIn(token, artifact_inspector_tests)
    for token in (
      "MAX_ENVIRONMENT_ARTIFACT_BYTES",
      "GENERATED_AT_MAX_FUTURE_SKEW_SECONDS",
      "ALLOWED_PLATFORM_SYMLINK_ALIASES",
      "DOCTOR_ARTIFACT_ENV",
      "default_artifact_path",
      "QIXI_SCREENSHOT_DOCTOR_ARTIFACT",
      "QIXI_SCREENSHOT_ENVIRONMENT_MIN_MTIME_EPOCH",
      "normalized_path",
      "is_allowed_platform_symlink_alias",
      "reject_symlink_components",
      "inspect_generated_at",
      "generatedAt must be a UTC ISO-8601 timestamp ending in Z",
      "stale screenshot environment generatedAt",
      "too far in the future",
      "reject_duplicate_keys",
      "reject_non_standard_constant",
      "path.is_symlink()",
      "path.is_file()",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "byte-count drift after opening",
      "byte-count drift while reading",
      "SIMULATOR_UDID_RE",
      "EXPECTED_COMMANDS",
      "selected.{kind}",
      'inspect_selected_device("iPad"',
      'inspect_selected_device("iPhone"',
      "selected.{kind}.state must be Booted when bootSimulators is true",
      "Simulator evidence covers SwiftUI layout",
      "Real ProMotion, Metal/GPU/ANE, camera, iCloud propagation, background kill, and native in-process KataGo still require physical-device evidence.",
    ):
      self.assertIn(token, environment_inspector)
    for token in (
      "write_artifact_atomically",
      "prepare_artifact_target",
      "canonicalize_allowed_platform_alias_prefix",
      "ALLOWED_PLATFORM_SYMLINK_ALIASES",
      "reject_symlink_components",
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
    ):
      self.assertIn(token, environment_doctor)
    self.assertNotIn("artifact_path.write_text", environment_doctor)
    self.assertNotIn('mkdir -p "$(dirname "$ARTIFACT_PATH")"', environment_doctor)
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
    for token in (
      "protected_build_marker.py",
      "Native simulator build marker",
      "expected_target=\"/private/var\"",
      "expected_target=\"/private/tmp\"",
      "expected_target=\"/private/etc\"",
    ):
      self.assertIn(token, run_native_sim)
    self.assertNotIn(': > "$BUILD_MARKER"', run_native_sim)
    self.assertNotIn('touch "$BUILD_MARKER"', run_native_sim)
    for token in (
      "prepare_output_artifact",
      "temporary_output_path",
      "expected_target=\"/private/var\"",
      "expected_target=\"/private/tmp\"",
      "expected_target=\"/private/etc\"",
      "RAW_CAPTURE_PATH",
      "CROPPED_CAPTURE_PATH",
      "raw screenshot artifact",
      "cropped screenshot artifact",
      "os.replace(tmp_path, target)",
      "os.replace(tmp_path, metrics_path)",
      "os.O_NOFOLLOW",
      "os.fstat(fd)",
      "metrics artifact byte count drift after writing",
      "os.fsync(parent_fd)",
    ):
      self.assertIn(token, screenshot_sim)
    self.assertNotIn('mkdir -p "$(dirname "$SCREENSHOT_PATH")"', screenshot_sim)
    self.assertNotIn("metrics_path.write_text", screenshot_sim)
    self.assertIn("protected_build_marker.py", screenshot_sim)
    self.assertIn("Simulator screenshot build marker", screenshot_sim)
    self.assertNotIn(': > "$BUILD_MARKER"', screenshot_sim)
    self.assertNotIn('touch "$BUILD_MARKER"', screenshot_sim)
    self.assertIn("screenshot-sim.sh", screenshot_smoke)
    self.assertIn("screenshot-iphone-sim.sh", screenshot_smoke)
    self.assertIn("performance-smoke-sim.sh", screenshot_smoke)
    self.assertNotIn('mkdir -p "$SCREENSHOT_DIR"', screenshot_smoke)
    for token in (
      "reject_symlink_components",
      "prepare_output_artifact",
      "expected_target=\"/private/var\"",
      "expected_target=\"/private/tmp\"",
      "expected_target=\"/private/etc\"",
      "Simulator performance $label target must not be a symbolic link",
      "os.O_NOFOLLOW",
      "os.fstat(fd)",
      "metrics artifact byte count drift after writing",
      "os.replace(tmp_path, metrics_path)",
      "os.fsync(parent_fd)",
    ):
      self.assertIn(token, performance_smoke)
    self.assertNotIn("metrics_path.write_text", performance_smoke)
    for token in (
      "test_accepts_valid_screenshot_environment_artifact",
      "test_default_artifact_path_uses_doctor_artifact_env",
      "test_rejects_ambiguous_or_non_standard_json",
      "test_rejects_unsafe_or_oversized_artifact_files",
      "test_rejects_symlink_path_components_but_allows_platform_aliases",
      "test_rejects_stale_environment_artifact",
      "test_rejects_stale_generated_at_even_when_file_mtime_is_fresh",
      "test_rejects_generated_at_too_far_in_the_future",
      "test_rejects_command_drift",
      "test_rejects_selected_simulator_shape_errors",
      "test_rejects_missing_real_device_caveat",
    ):
      self.assertIn(token, environment_inspector_tests)
    for token in (
      "MAX_SCREENSHOT_MANIFEST_BYTES",
      "validate_manifest_structure",
      "validate_manifest_relative_path",
      "path.is_symlink()",
      "path.is_file()",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "handle.read(MAX_SCREENSHOT_MANIFEST_BYTES + 1)",
      "raw_path.split(\"/\")",
      "must not contain empty, current-directory, or parent-directory components",
    ):
      self.assertIn(token, manifest_json)
    for token in (
      "MAX_REVIEW_HTML_BYTES",
      "read_bounded_utf8",
      "opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "handle.read(max_bytes + 1)",
      "opened-byte-count drift while reading",
      "opened-byte-count drift while hashing",
      "MAX_SCREENSHOT_MANIFEST_BYTES",
      "review-board {label} is empty",
      "review-board {label} exceeds",
      "inspect_generated_at",
      "REVIEW_BOARD_GENERATED_AT_MAX_FUTURE_SKEW_SECONDS",
      "too far in the future",
      "generatedAt must be a UTC ISO-8601 timestamp ending in Z",
      "stale review-board generatedAt",
      "safe_posix_parts",
      "must not contain empty, current-directory, or parent-directory components",
      "inspect_png_header",
      "inspect_png_decodes",
      "inspect_png_artifact",
      "PNG_HEADER_BYTES",
      "REVIEW_BOARD_IMAGE_MAX_BYTES",
      "REVIEW_BOARD_IMAGE_MAX_PIXELS",
      "handle.read(REVIEW_BOARD_IMAGE_MAX_BYTES + 1)",
      "Image.open(io.BytesIO(image_data))",
      "hashlib.sha256(image_data).hexdigest()",
      "must be a decodable PNG image",
      "decoded dimensions do not match PNG IHDR",
      "exceeds byte budget",
    ):
      self.assertIn(token, review_board_inspector)
    for token in (
      "DriftHandle",
      "test_review_board_inspector_rejects_png_opened_byte_count_drift",
      "test_review_board_inspector_decodes_same_bounded_png_bytes",
      "all(isinstance(file, io.BytesIO) for file in opened_from)",
    ):
      self.assertIn(token, review_board_tests)
    self.assertNotIn('path.read_text(encoding="utf-8")', review_board_inspector)
    for token in (
      "MAX_SCREENSHOT_MANIFEST_BYTES",
      "opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "reject_symlink_components",
      "opened-byte-count drift while hashing",
      "byte count drift after opening",
      "ScreenshotEvidence",
      "handle.read(SCREENSHOT_ARTIFACT_MAX_BYTES + 1)",
      "opened-byte-count drift while reading",
      "Image.open(io.BytesIO(image_data))",
      "Image.open(io.BytesIO(evidence.image_data))",
      "hashlib.sha256(image_data).hexdigest()",
      "hashlib.sha256(page_data).hexdigest()",
      "MAX_REVIEW_JSON_BYTES",
      "MAX_REVIEW_HTML_BYTES",
      "write_atomic_artifact",
      "write_atomic_text",
      "expected_byte_count",
      "byte count drift after writing",
      "os.O_EXCL",
      "os.O_NOFOLLOW",
      "os.fsync(handle.fileno())",
      "os.replace",
      "fsync_parent_directory",
      "os.fsync(parent_fd)",
      "could not fsync parent directory after atomic replace",
      "atomic-write temporary file",
      "target must not be a symbolic link",
    ):
      self.assertIn(token, review_board)
    for token in (
      "test_builder_rejects_source_screenshot_opened_byte_count_drift",
      "test_builder_decodes_source_screenshots_from_same_bounded_bytes",
      "test_review_board_builder_atomic_bytes_rejects_short_write",
      "test_review_board_builder_atomic_write_reports_parent_fsync_failure",
      "all(isinstance(file, io.BytesIO) for file in opened_from)",
    ):
      self.assertIn(token, review_board_tests)
    self.assertNotIn("Image.open(handle)", review_board)

  def test_ci_workflow_calls_quality_gate(self) -> None:
    workflow = read(ROOT / ".github" / "workflows" / "qixi-quality.yml")
    self.assertIn("scripts/qixi-quality-gate.sh", workflow)
    self.assertIn("macos", workflow.lower())
    self.assertRegex(workflow, r"pull_request:")
    self.assertRegex(workflow, r"workflow_dispatch:")
    self.assertIn("scripts/qixi_changed_surface_gate.py --github-output", workflow)
    self.assertIn("fetch-depth: 0", workflow)
    self.assertIn("steps.classify.outputs.requires_screenshots == 'true'", workflow)
    self.assertIn("steps.classify.outputs.requires_real_models == 'true'", workflow)
    self.assertIn("steps.classify.outputs.requires_ios_katago_cmake == 'true'", workflow)
    self.assertIn("steps.classify.outputs.requires_native_release_sim == 'true'", workflow)
    self.assertIn("steps.classify.outputs.requires_release_review == 'true'", workflow)
    self.assertIn("Screenshot gate not required by changed-file classification.", workflow)
    self.assertIn("Real-model gate not required by changed-file classification.", workflow)
    self.assertIn("iOS KataGo CMake gate not required by changed-file classification.", workflow)
    self.assertIn("NativeRelease simulator gate not required by changed-file classification.", workflow)
    self.assertIn("Release/App Store review not required by changed-file classification.", workflow)
    self.assertIn("iOS KataGo CMake Gate", workflow)
    self.assertIn("NativeRelease Simulator Gate", workflow)
    self.assertIn("Release-Sensitive Review Classification", workflow)
    self.assertIn("Device Bridge Smoke Gate", workflow)
    self.assertIn("ios_katago_cmake_relevant_files", workflow)
    self.assertIn("native_release_sim_relevant_files", workflow)
    self.assertIn("release_sensitive_files", workflow)
    self.assertIn("QIXI_RUN_SCREENSHOTS: \"1\"", workflow)
    self.assertIn("QIXI_RUN_REAL_MODELS: \"1\"", workflow)
    self.assertIn("QIXI_RUN_IOS_KATAGO_CMAKE: \"1\"", workflow)
    self.assertIn("QIXI_RUN_NATIVE_RELEASE_SIM: \"1\"", workflow)
    self.assertIn("QIXI_RUN_DEVICE_BRIDGE_SMOKE: \"1\"", workflow)
    self.assertIn("inputs.run_native_release_sim == 'true'", workflow)
    self.assertIn("run_device_bridge_smoke", workflow)
    self.assertIn("inputs.run_device_bridge_smoke == 'true'", workflow)
    self.assertIn("device_bridge_runner", workflow)
    self.assertIn('default: \'["self-hosted","macOS","qixi-device"]\'', workflow)
    self.assertIn("runs-on: ${{ fromJSON(inputs.device_bridge_runner) }}", workflow)
    self.assertIn("secrets.QIXI_DEVICE_BACKEND_URL", workflow)
    self.assertIn("secrets.QIXI_DEVICE_DEVELOPMENT_TEAM", workflow)
    self.assertIn("secrets.QIXI_DEVICE_ID", workflow)
    self.assertIn("secrets.QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES", workflow)
    self.assertIn("scripts/qixi-device-signing-doctor.sh", workflow)
    self.assertIn("iPad/iPhone simulator screenshot", workflow)

  def test_changed_surface_classifier_treats_model_artifacts_as_release_sensitive(self) -> None:
    classifier = read(ROOT / "scripts" / "qixi_changed_surface_gate.py")
    classifier_tests = read(ROOT / "tests" / "test_changed_surface_gate.py")
    docs = read(ROOT / "docs" / "quality-gates.md")
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")

    for token in (
      "MODEL_ARTIFACT_PATTERNS",
      "*.bin.gz",
      "*.txt.gz",
      "*.onnx",
      "*.mlmodel",
      "*.mlmodelc/**",
      "*.mlpackage/**",
      "Models/**",
      "*MODEL_ARTIFACT_PATTERNS",
      "SCREENSHOT_RELEVANT_PATTERNS",
      '"qixi-ios-native/scripts/build_screenshot_review_board.py"',
      '"qixi-ios-native/scripts/performance-smoke-sim.sh"',
      '"qixi-ios-native/scripts/persistence-smoke-sim.sh"',
      '"README.md"',
      '"qixi-ios-native/README.md"',
      '"qixi-ios-sim/README.md"',
      '".gitignore"',
      '"docs/native-ios-runbook.md"',
      '"docs/native-katago-integration.md"',
      '"scripts/qixi-appstore-archive-preflight.sh"',
      '"scripts/qixi-device-run-preflight.sh"',
      '"scripts/qixi_device_run_preflight.py"',
      '"scripts/qixi_device_bridge_smoke.py"',
      '"scripts/qixi-device-bridge-plan-inspect.sh"',
      '"scripts/qixi_device_bridge_smoke_inspect.py"',
      '"scripts/qixi_device_signing_doctor.py"',
      '"qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh"',
      '"qixi-ios-native/tests/screenshot_manifest_json.py"',
      '"tests/test_quality_gate_skip_audit.py"',
      '"tests/fixtures/position_identity_cases.json"',
      '"tests/validate_position_identity_fixture.py"',
      '"tests/test_position_identity_fixture_validator.py"',
      '"tests/test_device_run_preflight.py"',
      '"tests/test_device_signing_doctor.py"',
      "def github_output_delimiter",
      "hashlib.sha256",
      "write_multiline_github_output",
      "if delimiter not in lines",
      "could not choose a safe GitHub output delimiter",
      'raw.split("\\0")',
      '["diff", "--name-only", "-z", candidate]',
      '["diff", "--name-only", "-z", "HEAD~1...HEAD"]',
      "repository-relative",
      "POSIX separators",
      "backslashes",
      "control characters",
      "surrounding whitespace",
      'os.environ.get("QIXI_CHANGED_FILES", "")',
      'pieces = raw.split(",")',
      "empty, current-directory, or parent-directory segments",
    ):
      self.assertIn(token, classifier)
    self.assertNotIn("<<QIXI_EOF\\n", classifier)

    for token in (
      "test_local_model_and_coreml_artifact_paths_are_release_sensitive",
      "converted/b6/network.onnx",
      "converted/b6/network.mlmodelc/Info.plist",
      "converted/b6/network.mlpackage/Manifest.json",
      "test_gitignore_change_is_release_sensitive_hygiene_surface",
      "test_native_ios_runbook_change_is_release_sensitive_only",
      "test_native_katago_integration_doc_change_is_release_sensitive_only",
      "test_device_signing_doctor_implementation_change_requires_release_review",
      "test_device_bridge_smoke_implementation_change_requires_release_review",
      "test_screenshot_manifest_and_inspector_changes_require_screenshot_gate",
      "test_qixi_readmes_are_release_sensitive_only",
      "qixi-ios-native/scripts/build_screenshot_review_board.py",
      "qixi-ios-native/scripts/performance-smoke-sim.sh",
      "qixi-ios-native/scripts/persistence-smoke-sim.sh",
      "scripts/qixi-appstore-archive-preflight.sh",
      "scripts/qixi_device_run_preflight.py",
      "scripts/qixi_device_bridge_smoke.py",
      "scripts/qixi-device-bridge-plan-inspect.sh",
      "scripts/qixi_device_bridge_smoke_inspect.py",
      "scripts/qixi_device_signing_doctor.py",
      "qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh",
      "qixi-ios-native/tests/screenshot_manifest_json.py",
      "tests/test_quality_gate_skip_audit.py",
      "tests/fixtures/position_identity_cases.json",
      "tests/validate_position_identity_fixture.py",
      "tests/test_position_identity_fixture_validator.py",
      "tests/test_device_run_preflight.py",
      "tests/test_device_signing_doctor.py",
      "test_github_output_uses_content_unique_delimiters",
      "self.assertNotIn(\"<<QIXI_EOF\\n\", text)",
      "test_changed_file_parser_preserves_nul_separated_special_paths",
      "test_changed_file_parser_rejects_untrusted_paths",
      "test_changed_file_classifier_rejects_backslashes_in_tokenized_paths",
      "test_changed_file_parser_rejects_surrounding_whitespace_in_tokenized_paths",
      "test_changed_file_parser_rejects_surrounding_whitespace_in_comma_input",
      "test_changed_files_from_env_rejects_whitespace_only_value",
      "test_git_diff_rejects_surrounding_whitespace_in_nul_terminated_name",
      "test_git_diff_uses_nul_terminated_name_output",
      "test_run_git_diff_parses_nul_terminated_names",
      "test_run_git_diff_rejects_backslashes_in_nul_terminated_names",
    ):
      self.assertIn(token, classifier_tests)

    for token in (
      "raw/ONNX/CoreML package artifact paths",
      "runbooks",
      "native engine integration docs",
      "Qixi README files",
      "App Store archive preflight",
      "device preflight/signing doctor/bridge smoke contracts",
      "real-device evidence negative simulator smoke",
      "position identity fixtures",
      "`.gitignore`",
      "repository-relative POSIX changed-file paths",
      "backslashes",
      "control characters",
      "surrounding whitespace",
    ):
      self.assertIn(token, docs)
      self.assertIn(token, matrix)

  def test_pull_request_template_requires_evidence(self) -> None:
    template = read(ROOT / ".github" / "pull_request_template.md")
    required_checks = [
      "docs/pr-verification-matrix.md",
      "scripts/qixi-quality-gate.sh",
      "QIXI_RUN_SCREENSHOT_SMOKE=1 scripts/qixi-quality-gate.sh",
      "QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh",
      "QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh",
      "raw/ONNX/CoreML package artifact paths",
      "QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh",
      "QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh",
      "scripts/qixi-release-evidence-gate.sh",
      "QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json scripts/qixi-real-device-evidence-preflight.sh",
      "scripts/qixi-device-signing-doctor.sh",
      "QIXI_RUN_DEVICE_BRIDGE_SMOKE=1 QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 scripts/qixi-quality-gate.sh",
      "device preflight/signing doctor/bridge smoke contracts changed",
      "Confirmed release/App Store evidence did not set development skip switches such as `QIXI_SKIP_XCODEBUILD`",
      "Confirmed release/App Store evidence ran repository hygiene with `QIXI_REQUIRE_TRACKED_FILE_AUDIT=1`",
      "Confirmed the GitHub changed-surface classifier either ran the NativeRelease simulator gate or recorded a non-native-release skip",
      "Confirmed the GitHub changed-surface classifier either recorded release-sensitive review files or recorded a release-sensitive skip",
      "full union of required gates",
      "Skipped checks",
      "Screenshots or visual diff",
      "Parser/recognition/correctness tests",
      "Persistence or tombstone evidence",
      "Real-model analysis evidence",
      "Real-device iPad/iPhone evidence",
      "Memory, launch time, or performance note",
      "iCloud or multi-device sync evidence",
    ]
    for token in required_checks:
      self.assertIn(token, template)
    self.assertGreaterEqual(len(re.findall(r"- \[ \]", template)), 10)

  def test_pr_verification_matrix_maps_surfaces_to_gates(self) -> None:
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")
    required_tokens = [
      "Required For Every Pull Request",
      "Change-To-Gate Matrix",
      "scripts/qixi-quality-gate.sh",
      "QIXI_RUN_SCREENSHOT_SMOKE=1 scripts/qixi-quality-gate.sh",
      "QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh",
      "QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh",
      "QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh",
      "QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh",
      "GitHub Actions changed-surface classification",
      "automatically run",
      "NativeRelease simulator",
      "bridging header",
      "persistence/tombstone",
      "position identity",
      "iCloud sync",
      "source/header changes",
      "release-sensitive",
      "App\n  Store/release evidence",
      "backend, model, native KataGo",
      "SwiftUI layout",
      "review-board/performance/persistence helper scripts",
      "Board geometry",
      "App lifecycle",
      "SGF import",
      "photo recognition",
      "SGF/photo input-size guards",
      "visible-stone-preview boundary",
      "iCloud sync",
      "Backend API bridge",
      "position identity",
      "KataGo Metal mux",
      "persistent MCTS",
      "Native iPad engine integration",
      "qixi-ios-native/tests/run_analysis_service_smoke.sh",
      "scripts/qixi-native-inprocess-contract-preflight.sh",
      "qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh",
      "scripts/qixi-native-model-preflight.sh",
      "scripts/qixi-device-run-preflight.sh",
      "scripts/qixi-device-bridge-smoke.sh",
      "scripts/qixi-device-bridge-plan-inspect.sh",
      "scripts/qixi-device-bridge-smoke-inspect.sh",
      "scripts/qixi-device-bridge-failure-inspect.sh",
      "diagnosticCategory",
      "iosLocalNetworkDenied",
      "QIXI_RUN_DEVICE_BRIDGE_SMOKE",
      "QIXI_DEVICE_BRIDGE_RUN_ID",
      "scripts/qixi-real-device-run-kit-preflight.sh",
      "scripts/qixi-real-device-evidence-preflight.sh",
      "scripts/qixi_release_evidence_archive_match.py",
      "repository hygiene preflight",
      "App Store privacy",
      "scripts/qixi-appstore-preflight.sh",
      "docs/app-store-readiness.md",
      "memory",
      "launch time",
      "CI, scripts, docs",
      "Evidence Quality",
      "Do not mark a gate as passed when it was skipped",
    ]
    for token in required_tokens:
      self.assertIn(token, matrix)

  def test_real_model_gate_checks_response_shape_and_model_isolation(self) -> None:
    integration = read(ROOT / "qixi-ios-sim" / "tests" / "integration_all_models.py")
    b6_integration = read(ROOT / "qixi-ios-sim" / "tests" / "integration_real_b6.py")
    parser_tests = read(ROOT / "qixi-ios-sim" / "tests" / "test_real_model_integration_response_parser.py")
    inspector = read(ROOT / "qixi-ios-sim" / "tests" / "inspect_real_model_integration_artifact.py")
    inspector_tests = read(ROOT / "qixi-ios-sim" / "tests" / "test_real_model_artifact_inspector.py")
    quality_gate = read(ROOT / "scripts" / "qixi-quality-gate.sh")
    for token in (
      "assert_real_analysis",
      "assert_candidate_moves_are_well_formed",
      "EXPECTED_CASE_IDS = (\"opening\", \"same-stones-history-a\", \"same-stones-history-b\")",
      "DEFAULT_REAL_MODEL_MAX_VISITS = 8",
      "analysis_cases",
      "summarize_real_model_case_result",
      "same_visible_different_history_check",
      "qixi_backend.position_key(",
      "len(ownership) == 19 * 19",
      "len(set(position_keys)) == len(position_keys)",
      "qixi-real-model-metal-mux-integration",
      "latest-real-model-integration.json",
      "write_real_model_artifact",
      "caseDefinitions",
      "analysisCases",
      "sameVisibleDifferentHistoryChecks",
      "modelByteCount",
      "analysisElapsedMs",
      "ownershipMin",
      "ownershipMax",
      "positionKeysUnique",
      '"engine": "none"',
      'off_result["moves"] == []',
      'off_result["ownership"] == []',
      "write_atomic_real_model_artifact",
      "reject_symlink_components",
      "os.O_EXCL",
      "os.O_NOFOLLOW",
      "os.fsync(handle.fileno())",
      "os.replace(tmp_path, checked_path)",
      "os.fsync(parent_fd)",
      "atomic-write temporary file",
      "must not contain symbolic links",
      "Real model integration artifact:",
      "All real model integrations passed: b6, b18nbt, b28nbt",
    ):
      self.assertIn(token, integration)
    for script in (integration, b6_integration):
      for token in (
        "MAX_HTTP_RESPONSE_BYTES",
        "load_json_object_without_duplicate_keys",
        "object_pairs_hook=reject_duplicate_keys",
        "parse_constant=reject_non_standard_constant",
        "response body exceeds",
        "backend response must use application/json",
        "must be a JSON object",
        "duplicate JSON key",
        "non-standard JSON constant",
        "resp.read(MAX_HTTP_RESPONSE_BYTES + 1)",
      ):
        self.assertIn(token, script)
      self.assertNotIn('json.loads(resp.read().decode("utf-8"))', script)
    for token in (
      "qixi-ios-sim/tests/inspect_real_model_integration_artifact.py",
      "real-model integration artifact inspection",
      "QIXI_REAL_MODEL_ARTIFACT_MIN_MTIME_EPOCH",
      "qixi-ios-sim/tests/test_real_model_integration_response_parser.py",
      "real-model integration response parser contract",
    ):
      self.assertIn(token, quality_gate)
    for token in (
      "test_real_model_artifact_writer_is_atomic_and_rejects_symlink_targets",
      "test_real_model_artifact_writer_uses_exclusive_temporary_file",
      "owned-by-someone-else",
    ):
      self.assertIn(token, parser_tests)
    self.assertLess(
      quality_gate.index("qixi-ios-sim/tests/integration_all_models.py"),
      quality_gate.index("qixi-ios-sim/tests/inspect_real_model_integration_artifact.py"),
    )
    for token in (
      "Real model integration artifact inspection passed",
      "EXPECTED_ENGINES = (\"b6\", \"b18nbt\", \"b28nbt\")",
      "EXPECTED_CASE_IDS = (\"opening\", \"same-stones-history-a\", \"same-stones-history-b\")",
      "EXPECTED_KIND = \"qixi-real-model-metal-mux-integration\"",
      "MIN_REAL_MODEL_MAX_VISITS = 8",
      "QIXI_REAL_MODEL_ARTIFACT_MAX_AGE_SECONDS",
      "QIXI_REAL_MODEL_ARTIFACT_MIN_MTIME_EPOCH",
      "artifact_min_mtime_epoch",
      "stale for this run",
      "MAX_ARTIFACT_BYTES",
      "REPO_ROOT",
      "bounded_text",
      "reject_symlink_components",
      "repository_path",
      "regular_file_stat",
      "must stay inside repository root",
      "must not contain symbolic links",
      "exceeds bounded size",
      "modelByteCount does not match modelPath size",
      "katagoBinaryByteCount does not match katagoBinary size",
      "ownershipPointCount must be 361",
      "engine position keys must be unique",
      "all real-model analysis case position keys must be unique",
      "sameVisibleDifferentHistoryChecks",
      "positionKeysDistinct must be true",
      "off-engine position keys should be identical",
      "off-engine position key must not equal a real-model position key",
      "load_strict_json",
      "duplicate JSON key",
      "non-standard JSON constant",
    ):
      self.assertIn(token, inspector)
    for token in (
      "test_valid_artifact_passes",
      "test_rejects_negative_artifact_cases",
      "test_rejects_ambiguous_or_non_standard_json",
      "test_rejects_artifacts_older_than_current_gate_marker",
      "test_rejects_symbolic_link_artifact_and_model_paths",
      "test_rejects_oversized_artifact_before_json_decode",
      "test_rejects_artifacts_that_reference_files_outside_repository_root",
      "modelByteCount",
      "ownershipPointCount",
      "engine position keys must be unique",
      "maxVisits must be at least 8",
      "analysisCases must contain exactly 3 entries",
      "positionKeysDistinct must be true",
      "off-engine position key must not equal a real-model position key",
      "non-standard JSON constant NaN",
      "coordinates must be on a 19x19 board",
    ):
      self.assertIn(token, inspector_tests)
    for token in (
      "test_accepts_strict_json_objects",
      "test_rejects_ambiguous_or_non_standard_responses",
      "test_rejects_oversized_responses_before_json_decode",
      "integration_real_b6.py",
      "integration_all_models.py",
      "duplicate JSON key 'engine'",
      "non-standard JSON constant NaN",
      "must be a JSON object",
      "response body exceeds",
    ):
      self.assertIn(token, parser_tests)

  def test_backend_http_bridge_rejects_ambiguous_or_oversized_requests(self) -> None:
    backend = read(ROOT / "qixi-ios-sim" / "backend" / "qixi_backend.py")
    backend_tests = read(ROOT / "qixi-ios-sim" / "tests" / "test_backend_contract.py")
    docs = read(ROOT / "docs" / "quality-gates.md")
    readme = read(ROOT / "README.md")

    for token in (
      "MAX_REQUEST_BYTES",
      "load_json_object_without_duplicate_keys",
      "object_pairs_hook",
      "parse_constant",
      "duplicate JSON key",
      "non-standard JSON constant",
      "must be a JSON object",
      "POST request must use application/json",
      "request body exceeds",
      "KataGo analysis response",
    ):
      self.assertIn(token, backend)

    for token in (
      "test_http_post_json_parser_rejects_ambiguous_or_non_standard_requests",
      "test_http_post_json_parser_rejects_wrong_content_type_and_oversized_body",
      "test_katago_stdout_json_parser_rejects_ambiguous_or_non_standard_responses",
      "duplicate JSON key 'maxVisits'",
      "non-standard JSON constant NaN",
      "request JSON must be a JSON object",
      "KataGo analysis response must not contain duplicate JSON key 'id'",
      "POST request must use application/json",
      "request body exceeds",
      "application/json; charset=utf-8",
      "post_declared_length_expect_error",
      'connection.putheader("Content-Length", str(declared_length))',
    ):
      self.assertIn(token, backend_tests)

    for token in (
      "Mac-hosted backend bridge",
      "bounded `application/json` POST bodies",
      "duplicate JSON keys",
      "`NaN`/`Infinity`",
      "KataGo analysis stdout responses",
    ):
      self.assertIn(token, docs)
      self.assertIn(token, readme)

  def test_native_backend_client_rejects_ambiguous_or_oversized_responses(self) -> None:
    backend_client = read(ROOT / "qixi-ios-native" / "Qixi" / "BackendClient.swift")
    smoke = read(ROOT / "qixi-ios-native" / "tests" / "analysis_service_smoke.swift")
    docs = read(ROOT / "docs" / "quality-gates.md")
    runbook = read(ROOT / "docs" / "native-ios-runbook.md")
    readme = read(ROOT / "README.md")

    for token in (
      "enum BackendClientResponseError: Error, Equatable, LocalizedError",
      "case unacceptableStatusCode(Int)",
      "case missingJSONContentType(String?)",
      "case responseTooLarge(bytes: Int, limit: Int)",
      "static let maxResponseBytes = 1024 * 1024",
      "var session = URLSession.shared",
      "throw BackendClientResponseError.unacceptableStatusCode(http.statusCode)",
      "http.value(forHTTPHeaderField: \"Content-Type\")",
          "Self.isJSONContentType(contentType)",
          "throw BackendClientResponseError.responseTooLarge",
          "QixiStrictJSONDocumentValidator.validatedObjectData",
          "label: \"Qixi HTTP bridge response\"",
          "JSONDecoder().decode(Response.self, from: objectData)",
        ):
          self.assertIn(token, backend_client)

    for token in (
      "BackendClientSmokeURLProtocol",
      "BackendClient accepts bounded application/json responses with charset parameters",
      "BackendClient must reject non-2xx HTTP responses",
      "BackendClient reports the rejected HTTP status code",
      "BackendClient must reject non-JSON content types",
      "BackendClient reports the rejected response content type",
          "BackendClient must reject oversized backend responses before decoding",
          "BackendClient response-size error reports actual and limit bytes",
          "BackendClient must reject duplicate keys in bridge responses before decoding",
          "BackendClient strict JSON reports duplicate bridge response keys",
          "BackendClient must reject non-standard constants in bridge responses before decoding",
          "BackendClient strict JSON reports non-standard bridge response constants",
          "BackendClient must reject non-object bridge responses before decoding",
          "BackendClient strict JSON requires top-level bridge response objects",
        ):
          self.assertIn(token, smoke)

    for token in (
          "native Swift HTTP bridge response guards",
          "non-`application/json` responses",
          "duplicate JSON keys",
          "`NaN`/`Infinity`",
          "non-object JSON",
          "response bodies larger than",
        ):
          self.assertIn(token, docs)
    for token in (
          "The native Swift",
          "`BackendClient` mirrors that response-side posture",
          "duplicate JSON keys",
          "`NaN`/`Infinity`",
          "non-object JSON",
          "response bodies larger than 1 MiB",
        ):
          self.assertIn(token, runbook)
    for token in (
          "On the native Swift side",
          "`BackendClient` also rejects non-2xx bridge",
          "duplicate JSON keys",
          "`NaN`/`Infinity`",
          "non-object JSON",
          "response bodies larger",
        ):
      self.assertIn(token, readme)

  def test_native_inprocess_bridge_rejects_ambiguous_or_oversized_responses(self) -> None:
    native_service = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeKataGoAnalysisService.swift")
    smoke = read(ROOT / "qixi-ios-native" / "tests" / "analysis_service_smoke.swift")
    docs = read(ROOT / "docs" / "quality-gates.md")
    native_doc = read(ROOT / "docs" / "native-katago-integration.md")
    readme = read(ROOT / "README.md")

    for token in (
      "case invalidBridgeResponse(String)",
      "NativeKataGoBridgeResponseValidator.validatedData(from: responseJSON)",
      "JSONDecoder().decode(AnalysisResponse.self, from: responseData)",
      "enum NativeKataGoBridgeResponseValidator",
      "static let maxResponseBytes = 1024 * 1024",
      "StrictJSONDuplicateKeyScanner",
      "validateTopLevelObject",
      "try data.withUnsafeBytes",
      "let bytes = rawBuffer.bindMemory(to: UInt8.self)",
      "let bytes: UnsafeBufferPointer<UInt8>",
      "dataSlice(from: start, to: index)",
      "duplicate JSON key",
      "non-standard JSON constant",
      "must be a JSON object",
    ):
      self.assertIn(token, native_service)
    self.assertNotIn("Array(data)", native_service)

    for token in (
      "native service must reject duplicate keys in adapter responses before UI caching",
      "native bridge response validator reports duplicate adapter keys",
      "native service must reject non-standard constants in adapter responses before decoding",
      "native bridge response validator reports non-standard JSON constants",
      "native service must reject oversized adapter responses before decoding",
      "NativeKataGoBridgeResponseValidator.maxResponseBytes",
    ):
      self.assertIn(token, smoke)

    for token in (
      "native Swift in-process bridge response guards",
      "`NativeKataGoBridgeResponseValidator` rejects duplicate JSON keys",
      "response bodies larger than 1 MiB",
      "duplicate-key scanner reads the response `Data` through `withUnsafeBytes`",
      "does not allocate a second full byte\n  array",
    ):
      self.assertIn(token, docs)
    for token in (
      "Before Swift decodes native bridge output",
      "parser-specific last-key-wins",
      "allocation before the shared",
    ):
      self.assertIn(token, native_doc)
    for token in (
      "The in-process native bridge path",
      "`QixiNativeKataGoBridge` analysis output",
      "rejected before Swift decodes adapter output into app state",
    ):
      self.assertIn(token, readme)

  def test_native_persistence_rejects_ambiguous_or_oversized_json_before_restore(self) -> None:
    persistence = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiPersistence.swift")
    real_device_evidence = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiRealDeviceEvidence.swift")
    smoke = read(ROOT / "qixi-ios-native" / "tests" / "persistence_sync_smoke.swift")
    docs = read(ROOT / "docs" / "quality-gates.md")
    app_store_doc = read(ROOT / "docs" / "app-store-readiness.md")
    runbook = read(ROOT / "docs" / "native-ios-runbook.md")
    readme = read(ROOT / "README.md")

    for token in (
      "enum QixiStrictJSONError: Error, Equatable, LocalizedError",
          "enum QixiStrictJSONDocumentValidator",
          "validatedObjectData",
          "from url: URL",
          "fileManager.attributesOfItem(atPath: url.path)",
      "private static func boundedData(",
      "validateRegularFileURL(url, label: label)",
      "let openedByteCount = try validateRegularOpenFile(",
      "maxBytes: maxBytes",
      "fstat(handle.fileDescriptor, &statBuffer)",
      "return Int(statBuffer.st_size)",
      "S_IFREG",
      "enum QixiTrustedFilePath",
      "createDirectoryForTrustedWrite",
      "static func writeProtectedDataAtomically(",
      "O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW",
      "Darwin.write(",
      "fstat(descriptor, &statBuffer)",
      "temporary file byte count mismatch after writing",
      "try? (tempURL as NSURL).setResourceValue(fileProtection",
      "Darwin.fcntl(descriptor, F_FULLFSYNC)",
      "Darwin.fsync(descriptor)",
      "Darwin.rename(tempURL.path, url.path)",
      "syncParentDirectory(directoryURL, label: label)",
      "private static func syncParentDirectory(",
      "O_RDONLY | O_NOFOLLOW",
      "could not fsync parent directory after atomic replace",
      'label: "Qixi app snapshot directory"',
      'label: "Qixi lifecycle tombstone directory"',
      'label: "Qixi native engine audit directory"',
      "rejectSymbolicLinkComponents(in: url, label: label)",
      "path must not contain symbolic links",
      "FileHandle(forReadingFrom: url)",
          "let readLimit = maxBytes == Int.max ? maxBytes : maxBytes + 1",
          "handle.readData(ofLength: readLimit)",
          "if openedByteCount > maxBytes",
          "guard data.count == openedByteCount",
          "opened-byte-count drift while reading",
          "try data.withUnsafeBytes",
      "let bytes = rawBuffer.bindMemory(to: UInt8.self)",
      "let bytes: UnsafeBufferPointer<UInt8>",
      "dataSlice(from: start, to: index)",
      "duplicateKey(label: String, key: String)",
      "nonStandardConstant(label: String, value: String)",
      "notRegularFile(label: String, path: String)",
      "documentTooLarge(label: String, bytes: Int, limit: Int)",
      "static let maxSnapshotBytes = 16 * 1024 * 1024",
      "QixiTrustedFilePath.writeProtectedDataAtomically(",
      'label: "Qixi app snapshot"',
      'label: "Qixi lifecycle tombstone"',
          'label: "Qixi native engine restore audit"',
          'label: "Qixi native engine export audit"',
          "static func decode(from url: URL) throws -> QixiAppSnapshot?",
          "static func decode(from url: URL) throws -> QixiEngineTombstoneRestoreAudit?",
          "static func decodeExportAudit(from url: URL) throws -> QixiEngineTombstoneExportAudit?",
          "static func decode(from url: URL) throws -> QixiLifecycleTombstone?",
        ):
          self.assertIn(token, persistence)
    self.assertNotIn("Parser(bytes: Array(data)", persistence)
    self.assertNotIn("Data(contentsOf: url, options: [.mappedIfSafe])", persistence)

    for token in (
      "static let maxEvidenceBytes = 1 * 1024 * 1024",
      "static let maxExportAuditBytes = 64 * 1024",
      "static let maxScreenshotArtifactBytes = 64 * 1024 * 1024",
      "static let maxPerformanceArtifactBytes = 1 * 1024 * 1024",
      "static let maxDeviceLogArtifactBytes = 1 * 1024 * 1024",
      "static let maxScreenshotPixels = 16 * 1024 * 1024",
      "private static let pngHeaderByteCount = 33",
      "readData(ofLength: pngHeaderByteCount)",
      "Screenshot artifact is too large for bounded visual inspection",
      'label: "Qixi real-device evidence"',
      'label: "Qixi real-device evidence export audit"',
      'label: "Qixi real-device performance artifact"',
      'label: "Qixi real-device device-log artifact"',
      "strictArtifactJSONObject(",
      "import CryptoKit",
      "private struct StrictArtifactJSONObject",
      "sha256HexDigest(of: objectData)",
      "SHA256.hash(data: data)",
      "content bytes must match recorded fingerprint",
      "from: artifactURL",
      "QixiTrustedFilePath.createDirectoryForTrustedWrite",
      "QixiTrustedFilePath.writeProtectedDataAtomically(",
      'label: "Real-device evidence directory"',
      'label: "Real-device evidence export audit directory"',
      "rejectSymbolicLinkComponents(in: url, label: \"Real-device evidence path\")",
      "rejectSymbolicLinkComponents(in: exportAuditURL, label: \"Real-device evidence export audit path\")",
      "isAllowedPlatformSymlinkAlias",
      '"/var": "private/var"',
      "regularArtifactFileURL",
      ".isSymbolicLinkKey",
      "Artifact path must not contain symbolic links",
      "Artifact file must be a regular file",
      "validateArtifactByteBudget",
      "let validatedFingerprint = try validateArtifactFingerprint(",
      "private struct ArtifactFileFingerprint: Equatable",
      "validateArtifactFingerprintStableAfterContent",
      "expectedFingerprint: ArtifactFileFingerprint",
      "Artifact \\(kind) changed while validating content",
      "before fingerprinting",
      "standards-compliant JSON object without duplicate keys",
    ):
      self.assertIn(token, real_device_evidence)
    self.assertLess(
      real_device_evidence.index("try validateArtifactByteBudget(kind: kind"),
      real_device_evidence.index("let validatedFingerprint = try validateArtifactFingerprint("),
    )
    self.assertLess(
      real_device_evidence.index("let validatedFingerprint = try validateArtifactFingerprint("),
      real_device_evidence.index("try validateArtifactContent("),
    )
    self.assertLess(
      real_device_evidence.index("try validateArtifactContent("),
      real_device_evidence.index("try validateArtifactFingerprintStableAfterContent("),
    )
    self.assertNotIn("Data(contentsOf: artifactURL)", real_device_evidence)

    for token in (
      "snapshot decode rejects duplicate top-level JSON keys",
      "snapshot decode rejects nested duplicate JSON keys",
      "snapshot decode rejects non-standard JSON constants",
      "snapshot decode rejects non-object JSON documents",
      "snapshot decode rejects oversized JSON documents before decoding",
      "snapshot URL decode rejects oversized JSON files before loading",
      "snapshot URL decode rejects symbolic-link files before loading",
      "snapshot URL decode rejects non-regular files before FileHandle read",
      "snapshot save rejects symbolic-link primary paths",
      "snapshot save rejects symbolic-link snapshot directories",
      "oversized lifecycle tombstone URL is rejected before loading",
      "lifecycle tombstone URL rejects symbolic-link files before loading",
      "lifecycle tombstone mark rejects symbolic-link paths",
      "oversized native engine export audit URL is rejected before loading",
      "native engine export audit URL rejects symbolic-link files before loading",
      "native engine export audit mark rejects symbolic-link paths",
      "oversized native engine restore audit URL is rejected before loading",
      "native engine restore audit URL rejects symbolic-link files before loading",
      "native engine restore audit mark rejects symbolic-link paths",
      "duplicate-key primary snapshot falls back to backup",
      "preferredSnapshot recovers from remote backup when primary sync snapshot has duplicate JSON keys",
      "remote backup is preserved when primary sync snapshot has duplicate JSON keys",
      "preferredSnapshot recovers from remote backup when primary sync snapshot is a directory",
      "remote backup is preserved when primary sync snapshot is a directory",
      "reconcile treats missing remote backup as mirror repair, not an import",
      "remote backup repair preserves an already-valid primary sync snapshot",
      "reconcile repairs a missing remote backup from the valid primary sync snapshot",
	      "reconcile treats corrupted remote backup as mirror repair, not an import",
	      "corrupted remote backup repair preserves an already-valid primary sync snapshot",
	      "reconcile repairs a corrupted remote backup from the valid primary sync snapshot",
	      "launch does not present local sync fallback as enabled iCloud",
	      "manual sync does not persist local fallback as enabled iCloud",
	      "real-device evidence decode rejects duplicate top-level JSON keys",
      "real-device evidence decode rejects nested duplicate JSON keys",
      "real-device evidence decode rejects non-standard JSON constants",
      "real-device evidence decode rejects non-object JSON documents",
      "real-device evidence decode rejects oversized JSON documents before decoding",
      "oversized real-device evidence URL is rejected before loading",
      "real-device evidence URL rejects symbolic-link evidence files before loading",
      "real-device evidence save rejects symbolic-link evidence paths",
      "real-device evidence save rejects symbolic-link evidence directories",
      "real-device evidence export audit rejects duplicate JSON keys",
      "real-device evidence export audit rejects non-object JSON documents",
      "real-device evidence export audit rejects oversized JSON documents before decoding",
      "oversized real-device evidence export audit URL is rejected before loading",
      "real-device evidence export audit URL rejects symbolic-link files before loading",
      "real-device evidence export audit save rejects symbolic-link paths",
      "real-device evidence export audit save rejects symbolic-link directories",
      "real-device evidence export audit does not write through symbolic-link directories",
      "file-backed strict JSON validator rejects opened file byte count when file size is unavailable",
      "real-device performance artifact rejects duplicate JSON keys",
      "real-device performance artifact rejects non-standard JSON constants",
      "real-device performance artifact rejects oversized JSON files before loading",
      "real-device performance artifact rejects oversized JSON files before loading and before fingerprinting",
      "real-device device-log artifact rejects duplicate JSON keys",
      "real-device device-log artifact rejects oversized JSON files before loading",
      "real-device device-log artifact rejects oversized JSON files before loading and before fingerprinting",
      "real-device evidence rejects symbolic-link artifact files",
      "real-device evidence fingerprinting rejects symbolic-link artifact directories",
      "sync write rejects symbolic-link snapshot directories",
      "createSymbolicLink",
      "real-device evidence rejects an oversized screenshot before bitmap allocation",
      "real-device evidence rejects oversized screenshot artifact bytes before fingerprinting",
      "pngHeaderOnly(width: 20_000, height: 10_000)",
      "expectThrowsContaining",
      "dataByReplacingFirst",
      "writeSparseFile",
    ):
      self.assertIn(token, smoke)
    sync = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiSync.swift")
    view_model = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiViewModel.swift")
    self.assertIn('QixiTrustedFilePath.createDirectoryForTrustedWrite', sync)
    self.assertIn('QixiTrustedFilePath.writeProtectedDataAtomically', sync)
    self.assertIn('label: "Qixi sync snapshot directory"', sync)
    self.assertIn('QixiTrustedFilePath.rejectSymbolicLinkComponents(in: url, label: "Qixi sync snapshot path")', sync)
    self.assertIn("guard let firstCandidate = validCandidates.first else", sync)
    self.assertIn("remainingCandidates: validCandidates.dropFirst()", sync)
    self.assertIn("static var currentProvider: QixiSyncProvider", sync)
    self.assertIn("static func launchSyncEnabled(", sync)
    self.assertIn("requestedEnabled && provider == .iCloud", sync)
    self.assertIn("static func persistedICloudEnabled(afterSyncWith provider: QixiSyncProvider) -> Bool", sync)
    self.assertNotIn("preconditionFailure", sync)
    self.assertIn("let launchSyncOverride = QixiPreferences.iCloudSyncEnabledAutomationOverride", view_model)
    self.assertIn("let requestedLaunchSyncEnabled = launchSyncOverride ??", view_model)
    self.assertIn("QixiSyncStore.launchSyncEnabled(", view_model)
    self.assertIn("requestedEnabled: requestedLaunchSyncEnabled", view_model)
    self.assertIn("automationOverride: launchSyncOverride", view_model)
    self.assertIn("QixiSyncStore.persistedICloudEnabled(afterSyncWith: result.provider)", view_model)
    self.assertIn("QixiPreferences.iCloudSyncEnabledAutomationOverride != nil", view_model)
    self.assertIn('ProcessInfo.processInfo.environment["QIXI_SYNC_STATUS"] != nil', view_model)
    self.assertIn("setICloudSyncEnabled(didUseICloud)", view_model)
    self.assertIn("private func applySyncResultStatus(_ result: QixiSyncResult, syncedAt: Date = Date())", view_model)
    self.assertIn("lastSyncAt: didUseICloud ? syncedAt : nil", view_model)
    self.assertIn("lastError: didUseICloud ? nil : L10n.text(.syncErrorMessage)", view_model)
    self.assertGreaterEqual(view_model.count("applySyncResultStatus(result)"), 2)
    self.assertNotIn("syncStatus = QixiSyncStatus(provider: result.provider, lastSyncAt: Date(), lastError: nil)", view_model)
    utility = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiUtilitySheets.swift")
    self.assertIn('model.iCloudSyncEnabled ? "icloud.and.arrow.up" : "icloud.slash"', utility)
    self.assertIn("model.iCloudSyncEnabled ? QixiColor.hermesBlue : Color.secondary", utility)
    utility_inspector = read(ROOT / "qixi-ios-native" / "tests" / "inspect_utility_sheet_screenshot.py")
    self.assertIn("def sync_icon_blue_pixel_count", utility_inspector)
    self.assertIn('expected_state in {"enabled", "synced", "error", "conflict"}', utility_inspector)
    self.assertIn("disabled sync sheet must not reuse the enabled blue iCloud icon", utility_inspector)
    self.assertIn("@State private var visualState: ImportSheetVisualState", utility)
    self.assertIn("Image(systemName: visualState.systemImageName)", utility)
    self.assertIn(".foregroundStyle(visualState.tint)", utility)
    self.assertIn("visualState = .verifying", utility)
    self.assertIn("visualState = .installed", utility)
    self.assertIn("visualState = .failed", utility)
    self.assertIn("private enum ImportSheetVisualState", utility)
    self.assertIn('return "hourglass"', utility)
    self.assertIn('return "checkmark.seal.fill"', utility)
    self.assertIn('return "exclamationmark.triangle.fill"', utility)
    self.assertIn("QixiColor.hermesOrange", utility)
    self.assertIn("QixiColor.successGreen", utility)
    self.assertIn("QixiColor.warningRed", utility)
    self.assertIn("sync write rejects symbolic-link primary snapshot paths", smoke)
    self.assertIn("launch does not present local sync fallback as enabled iCloud", smoke)
    self.assertIn("launch preserves requested iCloud sync when an iCloud provider is available", smoke)
    self.assertIn("launch automation override can force iCloud sync visual states", smoke)
    self.assertIn("manual sync does not persist local fallback as enabled iCloud", smoke)
    self.assertIn("manual sync persists enabled iCloud only after real iCloud reconciliation", smoke)

    for token in (
      "native persistence and iCloud sync JSON guards",
      "`QixiStrictJSONDocumentValidator` rejects duplicate JSON keys",
      "symbolic-link snapshot, tombstone, audit, and sync paths",
      "non-regular autosave, sync snapshot, tombstone, and audit paths",
      "lifecycle tombstone, and native engine audit files",
      "File-backed restore paths check the file byte count",
      "then read at most `maxBytes + 1` through `FileHandle`",
      "opened-byte-count drift if the actual read length differs",
      "without creating a large\n  `Data`",
      "scans `Data` through\n  `withUnsafeBytes` rather than copying the entire document",
      "QixiTrustedFilePath.writeProtectedDataAtomically",
      "same-directory\n  temporary file opened with `O_EXCL` and `O_NOFOLLOW`",
      "post-write `fstat` byte-count verification",
      "`F_FULLFSYNC`/`fsync`, atomic\n  `rename`, and parent-directory `fsync`",
      "Manual iCloud sync and autosave mirroring only persist the enabled preference\n  when reconciliation reports the `.iCloud` provider",
      "local\n  `SyncFallback` directory",
      "must leave iCloud disabled and surface sync attention",
      "Screenshot automation values for\n  `QIXI_ICLOUD_SYNC_ENABLED` and `QIXI_SYNC_STATUS` pin sync visual state",
      "launch autosave cannot race the screenshot and rewrite the intended sheet",
      "utility-sheet inspector also checks the enabled sync states for the\nblue iCloud icon",
      "rejects disabled sync sheets that reuse that enabled icon",
      "bounded strict object parsing to the evidence\nfile, export audit, performance artifact, and device-log artifact",
      "real-device evidence and export-audit file and directory paths",
      "rechecks each artifact's byte count and SHA-256 after content validation",
      "parse the same strict `Data` whose\nSHA-256 is compared",
    ):
      self.assertIn(token, docs)
    for token in (
      "native\nSwift evidence store applies bounded strict object parsing",
      "evidence file,\nexport audit, performance artifact, and device-log artifact",
      "shared exclusive no-follow atomic writer",
      "post-write `fstat` byte-count verification",
      "`F_FULLFSYNC`/`fsync`, atomic\n`rename`, and parent-directory `fsync`",
      "rechecks each artifact's byte count and SHA-256 after\ncontent validation",
      "parses the same\nstrictly loaded `Data` whose SHA-256 is compared",
    ):
      self.assertIn(token, app_store_doc)
    for token in (
      "Before autosave, backup, iCloud sync",
      "strict object parser",
      "parser-specific last-key-wins behavior",
      "File-backed restore paths check the file byte",
      "then read at most `maxBytes + 1` through `FileHandle`",
      "opened-byte-count drift if the actual read length differs",
      "without creating a large `Data` allocation",
      "shared Swift atomic writer",
      "exclusive no-follow flags",
      "post-write `fstat` byte-count\nverification",
      "`F_FULLFSYNC`/`fsync`, atomic `rename`, and parent-directory\n`fsync`",
    ):
      self.assertIn(token, runbook)
    for token in (
      "Real-device release evidence, its export audit",
      "bounded strict object parser",
      "File-backed restore paths check byte counts",
      "opened-byte-count drift if the bytes actually read do not match",
      "shared Swift atomic writer",
      "exclusive no-follow flags",
      "post-write `fstat` byte-count\nverification",
      "`F_FULLFSYNC`/`fsync`, atomic `rename`, and parent-directory",
      "rechecks artifact byte counts and SHA-256 digests\nafter content validation",
      "JSON artifact content is parsed from the same strict `Data`",
      "large `Data` allocations",
    ):
      self.assertIn(token, readme)
    for token in (
      "Autosave, backup, iCloud sync",
      "JSON files also pass a strict object parser before restore",
      "cannot silently change",
    ):
      self.assertIn(token, readme)

  def test_quality_docs_describe_tiers_and_escalation(self) -> None:
    docs = read(ROOT / "docs" / "quality-gates.md")
    for token in (
      "Default gate",
      "Screenshot gate",
      "Real-model gate",
      "Release evidence gate",
      "When to run the expensive gates",
      "No silent skips",
      "docs/pr-verification-matrix.md",
      "scripts/qixi-release-evidence-gate.sh",
      "run_device_bridge_smoke",
      "runner-label array",
      '["self-hosted","macOS","qixi-device"]',
      "Device Bridge Smoke Gate",
      "qixi-ios-native/scripts/screenshot-smoke-sim.sh",
      "qixi-ios-native/scripts/screenshot-environment-doctor.sh",
      "qixi-ios-native/tests/inspect_screenshot_environment.py",
      "fresh mtime",
      "UTC `generatedAt` freshness/future-skew checks",
      "path-component rejection",
      "selected simulator UDIDs",
      "simulator-vs-device limitation caveats",
      "QIXI_RUN_SCREENSHOT_SMOKE=1 scripts/qixi-quality-gate.sh",
      "quick regression tripwire",
      "not a replacement for the full matrix",
      "App Store static preflight",
      "static preflight reads the Xcode project",
      "through bounded local file-size guards before parsing",
      "rejects symbolic-link\n  path components before load",
      "resolve to `/usr/bin/xcodebuild`",
      "shadowed `xcodebuild` earlier in `PATH`",
      "fake build evidence",
      "Repository hygiene preflight",
      "Python bytecode caches",
      "source paths for Python bytecode caches",
      "Xcode user/build result bundles",
      "temporary files, and recovery files",
      "outside a git worktree",
      "native in-process integration contract preflight",
      "native KataGo adapter compile probe",
      "native SGF parser smoke test",
      "bounded UTF-8/Latin-1 file loading",
      "oversized SGF rejection before file data is loaded",
      "native board legality crosscheck smoke",
      "qixi-ios-native/tests/run_board_legality_crosscheck.sh",
      "native board recognition smoke test",
      "large-photo",
      "downsampling",
      "oversized-photo rejection",
      "EXIF orientation correction",
      "visible stones without changing ordered history",
      "`board-recognition-preview` fixture",
      "Hermes-blue preview rings",
      "current analysis root",
      "position identity fixture contract",
      "tests/validate_position_identity_fixture.py",
      "bounded UTF-8 fixture read",
      "rejects symbolic-link and non-regular\n  fixture paths",
      "rechecks the opened descriptor with `fstat`",
      "closed case/relation references",
      "`sameVisibleStones=true` but `equal=false` relations",
      "replays each fixture history",
      "occupied-point moves",
      "immediate simple-ko recapture",
      "`sameVisibleStones` value matches",
      "`sameNextPlayer` value matches",
      "standalone\n    `qixi-ios-native/tests/run_analysis_service_smoke.sh`",
      "manifest is parsed as standards-compliant JSON",
      "coverage cannot depend on parser-specific last-key-wins behavior",
      "tests/fixtures/position_identity_cases.json",
      "equality-partition fixture",
      "sameVisibleStones",
      "sameNextPlayer",
      "ko-history-after-passes",
      "Python preflight derives the b6, b18nbt, and b28nbt",
      "from `QixiNativeModelRegistry.swift`",
      "memory budgets and CoreML companion package specs",
      "nativeInProcess peak and post-analysis RSS measurements",
      "`maximumMemoryMB`",
      "non-standards-compliant JSON with duplicate object\nkeys or `NaN`/`Infinity` constants",
      "positive-integer visits and candidate counts",
      "finite\nlaunch/memory/frame-pacing measurements",
      "standards-compliant JSON",
      "rejects duplicate object keys",
      "`NaN`/`Infinity`",
      "non-finite-number behavior",
      "last-key-wins",
      "parser rejects a Swift registry missing any release engine",
      "before `configureModel` or any real-engine",
      "it must not enter a partially configured",
      "Changes to the shared",
      "`tests/fixtures/position_identity_cases.json` fixture, its",
      "`tests/validate_position_identity_fixture.py` validator",
      "that validator's\ntests also trigger",
	      "shared position-identity fixtures",
	      "remote sync primary/backup recovery",
	      "remote sync mirror repair",
	      "provider-aware iCloud enablement decisions",
	      "local `SyncFallback`\n  writes from being persisted or displayed as enabled iCloud sync",
	      "screenshot automation overrides",
	      "`firstIllegalMoveIndex` validates histories in a single pass",
      "retaining only the current board and previous board",
      "`visibleStones`, `isOccupied`, and `isLegalMove` share the same bounded replay\n  state",
      "precomputed 361-point adjacency table",
      "instead\n  of allocating a fresh neighbor array",
      "fixed 361-entry visited table plus array-backed\n  group storage",
      "rather than hash sets on the board hot path",
      "wrong-engine analysis-cache rejection",
      "malformed semantic analysis-cache rejection",
      "canonical UInt64 bit-pattern semantic cache fields",
      "finite in-range semantic\n  cache settings",
      "distinct same-stones/different-history and different valid-setting\n  semantic caches",
      "illegal semantic-cache history rejection",
      "long mixed-history\n  bounded legality validation",
      "Every decoded semantic cache history must pass the same board-legality check",
      "A snapshot may\n  preserve multiple valid history and setting identities",
      "decode back to finite values inside the\n  supported `QixiAnalysisLimits` komi and root-noise ranges",
      "without exceeding 16 hex digits",
      "`QixiPositionIdentity` semantic structure",
      "without silently overwriting damaged remote state",
      "cache key in the matching\n  `analysisByEngine` engine partition",
      "temporary CMake build directory must stay directly under `/private/tmp` or\n`/tmp`",
      "`qixi-ios-katago-cmake-preflight-` prefix",
      "reject symbolic-link\npath components before",
      "`libkatago_core.a`",
      "`libKataGoSwift.a`",
      "`katago.app/katago`",
      "`lipo` and `otool`",
      "expected iOS/iOS Simulator Mach-O platform",
      "no non-target platform object files",
    ):
      self.assertIn(token, docs)

  def test_position_identity_fixture_validator_bounds_fixture_file_reads(self) -> None:
    validator_source = read(ROOT / "tests" / "validate_position_identity_fixture.py")
    validator_tests = read(ROOT / "tests" / "test_position_identity_fixture_validator.py")
    readme = read(ROOT / "README.md")
    native_readme = read(ROOT / "qixi-ios-native" / "README.md")
    docs = read(ROOT / "docs" / "quality-gates.md")

    for token in (
      "FIXTURE_MAX_BYTES = 1 * 1024 * 1024",
      "def reject_symlink_components(path: pathlib.Path) -> None:",
      "def opened_regular_file_stat(handle: Any, path: pathlib.Path) -> os.stat_result:",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG(opened_stat.st_mode)",
      "handle.read(FIXTURE_MAX_BYTES + 1)",
      "opened-byte-count drift while reading fixture",
      "fixture must be valid UTF-8",
    ):
      self.assertIn(token, validator_source)
    self.assertNotIn('path.read_text(encoding="utf-8")', validator_source)

    for token in (
      "test_fixture_path_must_not_be_symbolic_link",
      "test_fixture_path_must_be_regular_file_before_opening",
      "test_oversized_fixture_is_rejected_before_json_parse",
      "test_fixture_reader_rechecks_opened_descriptor_is_regular",
      "test_fixture_reader_rejects_invalid_utf8_before_json_parse",
    ):
      self.assertIn(token, validator_tests)

    for token in (
      "bounded UTF-8 fixture read",
      "rejects\nsymbolic-link and non-regular fixture paths",
      "rechecks the opened descriptor with\n`fstat`",
    ):
      self.assertIn(token, readme)
    for token in (
      "bounded UTF-8 fixture read",
      "rejects symbolic-link and non-regular\n  fixture paths",
      "rechecks the opened descriptor with `fstat`",
    ):
      self.assertIn(token, docs)
    for token in (
      "bounded UTF-8 load",
      "rejects\nsymbolic-link and non-regular fixture paths",
      "with `fstat` before strict JSON parsing",
    ):
      self.assertIn(token, native_readme)

  def test_native_inprocess_contract_preflight_pins_real_adapter_boundary(self) -> None:
    script = read(ROOT / "scripts" / "qixi-native-inprocess-contract-preflight.sh")
    doc = read(ROOT / "docs" / "native-katago-integration.md")
    quality_doc = read(ROOT / "docs" / "quality-gates.md")
    readme = read(ROOT / "README.md")
    engine_impl = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeKataGoEngine.cpp")
    compile_runner = read(ROOT / "qixi-ios-native" / "tests" / "run_native_katago_adapter_compile_probe.sh")
    compile_probe = read(ROOT / "qixi-ios-native" / "tests" / "native_katago_adapter_compile_probe.cpp")

    for token in (
      "Production Adapter Contract",
      "Setup::initializeNNEvaluator",
      "AsyncBot",
      "Search::getAnalysisData",
      "Search::getAnalysisJson",
      "Search::getAverageTreeOwnership",
      "Search::getAverageAndStandardDeviationTreeOwnership",
      "EvalCacheTable",
      "BoardHistory",
      "same stones but different previous move order",
      "tests/fixtures/position_identity_cases.json",
      "same equality partition",
      "sameVisibleStones",
      "sameNextPlayer",
      "ko-history-after-passes",
      "parseNativeKataGoAnalysisRequestJSON",
      "NativeKataGoAnalysisRequest",
      "nextPlayer",
      "finalBoard",
      "must not clear `BoardHistory` mid-replay",
      "NativeKataGoRules",
      "Chinese rules",
      "occupied-point moves",
      "suicide",
      "simple-ko recapture",
      "analyzeRequest(const NativeKataGoAnalysisRequest&)",
      "MCTS+NN average",
      "qixi::NativeKataGoEngine::unloadModel",
      "must not call `loadModel` for the next engine",
      "must not use `MainCmds::analysis`",
      "must not use `MainCmds::gtp`",
      "exportTombstoneToFile",
      "restoreTombstoneFromFile",
      "NativeKataGoCore",
      "partially restored or stale native tree",
      "does not leave a b6/b18nbt/b28nbt model resident under",
      "Missing or empty restore sources",
      "call `NativeKataGoEngine::unloadModel`",
      "readable and non-empty",
      "bounded 256 MiB",
      "verify the opened descriptor",
      "read in chunks",
      "Internal persistent-MCTS temporary files must never follow a symlink",
      "create its `.tmp` file exclusively",
      "flush that temporary",
      "oversized restore source",
      "produced no recoverable file",
      "qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh",
        "Search::setPositionForMCTSPersistence",
        "`lipo`, `otool`, and `nm`",
        "must not contain symbolic links",
        "bounded before loading",
        "without traversing outside the XCFramework",
        "symlinked artifacts",
        "not considered a real KataGo runtime merely because it contains broad",
        "`initializeNNEvaluator`",
        "`restorePersistentMCTSTombstone`",
    ):
      self.assertIn(token, doc)

    for token in (
      "Native in-process contract preflight passed",
      "KataGo/cpp/command/analysis.cpp",
      "KataGo/cpp/search/asyncbot.h",
      "KataGo/cpp/search/search.h",
      "KataGo/cpp/program/setup.h",
      "QixiNativeKataGoCore.hpp",
      "QixiNativeKataGoCore.cpp",
      "QixiNativeKataGoEngine.cpp",
      "QixiNativeKataGoAnalysisService.swift",
      "QIXI_NATIVE_INPROCESS_PREFLIGHT_TESTING",
      "QIXI_NATIVE_INPROCESS_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR",
      "SOURCE_TEXT_MAX_BYTES",
      "_opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "must be a regular file after opening",
      "after opening",
      "_reject_symlink_components",
      "_is_allowed_platform_symlink_alias",
      "handle.read(SOURCE_TEXT_MAX_BYTES + 1)",
      "exceeds bounded size",
      "Setup::initializeNNEvaluator",
      "search->getAnalysisJson",
      "std::vector<double> getAverageTreeOwnership",
      "struct NativeKataGoAnalysisRequest",
      "struct NativeKataGoRules",
      "enum class NativeKataGoKoRule",
      "enum class NativeKataGoScoringRule",
      "enum class NativeKataGoTaxRule",
      "enum class NativeKataGoWhiteHandicapBonusRule",
      "NativeKataGoKoRule koRule = NativeKataGoKoRule::simple",
      "NativeKataGoScoringRule scoringRule = NativeKataGoScoringRule::area",
      "NativeKataGoTaxRule taxRule = NativeKataGoTaxRule::none",
      "NativeKataGoWhiteHandicapBonusRule whiteHandicapBonusRule = NativeKataGoWhiteHandicapBonusRule::n",
      "bool friendlyPassOk = true",
      "enum class NativeKataGoBoardPoint",
      "std::array<NativeKataGoBoardPoint, 19 * 19> finalBoard{}",
      "NativeKataGoRules rules",
      "NativeKataGoMoveColor nextPlayer = NativeKataGoMoveColor::black",
      "parseNativeKataGoAnalysisRequestJSON",
      "nativeKataGoChineseRules",
      "nativeMoveHistoryLooksLegal",
      "applyNativeBoardMove",
      "nativeBoardPointsFromSnapshot",
      "nativeBoardGroupHasLiberty",
      "request.rules = chineseRules()",
      "valueIsJSONStringEqual(json, rulesStart, rulesEnd, \\\"Chinese\\\")",
      "nativeKataGoOppositeColor",
      "nativeKataGoMoveColorCode",
      "nativeKataGoKoRuleCode",
      "nativeKataGoScoringRuleCode",
      "nativeKataGoTaxRuleCode",
      "nativeKataGoWhiteHandicapBonusRuleCode",
      "nativeKataGoPositionKeyMaterial",
      "parseRequestMovesArray",
      "virtual NativeKataGoResult analyzeRequest(const NativeKataGoAnalysisRequest& request)",
      "native engine adapter interface must receive parsed requests, not raw JSON",
      "engine->analyzeRequest(request)",
      "virtual NativeKataGoResult unloadModel() = 0",
      "engine->unloadModel()",
      "clearLoadedEngineAfterTombstoneRestoreFailure",
      "clearLoadedEngineAfterTombstoneRestoreFailure(engine.get(), loadedEngineID)",
      "must not call `loadModel` for the next engine",
      "BackendClient",
      "URLSession",
      "MainCmds::analysis",
      "MainCmds::gtp",
      "popen(",
      "std::system",
      "system(",
      "NSTask",
      "Process(",
      "native C++ adapter must not use process, GTP, or Mac-hosted bridge token",
      "Native KataGo is not linked into this build.",
      "#if !QIXI_ENABLE_NATIVE_KATAGO\\nNativeKataGoResult libraryNotLinkedResult()",
      "#if !QIXI_ENABLE_NATIVE_KATAGO\\nclass PlaceholderNativeKataGoEngine final",
      "#if QIXI_ENABLE_NATIVE_KATAGO\\n  return std::make_unique<LinkedNativeKataGoEngine>();\\n#else",
    ):
      self.assertIn(token, script)
    self.assertNotIn("path.read_text(encoding=\"utf-8\")", script)

    unguarded_descriptor_env = {
      **os.environ,
      "QIXI_NATIVE_INPROCESS_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR": "1",
    }
    unguarded_descriptor_result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-native-inprocess-contract-preflight.sh")],
      cwd=ROOT,
      env=unguarded_descriptor_env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(unguarded_descriptor_result.returncode, 0)
    self.assertIn(
      "QIXI_NATIVE_INPROCESS_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR may only be used with QIXI_NATIVE_INPROCESS_PREFLIGHT_TESTING=1",
      unguarded_descriptor_result.stderr,
    )

    descriptor_env = {
      **os.environ,
      "QIXI_NATIVE_INPROCESS_PREFLIGHT_TESTING": "1",
      "QIXI_NATIVE_INPROCESS_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR": "1",
    }
    descriptor_result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-native-inprocess-contract-preflight.sh")],
      cwd=ROOT,
      env=descriptor_env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(descriptor_result.returncode, 0)
    self.assertIn("native integration doc must be a regular file after opening", descriptor_result.stderr)
    self.assertNotIn("Native in-process contract preflight passed", descriptor_result.stdout)
    for token in (
      "audited\n  source and contract-document inputs through bounded UTF-8 loads",
      "rechecks opened descriptors with `fstat`",
    ):
      self.assertIn(token, quality_doc)
    for token in (
      "native in-process contract preflight",
      "bounded UTF-8 loads",
      "rechecks opened descriptors with `fstat`",
    ):
      self.assertIn(token, readme)

    for token in (
      "-fsyntax-only",
      "native_katago_adapter_compile_probe.cpp",
      "Native KataGo adapter compile probe passed",
    ):
      self.assertIn(token, compile_runner)

    for token in (
      "#define QIXI_ENABLE_NATIVE_KATAGO 1",
      '#include "../Qixi/QixiNativeKataGoEngine.cpp"',
    ):
      self.assertIn(token, compile_probe)

    for token in (
      "#if QIXI_ENABLE_NATIVE_KATAGO",
      "qixiToKataGoRules",
      "NativeKataGoRules",
      "Rules::KO_SIMPLE",
      "Rules::SCORING_AREA",
      "Rules::TAX_NONE",
      "Rules::WHB_N",
      "qixiBuildKataGoRoot",
      "BoardHistory history(board, initialPlayer, rules, 0)",
      "history.makeBoardMoveTolerant(board, moveLoc, movePlayer, false)",
      "root.history.moveHistory.size() == request.moves.size()",
      "search.setPositionForMCTSPersistence",
      "search.getAnalysisJson",
      "search.getAverageTreeOwnership",
      "qixiBuildAnalysisResponseJSON",
      "qixiMCTSTreeOwnershipJSON",
      'response["ownership"] = qixiMCTSTreeOwnershipJSON(search)',
      'response["moves"] = moves',
      'response["winrate"]',
      'response["scoreMean"]',
      "nativeKataGoPositionKeyMaterial(request)",
      "class LinkedNativeKataGoEngine final",
      "Board::initHash()",
      "ScoreValue::initTables()",
      "Setup::initializeNNEvaluator",
      "Setup::loadSingleParams",
      "qixiNativeKataGoConfigMap",
      "qixiRequestSearchParams",
      "qixiLinkedTombstoneJSON",
      "qixiLinkedTombstoneMatchesLoadedConfig",
      "kQixiNativeKataGoMaxPersistentMCTSTombstoneBytes = 256ULL * 1024ULL * 1024ULL",
      "kQixiNativeKataGoTombstoneReadChunkBytes = 1024ULL * 1024ULL",
      "qixiReadFileBounded",
      "O_RDONLY",
      "fstat(fd, &openedMetadata)",
      "openedMetadata.st_size",
      "opened-byte-count drift while reading",
      "label + \" is not a regular file",
      "read(fd, buffer.data(), buffer.size())",
      "qixiPrepareInternalTombstoneTempPath",
      "qixiRequireAtomicTombstoneTargetPath",
      "qixiFlushFileDescriptorToStorage",
      "qixiWriteNewRegularFileExclusively",
      "O_CREAT | O_EXCL",
      "O_CLOEXEC",
      "O_NOFOLLOW",
      "F_FULLFSYNC",
      "fsync(fd)",
      "Could not flush ",
      "byte count drift after writing",
      "EINTR",
      "contents.data() + offset",
      "qixiCloseAndRemoveTempFile(fd, path)",
      "Native KataGo raw persistent-MCTS export temporary path",
      "Native KataGo raw persistent-MCTS restore temporary path",
      "Native KataGo atomic-write target path",
      "Native KataGo atomic-write temporary path",
      "Native KataGo atomic-write temporary file",
      "target must not be a symbolic link",
      "target must not be a directory-shaped artifact",
      "Native KataGo atomic-write payload exceeds",
      "lstat(path.c_str(), &metadata)",
      "if(errno == ENOENT)",
      "!S_ISREG(metadata.st_mode)",
      "grew beyond the bounded native tombstone size",
      '"rootKeyMaterial"',
      '"persistentMCTS"',
      '"rootKey"',
      '"position"',
      "std::make_unique<LinkedNativeKataGoEngine>()",
      "search->setPositionForMCTSPersistence",
      "search->runWholeSearch",
      "qixiPrepareInternalTombstoneTempPath(rawPath, \"Native KataGo raw persistent-MCTS export temporary path\")",
      "search->exportPersistentMCTS",
      "qixiPrepareInternalTombstoneTempPath(rawPath, \"Native KataGo raw persistent-MCTS restore temporary path\")",
      "search->restorePersistentMCTSTombstone",
      "bot.setPosition(root.nextPlayer, root.board, root.history)",
      "bot.genMoveSynchronousAnalyze",
    ):
      self.assertIn(token, engine_impl)
    self.assertLess(
      engine_impl.index("qixiFlushFileDescriptorToStorage(fd, label, path)"),
      engine_impl.index("Could not close \" + label + \" after writing"),
    )
    self.assertNotIn("std::ifstream in(path", engine_impl)
    self.assertNotIn("std::ofstream out(tmpPath", engine_impl)
    self.assertNotIn("history.clear(board, movePlayer, rules, history.encorePhase)", engine_impl)
    self.assertNotIn("Native KataGo tombstone export for linked engines is not implemented yet.", engine_impl)
    self.assertNotIn("Native KataGo tombstone restore for linked engines is not implemented yet.", engine_impl)
    self.assertNotIn("qixiReadFile(", engine_impl)
    self.assertNotIn(
      "std::remove(path.c_str());\n    if(std::rename(tmpPath.c_str(), path.c_str()) != 0)",
      engine_impl,
    )

  def test_repository_hygiene_preflight_blocks_generated_and_large_artifacts(self) -> None:
    gitignore = read(ROOT / ".gitignore")
    hygiene = read(ROOT / "scripts" / "qixi-repo-hygiene-preflight.sh")

    required_patterns = [
      ".DS_Store",
      "__pycache__/",
      "*.pyc",
      ".pytest_cache/",
      ".mypy_cache/",
      ".ruff_cache/",
      ".coverage",
      "coverage.xml",
      "node_modules/",
      "npm-debug.log*",
      "yarn-debug.log*",
      "yarn-error.log*",
      "pnpm-debug.log*",
      "analysis_logs/",
      "qixi-ios-native/artifacts/",
      "qixi-ios-sim/artifacts/",
      "DerivedData/",
      "build/",
      "*.xcuserdata/",
      "*.xcuserstate",
      "*.xcresult",
      "*.xcarchive",
      "*.ipa",
      "*.dSYM/",
      "*.tmp",
      "*.moved-aside",
      "/*.bin",
      "/*.bin.gz",
      "/*.txt.gz",
      "/*.onnx",
      "/*.mlmodel",
      "/*.mlmodelc/",
      "/*.mlpackage/",
      "/Models/",
      "KataGo/cpp/build-*/",
      "KataGo/cpp/tests/results/",
    ]
    for pattern in required_patterns:
      self.assertIn(pattern, gitignore)
      self.assertIn(pattern, hygiene)

    for token in (
      "git ls-files",
      "forbidden_tracked_regex",
      "source_pollution",
      "fallback_candidate_pollution",
      "model_source_pollution",
      "allowed_tracked_regex",
      "Generated source-control pollution must be removed",
      "Generated or recoverable artifacts must not live in non-ignored source paths",
      "Local model, CoreML, and ONNX artifacts must stay in ignored top-level model locations",
      '-name ".DS_Store" -o',
      '-name ".pytest_cache" -print -prune',
      '-name ".mypy_cache" -print -prune',
      '-name ".ruff_cache" -print -prune',
      '-name "node_modules" -print -prune',
      '-name "*.mlmodelc" -print -prune',
      '-name "*.mlpackage" -print -prune',
      '-name "*.bin" -o',
      '-name "*.bin.gz" -o',
      '-name "*.txt.gz" -o',
      '-name "*.onnx" -o',
      '-name "*.mlmodel"',
      '-name ".coverage" -o',
      '-name "coverage.xml" -o',
      '-name "npm-debug.log*" -o',
      '-name "yarn-debug.log*" -o',
      '-name "yarn-error.log*" -o',
      '-name "pnpm-debug.log*" -o',
      "(.*/)?\\.DS_Store$",
      "(.*/)?__pycache__/",
      "(.*/)?\\.(pytest_cache|mypy_cache|ruff_cache)/",
      "(.*/)?[^/]+\\.pyc$",
      "(.*/)?\\.coverage$",
      "(.*/)?coverage\\.xml$",
      "(.*/)?(npm-debug|yarn-debug|yarn-error|pnpm-debug)\\.log",
      "(.*/)?node_modules/",
      "(.*/)?[^/]+\\.(bin|bin\\.gz|txt\\.gz|onnx|mlmodel)$",
      "(.*/)?[^/]+\\.(mlmodelc|mlpackage)(/|$)",
      "^KataGo/cpp/tests/models/",
      "(.*/)?[^/]+\\.ipa$",
      "(.*/)?[^/]+\\.(xcresult|xcarchive|dSYM)/",
      "KataGo/cpp/build-[^/]+/",
      "KataGo/cpp/tests/results/",
      "qixi-ios-sim/artifacts/",
      "xcresult|xcarchive|dSYM",
      "(.*/)?[^/]+\\.(tmp|moved-aside)",
      "Repository hygiene fallback source-path audit completed: not inside a git worktree",
      "QIXI_REQUIRE_TRACKED_FILE_AUDIT",
      "Repository hygiene tracked-file audit requires a git worktree",
      "Generated or recoverable large artifacts must not be tracked",
      "Repository hygiene preflight passed",
    ):
      self.assertIn(token, hygiene)

    quality_gate = read(ROOT / "scripts" / "qixi-quality-gate.sh")
    self.assertIn('export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"', quality_gate)
    self.assertIn("tests/test_repo_hygiene_preflight.py", quality_gate)
    self.assertIn("cleanup_recoverable_xcode_ui_state", quality_gate)
    self.assertIn("cleanup_recoverable_python_bytecode", quality_gate)
    self.assertIn("cleanup_recoverable_macos_metadata", quality_gate)
    self.assertIn("cleanup_recoverable_tool_caches", quality_gate)
    self.assertIn("cleanup_recoverable_generated_state", quality_gate)
    self.assertIn('find qixi-ios-native/Qixi.xcodeproj -name "*.xcuserstate" -type f -delete', quality_gate)
    self.assertIn('find scripts tests qixi-ios-native qixi-ios-sim', quality_gate)
    self.assertIn('"__pycache__" -type d -prune -exec rm -rf {} +', quality_gate)
    self.assertIn('"*.pyc" -type f -delete', quality_gate)
    self.assertIn('-name ".DS_Store" -type f -delete', quality_gate)
    self.assertIn('-name ".pytest_cache" -o', quality_gate)
    self.assertIn('-name ".mypy_cache" -o', quality_gate)
    self.assertIn('-name ".ruff_cache"', quality_gate)
    self.assertIn('-name ".coverage" -o', quality_gate)
    self.assertIn('-name "coverage.xml" -o', quality_gate)
    self.assertIn('-name "npm-debug.log*" -o', quality_gate)
    self.assertIn('-name "yarn-debug.log*" -o', quality_gate)
    self.assertIn('-name "yarn-error.log*" -o', quality_gate)
    self.assertIn('-name "pnpm-debug.log*"', quality_gate)
    self.assertIn('-path "./KataGo/.git"', quality_gate)
    self.assertIn("trap cleanup_recoverable_generated_state EXIT", quality_gate)
    self.assertLess(
      quality_gate.index('run_step "clean recoverable generated state" cleanup_recoverable_generated_state'),
      quality_gate.index('run_step "repository hygiene preflight" scripts/qixi-repo-hygiene-preflight.sh'),
    )

  def test_shell_entrypoints_do_not_emit_python_bytecode_by_default(self) -> None:
    script_dirs = (
      ROOT / "scripts",
      ROOT / "qixi-ios-native" / "scripts",
      ROOT / "qixi-ios-native" / "tests",
    )
    shell_scripts = sorted(
      script
      for script_dir in script_dirs
      for script in script_dir.glob("*.sh")
    )
    self.assertGreaterEqual(len(shell_scripts), 30)
    for script in shell_scripts:
      with self.subTest(script=script.relative_to(ROOT).as_posix()):
        text = read(script)
        self.assertIn('export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"', text)

  def test_native_release_simulator_smoke_links_and_launches_native_release(self) -> None:
    script_path = ROOT / "qixi-ios-native" / "scripts" / "native-release-sim-smoke.sh"
    script = read(script_path)
    quality_gate = read(ROOT / "scripts" / "qixi-quality-gate.sh")
    docs = (
      read(ROOT / "README.md")
      + read(ROOT / "qixi-ios-native" / "README.md")
      + read(ROOT / "docs" / "quality-gates.md")
      + read(ROOT / "docs" / "native-ios-runbook.md")
      + read(ROOT / "docs" / "pr-verification-matrix.md")
    )

    self.assertTrue(os.access(script_path, os.X_OK))
    for token in (
      "QIXI_NATIVE_RELEASE_SIM_CMAKE_BUILD_DIR",
      "QIXI_NATIVE_RELEASE_SIM_BUILD_MARKER",
      "QIXI_NATIVE_RELEASE_SIM_VALIDATE_ONLY",
      "QIXI_IOS_SDK=iphonesimulator",
      "scripts/qixi-ios-katago-cmake-preflight.sh",
      "-configuration NativeRelease",
      "NativeRelease-iphonesimulator/Qixi.app",
      "CORE_LIBRARY",
      "SWIFT_SIDECAR",
      "EXPECTED_SIMULATOR_PLATFORM_NUMBER=\"7\"",
      "EXPECTED_SIMULATOR_ARCHES",
      "prepare_build_marker",
      "protected_build_marker.py",
      "NativeRelease simulator build marker",
      "validate_native_release_sim_artifacts",
      "validate_native_release_sim_executable",
      "libkatago_core.a and libKataGoSwift.a",
      "NativeRelease simulator app executable passed",
      "is older than NativeRelease simulator build marker",
      "built simulator artifact missing expected architecture",
      "built simulator artifact must not contain object files for another Apple platform",
      "built simulator artifact must target the $EXPECTED_SIMULATOR_PLATFORM_LABEL platform",
      "QIXI_KATAGO_IOS_LIBRARY=$CORE_LIBRARY",
      "APP_EXECUTABLE",
      "NativeRelease simulator app executable is older than the build marker",
      "NativeRelease simulator app executable missing expected architecture",
      "NativeRelease simulator app executable must not contain load commands for another Apple platform",
      "NativeRelease simulator app executable must target the $EXPECTED_SIMULATOR_PLATFORM_LABEL platform",
      "QixiAnalysisRuntime",
      "nativeInProcess",
      "QixiBackendBaseURL",
      "QIXI_BACKEND_URL",
      "QIXI_DEVICE_BACKEND_URL",
      "QIXI_ANALYSIS_RUNTIME",
      "SIMCTL_CHILD_QIXI_BACKEND_URL",
      "SIMCTL_CHILD_QIXI_DEVICE_BACKEND_URL",
      "SIMCTL_CHILD_QIXI_ANALYSIS_RUNTIME",
      "reject_inherited_environment",
      "expected_target=\"/private/var\"",
      "expected_target=\"/private/tmp\"",
      "expected_target=\"/private/etc\"",
      "prepare_output_artifact",
      "temporary_output_path",
      "cleanup_native_release_temp_outputs",
      "SCREENSHOT_CAPTURE_PATH",
      "CONTENT_CAPTURE_PATH",
      "NativeRelease full screenshot artifact",
      "NativeRelease content screenshot artifact",
      "os.replace(tmp_path, target)",
      "os.fsync(parent_fd)",
      "BackendClient",
      "HTTPBridgeAnalysisService",
      "QIXI_NATIVE_RELEASE_SIM_LAUNCH_LOG",
      "QIXI_NATIVE_RELEASE_SIM_CONTENT_SCREENSHOT",
      "APP_PID",
      "/bin/kill -0",
      "SIMCTL_CHILD_QIXI_SKIP_ONBOARDING=1",
      "simctl launch",
      "simctl io",
      "screenshot",
      "content_width <= content_height",
      "content.save(content_capture_path)",
      "tests/inspect_screenshot.py",
      "NativeRelease simulator smoke passed",
    ):
      self.assertIn(token, script)
    self.assertNotIn(': > "$BUILD_MARKER"', script)
    self.assertNotIn('touch "$BUILD_MARKER"', script)
    self.assertNotIn('mkdir -p "$(dirname "$SCREENSHOT_PATH")"', script)
    self.assertNotIn("content.save(content_path)", script)
    self.assertNotIn("SIMCTL_CHILD_QIXI_BACKEND_URL=", script)
    self.assertNotIn("SIMCTL_CHILD_QIXI_DEVICE_BACKEND_URL=", script)
    self.assertNotIn("SIMCTL_CHILD_QIXI_ANALYSIS_RUNTIME=", script)

    self.assertIn("QIXI_RUN_NATIVE_RELEASE_SIM", quality_gate)
    self.assertIn("native release simulator smoke", quality_gate)
    self.assertIn("qixi-ios-native/scripts/native-release-sim-smoke.sh", quality_gate)

    for token in (
      "QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh",
      "NativeRelease simulator",
      "matching `libKataGoSwift.a`",
      "without backend environment variables",
      "nonblank landscape",
      "protected same-directory temporary PNGs",
      "symbolic-link output paths",
      "exclusive no-follow atomic marker",
      "physical-device",
    ):
      self.assertIn(token, docs)

    env = hermetic_qixi_env(SIMCTL_CHILD_QIXI_BACKEND_URL="http://127.0.0.1:8765")
    inherited_backend_result = subprocess.run(
      [str(script_path)],
      cwd=ROOT,
      env=env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(inherited_backend_result.returncode, 0)
    self.assertIn(
      "inherited SIMCTL_CHILD_QIXI_BACKEND_URL is forbidden",
      inherited_backend_result.stderr,
    )

    with tempfile.TemporaryDirectory() as tmpdir:
      target = pathlib.Path(tmpdir) / "target-native-release.png"
      screenshot_link = pathlib.Path(tmpdir) / "linked-native-release.png"
      screenshot_link.symlink_to(target)
      symlink_env = hermetic_qixi_env()
      symlink_env["QIXI_NATIVE_RELEASE_SIM_SCREENSHOT"] = str(screenshot_link)
      symlink_result = subprocess.run(
        [str(script_path)],
        cwd=ROOT,
        env=symlink_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(symlink_result.returncode, 0)
      self.assertIn("symbolic link", symlink_result.stderr)
      self.assertNotIn("Building simulator KataGo artifact", symlink_result.stdout)
      self.assertFalse(target.exists())

    with tempfile.TemporaryDirectory(dir="/private/tmp") as tmpdir:
      build_dir = pathlib.Path(tmpdir)
      core_library = build_dir / "libkatago_core.a"
      swift_sidecar = build_dir / "libKataGoSwift.a"
      build_marker = build_dir / "native-release-marker"
      core_library.write_bytes(b"old core archive\n")
      swift_sidecar.write_bytes(b"old swift archive\n")
      build_marker.write_bytes(b"new marker\n")
      old_epoch = 1_700_000_000
      os.utime(core_library, (old_epoch, old_epoch))
      os.utime(swift_sidecar, (old_epoch, old_epoch))
      os.utime(build_marker, (old_epoch + 10, old_epoch + 10))

      validate_env = hermetic_qixi_env()
      validate_env.update(
        {
          "QIXI_NATIVE_RELEASE_SIM_VALIDATE_ONLY": "1",
          "QIXI_NATIVE_RELEASE_SIM_CMAKE_BUILD_DIR": str(build_dir),
          "QIXI_NATIVE_RELEASE_SIM_BUILD_MARKER": str(build_marker),
        }
      )
      stale_artifact_result = subprocess.run(
        [str(script_path)],
        cwd=ROOT,
        env=validate_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(stale_artifact_result.returncode, 0)
      self.assertIn(
        "is older than NativeRelease simulator build marker",
        stale_artifact_result.stderr,
      )
    self.assertNotIn("Building simulator KataGo artifact", inherited_backend_result.stdout)

  def test_device_signing_doctor_reports_profile_diagnostics(self) -> None:
    wrapper = read(ROOT / "scripts" / "qixi-device-signing-doctor.sh")
    script = read(ROOT / "scripts" / "qixi_device_signing_doctor.py")
    unit = read(ROOT / "tests" / "test_device_signing_doctor.py")
    self.assertIn("qixi_device_signing_doctor.py", wrapper)
    for token in (
      "qixi-device-signing-doctor",
      "PROFILE_SCAN_LIMIT",
      "profile_summary",
      "scan_profiles",
      "identity_summary",
      "availableTeamIdentifiers",
      "apple_development_team_identifiers",
      "visibleDevices",
      "visible devicectl devices",
      "collect_facts",
      "recommendedActions",
      "recommended_actions",
      "selected_device_detail_summary",
      "selected_device_udid",
      "device.coredevice_transport_not_ready",
      "signing.team_identity_missing",
      "signing.profile_missing",
      "signing.xcode_account_probe_failed",
      "matchingProfiles",
      "decodeErrors",
      "xcodeAccountProbe",
      "run_xcode_automatic_provisioning_probe",
      "provisioning_profile_match_failures",
      "per-profile mismatch reasons",
      "Xcode automatic provisioning account probe",
      "--json",
      "DEVICE_ALLOW_PROVISIONING_UPDATES_ENV",
      "Next steps:",
    ):
      self.assertIn(token, script)
    for token in (
      "test_profile_summary_reports_actionable_mismatch_reasons",
      "test_profile_summary_accepts_matching_development_profile",
      "test_preflight_rejects_profile_without_expiration_date",
      "test_scan_profiles_lists_matching_and_nonmatching_profiles",
      "test_identity_summary_counts_matching_team_identities",
      "test_device_detail_summary_extracts_coredevice_readiness_fields",
      "test_collect_facts_reports_visible_unusable_device_states",
      "test_auto_provisioning_requires_clean_xcode_account_probe",
      "test_recommended_actions_report_team_mismatch_and_missing_profile",
      "test_recommended_actions_ignore_unselected_unavailable_devices",
      "test_recommended_actions_report_selected_device_transport_blocker",
      "test_recommended_actions_are_empty_when_ready",
    ):
      self.assertIn(token, unit)

  def test_device_bridge_smoke_writes_manifest_atomically(self) -> None:
    script = read(ROOT / "scripts" / "qixi_device_bridge_smoke.py")
    unit = read(ROOT / "tests" / "test_device_bridge_smoke.py")
    preflight = read(ROOT / "scripts" / "qixi_device_run_preflight.py")
    preflight_unit = read(ROOT / "tests" / "test_device_run_preflight.py")
    for token in (
      "write_manifest",
      "device bridge smoke manifest path",
      "device bridge smoke manifest temporary path",
      "os.O_EXCL",
      "os.O_NOFOLLOW",
      "os.fsync(handle.fileno())",
      "os.replace(tmp_path, checked_path)",
      "os.fsync(parent_fd)",
      "device bridge smoke manifest could not be written",
      "created_tmp",
      "DEVICE_DISABLE_ICLOUD_ENTITLEMENTS_ENV",
      "DEVICE_ALLOW_BUNDLE_OVERRIDE_WITH_ICLOUD_ENV",
      "DEVICE_BRIDGE_PLAN_ONLY_ENV",
      "validate_bridge_signing_overrides",
      "collect_plan_only_signing_blockers",
      "validate_xcode_destination_for_device",
      "PRODUCT_BUNDLE_IDENTIFIER={bundle_id}",
      "CODE_SIGN_ENTITLEMENTS=",
      "iCloudEntitlementsDisabledForLocalBridge",
      "diagnostic_category",
      "diagnosticCategory",
      "iosLocalNetworkDenied",
      "appRuntimeDiagnostic",
      "preflight_facts",
      "signingBlockers",
      "planOnly",
    ):
      self.assertIn(token, script)
    for token in (
      "DEVICE_BUNDLE_ID_ENV",
      "BUNDLE_IDENTIFIER_RE",
      "validate_bundle_identifier",
      "reverse-DNS bundle identifier",
    ):
      self.assertIn(token, preflight)
    for token in (
      "test_write_manifest_is_atomic_and_rejects_symlink_paths",
      "test_write_manifest_uses_exclusive_temporary_file",
      "test_bundle_override_requires_explicit_icloud_entitlement_choice",
      "test_plan_only_signing_blockers_are_collected_without_building",
      "test_backend_events_artifact_payload_requires_selected_engine_event",
      "test_plan_only_manifest_records_preflight_blockers_and_stays_dry_run",
      "manifest path must not contain symbolic links",
      "manifest could not be written",
    ):
      self.assertIn(token, unit)
    for token in (
      "com.example.qixi.local-device",
      "reverse-DNS bundle identifier",
      "DEVICE_BUNDLE_ID_ENV",
    ):
      self.assertIn(token, preflight_unit)

  def test_device_bridge_smoke_inspector_uses_strict_embedded_launch_env_json(self) -> None:
    script = read(ROOT / "scripts" / "qixi_device_bridge_smoke_inspect.py")
    unit = read(ROOT / "tests" / "test_device_bridge_smoke_inspector.py")
    for token in (
      "MAX_LAUNCH_ENV_JSON_BYTES",
      "strict_json_text",
      "as_command_list",
      "require_command_prefix",
      "command_option_value",
      "require_command_option_value",
      "validate_plan_manifest",
      "validate_common_command_shape",
      "validate_manifest_header",
      "validate_string_list",
      "object_pairs_hook",
      "parse_constant",
      "launch environment JSON",
      "target the validated device UDID",
      "must set {option}",
      "\"--device\"",
      "\"--json-output\"",
      "launch the validated app bundle",
      "\"--source\"",
      "device bridge plan manifest must be dryRun",
      "device bridge plan xcodebuild command must disable iCloud entitlements",
      "DIAGNOSTIC_CATEGORIES",
      "failureBackendEvents.diagnosticCategory",
      "backed by Wi-Fi denial diagnostics",
      "Device bridge plan inspection passed",
      "duplicate JSON key",
      "non-standard JSON constant",
      "exceeds bounded size",
    ):
      self.assertIn(token, script)
    for token in (
      "build_plan_manifest",
      "test_plan_manifest_passes_only_plan_inspector",
      "test_plan_manifest_rejects_real_evidence_shape_and_command_drift",
      "test_failure_manifest_rejects_contradictory_or_weak_failure_evidence",
      "test_rejects_ambiguous_or_unbounded_launch_environment_json",
      "test_rejects_malformed_or_token_stuffed_command_records",
      "test_rejects_command_device_artifact_and_bundle_mismatches",
      "install command must be a command list",
      "target the validated device UDID",
      "value after --environment-variables",
      "launch command must set --device",
      "install command must set --json-output",
      "launch the validated app bundle",
      "copyAppSupport command must set --source",
      "duplicate JSON key 'QIXI_ANALYSIS_RUNTIME'",
      "non-standard JSON constant NaN",
      "launch environment JSON must be an object",
      "launch environment JSON exceeds bounded size",
    ):
      self.assertIn(token, unit)

  def test_root_readme_points_to_native_and_quality_docs(self) -> None:
    readme = read(ROOT / "README.md")
    self.assertIn("棋析", readme)
    self.assertIn("qixi-ios-native", readme)
    self.assertIn("scripts/qixi-quality-gate.sh", readme)
    self.assertIn("scripts/qixi_changed_surface_gate.py", readme)
    self.assertIn("automatically runs the full screenshot gate", readme)
    self.assertIn("qixi-ios-native/tests/inspect_screenshot_environment.py", readme)
    self.assertIn("stale or malformed\nenvironment evidence, stale `generatedAt`, future-dated `generatedAt`", readme)
    self.assertIn("screenshot review-board/performance/persistence helper\nscripts", readme)
    self.assertIn("manifest itself is parsed as standards-compliant JSON", readme)
    self.assertIn("rejecting duplicate\nobject keys and `NaN`/`Infinity` constants", readme)
    self.assertIn("real-model gate as well", readme)
    self.assertIn("NativeRelease simulator smoke", readme)
    self.assertIn("bridging header", readme)
    self.assertIn("persistence/tombstone", readme)
    self.assertIn("position identity", readme)
    self.assertIn("iCloud\nsync", readme)
    self.assertIn("source/header changes", readme)
    self.assertIn("native runtime/evidence export files", readme)
    self.assertIn("non-standards-compliant JSON", readme)
    self.assertIn("release-sensitive review\nclassification", readme)
    self.assertIn("qixi-ios-native/tests/test_localization_contract.py", readme)
    self.assertIn("scripts/qixi-native-model-preflight.sh", readme)
    self.assertIn("qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh", readme)
    self.assertIn("scripts/qixi-native-linked-build-preflight.sh", readme)
    self.assertIn("QIXI_KATAGO_IOS_XCFRAMEWORK=/path/to/KataGo.xcframework", readme)
    self.assertIn("QIXI_KATAGO_IOS_LIBRARY=/path/to/libkatago_core.a", readme)
    self.assertIn("QIXI_KATAGO_IOS_LIBRARY_DIR=/path/to/cmake-build", readme)
    self.assertIn("scripts/qixi-ios-katago-cmake-preflight.sh", readme)
    self.assertIn("QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh", readme)
    self.assertIn("scripts/qixi-device-signing-doctor.sh", readme)
    self.assertIn("scripts/qixi-device-run-preflight.sh", readme)
    self.assertIn("run_device_bridge_smoke", readme)
    self.assertIn("Device Bridge Smoke Gate", readme)
    self.assertIn('["self-hosted","macOS","qixi-device"]', readme)
    self.assertIn("runner-label array", readme)
    self.assertIn("QIXI_DEVICE_BACKEND_URL", readme)
    self.assertIn("QIXI_DEVICE_DEVELOPMENT_TEAM", readme)
    self.assertIn("diagnosticCategory", readme)
    self.assertIn("iosLocalNetworkDenied", readme)
    self.assertIn("scripts/qixi-real-device-evidence-preflight.sh", readme)
    self.assertIn("Python bytecode caches", readme)
    self.assertIn("rejected from\nnon-ignored source paths", readme)
    self.assertIn("scripts/qixi-release-evidence-gate.sh", readme)
    self.assertIn("placeholder native engine", readme)
    self.assertIn("Simulator+device iOS KataGo CMake path", readme)
    self.assertIn("scripts/qixi-repo-hygiene-preflight.sh", readme)
    self.assertIn("docs/quality-gates.md", readme)
    self.assertIn("docs/pr-verification-matrix.md", readme)
    self.assertIn("docs/native-ios-runbook.md", readme)
    self.assertIn("docs/native-katago-integration.md", readme)
    self.assertIn("docs/app-store-readiness.md", readme)
    self.assertIn("KataGo", readme)

  def test_native_model_preflight_rejects_untrusted_inputs_before_loading(self) -> None:
    script = read(ROOT / "scripts" / "qixi-native-model-preflight.sh")
    for token in (
      "QIXI_NATIVE_MODEL_PREFLIGHT_TESTING",
      "QIXI_NATIVE_MODEL_PREFLIGHT_TEST_ROOT",
      "QIXI_NATIVE_MODEL_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR",
      "SOURCE_TEXT_MAX_BYTES",
      "MODEL_FILE_MAX_BYTES",
      "HASH_CHUNK_BYTES",
      "_is_allowed_platform_symlink_alias",
      "reject_symlink_components",
      "validate_regular_file",
      "opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "must be a regular file after opening",
      "after opening",
      "bounded_bytes",
      "handle.read(max_bytes + 1)",
      "bytes_read += len(chunk)",
      "opened-byte-count drift while hashing",
      "while hashing",
      "validate_regular_file(model_path",
      "must not contain symbolic links",
      "exceeds bounded size",
    ):
      self.assertIn(token, script)
    self.assertNotIn("path.read_text(encoding=\"utf-8\")", script)
    self.assertNotIn("path.read_bytes()", script)
    readme = read(ROOT / "README.md")
    native_doc = read(ROOT / "docs" / "native-katago-integration.md")
    quality_doc = read(ROOT / "docs" / "quality-gates.md")
    for doc_text in (readme, native_doc, quality_doc):
      normalized_doc = " ".join(doc_text.split())
      self.assertIn("symbolic links", normalized_doc)
      self.assertIn("bounded", normalized_doc)
      self.assertIn("before hashing", normalized_doc)
      self.assertIn("fstat", normalized_doc)
      self.assertIn("opened-byte-count drift", normalized_doc)

    with tempfile.TemporaryDirectory() as tmpdir:
      base = pathlib.Path(tmpdir)
      script_path = ROOT / "scripts" / "qixi-native-model-preflight.sh"

      unguarded_descriptor_env = {
        **os.environ,
        "QIXI_NATIVE_MODEL_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR": "1",
      }
      unguarded_descriptor_result = subprocess.run(
        [str(script_path)],
        cwd=ROOT,
        env=unguarded_descriptor_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(unguarded_descriptor_result.returncode, 0)
      self.assertIn(
        "QIXI_NATIVE_MODEL_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR may only be used with QIXI_NATIVE_MODEL_PREFLIGHT_TESTING=1",
        unguarded_descriptor_result.stderr,
      )

      descriptor_env = {
        **os.environ,
        "QIXI_NATIVE_MODEL_PREFLIGHT_TESTING": "1",
        "QIXI_NATIVE_MODEL_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR": "1",
      }
      descriptor_result = subprocess.run(
        [str(script_path)],
        cwd=ROOT,
        env=descriptor_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(descriptor_result.returncode, 0)
      self.assertIn("native model registry must be a regular file after opening", descriptor_result.stderr)
      self.assertNotIn("Native model preflight passed", descriptor_result.stdout)

      guarded_env = {**os.environ, "QIXI_NATIVE_MODEL_PREFLIGHT_TEST_ROOT": str(base / "guarded")}
      guarded_result = subprocess.run(
        [str(script_path)],
        cwd=ROOT,
        env=guarded_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(guarded_result.returncode, 0)
      self.assertIn(
        "QIXI_NATIVE_MODEL_PREFLIGHT_TEST_ROOT may only be used with QIXI_NATIVE_MODEL_PREFLIGHT_TESTING=1",
        guarded_result.stderr,
      )

      symlink_root = base / "source-symlink-root"
      symlink_registry_dir = symlink_root / "qixi-ios-native" / "Qixi"
      symlink_registry_dir.mkdir(parents=True)
      symlink_target = base / "registry-target.swift"
      symlink_target.write_text("// target\n", encoding="utf-8")
      (symlink_registry_dir / "QixiNativeModelRegistry.swift").symlink_to(symlink_target)
      symlink_env = {
        **os.environ,
        "QIXI_NATIVE_MODEL_PREFLIGHT_TESTING": "1",
        "QIXI_NATIVE_MODEL_PREFLIGHT_TEST_ROOT": str(symlink_root),
      }
      symlink_result = subprocess.run(
        [str(script_path)],
        cwd=ROOT,
        env=symlink_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(symlink_result.returncode, 0)
      self.assertIn(
        "source file qixi-ios-native/Qixi/QixiNativeModelRegistry.swift must not contain symbolic links",
        symlink_result.stderr,
      )

      oversized_root = base / "oversized-source-root"
      oversized_registry = oversized_root / "qixi-ios-native" / "Qixi" / "QixiNativeModelRegistry.swift"
      oversized_registry.parent.mkdir(parents=True)
      write_sparse_file(oversized_registry, 4 * 1024 * 1024 + 1)
      oversized_env = {
        **os.environ,
        "QIXI_NATIVE_MODEL_PREFLIGHT_TESTING": "1",
        "QIXI_NATIVE_MODEL_PREFLIGHT_TEST_ROOT": str(oversized_root),
      }
      oversized_result = subprocess.run(
        [str(script_path)],
        cwd=ROOT,
        env=oversized_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(oversized_result.returncode, 0)
      self.assertIn(
        "source file qixi-ios-native/Qixi/QixiNativeModelRegistry.swift exceeds bounded size",
        oversized_result.stderr,
      )

      model_symlink_root = base / "model-symlink-root"
      write_minimal_native_model_preflight_root(model_symlink_root)
      model_target = base / "b6-target.bin.gz"
      model_target.write_bytes(b"tiny model")
      model_path = (
        model_symlink_root
        / "KataGo"
        / "cpp"
        / "tests"
        / "models"
        / "g170-b6c96-s175395328-d26788732.bin.gz"
      )
      model_path.symlink_to(model_target)
      model_symlink_env = {
        **os.environ,
        "QIXI_NATIVE_MODEL_PREFLIGHT_TESTING": "1",
        "QIXI_NATIVE_MODEL_PREFLIGHT_TEST_ROOT": str(model_symlink_root),
      }
      model_symlink_result = subprocess.run(
        [str(script_path)],
        cwd=ROOT,
        env=model_symlink_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(model_symlink_result.returncode, 0)
      self.assertIn("b6 model file must not contain symbolic links", model_symlink_result.stderr)

  def test_app_store_preflight_and_privacy_manifest_contract(self) -> None:
    script = read(ROOT / "scripts" / "qixi-appstore-preflight.sh")
    project = read(ROOT / "qixi-ios-native" / "Qixi.xcodeproj" / "project.pbxproj")
    info_path = ROOT / "qixi-ios-native" / "Qixi" / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    native_release_info_path = ROOT / "qixi-ios-native" / "Qixi" / "NativeReleaseInfo.plist"
    native_release_info = plistlib.loads(native_release_info_path.read_bytes())
    privacy_path = ROOT / "qixi-ios-native" / "Qixi" / "PrivacyInfo.xcprivacy"
    privacy = plistlib.loads(privacy_path.read_bytes())
    app_store_doc = read(ROOT / "docs" / "app-store-readiness.md")

    for token in (
      "PrivacyInfo.xcprivacy",
      "NSPrivacyTracking",
      "NSPrivacyAccessedAPICategoryUserDefaults",
      "CA92.1",
      "NSCameraUsageDescription",
      "NSPhotoLibraryUsageDescription",
      "NSLocalNetworkUsageDescription",
      "NSAllowsLocalNetworking",
      "NSAllowsArbitraryLoads",
      "ITSAppUsesNonExemptEncryption",
      "iCloud.com.qixi.localanalysis",
      "TARGETED_DEVICE_FAMILY",
      "CADisableMinimumFrameDurationOnPhone",
      "QIXI_APPSTORE_SUBMISSION",
      "NATIVE_RELEASE_INFO",
      "ACTIVE_INFO",
      "QIXI_APPSTORE_PREFLIGHT_TEST_ROOT",
      "APPSTORE_SOURCE_TEXT_MAX_BYTES",
      "APPSTORE_PLIST_MAX_BYTES",
      "_bounded_bytes",
      "_bounded_text",
      "_opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "must be a regular file after opening",
      "after opening",
      "QIXI_APPSTORE_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR",
      "_selftest_opened_descriptor_recheck",
      "_validate_regular_file",
      "_reject_symlink_components",
      "_is_allowed_platform_symlink_alias",
      "_guarded_by_native_disabled_block",
      "_factory_uses_linked_engine_when_native_enabled",
      "_xcbuild_configuration_blocks",
      "_target_xcbuild_configuration_blocks",
      "_native_release_swift_scope_blockers",
      "handle.read(max_bytes + 1)",
      "must not contain symbolic links",
      "exceeds bounded size",
      "submission mode requires QixiAnalysisRuntime=nativeInProcess",
      "submission mode requires the real iOS NativeKataGoEngine adapter",
      "submission mode requires NativeRelease to define QIXI_ENABLE_NATIVE_KATAGO=1",
      "requires NativeRelease target to define Swift condition QIXI_NATIVE_RELEASE",
      "requires NativeRelease target OTHER_SWIFT_FLAGS to pass -D QIXI_NATIVE_RELEASE",
      "requires NativeRelease target to exclude development HTTP bridge source files",
      "target build settings to stay off QIXI_NATIVE_RELEASE",
      "submission mode requires PlaceholderNativeKataGoEngine to be excluded by #if !QIXI_ENABLE_NATIVE_KATAGO",
      "submission mode must construct LinkedNativeKataGoEngine when QIXI_ENABLE_NATIVE_KATAGO=1",
      "development preflight expects QixiAnalysisRuntime=httpBridge",
      "development preflight expected the placeholder native engine marker to be explicit",
    ):
      self.assertIn(token, script)
    self.assertNotIn(".read_text(", script)
    self.assertNotIn(".read_bytes()", script)

    self.assertIn("PrivacyInfo.xcprivacy in Resources", project)
    self.assertIn("NativeReleaseInfo.plist", project)
    self.assertIn("NativeRelease", project)
    self.assertIn("QIXI_ENABLE_NATIVE_KATAGO=1", project)
    self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS = QIXI_NATIVE_RELEASE;", project)
    self.assertIn("OTHER_SWIFT_FLAGS", project)
    self.assertIn("-D", project)
    self.assertIn("QIXI_NATIVE_RELEASE", project)
    self.assertIn("EXCLUDED_SOURCE_FILE_NAMES", project)
    self.assertIn("BackendClient.swift", project)
    self.assertIn("QixiHTTPBridgeAnalysisService.swift", project)
    self.assertIn("QIXI_KATAGO_IOS_LIBRARY", project)
    self.assertIn("QIXI_KATAGO_IOS_XCFRAMEWORK", project)
    self.assertIn("KATAGO_CPP_INCLUDE_DIR", project)
    self.assertIn("Metal.framework in Frameworks", project)
    self.assertIn("Accelerate.framework in Frameworks", project)
    self.assertIn("CoreML.framework in Frameworks", project)
    self.assertIn("MetalPerformanceShaders.framework in Frameworks", project)
    self.assertIn("MetalPerformanceShadersGraph.framework in Frameworks", project)
    self.assertIn("-lKataGoSwift", project)
    self.assertIn("-lz", project)
    self.assertIn("TARGETED_DEVICE_FAMILY = \"1,2\";", project)
    self.assertIn("SUPPORTS_MACCATALYST = NO;", project)
    self.assertIn("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;", project)
    self.assertIs(info["ITSAppUsesNonExemptEncryption"], False)
    self.assertEqual(info["QixiAnalysisRuntime"], "httpBridge")
    self.assertEqual(info["QixiBackendBaseURL"], "http://127.0.0.1:8765")
    self.assertEqual(native_release_info["QixiAnalysisRuntime"], "nativeInProcess")
    self.assertNotIn("QixiBackendBaseURL", native_release_info)
    self.assertIs(native_release_info["ITSAppUsesNonExemptEncryption"], False)
    self.assertIs(privacy["NSPrivacyTracking"], False)
    self.assertEqual(privacy["NSPrivacyTrackingDomains"], [])
    self.assertEqual(privacy["NSPrivacyCollectedDataTypes"], [])
    api_entries = {
      entry["NSPrivacyAccessedAPIType"]: set(entry["NSPrivacyAccessedAPITypeReasons"])
      for entry in privacy["NSPrivacyAccessedAPITypes"]
    }
    self.assertIn("CA92.1", api_entries["NSPrivacyAccessedAPICategoryUserDefaults"])

    for token in (
      "privacy-manifest-files",
      "adding-a-privacy-manifest-to-your-app-or-third-party-sdk",
      "tn3183-adding-required-reason-api-entries",
      "scripts/qixi-appstore-preflight.sh",
      "scripts/qixi-appstore-archive-preflight.sh",
      "ITSAppUsesNonExemptEncryption",
      "non-exempt encryption",
      "Submission Blockers Still Open",
      "QIXI_APPSTORE_SUBMISSION=1",
      "fully in-process KataGo execution on a physical iPad",
      "placeholder native engine",
      "real-device evidence",
      "machine-checkable JSON",
      "scripts/qixi-real-device-evidence-preflight.sh",
      "QIXI_REAL_DEVICE_EVIDENCE",
      "QIXI_APPSTORE_ARCHIVE_PATH",
      "scripts/qixi-native-linked-build-preflight.sh",
      "symbolic-link path components",
      "bounded local file-size guards",
      "rechecks opened descriptors with `fstat`",
      "temporary root override",
      "explicit test-mode",
      "reject dummy",
      "initializeNNEvaluator",
      "restorePersistentMCTSTombstone",
    ):
      self.assertIn(token, app_store_doc)

  def test_app_store_preflight_rejects_symlink_and_oversized_inputs_before_loading(self) -> None:
    script = ROOT / "scripts" / "qixi-appstore-preflight.sh"

    unguarded_descriptor_env = {
      **os.environ,
      "QIXI_APPSTORE_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR": "1",
    }
    unguarded_descriptor_result = subprocess.run(
      [str(script)],
      cwd=ROOT,
      env=unguarded_descriptor_env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(unguarded_descriptor_result.returncode, 0)
    self.assertIn(
      "QIXI_APPSTORE_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR may only be used with QIXI_APPSTORE_PREFLIGHT_TESTING=1",
      unguarded_descriptor_result.stderr,
    )

    descriptor_env = {
      **os.environ,
      "QIXI_APPSTORE_PREFLIGHT_TESTING": "1",
      "QIXI_APPSTORE_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR": "1",
    }
    descriptor_result = subprocess.run(
      [str(script)],
      cwd=ROOT,
      env=descriptor_env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(descriptor_result.returncode, 0)
    self.assertIn("Info.plist must be a regular file after opening", descriptor_result.stderr)
    self.assertNotIn("App Store development preflight passed", descriptor_result.stdout)

    with tempfile.TemporaryDirectory() as tmpdir:
      fixture_root = pathlib.Path(tmpdir) / "valid-root"
      write_minimal_appstore_preflight_root(fixture_root)
      env = {
        **os.environ,
        "QIXI_APPSTORE_PREFLIGHT_TESTING": "1",
        "QIXI_APPSTORE_PREFLIGHT_TEST_ROOT": str(fixture_root),
      }
      valid_result = subprocess.run(
        [str(script)],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertEqual(valid_result.returncode, 0, valid_result.stderr)
      self.assertIn("App Store preflight passed", valid_result.stdout)

      symlink_root = pathlib.Path(tmpdir) / "symlink-root"
      write_minimal_appstore_preflight_root(symlink_root)
      project = symlink_root / "qixi-ios-native" / "Qixi.xcodeproj" / "project.pbxproj"
      target = symlink_root / "qixi-ios-native" / "Qixi.xcodeproj" / "project-target.pbxproj"
      target.write_text(project.read_text(encoding="utf-8"), encoding="utf-8")
      project.unlink()
      try:
        project.symlink_to(target)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")
      symlink_env = {
        **os.environ,
        "QIXI_APPSTORE_PREFLIGHT_TESTING": "1",
        "QIXI_APPSTORE_PREFLIGHT_TEST_ROOT": str(symlink_root),
      }
      symlink_result = subprocess.run(
        [str(script)],
        cwd=ROOT,
        env=symlink_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(symlink_result.returncode, 0)
      self.assertIn("project file must not contain symbolic links", symlink_result.stderr)

      oversized_plist_root = pathlib.Path(tmpdir) / "oversized-plist-root"
      write_minimal_appstore_preflight_root(oversized_plist_root)
      write_sparse_file(
        oversized_plist_root / "qixi-ios-native" / "Qixi" / "Info.plist",
        1 * 1024 * 1024 + 1,
      )
      oversized_plist_env = {
        **os.environ,
        "QIXI_APPSTORE_PREFLIGHT_TESTING": "1",
        "QIXI_APPSTORE_PREFLIGHT_TEST_ROOT": str(oversized_plist_root),
      }
      oversized_plist_result = subprocess.run(
        [str(script)],
        cwd=ROOT,
        env=oversized_plist_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(oversized_plist_result.returncode, 0)
      self.assertIn("Info.plist exceeds bounded size", oversized_plist_result.stderr)

      oversized_source_root = pathlib.Path(tmpdir) / "oversized-source-root"
      write_minimal_appstore_preflight_root(oversized_source_root)
      write_sparse_file(
        oversized_source_root / "qixi-ios-native" / "Qixi" / "Huge.swift",
        4 * 1024 * 1024 + 1,
      )
      oversized_source_env = {
        **os.environ,
        "QIXI_APPSTORE_PREFLIGHT_TESTING": "1",
        "QIXI_APPSTORE_PREFLIGHT_TEST_ROOT": str(oversized_source_root),
      }
      oversized_source_result = subprocess.run(
        [str(script)],
        cwd=ROOT,
        env=oversized_source_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(oversized_source_result.returncode, 0)
      self.assertIn("Swift source Huge.swift exceeds bounded size", oversized_source_result.stderr)

  def test_submission_preflight_accepts_guarded_placeholder_and_rejects_release_placeholder_leak(self) -> None:
    env = os.environ.copy()
    env["QIXI_APPSTORE_SUBMISSION"] = "1"
    result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-appstore-preflight.sh")],
      cwd=ROOT,
      env=env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertIn("App Store submission preflight passed", result.stdout)

    with tempfile.TemporaryDirectory() as tmpdir:
      fixture_root = pathlib.Path(tmpdir) / "unguarded-placeholder-root"
      write_minimal_appstore_preflight_root(fixture_root)
      engine_path = fixture_root / "qixi-ios-native" / "Qixi" / "QixiNativeKataGoEngine.cpp"
      engine_path.write_text(
        """
class LinkedNativeKataGoEngine final {};
class PlaceholderNativeKataGoEngine final {};
const char *diagnostic = "Native KataGo is not linked into this build.";
auto factory() {
  return std::make_unique<PlaceholderNativeKataGoEngine>();
}
""",
        encoding="utf-8",
      )
      leak_env = {
        **os.environ,
        "QIXI_APPSTORE_SUBMISSION": "1",
        "QIXI_APPSTORE_PREFLIGHT_TESTING": "1",
        "QIXI_APPSTORE_PREFLIGHT_TEST_ROOT": str(fixture_root),
      }
      leak_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-preflight.sh")],
        cwd=ROOT,
        env=leak_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(leak_result.returncode, 0)
      self.assertIn("App Store preflight failed:", leak_result.stderr)
      for token in (
        "submission mode blockers remain",
        "submission mode requires PlaceholderNativeKataGoEngine to be excluded by #if !QIXI_ENABLE_NATIVE_KATAGO",
        "submission mode requires the libraryNotLinked placeholder diagnostic to be excluded by #if !QIXI_ENABLE_NATIVE_KATAGO",
        "submission mode must construct LinkedNativeKataGoEngine when QIXI_ENABLE_NATIVE_KATAGO=1",
      ):
        self.assertIn(token, leak_result.stderr)
      self.assertNotIn("submission mode requires QixiAnalysisRuntime=nativeInProcess", leak_result.stderr)
      self.assertNotIn("submission mode must not ship a default Mac-hosted backend URL", leak_result.stderr)

      release_scope_root = pathlib.Path(tmpdir) / "release-scope-root"
      write_minimal_appstore_preflight_root(release_scope_root)
      project_path = release_scope_root / "qixi-ios-native" / "Qixi.xcodeproj" / "project.pbxproj"
      project_text = project_path.read_text(encoding="utf-8")
      project_text = re.sub(
        r"(100000000000000000000B02 /\* Release \*/ = \{.*?SWIFT_OBJC_BRIDGING_HEADER = \"Qixi/Qixi-Bridging-Header\.h\";)",
        "\\1\n    SWIFT_ACTIVE_COMPILATION_CONDITIONS = QIXI_NATIVE_RELEASE;",
        project_text,
        count=1,
        flags=re.DOTALL,
      )
      project_path.write_text(project_text, encoding="utf-8")
      release_scope_env = {
        **os.environ,
        "QIXI_APPSTORE_SUBMISSION": "1",
        "QIXI_APPSTORE_PREFLIGHT_TESTING": "1",
        "QIXI_APPSTORE_PREFLIGHT_TEST_ROOT": str(release_scope_root),
      }
      release_scope_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-preflight.sh")],
        cwd=ROOT,
        env=release_scope_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(release_scope_result.returncode, 0)
      self.assertIn("submission mode blockers remain", release_scope_result.stderr)
      self.assertIn(
        "submission mode requires Release target build settings to stay off QIXI_NATIVE_RELEASE",
        release_scope_result.stderr,
      )
      self.assertNotIn(
        "submission mode requires NativeRelease target to define Swift condition QIXI_NATIVE_RELEASE",
        release_scope_result.stderr,
      )

  def test_appstore_archive_preflight_requires_release_archive_artifact(self) -> None:
    script = read(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")
    for token in (
      "QIXI_APPSTORE_ARCHIVE_PATH",
      "QIXI_REQUIRE_APPSTORE_DISTRIBUTION_SIGNATURE",
      ".xcarchive",
      "ApplicationProperties",
      "ArchiveVersion",
      "CreationDate",
      "SchemeName",
      "ApplicationPath",
      "ApplicationProperties.CFBundleShortVersionString",
      "ApplicationProperties.CFBundleVersion",
      "ApplicationProperties.SigningIdentity",
      "ApplicationProperties.Team",
      "Products/Applications",
      "Qixi.app",
      "PrivacyInfo.xcprivacy",
      "ApplicationProperties.CFBundleIdentifier",
      "CFBundleExecutable",
      "_CodeSignature",
      "codesign",
      "--verify",
      "--deep",
      "--strict",
      "archive app code signature must verify",
      "Signature=adhoc",
      "TeamIdentifier=not set",
      "Apple Distribution",
      "iPhone Distribution",
      "signed entitlements",
      "com.apple.developer.icloud-container-identifiers",
      "com.apple.developer.ubiquity-container-identifiers",
      "com.apple.developer.icloud-services",
      "application-identifier",
      "com.apple.developer.team-identifier",
      "get-task-allow",
      "CPU_TYPE_ARM64",
      "MH_EXECUTE",
      "LC_BUILD_VERSION",
      "PLATFORM_IOS",
      "DTPlatformName",
      "DTSDKName",
      "CFBundleDisplayName",
      "CFBundleShortVersionString",
      "CFBundleSupportedPlatforms",
      "CFBundleVersion",
      "UIDeviceFamily",
      "MinimumOSVersion",
      "NSCameraUsageDescription",
      "NSPhotoLibraryUsageDescription",
      "NSLocalNetworkUsageDescription",
      "NSAllowsLocalNetworking",
      "NSAllowsArbitraryLoads",
      "ITSAppUsesNonExemptEncryption",
      "CADisableMinimumFrameDurationOnPhone",
      "NSPrivacyTrackingDomains",
      "NSPrivacyAccessedAPITypes",
      "NSPrivacyAccessedAPICategoryUserDefaults",
      "CA92.1",
      "Mach-O",
      "QixiAnalysisRuntime",
      "nativeInProcess",
      "QixiBackendBaseURL",
      "NSPrivacyTracking=false",
      "ARCHIVE_PLIST_MAX_BYTES",
      "ARCHIVE_EXECUTABLE_MAX_BYTES",
      "ARCHIVE_FORBIDDEN_EXECUTABLE_STRINGS",
      "Native KataGo is not linked into this build.",
      "PlaceholderNativeKataGoEngine",
      "BackendClient",
      "HTTPBridgeAnalysisService",
      "Qixi HTTP bridge response",
      "QIXI_BACKEND_URL",
      "QIXI_ANALYSIS_RUNTIME",
      "qixi.backendBaseURL",
      "QIXI_DEVICE_BACKEND_URL",
      "http://127.0.0.1:8765",
      "archive app executable must not contain development bridge or placeholder string",
      "_bounded_bytes",
      "_opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "must be a regular file after opening",
      "after opening",
      "QIXI_APPSTORE_ARCHIVE_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR",
      "_selftest_opened_descriptor_recheck",
      "_validate_regular_file",
      "_validate_directory",
      "_reject_symlink_components",
      "_is_allowed_platform_symlink_alias",
      "handle.read(max_bytes + 1)",
      "must not contain symbolic links",
      "must not traverse outside Products",
      "App Store archive preflight passed",
    ):
      self.assertIn(token, script)
    self.assertNotIn("path.read_bytes()", script)

    missing_result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
      cwd=ROOT,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(missing_result.returncode, 0)
    self.assertIn("QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive is required", missing_result.stderr)

    descriptor_recheck_env = {
      **os.environ,
      "QIXI_APPSTORE_ARCHIVE_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR": "1",
    }
    descriptor_recheck_result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
      cwd=ROOT,
      env=descriptor_recheck_env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(descriptor_recheck_result.returncode, 0)
    self.assertIn(
      "archive plist must be a regular file after opening",
      descriptor_recheck_result.stderr,
    )
    self.assertNotIn(
      "QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive is required",
      descriptor_recheck_result.stderr,
    )

    with tempfile.TemporaryDirectory() as tmpdir:
      archive = write_minimal_appstore_archive(pathlib.Path(tmpdir))
      env = {**os.environ, "QIXI_APPSTORE_ARCHIVE_PATH": str(archive)}
      valid_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertEqual(valid_result.returncode, 0, valid_result.stderr)
      self.assertIn("App Store archive preflight passed", valid_result.stdout)

      linked_archive = pathlib.Path(tmpdir) / "linked-Qixi.xcarchive"
      linked_archive.symlink_to(archive, target_is_directory=True)
      linked_archive_env = {**os.environ, "QIXI_APPSTORE_ARCHIVE_PATH": str(linked_archive)}
      linked_archive_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=linked_archive_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(linked_archive_result.returncode, 0)
      self.assertIn("QIXI_APPSTORE_ARCHIVE_PATH must not contain symbolic links", linked_archive_result.stderr)

      linked_app_archive = pathlib.Path(tmpdir) / "linked-app.xcarchive"
      shutil.copytree(archive, linked_app_archive)
      linked_app = linked_app_archive / "Products" / "Applications" / "Qixi.app"
      linked_app_target = linked_app_archive / "Products" / "Applications" / "Qixi-target.app"
      linked_app.rename(linked_app_target)
      linked_app.symlink_to(linked_app_target, target_is_directory=True)
      linked_app_env = {**os.environ, "QIXI_APPSTORE_ARCHIVE_PATH": str(linked_app_archive)}
      linked_app_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=linked_app_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(linked_app_result.returncode, 0)
      self.assertIn("archive application bundle must not contain symbolic links", linked_app_result.stderr)

      escaped_application_path_archive = pathlib.Path(tmpdir) / "escaped-application-path.xcarchive"
      shutil.copytree(archive, escaped_application_path_archive)
      escaped_archive_info_path = escaped_application_path_archive / "Info.plist"
      escaped_archive_info = plistlib.loads(escaped_archive_info_path.read_bytes())
      escaped_archive_info["ApplicationProperties"]["ApplicationPath"] = "../Escaped.app"
      with escaped_archive_info_path.open("wb") as plist_file:
        plistlib.dump(escaped_archive_info, plist_file)
      escaped_application_path_env = {
        **os.environ,
        "QIXI_APPSTORE_ARCHIVE_PATH": str(escaped_application_path_archive),
      }
      escaped_application_path_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=escaped_application_path_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(escaped_application_path_result.returncode, 0)
      self.assertIn("ApplicationPath must not traverse outside Products", escaped_application_path_result.stderr)

      oversized_plist_archive = pathlib.Path(tmpdir) / "oversized-plist.xcarchive"
      shutil.copytree(archive, oversized_plist_archive)
      write_sparse_file(oversized_plist_archive / "Info.plist", 1 * 1024 * 1024 + 1)
      oversized_plist_env = {**os.environ, "QIXI_APPSTORE_ARCHIVE_PATH": str(oversized_plist_archive)}
      oversized_plist_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=oversized_plist_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(oversized_plist_result.returncode, 0)
      self.assertIn("archive Info.plist exceeds bounded size", oversized_plist_result.stderr)

      oversized_executable_archive = pathlib.Path(tmpdir) / "oversized-executable.xcarchive"
      shutil.copytree(archive, oversized_executable_archive)
      oversized_executable = oversized_executable_archive / "Products" / "Applications" / "Qixi.app" / "Qixi"
      write_sparse_file(oversized_executable, 256 * 1024 * 1024 + 1)
      oversized_executable_env = {**os.environ, "QIXI_APPSTORE_ARCHIVE_PATH": str(oversized_executable_archive)}
      oversized_executable_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=oversized_executable_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(oversized_executable_result.returncode, 0)
      self.assertIn("archive app executable exceeds bounded size", oversized_executable_result.stderr)

      archive_metadata_cases = [
        (
          "archive-version",
          lambda info: info.__setitem__("ArchiveVersion", 1),
          "archive Info.plist ArchiveVersion must be at least 2",
        ),
        (
          "creation-date",
          lambda info: info.__setitem__("CreationDate", "2026-07-04T00:00:00Z"),
          "archive Info.plist CreationDate must be a plist date",
        ),
        (
          "archive-name",
          lambda info: info.__setitem__("Name", ""),
          "archive Info.plist Name must be a non-empty string",
        ),
        (
          "scheme-name",
          lambda info: info.__setitem__("SchemeName", "QixiDev"),
          "archive Info.plist SchemeName must be Qixi",
        ),
        (
          "short-version",
          lambda info: info["ApplicationProperties"].__setitem__("CFBundleShortVersionString", "9.9"),
          "archive app CFBundleShortVersionString must match ApplicationProperties.CFBundleShortVersionString",
        ),
        (
          "build-version",
          lambda info: info["ApplicationProperties"].__setitem__("CFBundleVersion", "2"),
          "archive app CFBundleVersion must match ApplicationProperties.CFBundleVersion",
        ),
        (
          "signing-identity",
          lambda info: info["ApplicationProperties"].__setitem__("SigningIdentity", ""),
          "archive ApplicationProperties.SigningIdentity must be a non-empty string",
        ),
        (
          "team",
          lambda info: info["ApplicationProperties"].__setitem__("Team", ""),
          "archive ApplicationProperties.Team must be a non-empty string",
        ),
      ]
      for case_name, mutate_archive_info, expected_error in archive_metadata_cases:
        with self.subTest(archive_metadata_case=case_name):
          archive_metadata = pathlib.Path(tmpdir) / f"{case_name}.xcarchive"
          shutil.copytree(archive, archive_metadata)
          archive_info_path = archive_metadata / "Info.plist"
          archive_info = plistlib.loads(archive_info_path.read_bytes())
          mutate_archive_info(archive_info)
          with archive_info_path.open("wb") as plist_file:
            plistlib.dump(archive_info, plist_file)
          archive_metadata_env = {**os.environ, "QIXI_APPSTORE_ARCHIVE_PATH": str(archive_metadata)}
          archive_metadata_result = subprocess.run(
            [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
            cwd=ROOT,
            env=archive_metadata_env,
            text=True,
            capture_output=True,
            check=False,
          )
          self.assertNotEqual(archive_metadata_result.returncode, 0)
          self.assertIn(expected_error, archive_metadata_result.stderr)

      strict_env = {
        **os.environ,
        "QIXI_APPSTORE_ARCHIVE_PATH": str(archive),
        "QIXI_REQUIRE_APPSTORE_DISTRIBUTION_SIGNATURE": "1",
      }
      strict_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=strict_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(strict_result.returncode, 0)
      self.assertIn("archive app signature must not be ad-hoc for release evidence", strict_result.stderr)

      entitlement_dir = pathlib.Path(tmpdir) / "entitlement-case"
      entitlement_dir.mkdir()
      entitlement_archive = write_minimal_appstore_archive(entitlement_dir)
      entitlement_app = entitlement_archive / "Products" / "Applications" / "Qixi.app"
      subprocess.run(
        [
          "codesign",
          "--force",
          "--sign",
          "-",
          "--entitlements",
          str(write_minimal_archive_entitlements(entitlement_dir, include_icloud=False)),
          str(entitlement_app),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      entitlement_env = {**os.environ, "QIXI_APPSTORE_ARCHIVE_PATH": str(entitlement_archive)}
      entitlement_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=entitlement_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(entitlement_result.returncode, 0)
      self.assertIn("archive app signed entitlements must include the Qixi iCloud container", entitlement_result.stderr)

      info_dir = pathlib.Path(tmpdir) / "info-case"
      info_dir.mkdir()
      info_archive = write_minimal_appstore_archive(info_dir)
      info_app_path = info_archive / "Products" / "Applications" / "Qixi.app"
      info_plist_path = info_app_path / "Info.plist"
      info_payload = plistlib.loads(info_plist_path.read_bytes())
      info_payload["NSAppTransportSecurity"]["NSAllowsArbitraryLoads"] = True
      with info_plist_path.open("wb") as plist_file:
        plistlib.dump(info_payload, plist_file)
      subprocess.run(
        [
          "codesign",
          "--force",
          "--sign",
          "-",
          "--entitlements",
          str(write_minimal_archive_entitlements(info_dir)),
          str(info_app_path),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      info_env = {**os.environ, "QIXI_APPSTORE_ARCHIVE_PATH": str(info_archive)}
      info_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=info_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(info_result.returncode, 0)
      self.assertIn("archive app Info.plist must not allow arbitrary network loads", info_result.stderr)

      device_family_dir = pathlib.Path(tmpdir) / "device-family-case"
      device_family_dir.mkdir()
      device_family_archive = write_minimal_appstore_archive(device_family_dir)
      device_family_app_path = device_family_archive / "Products" / "Applications" / "Qixi.app"
      device_family_plist_path = device_family_app_path / "Info.plist"
      device_family_payload = plistlib.loads(device_family_plist_path.read_bytes())
      device_family_payload["UIDeviceFamily"] = [1]
      with device_family_plist_path.open("wb") as plist_file:
        plistlib.dump(device_family_payload, plist_file)
      subprocess.run(
        [
          "codesign",
          "--force",
          "--sign",
          "-",
          "--entitlements",
          str(write_minimal_archive_entitlements(device_family_dir)),
          str(device_family_app_path),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      device_family_env = {**os.environ, "QIXI_APPSTORE_ARCHIVE_PATH": str(device_family_archive)}
      device_family_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=device_family_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(device_family_result.returncode, 0)
      self.assertIn("archive app Info.plist UIDeviceFamily must target both iPhone and iPad", device_family_result.stderr)

      privacy_dir = pathlib.Path(tmpdir) / "privacy-case"
      privacy_dir.mkdir()
      privacy_archive = write_minimal_appstore_archive(privacy_dir)
      privacy_app_path = privacy_archive / "Products" / "Applications" / "Qixi.app"
      privacy_plist_path = privacy_app_path / "PrivacyInfo.xcprivacy"
      privacy_payload = plistlib.loads(privacy_plist_path.read_bytes())
      privacy_payload["NSPrivacyAccessedAPITypes"] = []
      with privacy_plist_path.open("wb") as plist_file:
        plistlib.dump(privacy_payload, plist_file)
      subprocess.run(
        [
          "codesign",
          "--force",
          "--sign",
          "-",
          "--entitlements",
          str(write_minimal_archive_entitlements(privacy_dir)),
          str(privacy_app_path),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      privacy_env = {**os.environ, "QIXI_APPSTORE_ARCHIVE_PATH": str(privacy_archive)}
      privacy_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=privacy_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(privacy_result.returncode, 0)
      self.assertIn("archive privacy manifest must declare UserDefaults reason CA92.1", privacy_result.stderr)

      signature_dir = pathlib.Path(tmpdir) / "signature-case"
      signature_dir.mkdir()
      signature_archive = write_minimal_appstore_archive(signature_dir)
      signature_executable = signature_archive / "Products" / "Applications" / "Qixi.app" / "Qixi"
      with signature_executable.open("ab") as executable_file:
        executable_file.write(b"\0")
      signature_env = {**os.environ, "QIXI_APPSTORE_ARCHIVE_PATH": str(signature_archive)}
      signature_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=signature_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(signature_result.returncode, 0)
      self.assertIn("archive app code signature must verify", signature_result.stderr)

      app_info_path = archive / "Products" / "Applications" / "Qixi.app" / "Info.plist"
      app_executable = archive / "Products" / "Applications" / "Qixi.app" / "Qixi"
      app_info = plistlib.loads(app_info_path.read_bytes())
      app_info["DTPlatformName"] = "iphonesimulator"
      with app_info_path.open("wb") as plist_file:
        plistlib.dump(app_info, plist_file)
      simulator_platform_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(simulator_platform_result.returncode, 0)
      self.assertIn("archive app DTPlatformName must be iphoneos", simulator_platform_result.stderr)

      app_info["DTPlatformName"] = "iphoneos"
      with app_info_path.open("wb") as plist_file:
        plistlib.dump(app_info, plist_file)
      app_executable.write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 64)
      fake_header_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(fake_header_result.returncode, 0)
      self.assertIn("Mach-O slice must use CPU_TYPE_ARM64", fake_header_result.stderr)

      app_executable.write_bytes(minimal_arm64_macho_execute(platform=7))
      simulator_binary_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(simulator_binary_result.returncode, 0)
      self.assertIn("Mach-O slice must target the iOS device platform", simulator_binary_result.stderr)

      app_executable.write_bytes(minimal_arm64_macho_execute(filetype=6))
      dylib_binary_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(dylib_binary_result.returncode, 0)
      self.assertIn("Mach-O slice must be MH_EXECUTE", dylib_binary_result.stderr)

      app_executable.write_bytes(b"notmach")
      executable_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(executable_result.returncode, 0)
      self.assertIn("archive app executable must be a Mach-O binary", executable_result.stderr)

      app_executable.write_bytes(
        minimal_arm64_macho_execute() +
        b"\0Native KataGo is not linked into this build.\0"
      )
      forbidden_string_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(forbidden_string_result.returncode, 0)
      self.assertIn(
        "archive app executable must not contain development bridge or placeholder string: Native KataGo is not linked into this build.",
        forbidden_string_result.stderr,
      )
      self.assertNotIn("archive app code signature must verify", forbidden_string_result.stderr)

      app_executable.write_bytes(
        minimal_arm64_macho_execute() +
        b"\0BackendClient\0HTTPBridgeAnalysisService\0"
      )
      bridge_forbidden_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(bridge_forbidden_result.returncode, 0)
      self.assertIn(
        "archive app executable must not contain development bridge or placeholder string: BackendClient",
        bridge_forbidden_result.stderr,
      )
      self.assertNotIn("archive app code signature must verify", bridge_forbidden_result.stderr)

      app_executable.write_bytes(minimal_arm64_macho_execute())
      app_info["QixiBackendBaseURL"] = "http://127.0.0.1:8765"
      with app_info_path.open("wb") as plist_file:
        plistlib.dump(app_info, plist_file)
      backend_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-appstore-archive-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(backend_result.returncode, 0)
      self.assertIn("archive app must not ship QixiBackendBaseURL", backend_result.stderr)

  def test_native_linked_build_preflight_blocks_unlinked_release_settings(self) -> None:
    script = read(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")

    for token in (
      "QIXI_ENABLE_NATIVE_KATAGO=1",
      "QIXI_NATIVE_RELEASE",
      "SWIFT_ACTIVE_COMPILATION_CONDITIONS = QIXI_NATIVE_RELEASE;",
      "OTHER_SWIFT_FLAGS",
      "-D",
      "qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh",
      "QIXI_KATAGO_IOS_XCFRAMEWORK",
      "QIXI_KATAGO_IOS_LIBRARY",
      "QIXI_KATAGO_IOS_LIBRARY_DIR",
      "libKataGoSwift.a",
      "QIXI_NATIVE_LINKED_INFO_PLIST",
      "QIXI_NATIVE_LINKED_PREFLIGHT_TESTING",
      "QIXI_NATIVE_LINKED_PREFLIGHT_REPORT",
      "write_report",
      "_prepare_report_output_path",
      "_report_path_symlink_errors",
      "os.O_EXCL",
      "os.O_NOFOLLOW",
      "os.fsync",
      "os.replace",
      "qixi-native-linked-build-preflight",
      "generatedAt",
      "blockers",
      "_absolute_env_path",
      "must be an absolute path",
      "release evidence must set exactly one of QIXI_KATAGO_IOS_XCFRAMEWORK or QIXI_KATAGO_IOS_LIBRARY, not both",
      "KATAGO_CPP_INCLUDE_DIR",
      "KATAGO_IOS_LIBRARY",
      "KATAGO_IOS_XCFRAMEWORK",
      "Metal.framework",
      "Accelerate.framework",
      "CoreML.framework",
      "MetalPerformanceShaders.framework",
      "MetalPerformanceShadersGraph.framework",
      "-lKataGoSwift",
      "-lz",
      "QixiBackendBaseURL",
      "AvailableLibraries",
      "SupportedPlatform",
      "SupportedPlatformVariant",
      "SupportedArchitectures",
      "LibraryIdentifier",
      "LibraryPath",
      "must contain an iOS device arm64 slice",
      "must reference an existing library or framework",
      "lipo",
      "otool",
      "LC_VERSION_MIN_IPHONEOS",
      "platform 2",
      "IOS_DEVICE_PLATFORM_VALUES",
      "platform_values",
      "unexpected_platforms",
      "must contain an arm64 iOS device architecture",
      "must target the iOS device platform, not macOS or iOS Simulator",
      "must not contain non-iOS platform object files",
      "linked native release builds must default QixiAnalysisRuntime to nativeInProcess",
      "Qixi NativeRelease target must define Swift condition QIXI_NATIVE_RELEASE",
      "Qixi NativeRelease target must pass -D QIXI_NATIVE_RELEASE through OTHER_SWIFT_FLAGS",
      "Qixi NativeRelease target must exclude development HTTP bridge source files from compilation",
      "target must not define QIXI_NATIVE_RELEASE",
      "KATAGO_REQUIRED_SYMBOL_FRAGMENTS",
      "KATAGO_MIN_DEFINED_SYMBOLS",
      "KATAGO_MIN_KATAGO_LIKE_SYMBOLS",
      "KATAGO_LIKE_SYMBOL_FRAGMENTS",
      "KATAGO_SWIFT_REQUIRED_SYMBOL_FRAGMENTS",
      "KATAGO_SWIFT_MIN_DEFINED_SYMBOLS",
      "validate_swift_sidecar_for_core_library",
      "does not look like the KataGo Swift Metal sidecar",
      "does not expose enough defined Swift symbols",
      "c++filt",
      "AsyncBot",
      "BoardHistory",
      "NNEvaluator",
      "Search",
      "initializeNNEvaluator",
      "loadSingleParams",
      "setPositionForMCTSPersistence",
      "runWholeSearch",
      "getAnalysisJson",
      "getAverageTreeOwnership",
      "exportPersistentMCTS",
      "restorePersistentMCTSTombstone",
      "validation requires nm or xcrun",
      "does not look like a real KataGo iOS library",
      "does not expose enough defined symbols",
      "does not expose enough KataGo-like C++ symbols",
      "release_info_plist_path",
      "may only be used with",
      "SOURCE_TEXT_MAX_BYTES",
      "PLIST_MAX_BYTES",
      "_bounded_bytes",
      "_bounded_text",
      "_opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "must be a regular file after opening",
      "after opening",
      "QIXI_NATIVE_LINKED_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR",
      "_selftest_opened_descriptor_recheck",
      "_validate_regular_file",
      "_validate_directory",
      "_reject_symlink_components",
      "_is_allowed_platform_symlink_alias",
      "_xcframework_relative_path",
      "_xcbuild_configuration_blocks",
      "_target_xcbuild_configuration_blocks",
      "_native_release_swift_scope_blockers",
      "handle.read(max_bytes + 1)",
      "must not contain symbolic links",
      "must not traverse outside the XCFramework",
      "could not read plist",
      "could not read file",
      "class LinkedNativeKataGoEngine final",
      "std::make_unique<LinkedNativeKataGoEngine>()",
      "Native linked build preflight passed",
    ):
      self.assertIn(token, script)
    self.assertNotIn("path.read_text(encoding=\"utf-8\")", script)
    self.assertNotIn("path.read_bytes()", script)
    self.assertLess(
      script.index("blockers: list[str] = []"),
      script.index("info = load_plist(release_info_plist_path(), \"release Info.plist\")"),
    )

    unguarded_descriptor_env = os.environ.copy()
    unguarded_descriptor_env["QIXI_NATIVE_LINKED_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR"] = "1"
    unguarded_descriptor_result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
      cwd=ROOT,
      env=unguarded_descriptor_env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(unguarded_descriptor_result.returncode, 0)
    self.assertIn(
      "QIXI_NATIVE_LINKED_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR may only be used with QIXI_NATIVE_LINKED_PREFLIGHT_TESTING=1",
      unguarded_descriptor_result.stderr,
    )
    self.assertNotIn("Native KataGo adapter compile probe passed", unguarded_descriptor_result.stdout)

    descriptor_env = os.environ.copy()
    descriptor_env["QIXI_NATIVE_LINKED_PREFLIGHT_TESTING"] = "1"
    descriptor_env["QIXI_NATIVE_LINKED_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR"] = "1"
    descriptor_result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
      cwd=ROOT,
      env=descriptor_env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(descriptor_result.returncode, 0)
    self.assertIn("Native linked build preflight failed:", descriptor_result.stderr)
    self.assertIn("release Info.plist must be a regular file after opening", descriptor_result.stderr)
    self.assertNotIn("Native KataGo adapter compile probe passed", descriptor_result.stdout)

    result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
      cwd=ROOT,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("Native linked build preflight failed:", result.stderr)
    for token in (
      "release evidence must set QIXI_KATAGO_IOS_XCFRAMEWORK",
    ):
      self.assertIn(token, result.stderr)
    for token in (
      "Qixi Xcode target must define QIXI_ENABLE_NATIVE_KATAGO=1",
      "Qixi NativeRelease target must define Swift condition QIXI_NATIVE_RELEASE",
      "Qixi NativeRelease target must pass -D QIXI_NATIVE_RELEASE through OTHER_SWIFT_FLAGS",
      "Qixi NativeRelease target must exclude development HTTP bridge source files from compilation",
      "Qixi Debug target must not define QIXI_NATIVE_RELEASE",
      "Qixi Release target must not define QIXI_NATIVE_RELEASE",
      "linked native release builds must default QixiAnalysisRuntime to nativeInProcess",
      "Qixi Xcode target must link a real iOS KataGo library or XCFramework",
      "Qixi Xcode target must link Metal.framework",
      "Qixi Xcode target must link Accelerate.framework",
      "linked native release builds must not ship the default Mac-hosted backend URL",
    ):
      self.assertNotIn(token, result.stderr)

    with tempfile.TemporaryDirectory() as tmpdir:
      report_path = pathlib.Path(tmpdir) / "native-linked-report.json"
      report_env = os.environ.copy()
      report_env["QIXI_NATIVE_LINKED_PREFLIGHT_REPORT"] = str(report_path)
      report_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=report_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(report_result.returncode, 0)
      self.assertTrue(report_path.is_file())
      report = json.loads(report_path.read_text(encoding="utf-8"))
      self.assertEqual(report["schemaVersion"], 1)
      self.assertEqual(report["kind"], "qixi-native-linked-build-preflight")
      self.assertEqual(report["status"], "failed")
      self.assertRegex(report["generatedAt"], r"^\d{4}-\d{2}-\d{2}T")
      self.assertIn("inputs", report)
      self.assertIn("blockers", report)
      self.assertIn(
        "release evidence must set QIXI_KATAGO_IOS_XCFRAMEWORK=<path> or QIXI_KATAGO_IOS_LIBRARY=<path> to a real built iOS KataGo artifact",
        report["blockers"],
      )
      self.assertEqual(
        report["blockers"],
        [
          "release evidence must set QIXI_KATAGO_IOS_XCFRAMEWORK=<path> or QIXI_KATAGO_IOS_LIBRARY=<path> to a real built iOS KataGo artifact"
        ],
      )

      report_target = pathlib.Path(tmpdir) / "native-linked-report-target.json"
      symlink_report = pathlib.Path(tmpdir) / "native-linked-report-link.json"
      try:
        symlink_report.symlink_to(report_target)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")
      symlink_report_env = os.environ.copy()
      symlink_report_env["QIXI_NATIVE_LINKED_PREFLIGHT_REPORT"] = str(symlink_report)
      symlink_report_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=symlink_report_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(symlink_report_result.returncode, 0)
      self.assertIn(
        "QIXI_NATIVE_LINKED_PREFLIGHT_REPORT must not contain symbolic links",
        symlink_report_result.stderr,
      )
      self.assertFalse(report_target.exists())

      real_report_parent = pathlib.Path(tmpdir) / "real-report-parent"
      real_report_parent.mkdir()
      linked_report_parent = pathlib.Path(tmpdir) / "linked-report-parent"
      linked_report_parent.symlink_to(real_report_parent, target_is_directory=True)
      linked_parent_env = os.environ.copy()
      linked_parent_env["QIXI_NATIVE_LINKED_PREFLIGHT_REPORT"] = str(
        linked_report_parent / "native-linked-report.json"
      )
      linked_parent_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=linked_parent_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(linked_parent_result.returncode, 0)
      self.assertIn(
        "QIXI_NATIVE_LINKED_PREFLIGHT_REPORT must not contain symbolic links",
        linked_parent_result.stderr,
      )
      self.assertFalse((real_report_parent / "native-linked-report.json").exists())

      directory_report = pathlib.Path(tmpdir) / "directory-shaped-report.json"
      directory_report.mkdir()
      directory_report_env = os.environ.copy()
      directory_report_env["QIXI_NATIVE_LINKED_PREFLIGHT_REPORT"] = str(directory_report)
      directory_report_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=directory_report_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(directory_report_result.returncode, 0)
      self.assertIn(
        "QIXI_NATIVE_LINKED_PREFLIGHT_REPORT is not a regular file",
        directory_report_result.stderr,
      )

      bad_info = pathlib.Path(tmpdir) / "not-a-plist.plist"
      bad_info.write_text("this is not a plist\n", encoding="utf-8")
      guarded_env = os.environ.copy()
      guarded_env["QIXI_NATIVE_LINKED_INFO_PLIST"] = str(bad_info)
      guarded_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=guarded_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(guarded_result.returncode, 0)
      self.assertIn(
        "QIXI_NATIVE_LINKED_INFO_PLIST may only be used with QIXI_NATIVE_LINKED_PREFLIGHT_TESTING=1",
        guarded_result.stderr,
      )
      self.assertNotIn(f"could not read plist {bad_info}", guarded_result.stderr)
      self.assertNotIn("Traceback", guarded_result.stderr)

      testing_env = guarded_env.copy()
      testing_env["QIXI_NATIVE_LINKED_PREFLIGHT_TESTING"] = "1"
      malformed_info_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=testing_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(malformed_info_result.returncode, 0)
      self.assertIn("Native linked build preflight failed:", malformed_info_result.stderr)
      self.assertIn(f"could not read plist {bad_info}", malformed_info_result.stderr)
      self.assertNotIn("Traceback", malformed_info_result.stderr)
      self.assertNotIn("NameError", malformed_info_result.stderr)

      fake_xcframework = pathlib.Path(tmpdir) / "KataGo.xcframework"
      fake_xcframework.mkdir()
      env = os.environ.copy()
      env["QIXI_KATAGO_IOS_XCFRAMEWORK"] = str(fake_xcframework)
      relative_xcframework_env = os.environ.copy()
      relative_xcframework_env["QIXI_KATAGO_IOS_XCFRAMEWORK"] = "relative/KataGo.xcframework"
      relative_xcframework_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=relative_xcframework_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(relative_xcframework_result.returncode, 0)
      self.assertIn(
        "QIXI_KATAGO_IOS_XCFRAMEWORK must be an absolute path",
        relative_xcframework_result.stderr,
      )

      relative_library_env = os.environ.copy()
      relative_library_env["QIXI_KATAGO_IOS_LIBRARY"] = "relative/libkatago.a"
      relative_library_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=relative_library_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(relative_library_result.returncode, 0)
      self.assertIn(
        "QIXI_KATAGO_IOS_LIBRARY must be an absolute path",
        relative_library_result.stderr,
      )

      both_library = pathlib.Path(tmpdir) / "libkatago_both.a"
      both_library.write_bytes(b"not a real static library")
      both_env = os.environ.copy()
      both_env["QIXI_KATAGO_IOS_XCFRAMEWORK"] = str(fake_xcframework)
      both_env["QIXI_KATAGO_IOS_LIBRARY"] = str(both_library)
      both_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=both_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(both_result.returncode, 0)
      self.assertIn(
        "release evidence must set exactly one of QIXI_KATAGO_IOS_XCFRAMEWORK or QIXI_KATAGO_IOS_LIBRARY, not both",
        both_result.stderr,
      )

      linked_xcframework = pathlib.Path(tmpdir) / "LinkedKataGo.xcframework"
      linked_xcframework.symlink_to(fake_xcframework, target_is_directory=True)
      linked_xcframework_env = os.environ.copy()
      linked_xcframework_env["QIXI_KATAGO_IOS_XCFRAMEWORK"] = str(linked_xcframework)
      linked_xcframework_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=linked_xcframework_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(linked_xcframework_result.returncode, 0)
      self.assertIn("QIXI_KATAGO_IOS_XCFRAMEWORK must not contain symbolic links", linked_xcframework_result.stderr)

      fake_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(fake_result.returncode, 0)
      self.assertIn("QIXI_KATAGO_IOS_XCFRAMEWORK must contain Info.plist", fake_result.stderr)

      write_sparse_file(fake_xcframework / "Info.plist", 1 * 1024 * 1024 + 1)
      oversized_xcframework_info_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(oversized_xcframework_info_result.returncode, 0)
      self.assertIn("QIXI_KATAGO_IOS_XCFRAMEWORK Info.plist exceeds bounded size", oversized_xcframework_info_result.stderr)

      with (fake_xcframework / "Info.plist").open("wb") as plist_file:
        plistlib.dump(
          {
            "AvailableLibraries": [
              {
                "LibraryIdentifier": "ios-arm64_x86_64-simulator",
                "LibraryPath": "KataGo.framework",
                "SupportedArchitectures": ["arm64", "x86_64"],
                "SupportedPlatform": "ios",
                "SupportedPlatformVariant": "simulator",
              }
            ]
          },
          plist_file,
        )
      simulator_only_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(simulator_only_result.returncode, 0)
      self.assertIn(
        "QIXI_KATAGO_IOS_XCFRAMEWORK must contain an iOS device arm64 slice",
        simulator_only_result.stderr,
      )

      with (fake_xcframework / "Info.plist").open("wb") as plist_file:
        plistlib.dump(
          {
            "AvailableLibraries": [
              {
                "LibraryIdentifier": "ios-arm64",
                "LibraryPath": "../Escaped.framework",
                "SupportedArchitectures": ["arm64"],
                "SupportedPlatform": "ios",
              }
            ]
          },
          plist_file,
        )
      escaped_library_path_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(escaped_library_path_result.returncode, 0)
      self.assertIn(
        "QIXI_KATAGO_IOS_XCFRAMEWORK LibraryPath must not traverse outside the XCFramework",
        escaped_library_path_result.stderr,
      )

      with (fake_xcframework / "Info.plist").open("wb") as plist_file:
        plistlib.dump(
          {
            "AvailableLibraries": [
              {
                "LibraryIdentifier": "ios-arm64",
                "LibraryPath": "KataGo.framework",
                "SupportedArchitectures": ["arm64"],
                "SupportedPlatform": "ios",
              }
            ]
          },
          plist_file,
        )
      missing_artifact_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(missing_artifact_result.returncode, 0)
      self.assertIn(
        "QIXI_KATAGO_IOS_XCFRAMEWORK iOS device arm64 slice must reference an existing library or framework",
        missing_artifact_result.stderr,
      )

      dummy_library = pathlib.Path(tmpdir) / "libkatago_dummy.a"
      dummy_library.write_bytes(b"not a real static library")
      linked_library = pathlib.Path(tmpdir) / "linked-libkatago.a"
      linked_library.symlink_to(dummy_library)
      linked_library_env = os.environ.copy()
      linked_library_env["QIXI_KATAGO_IOS_LIBRARY"] = str(linked_library)
      linked_library_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=linked_library_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(linked_library_result.returncode, 0)
      self.assertIn("QIXI_KATAGO_IOS_LIBRARY must not contain symbolic links", linked_library_result.stderr)

      fake_core_source = pathlib.Path(tmpdir) / "fake_core_sidecar_probe.c"
      fake_core_object = pathlib.Path(tmpdir) / "fake_core_sidecar_probe.o"
      fake_core_library = pathlib.Path(tmpdir) / "libkatago_core.a"
      fake_core_source.write_text("int qixi_fake_core_sidecar_probe(void) { return 7; }\n", encoding="utf-8")
      subprocess.run(
        [
          "xcrun",
          "--sdk",
          "iphoneos",
          "clang",
          "-target",
          "arm64-apple-ios17.0",
          "-c",
          str(fake_core_source),
          "-o",
          str(fake_core_object),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      subprocess.run(
        ["ar", "rcs", str(fake_core_library), str(fake_core_object)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      fake_core_env = os.environ.copy()
      fake_core_env["QIXI_KATAGO_IOS_LIBRARY"] = str(fake_core_library)
      fake_core_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=fake_core_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(fake_core_result.returncode, 0)
      self.assertIn(
        "QIXI_KATAGO_IOS_LIBRARY_DIR must point at the directory containing libKataGoSwift.a",
        fake_core_result.stderr,
      )
      relative_sidecar_env = fake_core_env.copy()
      relative_sidecar_env["QIXI_KATAGO_IOS_LIBRARY_DIR"] = "relative-build"
      relative_sidecar_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=relative_sidecar_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(relative_sidecar_result.returncode, 0)
      self.assertIn(
        "QIXI_KATAGO_IOS_LIBRARY_DIR must be an absolute path",
        relative_sidecar_result.stderr,
      )

      fake_source = pathlib.Path(tmpdir) / "fake_macos_katago.c"
      fake_object = pathlib.Path(tmpdir) / "fake_macos_katago.o"
      fake_library = pathlib.Path(tmpdir) / "libkatago_macos_arm64.a"
      fake_source.write_text("int qixi_fake_katago(void) { return 7; }\n", encoding="utf-8")
      subprocess.run(
        [
          "xcrun",
          "--sdk",
          "macosx",
          "clang",
          "-target",
          "arm64-apple-macos13",
          "-c",
          str(fake_source),
          "-o",
          str(fake_object),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      subprocess.run(
        ["ar", "rcs", str(fake_library), str(fake_object)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )

      symlink_slice = fake_xcframework / "ios-arm64-symlink"
      symlink_slice.mkdir(exist_ok=True)
      symlink_slice_artifact = symlink_slice / "libkatago-symlink.a"
      symlink_slice_artifact.symlink_to(fake_library)
      with (fake_xcframework / "Info.plist").open("wb") as plist_file:
        plistlib.dump(
          {
            "AvailableLibraries": [
              {
                "LibraryIdentifier": "ios-arm64-symlink",
                "LibraryPath": symlink_slice_artifact.name,
                "SupportedArchitectures": ["arm64"],
                "SupportedPlatform": "ios",
              }
            ]
          },
          plist_file,
        )
      symlink_slice_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(symlink_slice_result.returncode, 0)
      self.assertIn(
        "QIXI_KATAGO_IOS_XCFRAMEWORK slice artifact must not contain symbolic links",
        symlink_slice_result.stderr,
      )

      mislabeled_slice = fake_xcframework / "ios-arm64"
      mislabeled_slice.mkdir(exist_ok=True)
      mislabeled_library = mislabeled_slice / fake_library.name
      mislabeled_library.write_bytes(fake_library.read_bytes())
      with (fake_xcframework / "Info.plist").open("wb") as plist_file:
        plistlib.dump(
          {
            "AvailableLibraries": [
              {
                "LibraryIdentifier": "ios-arm64",
                "LibraryPath": fake_library.name,
                "SupportedArchitectures": ["arm64"],
                "SupportedPlatform": "ios",
              }
            ]
          },
          plist_file,
        )
      mislabeled_xcframework_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(mislabeled_xcframework_result.returncode, 0)
      self.assertIn(
        "QIXI_KATAGO_IOS_XCFRAMEWORK must not contain non-iOS platform object files",
        mislabeled_xcframework_result.stderr,
      )

      library_env = os.environ.copy()
      library_env["QIXI_KATAGO_IOS_LIBRARY"] = str(fake_library)
      macos_library_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=library_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(macos_library_result.returncode, 0)
      self.assertIn(
        "QIXI_KATAGO_IOS_LIBRARY must not contain non-iOS platform object files",
        macos_library_result.stderr,
      )

      mixed_ios_source = pathlib.Path(tmpdir) / "mixed_ios_katago.c"
      mixed_ios_object = pathlib.Path(tmpdir) / "mixed_ios_katago.o"
      mixed_macos_source = pathlib.Path(tmpdir) / "mixed_macos_katago.c"
      mixed_macos_object = pathlib.Path(tmpdir) / "mixed_macos_katago.o"
      mixed_library = pathlib.Path(tmpdir) / "libkatago_mixed_platforms.a"
      mixed_ios_source.write_text("int qixi_mixed_ios_katago(void) { return 1; }\n", encoding="utf-8")
      mixed_macos_source.write_text("int qixi_mixed_macos_katago(void) { return 2; }\n", encoding="utf-8")
      subprocess.run(
        [
          "xcrun",
          "--sdk",
          "iphoneos",
          "clang",
          "-target",
          "arm64-apple-ios17.0",
          "-c",
          str(mixed_ios_source),
          "-o",
          str(mixed_ios_object),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      subprocess.run(
        [
          "xcrun",
          "--sdk",
          "macosx",
          "clang",
          "-target",
          "arm64-apple-macos13",
          "-c",
          str(mixed_macos_source),
          "-o",
          str(mixed_macos_object),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      subprocess.run(
        ["ar", "rcs", str(mixed_library), str(mixed_ios_object), str(mixed_macos_object)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      mixed_env = os.environ.copy()
      mixed_env["QIXI_KATAGO_IOS_LIBRARY"] = str(mixed_library)
      mixed_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=mixed_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(mixed_result.returncode, 0)
      self.assertIn("must not contain non-iOS platform object files", mixed_result.stderr)

      fake_symbol_source = pathlib.Path(tmpdir) / "fake_old_symbol_fragments.c"
      fake_symbol_object = pathlib.Path(tmpdir) / "fake_old_symbol_fragments.o"
      fake_symbol_library = pathlib.Path(tmpdir) / "libkatago_old_fragments_macos_arm64.a"
      fake_symbol_source.write_text(
        "\n".join(
          [
            "int AsyncBot(void) { return 1; }",
            "int BoardHistory(void) { return 2; }",
            "int NNEvaluator(void) { return 3; }",
            "int Search(void) { return 4; }",
            "",
          ]
        ),
        encoding="utf-8",
      )
      subprocess.run(
        [
          "xcrun",
          "--sdk",
          "macosx",
          "clang",
          "-target",
          "arm64-apple-macos13",
          "-c",
          str(fake_symbol_source),
          "-o",
          str(fake_symbol_object),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      subprocess.run(
        ["ar", "rcs", str(fake_symbol_library), str(fake_symbol_object)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      old_fragment_env = os.environ.copy()
      old_fragment_env["QIXI_KATAGO_IOS_LIBRARY"] = str(fake_symbol_library)
      old_fragment_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=old_fragment_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(old_fragment_result.returncode, 0)
      self.assertIn("does not look like a real KataGo iOS library", old_fragment_result.stderr)
      self.assertIn("initializeNNEvaluator", old_fragment_result.stderr)
      self.assertIn("setPositionForMCTSPersistence", old_fragment_result.stderr)
      self.assertIn("restorePersistentMCTSTombstone", old_fragment_result.stderr)

      spoof_source = pathlib.Path(tmpdir) / "fake_all_symbol_fragments_ios.c"
      spoof_object = pathlib.Path(tmpdir) / "fake_all_symbol_fragments_ios.o"
      spoof_library = pathlib.Path(tmpdir) / "libkatago_spoofed_ios_arm64.a"
      spoof_source.write_text(
        "\n".join(
          [
            "int AsyncBot(void) { return 1; }",
            "int BoardHistory(void) { return 2; }",
            "int NNEvaluator(void) { return 3; }",
            "int Search(void) { return 4; }",
            "int initializeNNEvaluator(void) { return 5; }",
            "int loadSingleParams(void) { return 6; }",
            "int setPositionForMCTSPersistence(void) { return 7; }",
            "int runWholeSearch(void) { return 8; }",
            "int getAnalysisJson(void) { return 9; }",
            "int getAverageTreeOwnership(void) { return 10; }",
            "int exportPersistentMCTS(void) { return 11; }",
            "int restorePersistentMCTSTombstone(void) { return 12; }",
            "",
          ]
        ),
        encoding="utf-8",
      )
      subprocess.run(
        [
          "xcrun",
          "--sdk",
          "iphoneos",
          "clang",
          "-target",
          "arm64-apple-ios17.0",
          "-c",
          str(spoof_source),
          "-o",
          str(spoof_object),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      subprocess.run(
        ["ar", "rcs", str(spoof_library), str(spoof_object)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      spoof_env = os.environ.copy()
      spoof_env["QIXI_KATAGO_IOS_LIBRARY"] = str(spoof_library)
      spoof_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=spoof_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(spoof_result.returncode, 0)
      self.assertIn("does not expose enough defined symbols", spoof_result.stderr)
      self.assertIn("does not expose enough KataGo-like C++ symbols", spoof_result.stderr)

      archive_symbol_source = pathlib.Path(tmpdir) / "fake_many_archive_symbols_ios.c"
      archive_symbol_object = pathlib.Path(tmpdir) / "fake_many_archive_symbols_ios.o"
      archive_symbol_library = pathlib.Path(tmpdir) / "libkatago_many_archive_symbols_ios_arm64.a"
      archive_symbol_lines = [
        "int AsyncBot(void) { return 1; }",
        "int BoardHistory(void) { return 2; }",
        "int NNEvaluator(void) { return 3; }",
        "int Search(void) { return 4; }",
        "int initializeNNEvaluator(void) { return 5; }",
        "int loadSingleParams(void) { return 6; }",
        "int setPositionForMCTSPersistence(void) { return 7; }",
        "int runWholeSearch(void) { return 8; }",
        "int getAnalysisJson(void) { return 9; }",
        "int getAverageTreeOwnership(void) { return 10; }",
        "int exportPersistentMCTS(void) { return 11; }",
        "int restorePersistentMCTSTombstone(void) { return 12; }",
      ]
      archive_symbol_lines.extend(
        f"int qixi_archive_defined_symbol_{index}(void) {{ return {index}; }}"
        for index in range(260)
      )
      archive_symbol_source.write_text("\n".join(archive_symbol_lines) + "\n", encoding="utf-8")
      subprocess.run(
        [
          "xcrun",
          "--sdk",
          "iphoneos",
          "clang",
          "-target",
          "arm64-apple-ios17.0",
          "-c",
          str(archive_symbol_source),
          "-o",
          str(archive_symbol_object),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      subprocess.run(
        ["ar", "rcs", str(archive_symbol_library), str(archive_symbol_object)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
      )
      archive_symbol_env = os.environ.copy()
      archive_symbol_env["QIXI_KATAGO_IOS_LIBRARY"] = str(archive_symbol_library)
      archive_symbol_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-native-linked-build-preflight.sh")],
        cwd=ROOT,
        env=archive_symbol_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(archive_symbol_result.returncode, 0)
      self.assertNotIn("does not expose enough defined symbols", archive_symbol_result.stderr)
      self.assertNotIn("does not look like a real KataGo iOS library", archive_symbol_result.stderr)
      self.assertIn("does not expose enough KataGo-like C++ symbols", archive_symbol_result.stderr)

  def test_native_release_build_preflight_builds_native_release_target(self) -> None:
    script_path = ROOT / "scripts" / "qixi-native-release-build-preflight.sh"
    script = read(script_path)
    release_gate = read(ROOT / "scripts" / "qixi-release-evidence-gate.sh")
    docs = (
      read(ROOT / "docs" / "quality-gates.md")
      + read(ROOT / "docs" / "app-store-readiness.md")
      + read(ROOT / "README.md")
      + read(ROOT / "docs" / "pr-verification-matrix.md")
    )

    self.assertTrue(os.access(script_path, os.X_OK))
    for token in (
      "scripts/qixi-native-linked-build-preflight.sh",
      "QIXI_NATIVE_RELEASE_DERIVED_DATA",
      "qixi-native-release-build-preflight-",
      "require_xcodebuild_iphoneos",
      "command -v xcodebuild",
      "/usr/bin/xcodebuild",
      "do not shadow xcodebuild in PATH",
      "xcodebuild -showsdks",
      "iphoneos",
      "NativeRelease",
      "-configuration",
      "CODE_SIGNING_ALLOWED=NO",
      "CODE_SIGNING_REQUIRED=NO",
      "QIXI_KATAGO_IOS_XCFRAMEWORK",
      "QIXI_KATAGO_IOS_LIBRARY",
      "QIXI_KATAGO_IOS_LIBRARY_DIR",
      "QIXI_NATIVE_RELEASE_DESTINATION",
      "QIXI_NATIVE_RELEASE_APP_PATH",
      "QixiAnalysisRuntime",
      "nativeInProcess",
      "QixiBackendBaseURL",
      "CFBundleSupportedPlatforms",
      "iPhoneOS",
      "FORBIDDEN_EXECUTABLE_STRINGS",
      "Native KataGo is not linked into this build.",
      "PlaceholderNativeKataGoEngine",
      "BackendClient",
      "HTTPBridgeAnalysisService",
      "Qixi HTTP bridge response",
      "QIXI_BACKEND_URL",
      "QIXI_ANALYSIS_RUNTIME",
      "qixi.backendBaseURL",
      "QIXI_DEVICE_BACKEND_URL",
      "http://127.0.0.1:8765",
      "bounded_bytes",
      "opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "must be a regular file after opening",
      "after opening",
      "QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_TESTING",
      "QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_ARTIFACT_VALIDATION_ONLY",
      "QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR",
      "selftest_opened_descriptor_recheck",
      "validate_regular_file",
      "validate_directory",
      "reject_symlink_components",
      "EXECUTABLE_MAX_BYTES",
      "PLIST_MAX_BYTES",
      "lipo",
      "-info",
      "arm64",
      "otool",
      "platform 2",
      "platform ios",
      "NativeRelease build artifact validation passed",
      "Native release build preflight passed",
    ):
      self.assertIn(token, script)
    self.assertNotIn("read_bytes()", script)

    for token in (
      "native release Xcode build preflight",
      "scripts/qixi-native-release-build-preflight.sh",
    ):
      self.assertIn(token, release_gate)
      self.assertIn(token, docs)

    unguarded_validation_env = os.environ.copy()
    unguarded_validation_env["QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_ARTIFACT_VALIDATION_ONLY"] = "1"
    unguarded_validation_result = subprocess.run(
      [str(script_path)],
      cwd=ROOT,
      env=unguarded_validation_env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(unguarded_validation_result.returncode, 0)
    self.assertIn(
      "QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_ARTIFACT_VALIDATION_ONLY may only be used with QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_TESTING=1",
      unguarded_validation_result.stderr,
    )
    self.assertNotIn("xcodebuild NativeRelease failed", unguarded_validation_result.stderr)

    descriptor_recheck_env = os.environ.copy()
    descriptor_recheck_env["QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_TESTING"] = "1"
    descriptor_recheck_env["QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_ARTIFACT_VALIDATION_ONLY"] = "1"
    descriptor_recheck_env["QIXI_NATIVE_RELEASE_BUILD_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR"] = "1"
    descriptor_recheck_result = subprocess.run(
      [str(script_path)],
      cwd=ROOT,
      env=descriptor_recheck_env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(descriptor_recheck_result.returncode, 0)
    self.assertIn(
      "NativeRelease app Info.plist must be a regular file after opening",
      descriptor_recheck_result.stderr,
    )
    self.assertNotIn("native release build requires xcodebuild", descriptor_recheck_result.stderr)
    self.assertNotIn("xcodebuild NativeRelease failed", descriptor_recheck_result.stderr)

    missing_artifact_result = subprocess.run(
      [str(script_path)],
      cwd=ROOT,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(missing_artifact_result.returncode, 0)
    self.assertIn(
      "release evidence must set QIXI_KATAGO_IOS_XCFRAMEWORK",
      missing_artifact_result.stderr,
    )
    self.assertNotIn("xcodebuild NativeRelease failed", missing_artifact_result.stderr)

    with tempfile.TemporaryDirectory() as tmpdir:
      temp_bin = pathlib.Path(tmpdir) / "bin"
      temp_bin.mkdir()
      (temp_bin / "bash").symlink_to("/bin/bash")
      (temp_bin / "dirname").symlink_to("/usr/bin/dirname")
      fake_xcodebuild = temp_bin / "xcodebuild"
      fake_xcodebuild.write_text("#!/bin/bash\necho fake xcodebuild\n", encoding="utf-8")
      fake_xcodebuild.chmod(0o755)
      fake_env = os.environ.copy()
      fake_env["PATH"] = str(temp_bin)
      fake_result = subprocess.run(
        [str(script_path)],
        cwd=ROOT,
        env=fake_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(fake_result.returncode, 0)
      self.assertIn(
        "native release build requires xcodebuild to resolve to /usr/bin/xcodebuild",
        fake_result.stderr,
      )
      self.assertIn("do not shadow xcodebuild in PATH", fake_result.stderr)
      self.assertNotIn("Native KataGo adapter compile probe passed", fake_result.stdout)

    target_dir = pathlib.Path(tempfile.mkdtemp(
      prefix="qixi-native-release-build-preflight-target-",
      dir="/private/tmp",
    ))
    linked_derived = pathlib.Path("/private/tmp") / f"qixi-native-release-build-preflight-linked-{os.getpid()}"
    try:
      linked_derived.symlink_to(target_dir, target_is_directory=True)
      symlink_env = os.environ.copy()
      symlink_env["QIXI_NATIVE_RELEASE_DERIVED_DATA"] = str(linked_derived)
      symlink_result = subprocess.run(
        [str(script_path)],
        cwd=ROOT,
        env=symlink_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(symlink_result.returncode, 0)
      self.assertIn(
        "QIXI_NATIVE_RELEASE_DERIVED_DATA must not contain symbolic links",
        symlink_result.stderr,
      )
      self.assertNotIn("Native KataGo adapter compile probe passed", symlink_result.stdout)
    finally:
      try:
        linked_derived.unlink()
      except OSError:
        pass
      shutil.rmtree(target_dir, ignore_errors=True)

  def test_ios_katago_cmake_preflight_builds_without_runtime_coreml_converter(self) -> None:
    script = read(ROOT / "scripts" / "qixi-ios-katago-cmake-preflight.sh")
    app_store_doc = read(ROOT / "docs" / "app-store-readiness.md")
    cmake = read(ROOT / "KataGo" / "cpp" / "CMakeLists.txt")
    metal_cpp = read(ROOT / "KataGo" / "cpp" / "neuralnet" / "metalbackend.cpp")
    metal_swift = read(ROOT / "KataGo" / "cpp" / "neuralnet" / "metalbackend.swift")
    add_swift = read(ROOT / "KataGo" / "cpp" / "external" / "macos" / "cmake" / "modules" / "AddSwift.cmake")
    init_swift = read(ROOT / "KataGo" / "cpp" / "external" / "macos" / "cmake" / "modules" / "InitializeSwift.cmake")

    for token in (
      "-DUSE_BACKEND=METAL",
      "-DKATAGO_METAL_ENABLE_COREML_CONVERSION=0",
      "-DCMAKE_SYSTEM_NAME=iOS",
      "QIXI_IOS_SDK",
      "iphonesimulator",
      "iphoneos",
      "-DCMAKE_OSX_SYSROOT=\"$IOS_SDK\"",
      "QIXI_IOS_ARCH",
      "-DCMAKE_OSX_ARCHITECTURES",
      "-DCMAKE_OSX_DEPLOYMENT_TARGET",
      "-DCMAKE_Swift_COMPILER_TARGET",
      "DEFAULT_SWIFT_TARGET=\"${DEFAULT_IOS_ARCH}-apple-ios${DEFAULT_IOS_DEPLOYMENT_TARGET}-simulator\"",
      "DEFAULT_SWIFT_TARGET=\"${DEFAULT_IOS_ARCH}-apple-ios${DEFAULT_IOS_DEPLOYMENT_TARGET}\"",
      "SWIFT_TARGET=\"${QIXI_IOS_SWIFT_TARGET:-${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator}\"",
      "SWIFT_TARGET=\"${QIXI_IOS_SWIFT_TARGET:-${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}}\"",
      "QIXI_IOS_KATAGO_BUILD_TARGET",
      "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR",
      "QIXI_IOS_KATAGO_ARTIFACT_PATH",
      "SAFE_BUILD_DIR_PREFIX",
      "qixi-ios-katago-cmake-preflight-",
      "EXPECTED_PLATFORM_NUMBER",
      "find_developer_tool",
      "validate_build_dir",
      "reject_symlink_components",
      "artifact_for_target",
      "validate_built_artifact",
      "must stay directly under /private/tmp or /tmp",
      "basename must start",
      "must not contain symbolic links",
      "rm -rf \"$BUILD_DIR\"",
      "katago_core)",
      "libkatago_core.a",
      "libKataGoSwift.a",
      "katago.app/katago",
      "lipo",
      "otool",
      "LC_BUILD_VERSION|LC_VERSION_MIN_IPHONEOS",
      "platform_values",
      "unexpected_platforms",
      "built artifact must not contain object files for another Apple platform",
      "built artifact must target the $EXPECTED_PLATFORM_LABEL platform",
      "KataGoSwift",
      "katago_core",
      "katago",
      "unable to load standard library for target",
      "Could NOT find Protobuf",
      "KATAGO_METAL_ENABLE_COREML_CONVERSION=0 should keep katagocoreml out of the runtime build",
      "iOS KataGo CMake preflight passed for $IOS_SDK target",
    ):
      self.assertIn(token, script)

    result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-ios-katago-cmake-preflight.sh")],
      cwd=ROOT,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertIn("iOS KataGo CMake preflight passed for iphonesimulator target katago_core", result.stdout)

    swift_target_result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-ios-katago-cmake-preflight.sh")],
      cwd=ROOT,
      env={**os.environ, "QIXI_IOS_KATAGO_BUILD_TARGET": "KataGoSwift"},
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertEqual(swift_target_result.returncode, 0, swift_target_result.stderr)
    self.assertIn("iOS KataGo CMake preflight passed for iphonesimulator target KataGoSwift", swift_target_result.stdout)

    invalid_sdk_result = subprocess.run(
      [
        str(ROOT / "scripts" / "qixi-ios-katago-cmake-preflight.sh"),
      ],
      cwd=ROOT,
      env={**os.environ, "QIXI_IOS_SDK": "macosx"},
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(invalid_sdk_result.returncode, 0)
    self.assertIn("QIXI_IOS_SDK must be iphonesimulator or iphoneos", invalid_sdk_result.stderr)

    dangerous_build_dir_result = subprocess.run(
      [
        str(ROOT / "scripts" / "qixi-ios-katago-cmake-preflight.sh"),
      ],
      cwd=ROOT,
      env={
        **os.environ,
        "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR": str(ROOT / "KataGo" / "cpp"),
      },
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(dangerous_build_dir_result.returncode, 0)
    self.assertIn("QIXI_IOS_KATAGO_CMAKE_BUILD_DIR basename must start", dangerous_build_dir_result.stderr)

    bad_prefix_result = subprocess.run(
      [
        str(ROOT / "scripts" / "qixi-ios-katago-cmake-preflight.sh"),
      ],
      cwd=ROOT,
      env={
        **os.environ,
        "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR": "/private/tmp/qixi-unsafe-cmake-preflight-test",
      },
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(bad_prefix_result.returncode, 0)
    self.assertIn("QIXI_IOS_KATAGO_CMAKE_BUILD_DIR basename must start", bad_prefix_result.stderr)

    with tempfile.TemporaryDirectory(dir="/private/tmp") as tmpdir:
      target_dir = pathlib.Path(tmpdir) / "target"
      target_dir.mkdir()
      symlink_dir = pathlib.Path(tmpdir) / "linked"
      try:
        symlink_dir.symlink_to(target_dir, target_is_directory=True)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")
      symlink_build_result = subprocess.run(
        [
          str(ROOT / "scripts" / "qixi-ios-katago-cmake-preflight.sh"),
        ],
        cwd=ROOT,
        env={
          **os.environ,
          "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR": str(symlink_dir / "qixi-ios-katago-cmake-preflight-test"),
        },
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(symlink_build_result.returncode, 0)
      self.assertIn("QIXI_IOS_KATAGO_CMAKE_BUILD_DIR must not contain symbolic links", symlink_build_result.stderr)

    with tempfile.TemporaryDirectory(dir="/private/tmp") as tmpdir:
      tool_dir = pathlib.Path(tmpdir)
      fake_cmake = tool_dir / "fake-cmake"
      fake_cmake.write_text(
        """#!/usr/bin/env python3
import pathlib
import sys

args = sys.argv[1:]
if "-B" in args:
  build = pathlib.Path(args[args.index("-B") + 1])
  build.mkdir(parents=True, exist_ok=True)
  (build / "CMakeCache.txt").write_text(
    "CMAKE_Swift_COMPILER_TARGET:STRING=arm64-apple-ios17.0-simulator\\n",
    encoding="utf-8",
  )
  raise SystemExit(0)
if "--build" in args:
  build = pathlib.Path(args[args.index("--build") + 1])
  target = args[args.index("--target") + 1] if "--target" in args else ""
  if target == "help":
    print("katago_core:")
    print("katago:")
    print("KataGoSwift:")
    raise SystemExit(0)
  if target == "katago_core":
    (build / "libkatago_core.a").write_bytes(b"fake archive\\n")
  elif target == "KataGoSwift":
    (build / "libKataGoSwift.a").write_bytes(b"fake archive\\n")
  else:
    (build / "katago.app").mkdir(exist_ok=True)
    (build / "katago.app" / "katago").write_bytes(b"fake executable\\n")
  raise SystemExit(0)
raise SystemExit(0)
""",
        encoding="utf-8",
      )
      fake_cmake.chmod(0o755)
      fake_lipo = tool_dir / "lipo"
      fake_lipo.write_text(
        """#!/usr/bin/env bash
echo "Non-fat file: $2 is architecture: arm64"
""",
        encoding="utf-8",
      )
      fake_lipo.chmod(0o755)
      fake_otool = tool_dir / "otool"
      fake_otool.write_text(
        """#!/usr/bin/env bash
cat <<'EOF'
Load command 0
      cmd LC_BUILD_VERSION
  cmdsize 24
 platform 1
   minos 17.0
     sdk 26.5
EOF
""",
        encoding="utf-8",
      )
      fake_otool.chmod(0o755)
      build_dir = pathlib.Path("/private/tmp") / f"qixi-ios-katago-cmake-preflight-fake-platform-{tool_dir.name}"
      try:
        fake_platform_result = subprocess.run(
          [
            str(ROOT / "scripts" / "qixi-ios-katago-cmake-preflight.sh"),
          ],
          cwd=ROOT,
          env={
            **os.environ,
            "CMAKE_BIN": str(fake_cmake),
            "PATH": f"{tool_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            "QIXI_IOS_KATAGO_CMAKE_BUILD_DIR": str(build_dir),
          },
          text=True,
          capture_output=True,
          check=False,
        )
      finally:
        shutil.rmtree(build_dir, ignore_errors=True)
        for suffix in (".log", ".targets"):
          try:
            pathlib.Path(str(build_dir) + suffix).unlink()
          except FileNotFoundError:
            pass
      self.assertNotEqual(fake_platform_result.returncode, 0)
      self.assertIn("built artifact must not contain object files for another Apple platform", fake_platform_result.stderr)

    for token in (
      "KATAGO_METAL_ENABLE_COREML_CONVERSION",
      "add_subdirectory(external/katagocoreml)",
      "target_compile_definitions(katago_core PUBLIC KATAGO_METAL_ENABLE_COREML_CONVERSION)",
      "iOS platform detected: using SDK-provided pthread support without linking Threads::Threads",
      "KATAGO_TARGET_PROCESSOR",
      "CMAKE_OSX_ARCHITECTURES",
    ):
      self.assertIn(token, cmake)

    for token in (
      "#ifdef KATAGO_METAL_ENABLE_COREML_CONVERSION",
      "#include <katagocoreml/KataGoConverter.hpp>",
      "KataGoConverter::convert",
      "findPreconvertedModelPackage",
      "findExplicitPreconvertedModelPackage",
      "metalCoreMLPackagePathCount",
      "metalCoreMLPackagePath",
      "Explicit Metal CoreML package paths were configured",
      "getPreconvertedModelCandidates",
      "stripKnownModelSuffix",
      ".mlpackage",
      ".mlmodelc",
      "deleteAfterLoad",
      "requires a preconverted .mlpackage or .mlmodelc",
    ):
      self.assertIn(token, metal_cpp)

    for token in (
      "deleteSourceAfterLoad",
      "mlmodelc",
      "MLModel.compileModel",
      "preconverted .mlpackage/.mlmodelc",
    ):
      self.assertIn(token, metal_swift)

    for text in (add_swift, init_swift):
      self.assertIn("CMAKE_Swift_COMPILER_TARGET", text)
      self.assertIn("-target", text)

    for token in (
      "scripts/qixi-ios-katago-cmake-preflight.sh",
      "Protobuf/abseil",
      "katagocoreml",
      "KATAGO_METAL_ENABLE_COREML_CONVERSION=0",
      ".mlpackage",
      ".mlmodelc",
      "NativeKataGoCoreMLPackageSpec",
      "QixiNativeCoreMLPackageIntegrity",
      "QixiNativeCoreMLPackageInstallReceiptStore",
    ):
      self.assertIn(token, app_store_doc)

  def test_coreml_package_integrity_rejects_manifest_budget_overflow_before_digest(self) -> None:
    integrity = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelIntegrity.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    smoke = read(ROOT / "qixi-ios-native" / "tests" / "analysis_service_smoke.swift")
    native_doc = read(ROOT / "docs" / "native-katago-integration.md")
    app_store_doc = read(ROOT / "docs" / "app-store-readiness.md")

    for token in (
      "maxFileCount: packageSpec.expectedFileCount",
      "maxTotalByteCount: packageSpec.expectedTotalByteCount",
      "budgetResourceName: packageSpec.resourceName",
      "validateRegularOpenPackageFile",
      "packageResourceName: packageResourceName",
      "fstat(handle.fileDescriptor, &statBuffer)",
      "if let maxFileCount, fileCount > maxFileCount",
      "if let maxTotalByteCount, totalByteCount > maxTotalByteCount",
      "addingReportingOverflow",
      "if includeTreeDigest",
      "fileCount = 0",
      "totalByteCount: UInt64 = 0",
      "if let symlinkPath = QixiNativeModelIntegrity.symbolicLinkComponentPath(in: url)",
      "QixiNativeCoreMLPackageIntegrityError.packageNotDirectory(symlinkPath)",
      "let openedByteCount = try validateRegularOpenPackageFile",
      "var bytesRead: UInt64 = 0",
      "let nextBytesRead = bytesRead.addingReportingOverflow(UInt64(chunk.count))",
      "guard bytesRead == openedByteCount else",
      "QixiNativeCoreMLPackageIntegrityError.byteCountMismatch",
      "resourceName: packageResourceName",
      "expected: openedByteCount",
      "actual: bytesRead",
    ):
      self.assertIn(token, integrity)

    for token in (
      "maxFileCount: packageSpec.expectedFileCount",
      "maxTotalByteCount: packageSpec.expectedTotalByteCount",
    ):
      self.assertIn(token, frontend_contract)

    for token in (
      "CoreML package integrity quick check rejects file-count budget overflow",
      "CoreML package integrity must reject file-count budget overflow before tree digest",
      "CoreML package integrity quick check rejects byte-count budget overflow",
      "CoreML package integrity must reject byte-count budget overflow before tree digest",
      "CoreML package integrity validates opened package files before hashing",
      "CoreML package integrity must reject symbolic-link package path components",
      "CoreML package integrity reports the symbolic-link parent path",
    ):
      self.assertIn(token, frontend_contract)
      self.assertIn(token, smoke)

    for token in (
      "rejects symbolic-link\n  package source path components",
      "rejects packages as soon as recursive file count or total byte count exceeds the manifest",
      "before building the sorted tree-digest list or hashing file contents",
      "rechecks each opened package file descriptor with `fstat` before hashing",
    ):
      self.assertIn(token, native_doc)
    for token in (
      "rejects CoreML package source path components that traverse symbolic links",
      "rejects CoreML packages whose recursive file count or total byte count exceeds the manifest before tree-digest hashing",
      "prevents malformed package imports from forcing unbounded file-list growth",
      "CoreML package hashing also rechecks each opened package file descriptor with `fstat`",
    ):
      self.assertIn(token, app_store_doc)
    self.assertIn("CoreML package integrity rejects symbolic-link package\n    source path components", read(ROOT / "docs" / "quality-gates.md"))

  def test_native_model_hash_rejects_opened_byte_count_drift(self) -> None:
    integrity = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelIntegrity.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    native_doc = read(ROOT / "docs" / "native-katago-integration.md")
    quality_docs = read(ROOT / "docs" / "quality-gates.md")
    app_store_doc = read(ROOT / "docs" / "app-store-readiness.md")

    for token in (
      "let openedByteCount = try validateRegularOpenModelFile(handle, originalURL: url)",
      "var bytesRead: UInt64 = 0",
      "let nextBytesRead = bytesRead.addingReportingOverflow(UInt64(chunk.count))",
      "bytesRead = nextBytesRead.partialValue",
      "guard bytesRead == openedByteCount else",
      "expected: openedByteCount",
      "actual: bytesRead",
      "resourceName: url.lastPathComponent",
    ):
      self.assertIn(token, integrity)
      self.assertIn(token, frontend_contract)

    for token in (
      "hash path rejects opened-byte-count\n  drift after streaming all chunks",
      "concurrent\n  truncation",
    ):
      self.assertIn(token, native_doc)
    self.assertIn("hash path rejects opened-byte-count drift after streaming", quality_docs)
    self.assertIn(
      "SHA-256 path rejects opened-byte-count drift after streaming before trusting model bytes",
      app_store_doc,
    )

  def test_native_model_receipts_use_bounded_filehandle_reads(self) -> None:
    integrity = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelIntegrity.swift")
    installer = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelInstaller.swift")
    receipt = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelInstallReceipt.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    smoke = read(ROOT / "qixi-ios-native" / "tests" / "analysis_service_smoke.swift")
    native_doc = read(ROOT / "docs" / "native-katago-integration.md")
    app_store_doc = read(ROOT / "docs" / "app-store-readiness.md")

    for token in (
      "private static func boundedData(",
      "receiptByteCount(at: url, fileManager: fileManager)",
      "FileHandle(forReadingFrom: url)",
      "validateRegularReceiptFileURL(url, label: label, fileManager: fileManager)",
      "validateRegularOpenReceiptFile(handle, originalURL: url, label: label)",
      "case notRegularFile(label: String, path: String)",
      "fstat(handle.fileDescriptor, &statBuffer)",
      "guard (statBuffer.st_mode & S_IFMT) == S_IFREG else",
      "let readLimit = maxBytes >= UInt64(Int.max) ? Int.max : Int(maxBytes + 1)",
      "handle.readData(ofLength: readLimit)",
      "QixiNativeModelInstallReceiptJSONError.documentTooLarge",
      "try Scanner(data: data, label: label).validateTopLevelObject()",
      "static let maxReceiptBytes: UInt64 = 64 * 1024",
      "rejectSymbolicLinkComponents(in: url, label: label)",
      "path must not contain symbolic links",
      "QixiTrustedFilePath.writeProtectedDataAtomically(",
      "installedDeviceID: Int64",
      "installedFileID: Int64",
      "openedRegularModelStat(at: modelURL)",
      "statBuffer.st_ino",
      "static let schemaVersion = 3",
      'label: "Qixi native model install receipt directory"',
      'label: "Qixi native CoreML package install receipt directory"',
      'label: "Qixi native model install receipt path"',
      'label: "Qixi native CoreML package install receipt path"',
    ):
      self.assertIn(token, receipt)
    self.assertNotIn("fileManager.contents(atPath: url.path)", receipt)
    for token in (
      "case symbolicLink(String)",
      "case notRegularFile(String)",
      "validateRegularModelFile",
      "validateRegularOpenModelFile",
      "fstat(handle.fileDescriptor, &statBuffer)",
      "statBuffer.st_size",
      "Native model file must not be a symbolic link",
      "symbolicLinkComponentPath(in: url)",
      "fileprivate static func symbolicLinkComponentPath",
      "isAllowedPlatformSymlinkAlias",
    ):
      self.assertIn(token, integrity)
    for token in (
      "QixiTrustedFilePath.createDirectoryForTrustedWrite",
      'label: "Qixi native model install directory"',
      'label: "Qixi native CoreML package install directory"',
    ):
      self.assertIn(token, installer)

    for token in (
      'self.assertNotIn("fileManager.contents(atPath: url.path)", receipt)',
      'self.assertIn("FileHandle(forReadingFrom: url)", receipt)',
      'self.assertIn("QixiTrustedFilePath.writeProtectedDataAtomically", receipt)',
      'self.assertIn("installedDeviceID: Int64", receipt)',
      'self.assertIn("openedRegularModelStat(at: modelURL)", receipt)',
      'self.assertIn("symbolicLink(String)", integrity)',
      'self.assertIn("validateRegularOpenModelFile", integrity)',
      'self.assertIn("QixiTrustedFilePath.createDirectoryForTrustedWrite", installer)',
    ):
      self.assertIn(token, frontend_contract)
    for token in (
      "native model receipt reader reads at most maxReceiptBytes plus one when file size is unavailable",
      "native model installer receipt records the installed file metadata fingerprint",
      "native model store rejects a same-size managed model replaced after receipt even when mtime is restored",
      "native CoreML package receipt reader reads at most maxReceiptBytes plus one when file size is unavailable",
      "native model integrity must reject symbolic-link raw model files",
      "native model integrity must reject symbolic-link raw model path components",
      "native model integrity reports the symbolic-link parent path",
      "native model integrity must reject directory raw model files before hashing",
      "native model integrity reports the non-regular raw model path",
      "native model installer rejects symbolic-link managed model directories",
      "native model installer rejects symbolic-link CoreML package directories",
      "native model receipt rejects symbolic-link receipt files",
      "native model receipt write rejects symbolic-link receipt paths",
      "native model receipt rejects directory receipt files",
      "native model store rejects a managed model whose receipt is a directory",
      "native CoreML package receipt rejects symbolic-link receipt files",
      "native CoreML package receipt write rejects symbolic-link receipt paths",
      "native CoreML package receipt rejects directory receipt files",
      "native model installer must reject a raw model whose staged copy drifts after source verification",
      "native model installer leaves no destination after staged raw model drift",
      "native model installer must fail initial install when the staged model cannot be committed",
      "native model installer leaves no model destination after initial staged commit failure",
      "native model installer must fail replacement when the previous model cannot be backed up",
      "native model installer preserves the previous model when model backup fails",
      "native model installer preserves the previous receipt when model backup fails",
      "native model installer must fail CoreML package install when the package receipt cannot be written",
      "native model installer must reject a CoreML package whose staged copy drifts after source verification",
      "native model installer leaves no CoreML package destination after staged package drift",
      "native model installer must fail CoreML package replacement when the previous package cannot be backed up",
      "native model installer preserves the previous CoreML package when package backup fails",
      "native model installer preserves the previous CoreML package receipt when package backup fails",
      "native model installer must fail CoreML package install when the staged package cannot be committed",
      "native model installer leaves no CoreML package destination after initial staged commit failure",
      "native model installer removes the committed CoreML package after receipt write failure",
      "native model installer removes the failed CoreML package receipt path after receipt write failure",
      "native model installer must fail replacement when the staged model cannot be committed",
      "native model installer restores the previous model after staged commit failure",
      "native model installer restores the previous receipt after staged commit failure",
      "native model installer must fail CoreML package replacement when the previous package receipt cannot be backed up",
      "native model installer preserves the previous CoreML package after receipt backup failure",
      "native model installer preserves the previous CoreML package receipt after receipt backup failure",
      "native model installer must fail CoreML package replacement when the staged package cannot be committed",
      "native model installer restores the previous CoreML package after staged commit failure",
      "native model installer restores the previous CoreML package receipt after staged commit failure",
      "native model installer must fail CoreML package replacement when the package receipt cannot be written",
      "native model installer preserves the previous CoreML package after replacement receipt failure",
      "native model installer restores the previous CoreML package receipt after replacement receipt failure",
    ):
      self.assertIn(token, frontend_contract)
      self.assertIn(token, smoke)

    for token in (
      "Install receipt JSON is itself part of the trust boundary",
      "device id, and file id",
      "same-size replacement whose mtime is restored",
      "read at most `maxReceiptBytes + 1` through `FileHandle`",
      "without trusting the initial file-size check as the only memory guard",
      "symbolic-link and non-regular receipt files",
      "descriptor with `fstat`",
      "Raw model imports must reject symbolic-link source files",
      "raw model source path components",
      "Receipt writes must use the shared Swift exclusive no-follow atomic writer",
      "post-write `fstat` byte-count verification",
      "`F_FULLFSYNC`/`fsync`, atomic `rename`, and parent-directory `fsync`",
      "opened model file descriptor",
      "still a regular file with `fstat`",
      "If the staged copy drifts after source verification",
      "must leave no destination model",
      "If initial staged-model commit fails",
      "must leave no",
      "destination model or install receipt",
      "If the previous model cannot",
      "be moved into its backup path",
      "`fstat`",
      "Managed model, CoreML package, and receipt directories must reject symbolic links",
      "If the staged CoreML package copy drifts after source verification",
      "must leave no package destination",
      "If the previous CoreML package cannot be moved into its backup path",
      "If initial staged-package commit fails",
      "destination or package receipt",
      "If initial package receipt writing fails after the staged package is committed",
      "must remove both the committed package directory",
      "receipt path before returning the error",
      "CoreML package replacement uses the same backup-and-restore discipline",
      "staged-package commit failure",
      "restore the previous",
      "package directory and package receipt before returning the error",
    ):
      self.assertIn(token, native_doc)
    for token in (
      "`QixiNativeCoreMLPackageInstallReceiptStore`",
      "receipt readers use bounded `FileHandle` reads",
      "Raw model install receipts must store byte",
      "without requiring a full-model SHA-256 hash on every launch",
      "maxReceiptBytes + 1",
      "reject symbolic-link and non-regular receipt files",
      "recheck the opened descriptor with `fstat`",
      "Receipt writers use the same shared exclusive no-follow atomic writer",
      "parent-directory `fsync` after replacement",
      "native model trust metadata is not published partially",
      "raw model source path components",
      "model install directories",
      "receipt paths reject symbolic links",
    ):
      self.assertIn(token, app_store_doc)

  def test_board_recognition_url_import_avoids_full_file_data_load(self) -> None:
    recognizer = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiBoardImageRecognizer.swift")
    utility = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiUtilitySheets.swift")
    view_model = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiViewModel.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    smoke = read(ROOT / "qixi-ios-native" / "tests" / "board_recognition_smoke.swift")
    docs = read(ROOT / "docs" / "quality-gates.md")
    runbook = read(ROOT / "docs" / "native-ios-runbook.md")
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")

    for token in (
      "static let maxInputImageBytes: UInt64 = 32 * 1024 * 1024",
      "private static let maximumDecodePixelSize = 1600",
      "private static func decodedImage(from url: URL)",
      "CGImageSourceCreateWithURL(url as CFURL",
      "return try recognizeBoard(from: decodedImage(from: url))",
      "allowFullImageFallback: false",
      "CGImageSourceCreateThumbnailAtIndex",
      "kCGImageSourceThumbnailMaxPixelSize",
      "compressedFileByteCount(at: url)",
      "validateImportFileURL(url)",
      "rejectSymbolicLinkComponents(in: url)",
      "case symbolicLink(String)",
      "case notRegularFile(String)",
    ):
      self.assertIn(token, recognizer)
    self.assertNotIn("Data(contentsOf: url, options: [.mappedIfSafe])", recognizer)

    for token in (
      "CGImageSourceCreateWithURL(url as CFURL",
      "return try recognizeBoard(from: decodedImage(from: url))",
      "allowFullImageFallback: false",
      "self.assertNotIn(\"Data(contentsOf: url, options: [.mappedIfSafe])\", recognizer)",
      "self.assertIn(\"validateImportFileURL(url)\", recognizer)",
      "self.assertIn(\"FileRepresentation(importedContentType: .image)\", utility)",
      "self.assertNotIn(\"item.loadTransferable(type: Data.self)\", utility)",
    ):
      self.assertIn(token, frontend_contract)

    for token in (
      "struct QixiPickedBoardPhoto: Transferable",
      "FileRepresentation(importedContentType: .image)",
      "FileManager.default.copyItem(at: sourceURL, to: destinationURL)",
      "item.loadTransferable(type: QixiPickedBoardPhoto.self)",
      "QixiPendingBoardImageFactory.make(from: photo.url)",
      "pendingTemporaryPhotoURL = photo.url",
      "QixiBoardImageRecognizer.recognizeBoard(from: url, selection: selection)",
      "cleanupPendingPhotoFile()",
    ):
      self.assertIn(token, utility)
    self.assertNotIn("item.loadTransferable(type: Data.self)", utility)
    self.assertNotIn("model.recognizeBoardImage(data: data)", utility)
    self.assertNotIn("Data(contentsOf: photo.url)", utility)

    for token in (
      "test_camera_recognition_preview_is_cleared_on_position_identity_changes",
      '"step": r"func step\\(by delta: Int\\)',
      '"jump": r"func jump\\(to ply: Int\\)',
      '"pass": r"func passMove\\(\\)',
      '"play": r"func play\\(at x: Int, y: Int\\)',
      '"sgf import": r"func importSGF\\(text: String\\) throws',
      '"snapshot apply": r"private func apply\\(snapshot: QixiAppSnapshot\\)',
      'self.assertIn("clearBoardRecognitionPreview()", match.group("body"), label)',
      'self.assertIn("apply(snapshot: imported)", sync_body_match.group("body"))',
      'self.assertIn("lastBoardRecognition = nil", clear_body_match.group("body"))',
    ):
      self.assertIn(token, frontend_contract)
    for token in (
      "private func clearBoardRecognitionPreview()",
      "lastBoardRecognition = nil",
      "apply(snapshot: imported)",
    ):
      self.assertIn(token, view_model)
    for pattern, expected_clear in (
      (r"func step\(by delta: Int\) \{(?P<body>.*?)\n  \}", "clearBoardRecognitionPreview()"),
      (r"func jump\(to ply: Int\) \{(?P<body>.*?)\n  \}", "clearBoardRecognitionPreview()"),
      (r"func passMove\(\) \{(?P<body>.*?)\n  \}", "clearBoardRecognitionPreview()"),
      (r"func play\(at x: Int, y: Int\) \{(?P<body>.*?)\n  \}", "clearBoardRecognitionPreview()"),
      (r"func importSGF\(text: String\) throws \{(?P<body>.*?)\n  \}", "clearRecognizedSetup()"),
      (r"private func apply\(snapshot: QixiAppSnapshot\) \{(?P<body>.*?)\n  \}", "clearBoardRecognitionPreview()"),
    ):
      match = re.search(pattern, view_model, re.S)
      self.assertIsNotNone(match)
      self.assertIn(expected_clear, match.group("body"))

    for token in (
      "oversized image URL should be rejected before file data is loaded",
      "symbolic-link image URL should be rejected before ImageIO decode",
      "directory image URL should be rejected before ImageIO decode",
      "QixiBoardImageRecognizer.maxInputImageBytes + 1",
      "large",
      "exif-oriented",
    ):
      self.assertIn(token, smoke)

    for token in (
      "The PhotosPicker path imports a temporary file via",
      "`FileRepresentation` and uses ImageIO directly from that URL",
      "without creating",
      "a full compressed-image `Data` allocation",
      "oversized-photo rejection before ImageIO decode or file-data loading",
      "symbolic-link and non-regular photo URL rejection before ImageIO decode",
      "recognition",
      "preview is cleared on every current-position identity change",
      "imported sync snapshots",
    ):
      self.assertIn(token, docs)
    for token in (
      "The PhotosPicker path imports",
      "a temporary file through `FileRepresentation`",
      "uses ImageIO directly from that file URL without first creating a full",
      "compressed-image `Data` allocation",
      "rejects symbolic-link and directory photo URLs before ImageIO decode",
    ):
      self.assertIn(token, runbook)
    self.assertIn(
      "preserve the visible-stone-preview boundary and clear stale recognition previews on every current-position identity change",
      matrix,
    )

  def test_sgf_url_import_uses_bounded_filehandle_read(self) -> None:
    parser = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiSGFParser.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    smoke = read(ROOT / "qixi-ios-native" / "tests" / "sgf_parser_smoke.swift")
    docs = read(ROOT / "docs" / "quality-gates.md")
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")

    for token in (
      "static let maxInputBytes: UInt64 = 4 * 1024 * 1024",
      "private static func boundedData(from url: URL) throws -> Data",
      "FileHandle(forReadingFrom: url)",
      "let readLimit = Int(maxInputBytes) + 1",
      "handle.readData(ofLength: readLimit)",
      "return try loadText(from: boundedData(from: url))",
      "validateImportFileURL(url)",
      "rejectSymbolicLinkComponents(in: url)",
      "case symbolicLink(String)",
      "case notRegularFile(String)",
      "validateInputByteCount(UInt64(data.count))",
      "let scalars = text.unicodeScalars",
      "scalars.formIndex(after: &index)",
      "_ scalars: String.UnicodeScalarView",
      "index: inout String.UnicodeScalarView.Index",
    ):
      self.assertIn(token, parser)
    self.assertNotIn("Data(contentsOf: url, options: [.mappedIfSafe])", parser)
    self.assertNotIn("Array(text.unicodeScalars)", parser)

    for token in (
      "FileHandle(forReadingFrom: url)",
      "let readLimit = Int(maxInputBytes) + 1",
      "handle.readData(ofLength: readLimit)",
      "self.assertNotIn(\"Array(text.unicodeScalars)\", parser)",
      "self.assertNotIn(\"Data(contentsOf: url, options: [.mappedIfSafe])\", parser)",
      "self.assertIn(\"validateImportFileURL(url)\", parser)",
    ):
      self.assertIn(token, frontend_contract)

    for token in (
      "oversized SGF URL should be rejected before file data is loaded",
      "symbolic-link SGF URL should be rejected before FileHandle read",
      "directory SGF URL should be rejected before FileHandle read",
      "QixiSGFParser.maxInputBytes + 1",
      "SGF text loader accepts Latin-1 SGF comments",
    ):
      self.assertIn(token, smoke)

    for token in (
      "SGF URL import reads at most `maxInputBytes + 1` through `FileHandle`",
      "symbolic-link and non-regular SGF URL rejection before `FileHandle` reads",
      "never memory-maps the entire selected file",
      "SGF parsing scans `String.UnicodeScalarView` directly without copying the whole text into an array",
      "SGF/photo input-size guards",
    ):
      self.assertIn(token, docs + matrix)

  def test_position_identity_builds_history_key_without_intermediate_move_array(self) -> None:
    identity = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiPositionIdentity.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    smoke = read(ROOT / "qixi-ios-native" / "tests" / "analysis_service_smoke.swift")
    docs = read(ROOT / "docs" / "quality-gates.md")
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")

    for token in (
      "var key =",
      "key.reserveCapacity",
      "for (index, move) in moves.enumerated()",
      "key.append(\";\")",
      "key.append(\"\\(index):\\(move.color.rawValue):pass\")",
      "key.append(\"\\(index):\\(move.color.rawValue):\\(move.x ?? -1):\\(move.y ?? -1)\")",
      "return key",
    ):
      self.assertIn(token, identity)
    for forbidden in (
      "let encodedMoves = moves.enumerated().map",
      ".joined(separator: \";\")",
    ):
      self.assertNotIn(forbidden, identity)
    self.assertIn('self.assertNotIn("let encodedMoves = moves.enumerated().map", identity)', frontend_contract)
    self.assertIn('self.assertNotIn(".joined(separator: \\";\\")", identity)', frontend_contract)

    for token in (
      "position identity distinguishes same stones with different ordered history",
      "position identity preserves repeated coordinates instead of collapsing to board occupancy",
      "position identity keeps ko capture history distinct from its prior board",
      "position identity includes pass moves",
    ):
      self.assertIn(token, smoke)

    for token in (
      "Position identity builds ordered-history keys with a single reserved String builder",
      "without allocating an intermediate per-move string array",
      "position identity",
    ):
      self.assertIn(token, docs + matrix)

  def test_analysis_setting_changes_clear_stale_visible_analysis(self) -> None:
    view_model = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiViewModel.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    docs = read(ROOT / "docs" / "quality-gates.md")
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")

    for token in (
      "refreshVisibleAnalysisForCurrentSettings()",
      "private func refreshVisibleAnalysisForCurrentSettings()",
      "if selectedEngine == .none",
      "!restoreCachedAnalysisForCurrentPosition()",
      "clearVisibleAnalysisAndRefreshAnchor()",
    ):
      self.assertIn(token, view_model)
    for pattern in (
      r"@Published var komi: Double.*?didSet \{(?P<body>.*?)\n    \}\n  \}",
      r"@Published var rootNoise: Double.*?didSet \{(?P<body>.*?)\n    \}\n  \}",
    ):
      match = re.search(pattern, view_model, re.S)
      self.assertIsNotNone(match)
      self.assertIn("refreshVisibleAnalysisForCurrentSettings()", match.group("body"))
      self.assertLess(
        match.group("body").index("refreshVisibleAnalysisForCurrentSettings()"),
        match.group("body").index("scheduleAnalysisRefresh(reason:"),
      )

    for token in (
      "test_analysis_setting_changes_clear_stale_visible_analysis_immediately",
      "refreshVisibleAnalysisForCurrentSettings()",
      "!restoreCachedAnalysisForCurrentPosition()",
      'self.assertEqual(refresh_body.count("clearVisibleAnalysisAndRefreshAnchor()"), 2)',
    ):
      self.assertIn(token, frontend_contract)
    for token in (
      "Analysis setting changes immediately restore a matching cached analysis",
      "clear candidates and territory before the debounced engine refresh",
      "same root under different komi or root-noise settings",
    ):
      self.assertIn(token, docs + matrix)

  def test_analysis_disabled_preserves_visible_analysis(self) -> None:
    view_model = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiViewModel.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    docs = read(ROOT / "docs" / "quality-gates.md")
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")

    request_body_match = re.search(
      r"private func requestAnalysisIfNeeded\(\n    assumesEngineAlreadyLoaded: Bool = true\n  \) \{(?P<body>.*?)\n  \}",
      view_model,
      re.S,
    )
    self.assertIsNotNone(request_body_match)
    disabled_branch_match = re.search(
      r"guard selectedEngine != \.none else \{(?P<body>.*?)\n    \}",
      request_body_match.group("body"),
      re.S,
    )
    self.assertIsNotNone(disabled_branch_match)
    disabled_branch = disabled_branch_match.group("body")
    self.assertNotIn("clearVisibleAnalysis", disabled_branch)
    self.assertIn('saveSoon(reason: "analysisDisabled")', disabled_branch)
    self.assertNotIn("candidates = []", disabled_branch)
    self.assertNotIn("territory = []", disabled_branch)

    for token in (
      "test_analysis_disabled_preserves_visible_analysis",
      'self.assertNotIn("candidates = []", disabled_branch)',
      'self.assertNotIn("territory = []", disabled_branch)',
    ):
      self.assertIn(token, frontend_contract)
    for token in (
      "Disabled-analysis paths preserve the visible analysis",
      "switching to no engine does not erase the current analysis",
    ):
      self.assertIn(token, docs + matrix)

  def test_non_none_engine_selection_persists_before_loading(self) -> None:
    view_model = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiViewModel.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    docs = read(ROOT / "docs" / "quality-gates.md")
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")

    select_body_match = re.search(
      r"func selectEngine\(_ engine: AnalysisEngine\) \{(?P<body>.*?)\n  \}\n\n  private func startAnalysis",
      view_model,
      re.S,
    )
    self.assertIsNotNone(select_body_match)
    select_body = select_body_match.group("body")
    for token in (
      'saveNow(reason: "beforeEngineSwitch")',
      "selectedEngine = engine",
      'saveNow(reason: "engineSelected")',
      "startAnalysis(\n      engine: engine,\n      assumesEngineAlreadyLoaded: false,",
    ):
      self.assertIn(token, select_body)
    self.assertLess(
      select_body.index('saveNow(reason: "engineSelected")'),
      select_body.index("startAnalysis(\n      engine: engine,\n      assumesEngineAlreadyLoaded: false,"),
    )

    for token in (
      'saveNow(reason: "engineSelected")',
      'select_engine_body.index(\'saveNow(reason: "engineSelected")\')',
      'select_engine_body.index("startAnalysis(\\n      engine: engine,\\n      assumesEngineAlreadyLoaded: false,")',
    ):
      self.assertIn(token, frontend_contract)
    for token in (
      "Non-none engine selection is saved immediately",
      "before engine loading or analysis starts",
      "launch restore preserves",
      "selected model even",
      "loading or analysis fails",
    ):
      self.assertIn(token, docs + matrix)

  def test_candidate_overlay_uses_cached_best_winrate(self) -> None:
    view_model = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiViewModel.swift")
    board = read(ROOT / "qixi-ios-native" / "Qixi" / "BoardView.swift")
    models = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiModels.swift")
    palette = read(ROOT / "qixi-ios-native" / "Qixi" / "CandidatePalette.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    docs = read(ROOT / "docs" / "quality-gates.md")
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")

    for token in (
      "@Published var candidates: [CandidateMove] = [] {",
      "didSet",
      "updateCandidateCaches()",
      "private var bestCandidateWinrate: Double?",
      "private var cachedVisibleCandidates: [CandidateMove] = []",
      "private var cachedVisibleCandidateOverlays: [VisibleCandidateOverlay] = []",
      "var visibleCandidates: [CandidateMove] {\n    cachedVisibleCandidates\n  }",
      "var visibleCandidateOverlays: [VisibleCandidateOverlay] {\n    cachedVisibleCandidateOverlays\n  }",
      "guard let best = bestCandidateWinrate else { return 0 }",
      "private static func bestWinrate(in candidates: [CandidateMove]) -> Double?",
      "private func updateCandidateCaches()",
      "private static func visibleCandidates(",
      "forcedPointID: Int? = nil",
      "cachedVisibleCandidates = Self.visibleCandidates(",
      "cachedVisibleCandidateOverlays = Self.visibleCandidateOverlays(",
      "private static func visibleCandidateOverlays(",
      "overlays.reserveCapacity(visibleCandidates.count + (nextMoveOverlay == nil ? 0 : 1))",
      "rankText: String(candidate.rank)",
      "winrateText: NumberText.winrate(candidate.winrate)",
      "visitsText: String(candidate.visits)",
      "scoreText: NumberText.score(candidate.scoreMean)",
      "colorComponents: CandidatePalette.components(deltaPercent: delta)",
      "for candidate in candidates",
    ):
      self.assertIn(token, view_model)
    self.assertNotIn("candidates.map(\\.winrate).max()", view_model)

    for token in (
      "struct CandidateColorComponents: Equatable",
      "struct VisibleCandidateOverlay: Identifiable, Equatable",
      "var rankText: String",
      "var winrateText: String",
      "var visitsText: String",
      "var scoreText: String",
      "var colorComponents: CandidateColorComponents",
    ):
      self.assertIn(token, models)

    self.assertIn("static func components(deltaPercent k: Double) -> CandidateColorComponents", palette)
    self.assertIn("components(deltaPercent: k).color", palette)

    for token in (
      "for candidate in model.visibleCandidateOverlays",
      "Text(candidate.rankText)",
      "Text(candidate.winrateText)",
      "Text(candidate.visitsText)",
      "Text(candidate.scoreText)",
      "candidate.colorComponents?.color ?? QixiColor.background",
    ):
      self.assertIn(token, board)
    self.assertNotIn("NumberText.winrate(candidate.winrate)", board)
    self.assertNotIn("NumberText.score(candidate.scoreMean)", board)
    self.assertNotIn("model.candidateDelta(candidate)", board)

    for token in (
      'self.assertNotIn("candidates.map(\\\\.winrate).max()", view_model)',
      "cachedVisibleCandidates = Self.visibleCandidates(",
      "cachedVisibleCandidateOverlays = Self.visibleCandidateOverlays(",
      'self.assertNotIn("NumberText.winrate(candidate.winrate)", board)',
    ):
      self.assertIn(token, frontend_contract)

    for token in (
      "Candidate overlay refresh keeps the current best winrate and visible candidate list cached",
      "preformatted candidate labels and color components cached",
      "without allocating per-frame winrate, label-formatting, color-interpolation, or sorted visible-candidate arrays",
      "candidate labels",
    ):
      self.assertIn(token, docs + matrix)

  def test_promotion_update_link_stays_passive_and_released(self) -> None:
    app = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiApp.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    docs = read(ROOT / "docs" / "quality-gates.md")
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")

    for token in (
      "UIUpdateLink(view: self)",
      "CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)",
      "UIUpdateLink is passive by default",
      "link.isEnabled = true",
      "private func releaseFrameRatePreference()",
      "link.isEnabled = false",
      "releaseFrameRatePreference()",
    ):
      self.assertIn(token, app)
    self.assertNotIn("requiresContinuousUpdates =", app)
    self.assertNotIn("wantsLowLatencyEventDispatch =", app)
    self.assertNotIn("wantsImmediatePresentation =", app)

    for token in (
      'self.assertNotIn("requiresContinuousUpdates =", app)',
      'self.assertNotIn("wantsLowLatencyEventDispatch =", app)',
      'self.assertNotIn("wantsImmediatePresentation =", app)',
      'self.assertIn("private func releaseFrameRatePreference()", app)',
      'self.assertIn("link.isEnabled = false", app)',
    ):
      self.assertIn(token, frontend_contract)

    for token in (
      "UIUpdateLink passive",
      "continuous, low-latency, or immediate-presentation updates",
      "released when its host view leaves the window",
    ):
      self.assertIn(token, docs + matrix)

  def test_board_moves_prefix_is_cached_for_board_rendering_hot_path(self) -> None:
    view_model = read(ROOT / "qixi-ios-native" / "Qixi" / "QixiViewModel.swift")
    board = read(ROOT / "qixi-ios-native" / "Qixi" / "BoardView.swift")
    frontend_contract = read(ROOT / "qixi-ios-native" / "tests" / "test_frontend_contract.py")
    docs = read(ROOT / "docs" / "quality-gates.md")
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")

    for token in (
      "@Published var currentPly: Int = 0 {",
      "@Published var mainLine: [BoardMove] {",
      "updateBoardMoveCache()",
      "private var cachedBoardMoves: [BoardMove] = []",
      "private(set) var visibleBoardStones: [VisibleBoardStone] = []",
      "private(set) var visibleStoneColorsByID: [Int: StoneColor] = [:]",
      "private(set) var occupiedBoardPointIDs = Set<Int>()",
      "private func updateBoardMoveCache()",
      "let boundedPly = min(max(0, currentPly), mainLine.count)",
      "cachedBoardMoves = Array(mainLine.prefix(boundedPly))",
      "let stones = QixiBoardPosition.visibleStones(",
      "after: cachedBoardMoves",
      "setupStones: analysisSetupStones",
      "visibleBoardStones = stones",
      "colorsByID.reserveCapacity(stones.count)",
      "occupiedIDs.reserveCapacity(stones.count)",
      "visibleStoneColorsByID = colorsByID",
      "occupiedBoardPointIDs = occupiedIDs",
      "var boardMoves: [BoardMove] {\n    cachedBoardMoves\n  }",
    ):
      self.assertIn(token, view_model)
    board_moves_match = re.search(r"var boardMoves: \[BoardMove\] \{(?P<body>.*?)\n  \}", view_model, re.S)
    self.assertIsNotNone(board_moves_match)
    self.assertNotIn("Array(mainLine.prefix(currentPly))", board_moves_match.group("body"))

    for token in (
      "private var cachedBoardMoves: [BoardMove] = []",
      "visibleBoardStones",
      "visibleStoneColorsByID",
      "occupiedBoardPointIDs",
      "board_moves_body = re.search",
      'self.assertNotIn("Array(mainLine.prefix(currentPly))", board_moves_body.group("body"))',
    ):
      self.assertIn(token, frontend_contract)

    for token in (
      "ForEach(model.visibleBoardStones)",
      "let liveStones = model.visibleStoneColorsByID",
      "let occupied = model.occupiedBoardPointIDs",
    ):
      self.assertIn(token, board)
    self.assertNotIn("QixiBoardPosition.visibleStones(after: model.boardMoves)", board)

    for token in (
      "Board move prefixes are cached",
      "visible stones and occupied-point indexes",
      "without allocating `Array(mainLine.prefix(currentPly))` from board rendering",
      "stone placement",
    ):
      self.assertIn(token, docs + matrix)

  def test_release_evidence_gate_is_non_skippable_and_currently_blocked(self) -> None:
    script = read(ROOT / "scripts" / "qixi-release-evidence-gate.sh")
    docs = read(ROOT / "docs" / "quality-gates.md")
    app_store_doc = read(ROOT / "docs" / "app-store-readiness.md")
    template = read(ROOT / ".github" / "pull_request_template.md")
    matrix = read(ROOT / "docs" / "pr-verification-matrix.md")
    real_device_preflight = read(ROOT / "scripts" / "qixi_real_device_evidence_preflight.py")
    real_device_preflight_tests = read(ROOT / "tests" / "test_real_device_evidence_preflight.py")
    run_kit_preflight = read(ROOT / "scripts" / "qixi_real_device_run_kit_preflight.py")
    run_kit_preflight_tests = read(ROOT / "tests" / "test_real_device_run_kit_preflight.py")
    archive_match = read(ROOT / "scripts" / "qixi_release_evidence_archive_match.py")
    archive_match_tests = read(ROOT / "tests" / "test_release_evidence_archive_match.py")
    native_readme = read(ROOT / "qixi-ios-native" / "README.md")

    for token in (
      "QIXI_DEVICE_BACKEND_URL",
      "QIXI_BACKEND_URL",
      "QIXI_REAL_DEVICE_EVIDENCE",
      "QIXI_REAL_DEVICE_EXPECT_RUNTIME",
      "release evidence requires QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess",
      "httpBridge evidence is only a development smoke",
      "fully native evidence must not set QIXI_DEVICE_BACKEND_URL",
      "or QIXI_BACKEND_URL",
      "omit backend transport entirely",
      "scripts/qixi-real-device-evidence-preflight.sh",
      "release evidence/archive identity match",
      "scripts/qixi_release_evidence_archive_match.py",
      "QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW",
      "QIXI_APPSTORE_ARCHIVE_PATH",
      "QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive is required",
      "QIXI_REQUIRE_APPSTORE_DISTRIBUTION_SIGNATURE=1",
      "App Store archive preflight",
      "scripts/qixi-appstore-archive-preflight.sh",
      "QIXI_SKIP_XCODEBUILD",
      "release evidence must not set QIXI_SKIP_XCODEBUILD",
      "require_xcodebuild_iphoneos",
      "command -v xcodebuild",
      "/usr/bin/xcodebuild",
      "do not shadow xcodebuild in PATH",
      "release evidence requires xcodebuild to resolve to /usr/bin/xcodebuild",
      "xcodebuild -showsdks",
      "iphoneos",
      "release evidence requires xcodebuild in PATH",
      "release evidence requires xcodebuild -showsdks to report an iphoneos SDK",
      "must perform the native Xcode build instead of skipping it",
      "QIXI_APPSTORE_SUBMISSION=1",
      "native linked build preflight",
      "scripts/qixi-native-linked-build-preflight.sh",
      "native release Xcode build preflight",
      "scripts/qixi-native-release-build-preflight.sh",
      "iOS KataGo CMake preflight",
      "QIXI_IOS_SDK=iphoneos",
      "QIXI_IOS_KATAGO_BUILD_TARGET=katago_core",
      "scripts/qixi-ios-katago-cmake-preflight.sh",
      "QIXI_REQUIRE_TRACKED_FILE_AUDIT=1",
      "QIXI_RUN_SCREENSHOTS=1",
      "QIXI_RUN_IOS_KATAGO_CMAKE=1",
      "QIXI_RUN_NATIVE_RELEASE_SIM=1",
      "QIXI_RUN_REAL_MODELS=1",
      "NativeRelease simulator",
      "qixi-ios-native/tests/inspect_screenshot_manifest_artifacts.py",
      "Qixi release evidence gate passed",
    ):
      self.assertIn(token, script)

    for token in (
      "_resolve_regular_artifact",
      "_reject_symlink_path",
      "_is_allowed_platform_symlink_alias",
      "path.resolve(strict=True) == expected_target",
      'pathlib.Path("/var"): pathlib.Path("/private/var")',
      "_reject_symlink_components",
      "_validate_evidence_input_file",
      "_validate_evidence_input_file(evidence_path)",
      "is_symlink()",
      "REAL_DEVICE_EVIDENCE_MAX_BYTES",
      "REAL_DEVICE_EVIDENCE_KIND",
      "SHA256_HEX_PATTERN",
      "PERFORMANCE_ARTIFACT_MAX_BYTES",
      "DEVICE_LOG_ARTIFACT_MAX_BYTES",
      "SCREENSHOT_ARTIFACT_MAX_BYTES",
      "SWIFT_NATIVE_MODEL_REGISTRY_MAX_BYTES",
      "SCREENSHOT_MAX_PIXELS",
      "PNG_HEADER_BYTES",
      "_bounded_text",
      "_bounded_source_text",
      "_opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "must be a regular file after opening",
      "opened-byte-count drift while reading",
      "after opening",
      "_validate_artifact_byte_budget",
      "_artifact_file_fingerprint",
      "artifact {kind} while hashing",
      "opened-byte-count drift while hashing",
      "after opening while hashing",
      "app.executableSHA256HexDigest",
      "raw_parts = raw_path.split(\"/\")",
      "part == \"\" or part == \".\"",
      "must not contain empty or current-directory path components",
      "handle.read(max_bytes + 1)",
      "handle.read(PNG_HEADER_BYTES)",
      "before fingerprinting",
      "Swift native model registry",
      "exceeds bounded source size",
      "artifact is not a regular file",
      "symbolic links",
    ):
      self.assertIn(token, real_device_preflight)
    self.assertNotIn("registry_path.read_text(encoding=\"utf-8\")", real_device_preflight)
    self.assertNotIn("path.read_bytes()[:33]", real_device_preflight)

    for token in (
      "registry-target.swift",
      "SWIFT_NATIVE_MODEL_REGISTRY_MAX_BYTES + 1",
      "Swift native model registry must not contain symbolic links",
      "Swift native model registry exceeds bounded source size",
      "test_bounded_readers_recheck_opened_descriptor_is_regular",
      "test_bounded_readers_recheck_opened_descriptor_byte_count",
      "DirectoryHandle",
      "DriftHandle",
      "real-device evidence JSON opened-byte-count drift while reading",
      "Swift native model registry opened-byte-count drift while reading",
      "test_artifact_fingerprinting_rechecks_opened_descriptor",
      "test_artifact_fingerprinting_rejects_oversized_opened_descriptor",
      "oversized-opened-screenshot.png",
      "artifact screenshot while hashing.*regular file after opening",
      "artifact screenshot opened-byte-count drift while hashing",
      "after opening while hashing",
      "must be a regular file after opening",
      "./ipad-main.png",
      "ipad-main.png/",
      "nested//ipad-main.png",
      "nested/./ipad-main.png",
      "qixi-device-log",
      "must not contain empty or current-directory path components",
      "ipad-main-link.png",
      "linked-artifacts/ipad-main.png",
      "linked-evidence",
      "linked-evidence-root",
      "linked_root / \"sub\" / \"real-device-evidence.json\"",
      "{not-json}",
      "REAL_DEVICE_EVIDENCE_MAX_BYTES + 1",
      "PERFORMANCE_ARTIFACT_MAX_BYTES + 1",
      "DEVICE_LOG_ARTIFACT_MAX_BYTES + 1",
      "SCREENSHOT_ARTIFACT_MAX_BYTES + 1",
      "png_header_only(20_000, 10_000)",
      "positionIdentity",
      "sameVisibleHistoryKeysDistinct",
      "same-visible history keys must be distinct",
      "device-log artifact analysis.positionIdentity.sameVisibleHistoryBKey",
      "write_sparse_file",
      "symbolic links",
    ):
      self.assertIn(token, real_device_preflight_tests)

    for token in (
      "QIXI_REAL_DEVICE_RUN_KIT_DIR",
      "xcode-run-env-template.txt still contains placeholder values",
      "nativeInProcess run-kit preflight must not inherit backend environment",
      "QIXI_AUTOMATION_SELECT_ENGINE must be b6, b18nbt, or b28nbt",
      "QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH",
      "requiredArtifacts must not duplicate artifact kind",
      "requiredArtifacts must not duplicate artifact path",
      "requiredArtifacts contains unsupported artifact kind",
      "requiredArtifacts must contain exactly screenshot, performance, and device-log",
      "REQUIRED_FINAL_ARTIFACT_PRODUCERS",
      "requiredArtifacts.{kind}.producer",
      "requiredArtifacts.{kind}.mustBeTemplate",
      "mustBeTemplate must be false",
      "real-device-performance.json must not be the template JSON",
      "real-device-log.json must not exist before the final evidence finalization launch",
      'f"{filename} must not exist before the final evidence finalization launch; the app must write it"',
      "{label} must be a PNG file",
      "SCREENSHOT_ARTIFACT_MAX_BYTES",
      "opened-byte-count drift while reading",
      "Image.open(io.BytesIO(image_data))",
      "SCREENSHOT_MAX_PIXELS",
      "{label} must be a decodable PNG image",
      "{label} looks blank or nearly flat",
      "{label} lacks visible board/grid detail",
      "real-device performance artifact source must be instruments, xctrace, or metricKit",
      "real-device performance artifact {env_key} must match xcode-run-env-template.txt",
      "QIXI_REAL_DEVICE_OBSERVED_REFRESH_HZ",
      "QIXI_REAL_DEVICE_DROPPED_FRAME_PERCENT",
    ):
      self.assertIn(token, run_kit_preflight)

    for token in (
      "test_accepts_filled_run_kit_before_finalization_launch",
      "DriftHandle",
      "test_bounded_readers_recheck_opened_descriptor_byte_count",
      "artifact-requirements.json opened-byte-count drift while reading",
      "real-device run-kit Xcode environment template opened-byte-count drift while reading",
      "real-device screenshot artifact opened-byte-count drift while reading",
      "test_screenshot_visual_decode_uses_same_bounded_bytes",
      "self.assertIsInstance(opened_from[0], io.BytesIO)",
      "test_rejects_placeholders_or_backend_transport",
      "test_rejects_template_or_mismatched_performance_artifact",
      "test_rejects_ambiguous_required_artifact_manifest_entries",
      "duplicate artifact kind: screenshot",
      "duplicate artifact path",
      "unsupported artifact kind: trace",
      "must contain exactly",
      "test_rejects_required_artifact_manifest_metadata_drift",
      "simulator screenshot",
      "requiredArtifacts.screenshot.producer",
      "requiredArtifacts.performance.mustBeTemplate must be false",
      "requiredArtifacts.device-log.mustBeTemplate must be a boolean",
      "test_rejects_preexisting_app_written_outputs",
      "test_rejects_symlinked_artifact_and_weak_screenshot",
      "png_header_only",
      "decodable PNG",
      "blank or nearly flat",
      "too large for bounded visual inspection",
      "real-device-evidence.export.json",
      "real-device-performance.json",
      "real-device-log.json",
    ):
      self.assertIn(token, run_kit_preflight_tests)

    for token in (
      "REAL_DEVICE_EVIDENCE_MAX_BYTES",
      "REAL_DEVICE_EVIDENCE_SCHEMA_VERSION",
      "REAL_DEVICE_EVIDENCE_KIND",
      "ARCHIVE_PLIST_MAX_BYTES",
      "ARCHIVE_EXECUTABLE_MAX_BYTES",
      "VALID_RUNTIMES",
      "SHA256_HEX_PATTERN",
      "_bounded_bytes",
      "_sha256_hex_digest",
      "_opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "must be a regular file after opening",
      "opened-byte-count drift while reading",
      "opened-byte-count drift while hashing",
      "while hashing",
      "_runtime",
      "_reject_symlink_components",
      "_validate_regular_file",
      "_validate_directory",
      "_archive_application_path",
      "_archive_executable_name",
      "CFBundleExecutable",
      "archive app executable SHA-256",
      "real-device evidence schemaVersion must be",
      "real-device evidence kind must be",
      "_runtime(app.get(\"analysisRuntime\")",
      "_runtime(\n    app_info.get(\"QixiAnalysisRuntime\")",
      "real-device evidence app.executableSHA256HexDigest",
      "must not traverse outside Products",
      "handle.read(max_bytes + 1)",
      "path.resolve(strict=True) == expected_target",
      'pathlib.Path("/var"): pathlib.Path("/private/var")',
    ):
      self.assertIn(token, archive_match)
    self.assertNotIn("path.read_text(encoding=\"utf-8\")", archive_match)
    self.assertNotIn("path.read_bytes()", archive_match)

    for token in (
      "linked-real-device-evidence.json",
      "linked-Qixi.xcarchive",
      "Qixi-target.app",
      "REAL_DEVICE_EVIDENCE_MAX_BYTES + 1",
      "ARCHIVE_PLIST_MAX_BYTES + 1",
      "test_bounded_readers_recheck_opened_descriptor_is_regular",
      "DirectoryHandle",
      "DriftHandle",
      "test_bounded_readers_recheck_opened_descriptor_byte_count",
      "real-device evidence JSON opened-byte-count drift while reading",
      "test_hash_rechecks_opened_descriptor_byte_count",
      "archive app executable opened-byte-count drift while hashing",
      "must be a regular file after opening",
      "executableSHA256HexDigest",
      "CFBundleExecutable",
      "archive app executable",
      "stale schema",
      "qixi-device-log",
      "sidecarRuntime",
      "same invalid runtime",
      "invalid archive runtime",
      "../Escaped.app",
      "write_sparse_file",
    ):
      self.assertIn(token, archive_match_tests)

    for token in (
      "Release evidence gate",
      "non-skippable gate",
      "QIXI_REAL_DEVICE_EVIDENCE",
      "QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess",
      "QIXI_APPSTORE_ARCHIVE_PATH",
      "QIXI_BACKEND_URL",
      "scripts/qixi-real-device-evidence-preflight.sh",
      "machine-checkable evidence JSON",
      "must omit the `backend` object entirely",
      "QIXI_APPSTORE_SUBMISSION=1",
      "scripts/qixi-native-linked-build-preflight.sh",
      "scripts/qixi-native-release-build-preflight.sh",
      "QIXI_IOS_SDK=iphoneos QIXI_IOS_KATAGO_BUILD_TARGET=katago_core scripts/qixi-ios-katago-cmake-preflight.sh",
      "full screenshot matrix",
      "`QIXI_RUN_NATIVE_RELEASE_SIM=1` NativeRelease simulator smoke",
      "real-model integration",
      "expected to fail in the current development state",
      "placeholder native engine",
      "release gate rejects development skip switches such as `QIXI_SKIP_XCODEBUILD`",
      "release proof must include the native Xcode build",
      "`xcodebuild` is not in `PATH`",
      "`xcodebuild` does not resolve to `/usr/bin/xcodebuild`",
      "shadowed `xcodebuild`",
      "`xcodebuild -showsdks` does not\nreport an `iphoneos` SDK",
      "development-friendly\nXcode skip is not release evidence",
      "QIXI_REQUIRE_TRACKED_FILE_AUDIT=1",
      "QIXI_RUN_IOS_KATAGO_CMAKE=1",
      "QIXI_RUN_NATIVE_RELEASE_SIM=1",
      "release pass cannot omit the\nSimulator+device iOS KataGo CMake path",
      "runnable linked NativeRelease Simulator\nsmoke",
      "repository hygiene\ncannot silently skip the tracked-file audit",
      "validates `QIXI_APPSTORE_ARCHIVE_PATH` as a real `.xcarchive`",
      "scripts/qixi_release_evidence_archive_match.py",
      "ApplicationProperties.CFBundleIdentifier",
      "ApplicationProperties.CFBundleShortVersionString",
      "ApplicationProperties.CFBundleVersion",
      "app.bundleIdentifier",
      "app.version",
      "app.build",
      "app.analysisRuntime",
      "CFBundleIdentifier",
      "CFBundleShortVersionString",
      "CFBundleVersion",
      "QixiAnalysisRuntime",
      "evidence from one build cannot be paired with another",
      "different runtime",
      "runtime fields must be one of `httpBridge` or `nativeInProcess`",
      "match step rejects symbolic links",
      "bounds the evidence JSON and archive plist reads",
      "requires archive `ApplicationPath` to stay inside `Products`",
      "top-level\narchive `Info.plist`",
      "`ArchiveVersion`",
      "plist `CreationDate`",
      "`SchemeName = Qixi`",
      "ApplicationProperties.SigningIdentity",
      "ApplicationProperties.Team",
      "app-matching version fields",
      "Products/Applications/Qixi.app",
      "PrivacyInfo.xcprivacy",
      "iPhoneOS app executable",
      "arm64 iOS device",
      "`MH_EXECUTE`",
      "Mach-O",
      "code signature",
      "codesign --verify --deep --strict",
      "release evidence signature",
      "ad-hoc",
      "`Apple Distribution`",
      "`iPhone Distribution`",
      "archived `Info.plist`",
      "camera/photo/local-network usage descriptions",
      "safe ATS local-network policy",
      "export-compliance metadata",
      "ProMotion support",
      "version strings",
      "exact `CFBundleSupportedPlatforms = [iPhoneOS]`",
      "exact `UIDeviceFamily = [1,2]`",
      "`MinimumOSVersion >= 17.0`",
      "archived `PrivacyInfo.xcprivacy`",
      "UserDefaults reason `CA92.1`",
      "signed entitlements",
      "Qixi iCloud containers",
      "`CloudDocuments`",
      "team identifier",
      "bundle-suffixed `application-identifier`",
      "disabled `get-task-allow`",
      "real iOS KataGo library or XCFramework",
      "substantial defined-symbol surface",
        "KataGo-like C++ symbol",
        "broad",
        "fragment names",
        "symbolic links in configured",
        "bounds source/plist reads before",
        "XCFramework `LibraryIdentifier` plus `LibraryPath` entries",
        "remain inside the XCFramework",
        "QIXI_KATAGO_IOS_XCFRAMEWORK",
        "QIXI_KATAGO_IOS_LIBRARY",
        "QIXI_KATAGO_IOS_LIBRARY_DIR",
        "native release Xcode build preflight",
        "scripts/qixi-native-release-build-preflight.sh",
        "Metal/Accelerate/CoreML/MPS/MPSGraph plus zlib",
        "matching `libKataGoSwift.a` sidecar",
      "defaults `QixiAnalysisRuntime`",
      "to `nativeInProcess`",
      "CMAKE_OSX_SYSROOT=iphoneos",
      "CMAKE_Swift_COMPILER_TARGET=arm64-apple-ios17.0",
      "CMAKE_Swift_COMPILER_TARGET=arm64-apple-ios17.0-simulator",
      "KATAGO_METAL_ENABLE_COREML_CONVERSION=0",
      "Protobuf/abseil",
      "katagocoreml",
      "directly under `/private/tmp` or\n`/tmp`",
      "`qixi-ios-katago-cmake-preflight-`",
      "contain no symbolic-link\npath components",
      "`libkatago_core.a`",
      "`libKataGoSwift.a`",
      "`katago.app/katago`",
      "`lipo` and `otool`",
      "expected iOS/iOS Simulator Mach-O platform",
      "no non-target platform object files",
      ".mlpackage",
      ".mlmodelc",
      "fully in-process KataGo execution on a physical iPad",
      "device-log artifact must be structured JSON",
      "artifact paths must be unique portable relative paths",
      "Reserved release evidence and export-audit filenames are rejected",
      "artifact paths must not resolve to the current evidence JSON path",
      "`QIXI_REAL_DEVICE_EVIDENCE_OUTPUT`",
      "relative outputs must be portable POSIX paths without traversal",
      "export-audit filename is\nrejected before evidence is written",
      "app-side automation export also rejects",
      "`QIXI_BACKEND_URL` and `QIXI_DEVICE_BACKEND_URL` for `nativeInProcess`",
      "validates custom evidence output paths, constructs evidence, fingerprints\nartifacts",
      "touches native model/tombstone state",
      "does not create or retain the final evidence JSON, export\naudit, screenshot",
      "`real-device-evidence.export.json`",
      "`real-device-main.png`",
      "`real-device-performance.json`",
      "`real-device-log.json`",
      "Symbolic links are rejected",
      "relative evidence paths cannot escape",
      "record file byte count and lowercase SHA-256 digest",
      "recomputes both before inspecting artifact content",
      "before recomputing SHA-256",
      "evidence `recordedAt` timestamp must be recent",
      "top-level `runId`",
      "same `runId`",
      "bounded staging window",
      "visual variance plus dark board/grid detail",
      "qixi-real-device-log",
      "analysis.nativeEngine.engineId",
      "analysis.nativeEngine.modelSHA256HexDigest",
      "analysis.nativeEngine.coreMLPackages",
      "analysis.nativeEngine.tombstoneRestoredAt",
      "analysis.positionIdentity",
      "sameVisibleHistoryKeysDistinct",
      "qixi-real-device-performance",
      "schemaVersion = 1",
      "performance artifact.source",
    ):
      self.assertIn(token, docs)

    for token in (
      "standalone real-device evidence preflight enforces the same",
      "runtime/transport split",
      "scripts/qixi_release_evidence_archive_match.py",
      "ApplicationProperties.CFBundleIdentifier",
      "ApplicationProperties.CFBundleShortVersionString",
      "ApplicationProperties.CFBundleVersion",
      "app.bundleIdentifier",
      "app.version",
      "app.build",
      "app.analysisRuntime",
      "app.executableSHA256HexDigest",
      "CFBundleShortVersionString",
      "archived executable SHA-256",
      "real iPad run from an older, different, or non-native",
      "When `QIXI_REAL_DEVICE_EXPECT_RUNTIME` is set",
      "evidence/archive `QixiAnalysisRuntime`",
        "expected runtime",
        "current real-device evidence schema and kind",
        "Both runtime fields must be one of `httpBridge` or\n`nativeInProcess`",
        "non-native\nbuild cannot be reused",
      "hashes the archived app executable in bounded\nchunks",
      "archive `ApplicationPath` and `CFBundleExecutable`",
      "app executable SHA-256",
      "exactly one\nexisting non-empty artifact",
      "Unknown or duplicated",
      "artifact kinds are rejected",
      "Artifact paths must be unique portable relative paths",
      "absolute paths, home-relative paths",
      "empty segments, `.` segments",
      "parent-directory traversal are rejected",
      "Artifact paths must also not use reserved",
      "must not resolve to the\ncurrent evidence JSON path",
      "Artifact paths must not contain symbolic links",
      "cannot secretly point outside the evidence bundle",
      "Each artifact entry must also record the file",
      "byte count and lowercase SHA-256 digest",
      "tampered or swapped artifact files cannot satisfy",
      "before computing the artifact SHA-256",
      "top-level\n`recordedAt` timestamp must be recent",
      "top-level `runId`",
      "same `runId`",
      "`QIXI_REAL_DEVICE_RECORDED_AT`",
      "`QIXI_REAL_DEVICE_RUN_ID`",
      "`QIXI_REAL_DEVICE_EVIDENCE_OUTPUT`",
      "relative paths must be portable\nPOSIX paths",
      "non-JSON outputs",
      "export-audit filename",
      "app-side automation export repeats the same boundary",
      "before validating custom evidence output paths",
      "constructing evidence, fingerprinting artifacts",
      "touching native\nmodel/tombstone state",
      "`real-device-evidence.export.json`",
      "`real-device-main.png`",
      "`real-device-performance.json`",
      "`real-device-log.json`",
      "PNG signature",
      "landscape dimensions",
      "at least `1000x700` for iPad",
      "at least `800x350` for iPhone",
      "decode as real PNG",
      "visual variance plus dark board/grid detail",
      "blank, flat, or header-only placeholder",
      "positive-integer visits and candidate counts",
      "finite\nlaunch/memory/frame-pacing measurements",
      "standards-compliant JSON",
      "rejects duplicate object keys",
      "`NaN`/`Infinity`",
      "non-finite-number behavior",
      "last-key-wins",
      "Performance artifacts must be JSON",
      "`schemaVersion = 1`",
      "`kind = qixi-real-device-performance`",
      "source of `instruments`, `xctrace`, or `metricKit`",
      "`measurements.launch`, `measurements.memory`, and",
      "`measurements.framePacing` values, a matching `runId`, and a bounded staged `recordedAt`",
      "`nativeInProcess` memory measurements must not exceed",
      "`maximumMemoryMB`",
      "placeholder or stale Instruments export cannot satisfy",
      "Device-log artifacts must be JSON objects",
      "`schemaVersion = 1`",
      "`kind = qixi-real-device-log`",
      "their `runId`, exact `recordedAt`, device, app",
      "nativeInProcess device-log artifacts must also carry matching",
      "`analysis.nativeEngine`",
      "`analysis.nativeEngine.engineId`",
      "`analysis.nativeEngine.coreMLPackages`",
      "generic text log",
      "log from another run cannot be reused",
      "`nm` for KataGo core symbol fragments",
      "`AsyncBot`, `BoardHistory`, `NNEvaluator`, and `Search`",
      "empty or unrelated",
      "iOS library cannot satisfy the release linked-build proof",
      "Bridge evidence must not include",
      "analysis.nativeEngine",
      "Fully native evidence must include",
      "stream-verify the selected model's SHA-256 digest",
      "model resource name, byte count, SHA-256 digest",
      "CoreML package resource name, variant, file count, total byte count, and tree digest",
      "tombstone audit timestamps",
      "release evidence freshness window",
      "Do not set development skip switches such as `QIXI_SKIP_XCODEBUILD`",
      "Submission evidence must include the native Xcode build",
      "`xcodebuild` is not in `PATH`",
      "`xcodebuild` does not resolve to `/usr/bin/xcodebuild`",
      "shadowed `xcodebuild`",
      "must never inherit the default quality gate's development-friendly\nXcode skip",
      "`xcodebuild -showsdks` to report an `iphoneos` SDK",
      "release gate also forces `QIXI_REQUIRE_TRACKED_FILE_AUDIT=1`",
      "`QIXI_RUN_IOS_KATAGO_CMAKE=1`",
      "`QIXI_RUN_NATIVE_RELEASE_SIM=1`",
      "cannot omit the Simulator+device iOS\nKataGo CMake path",
      "runnable linked NativeRelease Simulator smoke",
      "cannot evade the\ntracked-file audit",
      "requires `QIXI_APPSTORE_ARCHIVE_PATH`",
      "scripts/qixi-appstore-archive-preflight.sh",
      "`ArchiveVersion`",
      "plist `CreationDate`",
      "`SchemeName = Qixi`",
      "ApplicationProperties.SigningIdentity",
      "ApplicationProperties.Team",
      "app-matching version fields",
      "Products/Applications/Qixi.app",
      "iPhoneOS app executable",
      "arm64 iOS device",
      "`MH_EXECUTE`",
      "Mach-O",
      "code signature",
      "codesign --verify --deep --strict",
      "ad-hoc release signatures",
      "`Apple Distribution`",
      "`iPhone Distribution`",
      "archived `Info.plist`",
      "camera/photo/local-network usage descriptions",
      "safe ATS local-network policy",
      "export-compliance metadata",
      "ProMotion support",
      "version strings",
      "exact `CFBundleSupportedPlatforms = [iPhoneOS]`",
      "exact `UIDeviceFamily = [1,2]`",
      "`MinimumOSVersion >= 17.0`",
      "signed entitlements",
      "Qixi iCloud containers",
      "`CloudDocuments`",
      "team identifier",
      "bundle-suffixed `application-identifier`",
      "disabled `get-task-allow`",
      "rejects archived `QixiBackendBaseURL`",
      "bundled `PrivacyInfo.xcprivacy`",
      "UserDefaults reason `CA92.1`",
      "no tracking domains or collected data",
      "bounded local file-size guards before decode/import",
      "QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess",
      "QIXI_AUTOMATION_SELECT_ENGINE",
      "QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH",
      "scripts/qixi-real-device-run-kit-preflight.sh",
      "QIXI_DEVICE_BACKEND_URL",
      "QIXI_BACKEND_URL",
    ):
      self.assertIn(token, app_store_doc)

    self.assertIn("scripts/qixi-release-evidence-gate.sh", template)
    self.assertIn("scripts/qixi-real-device-evidence-preflight.sh", template)
    self.assertIn("scripts/qixi-release-evidence-gate.sh", matrix)
    self.assertIn("scripts/qixi-real-device-evidence-preflight.sh", matrix)
    self.assertIn("scripts/qixi_release_evidence_archive_match.py", matrix)
    self.assertIn("release/App Store readiness", matrix)

    readme = read(ROOT / "README.md")
    release_example_start = readme.index("QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess")
    release_example_end = readme.index("This gate is expected to fail", release_example_start)
    release_example = readme[release_example_start:release_example_end]
    self.assertNotIn("QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765", release_example)
    evidence_check_start = readme.index("Check the recorded real-device evidence JSON")
    evidence_check_end = readme.index("Check that generated logs", evidence_check_start)
    evidence_check = readme[evidence_check_start:evidence_check_end]
    self.assertIn("QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess", evidence_check)
    self.assertIn("scripts/qixi-real-device-evidence-preflight.sh", evidence_check)
    self.assertNotIn("QIXI_DEVICE_BACKEND_URL", evidence_check)
    self.assertIn("QIXI_BACKEND_URL", readme)
    self.assertIn("any backend transport belongs", readme)
    self.assertIn("only to development bridge evidence", readme)
    self.assertIn("QIXI_AUTOMATION_SELECT_ENGINE=b6", readme)
    self.assertIn("scripts/qixi-real-device-run-kit-preflight.sh /tmp/qixi-real-device-run", readme)
    self.assertIn("b18nbt", readme)
    self.assertIn("b28nbt", readme)
    self.assertIn("tracked-file audit, full screenshots, real-model integrations", readme)
    self.assertIn("Simulator+device iOS KataGo CMake path", readme)
    self.assertIn("runnable linked NativeRelease\nSimulator smoke", readme)
    self.assertIn("fails if `xcodebuild` is not\navailable", readme)
    self.assertIn("does not resolve to `/usr/bin/xcodebuild`", readme)
    self.assertIn("shadowed `xcodebuild`", readme)
    self.assertIn("`xcodebuild -showsdks` does not report an `iphoneos` SDK", readme)

    for token in (
      "For a physical `nativeInProcess` release run",
      "scripts/qixi-real-device-evidence-template.py --output-dir /tmp/qixi-real-device-run",
      "refusing inherited backend URLs",
      "`real-device-evidence.qixi-release.json`",
      "`real-device-evidence.export.json`",
      "`real-device-main.png`",
      "`real-device-performance.json`",
      "`real-device-log.json`",
      "`real-device-performance.template.json`",
      "`real-device-log.template.json`",
      "QIXI_AUTOMATION_SELECT_ENGINE",
      "QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH",
      "scripts/qixi-real-device-run-kit-preflight.sh /tmp/qixi-real-device-run",
      "must still be\ngenerated on a real iPad or iPhone",
      "scripts/qixi-real-device-evidence-preflight.sh",
    ):
      self.assertIn(token, native_readme)

    result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-release-evidence-gate.sh")],
      cwd=ROOT,
      env=hermetic_qixi_env(),
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("Release evidence gate failed:", result.stderr)
    self.assertIn("QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json", result.stderr)

    env = hermetic_qixi_env(
      QIXI_REAL_DEVICE_EVIDENCE="/tmp/qixi-native-evidence.json",
      QIXI_REAL_DEVICE_EXPECT_RUNTIME="nativeInProcess",
      QIXI_DEVICE_BACKEND_URL="http://192.168.1.23:8765",
    )
    native_bridge_mix_result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-release-evidence-gate.sh")],
      cwd=ROOT,
      env=env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(native_bridge_mix_result.returncode, 0)
    self.assertIn(
      "fully native evidence must not set QIXI_DEVICE_BACKEND_URL",
      native_bridge_mix_result.stderr,
    )
    self.assertIn("omit backend transport entirely", native_bridge_mix_result.stderr)
    self.assertNotIn("QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW", native_bridge_mix_result.stderr)

    env = hermetic_qixi_env(
      QIXI_REAL_DEVICE_EVIDENCE="/tmp/qixi-native-evidence.json",
      QIXI_REAL_DEVICE_EXPECT_RUNTIME="nativeInProcess",
      QIXI_BACKEND_URL="http://192.168.1.23:8765",
    )
    legacy_bridge_mix_result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-release-evidence-gate.sh")],
      cwd=ROOT,
      env=env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(legacy_bridge_mix_result.returncode, 0)
    self.assertIn(
      "fully native evidence must not set QIXI_DEVICE_BACKEND_URL or QIXI_BACKEND_URL",
      legacy_bridge_mix_result.stderr,
    )
    self.assertNotIn("QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW", legacy_bridge_mix_result.stderr)

    env = hermetic_qixi_env(
      QIXI_REAL_DEVICE_EVIDENCE="/tmp/qixi-native-evidence.json",
      QIXI_REAL_DEVICE_EXPECT_RUNTIME="nativeInProcess",
      QIXI_APPSTORE_ARCHIVE_PATH="/tmp/Qixi.xcarchive",
      QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW="1",
      QIXI_SKIP_XCODEBUILD="1",
    )
    skip_build_result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-release-evidence-gate.sh")],
      cwd=ROOT,
      env=env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(skip_build_result.returncode, 0)
    self.assertIn("release evidence must not set QIXI_SKIP_XCODEBUILD", skip_build_result.stderr)
    self.assertNotIn("real-device evidence preflight", skip_build_result.stdout)

    with tempfile.TemporaryDirectory() as missing_xcode_dir:
      temp_bin = pathlib.Path(missing_xcode_dir) / "bin"
      temp_bin.mkdir()
      (temp_bin / "bash").symlink_to("/bin/bash")
      (temp_bin / "dirname").symlink_to("/usr/bin/dirname")
      missing_xcode_env = hermetic_qixi_env()
      missing_xcode_env["PATH"] = str(temp_bin)
      missing_xcode_env["QIXI_REAL_DEVICE_EVIDENCE"] = "/tmp/qixi-native-evidence.json"
      missing_xcode_env["QIXI_REAL_DEVICE_EXPECT_RUNTIME"] = "nativeInProcess"
      missing_xcode_env["QIXI_APPSTORE_ARCHIVE_PATH"] = "/tmp/Qixi.xcarchive"
      missing_xcode_env["QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW"] = "1"
      missing_xcode_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-release-evidence-gate.sh")],
        cwd=ROOT,
        env=missing_xcode_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(missing_xcode_result.returncode, 0)
      self.assertIn("release evidence requires xcodebuild in PATH", missing_xcode_result.stderr)
      self.assertNotIn("==> App Store archive preflight", missing_xcode_result.stdout)

    with tempfile.TemporaryDirectory() as fake_xcode_dir:
      temp_bin = pathlib.Path(fake_xcode_dir) / "bin"
      temp_bin.mkdir()
      (temp_bin / "bash").symlink_to("/bin/bash")
      (temp_bin / "dirname").symlink_to("/usr/bin/dirname")
      fake_xcodebuild = temp_bin / "xcodebuild"
      fake_xcodebuild.write_text(
        "#!/bin/bash\n"
        "if [[ \"$1\" == \"-showsdks\" ]]; then\n"
        "  echo 'macOS SDKs:'\n"
        "  echo '  macOS 26.5 -sdk macosx26.5'\n"
        "  exit 0\n"
        "fi\n"
        "exit 0\n",
        encoding="utf-8",
      )
      fake_xcodebuild.chmod(0o755)
      fake_xcode_env = hermetic_qixi_env()
      fake_xcode_env["PATH"] = str(temp_bin)
      fake_xcode_env["QIXI_REAL_DEVICE_EVIDENCE"] = "/tmp/qixi-native-evidence.json"
      fake_xcode_env["QIXI_REAL_DEVICE_EXPECT_RUNTIME"] = "nativeInProcess"
      fake_xcode_env["QIXI_APPSTORE_ARCHIVE_PATH"] = "/tmp/Qixi.xcarchive"
      fake_xcode_env["QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW"] = "1"
      fake_xcode_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-release-evidence-gate.sh")],
        cwd=ROOT,
        env=fake_xcode_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(fake_xcode_result.returncode, 0)
      self.assertIn(
        "release evidence requires xcodebuild to resolve to /usr/bin/xcodebuild",
        fake_xcode_result.stderr,
      )
      self.assertIn("do not shadow xcodebuild in PATH", fake_xcode_result.stderr)
      self.assertNotIn("==> App Store archive preflight", fake_xcode_result.stdout)

    env = hermetic_qixi_env(
      QIXI_REAL_DEVICE_EVIDENCE="/tmp/qixi-native-evidence.json",
      QIXI_REAL_DEVICE_EXPECT_RUNTIME="nativeInProcess",
      QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW="1",
    )
    missing_archive_result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-release-evidence-gate.sh")],
      cwd=ROOT,
      env=env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(missing_archive_result.returncode, 0)
    self.assertIn("QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive is required", missing_archive_result.stderr)
    self.assertNotIn("==> App Store archive preflight", missing_archive_result.stdout)
    self.assertNotIn("==> real-device evidence preflight", missing_archive_result.stdout)

    with tempfile.TemporaryDirectory() as raw_dir:
      evidence_dir = pathlib.Path(raw_dir)
      archive_path = write_minimal_appstore_archive(evidence_dir)
      archive_executable_digest = hashlib.sha256(
        (archive_path / "Products" / "Applications" / "Qixi.app" / "Qixi").read_bytes()
      ).hexdigest()
      recorded_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0) - datetime.timedelta(hours=1)
      recorded_at_text = isoformat_z(recorded_at)
      run_id = "00000000-0000-4000-8000-000000000001"
      measurements = {
        "launch": {"coldLaunchMs": 900, "visualReadyMs": 1400},
        "memory": {"peakRSSMB": 620, "postAnalysisRSSMB": 590},
        "framePacing": {
          "targetRefreshHz": 120,
          "observedRefreshHz": 118,
          "droppedFramePercent": 1.2,
        },
      }
      artifacts = []
      for kind, filename in (
        ("screenshot", "ipad-main.png"),
        ("performance", "instruments.json"),
        ("device-log", "device.log"),
      ):
        artifact = evidence_dir / filename
        if kind == "screenshot":
          artifact.write_bytes(png_with_dimensions(1200, 800))
        elif kind == "performance":
          artifact.write_text(
            json.dumps(
              {
                "source": "instruments",
                "schemaVersion": 1,
                "kind": "qixi-real-device-performance",
                "runId": run_id,
                "recordedAt": recorded_at_text,
                "measurements": measurements,
              },
              sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
          )
        artifacts.append({"kind": kind, "path": filename})
      evidence_payload = {
        "schemaVersion": 5,
        "kind": "qixi-real-device-evidence",
        "runId": run_id,
        "recordedAt": recorded_at_text,
        "device": {
          "idiom": "iPad",
          "model": "iPad Pro 13-inch (M5)",
          "osVersion": "iPadOS 26.5",
          "simulator": False,
        },
        "app": {
          "bundleIdentifier": "com.qixi.localanalysis",
          "version": "1.0",
          "build": "1",
          "analysisRuntime": "httpBridge",
          "executableSHA256HexDigest": archive_executable_digest,
        },
        "backend": {
          "url": "http://192.168.1.23:8765",
          "status": {
            "engine": "katago-metal-mux:b6",
            "engineId": "b6",
            "state": "running",
            "running": True,
            "paused": False,
          },
        },
        "analysis": {
          "engineId": "b6",
          "realModel": True,
          "visits": 128,
          "candidateCount": 8,
          "ownershipSource": "mcts",
        },
        "measurements": measurements,
        "lifecycle": {
          "backgroundedSeconds": 30,
          "autosaveWritten": True,
          "tombstoneWritten": True,
          "restoredLatestState": True,
        },
        "features": {
          "cameraRecognitionTested": True,
          "iCloudSyncTested": True,
          "modelImportTested": True,
        },
        "artifacts": artifacts,
      }
      (evidence_dir / "device.log").write_text(
        json.dumps(
          {
            "schemaVersion": 1,
            "kind": "qixi-real-device-log",
            "runId": evidence_payload["runId"],
            "recordedAt": evidence_payload["recordedAt"],
            "device": evidence_payload["device"],
            "app": evidence_payload["app"],
            "backend": evidence_payload["backend"],
            "analysis": evidence_payload["analysis"],
            "lifecycle": evidence_payload["lifecycle"],
            "features": evidence_payload["features"],
          },
          sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
      )
      for artifact_kind in ("screenshot", "performance", "device-log"):
        refresh_artifact_metadata(artifacts, evidence_dir, artifact_kind)
      evidence_path = evidence_dir / "real-device-evidence.json"
      evidence_path.write_text(
        json.dumps(evidence_payload, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
      )

      env = os.environ.copy()
      env["QIXI_DEVICE_BACKEND_URL"] = "http://192.168.1.23:8765"
      env["QIXI_REAL_DEVICE_EVIDENCE"] = str(evidence_path)
      env["QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW"] = "1"
      env["QIXI_APPSTORE_ARCHIVE_PATH"] = str(archive_path)
      result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-release-evidence-gate.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(result.returncode, 0)
      self.assertNotIn("==> real-device evidence preflight", result.stdout)
      self.assertNotIn("==> App Store submission preflight", result.stdout)
      self.assertIn(
        "release evidence requires QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess",
        result.stderr,
      )
      self.assertIn(
        "httpBridge evidence is only a development smoke",
        result.stderr,
      )

      native_payload = json.loads(evidence_path.read_text(encoding="utf-8"))
      native_payload["app"]["analysisRuntime"] = "nativeInProcess"
      native_payload.pop("backend")
      native_payload["analysis"]["nativeEngine"] = {
        "modelDigestVerified": True,
        "engineId": "b6",
        "modelResourceName": "g170-b6c96-s175395328-d26788732.bin.gz",
        "modelByteCount": 3827339,
        "modelSHA256HexDigest": "f5d32604e3675c480c7c8f6aa579a1ea857135628a0afccc8fa56330fbacd38d",
        "coreMLPackages": [],
        "tombstoneExported": True,
        "tombstoneFilename": "native-engine-tombstone.qixi-native",
        "tombstoneExportedAt": isoformat_z(recorded_at - datetime.timedelta(minutes=2)),
        "tombstoneRestored": True,
        "tombstoneRestoredAt": isoformat_z(recorded_at - datetime.timedelta(minutes=1)),
      }
      native_evidence_path = evidence_dir / "native-real-device-evidence.json"
      (evidence_dir / "device.log").write_text(
        json.dumps(
          {
            "schemaVersion": 1,
            "kind": "qixi-real-device-log",
            "runId": native_payload["runId"],
            "recordedAt": native_payload["recordedAt"],
            "device": native_payload["device"],
            "app": native_payload["app"],
            "analysis": native_payload["analysis"],
            "lifecycle": native_payload["lifecycle"],
            "features": native_payload["features"],
          },
          sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(native_payload["artifacts"], evidence_dir, "device-log")
      native_evidence_path.write_text(
        json.dumps(native_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
      )
      env = hermetic_qixi_env(
        QIXI_REAL_DEVICE_EXPECT_RUNTIME="nativeInProcess",
        QIXI_REAL_DEVICE_EVIDENCE=str(native_evidence_path),
        QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW="1",
        QIXI_APPSTORE_ARCHIVE_PATH=str(archive_path),
      )
      native_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-release-evidence-gate.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(native_result.returncode, 0)
      self.assertIn("==> App Store archive preflight", native_result.stdout)
      self.assertNotIn("==> real-device evidence preflight", native_result.stdout)
      self.assertNotIn("==> App Store submission preflight", native_result.stdout)
      self.assertNotIn("==> strict physical-device backend preflight", native_result.stdout)
      self.assertIn("archive app signature must not be ad-hoc for release evidence", native_result.stderr)

  def test_device_run_preflight_guards_against_false_device_evidence(self) -> None:
    wrapper = read(ROOT / "scripts" / "qixi-device-run-preflight.sh")
    script = read(ROOT / "scripts" / "qixi_device_run_preflight.py")
    unit = read(ROOT / "tests" / "test_device_run_preflight.py")
    self.assertIn("qixi_device_run_preflight.py", wrapper)
    for token in (
      "QIXI_DEVICE_STRICT",
      "QIXI_DEVICE_BACKEND_URL",
      "QIXI_DEVICE_PREFLIGHT_TEST_ROOT",
      "SOURCE_TEXT_MAX_BYTES",
      "PLIST_MAX_BYTES",
      "bounded_bytes",
      "opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "must be a regular file after opening",
      "after opening",
      "reject_symlink_components",
      "is_allowed_platform_symlink_alias",
      "handle.read(max_bytes + 1)",
      "must not contain symbolic links",
      "exceeds bounded size",
      "physical-device backend URL must not use localhost or loopback",
      "strict physical-device preflight requires QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765",
      "QIXI_DEVICE_ID",
      "QIXI_DEVICE_DEVELOPMENT_TEAM",
      "QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES",
      "QIXI_DEVICE_PROVISIONING_PROFILE_DIR",
      "QIXI_DEVICE_XCODE_ACCOUNT_PROBE_DERIVED_DATA",
      "PRODUCT_BUNDLE_IDENTIFIER",
      "devicectl",
      "DEVICE_LIST_ROW_RE",
      "DEVICE_LIST_IDENTIFIER_RE",
      "devicectl_device_rows_from_list",
      "devicectl_device_state_summary_from_list",
      "detail_probe_device_identifiers_from_devicectl_list",
      "require_devicectl_identifier_detail_probeable",
      "not probeable by devicectl device details",
      "connected (no DDI)",
      "available (paired)",
      "unavailable",
      "visible devices",
      "developerModeStatus: enabled",
      "ddiServicesAvailable: true",
      "tunnelState: connected",
      "Install Application (",
      "Launch Application (",
      "strict physical-device preflight requires DEVELOPMENT_TEAM",
      "strict physical-device preflight requires PRODUCT_BUNDLE_IDENTIFIER",
      "Apple Development code-signing identities",
      "iOS App Development provisioning profile",
      "security\", \"cms\", \"-D\", \"-i\"",
      "provisioning_profile_matches",
      "check_development_provisioning_profile",
      "xcode_account_probe_problem_messages",
      "run_xcode_automatic_provisioning_probe",
      "check_xcode_automatic_provisioning_account",
      "DVTDeveloperAccountManager",
      "No Account for Team",
      "No Accounts",
      "No profiles for",
      "xcodebuild destination discovery",
      "QIXI_DEVICE_REQUIRE_REAL_MODELS",
      "xcodebuild -showsdks",
      "/api/status",
      "STATUS_RESPONSE_MAX_BYTES",
      "Content-Type",
      "must return application/json",
      "status response is too large",
      "load_status_json",
      "object_pairs_hook",
      "parse_constant",
      "duplicate JSON key",
      "non-standard JSON constant",
      "status payload must be a JSON object",
      "engineId",
      "must be a non-empty string",
      "must be a boolean",
      "NSAllowsLocalNetworking",
      "NSLocalNetworkUsageDescription",
      "QixiAnalysisRuntime",
      "httpBridge",
    ):
      self.assertIn(token, script)
    for token in (
      "status_server",
      "test_status_checker_accepts_real_qixi_status_shape",
      "test_status_checker_rejects_missing_fields_and_bad_states",
      "test_status_checker_rejects_ambiguous_or_non_standard_json",
      "test_status_checker_rejects_wrong_field_types",
      "test_status_checker_rejects_non_json_content_type_and_large_body",
      "test_local_preflight_inputs_use_bounded_reads_and_reject_symlinks",
      "test_local_preflight_inputs_recheck_opened_descriptor_is_regular",
      "DirectoryHandle",
      "test_physical_device_backend_url_rejects_loopback_and_unspecified_hosts",
      "test_physical_device_backend_url_accepts_lan_origin_and_normalizes_path",
      "test_devicectl_connected_device_parser_accepts_single_connected_device",
      "test_devicectl_selection_error_reports_visible_unprobeable_devices",
      "test_ambiguous_detail_probeable_devices_require_explicit_device_id",
      "test_explicit_devicectl_device_id_must_be_visible_and_detail_probeable",
      "test_device_detail_validation_requires_physical_developer_mode_and_ddi",
      "test_xcode_destination_parser_requires_physical_device_udid",
      "test_development_team_resolution_uses_project_or_explicit_override",
      "test_product_bundle_identifier_resolution_requires_single_bundle",
      "test_codesigning_identity_validation_requires_apple_development_for_team",
      "test_provisioning_profile_matching_checks_team_bundle_udid_and_expiration",
      "test_development_provisioning_profile_check_uses_installed_profiles_or_explicit_xcode_updates",
      "test_xcode_account_probe_problem_parser_catches_credential_failures",
      "test_xcode_account_probe_problem_parser_accepts_clean_show_build_settings_output",
    ):
      self.assertIn(token, unit)

    env = hermetic_qixi_env(QIXI_DEVICE_BACKEND_URL="http://127.0.0.1:8765")
    result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-device-run-preflight.sh")],
      cwd=ROOT,
      env=env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("physical-device backend URL must not use localhost or loopback", result.stderr)

    env = hermetic_qixi_env(QIXI_DEVICE_STRICT="1")
    result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-device-run-preflight.sh")],
      cwd=ROOT,
      env=env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(result.returncode, 0)
    self.assertIn(
      "strict physical-device preflight requires QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765",
      result.stderr,
    )

  def test_native_ios_runbook_documents_simulator_device_and_limits(self) -> None:
    runbook = read(ROOT / "docs" / "native-ios-runbook.md")
    for token in (
      "Build The Native App For Simulator",
      "Choose The Right Run Path",
      "Run The Native App Interactively On Mac",
      "qixi-ios-native/scripts/run-native-sim.sh",
      "QIXI_SIM_RESET_APP=1",
      "QIXI_SIM_RUN_CONSOLE=1",
      "bounded `/api/status` health check",
      "Run Screenshot QA On Mac",
      "qixi-ios-native/artifacts/screenshots/review-board",
      "latest-screenshot-review-board.html",
      "Run The Mac-Hosted Backend",
      "Run On A Physical iPad Or iPhone",
      "QIXI_KATAGO_OVERRIDE",
      "curl http://127.0.0.1:8765/api/status",
      "http://<mac-lan-ip>:8765/api/status",
      "QIXI_BACKEND_URL=http://<mac-lan-ip>:8765",
      "scripts/qixi-device-signing-doctor.sh",
      "scripts/qixi-device-signing-doctor.sh --json",
      "scripts/qixi-device-run-preflight.sh",
      "scripts/qixi-device-bridge-smoke.sh",
      "scripts/qixi-device-bridge-plan-inspect.sh",
      "scripts/qixi-device-bridge-smoke-inspect.sh",
      "QIXI_RUN_DEVICE_BRIDGE_SMOKE",
      "QIXI_DEVICE_BRIDGE_RUN_ID",
      "QIXI_DEVICE_STRICT=1",
      "QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765",
      "QIXI_DEVICE_ID",
      "selected identifier must still be visible",
      "probeable by `devicectl device info details`",
      "QIXI_DEVICE_DEVELOPMENT_TEAM",
      "QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES",
      "PRODUCT_BUNDLE_IDENTIFIER",
      "-allowProvisioningUpdates",
      "-allowProvisioningDeviceRegistration",
      "qixi-ios-native/artifacts/device-bridge",
      "devicectl device install",
      "devicectl device process launch",
      "Developer Mode",
      "Developer Disk Image",
      "active CoreDevice transport",
      "install/launch capabilities",
      "available (paired)",
      "unavailable",
      "visible `devicectl` device states",
      "recommendedActions",
      "selected device identifier/UDID",
      "device.coredevice_transport_not_ready",
      "signing.team_identity_missing",
      "signing.profile_missing",
      "signing.xcode_account_probe_failed",
      "Apple Development",
      "physical-device backend URL must not use localhost or loopback",
      "bounded `application/json` response",
      "strict JSON parsing",
      "typed status fields",
      "symbolic-link local project inputs",
      "bounded\nfile-size guards",
      "Do not use `127.0.0.1` for a physical device",
      "Simulation Fidelity And Limits",
      "ProMotion feel",
      "downsampled large photos",
      "oversized-photo rejection before decode/load",
      "EXIF-oriented images",
      "real lighting, blur, hands, or lens geometry",
      "previews visible stones only",
      "same stones with different",
      "QIXI_ANALYSIS_RUNTIME=nativeInProcess",
      "What Physical-Device Smoke Should Record",
      "Current Limitation",
      "fully in-process iPad KataGo engine",
      "not an App-Store-ready on-device KataGo runtime",
    ):
      self.assertIn(token, runbook)

  def test_native_katago_integration_doc_keeps_runtime_boundary_explicit(self) -> None:
    doc = read(ROOT / "docs" / "native-katago-integration.md")
    for token in (
      "QixiAnalysisService",
      "HTTPBridgeAnalysisService",
      "NativeKataGoAnalysisService",
      "QixiNativeKataGoBridge",
      "Qixi-Bridging-Header.h",
      "qixi::NativeKataGoCore",
      "QixiNativeModelRegistry",
      "QixiNativeModelStore",
      "NativeKataGoCoreMLPackageSpec",
      "QixiNativeCoreMLPackageIntegrity",
      "QixiNativeCoreMLPackageInstallReceiptStore",
      ".mlpackage",
      ".mlmodelc",
      "coreMLPackagePaths",
      "Application Support/Qixi/Models",
      "modelPath",
      "modelMissing",
      "scripts/qixi-native-model-preflight.sh",
      "QixiNativeKataGoErrorLibraryNotLinked",
      "must never silently fall back",
      "missing or the adapter load fails",
      "stale previously loaded",
      "native runtime must not use `URLSession`",
      "`BackendStatusResponse.engineId` is always the selected model identity",
      "must not be",
      "`native-in-process`",
      "pure C++ core must remain separately compiled",
      "native no-engine core path must return a decodable `AnalysisResponse`",
      "native-none:",
      "engine tombstone export/restore",
      "tiny versioned tombstone JSON",
      "Lifecycle tombstones must record the native engine tombstone filename",
      "Launch restore must",
      "iOS background",
      "QixiPositionIdentity",
      "currentEngine",
      "`modelMissing` failures",
      "minimum <= recommended",
      "Receipt-write failure",
      "restore the previous model",
      "previous model and receipt",
      "Backup-stage failures",
      "stale orphan",
      ".receipt-backup",
      ".coreml-package-tmp",
      ".coreml-package-backup",
          ".coreml-package-receipt-backup",
          "Runtime model resolution and engine selection",
          "untrusted additional search directories",
          "directory-shaped artifact names",
          "symbolic links",
          "Install receipt JSON is itself part of the trust boundary",
          "bounded strict object parsing",
          "64 KiB limit",
          "reject duplicate object keys",
          "`NaN`/`Infinity`",
          "non-object JSON and trailing data",
          "parser-specific last-key-wins behavior",
          "ordered move history",
          "qixi-ios-native/tests/run_analysis_service_smoke.sh",
      "QIXI_ANALYSIS_RUNTIME=nativeInProcess",
      "b6/b18nbt/b28nbt",
      "readable",
      "non-empty model file",
      "regular model file",
      "symbolic links",
      "readable non-empty regular file",
      "overwrite a symlink target",
    ):
      self.assertIn(token, doc)

  def test_contributing_requires_matrix_and_regression_evidence(self) -> None:
    contributing = read(ROOT / "CONTRIBUTING.md")
    for token in (
      "docs/pr-verification-matrix.md",
      "union of required gates",
      "scripts/qixi-quality-gate.sh",
      "scripts/qixi_changed_surface_gate.py",
      "scripts/qixi-repo-hygiene-preflight.sh",
      "QIXI_RUN_SCREENSHOT_SMOKE=1 scripts/qixi-quality-gate.sh",
      "QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh",
      "QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh",
      "QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh",
      "QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh",
      "bridging header",
      "persistence/tombstone",
      "position identity",
      "iCloud sync",
      "source/header changes",
      "generated logs",
      "local model packages",
      "real iPad/iPhone evidence",
      "device-only behavior",
      "smallest focused test",
      "regression test",
      "Silent skips are not accepted",
      "non-UI screenshot skip",
      "real-model gate automatically",
      "Real-model skips",
      "NativeRelease simulator skips",
    ):
      self.assertIn(token, contributing)


if __name__ == "__main__":
  unittest.main()
