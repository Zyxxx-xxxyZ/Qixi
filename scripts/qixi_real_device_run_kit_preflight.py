#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime
import io
import json
import math
import os
import pathlib
import re
import stat
import sys
import uuid
from typing import Any


RUN_KIT_SCHEMA_VERSION = 1
RUN_KIT_KIND = "qixi-real-device-evidence-run-kit"
VALID_ENGINES = {"b6", "b18nbt", "b28nbt"}
VALID_PERFORMANCE_SOURCES = {"instruments", "xctrace", "metricKit"}
BACKEND_ENV_KEYS = ("QIXI_DEVICE_BACKEND_URL", "QIXI_BACKEND_URL")
STAGED_ARTIFACT_MAX_AGE_SECONDS = 24 * 60 * 60
MAX_JSON_BYTES = 1 * 1024 * 1024
MAX_TEXT_BYTES = 256 * 1024
SCREENSHOT_ARTIFACT_MAX_BYTES = 64 * 1024 * 1024
PNG_HEADER_BYTES = 33
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SCREENSHOT_MAX_PIXELS = 16 * 1024 * 1024
SCREENSHOT_MIN_VISUAL_VARIANCE = 12.0
SCREENSHOT_MIN_DARK_PIXEL_RATIO = 1 / 1000
SCREENSHOT_MIN_DARK_PIXELS = 800
RESERVED_FINAL_FILES = (
  "real-device-evidence.qixi-release.json",
  "real-device-evidence.export.json",
  "real-device-log.json",
)
REQUIRED_FINAL_ARTIFACTS = {
  "screenshot": "real-device-main.png",
  "performance": "real-device-performance.json",
  "device-log": "real-device-log.json",
}
REQUIRED_FINAL_ARTIFACT_PRODUCERS = {
  "screenshot": "real physical-device landscape screenshot",
  "performance": "Instruments, xctrace, or MetricKit measurement JSON",
  "device-log": "Qixi app auto-written structured device-log JSON matching the evidence fields",
}
REQUIRED_ENV = {
  "QIXI_ANALYSIS_RUNTIME": "nativeInProcess",
  "QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH": "1",
  "QIXI_REAL_DEVICE_EXPECT_RUNTIME": "nativeInProcess",
  "QIXI_REAL_DEVICE_EVIDENCE_OUTPUT": "real-device-evidence.qixi-release.json",
  "QIXI_REAL_DEVICE_SCREENSHOT_ARTIFACT": "real-device-main.png",
  "QIXI_REAL_DEVICE_PERFORMANCE_ARTIFACT": "real-device-performance.json",
  "QIXI_REAL_DEVICE_DEVICE_LOG_ARTIFACT": "real-device-log.json",
  "QIXI_REAL_DEVICE_TARGET_REFRESH_HZ": "120",
  "QIXI_REAL_DEVICE_SIMULATOR": "0",
  "QIXI_REAL_DEVICE_AUTOSAVE_WRITTEN": "1",
  "QIXI_REAL_DEVICE_TOMBSTONE_WRITTEN": "1",
  "QIXI_REAL_DEVICE_RESTORED_LATEST_STATE": "1",
  "QIXI_REAL_DEVICE_CAMERA_RECOGNITION_TESTED": "1",
  "QIXI_REAL_DEVICE_ICLOUD_SYNC_TESTED": "1",
  "QIXI_REAL_DEVICE_MODEL_IMPORT_TESTED": "1",
}
NUMERIC_ENV = {
  "QIXI_REAL_DEVICE_COLD_LAUNCH_MS": (1.0, None),
  "QIXI_REAL_DEVICE_VISUAL_READY_MS": (1.0, None),
  "QIXI_REAL_DEVICE_PEAK_RSS_MB": (1.0, None),
  "QIXI_REAL_DEVICE_POST_ANALYSIS_RSS_MB": (1.0, None),
  "QIXI_REAL_DEVICE_OBSERVED_REFRESH_HZ": (110.0, None),
  "QIXI_REAL_DEVICE_DROPPED_FRAME_PERCENT": (0.0, 5.0),
  "QIXI_REAL_DEVICE_BACKGROUNDED_SECONDS": (0.0, None),
}
ALLOWED_PLATFORM_SYMLINK_ALIASES = {
  pathlib.Path("/var"): pathlib.Path("/private/var"),
  pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
  pathlib.Path("/etc"): pathlib.Path("/private/etc"),
}


class RealDeviceRunKitPreflightError(RuntimeError):
  pass


def fail(message: str) -> None:
  raise RealDeviceRunKitPreflightError(message)


def normalized_path(path: pathlib.Path) -> pathlib.Path:
  expanded = path.expanduser()
  if expanded.is_absolute():
    return expanded
  return pathlib.Path.cwd() / expanded


def is_allowed_platform_symlink_alias(path: pathlib.Path) -> bool:
  expected = ALLOWED_PLATFORM_SYMLINK_ALIASES.get(path)
  if expected is None:
    return False
  try:
    return path.resolve(strict=True) == expected
  except OSError:
    return False


def reject_symlink_components(path: pathlib.Path, label: str) -> pathlib.Path:
  candidate = normalized_path(path)
  current = pathlib.Path(candidate.anchor) if candidate.anchor else pathlib.Path()
  for part in candidate.parts:
    if part == candidate.anchor or not part:
      continue
    current = current / part
    if current.is_symlink() and not is_allowed_platform_symlink_alias(current):
      fail(f"{label} must not contain symbolic links: {current}")
  return candidate


def ensure_inside(base: pathlib.Path, child: pathlib.Path, label: str) -> pathlib.Path:
  checked = reject_symlink_components(child, label)
  try:
    checked.relative_to(base)
  except ValueError:
    fail(f"{label} must stay inside the run-kit directory: {checked}")
  return checked


def regular_file(path: pathlib.Path, label: str, max_bytes: int) -> pathlib.Path:
  checked = reject_symlink_components(path, label)
  if not checked.exists():
    fail(f"{label} does not exist: {checked}")
  try:
    file_stat = checked.stat()
  except OSError as exc:
    fail(f"{label} could not be statted: {checked}: {exc}")
  if not stat.S_ISREG(file_stat.st_mode):
    fail(f"{label} must be a regular file: {checked}")
  if file_stat.st_size > max_bytes:
    fail(f"{label} exceeds bounded size {max_bytes}: {checked}")
  return checked


def bounded_bytes(path: pathlib.Path, label: str, max_bytes: int) -> bytes:
  checked = regular_file(path, label, max_bytes)
  try:
    with checked.open("rb") as handle:
      opened = os.fstat(handle.fileno())
      if not stat.S_ISREG(opened.st_mode):
        fail(f"{label} must be a regular file after opening: {checked}")
      if opened.st_size > max_bytes:
        fail(f"{label} exceeds bounded size {max_bytes} after opening: {checked}")
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    fail(f"{label} could not be read: {checked}: {exc}")
  if len(data) > max_bytes:
    fail(f"{label} exceeds bounded size {max_bytes} while reading: {checked}")
  if len(data) != opened.st_size:
    fail(
      f"{label} opened-byte-count drift while reading: "
      f"read {len(data)} bytes but opened descriptor reported {opened.st_size} bytes"
    )
  return data


def bounded_text(path: pathlib.Path, label: str, max_bytes: int = MAX_TEXT_BYTES) -> str:
  try:
    return bounded_bytes(path, label, max_bytes).decode("utf-8")
  except UnicodeDecodeError as exc:
    fail(f"{label} must be UTF-8: {path}: {exc}")


def load_json(path: pathlib.Path, label: str) -> Any:
  def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
      if key in result:
        fail(f"{label} must not contain duplicate JSON key {key!r}")
      result[key] = value
    return result

  def reject_non_standard_constant(value: str) -> None:
    fail(f"{label} must not contain non-standard JSON constant {value}")

  try:
    return json.loads(
      bounded_text(path, label, MAX_JSON_BYTES),
      object_pairs_hook=reject_duplicate_keys,
      parse_constant=reject_non_standard_constant,
    )
  except RealDeviceRunKitPreflightError:
    raise
  except Exception as exc:
    fail(f"{label} must be JSON: {path}: {exc}")


def as_object(value: Any, label: str) -> dict[str, Any]:
  if not isinstance(value, dict):
    fail(f"{label} must be an object")
  return value


def as_string(value: Any, label: str) -> str:
  if not isinstance(value, str) or not value.strip():
    fail(f"{label} must be a non-empty string")
  return value.strip()


def as_list(value: Any, label: str) -> list[Any]:
  if not isinstance(value, list):
    fail(f"{label} must be an array")
  return value


def as_bool(value: Any, label: str) -> bool:
  if not isinstance(value, bool):
    fail(f"{label} must be a boolean")
  return value


def finite_number(value: Any, label: str, *, minimum: float | None = None, maximum: float | None = None) -> float:
  if isinstance(value, bool) or not isinstance(value, (int, float)):
    fail(f"{label} must be numeric")
  number = float(value)
  if not math.isfinite(number):
    fail(f"{label} must be finite")
  if minimum is not None and number < minimum:
    fail(f"{label} must be at least {minimum:g}")
  if maximum is not None and number > maximum:
    fail(f"{label} must be at most {maximum:g}")
  return number


def canonical_uuid(raw: Any, label: str) -> str:
  value = as_string(raw, label)
  try:
    parsed = uuid.UUID(value)
  except ValueError as exc:
    fail(f"{label} must be a canonical lowercase UUID")
  if str(parsed) != value:
    fail(f"{label} must be a canonical lowercase UUID")
  return value


def parse_utc(raw: Any, label: str) -> datetime.datetime:
  value = as_string(raw, label)
  if not value.endswith("Z"):
    fail(f"{label} must be a UTC timestamp ending in Z")
  try:
    parsed = datetime.datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
  except ValueError as exc:
    fail(f"{label} must be ISO-8601: {exc}")
  return parsed.astimezone(datetime.timezone.utc)


def parse_env_file(path: pathlib.Path) -> dict[str, str]:
  text = bounded_text(path, "real-device run-kit Xcode environment template")
  if "<" in text or ">" in text:
    fail("xcode-run-env-template.txt still contains placeholder values")
  result: dict[str, str] = {}
  for line_number, raw_line in enumerate(text.splitlines(), start=1):
    line = raw_line.strip()
    if not line or line.startswith("#"):
      continue
    if line.startswith("export "):
      line = line[len("export "):].strip()
    if "=" not in line:
      fail(f"xcode-run-env-template.txt line {line_number} must be KEY=value")
    key, value = line.split("=", 1)
    key = key.strip()
    value = value.strip()
    if not re.fullmatch(r"[A-Z0-9_]+", key):
      fail(f"xcode-run-env-template.txt line {line_number} has invalid key {key!r}")
    if key in result:
      fail(f"xcode-run-env-template.txt must not define {key} more than once")
    result[key] = value
  return result


def reject_backend_environment(current_env: dict[str, str], run_env: dict[str, str]) -> None:
  inherited = [key for key in BACKEND_ENV_KEYS if current_env.get(key, "").strip()]
  if inherited:
    fail(f"nativeInProcess run-kit preflight must not inherit backend environment: {', '.join(inherited)}")
  configured = [key for key in BACKEND_ENV_KEYS if run_env.get(key, "").strip()]
  if configured:
    fail(f"xcode-run-env-template.txt must not configure backend transport: {', '.join(configured)}")


def relative_artifact_path(raw: str, base: pathlib.Path, label: str) -> pathlib.Path:
  if raw.startswith("/") or raw.startswith("~") or "\\" in raw:
    fail(f"{label} must be a portable relative path")
  parts = raw.split("/")
  if not parts or any(part in {"", ".", ".."} for part in parts):
    fail(f"{label} must not contain empty, current-directory, or parent-directory segments")
  return ensure_inside(base, base.joinpath(*parts), label)


def validate_manifest(manifest: dict[str, Any]) -> tuple[str, str, dict[str, str]]:
  if manifest.get("schemaVersion") != RUN_KIT_SCHEMA_VERSION:
    fail("artifact-requirements.json schemaVersion must be 1")
  if manifest.get("kind") != RUN_KIT_KIND:
    fail("artifact-requirements.json kind must be qixi-real-device-evidence-run-kit")
  if manifest.get("runtime") != "nativeInProcess":
    fail("artifact-requirements.json runtime must be nativeInProcess")
  run_id = canonical_uuid(manifest.get("runId"), "artifact-requirements.json runId")
  recorded_at = as_string(manifest.get("recordedAt"), "artifact-requirements.json recordedAt")
  parse_utc(recorded_at, "artifact-requirements.json recordedAt")
  if manifest.get("finalEvidence") != "real-device-evidence.qixi-release.json":
    fail("artifact-requirements.json finalEvidence must be real-device-evidence.qixi-release.json")
  forbidden = as_list(manifest.get("forbiddenEnvironment"), "artifact-requirements.json forbiddenEnvironment")
  if forbidden != list(BACKEND_ENV_KEYS):
    fail("artifact-requirements.json forbiddenEnvironment must list backend URL keys")
  artifact_entries = as_list(manifest.get("requiredArtifacts"), "artifact-requirements.json requiredArtifacts")
  artifacts: dict[str, str] = {}
  paths: dict[str, str] = {}
  for entry in artifact_entries:
    artifact = as_object(entry, "requiredArtifacts entry")
    kind = as_string(artifact.get("kind"), "requiredArtifacts.kind")
    if kind not in REQUIRED_FINAL_ARTIFACTS:
      fail(f"artifact-requirements.json requiredArtifacts contains unsupported artifact kind: {kind}")
    if kind in artifacts:
      fail(f"artifact-requirements.json requiredArtifacts must not duplicate artifact kind: {kind}")
    path = as_string(artifact.get("path"), f"requiredArtifacts.{kind}.path")
    if path in paths:
      fail(
        "artifact-requirements.json requiredArtifacts must not duplicate artifact path: "
        f"{path} for {paths[path]} and {kind}"
      )
    producer = as_string(artifact.get("producer"), f"requiredArtifacts.{kind}.producer")
    if producer != REQUIRED_FINAL_ARTIFACT_PRODUCERS[kind]:
      fail(f"artifact-requirements.json requiredArtifacts.{kind}.producer must be {REQUIRED_FINAL_ARTIFACT_PRODUCERS[kind]}")
    must_be_template = as_bool(artifact.get("mustBeTemplate"), f"requiredArtifacts.{kind}.mustBeTemplate")
    if must_be_template is not False:
      fail(f"artifact-requirements.json requiredArtifacts.{kind}.mustBeTemplate must be false")
    paths[path] = kind
    artifacts[kind] = path
  if len(artifact_entries) != len(REQUIRED_FINAL_ARTIFACTS):
    fail("artifact-requirements.json requiredArtifacts must contain exactly screenshot, performance, and device-log")
  if artifacts != REQUIRED_FINAL_ARTIFACTS:
    fail("artifact-requirements.json must require screenshot, performance, and device-log artifact filenames")
  return run_id, recorded_at, artifacts


def validate_environment(run_env: dict[str, str], run_id: str, recorded_at: str) -> str:
  for key, expected in REQUIRED_ENV.items():
    if run_env.get(key) != expected:
      fail(f"xcode-run-env-template.txt must set {key}={expected}")
  if run_env.get("QIXI_REAL_DEVICE_RUN_ID") != run_id:
    fail("xcode-run-env-template.txt runId must match artifact-requirements.json")
  if run_env.get("QIXI_REAL_DEVICE_RECORDED_AT") != recorded_at:
    fail("xcode-run-env-template.txt recordedAt must match artifact-requirements.json")
  engine = run_env.get("QIXI_AUTOMATION_SELECT_ENGINE", "")
  if engine not in VALID_ENGINES:
    fail("QIXI_AUTOMATION_SELECT_ENGINE must be b6, b18nbt, or b28nbt")
  for key, (minimum, maximum) in NUMERIC_ENV.items():
    raw = run_env.get(key)
    if raw is None:
      fail(f"xcode-run-env-template.txt must set {key}")
    try:
      number = float(raw)
    except ValueError:
      fail(f"xcode-run-env-template.txt {key} must be numeric")
    finite_number(number, key, minimum=minimum, maximum=maximum)
  return engine


def validate_png(path: pathlib.Path, label: str, device_idiom: str) -> None:
  image_data = bounded_bytes(path, label, SCREENSHOT_ARTIFACT_MAX_BYTES)
  header = image_data[:PNG_HEADER_BYTES]
  if len(header) < PNG_HEADER_BYTES or not header.startswith(PNG_SIGNATURE):
    fail(f"{label} must be a PNG file")
  if header[12:16] != b"IHDR":
    fail(f"{label} must contain a PNG IHDR header")
  width = int.from_bytes(header[16:20], "big")
  height = int.from_bytes(header[20:24], "big")
  if width <= 0 or height <= 0:
    fail(f"{label} has invalid PNG dimensions")
  if width * height > SCREENSHOT_MAX_PIXELS:
    fail(f"{label} is too large for bounded visual inspection: {width}x{height}")
  if width <= height:
    fail(f"{label} must be a landscape screenshot")
  minimum = (1000, 700) if device_idiom == "iPad" else (800, 350)
  if width < minimum[0] or height < minimum[1]:
    fail(f"{label} dimensions are too small for {device_idiom}: {width}x{height}")
  validate_png_visual_content(image_data, path, label, width, height)


def validate_png_visual_content(image_data: bytes, path: pathlib.Path, label: str, width: int, height: int) -> None:
  try:
    from PIL import Image, ImageStat
  except Exception as exc:
    fail(f"{label} visual inspection requires Pillow: {exc}")
  try:
    with Image.open(io.BytesIO(image_data)) as raw_image:
      image = raw_image.convert("RGB")
  except Exception as exc:
    fail(f"{label} must be a decodable PNG image: {path}: {exc}")
  if image.size != (width, height):
    fail(f"{label} decoded dimensions do not match PNG IHDR: {path}")
  image_stat = ImageStat.Stat(image)
  variance = sum(image_stat.stddev)
  if variance < SCREENSHOT_MIN_VISUAL_VARIANCE:
    fail(f"{label} looks blank or nearly flat: variance={variance:.3f}")
  pixels = image.get_flattened_data() if hasattr(image, "get_flattened_data") else image.getdata()
  dark_pixels = sum(1 for red, green, blue in pixels if max(red, green, blue) < 72)
  required_dark_pixels = max(SCREENSHOT_MIN_DARK_PIXELS, int(width * height * SCREENSHOT_MIN_DARK_PIXEL_RATIO))
  if dark_pixels < required_dark_pixels:
    fail(
      f"{label} lacks visible board/grid detail: "
      f"darkPixels={dark_pixels}, required={required_dark_pixels}"
    )


def validate_performance_artifact(path: pathlib.Path, run_env: dict[str, str], run_id: str, recorded_at: str) -> None:
  payload = as_object(load_json(path, "real-device performance artifact"), "real-device performance artifact")
  if payload.get("templateOnly") is True:
    fail("real-device-performance.json must not be the template JSON")
  if payload.get("schemaVersion") != 1:
    fail("real-device performance artifact schemaVersion must be 1")
  if payload.get("kind") != "qixi-real-device-performance":
    fail("real-device performance artifact kind must be qixi-real-device-performance")
  if payload.get("source") not in VALID_PERFORMANCE_SOURCES:
    fail("real-device performance artifact source must be instruments, xctrace, or metricKit")
  if payload.get("runId") != run_id:
    fail("real-device performance artifact runId must match the run kit")
  performance_recorded_at = parse_utc(
    payload.get("recordedAt"),
    "real-device performance artifact recordedAt",
  )
  run_kit_recorded_at = parse_utc(recorded_at, "artifact-requirements.json recordedAt")
  if performance_recorded_at > run_kit_recorded_at:
    fail("real-device performance artifact recordedAt must not be newer than the run kit")
  if (run_kit_recorded_at - performance_recorded_at).total_seconds() > STAGED_ARTIFACT_MAX_AGE_SECONDS:
    fail("real-device performance artifact recordedAt is too old for the run kit staging window")
  measurements = as_object(payload.get("measurements"), "real-device performance artifact measurements")
  launch = as_object(measurements.get("launch"), "real-device performance measurements.launch")
  memory = as_object(measurements.get("memory"), "real-device performance measurements.memory")
  frame = as_object(measurements.get("framePacing"), "real-device performance measurements.framePacing")
  checks = {
    "QIXI_REAL_DEVICE_COLD_LAUNCH_MS": launch.get("coldLaunchMs"),
    "QIXI_REAL_DEVICE_VISUAL_READY_MS": launch.get("visualReadyMs"),
    "QIXI_REAL_DEVICE_PEAK_RSS_MB": memory.get("peakRSSMB"),
    "QIXI_REAL_DEVICE_POST_ANALYSIS_RSS_MB": memory.get("postAnalysisRSSMB"),
    "QIXI_REAL_DEVICE_OBSERVED_REFRESH_HZ": frame.get("observedRefreshHz"),
    "QIXI_REAL_DEVICE_DROPPED_FRAME_PERCENT": frame.get("droppedFramePercent"),
  }
  if frame.get("targetRefreshHz") != 120:
    fail("real-device performance artifact targetRefreshHz must be 120")
  for env_key, value in checks.items():
    expected = finite_number(float(run_env[env_key]), env_key)
    actual = finite_number(value, f"real-device performance artifact {env_key}")
    if abs(expected - actual) > 1e-9:
      fail(f"real-device performance artifact {env_key} must match xcode-run-env-template.txt")


def validate_run_kit(path: pathlib.Path, current_env: dict[str, str]) -> dict[str, Any]:
  run_kit = reject_symlink_components(path, "real-device run-kit directory")
  if not run_kit.exists():
    fail(f"real-device run-kit directory does not exist: {run_kit}")
  if not run_kit.is_dir():
    fail(f"real-device run-kit path must be a directory: {run_kit}")
  manifest = as_object(load_json(run_kit / "artifact-requirements.json", "artifact-requirements.json"), "artifact-requirements.json")
  run_id, recorded_at, artifacts = validate_manifest(manifest)
  run_env = parse_env_file(run_kit / "xcode-run-env-template.txt")
  reject_backend_environment(current_env, run_env)
  engine = validate_environment(run_env, run_id, recorded_at)

  for filename in RESERVED_FINAL_FILES:
    candidate = ensure_inside(run_kit, run_kit / filename, f"reserved final artifact {filename}")
    if candidate.exists() or candidate.is_symlink():
      fail(f"{filename} must not exist before the final evidence finalization launch; the app must write it")

  screenshot = relative_artifact_path(artifacts["screenshot"], run_kit, "real-device screenshot artifact")
  performance = relative_artifact_path(artifacts["performance"], run_kit, "real-device performance artifact")
  device_log = relative_artifact_path(artifacts["device-log"], run_kit, "real-device device-log artifact")
  if device_log.exists() or device_log.is_symlink():
    fail("real-device-log.json must not exist before the final evidence finalization launch; the app must write it")
  device_idiom = run_env.get("QIXI_REAL_DEVICE_IDIOM", "iPad")
  if device_idiom not in {"iPad", "iPhone"}:
    fail("QIXI_REAL_DEVICE_IDIOM must be iPad or iPhone")
  validate_png(screenshot, "real-device screenshot artifact", device_idiom)
  validate_performance_artifact(performance, run_env, run_id, recorded_at)
  return {
    "runKit": str(run_kit),
    "runId": run_id,
    "recordedAt": recorded_at,
    "engine": engine,
    "deviceIdiom": device_idiom,
  }


def parse_args(argv: list[str]) -> argparse.Namespace:
  parser = argparse.ArgumentParser(
    description="Validate a filled Qixi nativeInProcess real-device run-kit before the final evidence export launch."
  )
  parser.add_argument("run_kit_dir", nargs="?", type=pathlib.Path, help="Run-kit directory from qixi-real-device-evidence-template.py")
  return parser.parse_args(argv)


def main(argv: list[str]) -> int:
  args = parse_args(argv)
  raw_dir = args.run_kit_dir or pathlib.Path(os.environ.get("QIXI_REAL_DEVICE_RUN_KIT_DIR", ""))
  if not str(raw_dir):
    print("Real-device run-kit preflight failed: provide RUN_KIT_DIR or QIXI_REAL_DEVICE_RUN_KIT_DIR", file=sys.stderr)
    return 2
  try:
    summary = validate_run_kit(raw_dir, os.environ)
  except RealDeviceRunKitPreflightError as exc:
    print(f"Real-device run-kit preflight failed: {exc}", file=sys.stderr)
    return 2
  print(
    "Real-device run-kit preflight passed: "
    f"engine={summary['engine']} runId={summary['runId']} dir={summary['runKit']}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main(sys.argv[1:]))
