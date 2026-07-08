#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

cd "$ROOT_DIR"

"$PYTHON_BIN" - <<'PY'
from __future__ import annotations

import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import datetime
import stat as stat_module
import tempfile


ROOT = pathlib.Path.cwd()
ARCHIVE_ENV = "QIXI_APPSTORE_ARCHIVE_PATH"
REQUIRE_DISTRIBUTION_SIGNATURE_ENV = "QIXI_REQUIRE_APPSTORE_DISTRIBUTION_SIGNATURE"
EXPECTED_BUNDLE_ID = "com.qixi.localanalysis"
EXPECTED_ICLOUD_CONTAINER = "iCloud.com.qixi.localanalysis"
MINIMUM_IOS_VERSION = (17, 0)
ARCHIVE_PLIST_MAX_BYTES = 1 * 1024 * 1024
ARCHIVE_EXECUTABLE_MAX_BYTES = 256 * 1024 * 1024
ARCHIVE_FORBIDDEN_EXECUTABLE_STRINGS = (
  "Native KataGo is not linked into this build.",
  "PlaceholderNativeKataGoEngine",
  "BackendClient",
  "HTTPBridgeAnalysisService",
  "Qixi HTTP bridge response",
  "QixiBackendBaseURL",
  "qixi.backendBaseURL",
  "QIXI_ANALYSIS_RUNTIME",
  "QIXI_BACKEND_URL",
  "QIXI_DEVICE_BACKEND_URL",
  "http://127.0.0.1:8765",
  "127.0.0.1:8765",
  "localhost:8765",
)
LANDSCAPE = {"UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"}
ARCHIVE_REQUIRED_APPLICATION_PROPERTIES = (
  "ApplicationProperties.CFBundleShortVersionString",
  "ApplicationProperties.CFBundleVersion",
  "ApplicationProperties.SigningIdentity",
  "ApplicationProperties.Team",
)
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
MACHO_64_MAGICS = {
  b"\xcf\xfa\xed\xfe": "<",
  b"\xfe\xed\xfa\xcf": ">",
}
FAT_MAGICS = {
  b"\xca\xfe\xba\xbe": (">", False),
  b"\xbe\xba\xfe\xca": ("<", False),
  b"\xca\xfe\xba\xbf": (">", True),
  b"\xbf\xba\xfe\xca": ("<", True),
}


def fail(message: str) -> None:
  print(f"App Store archive preflight failed: {message}", file=sys.stderr)
  raise SystemExit(1)


def _opened_regular_file_stat(handle, path: pathlib.Path, label: str) -> os.stat_result:
  try:
    opened_stat = os.fstat(handle.fileno())
  except OSError as exc:
    fail(f"{label} could not be inspected after opening: {path}: {exc}")
  if not stat_module.S_ISREG(opened_stat.st_mode):
    fail(f"{label} must be a regular file after opening: {path}")
  return opened_stat


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


def _reject_symlink_components(path: pathlib.Path, label: str) -> None:
  current = pathlib.Path(path.anchor) if path.anchor else pathlib.Path()
  for part in path.parts:
    if part == path.anchor or not part:
      continue
    current = current / part
    _reject_symlink_path(current, label)


def _validate_regular_file(path: pathlib.Path, label: str) -> None:
  _reject_symlink_components(path, label)
  if not path.exists():
    fail(f"{label} does not exist: {path}")
  if not path.is_file():
    fail(f"{label} is not a regular file: {path}")


def _validate_directory(path: pathlib.Path, label: str) -> None:
  _reject_symlink_components(path, label)
  if not path.exists():
    fail(f"{label} does not exist: {path}")
  if not path.is_dir():
    fail(f"{label} is not a directory: {path}")


def _bounded_bytes(path: pathlib.Path, label: str, max_bytes: int) -> bytes:
  if max_bytes <= 0:
    fail(f"{label} has invalid byte budget")
  try:
    size = path.stat().st_size
  except OSError as exc:
    fail(f"{label} could not be statted: {path}: {exc}")
  if size > max_bytes:
    fail(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {path}")
  try:
    with path.open("rb") as handle:
      opened_stat = _opened_regular_file_stat(handle, path, label)
      if opened_stat.st_size > max_bytes:
        fail(f"{label} exceeds bounded size of {max_bytes} bytes after opening: {path}")
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    fail(f"{label} could not be read: {path}: {exc}")
  if len(data) > max_bytes:
    fail(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {path}")
  return data


def _selftest_opened_descriptor_recheck() -> None:
  with tempfile.TemporaryDirectory() as raw_dir:
    directory = pathlib.Path(raw_dir)
    fd = os.open(directory, os.O_RDONLY)
    try:
      class DirectoryHandle:
        def fileno(self) -> int:
          return fd

      _opened_regular_file_stat(DirectoryHandle(), directory / "Info.plist", "archive plist")
    finally:
      os.close(fd)
  fail("opened descriptor self-test did not reject a directory descriptor")


if os.environ.get("QIXI_APPSTORE_ARCHIVE_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR") == "1":
  _selftest_opened_descriptor_recheck()


def load_plist(path: pathlib.Path, label: str) -> dict:
  _validate_regular_file(path, label)
  try:
    payload = plistlib.loads(_bounded_bytes(path, label, ARCHIVE_PLIST_MAX_BYTES))
  except Exception as exc:
    fail(f"invalid plist {path}: {exc}")
  if not isinstance(payload, dict):
    fail(f"{label} must be a dictionary: {path}")
  return payload


def archive_application_path(raw_path: str) -> pathlib.PurePosixPath:
  if raw_path.startswith("~"):
    fail("archive ApplicationProperties.ApplicationPath must not be home-relative")
  if raw_path.startswith("/"):
    fail("archive ApplicationProperties.ApplicationPath must be relative")
  if "\\" in raw_path:
    fail("archive ApplicationProperties.ApplicationPath must use POSIX separators")
  path = pathlib.PurePosixPath(raw_path)
  if path.is_absolute() or not path.parts:
    fail("archive ApplicationProperties.ApplicationPath must name an app bundle")
  if any(part in {"", ".", ".."} for part in path.parts):
    fail("archive ApplicationProperties.ApplicationPath must not traverse outside Products")
  if path.suffix != ".app":
    fail("archive ApplicationProperties.ApplicationPath must point to an .app")
  return path


def unpack_struct(fmt: str, data: bytes, offset: int) -> tuple[int, ...]:
  import struct

  size = struct.calcsize(fmt)
  if offset < 0 or offset + size > len(data):
    raise ValueError("truncated Mach-O data")
  return struct.unpack_from(fmt, data, offset)


def macho_slice_is_ios_arm64_execute(data: bytes, offset: int, size: int) -> tuple[bool, str]:
  if size < 32 or offset < 0 or offset + size > len(data):
    return False, "truncated Mach-O header"

  magic = data[offset : offset + 4]
  endian = MACHO_64_MAGICS.get(magic)
  if endian is None:
    return False, "not a 64-bit Mach-O slice"

  try:
    _, cputype, _, filetype, ncmds, sizeofcmds, _, _ = unpack_struct(
      endian + "IiiIIIII",
      data,
      offset,
    )
  except ValueError as exc:
    return False, str(exc)

  if cputype != CPU_TYPE_ARM64:
    return False, "Mach-O slice must use CPU_TYPE_ARM64"
  if filetype != MH_EXECUTE:
    return False, "Mach-O slice must be MH_EXECUTE"

  commands_start = offset + 32
  commands_end = commands_start + sizeofcmds
  slice_end = offset + size
  if commands_end > slice_end:
    return False, "Mach-O load commands exceed slice size"

  cursor = commands_start
  saw_ios_device_platform = False
  for _ in range(ncmds):
    if cursor + 8 > commands_end:
      return False, "truncated Mach-O load command"
    try:
      cmd, cmdsize = unpack_struct(endian + "II", data, cursor)
    except ValueError as exc:
      return False, str(exc)
    if cmdsize < 8 or cursor + cmdsize > commands_end:
      return False, "invalid Mach-O load command size"
    if cmd == LC_VERSION_MIN_IPHONEOS:
      saw_ios_device_platform = True
    elif cmd == LC_BUILD_VERSION and cmdsize >= 24:
      try:
        _, _, platform, _, _, _ = unpack_struct(endian + "IIIIII", data, cursor)
      except ValueError as exc:
        return False, str(exc)
      if platform == PLATFORM_IOS:
        saw_ios_device_platform = True
    cursor += cmdsize

  if not saw_ios_device_platform:
    return False, "Mach-O slice must target the iOS device platform"
  return True, "ok"


def macho_has_ios_arm64_execute_slice(data: bytes) -> tuple[bool, str]:
  magic = data[:4]
  if magic in MACHO_64_MAGICS:
    return macho_slice_is_ios_arm64_execute(data, 0, len(data))

  fat = FAT_MAGICS.get(magic)
  if fat is None:
    return False, "archive app executable must be a Mach-O binary"

  endian, is_64_bit_fat = fat
  header_size = 32 if is_64_bit_fat else 20
  try:
    _, nfat_arch = unpack_struct(endian + "II", data, 0)
  except ValueError as exc:
    return False, str(exc)
  archs_start = 8
  archs_end = archs_start + nfat_arch * header_size
  if archs_end > len(data):
    return False, "truncated Mach-O fat header"

  arm64_failures: list[str] = []
  for index in range(nfat_arch):
    arch_offset = archs_start + index * header_size
    if is_64_bit_fat:
      cputype, _, slice_offset, slice_size, _, _ = unpack_struct(endian + "iiQQII", data, arch_offset)
    else:
      cputype, _, slice_offset, slice_size, _ = unpack_struct(endian + "iiIII", data, arch_offset)
    if cputype != CPU_TYPE_ARM64:
      continue
    if slice_offset + slice_size > len(data):
      arm64_failures.append("fat arm64 slice exceeds file size")
      continue
    ok, reason = macho_slice_is_ios_arm64_execute(data, int(slice_offset), int(slice_size))
    if ok:
      return True, "ok"
    arm64_failures.append(reason)

  if arm64_failures:
    return False, "; ".join(arm64_failures)
  return False, "Mach-O fat binary must contain an arm64 iOS device executable slice"


def require_macho_executable(path: pathlib.Path) -> None:
  _validate_regular_file(path, "archive app executable")
  data = _bounded_bytes(path, "archive app executable", ARCHIVE_EXECUTABLE_MAX_BYTES)
  ok, reason = macho_has_ios_arm64_execute_slice(data)
  if not ok:
    fail(reason)
  for token in ARCHIVE_FORBIDDEN_EXECUTABLE_STRINGS:
    if token.encode("utf-8") in data:
      fail(f"archive app executable must not contain development bridge or placeholder string: {token}")


def require_valid_code_signature(app_bundle: pathlib.Path) -> None:
  _validate_directory(app_bundle / "_CodeSignature", "archive app _CodeSignature")
  codesign = shutil.which("codesign")
  if not codesign:
    fail("archive code-signature validation requires codesign")
  result = subprocess.run(
    [codesign, "--verify", "--deep", "--strict", "--verbose=2", str(app_bundle)],
    text=True,
    capture_output=True,
    check=False,
  )
  if result.returncode != 0:
    detail = (result.stderr or result.stdout).strip()
    fail(f"archive app code signature must verify with codesign --verify --deep --strict: {detail}")


def code_signature_diagnostics(app_bundle: pathlib.Path) -> str:
  codesign = shutil.which("codesign")
  if not codesign:
    fail("archive signature identity validation requires codesign")
  result = subprocess.run(
    [codesign, "-d", "--verbose=4", str(app_bundle)],
    text=True,
    capture_output=True,
    check=False,
  )
  if result.returncode != 0:
    detail = (result.stderr or result.stdout).strip()
    fail(f"archive app signature identity must be readable: {detail}")
  return f"{result.stdout}\n{result.stderr}"


def require_distribution_signature(app_bundle: pathlib.Path) -> None:
  diagnostics = code_signature_diagnostics(app_bundle)
  if "Signature=adhoc" in diagnostics or "flags=0x2(adhoc)" in diagnostics:
    fail("archive app signature must not be ad-hoc for release evidence")
  if "TeamIdentifier=not set" in diagnostics:
    fail("archive app signature must include a signing team identifier")
  distribution_authorities = (
    "Authority=Apple Distribution:",
    "Authority=iPhone Distribution:",
  )
  if not any(authority in diagnostics for authority in distribution_authorities):
    fail("archive app signature must be signed with Apple Distribution or iPhone Distribution identity")


def signed_entitlements(app_bundle: pathlib.Path) -> dict:
  codesign = shutil.which("codesign")
  if not codesign:
    fail("archive entitlement validation requires codesign")
  result = subprocess.run(
    [codesign, "-d", "--entitlements", ":-", str(app_bundle)],
    text=False,
    capture_output=True,
    check=False,
  )
  if result.returncode != 0:
    detail = (result.stderr or result.stdout).decode("utf-8", "replace").strip()
    fail(f"archive app signed entitlements must be readable: {detail}")
  try:
    entitlements = plistlib.loads(result.stdout)
  except Exception as exc:
    fail(f"archive app signed entitlements must be a plist: {exc}")
  if not isinstance(entitlements, dict) or not entitlements:
    fail("archive app signed entitlements must not be empty")
  return entitlements


def require_archive_entitlements(app_bundle: pathlib.Path) -> None:
  entitlements = signed_entitlements(app_bundle)
  containers = entitlements.get("com.apple.developer.icloud-container-identifiers", [])
  ubiquity = entitlements.get("com.apple.developer.ubiquity-container-identifiers", [])
  services = entitlements.get("com.apple.developer.icloud-services", [])
  application_identifier = entitlements.get("application-identifier")
  team_identifier = entitlements.get("com.apple.developer.team-identifier")
  if EXPECTED_ICLOUD_CONTAINER not in containers:
    fail("archive app signed entitlements must include the Qixi iCloud container")
  if EXPECTED_ICLOUD_CONTAINER not in ubiquity:
    fail("archive app signed entitlements must include the Qixi ubiquity container")
  if "CloudDocuments" not in services:
    fail("archive app signed entitlements must include CloudDocuments")
  if not isinstance(application_identifier, str) or not application_identifier.endswith(f".{EXPECTED_BUNDLE_ID}"):
    fail("archive app signed entitlements application-identifier must end with the bundle identifier")
  if not isinstance(team_identifier, str) or not team_identifier.strip():
    fail("archive app signed entitlements must include a team identifier")
  if entitlements.get("get-task-allow") is True:
    fail("archive app signed entitlements must not enable get-task-allow")


def require_non_empty_info_string(info: dict, key: str) -> None:
  value = info.get(key)
  if not isinstance(value, str) or not value.strip():
    fail(f"archive app Info.plist {key} must be a non-empty string")


def parse_version(value: str) -> tuple[int, ...] | None:
  parts = value.split(".")
  if not parts or any(not part.isdigit() for part in parts):
    return None
  return tuple(int(part) for part in parts)


def version_at_least(value: str, minimum: tuple[int, ...]) -> bool:
  parsed = parse_version(value)
  if parsed is None:
    return False
  width = max(len(parsed), len(minimum))
  padded = parsed + (0,) * (width - len(parsed))
  minimum_padded = minimum + (0,) * (width - len(minimum))
  return padded >= minimum_padded


def require_archive_info_metadata(info: dict) -> None:
  for key in (
    "CFBundleDisplayName",
    "CFBundleShortVersionString",
    "CFBundleVersion",
    "NSCameraUsageDescription",
    "NSPhotoLibraryUsageDescription",
    "NSLocalNetworkUsageDescription",
  ):
    require_non_empty_info_string(info, key)

  ats = info.get("NSAppTransportSecurity")
  if not isinstance(ats, dict) or ats.get("NSAllowsLocalNetworking") is not True:
    fail("archive app Info.plist must allow local networking for device/backend smoke tests")
  if ats.get("NSAllowsArbitraryLoads") is True:
    fail("archive app Info.plist must not allow arbitrary network loads")
  if info.get("ITSAppUsesNonExemptEncryption") is not False:
    fail("archive app Info.plist ITSAppUsesNonExemptEncryption must be false")
  if info.get("CADisableMinimumFrameDurationOnPhone") is not True:
    fail("archive app Info.plist CADisableMinimumFrameDurationOnPhone must be true for ProMotion support")
  supported_platforms = info.get("CFBundleSupportedPlatforms")
  if supported_platforms != ["iPhoneOS"]:
    fail("archive app Info.plist CFBundleSupportedPlatforms must be exactly [iPhoneOS]")
  device_family = info.get("UIDeviceFamily")
  if device_family != [1, 2]:
    fail("archive app Info.plist UIDeviceFamily must target both iPhone and iPad")
  minimum_os = info.get("MinimumOSVersion")
  if not isinstance(minimum_os, str) or not version_at_least(minimum_os, MINIMUM_IOS_VERSION):
    fail("archive app Info.plist MinimumOSVersion must be at least 17.0")


def require_archive_privacy_manifest(privacy_info: dict) -> None:
  if privacy_info.get("NSPrivacyTracking") is not False:
    fail("archive privacy manifest must declare NSPrivacyTracking=false")
  if privacy_info.get("NSPrivacyTrackingDomains") != []:
    fail("archive privacy manifest must not declare tracking domains")
  if privacy_info.get("NSPrivacyCollectedDataTypes") != []:
    fail("archive privacy manifest must not declare collected data types for the current app")
  accessed_api_entries = privacy_info.get("NSPrivacyAccessedAPITypes")
  if not isinstance(accessed_api_entries, list):
    fail("archive privacy manifest must declare NSPrivacyAccessedAPITypes")
  accessed_api_reasons = {
    entry.get("NSPrivacyAccessedAPIType"): set(entry.get("NSPrivacyAccessedAPITypeReasons", []))
    for entry in accessed_api_entries
    if isinstance(entry, dict)
  }
  reasons = accessed_api_reasons.get("NSPrivacyAccessedAPICategoryUserDefaults", set())
  if "CA92.1" not in reasons:
    fail("archive privacy manifest must declare UserDefaults reason CA92.1")


def require_archive_container_metadata(archive_info: dict, properties: dict, require_distribution_signature: bool) -> None:
  archive_version = archive_info.get("ArchiveVersion")
  if not isinstance(archive_version, int) or archive_version < 2:
    fail("archive Info.plist ArchiveVersion must be at least 2")
  creation_date = archive_info.get("CreationDate")
  if not isinstance(creation_date, datetime.datetime):
    fail("archive Info.plist CreationDate must be a plist date")
  for key in ("Name", "SchemeName"):
    value = archive_info.get(key)
    if not isinstance(value, str) or not value.strip():
      fail(f"archive Info.plist {key} must be a non-empty string")
  if archive_info.get("SchemeName") != "Qixi":
    fail("archive Info.plist SchemeName must be Qixi")

  for contract_key in ARCHIVE_REQUIRED_APPLICATION_PROPERTIES:
    key = contract_key.removeprefix("ApplicationProperties.")
    value = properties.get(key)
    if not isinstance(value, str) or not value.strip():
      fail(f"archive {contract_key} must be a non-empty string")
  if require_distribution_signature:
    signing_identity = properties["SigningIdentity"]
    if "Apple Distribution:" not in signing_identity and "iPhone Distribution:" not in signing_identity:
      fail("archive ApplicationProperties.SigningIdentity must be Apple Distribution or iPhone Distribution")


raw_archive = os.environ.get(ARCHIVE_ENV, "").strip()
if not raw_archive:
  fail(f"{ARCHIVE_ENV}=/path/to/Qixi.xcarchive is required for release evidence")

archive = pathlib.Path(raw_archive).expanduser()
if archive.suffix != ".xcarchive":
  fail(f"{ARCHIVE_ENV} must point to an existing .xcarchive directory: {archive}")
_validate_directory(archive, ARCHIVE_ENV)

archive_info = load_plist(archive / "Info.plist", "archive Info.plist")
properties = archive_info.get("ApplicationProperties")
if not isinstance(properties, dict):
  fail("archive Info.plist must contain ApplicationProperties")
require_distribution = os.environ.get(REQUIRE_DISTRIBUTION_SIGNATURE_ENV, "0") == "1"
require_archive_container_metadata(archive_info, properties, require_distribution)

application_path = properties.get("ApplicationPath")
if not isinstance(application_path, str) or not application_path.strip():
  fail("archive ApplicationProperties.ApplicationPath must point to an .app")
portable_application_path = archive_application_path(application_path.strip())
if application_path != "Applications/Qixi.app":
  fail("archive ApplicationProperties.ApplicationPath must be Applications/Qixi.app")

archive_bundle_id = properties.get("CFBundleIdentifier")
if archive_bundle_id != EXPECTED_BUNDLE_ID:
  fail(f"archive ApplicationProperties.CFBundleIdentifier must be {EXPECTED_BUNDLE_ID}, got {archive_bundle_id!r}")

products_dir = archive / "Products" / "Applications"
_validate_directory(products_dir, "archive Products/Applications")

app_bundle = archive / "Products"
for part in portable_application_path.parts:
  app_bundle = app_bundle / part
_validate_directory(app_bundle, "archive application bundle")
if app_bundle.suffix != ".app":
  fail(f"archive application bundle is missing: {app_bundle}")
if not app_bundle.is_relative_to(products_dir):
  fail("archive application bundle must live under Products/Applications")

app_info = load_plist(app_bundle / "Info.plist", "archive app Info.plist")
bundle_id = app_info.get("CFBundleIdentifier")
if bundle_id != EXPECTED_BUNDLE_ID:
  fail(f"archive app bundle identifier must be {EXPECTED_BUNDLE_ID}, got {bundle_id!r}")
if bundle_id != archive_bundle_id:
  fail("archive app bundle identifier must match ApplicationProperties.CFBundleIdentifier")
if app_info.get("CFBundleShortVersionString") != properties.get("CFBundleShortVersionString"):
  fail("archive app CFBundleShortVersionString must match ApplicationProperties.CFBundleShortVersionString")
if app_info.get("CFBundleVersion") != properties.get("CFBundleVersion"):
  fail("archive app CFBundleVersion must match ApplicationProperties.CFBundleVersion")
if app_info.get("CFBundlePackageType") != "APPL":
  fail("archive app CFBundlePackageType must be APPL")
if app_info.get("LSRequiresIPhoneOS") is not True:
  fail("archive app LSRequiresIPhoneOS must be true")
if app_info.get("DTPlatformName") != "iphoneos":
  fail("archive app DTPlatformName must be iphoneos")
sdk_name = app_info.get("DTSDKName")
if not isinstance(sdk_name, str) or not sdk_name.startswith("iphoneos"):
  fail("archive app DTSDKName must start with iphoneos")
if app_info.get("UIRequiresFullScreen") is not True:
  fail("archive app UIRequiresFullScreen must be true")
require_archive_info_metadata(app_info)
executable_name = app_info.get("CFBundleExecutable")
if not isinstance(executable_name, str) or not executable_name or "/" in executable_name or "\\" in executable_name:
  fail("archive app CFBundleExecutable must name a bundled executable")
if executable_name in {".", ".."}:
  fail("archive app CFBundleExecutable must name a bundled executable")
require_macho_executable(app_bundle / executable_name)
if app_info.get("QixiAnalysisRuntime") != "nativeInProcess":
  fail("archive app must default QixiAnalysisRuntime to nativeInProcess")
if "QixiBackendBaseURL" in app_info:
  fail("archive app must not ship QixiBackendBaseURL")

orientations = set(app_info.get("UISupportedInterfaceOrientations", []))
ipad_orientations = set(app_info.get("UISupportedInterfaceOrientations~ipad", []))
if orientations != LANDSCAPE or ipad_orientations != LANDSCAPE:
  fail("archive app supported orientations must be landscape left/right for iPhone and iPad")

privacy = app_bundle / "PrivacyInfo.xcprivacy"
privacy_info = load_plist(privacy, "archive PrivacyInfo.xcprivacy")
require_archive_privacy_manifest(privacy_info)

require_valid_code_signature(app_bundle)
if require_distribution:
  require_distribution_signature(app_bundle)
require_archive_entitlements(app_bundle)

print("App Store archive preflight passed")
PY
