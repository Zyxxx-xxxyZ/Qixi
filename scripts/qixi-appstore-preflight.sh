#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

cd "$ROOT_DIR"

"$PYTHON_BIN" - <<'PY'
from __future__ import annotations

import pathlib
import plistlib
import re
import os
import stat as stat_module
import sys
import tempfile


DEFAULT_ROOT = pathlib.Path.cwd()
TEST_ROOT_ENV = "QIXI_APPSTORE_PREFLIGHT_TEST_ROOT"
TESTING_ENV = "QIXI_APPSTORE_PREFLIGHT_TESTING"
SELFTEST_OPENED_DESCRIPTOR_ENV = "QIXI_APPSTORE_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR"
APPSTORE_SOURCE_TEXT_MAX_BYTES = 4 * 1024 * 1024
APPSTORE_PLIST_MAX_BYTES = 1 * 1024 * 1024


def fail(message: str) -> None:
  print(f"App Store preflight failed: {message}", file=sys.stderr)
  raise SystemExit(1)


def _normalized_path(path: pathlib.Path) -> pathlib.Path:
  expanded = path.expanduser()
  if expanded.is_absolute():
    return expanded
  return pathlib.Path.cwd() / expanded


def _is_allowed_platform_symlink_alias(path: pathlib.Path) -> bool:
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


def _reject_symlink_path(path: pathlib.Path, label: str) -> None:
  if path.is_symlink() and not _is_allowed_platform_symlink_alias(path):
    fail(f"{label} must not contain symbolic links: {path}")


def _reject_symlink_components(path: pathlib.Path, label: str) -> pathlib.Path:
  candidate = _normalized_path(path)
  current = pathlib.Path(candidate.anchor) if candidate.anchor else pathlib.Path()
  for part in candidate.parts:
    if part == candidate.anchor or not part:
      continue
    current = current / part
    _reject_symlink_path(current, label)
  return candidate


def _preflight_root() -> pathlib.Path:
  override = os.environ.get(TEST_ROOT_ENV, "").strip()
  if not override:
    return _reject_symlink_components(DEFAULT_ROOT, "repository root")
  if os.environ.get(TESTING_ENV) != "1":
    fail(f"{TEST_ROOT_ENV} may only be used with {TESTING_ENV}=1")
  return _reject_symlink_components(pathlib.Path(override), "test repository root")


ROOT = _preflight_root()
NATIVE = ROOT / "qixi-ios-native"
SRC = NATIVE / "Qixi"
PROJECT = NATIVE / "Qixi.xcodeproj" / "project.pbxproj"
INFO = SRC / "Info.plist"
NATIVE_RELEASE_INFO = SRC / "NativeReleaseInfo.plist"
ENTITLEMENTS = SRC / "Qixi.entitlements"
PRIVACY = SRC / "PrivacyInfo.xcprivacy"
ENGINE_IMPL = SRC / "QixiNativeKataGoEngine.cpp"

SUBMISSION_MODE = os.environ.get("QIXI_APPSTORE_SUBMISSION", "0") == "1"
ACTIVE_INFO = NATIVE_RELEASE_INFO if SUBMISSION_MODE and NATIVE_RELEASE_INFO.exists() else INFO


def fail_many(header: str, messages: list[str]) -> None:
  print(f"App Store preflight failed: {header}", file=sys.stderr)
  for message in messages:
    print(f"- {message}", file=sys.stderr)
  raise SystemExit(1)


def _validate_regular_file(path: pathlib.Path, label: str) -> pathlib.Path:
  checked_path = _reject_symlink_components(path, label)
  if not checked_path.exists():
    fail(f"missing {checked_path.relative_to(ROOT)}")
  if not checked_path.is_file():
    fail(f"{label} is not a regular file: {checked_path}")
  return checked_path


def _validate_directory(path: pathlib.Path, label: str) -> pathlib.Path:
  checked_path = _reject_symlink_components(path, label)
  if not checked_path.exists():
    fail(f"missing {checked_path.relative_to(ROOT)}")
  if not checked_path.is_dir():
    fail(f"{label} is not a directory: {checked_path}")
  return checked_path


def _opened_regular_file_stat(handle, path: pathlib.Path, label: str) -> os.stat_result:
  try:
    opened_stat = os.fstat(handle.fileno())
  except OSError as exc:
    fail(f"{label} could not be inspected after opening: {path}: {exc}")
  if not stat_module.S_ISREG(opened_stat.st_mode):
    fail(f"{label} must be a regular file after opening: {path}")
  return opened_stat


def _bounded_bytes(path: pathlib.Path, label: str, max_bytes: int) -> bytes:
  if max_bytes <= 0:
    fail(f"{label} has invalid byte budget")
  checked_path = _validate_regular_file(path, label)
  try:
    file_stat = checked_path.stat()
  except OSError as exc:
    fail(f"{label} could not be statted: {checked_path}: {exc}")
  if file_stat.st_size > max_bytes:
    fail(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {checked_path}")
  try:
    with checked_path.open("rb") as handle:
      opened_stat = _opened_regular_file_stat(handle, checked_path, label)
      if opened_stat.st_size > max_bytes:
        fail(f"{label} exceeds bounded size of {max_bytes} bytes after opening: {checked_path}")
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    fail(f"{label} could not be read: {checked_path}: {exc}")
  if len(data) > max_bytes:
    fail(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {checked_path}")
  return data


def _selftest_opened_descriptor_recheck() -> None:
  if os.environ.get(SELFTEST_OPENED_DESCRIPTOR_ENV) != "1":
    return
  if os.environ.get(TESTING_ENV) != "1":
    fail(f"{SELFTEST_OPENED_DESCRIPTOR_ENV} may only be used with {TESTING_ENV}=1")
  with tempfile.TemporaryDirectory() as raw_dir:
    directory = pathlib.Path(raw_dir)
    fd = os.open(directory, os.O_RDONLY)
    try:
      class DirectoryHandle:
        def fileno(self) -> int:
          return fd

      _opened_regular_file_stat(DirectoryHandle(), directory / "Info.plist", "Info.plist")
    finally:
      os.close(fd)
  fail("opened descriptor self-test did not reject a directory descriptor")


_selftest_opened_descriptor_recheck()


def _bounded_text(path: pathlib.Path, label: str, max_bytes: int = APPSTORE_SOURCE_TEXT_MAX_BYTES) -> str:
  data = _bounded_bytes(path, label, max_bytes)
  try:
    return data.decode("utf-8")
  except UnicodeDecodeError as exc:
    fail(f"{label} must be UTF-8: {path}: {exc}")


def read(path: pathlib.Path, label: str | None = None) -> str:
  return _bounded_text(path, label or f"file {path.relative_to(ROOT)}")


def load_plist(path: pathlib.Path, label: str | None = None) -> dict:
  label = label or f"plist {path.relative_to(ROOT)}"
  try:
    payload = plistlib.loads(_bounded_bytes(path, label, APPSTORE_PLIST_MAX_BYTES))
  except Exception as exc:
    fail(f"invalid plist {path.relative_to(ROOT)}: {exc}")
  if not isinstance(payload, dict):
    fail(f"{label} must be a dictionary: {path}")
  return payload


def _guarded_by_native_disabled_block(source: str, token: str) -> bool:
  pattern = re.compile(r"#if\s+!QIXI_ENABLE_NATIVE_KATAGO\b(?P<body>.*?)#endif", re.DOTALL)
  return any(token in match.group("body") for match in pattern.finditer(source))


def _factory_uses_linked_engine_when_native_enabled(source: str) -> bool:
  pattern = re.compile(
    r"#if\s+QIXI_ENABLE_NATIVE_KATAGO\b"
    r"(?P<linked>.*?)"
    r"#else"
    r"(?P<placeholder>.*?)"
    r"#endif",
    re.DOTALL,
  )
  for match in pattern.finditer(source):
    if (
      "std::make_unique<LinkedNativeKataGoEngine>()" in match.group("linked")
      and "std::make_unique<PlaceholderNativeKataGoEngine>()" in match.group("placeholder")
    ):
      return True
  return False


def _xcbuild_configuration_blocks(project: str, name: str) -> list[str]:
  marker = f"/* {name} */ = {{"
  blocks: list[str] = []
  search_start = 0
  while True:
    start = project.find(marker, search_start)
    if start < 0:
      return blocks
    brace_start = project.find("{", start)
    if brace_start < 0:
      return blocks
    depth = 0
    end = -1
    for index in range(brace_start, len(project)):
      char = project[index]
      if char == "{":
        depth += 1
      elif char == "}":
        depth -= 1
        if depth == 0:
          end = index
          break
    if end < 0:
      return blocks
    block = project[start:end + 1]
    if "isa = XCBuildConfiguration;" in block and f"name = {name};" in block:
      blocks.append(block)
    search_start = end + 1


def _target_xcbuild_configuration_blocks(project: str, name: str) -> list[str]:
  return [
    block
    for block in _xcbuild_configuration_blocks(project, name)
    if "PRODUCT_NAME = \"$(TARGET_NAME)\";" in block
    and "SWIFT_OBJC_BRIDGING_HEADER" in block
  ]


def _native_release_swift_scope_blockers(project: str, context: str) -> list[str]:
  blockers: list[str] = []
  native_blocks = _target_xcbuild_configuration_blocks(project, "NativeRelease")
  if not native_blocks:
    return [f"{context} requires a NativeRelease target build settings block"]

  native_block = "\n".join(native_blocks)
  if "SWIFT_ACTIVE_COMPILATION_CONDITIONS = QIXI_NATIVE_RELEASE;" not in native_block:
    blockers.append(f"{context} requires NativeRelease target to define Swift condition QIXI_NATIVE_RELEASE")
  if "OTHER_SWIFT_FLAGS" not in native_block or "-D" not in native_block or "QIXI_NATIVE_RELEASE" not in native_block:
    blockers.append(f"{context} requires NativeRelease target OTHER_SWIFT_FLAGS to pass -D QIXI_NATIVE_RELEASE")
  if (
    "EXCLUDED_SOURCE_FILE_NAMES" not in native_block
    or "BackendClient.swift" not in native_block
    or "QixiHTTPBridgeAnalysisService.swift" not in native_block
  ):
    blockers.append(f"{context} requires NativeRelease target to exclude development HTTP bridge source files")

  for name in ("Debug", "Release"):
    for block in _target_xcbuild_configuration_blocks(project, name):
      if "QIXI_NATIVE_RELEASE" in block:
        blockers.append(f"{context} requires {name} target build settings to stay off QIXI_NATIVE_RELEASE")
  return blockers


_validate_directory(SRC, "Qixi source directory")
project = read(PROJECT, "project file")
info = load_plist(ACTIVE_INFO, "Info.plist")
entitlements = load_plist(ENTITLEMENTS, "Qixi.entitlements")
privacy = load_plist(PRIVACY, "PrivacyInfo.xcprivacy")
engine_impl = read(ENGINE_IMPL, "native engine implementation")
info_text = read(ACTIVE_INFO, "Info.plist source")
joined_swift = "\n".join(
  read(path, f"Swift source {path.name}")
  for path in sorted(SRC.glob("*.swift"))
)

if "PrivacyInfo.xcprivacy in Resources" not in project:
  fail("PrivacyInfo.xcprivacy is not copied in the app Resources build phase")
if "PrivacyInfo.xcprivacy" not in project:
  fail("PrivacyInfo.xcprivacy is not referenced by the Xcode project")

if privacy.get("NSPrivacyTracking") is not False:
  fail("privacy manifest must explicitly declare NSPrivacyTracking=false")
if privacy.get("NSPrivacyTrackingDomains") != []:
  fail("privacy manifest must not declare tracking domains for the current app")
if privacy.get("NSPrivacyCollectedDataTypes") != []:
  fail("privacy manifest currently expects no collected data types")

accessed_api_entries = privacy.get("NSPrivacyAccessedAPITypes")
if not isinstance(accessed_api_entries, list):
  fail("privacy manifest is missing NSPrivacyAccessedAPITypes")
accessed_api_reasons = {
  entry.get("NSPrivacyAccessedAPIType"): set(entry.get("NSPrivacyAccessedAPITypeReasons", []))
  for entry in accessed_api_entries
  if isinstance(entry, dict)
}
if "UserDefaults" in joined_swift:
  reasons = accessed_api_reasons.get("NSPrivacyAccessedAPICategoryUserDefaults", set())
  if "CA92.1" not in reasons:
    fail("UserDefaults usage requires NSPrivacyAccessedAPICategoryUserDefaults reason CA92.1")

required_info_strings = [
  "CFBundleDisplayName",
  "NSCameraUsageDescription",
  "NSPhotoLibraryUsageDescription",
  "NSLocalNetworkUsageDescription",
]
for key in required_info_strings:
  value = info.get(key)
  if not isinstance(value, str) or not value.strip():
    fail(f"Info.plist {key} must be a non-empty string")

ats = info.get("NSAppTransportSecurity")
if not isinstance(ats, dict) or ats.get("NSAllowsLocalNetworking") is not True:
  fail("Info.plist must allow local networking for device/backend smoke tests")
if ats.get("NSAllowsArbitraryLoads") is True:
  fail("Info.plist must not allow arbitrary network loads")

for key in ("CFBundleShortVersionString", "CFBundleVersion"):
  value = info.get(key)
  if not isinstance(value, str) or not value.strip():
    fail(f"Info.plist {key} must be present")

if info.get("ITSAppUsesNonExemptEncryption") is not False:
  fail("ITSAppUsesNonExemptEncryption must be false for the current no-non-exempt-encryption app")
if info.get("LSRequiresIPhoneOS") is not True:
  fail("LSRequiresIPhoneOS must be true")
if info.get("UIRequiresFullScreen") is not True:
  fail("UIRequiresFullScreen must be true for the current landscape-only layout")
if info.get("CADisableMinimumFrameDurationOnPhone") is not True:
  fail("CADisableMinimumFrameDurationOnPhone must be true for ProMotion support")

orientations = set(info.get("UISupportedInterfaceOrientations", []))
ipad_orientations = set(info.get("UISupportedInterfaceOrientations~ipad", []))
landscape = {"UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"}
if orientations != landscape or ipad_orientations != landscape:
  fail("supported orientations must be landscape left/right for iPhone and iPad")

containers = entitlements.get("com.apple.developer.icloud-container-identifiers", [])
ubiquity = entitlements.get("com.apple.developer.ubiquity-container-identifiers", [])
services = entitlements.get("com.apple.developer.icloud-services", [])
if "iCloud.com.qixi.localanalysis" not in containers:
  fail("iCloud container identifier is missing")
if "iCloud.com.qixi.localanalysis" not in ubiquity:
  fail("ubiquity container identifier is missing")
if "CloudDocuments" not in services:
  fail("CloudDocuments service is missing")

for token in (
  "TARGETED_DEVICE_FAMILY = \"1,2\";",
  "SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";",
  "SUPPORTS_MACCATALYST = NO;",
  "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;",
  "MARKETING_VERSION = 1.0;",
  "CURRENT_PROJECT_VERSION = 1;",
):
  if token not in project:
    fail(f"project build setting missing: {token}")

if re.search(r"NSAllowsArbitraryLoads\\s*</key>\\s*<true", info_text):
  fail("Info.plist must not contain NSAllowsArbitraryLoads=true")

if SUBMISSION_MODE:
  submission_blockers: list[str] = []
  if info.get("QixiAnalysisRuntime") != "nativeInProcess":
    submission_blockers.append("submission mode requires QixiAnalysisRuntime=nativeInProcess")
  if "QixiBackendBaseURL" in info:
    submission_blockers.append("submission mode must not ship a default Mac-hosted backend URL")
  if "QIXI_ENABLE_NATIVE_KATAGO=1" not in project:
    submission_blockers.append("submission mode requires NativeRelease to define QIXI_ENABLE_NATIVE_KATAGO=1")
  submission_blockers.extend(_native_release_swift_scope_blockers(project, "submission mode"))
  if "class LinkedNativeKataGoEngine final" not in engine_impl:
    submission_blockers.append("submission mode requires the real iOS NativeKataGoEngine adapter")
  if not _guarded_by_native_disabled_block(engine_impl, "class PlaceholderNativeKataGoEngine final"):
    submission_blockers.append("submission mode requires PlaceholderNativeKataGoEngine to be excluded by #if !QIXI_ENABLE_NATIVE_KATAGO")
  if not _guarded_by_native_disabled_block(engine_impl, "Native KataGo is not linked into this build."):
    submission_blockers.append("submission mode requires the libraryNotLinked placeholder diagnostic to be excluded by #if !QIXI_ENABLE_NATIVE_KATAGO")
  if not _factory_uses_linked_engine_when_native_enabled(engine_impl):
    submission_blockers.append("submission mode must construct LinkedNativeKataGoEngine when QIXI_ENABLE_NATIVE_KATAGO=1")
  if submission_blockers:
    fail_many("submission mode blockers remain", submission_blockers)
  print("App Store submission preflight passed")
else:
  if info.get("QixiAnalysisRuntime") != "httpBridge":
    fail("development preflight expects QixiAnalysisRuntime=httpBridge until native KataGo is linked")
  if info.get("QixiBackendBaseURL") != "http://127.0.0.1:8765":
    fail("development preflight expects the simulator backend URL to remain explicit")
  if "class PlaceholderNativeKataGoEngine final" not in engine_impl:
    fail("development preflight expected the placeholder native engine marker to be explicit")
  if "Native KataGo is not linked into this build." not in engine_impl:
    fail("development preflight expected the libraryNotLinked diagnostic to be explicit")
  print("App Store development preflight passed")

print("App Store preflight passed")
PY
