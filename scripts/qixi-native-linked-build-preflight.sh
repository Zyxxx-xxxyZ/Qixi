#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TESTING_MODE="${QIXI_NATIVE_LINKED_PREFLIGHT_TESTING:-0}"
SELFTEST_OPENED_DESCRIPTOR="${QIXI_NATIVE_LINKED_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR:-0}"

cd "$ROOT_DIR"

if [[ "$SELFTEST_OPENED_DESCRIPTOR" == "1" && "$TESTING_MODE" != "1" ]]; then
  echo "Native linked build preflight failed:" >&2
  echo "- QIXI_NATIVE_LINKED_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR may only be used with QIXI_NATIVE_LINKED_PREFLIGHT_TESTING=1" >&2
  exit 1
fi

if [[ "$SELFTEST_OPENED_DESCRIPTOR" != "1" ]]; then
  qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh
fi

"$PYTHON_BIN" - <<'PY'
from __future__ import annotations

import os
import pathlib
import json
import plistlib
import re
import shutil
import stat as stat_module
import subprocess
import sys
import tempfile
import datetime as dt


ROOT = pathlib.Path.cwd()
PROJECT = ROOT / "qixi-ios-native" / "Qixi.xcodeproj" / "project.pbxproj"
ENGINE_IMPL = ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeKataGoEngine.cpp"
INFO = ROOT / "qixi-ios-native" / "Qixi" / "Info.plist"
NATIVE_RELEASE_INFO = ROOT / "qixi-ios-native" / "Qixi" / "NativeReleaseInfo.plist"
IOS_XCFRAMEWORK = "QIXI_KATAGO_IOS_XCFRAMEWORK"
IOS_LIBRARY = "QIXI_KATAGO_IOS_LIBRARY"
IOS_LIBRARY_DIR = "QIXI_KATAGO_IOS_LIBRARY_DIR"
INFO_OVERRIDE_ENV = "QIXI_NATIVE_LINKED_INFO_PLIST"
TESTING_ENV = "QIXI_NATIVE_LINKED_PREFLIGHT_TESTING"
REPORT_ENV = "QIXI_NATIVE_LINKED_PREFLIGHT_REPORT"
SELFTEST_OPENED_DESCRIPTOR_ENV = "QIXI_NATIVE_LINKED_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR"
KATAGO_SWIFT_LIBRARY_NAME = "libKataGoSwift.a"
EXACTLY_ONE_ARTIFACT_MESSAGE = "release evidence must set exactly one of QIXI_KATAGO_IOS_XCFRAMEWORK or QIXI_KATAGO_IOS_LIBRARY, not both"
IOS_DEVICE_PLATFORM_NUMBER = "platform 2"
IOS_DEVICE_PLATFORM_VALUES = {"2", "ios"}
LEGACY_IPHONEOS_LOAD_COMMAND = "LC_VERSION_MIN_IPHONEOS"
SOURCE_TEXT_MAX_BYTES = 4 * 1024 * 1024
PLIST_MAX_BYTES = 1 * 1024 * 1024
KATAGO_REQUIRED_SYMBOL_FRAGMENTS = (
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
)
KATAGO_MIN_DEFINED_SYMBOLS = 250
KATAGO_MIN_KATAGO_LIKE_SYMBOLS = 40
KATAGO_LIKE_SYMBOL_FRAGMENTS = (
  "AnalysisData",
  "AsyncBot",
  "Board::",
  "BoardHistory",
  "EvalCacheTable",
  "Loc::",
  "Move",
  "NNOutput",
  "NNEvaluator",
  "NeuralNet",
  "Player",
  "Rules::",
  "ScoreValue",
  "Search::",
  "SearchParams",
  "Setup::",
  "TimeControls",
  "getAnalysisJson",
  "getAverageTreeOwnership",
  "setPositionForMCTSPersistence",
)
KATAGO_SWIFT_REQUIRED_SYMBOL_FRAGMENTS = (
  "KataGoSwift",
  "CoreMLComputeHandle",
  "MPSGraphModelHandle",
  "createMetalComputeContext",
  "createMPSGraphOnlyHandle",
  "createCoreMLComputeHandle",
)
KATAGO_SWIFT_MIN_DEFINED_SYMBOLS = 20
blockers: list[str] = []


def _now_utc() -> str:
  return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _report_path() -> pathlib.Path | None:
  raw = os.environ.get(REPORT_ENV, "").strip()
  if not raw:
    return None
  return pathlib.Path(raw).expanduser()


def _report_path_symlink_errors(path: pathlib.Path, label: str) -> list[str]:
  errors: list[str] = []
  current = pathlib.Path(path.anchor) if path.anchor else pathlib.Path()
  for part in path.parts:
    if part == path.anchor or not part:
      continue
    current = current / part
    if current.is_symlink() and not _is_allowed_platform_symlink_alias(current):
      errors.append(f"{label} must not contain symbolic links: {current}")
  return errors


def _prepare_report_output_path(path: pathlib.Path) -> list[str]:
  errors = _report_path_symlink_errors(path, REPORT_ENV)
  parent = path.parent if str(path.parent) else pathlib.Path(".")
  if parent.exists() and not parent.is_dir():
    errors.append(f"{REPORT_ENV} parent is not a directory: {parent}")
  if path.exists() and not path.is_file():
    errors.append(f"{REPORT_ENV} is not a regular file: {path}")
  if errors:
    return errors
  try:
    parent.mkdir(parents=True, exist_ok=True)
  except OSError as exc:
    return [f"{REPORT_ENV} parent directory could not be created: {parent}: {exc}"]
  return _report_path_symlink_errors(path, REPORT_ENV)


def write_report(status: str, messages: list[str]) -> list[str]:
  path = _report_path()
  if path is None:
    return []
  path_errors = _prepare_report_output_path(path)
  if path_errors:
    return path_errors
  payload = {
    "schemaVersion": 1,
    "kind": "qixi-native-linked-build-preflight",
    "generatedAt": _now_utc(),
    "status": status,
    "blockers": list(messages),
    "inputs": {
      IOS_XCFRAMEWORK: os.environ.get(IOS_XCFRAMEWORK, "").strip(),
      IOS_LIBRARY: os.environ.get(IOS_LIBRARY, "").strip(),
      IOS_LIBRARY_DIR: os.environ.get(IOS_LIBRARY_DIR, "").strip(),
      INFO_OVERRIDE_ENV: os.environ.get(INFO_OVERRIDE_ENV, "").strip(),
    },
  }
  text = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
  tmp_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
  flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
  if hasattr(os, "O_CLOEXEC"):
    flags |= os.O_CLOEXEC
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
  fd: int | None = None
  try:
    fd = os.open(tmp_path, flags, 0o600)
    encoded = text.encode("utf-8")
    with os.fdopen(fd, "wb") as handle:
      fd = None
      handle.write(encoded)
      handle.flush()
      os.fsync(handle.fileno())
    os.replace(tmp_path, path)
  except OSError as exc:
    if fd is not None:
      try:
        os.close(fd)
      except OSError:
        pass
    try:
      tmp_path.unlink()
    except OSError:
      pass
    return [f"{REPORT_ENV} could not be written: {path}: {exc}"]
  return []


def fail_many(messages: list[str]) -> None:
  report_errors = write_report("failed", messages)
  if report_errors:
    messages = [*messages, *report_errors]
  print("Native linked build preflight failed:", file=sys.stderr)
  for message in messages:
    print(f"- {message}", file=sys.stderr)
  raise SystemExit(1)


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


def _reject_symlink_path(path: pathlib.Path, label: str) -> bool:
  if path.is_symlink() and not _is_allowed_platform_symlink_alias(path):
    blockers.append(f"{label} must not contain symbolic links: {path}")
    return False
  return True


def _reject_symlink_components(path: pathlib.Path, label: str) -> bool:
  ok = True
  current = pathlib.Path(path.anchor) if path.anchor else pathlib.Path()
  for part in path.parts:
    if part == path.anchor or not part:
      continue
    current = current / part
    ok = _reject_symlink_path(current, label) and ok
  return ok


def _validate_regular_file(path: pathlib.Path, label: str) -> bool:
  ok = _reject_symlink_components(path, label)
  if not path.exists():
    blockers.append(f"{label} does not exist: {path}")
    return False
  if not path.is_file():
    blockers.append(f"{label} is not a regular file: {path}")
    return False
  return ok


def _validate_directory(path: pathlib.Path, label: str) -> bool:
  ok = _reject_symlink_components(path, label)
  if not path.exists():
    blockers.append(f"{label} does not exist: {path}")
    return False
  if not path.is_dir():
    blockers.append(f"{label} is not a directory: {path}")
    return False
  return ok


def _opened_regular_file_stat(handle, path: pathlib.Path, label: str) -> os.stat_result | None:
  try:
    opened_stat = os.fstat(handle.fileno())
  except OSError as exc:
    blockers.append(f"{label} could not be inspected after opening: {path}: {exc}")
    return None
  if not stat_module.S_ISREG(opened_stat.st_mode):
    blockers.append(f"{label} must be a regular file after opening: {path}")
    return None
  return opened_stat


def _absolute_env_path(raw_path: str, label: str) -> pathlib.Path | None:
  if raw_path.startswith("~"):
    blockers.append(f"{label} must be an absolute path, not home-relative")
    return None
  path = pathlib.Path(raw_path).expanduser()
  if not path.is_absolute():
    blockers.append(f"{label} must be an absolute path")
    return None
  return path


def _bounded_bytes(path: pathlib.Path, label: str, max_bytes: int) -> bytes | None:
  if max_bytes <= 0:
    blockers.append(f"{label} has invalid byte budget")
    return None
  if not _validate_regular_file(path, label):
    return None
  try:
    size = path.stat().st_size
  except OSError as exc:
    blockers.append(f"{label} could not be statted: {path}: {exc}")
    return None
  if size > max_bytes:
    blockers.append(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {path}")
    return None
  try:
    with path.open("rb") as handle:
      opened_stat = _opened_regular_file_stat(handle, path, label)
      if opened_stat is None:
        return None
      if opened_stat.st_size > max_bytes:
        blockers.append(f"{label} exceeds bounded size of {max_bytes} bytes after opening: {path}")
        return None
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    blockers.append(f"{label} could not be read: {path}: {exc}")
    return None
  if len(data) > max_bytes:
    blockers.append(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {path}")
    return None
  return data


def _selftest_opened_descriptor_recheck() -> None:
  with tempfile.TemporaryDirectory() as raw_dir:
    directory = pathlib.Path(raw_dir)
    fd = os.open(directory, os.O_RDONLY)
    try:
      class DirectoryHandle:
        def fileno(self) -> int:
          return fd

      _opened_regular_file_stat(DirectoryHandle(), directory / "Info.plist", "release Info.plist")
    finally:
      os.close(fd)
  if not blockers:
    blockers.append("opened descriptor self-test did not reject a directory descriptor")
  fail_many(blockers)


if os.environ.get(SELFTEST_OPENED_DESCRIPTOR_ENV) == "1":
  _selftest_opened_descriptor_recheck()


def _bounded_text(path: pathlib.Path, label: str, max_bytes: int) -> str:
  data = _bounded_bytes(path, label, max_bytes)
  if data is None:
    return ""
  try:
    return data.decode("utf-8")
  except UnicodeDecodeError as exc:
    blockers.append(f"could not read file {path}: {exc}")
    return ""


def read(path: pathlib.Path) -> str:
  return _bounded_text(path, f"file {path}", SOURCE_TEXT_MAX_BYTES)


def load_plist(path: pathlib.Path, label: str | None = None) -> dict:
  label = label or f"plist {path}"
  data = _bounded_bytes(path, label, PLIST_MAX_BYTES)
  if data is None:
    return {}
  try:
    payload = plistlib.loads(data)
  except Exception as exc:
    blockers.append(f"could not read plist {path}: {exc}")
    return {}
  if not isinstance(payload, dict):
    blockers.append(f"{label} must be a dictionary: {path}")
    return {}
  return payload


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


def _native_release_swift_scope_blockers(project: str) -> list[str]:
  scope_blockers: list[str] = []
  native_blocks = _target_xcbuild_configuration_blocks(project, "NativeRelease")
  if not native_blocks:
    return ["Qixi NativeRelease target build settings block is missing"]

  native_block = "\n".join(native_blocks)
  if "SWIFT_ACTIVE_COMPILATION_CONDITIONS = QIXI_NATIVE_RELEASE;" not in native_block:
    scope_blockers.append("Qixi NativeRelease target must define Swift condition QIXI_NATIVE_RELEASE")
  if "OTHER_SWIFT_FLAGS" not in native_block or "-D" not in native_block or "QIXI_NATIVE_RELEASE" not in native_block:
    scope_blockers.append("Qixi NativeRelease target must pass -D QIXI_NATIVE_RELEASE through OTHER_SWIFT_FLAGS")
  if (
    "EXCLUDED_SOURCE_FILE_NAMES" not in native_block
    or "BackendClient.swift" not in native_block
    or "QixiHTTPBridgeAnalysisService.swift" not in native_block
  ):
    scope_blockers.append("Qixi NativeRelease target must exclude development HTTP bridge source files from compilation")

  for name in ("Debug", "Release"):
    for block in _target_xcbuild_configuration_blocks(project, name):
      if "QIXI_NATIVE_RELEASE" in block:
        scope_blockers.append(f"Qixi {name} target must not define QIXI_NATIVE_RELEASE")
  return scope_blockers


def _xcframework_relative_path(raw_path: str, label: str) -> pathlib.PurePosixPath | None:
  if raw_path.startswith("~"):
    blockers.append(f"{label} must not be home-relative")
    return None
  if raw_path.startswith("/"):
    blockers.append(f"{label} must be relative")
    return None
  if "\\" in raw_path:
    blockers.append(f"{label} must use POSIX separators")
    return None
  path = pathlib.PurePosixPath(raw_path)
  if path.is_absolute() or not path.parts:
    blockers.append(f"{label} must be a relative path inside the XCFramework")
    return None
  if any(part in {"", ".", ".."} for part in path.parts):
    blockers.append(f"{label} must not traverse outside the XCFramework")
    return None
  return path


def release_info_plist_path() -> pathlib.Path:
  override = os.environ.get(INFO_OVERRIDE_ENV, "").strip()
  if not override:
    return NATIVE_RELEASE_INFO if NATIVE_RELEASE_INFO.exists() else INFO
  if os.environ.get(TESTING_ENV) != "1":
    blockers.append(f"{INFO_OVERRIDE_ENV} may only be used with {TESTING_ENV}=1")
    return INFO
  return pathlib.Path(override).expanduser()


def find_developer_tool(name: str) -> str | None:
  tool = shutil.which(name)
  if tool:
    return tool
  xcrun = shutil.which("xcrun")
  if not xcrun:
    return None
  result = subprocess.run([xcrun, "--find", name], text=True, capture_output=True, check=False)
  if result.returncode != 0:
    return None
  candidate = result.stdout.strip()
  return candidate or None


def framework_binary_path(path: pathlib.Path) -> pathlib.Path | None:
  if not path.is_dir() or path.suffix != ".framework":
    return None
  binary = path / path.stem
  return binary if binary.exists() and binary.is_file() else None


def validate_library_architecture(path: pathlib.Path, label: str) -> bool:
  lipo = find_developer_tool("lipo")
  if not lipo:
    blockers.append(f"{label} validation requires lipo or xcrun")
    return False
  result = subprocess.run([lipo, "-info", str(path)], text=True, capture_output=True, check=False)
  output = f"{result.stdout}\n{result.stderr}".strip()
  if result.returncode != 0:
    blockers.append(f"{label} must be readable by lipo: {path}: {output}")
    return False
  if "arm64" not in output:
    blockers.append(f"{label} must contain an arm64 iOS device architecture: {path}: {output}")
    return False
  return True


def validate_library_platform(path: pathlib.Path, label: str) -> None:
  otool = find_developer_tool("otool")
  if not otool:
    blockers.append(f"{label} validation requires otool or xcrun")
    return
  result = subprocess.run([otool, "-l", str(path)], text=True, capture_output=True, check=False)
  output = f"{result.stdout}\n{result.stderr}".strip()
  if result.returncode != 0:
    blockers.append(f"{label} must be readable by otool: {path}: {output}")
    return
  normalized = output.lower()
  platform_values = [
    match.group(1).lower()
    for match in re.finditer(r"^\s*platform\s+(\S+)\s*$", output, re.MULTILINE)
  ]
  unexpected_platforms = sorted(
    {value for value in platform_values if value not in IOS_DEVICE_PLATFORM_VALUES}
  )
  if unexpected_platforms:
    blockers.append(
      f"{label} must not contain non-iOS platform object files: "
      f"{', '.join(unexpected_platforms)} in {path}"
    )
    return
  if LEGACY_IPHONEOS_LOAD_COMMAND.lower() in normalized:
    return
  if platform_values and all(value in IOS_DEVICE_PLATFORM_VALUES for value in platform_values):
    return
  blockers.append(
    f"{label} must target the iOS device platform, not macOS or iOS Simulator: {path}"
  )


def library_symbol_text(path: pathlib.Path, label: str) -> str | None:
  nm = find_developer_tool("nm")
  if not nm:
    blockers.append(f"{label} validation requires nm or xcrun")
    return None
  result = subprocess.run([nm, "-arch", "arm64", str(path)], text=True, capture_output=True, check=False)
  output = f"{result.stdout}\n{result.stderr}".strip()
  if result.returncode != 0:
    result = subprocess.run([nm, str(path)], text=True, capture_output=True, check=False)
    output = f"{result.stdout}\n{result.stderr}".strip()
  if result.returncode != 0:
    blockers.append(f"{label} must expose readable KataGo symbols through nm: {path}: {output}")
    return None
  cxxfilt = find_developer_tool("c++filt")
  if not cxxfilt:
    return output
  demangle_result = subprocess.run([cxxfilt], input=output, text=True, capture_output=True, check=False)
  if demangle_result.returncode != 0:
    return output
  return output + "\n" + demangle_result.stdout


def count_defined_symbols(symbol_text: str) -> int:
  return len({
    line.strip()
    for line in symbol_text.splitlines()
    if re.search(r"^[0-9A-Fa-f]+\s+[A-Za-z]\s+", line.strip())
  })


def validate_library_symbols(path: pathlib.Path, label: str) -> None:
  symbol_text = library_symbol_text(path, label)
  if symbol_text is None:
    return
  missing = [fragment for fragment in KATAGO_REQUIRED_SYMBOL_FRAGMENTS if fragment not in symbol_text]
  if missing:
    blockers.append(
      f"{label} does not look like a real KataGo iOS library; missing symbols: {', '.join(missing)}"
    )
  defined_symbol_count = count_defined_symbols(symbol_text)
  if defined_symbol_count < KATAGO_MIN_DEFINED_SYMBOLS:
    blockers.append(
      f"{label} does not expose enough defined symbols for a real KataGo iOS library: "
      f"{defined_symbol_count} found, expected at least {KATAGO_MIN_DEFINED_SYMBOLS}"
    )
  kata_like_symbols = {
    line.strip()
    for line in symbol_text.splitlines()
    if any(fragment in line for fragment in KATAGO_LIKE_SYMBOL_FRAGMENTS)
  }
  if len(kata_like_symbols) < KATAGO_MIN_KATAGO_LIKE_SYMBOLS:
    blockers.append(
      f"{label} does not expose enough KataGo-like C++ symbols: "
      f"{len(kata_like_symbols)} found, expected at least {KATAGO_MIN_KATAGO_LIKE_SYMBOLS}"
    )


def validate_library_binary(path: pathlib.Path, label: str) -> None:
  if not _validate_regular_file(path, label):
    return
  if validate_library_architecture(path, label):
    validate_library_platform(path, label)
    validate_library_symbols(path, label)


def validate_swift_library_symbols(path: pathlib.Path, label: str) -> None:
  symbol_text = library_symbol_text(path, label)
  if symbol_text is None:
    return
  missing = [fragment for fragment in KATAGO_SWIFT_REQUIRED_SYMBOL_FRAGMENTS if fragment not in symbol_text]
  if missing:
    blockers.append(
      f"{label} does not look like the KataGo Swift Metal sidecar; missing symbols: {', '.join(missing)}"
    )
  defined_symbol_count = count_defined_symbols(symbol_text)
  if defined_symbol_count < KATAGO_SWIFT_MIN_DEFINED_SYMBOLS:
    blockers.append(
      f"{label} does not expose enough defined Swift symbols for the KataGo Metal sidecar: "
      f"{defined_symbol_count} found, expected at least {KATAGO_SWIFT_MIN_DEFINED_SYMBOLS}"
    )


def validate_swift_sidecar_for_core_library(library: pathlib.Path) -> None:
  if library.name != "libkatago_core.a":
    return
  library_dir = os.environ.get(IOS_LIBRARY_DIR, "").strip()
  if not library_dir:
    blockers.append(
      f"{IOS_LIBRARY_DIR} must point at the directory containing {KATAGO_SWIFT_LIBRARY_NAME} "
      f"when {IOS_LIBRARY} is libkatago_core.a"
    )
    return
  sidecar_dir = _absolute_env_path(library_dir, IOS_LIBRARY_DIR)
  if sidecar_dir is None:
    return
  if not _validate_directory(sidecar_dir, IOS_LIBRARY_DIR):
    return
  sidecar = sidecar_dir / KATAGO_SWIFT_LIBRARY_NAME
  if not _validate_regular_file(sidecar, f"{IOS_LIBRARY_DIR}/{KATAGO_SWIFT_LIBRARY_NAME}"):
    return
  if validate_library_architecture(sidecar, f"{IOS_LIBRARY_DIR}/{KATAGO_SWIFT_LIBRARY_NAME}"):
    validate_library_platform(sidecar, f"{IOS_LIBRARY_DIR}/{KATAGO_SWIFT_LIBRARY_NAME}")
    validate_swift_library_symbols(sidecar, f"{IOS_LIBRARY_DIR}/{KATAGO_SWIFT_LIBRARY_NAME}")


def validate_xcframework(path: pathlib.Path) -> None:
  info_path = path / "Info.plist"
  if not _validate_regular_file(info_path, f"{IOS_XCFRAMEWORK} Info.plist"):
    if not info_path.exists():
      blockers.append(f"{IOS_XCFRAMEWORK} must contain Info.plist: {info_path}")
    return

  info = load_plist(info_path, f"{IOS_XCFRAMEWORK} Info.plist")
  libraries = info.get("AvailableLibraries")
  if not isinstance(libraries, list):
    blockers.append(f"{IOS_XCFRAMEWORK} Info.plist must declare AvailableLibraries")
    return

  has_ios_arm64_device_slice = False
  has_existing_ios_arm64_artifact = False
  for entry in libraries:
    if not isinstance(entry, dict):
      continue
    platform = entry.get("SupportedPlatform")
    variant = entry.get("SupportedPlatformVariant")
    architectures = entry.get("SupportedArchitectures", [])
    identifier = entry.get("LibraryIdentifier")
    library_path = entry.get("LibraryPath")
    if platform == "ios" and not variant and "arm64" in architectures:
      has_ios_arm64_device_slice = True
      if isinstance(identifier, str) and isinstance(library_path, str):
        portable_identifier = _xcframework_relative_path(
          identifier,
          f"{IOS_XCFRAMEWORK} LibraryIdentifier",
        )
        portable_library_path = _xcframework_relative_path(
          library_path,
          f"{IOS_XCFRAMEWORK} LibraryPath",
        )
        if portable_identifier is None or portable_library_path is None:
          continue
        artifact = path
        for part in (*portable_identifier.parts, *portable_library_path.parts):
          artifact = artifact / part
        if artifact.exists() and (artifact.is_file() or artifact.is_dir()):
          has_existing_ios_arm64_artifact = True
          if artifact.is_dir():
            if not _validate_directory(artifact, f"{IOS_XCFRAMEWORK} slice artifact"):
              continue
            binary = framework_binary_path(artifact)
          else:
            if not _validate_regular_file(artifact, f"{IOS_XCFRAMEWORK} slice artifact"):
              continue
            binary = artifact
          if binary is None:
            blockers.append(f"{IOS_XCFRAMEWORK} iOS device arm64 framework slice is missing its binary: {artifact}")
          else:
            validate_library_binary(binary, IOS_XCFRAMEWORK)

  if not has_ios_arm64_device_slice:
    blockers.append(f"{IOS_XCFRAMEWORK} must contain an iOS device arm64 slice in AvailableLibraries")
  elif not has_existing_ios_arm64_artifact:
    blockers.append(f"{IOS_XCFRAMEWORK} iOS device arm64 slice must reference an existing library or framework")


project = read(PROJECT)
engine = read(ENGINE_IMPL)
info = load_plist(release_info_plist_path(), "release Info.plist")
xcframework_path = os.environ.get(IOS_XCFRAMEWORK, "").strip()
library_path = os.environ.get(IOS_LIBRARY, "").strip()

if "class LinkedNativeKataGoEngine final" not in engine:
  blockers.append("QixiNativeKataGoEngine.cpp must contain the linked native adapter implementation")
if "std::make_unique<LinkedNativeKataGoEngine>()" not in engine:
  blockers.append("makeNativeKataGoEngine must construct LinkedNativeKataGoEngine when native KataGo is enabled")
if "#if QIXI_ENABLE_NATIVE_KATAGO" not in engine:
  blockers.append("linked adapter must stay behind the QIXI_ENABLE_NATIVE_KATAGO compile guard")

if "QIXI_ENABLE_NATIVE_KATAGO=1" not in project:
  blockers.append("Qixi Xcode target must define QIXI_ENABLE_NATIVE_KATAGO=1 for the linked native build")
blockers.extend(_native_release_swift_scope_blockers(project))

if info.get("QixiAnalysisRuntime") != "nativeInProcess":
  blockers.append("linked native release builds must default QixiAnalysisRuntime to nativeInProcess")

if "KataGo/cpp" not in project and "KATAGO_CPP_INCLUDE_DIR" not in project:
  blockers.append("Qixi Xcode target must expose KataGo/cpp headers to the linked native build")

link_tokens = (
  "libkatago",
  "KataGo.xcframework",
  "KataGo.framework",
  "KATAGO_IOS_LIBRARY",
  "KATAGO_IOS_XCFRAMEWORK",
)
if not any(token in project for token in link_tokens):
  blockers.append("Qixi Xcode target must link a real iOS KataGo library or XCFramework")

if not xcframework_path and not library_path:
  blockers.append(
    f"release evidence must set {IOS_XCFRAMEWORK}=<path> or {IOS_LIBRARY}=<path> to a real built iOS KataGo artifact"
  )
if xcframework_path and library_path:
  blockers.append(EXACTLY_ONE_ARTIFACT_MESSAGE)
if xcframework_path:
  xcframework = _absolute_env_path(xcframework_path, IOS_XCFRAMEWORK)
  if xcframework is None:
    pass
  elif xcframework.suffix != ".xcframework":
    blockers.append(f"{IOS_XCFRAMEWORK} must point to an existing .xcframework directory: {xcframework}")
  elif _validate_directory(xcframework, IOS_XCFRAMEWORK):
    validate_xcframework(xcframework)
  if xcframework is not None and "KATAGO_IOS_XCFRAMEWORK" not in project and xcframework.name not in project:
    blockers.append("Qixi Xcode target must reference KATAGO_IOS_XCFRAMEWORK or the configured KataGo XCFramework name")
if library_path:
  library = _absolute_env_path(library_path, IOS_LIBRARY)
  if library is None:
    pass
  elif library.suffix not in {".a", ".dylib"}:
    blockers.append(f"{IOS_LIBRARY} must point to an existing iOS static or dynamic library: {library}")
  elif _validate_regular_file(library, IOS_LIBRARY):
    validate_library_binary(library, IOS_LIBRARY)
    validate_swift_sidecar_for_core_library(library)
  if library is not None and "KATAGO_IOS_LIBRARY" not in project and library.name not in project:
    blockers.append("Qixi Xcode target must reference KATAGO_IOS_LIBRARY or the configured KataGo library name")

required_frameworks = (
  "Metal.framework",
  "Accelerate.framework",
  "CoreML.framework",
  "MetalPerformanceShaders.framework",
  "MetalPerformanceShadersGraph.framework",
)
for framework in required_frameworks:
  if framework not in project:
    blockers.append(f"Qixi Xcode target must link {framework} for native KataGo execution")
if "-lKataGoSwift" not in project:
  blockers.append("Qixi Xcode target must link the KataGoSwift Metal sidecar with -lKataGoSwift")
if "-lz" not in project:
  blockers.append("Qixi Xcode target must link zlib with -lz for KataGo model loading")

if "QixiBackendBaseURL" in info:
  blockers.append("linked native release builds must not ship the default Mac-hosted backend URL")

if blockers:
  fail_many(blockers)

report_errors = write_report("passed", [])
if report_errors:
  fail_many(report_errors)
print("Native linked build preflight passed")
PY
