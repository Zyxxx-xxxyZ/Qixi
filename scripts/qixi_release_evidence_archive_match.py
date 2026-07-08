#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import stat as stat_module
import sys
from typing import Any


class ReleaseEvidenceArchiveMatchError(RuntimeError):
  pass


VALID_RUNTIMES = {"httpBridge", "nativeInProcess"}
REAL_DEVICE_EVIDENCE_SCHEMA_VERSION = 6
REAL_DEVICE_EVIDENCE_KIND = "qixi-real-device-evidence"
REAL_DEVICE_EVIDENCE_MAX_BYTES = 1 * 1024 * 1024
ARCHIVE_PLIST_MAX_BYTES = 1 * 1024 * 1024
ARCHIVE_EXECUTABLE_MAX_BYTES = 256 * 1024 * 1024
SHA256_HEX_PATTERN = re.compile(r"[0-9a-f]{64}")


def _fail(message: str) -> None:
  raise ReleaseEvidenceArchiveMatchError(message)


def _opened_regular_file_stat(handle: Any, path: pathlib.Path, label: str) -> os.stat_result:
  try:
    opened_stat = os.fstat(handle.fileno())
  except OSError as exc:
    _fail(f"{label} could not be inspected after opening: {path}: {exc}")
  if not stat_module.S_ISREG(opened_stat.st_mode):
    _fail(f"{label} must be a regular file after opening: {path}")
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
    _fail(f"{label} must not contain symbolic links: {path}")


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
    _fail(f"{label} does not exist: {path}")
  if not path.is_file():
    _fail(f"{label} is not a regular file: {path}")


def _validate_directory(path: pathlib.Path, label: str) -> None:
  _reject_symlink_components(path, label)
  if not path.exists():
    _fail(f"{label} does not exist: {path}")
  if not path.is_dir():
    _fail(f"{label} is not a directory: {path}")


def _bounded_bytes(path: pathlib.Path, label: str, max_bytes: int) -> bytes:
  if max_bytes <= 0:
    _fail(f"{label} has invalid byte budget")
  try:
    size = path.stat().st_size
  except OSError as exc:
    _fail(f"{label} could not be statted: {path}: {exc}")
  if size > max_bytes:
    _fail(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {path}")
  try:
    with path.open("rb") as handle:
      opened_stat = _opened_regular_file_stat(handle, path, label)
      if opened_stat.st_size > max_bytes:
        _fail(f"{label} exceeds bounded size of {max_bytes} bytes after opening: {path}")
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    _fail(f"{label} could not be read: {path}: {exc}")
  if len(data) > max_bytes:
    _fail(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {path}")
  if len(data) != opened_stat.st_size:
    _fail(
      f"{label} opened-byte-count drift while reading: "
      f"read {len(data)} bytes but opened descriptor reported {opened_stat.st_size} bytes"
    )
  return data


def _sha256_hex_digest(path: pathlib.Path, label: str, max_bytes: int) -> str:
  _validate_regular_file(path, label)
  try:
    size = path.stat().st_size
  except OSError as exc:
    _fail(f"{label} could not be statted: {path}: {exc}")
  if size > max_bytes:
    _fail(f"{label} exceeds bounded size of {max_bytes} bytes before hashing: {path}")
  digest = hashlib.sha256()
  try:
    with path.open("rb") as handle:
      opened_stat = _opened_regular_file_stat(handle, path, label)
      if opened_stat.st_size > max_bytes:
        _fail(f"{label} exceeds bounded size of {max_bytes} bytes after opening: {path}")
      total_bytes = 0
      while True:
        chunk = handle.read(1024 * 1024)
        if not chunk:
          break
        total_bytes += len(chunk)
        if total_bytes > max_bytes:
          _fail(f"{label} exceeds bounded size of {max_bytes} bytes while hashing: {path}")
        digest.update(chunk)
  except OSError as exc:
    _fail(f"{label} could not be read: {path}: {exc}")
  if total_bytes != opened_stat.st_size:
    _fail(
      f"{label} opened-byte-count drift while hashing: "
      f"read {total_bytes} bytes but opened descriptor reported {opened_stat.st_size} bytes"
    )
  return digest.hexdigest()


def _reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
  result: dict[str, Any] = {}
  for key, value in pairs:
    if key in result:
      _fail(f"real-device evidence JSON must not contain duplicate JSON key {key!r}")
    result[key] = value
  return result


def _reject_non_standard_json_constant(value: str) -> None:
  _fail(f"real-device evidence JSON must not contain non-standard JSON constant {value}")


def _load_json(path: pathlib.Path) -> dict[str, Any]:
  _validate_regular_file(path, "QIXI_REAL_DEVICE_EVIDENCE")
  try:
    data = _bounded_bytes(path, "real-device evidence JSON", REAL_DEVICE_EVIDENCE_MAX_BYTES)
    payload = json.loads(
      data.decode("utf-8"),
      object_pairs_hook=_reject_duplicate_json_keys,
      parse_constant=_reject_non_standard_json_constant,
    )
  except ReleaseEvidenceArchiveMatchError:
    raise
  except Exception as exc:
    _fail(f"could not parse real-device evidence JSON {path}: {exc}")
  if not isinstance(payload, dict):
    _fail(f"real-device evidence must be a JSON object: {path}")
  return payload


def _load_plist(path: pathlib.Path) -> dict[str, Any]:
  _validate_regular_file(path, "archive plist")
  try:
    payload = plistlib.loads(_bounded_bytes(path, "archive plist", ARCHIVE_PLIST_MAX_BYTES))
  except ReleaseEvidenceArchiveMatchError:
    raise
  except Exception as exc:
    _fail(f"could not parse archive plist {path}: {exc}")
  if not isinstance(payload, dict):
    _fail(f"archive plist must be a dictionary: {path}")
  return payload


def _str(value: Any, label: str) -> str:
  if not isinstance(value, str) or not value.strip():
    _fail(f"{label} must be a non-empty string")
  return value.strip()


def _archive_application_path(raw_path: str) -> pathlib.PurePosixPath:
  if raw_path.startswith("~"):
    _fail("archive Info.plist ApplicationProperties.ApplicationPath must not be home-relative")
  if raw_path.startswith("/"):
    _fail("archive Info.plist ApplicationProperties.ApplicationPath must be relative")
  if "\\" in raw_path:
    _fail("archive Info.plist ApplicationProperties.ApplicationPath must use POSIX separators")
  path = pathlib.PurePosixPath(raw_path)
  if path.is_absolute() or not path.parts:
    _fail("archive Info.plist ApplicationProperties.ApplicationPath must name an app bundle")
  if any(part in {"", ".", ".."} for part in path.parts):
    _fail("archive Info.plist ApplicationProperties.ApplicationPath must not traverse outside Products")
  if path.suffix != ".app":
    _fail("archive Info.plist ApplicationProperties.ApplicationPath must point to an app bundle")
  return path


def _archive_executable_name(raw_name: str) -> str:
  name = _str(raw_name, "archive app Info.plist CFBundleExecutable")
  if name.startswith("~") or name.startswith("/") or "\\" in name or "/" in name:
    _fail("archive app Info.plist CFBundleExecutable must be a plain executable filename")
  if name in {".", ".."}:
    _fail("archive app Info.plist CFBundleExecutable must be a plain executable filename")
  return name


def _archive_identity(archive_path: pathlib.Path) -> tuple[dict[str, Any], dict[str, Any], str]:
  if archive_path.suffix != ".xcarchive":
    _fail(f"QIXI_APPSTORE_ARCHIVE_PATH must point to an existing .xcarchive directory: {archive_path}")
  _validate_directory(archive_path, "QIXI_APPSTORE_ARCHIVE_PATH")
  archive_info = _load_plist(archive_path / "Info.plist")
  application_properties = archive_info.get("ApplicationProperties")
  if not isinstance(application_properties, dict):
    _fail("archive Info.plist ApplicationProperties must be a dictionary")
  application_path = _str(
    application_properties.get("ApplicationPath"),
    "archive Info.plist ApplicationProperties.ApplicationPath",
  )
  portable_application_path = _archive_application_path(application_path)
  app_bundle = archive_path / "Products"
  for part in portable_application_path.parts:
    app_bundle = app_bundle / part
  _validate_directory(app_bundle, "archive ApplicationProperties.ApplicationPath")
  app_info = _load_plist(app_bundle / "Info.plist")
  executable_name = _archive_executable_name(app_info.get("CFBundleExecutable"))
  executable_digest = _sha256_hex_digest(
    app_bundle / executable_name,
    "archive app executable",
    ARCHIVE_EXECUTABLE_MAX_BYTES,
  )
  return application_properties, app_info, executable_digest


def _evidence_app(evidence_path: pathlib.Path) -> dict[str, Any]:
  evidence = _load_json(evidence_path)
  if evidence.get("schemaVersion") != REAL_DEVICE_EVIDENCE_SCHEMA_VERSION:
    _fail(f"real-device evidence schemaVersion must be {REAL_DEVICE_EVIDENCE_SCHEMA_VERSION}")
  if evidence.get("kind") != REAL_DEVICE_EVIDENCE_KIND:
    _fail(f"real-device evidence kind must be {REAL_DEVICE_EVIDENCE_KIND}")
  app = evidence.get("app")
  if not isinstance(app, dict):
    _fail("real-device evidence app must be an object")
  return app


def _require_equal(evidence_value: str, archive_value: str, evidence_label: str, archive_label: str) -> None:
  if evidence_value != archive_value:
    _fail(
      f"{evidence_label}={evidence_value!r} must match "
      f"{archive_label}={archive_value!r}"
    )


def _runtime(value: Any, label: str) -> str:
  runtime = _str(value, label)
  if runtime not in VALID_RUNTIMES:
    _fail(f"{label} must be httpBridge or nativeInProcess")
  return runtime


def _normalized_expected_runtime(raw_value: str | None) -> str | None:
  if raw_value is None:
    return None
  value = raw_value.strip()
  if not value:
    return None
  if value not in VALID_RUNTIMES:
    _fail("QIXI_REAL_DEVICE_EXPECT_RUNTIME must be httpBridge or nativeInProcess")
  return value


def validate_archive_match(
  evidence_path: pathlib.Path,
  archive_path: pathlib.Path,
  *,
  expected_runtime: str | None = None,
) -> dict[str, str]:
  app = _evidence_app(evidence_path)
  application_properties, app_info, archive_executable_digest = _archive_identity(archive_path)
  expected_runtime = _normalized_expected_runtime(expected_runtime)

  evidence_bundle = _str(app.get("bundleIdentifier"), "real-device evidence app.bundleIdentifier")
  evidence_version = _str(app.get("version"), "real-device evidence app.version")
  evidence_build = _str(app.get("build"), "real-device evidence app.build")
  evidence_runtime = _runtime(app.get("analysisRuntime"), "real-device evidence app.analysisRuntime")
  evidence_executable_digest = _str(
    app.get("executableSHA256HexDigest"),
    "real-device evidence app.executableSHA256HexDigest",
  )
  if not SHA256_HEX_PATTERN.fullmatch(evidence_executable_digest):
    _fail("real-device evidence app.executableSHA256HexDigest must be a lowercase SHA-256 hex digest")

  archive_bundle = _str(app_info.get("CFBundleIdentifier"), "archive app Info.plist CFBundleIdentifier")
  archive_version = _str(
    app_info.get("CFBundleShortVersionString"),
    "archive app Info.plist CFBundleShortVersionString",
  )
  archive_build = _str(app_info.get("CFBundleVersion"), "archive app Info.plist CFBundleVersion")
  archive_runtime = _runtime(
    app_info.get("QixiAnalysisRuntime"),
    "archive app Info.plist QixiAnalysisRuntime",
  )
  archive_properties_bundle = _str(
    application_properties.get("CFBundleIdentifier"),
    "archive Info.plist ApplicationProperties.CFBundleIdentifier",
  )
  archive_properties_version = _str(
    application_properties.get("CFBundleShortVersionString"),
    "archive Info.plist ApplicationProperties.CFBundleShortVersionString",
  )
  archive_properties_build = _str(
    application_properties.get("CFBundleVersion"),
    "archive Info.plist ApplicationProperties.CFBundleVersion",
  )

  _require_equal(
    archive_properties_bundle,
    archive_bundle,
    "archive Info.plist ApplicationProperties.CFBundleIdentifier",
    "archive app Info.plist CFBundleIdentifier",
  )
  _require_equal(
    archive_properties_version,
    archive_version,
    "archive Info.plist ApplicationProperties.CFBundleShortVersionString",
    "archive app Info.plist CFBundleShortVersionString",
  )
  _require_equal(
    archive_properties_build,
    archive_build,
    "archive Info.plist ApplicationProperties.CFBundleVersion",
    "archive app Info.plist CFBundleVersion",
  )

  _require_equal(
    evidence_bundle,
    archive_bundle,
    "real-device evidence app.bundleIdentifier",
    "archive app Info.plist CFBundleIdentifier",
  )
  _require_equal(
    evidence_version,
    archive_version,
    "real-device evidence app.version",
    "archive app Info.plist CFBundleShortVersionString",
  )
  _require_equal(
    evidence_build,
    archive_build,
    "real-device evidence app.build",
    "archive app Info.plist CFBundleVersion",
  )
  _require_equal(
    evidence_runtime,
    archive_runtime,
    "real-device evidence app.analysisRuntime",
    "archive app Info.plist QixiAnalysisRuntime",
  )
  _require_equal(
    evidence_executable_digest,
    archive_executable_digest,
    "real-device evidence app.executableSHA256HexDigest",
    "archive app executable SHA-256",
  )
  if expected_runtime is not None:
    _require_equal(
      evidence_runtime,
      expected_runtime,
      "real-device evidence app.analysisRuntime",
      "QIXI_REAL_DEVICE_EXPECT_RUNTIME",
    )

  return {
    "bundleIdentifier": evidence_bundle,
    "version": evidence_version,
    "build": evidence_build,
    "analysisRuntime": evidence_runtime,
    "executableSHA256HexDigest": evidence_executable_digest,
  }


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(
    description="Validate that real-device evidence was recorded from the submitted Qixi archive build."
  )
  parser.add_argument("--evidence", default=os.environ.get("QIXI_REAL_DEVICE_EVIDENCE", ""))
  parser.add_argument("--archive", default=os.environ.get("QIXI_APPSTORE_ARCHIVE_PATH", ""))
  parser.add_argument("--expected-runtime", default=os.environ.get("QIXI_REAL_DEVICE_EXPECT_RUNTIME", ""))
  args = parser.parse_args(argv)

  if not args.evidence:
    print(
      "Release evidence/archive match failed: QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json is required",
      file=sys.stderr,
    )
    return 1
  if not args.archive:
    print(
      "Release evidence/archive match failed: QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive is required",
      file=sys.stderr,
    )
    return 1

  try:
    summary = validate_archive_match(
      pathlib.Path(args.evidence).expanduser(),
      pathlib.Path(args.archive).expanduser(),
      expected_runtime=args.expected_runtime,
    )
  except ReleaseEvidenceArchiveMatchError as exc:
    print(f"Release evidence/archive match failed: {exc}", file=sys.stderr)
    return 1

  print(
    "Release evidence/archive match passed: "
    f"{summary['bundleIdentifier']} {summary['version']} "
    f"({summary['build']}) runtime={summary['analysisRuntime']}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
