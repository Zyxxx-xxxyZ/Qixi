#!/usr/bin/env python3
from __future__ import annotations

import json
import datetime
import math
import os
import pathlib
import re
import stat
import sys
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import qixi_device_run_preflight as device_preflight


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_ARTIFACT = ROOT / "qixi-ios-native" / "artifacts" / "device-bridge" / "latest-device-bridge-smoke.json"
MAX_JSON_BYTES = 512 * 1024
MAX_LAUNCH_ENV_JSON_BYTES = 16 * 1024
MAX_APP_SNAPSHOT_BYTES = 16 * 1024 * 1024
DEFAULT_MAX_AGE_SECONDS = 24 * 60 * 60
MAX_FUTURE_SKEW_SECONDS = 5 * 60
RUN_ID_RE = re.compile(r"^[0-9a-f]{32}$")
DEFAULT_BUNDLE_ID = "com.qixi.localanalysis"
AUTOMATION_ENGINES = {"b6", "b18nbt", "b28nbt"}
DIAGNOSTIC_CATEGORIES = {"none", "appRuntimeDiagnostic", "iosLocalNetworkDenied"}


class DeviceBridgeSmokeArtifactError(RuntimeError):
  pass


def fail(message: str) -> None:
  raise DeviceBridgeSmokeArtifactError(message)


def normalized_path(path: pathlib.Path) -> pathlib.Path:
  expanded = path.expanduser()
  if expanded.is_absolute():
    return expanded
  return pathlib.Path.cwd() / expanded


def reject_symlink_components(path: pathlib.Path, label: str) -> pathlib.Path:
  try:
    return device_preflight.reject_symlink_components(path, label)
  except device_preflight.DeviceRunPreflightError as exc:
    fail(str(exc))


def repository_path(path: pathlib.Path, label: str) -> pathlib.Path:
  candidate = reject_symlink_components(normalized_path(path), label)
  root = reject_symlink_components(ROOT, "repository root")
  try:
    candidate.relative_to(root)
  except ValueError:
    fail(f"{label} must stay inside repository root: {candidate}")
  return candidate


def regular_file(path: pathlib.Path, label: str, *, max_bytes: int = MAX_JSON_BYTES) -> pathlib.Path:
  checked = repository_path(path, label)
  if not checked.exists():
    fail(f"{label} does not exist: {checked}")
  try:
    file_stat = checked.stat()
  except OSError as exc:
    fail(f"{label} is unreadable: {exc}")
  if not stat.S_ISREG(file_stat.st_mode):
    fail(f"{label} must be a regular file: {checked}")
  if file_stat.st_size > max_bytes:
    fail(f"{label} exceeds bounded size: {file_stat.st_size} > {max_bytes}")
  return checked


def artifact_min_mtime_epoch() -> float | None:
  raw = os.environ.get("QIXI_DEVICE_BRIDGE_ARTIFACT_MIN_MTIME_EPOCH", "").strip()
  if not raw:
    return None
  try:
    return float(raw)
  except ValueError:
    fail("QIXI_DEVICE_BRIDGE_ARTIFACT_MIN_MTIME_EPOCH must be a numeric Unix timestamp")


def bounded_json(path: pathlib.Path, label: str, *, max_bytes: int = MAX_JSON_BYTES) -> Any:
  checked = regular_file(path, label, max_bytes=max_bytes)
  minimum_mtime = artifact_min_mtime_epoch()
  if minimum_mtime is not None and checked.stat().st_mtime < minimum_mtime:
    fail(f"{label} is stale: {checked}")

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
    with checked.open("rb") as handle:
      opened = os.fstat(handle.fileno())
      if not stat.S_ISREG(opened.st_mode):
        fail(f"{label} must be a regular file after opening: {checked}")
      if opened.st_size > max_bytes:
        fail(f"{label} exceeds bounded size after opening: {opened.st_size} > {max_bytes}")
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    fail(f"{label} is unreadable: {exc}")
  if len(data) > max_bytes:
    fail(f"{label} exceeds bounded size while reading: {checked}")
  try:
    return json.loads(
      data.decode("utf-8"),
      object_pairs_hook=reject_duplicate_keys,
      parse_constant=reject_non_standard_constant,
    )
  except DeviceBridgeSmokeArtifactError:
    raise
  except Exception as exc:
    fail(f"{label} must be JSON: {exc}")


def strict_json_text(raw: str, label: str, *, max_bytes: int) -> Any:
  encoded = raw.encode("utf-8")
  if len(encoded) > max_bytes:
    fail(f"{label} exceeds bounded size: {len(encoded)} > {max_bytes}")

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
      raw,
      object_pairs_hook=reject_duplicate_keys,
      parse_constant=reject_non_standard_constant,
    )
  except DeviceBridgeSmokeArtifactError:
    raise
  except Exception as exc:
    fail(f"{label} must be JSON: {exc}")


def as_object(value: Any, label: str) -> dict[str, Any]:
  if not isinstance(value, dict):
    fail(f"{label} must be an object")
  return value


def as_string(value: Any, label: str, *, allow_empty: bool = False) -> str:
  if not isinstance(value, str):
    fail(f"{label} must be a string")
  if not allow_empty and not value:
    fail(f"{label} must not be empty")
  return value


def as_bool(value: Any, label: str) -> bool:
  if not isinstance(value, bool):
    fail(f"{label} must be boolean")
  return value


def as_finite_number(value: Any, label: str, *, minimum: float | None = None) -> float:
  if isinstance(value, bool) or not isinstance(value, (int, float)):
    fail(f"{label} must be numeric")
  number = float(value)
  if not math.isfinite(number):
    fail(f"{label} must be finite")
  if minimum is not None and number < minimum:
    fail(f"{label} must be at least {minimum:g}")
  return number


def as_path(value: Any, label: str) -> pathlib.Path:
  return repository_path(pathlib.Path(as_string(value, label)), label)


def as_command_list(value: Any, label: str) -> list[str]:
  if not isinstance(value, list):
    fail(f"{label} must be a command list")
  if not value:
    fail(f"{label} must not be empty")
  command: list[str] = []
  for index, item in enumerate(value):
    if not isinstance(item, str) or not item:
      fail(f"{label}[{index}] must be a non-empty string")
    command.append(item)
  return command


def require_command_prefix(command: list[str], prefix: list[str], label: str) -> None:
  if command[: len(prefix)] != prefix:
    fail(f"{label} must start with {' '.join(prefix)!r}")


def command_option_value(command: list[str], option: str, label: str) -> str:
  count = command.count(option)
  if count != 1:
    fail(f"{label} must include {option} exactly once")
  index = command.index(option)
  if index + 1 >= len(command):
    fail(f"{label} must include a value after {option}")
  return command[index + 1]


def require_command_option_value(command: list[str], option: str, expected: str, label: str) -> None:
  actual = command_option_value(command, option, label)
  if actual != expected:
    fail(f"{label} must set {option} to {expected!r}, got {actual!r}")


def parse_utc_timestamp(value: Any, label: str) -> datetime.datetime:
  raw = as_string(value, label)
  if not raw.endswith("Z"):
    fail(f"{label} must be a UTC timestamp ending in Z")
  try:
    parsed = datetime.datetime.fromisoformat(raw.removesuffix("Z") + "+00:00")
  except ValueError as exc:
    fail(f"{label} must be ISO-8601: {exc}")
  return parsed.astimezone(datetime.timezone.utc)


def max_age_seconds() -> float:
  raw = os.environ.get("QIXI_DEVICE_BRIDGE_MAX_AGE_SECONDS", str(DEFAULT_MAX_AGE_SECONDS)).strip()
  try:
    value = float(raw)
  except ValueError:
    fail("QIXI_DEVICE_BRIDGE_MAX_AGE_SECONDS must be numeric")
  if value <= 0:
    fail("QIXI_DEVICE_BRIDGE_MAX_AGE_SECONDS must be positive")
  return value


def validate_manifest_timestamps(manifest: dict[str, Any]) -> None:
  generated_at = parse_utc_timestamp(manifest.get("generatedAt"), "generatedAt")
  started_at = parse_utc_timestamp(manifest.get("startedAt"), "startedAt")
  completed_at = parse_utc_timestamp(manifest.get("completedAt"), "completedAt")
  if completed_at < started_at:
    fail("completedAt must not be earlier than startedAt")
  if generated_at < started_at or generated_at > completed_at + datetime.timedelta(seconds=MAX_FUTURE_SKEW_SECONDS):
    fail("generatedAt must fall within the bridge smoke run window")
  now = datetime.datetime.now(datetime.timezone.utc)
  if completed_at > now + datetime.timedelta(seconds=MAX_FUTURE_SKEW_SECONDS):
    fail("completedAt must not be in the future")
  if (now - completed_at).total_seconds() > max_age_seconds():
    fail("device bridge smoke manifest is stale")


def validate_timings(value: Any) -> dict[str, Any]:
  timings = as_object(value, "device bridge smoke manifest timingsMs")
  required = ("build", "install", "launch", "launchSettle", "processes", "displays", "copyAppSupport")
  for key in required:
    as_finite_number(timings.get(key), f"timingsMs.{key}", minimum=0)
  return timings


def validate_string_list(value: Any, label: str) -> list[str]:
  if not isinstance(value, list):
    fail(f"{label} must be a list")
  result: list[str] = []
  for index, item in enumerate(value):
    result.append(as_string(item, f"{label}[{index}]"))
  return result


def validate_devicectl_json(path: pathlib.Path, label: str) -> dict[str, Any]:
  payload = as_object(bounded_json(path, label), label)
  if not payload:
    fail(f"{label} must not be empty")
  return payload


def validate_app_support_dir(path: pathlib.Path) -> pathlib.Path:
  checked = repository_path(path, "device bridge app support artifact")
  if not checked.exists():
    fail(f"device bridge app support artifact does not exist: {checked}")
  if not checked.is_dir():
    fail(f"device bridge app support artifact must be a directory: {checked}")
  return checked


def validate_snapshot_copy(
  app_support_path: pathlib.Path,
  filename: str,
  *,
  expected_engine: str | None,
) -> dict[str, Any]:
  snapshot_path = app_support_path / filename
  snapshot = as_object(
    bounded_json(
      snapshot_path,
      f"device bridge app support {filename}",
      max_bytes=MAX_APP_SNAPSHOT_BYTES,
    ),
    f"device bridge app support {filename}",
  )
  if snapshot.get("schemaVersion") != 1:
    fail(f"device bridge app support {filename} schemaVersion must be 1")
  selected_engine = as_string(snapshot.get("selectedEngine"), f"{filename}.selectedEngine")
  if selected_engine not in {"none", *AUTOMATION_ENGINES}:
    fail(f"{filename}.selectedEngine is not a known analysis engine: {selected_engine!r}")
  as_string(snapshot.get("saveReason"), f"{filename}.saveReason")
  as_string(snapshot.get("savedAt"), f"{filename}.savedAt")
  as_object(snapshot.get("analysisByEngine"), f"{filename}.analysisByEngine")
  if expected_engine is not None and selected_engine != expected_engine:
    fail(
      f"device bridge app support {filename} selectedEngine must match "
      f"QIXI_AUTOMATION_SELECT_ENGINE={expected_engine}, got {selected_engine!r}"
    )
  return snapshot


def validate_runtime_diagnostic(app_support_path: pathlib.Path, expected_engine: str) -> None:
  diagnostic = as_object(
    bounded_json(
      app_support_path / "runtime-diagnostics.qixi-state.json",
      "device bridge app support runtime diagnostics",
      max_bytes=64 * 1024,
    ),
    "device bridge app support runtime diagnostics",
  )
  if diagnostic.get("schemaVersion") != 1:
    fail("device bridge runtime diagnostics schemaVersion must be 1")
  if as_string(diagnostic.get("selectedEngine"), "runtimeDiagnostics.selectedEngine") != expected_engine:
    fail("device bridge runtime diagnostics selectedEngine must match launch environment")
  as_string(diagnostic.get("recordedAt"), "runtimeDiagnostics.recordedAt")
  as_string(diagnostic.get("event"), "runtimeDiagnostics.event")
  as_bool(diagnostic.get("success"), "runtimeDiagnostics.success")
  as_string(diagnostic.get("analysisRuntime"), "runtimeDiagnostics.analysisRuntime")
  as_string(diagnostic.get("backendBaseURL"), "runtimeDiagnostics.backendBaseURL", allow_empty=True)
  as_string(diagnostic.get("message"), "runtimeDiagnostics.message", allow_empty=True)


def validate_app_support_snapshots(app_support_path: pathlib.Path, launch_env: dict[str, Any]) -> None:
  expected_engine_value = launch_env.get("QIXI_AUTOMATION_SELECT_ENGINE")
  expected_engine: str | None = None
  if expected_engine_value is not None:
    expected_engine = as_string(expected_engine_value, "QIXI_AUTOMATION_SELECT_ENGINE")
    if expected_engine not in AUTOMATION_ENGINES:
      fail("QIXI_AUTOMATION_SELECT_ENGINE must be b6, b18nbt, or b28nbt")
  primary = validate_snapshot_copy(
    app_support_path,
    "autosave.qixi-state.json",
    expected_engine=expected_engine,
  )
  backup = validate_snapshot_copy(
    app_support_path,
    "autosave.qixi-state.backup.json",
    expected_engine=expected_engine,
  )
  if primary.get("selectedEngine") != backup.get("selectedEngine"):
    fail("device bridge app support autosave and backup selectedEngine must match")
  if expected_engine is not None:
    validate_runtime_diagnostic(app_support_path, expected_engine)


def validate_backend_events_artifact(
  path: pathlib.Path,
  *,
  origin: str,
  launch_env: dict[str, Any],
) -> None:
  payload = as_object(
    bounded_json(path, "device bridge backend events artifact"),
    "device bridge backend events artifact",
  )
  if payload.get("schemaVersion") != 1:
    fail("device bridge backend events artifact schemaVersion must be 1")
  if as_string(payload.get("origin"), "backendEvents.origin") != origin:
    fail("device bridge backend events artifact origin must match backend.origin")
  as_finite_number(payload.get("beforeLatestSequence"), "backendEvents.beforeLatestSequence", minimum=0)
  as_finite_number(payload.get("afterLatestSequence"), "backendEvents.afterLatestSequence", minimum=0)
  new_events = payload.get("newEvents")
  if not isinstance(new_events, list):
    fail("device bridge backend events artifact newEvents must be a list")
  expected_engine_value = launch_env.get("QIXI_AUTOMATION_SELECT_ENGINE")
  if expected_engine_value is None:
    return
  expected_engine = as_string(expected_engine_value, "QIXI_AUTOMATION_SELECT_ENGINE")
  if as_string(payload.get("expectedEngine"), "backendEvents.expectedEngine") != expected_engine:
    fail("device bridge backend events artifact expectedEngine must match launch environment")
  if not as_bool(payload.get("observedExpectedEngine"), "backendEvents.observedExpectedEngine"):
    fail(
      "device bridge backend events artifact must mark observedExpectedEngine=true "
      f"for launch engine {expected_engine}"
    )
  as_string(payload.get("diagnosticHint"), "backendEvents.diagnosticHint", allow_empty=True)
  diagnostic_category = payload.get("diagnosticCategory")
  if diagnostic_category is not None:
    category = as_string(diagnostic_category, "backendEvents.diagnosticCategory")
    if category not in DIAGNOSTIC_CATEGORIES:
      fail("device bridge backend events artifact diagnosticCategory is not recognized")
  matched_engine_events = [
    event for event in new_events
    if isinstance(event, dict) and event.get("kind") == "engine" and event.get("engine") == expected_engine
  ]
  if not matched_engine_events:
    fail(
      "device bridge backend events artifact must prove the launched app selected "
      f"backend engine {expected_engine}"
    )


def validate_failure_backend_events_artifact(
  path: pathlib.Path,
  *,
  origin: str,
  launch_env: dict[str, Any],
) -> None:
  payload = as_object(
    bounded_json(path, "device bridge failure backend events artifact"),
    "device bridge failure backend events artifact",
  )
  if payload.get("schemaVersion") != 1:
    fail("device bridge failure backend events artifact schemaVersion must be 1")
  if as_string(payload.get("origin"), "failureBackendEvents.origin") != origin:
    fail("device bridge failure backend events artifact origin must match backend.origin")
  before_sequence = as_finite_number(payload.get("beforeLatestSequence"), "failureBackendEvents.beforeLatestSequence", minimum=0)
  after_sequence = as_finite_number(payload.get("afterLatestSequence"), "failureBackendEvents.afterLatestSequence", minimum=0)
  if after_sequence < before_sequence:
    fail("device bridge failure backend events artifact afterLatestSequence must not be earlier than beforeLatestSequence")
  new_events = payload.get("newEvents")
  if not isinstance(new_events, list):
    fail("device bridge failure backend events artifact newEvents must be a list")
  expected_engine_value = launch_env.get("QIXI_AUTOMATION_SELECT_ENGINE")
  if expected_engine_value is None:
    fail("device bridge failure artifacts must include QIXI_AUTOMATION_SELECT_ENGINE in launch environment")
  expected_engine = as_string(expected_engine_value, "QIXI_AUTOMATION_SELECT_ENGINE")
  if expected_engine not in AUTOMATION_ENGINES:
    fail("QIXI_AUTOMATION_SELECT_ENGINE must be b6, b18nbt, or b28nbt")
  if as_string(payload.get("expectedEngine"), "failureBackendEvents.expectedEngine") != expected_engine:
    fail("device bridge failure backend events artifact expectedEngine must match launch environment")
  if as_bool(payload.get("observedExpectedEngine"), "failureBackendEvents.observedExpectedEngine"):
    fail("device bridge failure backend events artifact must mark observedExpectedEngine=false")
  diagnostic_hint = as_string(payload.get("diagnosticHint"), "failureBackendEvents.diagnosticHint")
  if "runtime diagnostic" not in diagnostic_hint:
    fail("device bridge failure backend events artifact diagnosticHint must include the app runtime diagnostic")
  diagnostic_category = as_string(payload.get("diagnosticCategory"), "failureBackendEvents.diagnosticCategory")
  if diagnostic_category not in {"appRuntimeDiagnostic", "iosLocalNetworkDenied"}:
    fail("device bridge failure backend events artifact diagnosticCategory must describe an app runtime failure")
  if diagnostic_category == "iosLocalNetworkDenied" and (
    "Denied over Wi-Fi" not in diagnostic_hint and "_NSURLErrorNWPathKey=unsatisfied" not in diagnostic_hint
  ):
    fail("device bridge failure backend events artifact diagnosticCategory=iosLocalNetworkDenied must be backed by Wi-Fi denial diagnostics")
  matched_engine_events = [
    event for event in new_events
    if isinstance(event, dict) and event.get("kind") == "engine" and event.get("engine") == expected_engine
  ]
  if matched_engine_events:
    fail(
      "device bridge failure backend events artifact contradicts observedExpectedEngine=false "
      f"for backend engine {expected_engine}"
    )


def validate_status_payload(value: Any) -> dict[str, Any]:
  status = as_object(value, "backend.status")
  for key in ("engine", "engineId", "state"):
    as_string(status.get(key), f"backend.status.{key}")
  for key in ("running", "paused"):
    as_bool(status.get(key), f"backend.status.{key}")
  return status


def launch_environment_from_command(launch_command: list[str]) -> dict[str, Any]:
  encoded_env = command_option_value(
    launch_command,
    "--environment-variables",
    "device bridge smoke launch command",
  )
  return as_object(
    strict_json_text(
      as_string(encoded_env, "launch environment JSON"),
      "launch environment JSON",
      max_bytes=MAX_LAUNCH_ENV_JSON_BYTES,
    ),
    "launch environment JSON",
  )


def validate_common_command_shape(
  *,
  manifest: dict[str, Any],
  device: dict[str, Any],
  origin: str,
  app_bundle_id: str,
  require_artifacts: bool,
  validate_backend_events: bool = True,
) -> dict[str, list[str]]:
  artifacts = as_object(manifest.get("artifacts"), "device bridge smoke manifest artifacts")
  artifact_paths: dict[str, pathlib.Path] = {}
  for key in ("install", "launch", "processes", "displays", "appSupportCopy"):
    artifact_path = as_path(artifacts.get(key), f"artifacts.{key}")
    if require_artifacts:
      validate_devicectl_json(artifact_path, f"device bridge {key} artifact")
    artifact_paths[key] = artifact_path
  app_support_path = as_path(artifacts.get("appSupport"), "artifacts.appSupport")
  if require_artifacts:
    validate_app_support_dir(app_support_path)
  backend_events_path: pathlib.Path | None = None
  if artifacts.get("backendEvents") is not None:
    backend_events_path = as_path(artifacts.get("backendEvents"), "artifacts.backendEvents")

  commands = as_object(manifest.get("commands"), "device bridge smoke manifest commands")
  xcodebuild_command = as_command_list(commands.get("xcodebuild"), "device bridge smoke xcodebuild command")
  install_command = as_command_list(commands.get("install"), "device bridge smoke install command")
  launch_command = as_command_list(commands.get("launch"), "device bridge smoke launch command")
  processes_command = as_command_list(commands.get("processes"), "device bridge smoke processes command")
  displays_command = as_command_list(commands.get("displays"), "device bridge smoke displays command")
  copy_command = as_command_list(commands.get("copyAppSupport"), "device bridge smoke copyAppSupport command")

  require_command_prefix(xcodebuild_command, ["xcodebuild"], "device bridge smoke xcodebuild command")
  if "-destination" not in xcodebuild_command or f"id={device['udid']}" not in xcodebuild_command:
    fail("device bridge smoke xcodebuild command must target the validated device UDID")
  if "build" not in xcodebuild_command:
    fail("device bridge smoke xcodebuild command must include build action")
  require_command_prefix(install_command, ["xcrun", "devicectl", "device", "install", "app"], "device bridge smoke install command")
  require_command_prefix(launch_command, ["xcrun", "devicectl", "device", "process", "launch"], "device bridge smoke launch command")
  require_command_prefix(processes_command, ["xcrun", "devicectl", "device", "info", "processes"], "device bridge smoke processes command")
  require_command_prefix(displays_command, ["xcrun", "devicectl", "device", "info", "displays"], "device bridge smoke displays command")
  require_command_prefix(copy_command, ["xcrun", "devicectl", "device", "copy", "from"], "device bridge smoke copyAppSupport command")

  for label, command in (
    ("device bridge smoke install command", install_command),
    ("device bridge smoke launch command", launch_command),
    ("device bridge smoke processes command", processes_command),
    ("device bridge smoke displays command", displays_command),
    ("device bridge smoke copyAppSupport command", copy_command),
  ):
    require_command_option_value(command, "--device", device["identifier"], label)
  for key, command, label in (
    ("install", install_command, "device bridge smoke install command"),
    ("launch", launch_command, "device bridge smoke launch command"),
    ("processes", processes_command, "device bridge smoke processes command"),
    ("displays", displays_command, "device bridge smoke displays command"),
    ("appSupportCopy", copy_command, "device bridge smoke copyAppSupport command"),
  ):
    require_command_option_value(command, "--json-output", str(artifact_paths[key]), label)
  require_command_option_value(copy_command, "--domain-type", "appDataContainer", "device bridge smoke copyAppSupport command")
  require_command_option_value(copy_command, "--domain-identifier", app_bundle_id, "device bridge smoke copyAppSupport command")
  require_command_option_value(copy_command, "--source", "Library/Application Support/Qixi", "device bridge smoke copyAppSupport command")
  require_command_option_value(copy_command, "--destination", str(app_support_path), "device bridge smoke copyAppSupport command")
  require_command_option_value(copy_command, "--remove-existing-content", "true", "device bridge smoke copyAppSupport command")
  if app_bundle_id not in launch_command:
    fail("device bridge smoke launch command must launch the validated app bundle")
  if "--terminate-existing" not in launch_command:
    fail("device bridge smoke launch command must terminate an existing app process")

  launch_env = launch_environment_from_command(launch_command)
  if launch_env.get("QIXI_ANALYSIS_RUNTIME") != "httpBridge":
    fail("device bridge smoke launch environment must use QIXI_ANALYSIS_RUNTIME=httpBridge")
  if launch_env.get("QIXI_BACKEND_URL") != origin:
    fail("device bridge smoke launch environment must use the validated backend origin")
  if not launch_env.get("QIXI_SKIP_ONBOARDING"):
    fail("device bridge smoke launch environment must set QIXI_SKIP_ONBOARDING")
  if require_artifacts:
    validate_app_support_snapshots(app_support_path, launch_env)
    if validate_backend_events and launch_env.get("QIXI_AUTOMATION_SELECT_ENGINE") is not None:
      if backend_events_path is None:
        fail("device bridge smoke with QIXI_AUTOMATION_SELECT_ENGINE must include artifacts.backendEvents")
      validate_backend_events_artifact(backend_events_path, origin=origin, launch_env=launch_env)

  return {
    "xcodebuild": xcodebuild_command,
    "install": install_command,
    "launch": launch_command,
    "processes": processes_command,
    "displays": displays_command,
    "copyAppSupport": copy_command,
  }


def validate_real_smoke_signing(manifest: dict[str, Any], app_bundle_id: str) -> dict[str, Any]:
  try:
    device_preflight.validate_bundle_identifier(app_bundle_id, "app.bundleIdentifier")
  except device_preflight.DeviceRunPreflightError as exc:
    fail(str(exc))
  signing = manifest.get("signing")
  if app_bundle_id == DEFAULT_BUNDLE_ID:
    if isinstance(signing, dict):
      signing_bundle_id = as_string(signing.get("bundleIdentifier"), "signing.bundleIdentifier")
      if signing_bundle_id != app_bundle_id:
        fail("device bridge smoke signing bundleIdentifier must match app bundleIdentifier")
    return as_object(signing, "device bridge smoke manifest signing") if isinstance(signing, dict) else {}

  signing_object = as_object(signing, "device bridge smoke manifest signing")
  signing_bundle_id = as_string(signing_object.get("bundleIdentifier"), "signing.bundleIdentifier")
  if signing_bundle_id != app_bundle_id:
    fail("device bridge smoke signing bundleIdentifier must match app bundleIdentifier")
  if not as_bool(
    signing_object.get("iCloudEntitlementsDisabledForLocalBridge"),
    "signing.iCloudEntitlementsDisabledForLocalBridge",
  ):
    fail("local device bridge bundle overrides must disable iCloud entitlements in the manifest")
  return signing_object


def validate_manifest_header(path: pathlib.Path, *, expected_kind: str = "qixi-device-bridge-smoke") -> dict[str, Any]:
  manifest = as_object(bounded_json(path, "device bridge smoke manifest"), "device bridge smoke manifest")
  if manifest.get("schemaVersion") != 1:
    fail("device bridge smoke manifest schemaVersion must be 1")
  if manifest.get("kind") != expected_kind:
    fail(f"device bridge smoke manifest kind must be {expected_kind}")
  run_id = as_string(manifest.get("runId"), "runId")
  if not RUN_ID_RE.fullmatch(run_id):
    fail("runId must be a 32-character lowercase hex value")
  validate_manifest_timestamps(manifest)
  return manifest


def validate_manifest(path: pathlib.Path) -> dict[str, Any]:
  manifest = validate_manifest_header(path)
  if as_bool(manifest.get("dryRun"), "device bridge smoke manifest dryRun"):
    fail("device bridge smoke manifest must not be dryRun for real device evidence")

  device = as_object(manifest.get("device"), "device bridge smoke manifest device")
  as_string(device.get("identifier"), "device.identifier")
  as_string(device.get("udid"), "device.udid")

  backend = as_object(manifest.get("backend"), "device bridge smoke manifest backend")
  try:
    origin = device_preflight.validate_physical_device_backend_url(as_string(backend.get("origin"), "backend.origin"))
  except device_preflight.DeviceRunPreflightError as exc:
    fail(str(exc))
  validate_status_payload(backend.get("status"))

  app = as_object(manifest.get("app"), "device bridge smoke manifest app")
  app_bundle_id = as_string(app.get("bundleIdentifier"), "app.bundleIdentifier")
  signing = validate_real_smoke_signing(manifest, app_bundle_id)
  as_string(app.get("executable"), "app.executable")
  as_string(app.get("infoPlist"), "app.infoPlist")

  validate_timings(manifest.get("timingsMs"))
  commands = validate_common_command_shape(
    manifest=manifest,
    device=device,
    origin=origin,
    app_bundle_id=app_bundle_id,
    require_artifacts=True,
  )
  xcodebuild_command = commands["xcodebuild"]
  if app_bundle_id != DEFAULT_BUNDLE_ID and f"PRODUCT_BUNDLE_IDENTIFIER={app_bundle_id}" not in xcodebuild_command:
    fail("device bridge smoke xcodebuild command must use the local bridge bundle identifier")
  if signing and signing.get("iCloudEntitlementsDisabledForLocalBridge") and "CODE_SIGN_ENTITLEMENTS=" not in xcodebuild_command:
    fail("device bridge smoke xcodebuild command must disable iCloud entitlements when requested")

  return manifest


def validate_failure_manifest(path: pathlib.Path) -> dict[str, Any]:
  manifest = validate_manifest_header(path, expected_kind="qixi-device-bridge-smoke-failure")
  if as_bool(manifest.get("dryRun"), "device bridge failure manifest dryRun"):
    fail("device bridge failure manifest must not be dryRun")

  failure = as_object(manifest.get("failure"), "device bridge failure manifest failure")
  if as_string(failure.get("stage"), "failure.stage") != "backendEvents":
    fail("device bridge failure manifest failure.stage must be backendEvents")
  failure_message = as_string(failure.get("message"), "failure.message")
  if "did not observe" not in failure_message or "backend engine" not in failure_message:
    fail("device bridge failure manifest message must describe the missing backend engine observation")

  device = as_object(manifest.get("device"), "device bridge failure manifest device")
  as_string(device.get("identifier"), "device.identifier")
  as_string(device.get("udid"), "device.udid")

  backend = as_object(manifest.get("backend"), "device bridge failure manifest backend")
  try:
    origin = device_preflight.validate_physical_device_backend_url(as_string(backend.get("origin"), "backend.origin"))
  except device_preflight.DeviceRunPreflightError as exc:
    fail(str(exc))
  validate_status_payload(backend.get("status"))

  app = as_object(manifest.get("app"), "device bridge failure manifest app")
  app_bundle_id = as_string(app.get("bundleIdentifier"), "app.bundleIdentifier")
  signing = validate_real_smoke_signing(manifest, app_bundle_id)
  as_string(app.get("executable"), "app.executable")
  as_string(app.get("infoPlist"), "app.infoPlist")

  validate_timings(manifest.get("timingsMs"))
  commands = validate_common_command_shape(
    manifest=manifest,
    device=device,
    origin=origin,
    app_bundle_id=app_bundle_id,
    require_artifacts=True,
    validate_backend_events=False,
  )
  launch_env = launch_environment_from_command(commands["launch"])
  artifacts = as_object(manifest.get("artifacts"), "device bridge failure manifest artifacts")
  backend_events_path = as_path(artifacts.get("backendEvents"), "artifacts.backendEvents")
  validate_failure_backend_events_artifact(backend_events_path, origin=origin, launch_env=launch_env)
  expected_engine = as_string(launch_env.get("QIXI_AUTOMATION_SELECT_ENGINE"), "QIXI_AUTOMATION_SELECT_ENGINE")
  diagnostic_path = as_path(artifacts.get("appSupport"), "artifacts.appSupport") / "runtime-diagnostics.qixi-state.json"
  diagnostic = as_object(
    bounded_json(diagnostic_path, "device bridge failure runtime diagnostics", max_bytes=64 * 1024),
    "device bridge failure runtime diagnostics",
  )
  if as_string(diagnostic.get("selectedEngine"), "runtimeDiagnostics.selectedEngine") != expected_engine:
    fail("device bridge failure runtime diagnostics selectedEngine must match launch environment")
  if as_bool(diagnostic.get("success"), "runtimeDiagnostics.success"):
    fail("device bridge failure runtime diagnostics must record success=false")
  diagnostic_message = as_string(diagnostic.get("message"), "runtimeDiagnostics.message")
  if diagnostic_message and diagnostic_message[:120] not in failure_message:
    fail("device bridge failure manifest message must include the runtime diagnostic context")

  xcodebuild_command = commands["xcodebuild"]
  if app_bundle_id != DEFAULT_BUNDLE_ID and f"PRODUCT_BUNDLE_IDENTIFIER={app_bundle_id}" not in xcodebuild_command:
    fail("device bridge failure xcodebuild command must use the local bridge bundle identifier")
  if signing and signing.get("iCloudEntitlementsDisabledForLocalBridge") and "CODE_SIGN_ENTITLEMENTS=" not in xcodebuild_command:
    fail("device bridge failure xcodebuild command must disable iCloud entitlements when requested")

  return manifest


def validate_plan_manifest(path: pathlib.Path) -> dict[str, Any]:
  manifest = validate_manifest_header(path)
  if not as_bool(manifest.get("dryRun"), "device bridge smoke manifest dryRun"):
    fail("device bridge plan manifest must be dryRun")

  preflight = as_object(manifest.get("preflight"), "device bridge plan manifest preflight")
  if not as_bool(preflight.get("planOnly"), "preflight.planOnly"):
    fail("device bridge plan manifest preflight.planOnly must be true")
  if as_bool(preflight.get("strictPhysicalDeviceEnvironmentChecked"), "preflight.strictPhysicalDeviceEnvironmentChecked"):
    fail("device bridge plan manifest must not claim strict physical-device preflight passed")
  validate_string_list(preflight.get("signingBlockers"), "preflight.signingBlockers")
  validate_string_list(preflight.get("notes"), "preflight.notes")

  device = as_object(manifest.get("device"), "device bridge smoke manifest device")
  as_string(device.get("identifier"), "device.identifier")
  as_string(device.get("udid"), "device.udid")

  backend = as_object(manifest.get("backend"), "device bridge smoke manifest backend")
  try:
    origin = device_preflight.validate_physical_device_backend_url(as_string(backend.get("origin"), "backend.origin"))
  except device_preflight.DeviceRunPreflightError as exc:
    fail(str(exc))
  validate_status_payload(backend.get("status"))

  app = as_object(manifest.get("app"), "device bridge smoke manifest app")
  app_bundle_id = as_string(app.get("bundleIdentifier"), "app.bundleIdentifier")
  try:
    device_preflight.validate_bundle_identifier(app_bundle_id, "app.bundleIdentifier")
  except device_preflight.DeviceRunPreflightError as exc:
    fail(str(exc))
  as_string(app.get("executable"), "app.executable", allow_empty=True)
  as_string(app.get("infoPlist"), "app.infoPlist", allow_empty=True)

  signing = as_object(manifest.get("signing"), "device bridge plan manifest signing")
  signing_bundle_id = as_string(signing.get("bundleIdentifier"), "signing.bundleIdentifier")
  if signing_bundle_id != app_bundle_id:
    fail("device bridge plan signing bundleIdentifier must match app bundleIdentifier")
  development_team_override = as_string(
    signing.get("developmentTeamOverride"),
    "signing.developmentTeamOverride",
    allow_empty=True,
  )
  icloud_disabled = as_bool(
    signing.get("iCloudEntitlementsDisabledForLocalBridge"),
    "signing.iCloudEntitlementsDisabledForLocalBridge",
  )

  timings = as_object(manifest.get("timingsMs"), "device bridge smoke manifest timingsMs")
  if timings:
    fail("device bridge plan manifest timingsMs must be empty because no build/install/launch commands ran")

  commands = validate_common_command_shape(
    manifest=manifest,
    device=device,
    origin=origin,
    app_bundle_id=app_bundle_id,
    require_artifacts=False,
  )
  xcodebuild_command = commands["xcodebuild"]
  if f"PRODUCT_BUNDLE_IDENTIFIER={app_bundle_id}" not in xcodebuild_command:
    fail("device bridge plan xcodebuild command must use the planned bundle identifier")
  if development_team_override and f"DEVELOPMENT_TEAM={development_team_override}" not in xcodebuild_command:
    fail("device bridge plan xcodebuild command must use the planned development team")
  if icloud_disabled and "CODE_SIGN_ENTITLEMENTS=" not in xcodebuild_command:
    fail("device bridge plan xcodebuild command must disable iCloud entitlements when requested")

  return manifest


def main() -> int:
  plan_only = len(sys.argv) > 1 and sys.argv[1] == "--plan-only"
  failure_only = len(sys.argv) > 1 and sys.argv[1] == "--failure"
  if plan_only or failure_only:
    raw_path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_ARTIFACT
  else:
    raw_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_ARTIFACT
  try:
    if plan_only:
      manifest = validate_plan_manifest(raw_path)
    elif failure_only:
      manifest = validate_failure_manifest(raw_path)
    else:
      manifest = validate_manifest(raw_path)
  except (DeviceBridgeSmokeArtifactError, device_preflight.DeviceRunPreflightError) as exc:
    label = "Device bridge plan inspection" if plan_only else "Device bridge failure inspection" if failure_only else "Device bridge smoke artifact inspection"
    print(f"{label} failed: {exc}", file=sys.stderr)
    return 1
  if plan_only:
    blockers = len(manifest["preflight"]["signingBlockers"])
    print(
      "Device bridge plan inspection passed: "
      f"{raw_path} device={manifest['device']['udid']} backend={manifest['backend']['origin']} blockers={blockers}"
    )
    return 0
  if failure_only:
    print(
      "Device bridge failure inspection passed: "
      f"{raw_path} device={manifest['device']['udid']} backend={manifest['backend']['origin']} "
      f"stage={manifest['failure']['stage']}"
    )
    return 0
  print(
    "Device bridge smoke artifact inspection passed: "
    f"{raw_path} device={manifest['device']['udid']} backend={manifest['backend']['origin']}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
