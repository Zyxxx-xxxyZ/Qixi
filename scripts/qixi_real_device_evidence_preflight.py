#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
import pathlib
import re
import stat as stat_module
import sys
from typing import Any

from qixi_device_run_preflight import DeviceRunPreflightError, validate_physical_device_backend_url


class RealDeviceEvidenceError(RuntimeError):
  pass


VALID_RUNTIMES = {"httpBridge", "nativeInProcess"}
VALID_DEVICE_IDIOMS = {"iPad", "iPhone"}
VALID_ENGINES = {"b6", "b18nbt", "b28nbt"}
REQUIRED_ARTIFACT_KINDS = {"screenshot", "performance", "device-log"}
REAL_DEVICE_EVIDENCE_SCHEMA_VERSION = 6
REAL_DEVICE_EVIDENCE_KIND = "qixi-real-device-evidence"
REAL_DEVICE_EVIDENCE_MAX_BYTES = 1 * 1024 * 1024
PERFORMANCE_ARTIFACT_MAX_BYTES = 1 * 1024 * 1024
DEVICE_LOG_ARTIFACT_MAX_BYTES = 1 * 1024 * 1024
SCREENSHOT_ARTIFACT_MAX_BYTES = 64 * 1024 * 1024
SWIFT_NATIVE_MODEL_REGISTRY_MAX_BYTES = 4 * 1024 * 1024
REAL_DEVICE_EVIDENCE_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
REAL_DEVICE_EVIDENCE_FUTURE_CLOCK_SKEW_SECONDS = 5 * 60
STAGED_ARTIFACT_MAX_AGE_SECONDS = 24 * 60 * 60
PERFORMANCE_ARTIFACT_KIND = "qixi-real-device-performance"
PERFORMANCE_ARTIFACT_SCHEMA_VERSION = 1
DEVICE_LOG_ARTIFACT_SCHEMA_VERSION = 1
VALID_PERFORMANCE_ARTIFACT_SOURCES = {"instruments", "xctrace", "metricKit"}
RESERVED_ARTIFACT_FILENAMES = {"real-device-evidence.qixi-release.json", "real-device-evidence.export.json"}
RUN_ID_PATTERN = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SHA256_HEX_PATTERN = re.compile(r"[0-9a-f]{64}")
ROOT = pathlib.Path(__file__).resolve().parents[1]
SWIFT_NATIVE_MODEL_REGISTRY = ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelRegistry.swift"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SCREENSHOT_MIN_DIMENSIONS = {
  "iPad": (1000, 700),
  "iPhone": (800, 350),
}
SCREENSHOT_MIN_VISUAL_VARIANCE = 12.0
SCREENSHOT_MIN_DARK_PIXEL_RATIO = 1 / 1000
SCREENSHOT_MIN_DARK_PIXELS = 800
SCREENSHOT_MAX_PIXELS = 16 * 1024 * 1024
PNG_HEADER_BYTES = 33
NATIVE_TOMBSTONE_FILENAME = "native-engine-tombstone.qixi-native"
NATIVE_TOMBSTONE_AUDIT_MAX_AGE_SECONDS = 24 * 60 * 60


def _fail(message: str) -> None:
  raise RealDeviceEvidenceError(message)


def _opened_regular_file_stat(handle: Any, path: pathlib.Path, label: str) -> os.stat_result:
  try:
    opened_stat = os.fstat(handle.fileno())
  except OSError as exc:
    _fail(f"{label} could not be inspected after opening: {path}: {exc}")
  if not stat_module.S_ISREG(opened_stat.st_mode):
    _fail(f"{label} must be a regular file after opening: {path}")
  return opened_stat


def _bounded_text(path: pathlib.Path, label: str, max_bytes: int) -> str:
  if max_bytes <= 0:
    _fail(f"{label} has invalid byte budget")
  try:
    size = path.stat().st_size
  except OSError as exc:
    _fail(f"{label} could not be statted: {path}: {exc}")
  if size > max_bytes:
    _fail(f"{label} exceeds bounded JSON size of {max_bytes} bytes before loading: {path}")
  try:
    with path.open("rb") as handle:
      opened_stat = _opened_regular_file_stat(handle, path, label)
      if opened_stat.st_size > max_bytes:
        _fail(f"{label} exceeds bounded JSON size of {max_bytes} bytes after opening: {path}")
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    _fail(f"{label} could not be read: {path}: {exc}")
  if len(data) > max_bytes:
    _fail(f"{label} exceeds bounded JSON size of {max_bytes} bytes before loading: {path}")
  if len(data) != opened_stat.st_size:
    _fail(
      f"{label} opened-byte-count drift while reading: "
      f"read {len(data)} bytes but opened descriptor reported {opened_stat.st_size} bytes"
    )
  try:
    return data.decode("utf-8")
  except UnicodeDecodeError as exc:
    _fail(f"{label} must be UTF-8 JSON: {path}: {exc}")


def _json_max_bytes(label: str) -> int:
  if label == "real-device evidence JSON":
    return REAL_DEVICE_EVIDENCE_MAX_BYTES
  if label == "performance artifact":
    return PERFORMANCE_ARTIFACT_MAX_BYTES
  if label == "device-log artifact":
    return DEVICE_LOG_ARTIFACT_MAX_BYTES
  _fail(f"{label} has no bounded JSON byte budget")


def _load_json_without_duplicate_keys(path: pathlib.Path, label: str) -> Any:
  def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
      if key in result:
        _fail(f"{label} must not contain duplicate JSON key {key!r}")
      result[key] = value
    return result

  def reject_non_standard_constant(value: str) -> None:
    _fail(f"{label} must not contain non-standard JSON constant {value}")

  try:
    return json.loads(
      _bounded_text(path, label, _json_max_bytes(label)),
      object_pairs_hook=reject_duplicate_keys,
      parse_constant=reject_non_standard_constant,
    )
  except RealDeviceEvidenceError:
    raise
  except Exception as exc:
    _fail(f"{label} must be JSON: {path}: {exc}")


def load_native_model_manifest_from_swift_registry(
  registry_path: pathlib.Path = SWIFT_NATIVE_MODEL_REGISTRY,
) -> dict[str, dict[str, object]]:
  source = _bounded_source_text(
    registry_path,
    "Swift native model registry",
    SWIFT_NATIVE_MODEL_REGISTRY_MAX_BYTES,
  )

  case_pattern = re.compile(
    r"case \.(?P<engine>[A-Za-z0-9]+):(?P<body>.*?)(?=\n    case \.|\n    \}\n  \})",
    re.MULTILINE | re.DOTALL,
  )
  spec_pattern = re.compile(
    r"return NativeKataGoModelSpec\(\s*"
    r"engine: engine,\s*"
    r'resourceName: "(?P<resourceName>[^"]+)",\s*'
    r"expectedByteCount: (?P<byteCount>\d+),\s*"
    r'sha256HexDigest: "(?P<sha256HexDigest>[0-9a-f]{64})",\s*'
    r"minimumMemoryMB: (?P<minimumMemoryMB>\d+),\s*"
    r"recommendedMemoryMB: (?P<recommendedMemoryMB>\d+),\s*"
    r"maximumMemoryMB: (?P<maximumMemoryMB>\d+)",
    re.MULTILINE | re.DOTALL,
  )
  package_pattern = re.compile(
    r"NativeKataGoCoreMLPackageSpec\(\s*"
    r'resourceName: "(?P<resourceName>[^"]+)",\s*'
    r'variantID: "(?P<variantID>[^"]+)",\s*'
    r"expectedFileCount: (?P<fileCount>\d+),\s*"
    r"expectedTotalByteCount: (?P<totalByteCount>\d+),\s*"
    r'sha256TreeDigest: "(?P<sha256TreeDigest>[0-9a-f]{64})"',
    re.MULTILINE | re.DOTALL,
  )
  manifest: dict[str, dict[str, object]] = {}
  for case_match in case_pattern.finditer(source):
    engine = case_match.group("engine")
    if engine not in VALID_ENGINES:
      continue
    body = case_match.group("body")
    match = spec_pattern.search(body)
    if not match:
      continue
    manifest[engine] = {
      "resourceName": match.group("resourceName"),
      "byteCount": int(match.group("byteCount")),
      "sha256HexDigest": match.group("sha256HexDigest"),
      "minimumMemoryMB": int(match.group("minimumMemoryMB")),
      "recommendedMemoryMB": int(match.group("recommendedMemoryMB")),
      "maximumMemoryMB": int(match.group("maximumMemoryMB")),
      "coreMLPackages": [
        {
          "resourceName": package_match.group("resourceName"),
          "variantID": package_match.group("variantID"),
          "fileCount": int(package_match.group("fileCount")),
          "totalByteCount": int(package_match.group("totalByteCount")),
          "sha256TreeDigest": package_match.group("sha256TreeDigest"),
        }
        for package_match in package_pattern.finditer(body)
      ],
    }

  missing = sorted(VALID_ENGINES - set(manifest))
  if missing:
    raise RealDeviceEvidenceError(
      f"Swift native model registry is missing release-evidence engines: {', '.join(missing)}"
    )
  return manifest

def _dict(value: Any, path: str) -> dict[str, Any]:
  if not isinstance(value, dict):
    _fail(f"{path} must be an object")
  return value


def _list(value: Any, path: str) -> list[Any]:
  if not isinstance(value, list):
    _fail(f"{path} must be an array")
  return value


def _str(value: Any, path: str) -> str:
  if not isinstance(value, str) or not value.strip():
    _fail(f"{path} must be a non-empty string")
  return value.strip()


def _bool(value: Any, path: str) -> bool:
  if not isinstance(value, bool):
    _fail(f"{path} must be a boolean")
  return value


def _number(value: Any, path: str) -> float:
  if not isinstance(value, (int, float)) or isinstance(value, bool):
    _fail(f"{path} must be a number")
  number = float(value)
  if not math.isfinite(number):
    _fail(f"{path} must be a finite number")
  return number


def _int(value: Any, path: str) -> int:
  if not isinstance(value, int) or isinstance(value, bool):
    _fail(f"{path} must be an integer")
  return value


def _datetime(value: Any, path: str) -> datetime.datetime:
  raw = _str(value, path)
  try:
    parsed = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
  except ValueError as exc:
    _fail(f"{path} must be an ISO-8601 timestamp: {exc}")
  if parsed.tzinfo is None:
    _fail(f"{path} must include a timezone")
  return parsed.astimezone(datetime.timezone.utc)


def _run_id(value: Any, path: str) -> str:
  run_id = _str(value, path)
  if not RUN_ID_PATTERN.fullmatch(run_id):
    _fail(f"{path} must be a canonical lowercase UUID")
  return run_id


def _validate_recorded_at_freshness(
  recorded_at: datetime.datetime,
  *,
  now: datetime.datetime,
  max_age_seconds: float,
) -> None:
  if now.tzinfo is None:
    _fail("internal preflight clock must include a timezone")
  now = now.astimezone(datetime.timezone.utc)
  if max_age_seconds <= 0:
    _fail("QIXI_REAL_DEVICE_MAX_EVIDENCE_AGE_SECONDS must be positive")
  if (recorded_at - now).total_seconds() > REAL_DEVICE_EVIDENCE_FUTURE_CLOCK_SKEW_SECONDS:
    _fail("recordedAt must not be in the future beyond the release-evidence clock-skew budget")
  if (now - recorded_at).total_seconds() > max_age_seconds:
    _fail("recordedAt is too old for release evidence")


def _validate_artifact_recorded_at(
  payload: dict[str, Any],
  *,
  recorded_at: datetime.datetime,
  label: str,
  allow_staged_before_evidence: bool = False,
) -> None:
  artifact_recorded_at = _datetime(payload.get("recordedAt"), f"{label} recordedAt")
  if allow_staged_before_evidence:
    if (artifact_recorded_at - recorded_at).total_seconds() > 0:
      _fail(
        f"{label} recordedAt={artifact_recorded_at.isoformat()} "
        f"must not be newer than evidence recordedAt={recorded_at.isoformat()}"
      )
    if (recorded_at - artifact_recorded_at).total_seconds() > STAGED_ARTIFACT_MAX_AGE_SECONDS:
      _fail(f"{label} recordedAt is too old for staged release evidence")
    return
  if artifact_recorded_at != recorded_at:
    _fail(
      f"{label} recordedAt={artifact_recorded_at.isoformat()} "
      f"must match evidence recordedAt={recorded_at.isoformat()}"
    )


def _validate_artifact_run_id(payload: dict[str, Any], *, run_id: str, label: str) -> None:
  artifact_run_id = _run_id(payload.get("runId"), f"{label} runId")
  if artifact_run_id != run_id:
    _fail(f"{label} runId={artifact_run_id} must match evidence runId={run_id}")


def _bounded_positive(value: Any, path: str, maximum: float) -> float:
  number = _number(value, path)
  if number <= 0:
    _fail(f"{path} must be positive")
  if number > maximum:
    _fail(f"{path}={number:g} exceeds budget {maximum:g}")
  return number


def _bounded_positive_int(value: Any, path: str, maximum: int) -> int:
  number = _int(value, path)
  if number <= 0:
    _fail(f"{path} must be positive")
  if number > maximum:
    _fail(f"{path}={number} exceeds budget {maximum}")
  return number


def _artifact_portable_path(raw_path: str, path_label: str) -> pathlib.PurePosixPath:
  if raw_path.startswith("~"):
    _fail(f"{path_label} must be relative to the evidence file, not a home-relative path")
  if raw_path.startswith("/"):
    _fail(f"{path_label} must be relative to the evidence file, not an absolute path")
  if "\\" in raw_path:
    _fail(f"{path_label} must use portable POSIX separators")
  raw_parts = raw_path.split("/")
  if not raw_parts:
    _fail(f"{path_label} must name a relative artifact file")
  if any(part == "" or part == "." for part in raw_parts):
    _fail(f"{path_label} must not contain empty or current-directory path components")
  if any(part == ".." for part in raw_parts):
    _fail(f"{path_label} must not traverse outside the evidence directory")
  path = pathlib.PurePosixPath(*raw_parts)
  if path.is_absolute() or not path.parts:
    _fail(f"{path_label} must name a relative artifact file")
  return path


def _resolve_artifact(evidence_path: pathlib.Path, portable_path: pathlib.PurePosixPath) -> pathlib.Path:
  return evidence_path.parent.joinpath(*portable_path.parts)


def _reject_symlink_path(path: pathlib.Path, label: str) -> None:
  if path.is_symlink() and not _is_allowed_platform_symlink_alias(path):
    _fail(f"{label} must not contain symbolic links: {path}")


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


def _reject_symlink_components(path: pathlib.Path, label: str) -> None:
  current = pathlib.Path(path.anchor) if path.anchor else pathlib.Path()
  for part in path.parts:
    if part == path.anchor or not part:
      continue
    current = current / part
    _reject_symlink_path(current, label)


def _resolve_regular_artifact(evidence_path: pathlib.Path, portable_path: pathlib.PurePosixPath) -> pathlib.Path:
  path = _resolve_artifact(evidence_path, portable_path)
  _reject_symlink_components(path, "artifact path")
  if not path.exists():
    _fail(f"artifact does not exist: {path}")
  if not path.is_file():
    _fail(f"artifact is not a regular file: {path}")
  return path


def _reject_reserved_artifact_path(evidence_path: pathlib.Path, portable_path: pathlib.PurePosixPath) -> None:
  if portable_path.name in RESERVED_ARTIFACT_FILENAMES:
    _fail(f"artifact path must not use reserved real-device evidence filenames: {portable_path.as_posix()}")
  artifact_path = _resolve_artifact(evidence_path, portable_path)
  if artifact_path == evidence_path:
    _fail(f"artifact path must not overwrite the real-device evidence file: {portable_path.as_posix()}")


def _validate_existing_regular_file(path: pathlib.Path, label: str) -> None:
  _reject_symlink_components(path, label)
  if not path.exists():
    _fail(f"{label} does not exist: {path}")
  if not path.is_file():
    _fail(f"{label} is not a regular file: {path}")


def _validate_evidence_input_file(path: pathlib.Path) -> None:
  _reject_symlink_components(path.parent, "evidence directory")
  _validate_existing_regular_file(path, "QIXI_REAL_DEVICE_EVIDENCE")


def _bounded_source_text(path: pathlib.Path, label: str, max_bytes: int) -> str:
  _validate_existing_regular_file(path, label)
  if max_bytes <= 0:
    _fail(f"{label} has invalid byte budget")
  try:
    size = path.stat().st_size
  except OSError as exc:
    _fail(f"{label} could not be statted: {path}: {exc}")
  if size > max_bytes:
    _fail(f"{label} exceeds bounded source size of {max_bytes} bytes before loading: {path}")
  try:
    with path.open("rb") as handle:
      opened_stat = _opened_regular_file_stat(handle, path, label)
      if opened_stat.st_size > max_bytes:
        _fail(f"{label} exceeds bounded source size of {max_bytes} bytes after opening: {path}")
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    _fail(f"{label} could not be read: {path}: {exc}")
  if len(data) > max_bytes:
    _fail(f"{label} exceeds bounded source size of {max_bytes} bytes before loading: {path}")
  if len(data) != opened_stat.st_size:
    _fail(
      f"{label} opened-byte-count drift while reading: "
      f"read {len(data)} bytes but opened descriptor reported {opened_stat.st_size} bytes"
    )
  try:
    return data.decode("utf-8")
  except UnicodeDecodeError as exc:
    _fail(f"{label} must be UTF-8 source: {path}: {exc}")


NATIVE_MODEL_MANIFEST = load_native_model_manifest_from_swift_registry()


def _max_artifact_bytes(kind: str) -> int:
  if kind == "screenshot":
    return SCREENSHOT_ARTIFACT_MAX_BYTES
  if kind == "performance":
    return PERFORMANCE_ARTIFACT_MAX_BYTES
  if kind == "device-log":
    return DEVICE_LOG_ARTIFACT_MAX_BYTES
  _fail(f"artifact kind is unsupported: {kind}")


def _validate_artifact_byte_budget(kind: str, path: pathlib.Path, actual_byte_count: int) -> None:
  max_bytes = _max_artifact_bytes(kind)
  if actual_byte_count > max_bytes:
    _fail(
      f"artifact {kind} exceeds bounded artifact size of {max_bytes} bytes before fingerprinting: {path}"
    )


def _artifact_file_fingerprint(kind: str, path: pathlib.Path) -> tuple[int, str]:
  max_bytes = _max_artifact_bytes(kind)
  digest = hashlib.sha256()
  total_bytes = 0
  try:
    with path.open("rb") as handle:
      opened_stat = _opened_regular_file_stat(handle, path, f"artifact {kind} while hashing")
      if opened_stat.st_size > max_bytes:
        _fail(
          f"artifact {kind} exceeds bounded artifact size of {max_bytes} bytes after opening while hashing: {path}"
        )
      for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        total_bytes += len(chunk)
        if total_bytes > max_bytes:
          _fail(
            f"artifact {kind} exceeds bounded artifact size of {max_bytes} bytes while hashing: {path}"
          )
        digest.update(chunk)
  except OSError as exc:
    _fail(f"artifact {kind} could not be read while hashing: {path}: {exc}")
  if total_bytes != opened_stat.st_size:
    _fail(
      f"artifact {kind} opened-byte-count drift while hashing: "
      f"read {total_bytes} bytes but opened descriptor reported {opened_stat.st_size} bytes"
    )
  return total_bytes, digest.hexdigest()


def _validate_artifact_fingerprint(artifact: dict[str, Any], kind: str, path: pathlib.Path) -> None:
  actual_byte_count, actual_digest = _artifact_file_fingerprint(kind, path)
  expected_byte_count = _int(artifact.get("byteCount"), f"artifact {kind}.byteCount")
  if expected_byte_count != actual_byte_count:
    _fail(f"artifact {kind}.byteCount={expected_byte_count} must match file byte count {actual_byte_count}")
  expected_digest = _str(artifact.get("sha256HexDigest"), f"artifact {kind}.sha256HexDigest")
  if not SHA256_HEX_PATTERN.fullmatch(expected_digest):
    _fail(f"artifact {kind}.sha256HexDigest must be a lowercase SHA-256 hex digest")
  if expected_digest != actual_digest:
    _fail(
      f"artifact {kind}.sha256HexDigest={expected_digest} "
      f"must match file SHA-256 {actual_digest}"
    )


def _read_png_dimensions(path: pathlib.Path) -> tuple[int, int]:
  with path.open("rb") as handle:
    data = handle.read(PNG_HEADER_BYTES)
  if len(data) < PNG_HEADER_BYTES or data[: len(PNG_SIGNATURE)] != PNG_SIGNATURE:
    _fail(f"screenshot artifact must be a PNG file: {path}")
  ihdr_length = int.from_bytes(data[8:12], "big")
  ihdr_kind = data[12:16]
  if ihdr_length != 13 or ihdr_kind != b"IHDR":
    _fail(f"screenshot artifact must have a valid PNG IHDR: {path}")
  width = int.from_bytes(data[16:20], "big")
  height = int.from_bytes(data[20:24], "big")
  if width <= 0 or height <= 0:
    _fail(f"screenshot artifact has invalid PNG dimensions: {path}")
  if width * height > SCREENSHOT_MAX_PIXELS:
    _fail(f"screenshot artifact is too large for bounded visual inspection: {width}x{height} {path}")
  return width, height


def _validate_screenshot_dimensions(device_idiom: str, path: pathlib.Path) -> None:
  width, height = _read_png_dimensions(path)
  if width <= height:
    _fail(f"screenshot artifact must be landscape for {device_idiom}: {width}x{height} {path}")
  minimum = SCREENSHOT_MIN_DIMENSIONS.get(device_idiom)
  if not minimum:
    _fail(f"device.idiom has no screenshot size budget: {device_idiom}")
  min_width, min_height = minimum
  if width < min_width or height < min_height:
    _fail(
      f"screenshot artifact is too small for {device_idiom}: "
      f"{width}x{height}, expected at least {min_width}x{min_height}"
    )
  _validate_screenshot_visual_content(path, width, height)


def _validate_screenshot_visual_content(path: pathlib.Path, width: int, height: int) -> None:
  try:
    from PIL import Image, ImageStat
  except Exception as exc:
    _fail(f"screenshot artifact visual inspection requires Pillow: {exc}")
  try:
    image = Image.open(path).convert("RGB")
  except Exception as exc:
    _fail(f"screenshot artifact must be a decodable PNG image: {path}: {exc}")
  if image.size != (width, height):
    _fail(f"screenshot artifact decoded dimensions do not match PNG IHDR: {path}")
  stat = ImageStat.Stat(image)
  variance = sum(stat.stddev)
  if variance < SCREENSHOT_MIN_VISUAL_VARIANCE:
    _fail(f"screenshot artifact looks blank or nearly flat: variance={variance:.3f} {path}")
  pixels = image.get_flattened_data() if hasattr(image, "get_flattened_data") else image.getdata()
  dark_pixels = sum(1 for red, green, blue in pixels if max(red, green, blue) < 72)
  required_dark_pixels = max(SCREENSHOT_MIN_DARK_PIXELS, int(width * height * SCREENSHOT_MIN_DARK_PIXEL_RATIO))
  if dark_pixels < required_dark_pixels:
    _fail(
      f"screenshot artifact lacks visible board/grid detail: "
      f"darkPixels={dark_pixels}, required={required_dark_pixels} {path}"
    )


def _measurements_object(evidence: dict[str, Any]) -> dict[str, Any]:
  return _dict(evidence.get("measurements"), "measurements")


def _validate_matching_artifact_number(
  artifact_measurements: dict[str, Any],
  evidence_measurements: dict[str, Any],
  section: str,
  field: str,
) -> None:
  artifact_section = _dict(
    artifact_measurements.get(section),
    f"performance artifact measurements.{section}",
  )
  evidence_section = _dict(evidence_measurements.get(section), f"measurements.{section}")
  artifact_value = _number(
    artifact_section.get(field),
    f"performance artifact measurements.{section}.{field}",
  )
  evidence_value = _number(evidence_section.get(field), f"measurements.{section}.{field}")
  if abs(artifact_value - evidence_value) > 1e-9:
    _fail(
      f"performance artifact measurements.{section}.{field}={artifact_value:g} "
      f"must match evidence measurements.{section}.{field}={evidence_value:g}"
    )


def _validate_performance_artifact(
  path: pathlib.Path,
  evidence_measurements: dict[str, Any],
  recorded_at: datetime.datetime,
  run_id: str,
) -> None:
  payload = _load_json_without_duplicate_keys(path, "performance artifact")
  if not isinstance(payload, dict):
    _fail(f"performance artifact must be a JSON object: {path}")
  if _int(payload.get("schemaVersion"), "performance artifact.schemaVersion") != PERFORMANCE_ARTIFACT_SCHEMA_VERSION:
    _fail(f"performance artifact.schemaVersion must be {PERFORMANCE_ARTIFACT_SCHEMA_VERSION}")
  if _str(payload.get("kind"), "performance artifact.kind") != PERFORMANCE_ARTIFACT_KIND:
    _fail(f"performance artifact.kind must be {PERFORMANCE_ARTIFACT_KIND}")
  source = _str(payload.get("source"), "performance artifact.source")
  if source not in VALID_PERFORMANCE_ARTIFACT_SOURCES:
    _fail(
      "performance artifact.source must be one of "
      f"{', '.join(sorted(VALID_PERFORMANCE_ARTIFACT_SOURCES))}"
    )
  _validate_artifact_run_id(payload, run_id=run_id, label="performance artifact")
  _validate_artifact_recorded_at(
    payload,
    recorded_at=recorded_at,
    label="performance artifact",
    allow_staged_before_evidence=True,
  )
  artifact_measurements = _dict(
    payload.get("measurements"),
    "performance artifact measurements",
  )
  for section, fields in (
    ("launch", ("coldLaunchMs", "visualReadyMs")),
    ("memory", ("peakRSSMB", "postAnalysisRSSMB")),
    ("framePacing", ("targetRefreshHz", "observedRefreshHz", "droppedFramePercent")),
  ):
    for field in fields:
      _validate_matching_artifact_number(artifact_measurements, evidence_measurements, section, field)


def _validate_matching_value(
  artifact_root: dict[str, Any],
  evidence_root: dict[str, Any],
  path: tuple[str, ...],
) -> None:
  artifact_value: Any = artifact_root
  evidence_value: Any = evidence_root
  rendered = ".".join(path)
  for part in path:
    artifact_value = _dict(artifact_value, f"device-log artifact {rendered}").get(part)
    evidence_value = _dict(evidence_value, rendered).get(part)
  if artifact_value != evidence_value:
    _fail(
      f"device-log artifact {rendered}={artifact_value!r} "
      f"must match evidence {rendered}={evidence_value!r}"
    )


def _validate_device_log_artifact(
  path: pathlib.Path,
  evidence: dict[str, Any],
  recorded_at: datetime.datetime,
  run_id: str,
) -> None:
  payload = _load_json_without_duplicate_keys(path, "device-log artifact")
  payload = _dict(payload, "device-log artifact")
  if _int(payload.get("schemaVersion"), "device-log artifact.schemaVersion") != DEVICE_LOG_ARTIFACT_SCHEMA_VERSION:
    _fail(f"device-log artifact.schemaVersion must be {DEVICE_LOG_ARTIFACT_SCHEMA_VERSION}")
  if _str(payload.get("kind"), "device-log artifact.kind") != "qixi-real-device-log":
    _fail("device-log artifact.kind must be qixi-real-device-log")
  _validate_artifact_run_id(payload, run_id=run_id, label="device-log artifact")
  _validate_artifact_recorded_at(payload, recorded_at=recorded_at, label="device-log artifact")

  for field_path in (
    ("device", "idiom"),
    ("device", "model"),
    ("device", "osVersion"),
    ("device", "simulator"),
    ("app", "bundleIdentifier"),
    ("app", "version"),
    ("app", "build"),
    ("app", "analysisRuntime"),
    ("app", "executableSHA256HexDigest"),
    ("analysis", "engineId"),
    ("analysis", "realModel"),
    ("analysis", "visits"),
    ("analysis", "candidateCount"),
    ("analysis", "ownershipSource"),
    ("analysis", "positionIdentity", "currentPositionKey"),
    ("analysis", "positionIdentity", "sameVisibleStones"),
    ("analysis", "positionIdentity", "sameVisibleHistoryAKey"),
    ("analysis", "positionIdentity", "sameVisibleHistoryBKey"),
    ("analysis", "positionIdentity", "sameVisibleHistoryKeysDistinct"),
    ("lifecycle", "backgroundedSeconds"),
    ("lifecycle", "autosaveWritten"),
    ("lifecycle", "tombstoneWritten"),
    ("lifecycle", "restoredLatestState"),
    ("features", "cameraRecognitionTested"),
    ("features", "iCloudSyncTested"),
    ("features", "modelImportTested"),
  ):
    _validate_matching_value(payload, evidence, field_path)

  runtime = _str(_dict(evidence.get("app"), "app").get("analysisRuntime"), "app.analysisRuntime")
  if runtime == "httpBridge":
    for field_path in (
      ("backend", "url"),
      ("backend", "status", "engine"),
      ("backend", "status", "engineId"),
      ("backend", "status", "state"),
      ("backend", "status", "running"),
      ("backend", "status", "paused"),
    ):
      _validate_matching_value(payload, evidence, field_path)
  else:
    for field_path in (
      ("analysis", "nativeEngine", "modelDigestVerified"),
      ("analysis", "nativeEngine", "engineId"),
      ("analysis", "nativeEngine", "modelResourceName"),
      ("analysis", "nativeEngine", "modelByteCount"),
      ("analysis", "nativeEngine", "modelSHA256HexDigest"),
      ("analysis", "nativeEngine", "coreMLPackages"),
      ("analysis", "nativeEngine", "tombstoneExported"),
      ("analysis", "nativeEngine", "tombstoneFilename"),
      ("analysis", "nativeEngine", "tombstoneExportedAt"),
      ("analysis", "nativeEngine", "tombstoneRestored"),
      ("analysis", "nativeEngine", "tombstoneRestoredAt"),
    ):
      _validate_matching_value(payload, evidence, field_path)
    if "backend" in payload:
      _fail("device-log artifact for nativeInProcess evidence must omit backend")


def _validate_artifact_content(
  kind: str,
  path: pathlib.Path,
  device_idiom: str,
  evidence: dict[str, Any],
  recorded_at: datetime.datetime,
  run_id: str,
) -> None:
  if kind == "screenshot":
    _validate_screenshot_dimensions(device_idiom, path)
  elif kind == "performance":
    _validate_performance_artifact(path, _measurements_object(evidence), recorded_at, run_id)
  elif kind == "device-log":
    _validate_device_log_artifact(path, evidence, recorded_at, run_id)


def _validate_artifacts(
  evidence_path: pathlib.Path,
  evidence: dict[str, Any],
  recorded_at: datetime.datetime,
  run_id: str,
) -> None:
  artifacts = _list(evidence.get("artifacts"), "artifacts")
  device = _dict(evidence.get("device"), "device")
  device_idiom = _str(device.get("idiom"), "device.idiom")
  seen_kinds: set[str] = set()
  seen_paths: dict[str, str] = {}
  for index, raw_artifact in enumerate(artifacts):
    artifact = _dict(raw_artifact, f"artifacts[{index}]")
    kind = _str(artifact.get("kind"), f"artifacts[{index}].kind")
    if kind not in REQUIRED_ARTIFACT_KINDS:
      _fail(f"artifact kind is unsupported: {kind}")
    if kind in seen_kinds:
      _fail(f"artifact kind is duplicated: {kind}")
    raw_path = _str(artifact.get("path"), f"artifacts[{index}].path")
    portable_path = _artifact_portable_path(raw_path, f"artifacts[{index}].path")
    _reject_reserved_artifact_path(evidence_path, portable_path)
    normalized_path = portable_path.as_posix()
    if normalized_path in seen_paths:
      _fail(
        f"artifact path is duplicated: {normalized_path} "
        f"for kinds {seen_paths[normalized_path]} and {kind}"
      )
    seen_paths[normalized_path] = kind
    path = _resolve_regular_artifact(evidence_path, portable_path)
    actual_byte_count = path.stat().st_size
    if actual_byte_count <= 0:
      _fail(f"artifact is empty: {path}")
    _validate_artifact_byte_budget(kind, path, actual_byte_count)
    _validate_artifact_fingerprint(artifact, kind, path)
    _validate_artifact_content(kind, path, device_idiom, evidence, recorded_at, run_id)
    seen_kinds.add(kind)

  missing = sorted(REQUIRED_ARTIFACT_KINDS - seen_kinds)
  if missing:
    _fail(f"artifacts are missing required kinds: {', '.join(missing)}")


def _validate_device(evidence: dict[str, Any]) -> None:
  device = _dict(evidence.get("device"), "device")
  idiom = _str(device.get("idiom"), "device.idiom")
  if idiom not in VALID_DEVICE_IDIOMS:
    _fail("device.idiom must be iPad or iPhone")
  model = _str(device.get("model"), "device.model")
  if "simulator" in model.lower():
    _fail("device.model must be a physical device model, not a Simulator")
  _str(device.get("osVersion"), "device.osVersion")
  if _bool(device.get("simulator"), "device.simulator") is not False:
    _fail("device.simulator must be false for real-device evidence")


def _validate_app(evidence: dict[str, Any], expected_runtime: str | None) -> str:
  app = _dict(evidence.get("app"), "app")
  _str(app.get("bundleIdentifier"), "app.bundleIdentifier")
  _str(app.get("version"), "app.version")
  _str(app.get("build"), "app.build")
  executable_digest = _str(app.get("executableSHA256HexDigest"), "app.executableSHA256HexDigest")
  if not SHA256_HEX_PATTERN.fullmatch(executable_digest):
    _fail("app.executableSHA256HexDigest must be a lowercase SHA-256 hex digest")
  runtime = _str(app.get("analysisRuntime"), "app.analysisRuntime")
  if runtime not in VALID_RUNTIMES:
    _fail("app.analysisRuntime must be httpBridge or nativeInProcess")
  if expected_runtime and runtime != expected_runtime:
    _fail(f"app.analysisRuntime={runtime} does not match expected runtime {expected_runtime}")
  return runtime


def _validate_backend(
  evidence: dict[str, Any],
  runtime: str,
  expected_backend_origin: str | None,
  expected_backend_label: str,
) -> tuple[str, str] | None:
  if runtime == "httpBridge":
    backend = _dict(evidence.get("backend", {}), "backend")
    raw_url = _str(backend.get("url"), "backend.url")
    try:
      origin = validate_physical_device_backend_url(raw_url)
    except DeviceRunPreflightError as exc:
      _fail(str(exc))
    if expected_backend_origin:
      expected = validate_physical_device_backend_url(expected_backend_origin)
      if origin != expected:
        _fail(f"backend.url={origin} does not match {expected_backend_label}={expected}")
    status = _dict(backend.get("status"), "backend.status")
    for key in ("engine", "engineId", "state", "running", "paused"):
      if key not in status:
        _fail(f"backend.status is missing {key!r}")
    engine = _str(status.get("engine"), "backend.status.engine")
    engine_id = _str(status.get("engineId"), "backend.status.engineId")
    if status["state"] not in {"ready", "running", "paused"}:
      _fail(f"backend.status.state has unexpected value {status['state']!r}")
    _bool(status.get("running"), "backend.status.running")
    _bool(status.get("paused"), "backend.status.paused")
    return engine, engine_id
  else:
    if expected_backend_origin:
      _fail("nativeInProcess real-device evidence must not set QIXI_DEVICE_BACKEND_URL or QIXI_BACKEND_URL")
    if "backend" in evidence:
      _fail("nativeInProcess real-device evidence must omit backend entirely")
    return None


def _validate_native_audit_time(value: Any, path: str, recorded_at: datetime.datetime) -> None:
  audit_time = _datetime(value, path)
  if audit_time > recorded_at:
    _fail(f"{path} must not be newer than recordedAt")
  if (recorded_at - audit_time).total_seconds() > NATIVE_TOMBSTONE_AUDIT_MAX_AGE_SECONDS:
    _fail(f"{path} is too old for nativeInProcess release evidence")


def _validate_native_engine(native: dict[str, Any], engine_id: str, recorded_at: datetime.datetime) -> None:
  for key in ("modelDigestVerified", "tombstoneExported", "tombstoneRestored"):
    if _bool(native.get(key), f"analysis.nativeEngine.{key}") is not True:
      _fail(f"analysis.nativeEngine.{key} must be true")

  native_engine_id = _str(native.get("engineId"), "analysis.nativeEngine.engineId")
  if native_engine_id != engine_id:
    _fail("analysis.nativeEngine.engineId must match analysis.engineId")

  manifest = NATIVE_MODEL_MANIFEST[engine_id]
  resource_name = _str(native.get("modelResourceName"), "analysis.nativeEngine.modelResourceName")
  if resource_name != manifest["resourceName"]:
    _fail("analysis.nativeEngine.modelResourceName must match the engine manifest")
  byte_count = _int(native.get("modelByteCount"), "analysis.nativeEngine.modelByteCount")
  if byte_count != manifest["byteCount"]:
    _fail("analysis.nativeEngine.modelByteCount must match the engine manifest")
  digest = _str(native.get("modelSHA256HexDigest"), "analysis.nativeEngine.modelSHA256HexDigest")
  if digest != manifest["sha256HexDigest"]:
    _fail("analysis.nativeEngine.modelSHA256HexDigest must match the engine manifest")
  packages = _list(native.get("coreMLPackages"), "analysis.nativeEngine.coreMLPackages")
  expected_packages = _list(manifest.get("coreMLPackages"), "native model manifest coreMLPackages")
  if len(packages) != len(expected_packages):
    _fail("analysis.nativeEngine.coreMLPackages must match the engine manifest")
  for index, (package, expected) in enumerate(zip(packages, expected_packages)):
    package = _dict(package, f"analysis.nativeEngine.coreMLPackages[{index}]")
    expected = _dict(expected, f"native model manifest coreMLPackages[{index}]")
    if _str(package.get("resourceName"), f"analysis.nativeEngine.coreMLPackages[{index}].resourceName") != expected["resourceName"]:
      _fail("analysis.nativeEngine.coreMLPackages must match the engine manifest")
    if _str(package.get("variantID"), f"analysis.nativeEngine.coreMLPackages[{index}].variantID") != expected["variantID"]:
      _fail("analysis.nativeEngine.coreMLPackages must match the engine manifest")
    if _int(package.get("fileCount"), f"analysis.nativeEngine.coreMLPackages[{index}].fileCount") != expected["fileCount"]:
      _fail("analysis.nativeEngine.coreMLPackages must match the engine manifest")
    if _int(package.get("totalByteCount"), f"analysis.nativeEngine.coreMLPackages[{index}].totalByteCount") != expected["totalByteCount"]:
      _fail("analysis.nativeEngine.coreMLPackages must match the engine manifest")
    if _str(package.get("sha256TreeDigest"), f"analysis.nativeEngine.coreMLPackages[{index}].sha256TreeDigest") != expected["sha256TreeDigest"]:
      _fail("analysis.nativeEngine.coreMLPackages must match the engine manifest")

  tombstone_filename = _str(native.get("tombstoneFilename"), "analysis.nativeEngine.tombstoneFilename")
  if tombstone_filename != NATIVE_TOMBSTONE_FILENAME:
    _fail("analysis.nativeEngine.tombstoneFilename must match the native tombstone store")
  _validate_native_audit_time(
    native.get("tombstoneExportedAt"),
    "analysis.nativeEngine.tombstoneExportedAt",
    recorded_at,
  )
  _validate_native_audit_time(
    native.get("tombstoneRestoredAt"),
    "analysis.nativeEngine.tombstoneRestoredAt",
    recorded_at,
  )


def _position_identity_key(value: Any, path: str) -> str:
  key = _str(value, path)
  if len(key) > 4096:
    _fail(f"{path} must be bounded to 4096 characters")
  return key


def _validate_position_identity(analysis: dict[str, Any]) -> None:
  identity = _dict(analysis.get("positionIdentity"), "analysis.positionIdentity")
  current_key = _position_identity_key(
    identity.get("currentPositionKey"),
    "analysis.positionIdentity.currentPositionKey",
  )
  key_a = _position_identity_key(
    identity.get("sameVisibleHistoryAKey"),
    "analysis.positionIdentity.sameVisibleHistoryAKey",
  )
  key_b = _position_identity_key(
    identity.get("sameVisibleHistoryBKey"),
    "analysis.positionIdentity.sameVisibleHistoryBKey",
  )
  if not current_key:
    _fail("analysis.positionIdentity.currentPositionKey must not be empty")
  if _bool(identity.get("sameVisibleStones"), "analysis.positionIdentity.sameVisibleStones") is not True:
    _fail("analysis.positionIdentity.sameVisibleStones must be true")
  if _bool(identity.get("sameVisibleHistoryKeysDistinct"), "analysis.positionIdentity.sameVisibleHistoryKeysDistinct") is not True:
    _fail("analysis.positionIdentity.sameVisibleHistoryKeysDistinct must be true")
  if key_a == key_b:
    _fail("analysis.positionIdentity same-visible history keys must be distinct")


def _validate_analysis(evidence: dict[str, Any], runtime: str, recorded_at: datetime.datetime) -> str:
  analysis = _dict(evidence.get("analysis"), "analysis")
  engine_id = _str(analysis.get("engineId"), "analysis.engineId")
  if engine_id not in VALID_ENGINES:
    _fail("analysis.engineId must be one of b6, b18nbt, b28nbt")
  if _bool(analysis.get("realModel"), "analysis.realModel") is not True:
    _fail("analysis.realModel must be true")
  _bounded_positive_int(analysis.get("visits"), "analysis.visits", 10_000_000)
  _bounded_positive_int(analysis.get("candidateCount"), "analysis.candidateCount", 361)
  ownership_source = _str(analysis.get("ownershipSource"), "analysis.ownershipSource")
  if ownership_source != "mcts":
    _fail("analysis.ownershipSource must be mcts")
  _validate_position_identity(analysis)

  if runtime == "nativeInProcess":
    native = _dict(analysis.get("nativeEngine"), "analysis.nativeEngine")
    _validate_native_engine(native, engine_id, recorded_at)
  else:
    if "nativeEngine" in analysis:
      _fail("httpBridge real-device evidence must not include analysis.nativeEngine")
  return engine_id


def _validate_measurements(evidence: dict[str, Any], max_launch_ms: float, max_memory_mb: float) -> None:
  measurements = _dict(evidence.get("measurements"), "measurements")
  launch = _dict(measurements.get("launch"), "measurements.launch")
  cold_launch = _bounded_positive(launch.get("coldLaunchMs"), "measurements.launch.coldLaunchMs", max_launch_ms)
  visual_ready = _bounded_positive(launch.get("visualReadyMs"), "measurements.launch.visualReadyMs", max_launch_ms)
  if visual_ready < cold_launch:
    _fail("measurements.launch.visualReadyMs must be >= coldLaunchMs")

  memory = _dict(measurements.get("memory"), "measurements.memory")
  peak_rss = _bounded_positive(memory.get("peakRSSMB"), "measurements.memory.peakRSSMB", max_memory_mb)
  post_analysis_rss = _bounded_positive(
    memory.get("postAnalysisRSSMB"),
    "measurements.memory.postAnalysisRSSMB",
    max_memory_mb,
  )
  if post_analysis_rss > peak_rss:
    _fail("measurements.memory.postAnalysisRSSMB must be <= peakRSSMB")

  frame = _dict(measurements.get("framePacing"), "measurements.framePacing")
  target_hz = _number(frame.get("targetRefreshHz"), "measurements.framePacing.targetRefreshHz")
  observed_hz = _number(frame.get("observedRefreshHz"), "measurements.framePacing.observedRefreshHz")
  if target_hz not in {60, 120}:
    _fail("measurements.framePacing.targetRefreshHz must be 60 or 120")
  minimum_hz = 110 if target_hz == 120 else 55
  if observed_hz < minimum_hz:
    _fail(f"measurements.framePacing.observedRefreshHz={observed_hz:g} is below required {minimum_hz:g}")
  dropped = _number(frame.get("droppedFramePercent"), "measurements.framePacing.droppedFramePercent")
  if dropped < 0 or dropped > 5:
    _fail("measurements.framePacing.droppedFramePercent must be between 0 and 5")


def _validate_native_memory_budget(evidence: dict[str, Any], runtime: str, engine_id: str) -> None:
  if runtime != "nativeInProcess":
    return
  manifest = _dict(NATIVE_MODEL_MANIFEST.get(engine_id), f"native model manifest {engine_id}")
  maximum_memory_mb = _number(manifest.get("maximumMemoryMB"), f"native model manifest {engine_id}.maximumMemoryMB")
  memory = _dict(_dict(evidence.get("measurements"), "measurements").get("memory"), "measurements.memory")
  peak_rss = _number(memory.get("peakRSSMB"), "measurements.memory.peakRSSMB")
  post_analysis_rss = _number(memory.get("postAnalysisRSSMB"), "measurements.memory.postAnalysisRSSMB")
  if peak_rss > maximum_memory_mb or post_analysis_rss > maximum_memory_mb:
    _fail(
      f"nativeInProcess measurements.memory must not exceed {engine_id} "
      f"manifest maximumMemoryMB={maximum_memory_mb:g}"
    )


def _validate_lifecycle_and_features(evidence: dict[str, Any]) -> None:
  lifecycle = _dict(evidence.get("lifecycle"), "lifecycle")
  _bounded_positive(lifecycle.get("backgroundedSeconds"), "lifecycle.backgroundedSeconds", 86_400)
  for key in ("autosaveWritten", "tombstoneWritten", "restoredLatestState"):
    if _bool(lifecycle.get(key), f"lifecycle.{key}") is not True:
      _fail(f"lifecycle.{key} must be true")

  features = _dict(evidence.get("features"), "features")
  for key in ("cameraRecognitionTested", "iCloudSyncTested", "modelImportTested"):
    if _bool(features.get(key), f"features.{key}") is not True:
      _fail(f"features.{key} must be true")


def validate_evidence(
  evidence_path: pathlib.Path,
  *,
  expected_backend_origin: str | None = None,
  expected_backend_label: str = "configured backend URL",
  expected_runtime: str | None = None,
  max_launch_ms: float = 20_000,
  max_memory_mb: float = 1_800,
  max_evidence_age_seconds: float = REAL_DEVICE_EVIDENCE_MAX_AGE_SECONDS,
  now: datetime.datetime | None = None,
) -> dict[str, str]:
  _validate_evidence_input_file(evidence_path)
  evidence = _load_json_without_duplicate_keys(evidence_path, "real-device evidence JSON")
  evidence = _dict(evidence, "evidence")

  if evidence.get("schemaVersion") != REAL_DEVICE_EVIDENCE_SCHEMA_VERSION:
    _fail(f"schemaVersion must be {REAL_DEVICE_EVIDENCE_SCHEMA_VERSION}")
  if evidence.get("kind") != REAL_DEVICE_EVIDENCE_KIND:
    _fail(f"kind must be {REAL_DEVICE_EVIDENCE_KIND}")
  run_id = _run_id(evidence.get("runId"), "runId")
  recorded_at = _datetime(evidence.get("recordedAt"), "recordedAt")
  _validate_recorded_at_freshness(
    recorded_at,
    now=now or datetime.datetime.now(datetime.timezone.utc),
    max_age_seconds=max_evidence_age_seconds,
  )

  _validate_device(evidence)
  runtime = _validate_app(evidence, expected_runtime)
  backend_identity = _validate_backend(
    evidence,
    runtime,
    expected_backend_origin,
    expected_backend_label,
  )
  analysis_engine_id = _validate_analysis(evidence, runtime, recorded_at)
  if runtime == "httpBridge" and backend_identity is not None:
    backend_engine, backend_engine_id = backend_identity
    expected_backend_engine = f"katago-metal-mux:{analysis_engine_id}"
    if backend_engine != expected_backend_engine:
      _fail(
        f"backend.status.engine={backend_engine} must match {expected_backend_engine}"
      )
  if runtime == "httpBridge" and backend_identity is not None and backend_engine_id != analysis_engine_id:
    _fail(
      f"backend.status.engineId={backend_engine_id} must match analysis.engineId={analysis_engine_id}"
    )
  _validate_measurements(evidence, max_launch_ms, max_memory_mb)
  _validate_native_memory_budget(evidence, runtime, analysis_engine_id)
  _validate_lifecycle_and_features(evidence)
  _validate_artifacts(evidence_path, evidence, recorded_at, run_id)

  device = _dict(evidence["device"], "device")
  analysis = _dict(evidence["analysis"], "analysis")
  return {
    "device": f"{device['idiom']} {device['model']}",
    "runtime": runtime,
    "engineId": str(analysis["engineId"]),
    "runId": run_id,
  }


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description="Validate recorded Qixi real-device evidence.")
  parser.add_argument("--evidence", default=os.environ.get("QIXI_REAL_DEVICE_EVIDENCE", ""))
  args = parser.parse_args(argv)

  if not args.evidence:
    print(
      "Real-device evidence preflight failed: QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json is required",
      file=sys.stderr,
    )
    return 1

  expected_device_backend_origin = os.environ.get("QIXI_DEVICE_BACKEND_URL", "").strip() or None
  expected_legacy_backend_origin = os.environ.get("QIXI_BACKEND_URL", "").strip() or None
  if (
    expected_device_backend_origin
    and expected_legacy_backend_origin
    and expected_device_backend_origin != expected_legacy_backend_origin
  ):
    print(
      "Real-device evidence preflight failed: QIXI_DEVICE_BACKEND_URL and QIXI_BACKEND_URL "
      "must not both be set to different values",
      file=sys.stderr,
    )
    return 1
  expected_backend_origin = expected_device_backend_origin or expected_legacy_backend_origin
  if expected_device_backend_origin and expected_legacy_backend_origin:
    expected_backend_label = "QIXI_DEVICE_BACKEND_URL/QIXI_BACKEND_URL"
  elif expected_device_backend_origin:
    expected_backend_label = "QIXI_DEVICE_BACKEND_URL"
  elif expected_legacy_backend_origin:
    expected_backend_label = "QIXI_BACKEND_URL"
  else:
    expected_backend_label = "configured backend URL"
  expected_runtime = os.environ.get("QIXI_REAL_DEVICE_EXPECT_RUNTIME", "").strip() or None
  max_launch_ms = float(os.environ.get("QIXI_REAL_DEVICE_MAX_LAUNCH_MS", "20000"))
  max_memory_mb = float(os.environ.get("QIXI_REAL_DEVICE_MAX_MEMORY_MB", "1800"))
  max_evidence_age_seconds = float(os.environ.get(
    "QIXI_REAL_DEVICE_MAX_EVIDENCE_AGE_SECONDS",
    str(REAL_DEVICE_EVIDENCE_MAX_AGE_SECONDS),
  ))

  try:
    summary = validate_evidence(
      pathlib.Path(args.evidence).expanduser(),
      expected_backend_origin=expected_backend_origin,
      expected_backend_label=expected_backend_label,
      expected_runtime=expected_runtime,
      max_launch_ms=max_launch_ms,
      max_memory_mb=max_memory_mb,
      max_evidence_age_seconds=max_evidence_age_seconds,
    )
  except RealDeviceEvidenceError as exc:
    print(f"Real-device evidence preflight failed: {exc}", file=sys.stderr)
    return 1

  print(
    "Real-device evidence preflight passed: "
    f"{summary['device']} runtime={summary['runtime']} engine={summary['engineId']}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
