#!/usr/bin/env python3
from __future__ import annotations

import datetime
import json
import os
import pathlib
import re
import stat as stat_module
import sys
import time
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_ARTIFACT = ROOT / "artifacts" / "screenshots" / "screenshot-environment.json"
DOCTOR_ARTIFACT_ENV = "QIXI_SCREENSHOT_DOCTOR_ARTIFACT"
MAX_ENVIRONMENT_ARTIFACT_BYTES = 128 * 1024
GENERATED_AT_MAX_FUTURE_SKEW_SECONDS = 5 * 60
ALLOWED_PLATFORM_SYMLINK_ALIASES = {
  pathlib.Path("/var"): pathlib.Path("/private/var"),
  pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
  pathlib.Path("/etc"): pathlib.Path("/private/etc"),
}
SIMULATOR_UDID_RE = re.compile(
  r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
EXPECTED_COMMANDS = {
  "fastSmoke": "qixi-ios-native/scripts/screenshot-smoke-sim.sh",
  "fullMatrix": "QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh",
  "ipadSingle": "qixi-ios-native/scripts/screenshot-sim.sh",
  "iphoneSingle": "qixi-ios-native/scripts/screenshot-iphone-sim.sh",
}


class ScreenshotEnvironmentError(RuntimeError):
  pass


def default_artifact_path() -> pathlib.Path:
  raw = os.environ.get(DOCTOR_ARTIFACT_ENV, "").strip()
  if raw:
    return pathlib.Path(raw)
  return DEFAULT_ARTIFACT


def normalized_path(path: pathlib.Path) -> pathlib.Path:
  expanded = path.expanduser()
  if expanded.is_absolute():
    return expanded
  return pathlib.Path.cwd() / expanded


def is_allowed_platform_symlink_alias(path: pathlib.Path) -> bool:
  expected_target = ALLOWED_PLATFORM_SYMLINK_ALIASES.get(path)
  if expected_target is None:
    return False
  try:
    return path.resolve(strict=True) == expected_target
  except OSError:
    return False


def reject_symlink_components(path: pathlib.Path) -> pathlib.Path:
  candidate = normalized_path(path)
  current = pathlib.Path(candidate.anchor) if candidate.anchor else pathlib.Path()
  for part in candidate.parts:
    if part == candidate.anchor or not part:
      continue
    current = current / part
    if current.is_symlink() and not is_allowed_platform_symlink_alias(current):
      raise ScreenshotEnvironmentError(
        f"screenshot environment artifact path must not contain symbolic links: {current}"
      )
  return candidate


def environment_min_mtime_epoch() -> float | None:
  raw = os.environ.get("QIXI_SCREENSHOT_ENVIRONMENT_MIN_MTIME_EPOCH")
  if raw is None or raw == "":
    return None
  try:
    return float(raw)
  except ValueError as exc:
    raise ScreenshotEnvironmentError(
      "QIXI_SCREENSHOT_ENVIRONMENT_MIN_MTIME_EPOCH must be a numeric Unix timestamp"
    ) from exc


def load_artifact(path: pathlib.Path) -> tuple[dict[str, Any], os.stat_result]:
  def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
      if key in result:
        raise ScreenshotEnvironmentError(f"screenshot environment artifact must not contain duplicate JSON key {key!r}")
      result[key] = value
    return result

  def reject_non_standard_constant(value: str) -> None:
    raise ScreenshotEnvironmentError(f"screenshot environment artifact must not contain non-standard JSON constant {value}")

  checked_path = reject_symlink_components(path)
  try:
    checked_path.lstat()
  except FileNotFoundError as exc:
    raise ScreenshotEnvironmentError(f"screenshot environment artifact is missing: {checked_path}") from exc
  if checked_path.is_symlink():
    raise ScreenshotEnvironmentError(f"screenshot environment artifact must not be a symbolic link: {checked_path}")
  if not checked_path.is_file():
    raise ScreenshotEnvironmentError(f"screenshot environment artifact must be a regular file: {checked_path}")
  artifact_stat = checked_path.stat()
  if artifact_stat.st_size <= 0:
    raise ScreenshotEnvironmentError(f"screenshot environment artifact is empty: {checked_path}")
  if artifact_stat.st_size > MAX_ENVIRONMENT_ARTIFACT_BYTES:
    raise ScreenshotEnvironmentError(
      f"screenshot environment artifact exceeds {MAX_ENVIRONMENT_ARTIFACT_BYTES} bytes before loading: {checked_path}"
    )
  min_mtime = environment_min_mtime_epoch()
  if min_mtime is not None and artifact_stat.st_mtime < min_mtime:
    raise ScreenshotEnvironmentError(
      "screenshot environment artifact is stale for this run: "
      f"mtime={artifact_stat.st_mtime:.6f} min={min_mtime:.6f}"
    )
  try:
    with checked_path.open("rb") as handle:
      opened_stat = os.fstat(handle.fileno())
      if not stat_module.S_ISREG(opened_stat.st_mode):
        raise ScreenshotEnvironmentError(f"screenshot environment artifact must be a regular file after opening: {checked_path}")
      if opened_stat.st_size != artifact_stat.st_size:
        raise ScreenshotEnvironmentError(
          f"screenshot environment artifact byte-count drift after opening: {checked_path}"
        )
      if opened_stat.st_size > MAX_ENVIRONMENT_ARTIFACT_BYTES:
        raise ScreenshotEnvironmentError(
          f"screenshot environment artifact exceeds {MAX_ENVIRONMENT_ARTIFACT_BYTES} bytes after opening: {checked_path}"
        )
      data = handle.read(MAX_ENVIRONMENT_ARTIFACT_BYTES + 1)
  except OSError as exc:
    raise ScreenshotEnvironmentError(f"screenshot environment artifact could not be read: {checked_path}: {exc}") from exc
  if len(data) > MAX_ENVIRONMENT_ARTIFACT_BYTES:
    raise ScreenshotEnvironmentError(
      f"screenshot environment artifact exceeds {MAX_ENVIRONMENT_ARTIFACT_BYTES} bytes while reading: {checked_path}"
    )
  if len(data) != artifact_stat.st_size:
    raise ScreenshotEnvironmentError(f"screenshot environment artifact byte-count drift while reading: {checked_path}")
  try:
    text = data.decode("utf-8")
  except UnicodeDecodeError as exc:
    raise ScreenshotEnvironmentError(f"screenshot environment artifact must be UTF-8: {checked_path}") from exc
  try:
    payload = json.loads(
      text,
      object_pairs_hook=reject_duplicate_keys,
      parse_constant=reject_non_standard_constant,
    )
  except ScreenshotEnvironmentError:
    raise
  except Exception as exc:
    raise ScreenshotEnvironmentError(f"screenshot environment artifact must be JSON: {exc}") from exc
  if not isinstance(payload, dict):
    raise ScreenshotEnvironmentError("screenshot environment artifact must be a JSON object")
  return payload, artifact_stat


def require_nonempty_string(value: object, field: str) -> str:
  if not isinstance(value, str) or not value.strip():
    raise ScreenshotEnvironmentError(f"{field} must be a non-empty string")
  return value


def parse_generated_at(value: object) -> datetime.datetime:
  generated_at = require_nonempty_string(value, "generatedAt")
  if not generated_at.endswith("Z"):
    raise ScreenshotEnvironmentError("generatedAt must be a UTC ISO-8601 timestamp ending in Z")
  try:
    parsed = datetime.datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
  except ValueError as exc:
    raise ScreenshotEnvironmentError(f"generatedAt must be an ISO-8601 timestamp: {generated_at}") from exc
  if parsed.tzinfo is None or parsed.utcoffset() != datetime.timedelta(0):
    raise ScreenshotEnvironmentError("generatedAt must use UTC")
  return parsed


def inspect_generated_at(value: object, min_mtime_epoch: float | None) -> None:
  generated_at = parse_generated_at(value)
  generated_at_epoch = generated_at.timestamp()
  if min_mtime_epoch is not None and generated_at_epoch < min_mtime_epoch:
    raise ScreenshotEnvironmentError(
      f"stale screenshot environment generatedAt: {generated_at.isoformat()} "
      f"min={min_mtime_epoch:.6f}"
    )
  current_epoch = time.time()
  if generated_at_epoch > current_epoch + GENERATED_AT_MAX_FUTURE_SKEW_SECONDS:
    raise ScreenshotEnvironmentError(
      "screenshot environment generatedAt is too far in the future: "
      f"{generated_at.isoformat()} now={current_epoch:.3f} "
      f"maxSkew={GENERATED_AT_MAX_FUTURE_SKEW_SECONDS}"
    )


def inspect_selected_device(kind: str, payload: object, *, boot_simulators: bool) -> None:
  if not isinstance(payload, dict):
    raise ScreenshotEnvironmentError(f"selected.{kind} must be an object")
  name = require_nonempty_string(payload.get("name"), f"selected.{kind}.name")
  if not name.startswith(kind):
    raise ScreenshotEnvironmentError(f"selected.{kind}.name must describe a {kind} simulator: {name}")
  udid = require_nonempty_string(payload.get("udid"), f"selected.{kind}.udid")
  if SIMULATOR_UDID_RE.fullmatch(udid) is None:
    raise ScreenshotEnvironmentError(f"selected.{kind}.udid is not a simulator UDID: {udid}")
  runtime = require_nonempty_string(payload.get("runtime"), f"selected.{kind}.runtime")
  if not runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
    raise ScreenshotEnvironmentError(f"selected.{kind}.runtime must be an iOS simulator runtime: {runtime}")
  state = require_nonempty_string(payload.get("state"), f"selected.{kind}.state")
  if boot_simulators and state != "Booted":
    raise ScreenshotEnvironmentError(f"selected.{kind}.state must be Booted when bootSimulators is true")


def inspect_artifact(path: pathlib.Path = DEFAULT_ARTIFACT) -> dict[str, Any]:
  payload, _artifact_stat = load_artifact(path)
  if payload.get("schemaVersion") != 1:
    raise ScreenshotEnvironmentError("screenshot environment artifact schemaVersion must be 1")
  inspect_generated_at(payload.get("generatedAt"), environment_min_mtime_epoch())
  boot_simulators = payload.get("bootSimulators")
  if not isinstance(boot_simulators, bool):
    raise ScreenshotEnvironmentError("bootSimulators must be a boolean")
  xcode_version = require_nonempty_string(payload.get("xcodebuildVersion"), "xcodebuildVersion")
  if "Xcode" not in xcode_version or "Build version" not in xcode_version:
    raise ScreenshotEnvironmentError("xcodebuildVersion must include Xcode and Build version lines")
  selected = payload.get("selected")
  if not isinstance(selected, dict):
    raise ScreenshotEnvironmentError("selected must be an object")
  inspect_selected_device("iPad", selected.get("iPad"), boot_simulators=boot_simulators)
  inspect_selected_device("iPhone", selected.get("iPhone"), boot_simulators=boot_simulators)
  commands = payload.get("commands")
  if commands != EXPECTED_COMMANDS:
    raise ScreenshotEnvironmentError("commands must match the documented screenshot entrypoints")
  limits = payload.get("limits")
  if not isinstance(limits, list) or len(limits) < 2 or any(not isinstance(limit, str) or not limit for limit in limits):
    raise ScreenshotEnvironmentError("limits must be a non-empty string list with simulator and real-device caveats")
  joined_limits = "\n".join(limits)
  for token in (
    "Simulator evidence covers SwiftUI layout",
    "Real ProMotion, Metal/GPU/ANE, camera, iCloud propagation, background kill, and native in-process KataGo still require physical-device evidence.",
  ):
    if token not in joined_limits:
      raise ScreenshotEnvironmentError(f"limits must include caveat: {token}")
  return payload


def main(argv: list[str] | None = None) -> int:
  argv = argv or sys.argv[1:]
  path = pathlib.Path(argv[0]) if argv else default_artifact_path()
  try:
    payload = inspect_artifact(path)
  except ScreenshotEnvironmentError as exc:
    print(f"Screenshot environment artifact inspection failed: {exc}", file=sys.stderr)
    return 1
  selected = payload["selected"]
  print(
    "Screenshot environment artifact inspection passed: "
    f"iPad={selected['iPad']['name']} iPhone={selected['iPhone']['name']}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
