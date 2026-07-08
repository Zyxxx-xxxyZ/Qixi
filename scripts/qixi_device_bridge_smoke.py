#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time
import datetime
import uuid
import urllib.error
import urllib.request
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import qixi_device_run_preflight as device_preflight


ROOT = pathlib.Path(__file__).resolve().parents[1]
NATIVE = ROOT / "qixi-ios-native"
PROJECT = NATIVE / "Qixi.xcodeproj"
SCHEME = "Qixi"
CONFIGURATION = "Debug"
DEFAULT_DERIVED_DATA = pathlib.Path("/private/tmp/qixi-device-bridge-derived")
DEFAULT_ARTIFACT_DIR = NATIVE / "artifacts" / "device-bridge"
APP_NAME = "Qixi.app"
EXECUTABLE_NAME = "Qixi"
DEFAULT_BUNDLE_ID = "com.qixi.localanalysis"
DEVICE_DISABLE_ICLOUD_ENTITLEMENTS_ENV = "QIXI_DEVICE_DISABLE_ICLOUD_ENTITLEMENTS"
DEVICE_ALLOW_BUNDLE_OVERRIDE_WITH_ICLOUD_ENV = "QIXI_DEVICE_ALLOW_BUNDLE_OVERRIDE_WITH_ICLOUD"
DEVICE_BRIDGE_DRY_RUN_ENV = "QIXI_DEVICE_BRIDGE_DRY_RUN"
DEVICE_BRIDGE_PLAN_ONLY_ENV = "QIXI_DEVICE_BRIDGE_PLAN_ONLY"
DEVICE_AUTOMATION_SELECT_ENGINE_ENV = "QIXI_DEVICE_AUTOMATION_SELECT_ENGINE"
RUN_ID_RE = re.compile(r"^[0-9a-f]{32}$")
AUTOMATION_ENGINES = {"b6", "b18nbt", "b28nbt"}
MAX_BACKEND_EVENTS_BYTES = 1024 * 1024


class DeviceBridgeSmokeError(RuntimeError):
  pass


def fail(message: str) -> None:
  raise DeviceBridgeSmokeError(message)


def env_flag(name: str, default: str = "0") -> bool:
  return os.environ.get(name, default).strip() == "1"


def normalized_path(raw: str | pathlib.Path) -> pathlib.Path:
  path = pathlib.Path(raw).expanduser()
  if path.is_absolute():
    return path
  return pathlib.Path.cwd() / path


def reject_symlink_components(path: pathlib.Path, label: str) -> pathlib.Path:
  return device_preflight.reject_symlink_components(path, label)


def require_command(name: str) -> str:
  found = shutil.which(name)
  if found is None:
    fail(f"{name} is required for physical-device bridge smoke")
  return found


def run_command(args: list[str], label: str, *, timeout: float, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
  try:
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout, env=env, check=False)
  except subprocess.TimeoutExpired as exc:
    fail(f"{label} timed out after {timeout:g}s")
  if result.returncode != 0:
    detail = (result.stderr.strip() or result.stdout.strip())[:6000]
    fail(f"{label} failed: {detail}")
  return result


def fetch_backend_events(origin: str, timeout: float) -> dict[str, Any]:
  url = origin.rstrip("/") + "/api/events"
  try:
    with urllib.request.urlopen(url, timeout=timeout) as response:
      content_type = response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
      if content_type != "application/json":
        fail(f"backend events endpoint returned {content_type or '(missing Content-Type)'}")
      body = response.read(MAX_BACKEND_EVENTS_BYTES + 1)
  except urllib.error.URLError as exc:
    fail(f"backend events endpoint could not be read: {exc}")
  if len(body) > MAX_BACKEND_EVENTS_BYTES:
    fail("backend events endpoint response exceeded bounded size")
  try:
    payload = json.loads(body.decode("utf-8"))
  except json.JSONDecodeError as exc:
    fail(f"backend events endpoint returned invalid JSON: {exc}")
  if not isinstance(payload, dict):
    fail("backend events endpoint must return a JSON object")
  events = payload.get("events")
  if not isinstance(events, list):
    fail("backend events endpoint must return an events list")
  if not isinstance(payload.get("latestSequence"), int):
    fail("backend events endpoint must return an integer latestSequence")
  return payload


def backend_events_artifact_payload(
  *,
  origin: str,
  launch_environment: dict[str, str],
  before: dict[str, Any],
  after: dict[str, Any],
  diagnostic_hint: str = "",
) -> dict[str, Any]:
  before_sequence = int(before.get("latestSequence", 0))
  after_events = after.get("events", [])
  new_events = [
    dict(event)
    for event in after_events
    if isinstance(event, dict) and isinstance(event.get("sequence"), int) and event["sequence"] > before_sequence
  ]
  expected_engine = launch_environment.get("QIXI_AUTOMATION_SELECT_ENGINE")
  observed_expected_engine = False
  if expected_engine:
    matched_engine_events = [
      event for event in new_events
      if event.get("kind") == "engine" and event.get("engine") == expected_engine
    ]
    observed_expected_engine = bool(matched_engine_events)
  return {
    "schemaVersion": 1,
    "generatedAt": utc_timestamp(),
    "origin": origin,
    "beforeLatestSequence": before_sequence,
    "afterLatestSequence": after.get("latestSequence"),
    "expectedEngine": expected_engine or "",
    "observedExpectedEngine": observed_expected_engine,
    "diagnosticHint": diagnostic_hint,
    "diagnosticCategory": diagnostic_category(diagnostic_hint),
    "newEvents": new_events,
    "after": after,
  }


def diagnostic_category(diagnostic_hint: str) -> str:
  normalized = diagnostic_hint.lower()
  if "denied over wi-fi" in normalized or "_nsurlerrornwpathkey=unsatisfied" in normalized:
    return "iosLocalNetworkDenied"
  if "runtime diagnostic" in normalized:
    return "appRuntimeDiagnostic"
  return "none"


def backend_events_failure_message(payload: dict[str, Any]) -> str:
  expected_engine = str(payload.get("expectedEngine", ""))
  diagnostic_hint = str(payload.get("diagnosticHint", ""))
  hint = f"; {diagnostic_hint}" if diagnostic_hint else ""
  return (
    "device bridge smoke did not observe the launched app selecting "
    f"backend engine {expected_engine!r}; check iOS local-network permission and launch foreground state{hint}"
  )


def runtime_diagnostic_hint(app_support_dir: pathlib.Path) -> str:
  diagnostic_path = app_support_dir / "runtime-diagnostics.qixi-state.json"
  try:
    with diagnostic_path.open("rb") as handle:
      data = handle.read(64 * 1024 + 1)
  except OSError:
    return ""
  if len(data) > 64 * 1024:
    return "runtime diagnostic was present but exceeded bounded size"
  try:
    payload = json.loads(data.decode("utf-8"))
  except Exception:
    return "runtime diagnostic was present but not valid JSON"
  if not isinstance(payload, dict):
    return "runtime diagnostic was present but not a JSON object"
  event = str(payload.get("event", "unknown"))
  success = payload.get("success")
  message = str(payload.get("message", "")).replace("\n", " ")
  if len(message) > 480:
    message = message[:477] + "..."
  return f"runtime diagnostic event={event} success={success}: {message}"


def utc_timestamp() -> str:
  return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def elapsed_ms(start_ns: int, end_ns: int) -> int:
  return max(0, round((end_ns - start_ns) / 1_000_000))


def bridge_run_id() -> str:
  raw = os.environ.get("QIXI_DEVICE_BRIDGE_RUN_ID", "").strip()
  value = raw or uuid.uuid4().hex
  if not RUN_ID_RE.fullmatch(value):
    fail("QIXI_DEVICE_BRIDGE_RUN_ID must be a 32-character lowercase hex value")
  return value


def strict_backend_origin() -> str:
  raw = os.environ.get("QIXI_DEVICE_BACKEND_URL", "").strip()
  if not raw:
    fail("QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 is required for physical-device bridge smoke")
  return device_preflight.validate_physical_device_backend_url(raw)


def selected_device() -> tuple[str, str]:
  device_identifier = device_preflight.select_physical_device_identifier()
  details = device_preflight.command_output(
    ["xcrun", "devicectl", "device", "info", "details", "--device", device_identifier],
    "devicectl device details",
  )
  return device_identifier, device_preflight.validated_physical_device_udid(details)


def validate_xcode_destination_for_device(device_udid: str) -> None:
  destinations = device_preflight.command_output(
    ["xcodebuild", "-project", str(PROJECT), "-scheme", SCHEME, "-showdestinations"],
    "xcodebuild destination discovery",
  )
  if not device_preflight.xcode_destinations_include_device(destinations, device_udid):
    fail(f"physical-device bridge plan could not find iOS destination id:{device_udid} for the Qixi scheme")


def collect_plan_only_signing_blockers(
  team: str,
  bundle_id: str,
  device_udid: str,
  allow_provisioning_updates: bool = False,
  identity_output: str | None = None,
) -> list[str]:
  blockers: list[str] = []
  if identity_output is None:
    identity_output = device_preflight.command_output(
      ["security", "find-identity", "-v", "-p", "codesigning"],
      "code-signing identity lookup",
    )
  matching_profile: tuple[pathlib.Path, dict[str, Any]] | None = None
  try:
    matching_profile = device_preflight.find_matching_development_profile_payload(team, bundle_id, device_udid)
  except device_preflight.DeviceRunPreflightError as exc:
    blockers.append(str(exc))
  try:
    device_preflight.check_apple_development_identity(
      team,
      identity_output,
      matching_profile[1] if matching_profile else None,
    )
  except device_preflight.DeviceRunPreflightError as exc:
    blockers.append(str(exc))
  if matching_profile is None:
    if allow_provisioning_updates:
      blockers.append(
        "automatic provisioning is requested, but plan-only mode found no installed iOS App Development "
        f"provisioning profile for team {team}, bundle {bundle_id}, and device {device_udid}; "
        "run the signing doctor or real bridge smoke to verify Xcode account credentials and profile creation"
      )
    else:
      blockers.append(
        "strict physical-device preflight found no installed iOS App Development provisioning profile "
        f"for team {team}, bundle {bundle_id}, and device {device_udid}; "
        f"install a matching profile or set {device_preflight.DEVICE_ALLOW_PROVISIONING_UPDATES_ENV}=1 after adding a valid Xcode account"
      )
  return blockers


def build_xcodebuild_args(
  device_udid: str,
  derived_data: pathlib.Path,
  development_team: str | None,
  bundle_id: str | None = None,
  allow_provisioning_updates: bool = False,
  disable_icloud_entitlements: bool = False,
) -> list[str]:
  args = [
    "xcodebuild",
    "-project",
    str(PROJECT),
    "-scheme",
    SCHEME,
    "-destination",
    f"id={device_udid}",
    "-configuration",
    CONFIGURATION,
    "-derivedDataPath",
    str(derived_data),
  ]
  if allow_provisioning_updates:
    args.extend(["-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration"])
  args.append("build")
  if development_team:
    args.append(f"DEVELOPMENT_TEAM={development_team}")
  if bundle_id:
    args.append(f"PRODUCT_BUNDLE_IDENTIFIER={bundle_id}")
  if disable_icloud_entitlements:
    args.append("CODE_SIGN_ENTITLEMENTS=")
  return args


def built_app_path(derived_data: pathlib.Path) -> pathlib.Path:
  return derived_data / "Build" / "Products" / "Debug-iphoneos" / APP_NAME


def newest_input_mtime_ns(paths: list[pathlib.Path], *, label: str) -> int:
  newest = 0
  for root in paths:
    checked_root = reject_symlink_components(root, label)
    if checked_root.is_file():
      newest = max(newest, checked_root.stat().st_mtime_ns)
      continue
    if not checked_root.is_dir():
      continue
    for path in checked_root.rglob("*"):
      checked_path = reject_symlink_components(path, label)
      if checked_path.is_file():
        newest = max(newest, checked_path.stat().st_mtime_ns)
  return newest


def newest_executable_input_mtime_ns() -> int:
  newest = 0
  checked_project = reject_symlink_components(PROJECT / "project.pbxproj", "device bridge executable input")
  if checked_project.is_file():
    newest = max(newest, checked_project.stat().st_mtime_ns)
  source_root = reject_symlink_components(NATIVE / "Qixi", "device bridge executable input")
  for path in source_root.rglob("*"):
    checked_path = reject_symlink_components(path, "device bridge executable input")
    if checked_path.is_file() and checked_path.suffix in {".swift", ".mm", ".cpp", ".hpp", ".h"}:
      newest = max(newest, checked_path.stat().st_mtime_ns)
  return newest


def newest_app_input_mtime_ns() -> int:
  return newest_input_mtime_ns(
    [PROJECT / "project.pbxproj", NATIVE / "Qixi"],
    label="device bridge app input",
  )


def newest_app_bundle_mtime_ns(app_path: pathlib.Path) -> int:
  return newest_input_mtime_ns([app_path], label="built device app bundle")


def validate_built_app(app_path: pathlib.Path, marker_ns: int, expected_bundle_id: str) -> dict[str, Any]:
  checked_app = reject_symlink_components(app_path, "built device app")
  if not checked_app.is_dir():
    fail(f"built device app is missing: {checked_app}")
  executable = reject_symlink_components(checked_app / EXECUTABLE_NAME, "built device app executable")
  info_plist = reject_symlink_components(checked_app / "Info.plist", "built device app Info.plist")
  if not executable.is_file():
    fail(f"built device app executable is missing: {executable}")
  if not os.access(executable, os.X_OK):
    fail(f"built device app executable is not executable: {executable}")
  executable_mtime_ns = executable.stat().st_mtime_ns
  if executable_mtime_ns < marker_ns:
    executable_input_mtime_ns = newest_executable_input_mtime_ns()
    app_input_mtime_ns = newest_app_input_mtime_ns()
    bundle_mtime_ns = newest_app_bundle_mtime_ns(checked_app)
    if executable_mtime_ns < executable_input_mtime_ns or bundle_mtime_ns < app_input_mtime_ns:
      fail(
        "built device app executable is older than this smoke run and stale relative to app inputs: "
        f"{executable}"
      )
  if not info_plist.is_file():
    fail(f"built device app Info.plist is missing: {info_plist}")
  with info_plist.open("rb") as handle:
    opened = os.fstat(handle.fileno())
    if not stat.S_ISREG(opened.st_mode):
      fail(f"built device app Info.plist must be a regular file after opening: {info_plist}")
    payload = plistlib.load(handle)
  bundle_id = payload.get("CFBundleIdentifier")
  if bundle_id != expected_bundle_id:
    fail(f"built device app bundle id mismatch: expected {expected_bundle_id}, got {bundle_id!r}")
  return {"bundleIdentifier": bundle_id, "executable": str(executable), "infoPlist": str(info_plist)}


def devicectl_install_args(device_identifier: str, app_path: pathlib.Path, json_output: pathlib.Path, timeout: float) -> list[str]:
  return [
    "xcrun",
    "devicectl",
    "device",
    "install",
    "app",
    "--device",
    device_identifier,
    str(app_path),
    "--json-output",
    str(json_output),
    "--timeout",
    f"{timeout:g}",
  ]


def launch_environment(origin: str) -> dict[str, str]:
  language = os.environ.get("QIXI_DEVICE_APP_LANGUAGE", "zh-Hans").strip() or "zh-Hans"
  skip_onboarding = os.environ.get("QIXI_DEVICE_SKIP_ONBOARDING", "1").strip() or "1"
  environment = {
    "QIXI_ANALYSIS_RUNTIME": "httpBridge",
    "QIXI_BACKEND_URL": origin,
    "QIXI_SKIP_ONBOARDING": skip_onboarding,
    "QIXI_APP_LANGUAGE": language,
  }
  requested_engine = os.environ.get(DEVICE_AUTOMATION_SELECT_ENGINE_ENV, "").strip()
  if requested_engine:
    if requested_engine not in AUTOMATION_ENGINES:
      fail(
        f"{DEVICE_AUTOMATION_SELECT_ENGINE_ENV} must be one of "
        f"{', '.join(sorted(AUTOMATION_ENGINES))}"
      )
    environment["QIXI_AUTOMATION_SELECT_ENGINE"] = requested_engine
  return environment


def validate_bridge_signing_overrides(bundle_id: str, disable_icloud_entitlements: bool) -> None:
  if bundle_id == DEFAULT_BUNDLE_ID:
    return
  if disable_icloud_entitlements:
    return
  if env_flag(DEVICE_ALLOW_BUNDLE_OVERRIDE_WITH_ICLOUD_ENV):
    return
  fail(
    f"{device_preflight.DEVICE_BUNDLE_ID_ENV} differs from {DEFAULT_BUNDLE_ID}; "
    f"set {DEVICE_DISABLE_ICLOUD_ENTITLEMENTS_ENV}=1 for local bridge smoke with a personal bundle id, "
    f"or set {DEVICE_ALLOW_BUNDLE_OVERRIDE_WITH_ICLOUD_ENV}=1 only after the selected team owns the "
    "existing iCloud entitlements."
  )


def devicectl_launch_args(
  device_identifier: str,
  bundle_id: str,
  environment: dict[str, str],
  json_output: pathlib.Path,
  timeout: float,
) -> list[str]:
  return [
    "xcrun",
    "devicectl",
    "device",
    "process",
    "launch",
    "--device",
    device_identifier,
    "--terminate-existing",
    "--environment-variables",
    json.dumps(environment, sort_keys=True, separators=(",", ":")),
    bundle_id,
    "--json-output",
    str(json_output),
    "--timeout",
    f"{timeout:g}",
  ]


def devicectl_processes_args(device_identifier: str, json_output: pathlib.Path, timeout: float) -> list[str]:
  return [
    "xcrun",
    "devicectl",
    "device",
    "info",
    "processes",
    "--device",
    device_identifier,
    "--json-output",
    str(json_output),
    "--timeout",
    f"{timeout:g}",
  ]


def devicectl_displays_args(device_identifier: str, json_output: pathlib.Path, timeout: float) -> list[str]:
  return [
    "xcrun",
    "devicectl",
    "device",
    "info",
    "displays",
    "--device",
    device_identifier,
    "--json-output",
    str(json_output),
    "--timeout",
    f"{timeout:g}",
  ]


def devicectl_copy_app_support_args(
  device_identifier: str,
  bundle_id: str,
  destination: pathlib.Path,
  json_output: pathlib.Path,
  timeout: float,
) -> list[str]:
  return [
    "xcrun",
    "devicectl",
    "device",
    "copy",
    "from",
    "--device",
    device_identifier,
    "--domain-type",
    "appDataContainer",
    "--domain-identifier",
    bundle_id,
    "--source",
    "Library/Application Support/Qixi",
    "--destination",
    str(destination),
    "--remove-existing-content",
    "true",
    "--json-output",
    str(json_output),
    "--timeout",
    f"{timeout:g}",
  ]


def write_manifest(path: pathlib.Path, payload: dict[str, Any]) -> None:
  checked_path = reject_symlink_components(normalized_path(path), "device bridge smoke manifest path")
  checked_path.parent.mkdir(parents=True, exist_ok=True)
  checked_path = reject_symlink_components(checked_path, "device bridge smoke manifest path")
  tmp_path = checked_path.with_name(f".{checked_path.name}.{os.getpid()}.tmp")
  reject_symlink_components(tmp_path, "device bridge smoke manifest temporary path")
  flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
  if hasattr(os, "O_CLOEXEC"):
    flags |= os.O_CLOEXEC
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
  encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
  fd: int | None = None
  created_tmp = False
  try:
    fd = os.open(tmp_path, flags, 0o600)
    created_tmp = True
    with os.fdopen(fd, "wb") as handle:
      fd = None
      handle.write(encoded)
      handle.flush()
      os.fsync(handle.fileno())
    os.replace(tmp_path, checked_path)
    parent_fd = os.open(checked_path.parent, os.O_RDONLY)
    try:
      os.fsync(parent_fd)
    finally:
      os.close(parent_fd)
  except OSError as exc:
    if fd is not None:
      try:
        os.close(fd)
      except OSError:
        pass
    if created_tmp:
      try:
        tmp_path.unlink()
      except OSError:
        pass
    fail(f"device bridge smoke manifest could not be written: {checked_path}: {exc}")


def main() -> int:
  try:
    require_command("xcodebuild")
    require_command("xcrun")
    require_command("security")

    origin = strict_backend_origin()
    timeout = float(os.environ.get("QIXI_DEVICE_BRIDGE_TIMEOUT", "60"))
    settle_seconds = float(os.environ.get("QIXI_DEVICE_LAUNCH_SETTLE_SECONDS", "2"))
    derived_data = reject_symlink_components(
      normalized_path(os.environ.get("QIXI_DEVICE_DERIVED_DATA", str(DEFAULT_DERIVED_DATA))),
      "device bridge derived data path",
    )
    artifact_dir = reject_symlink_components(
      normalized_path(os.environ.get("QIXI_DEVICE_BRIDGE_ARTIFACT_DIR", str(DEFAULT_ARTIFACT_DIR))),
      "device bridge artifact path",
    )
    run_id = bridge_run_id()
    started_at = utc_timestamp()
    timings_ms: dict[str, int] = {}

    def run_timed(key: str, args: list[str], label: str) -> None:
      started_ns = time.monotonic_ns()
      run_command(args, label, timeout=timeout)
      timings_ms[key] = elapsed_ms(started_ns, time.monotonic_ns())

    static_project = device_preflight.read(device_preflight.PROJECT, "Xcode project for device bridge smoke")
    bundle_id = device_preflight.resolve_product_bundle_identifier(static_project)
    disable_icloud_entitlements = env_flag(DEVICE_DISABLE_ICLOUD_ENTITLEMENTS_ENV)
    validate_bridge_signing_overrides(bundle_id, disable_icloud_entitlements)
    plan_only = env_flag(DEVICE_BRIDGE_PLAN_ONLY_ENV)
    dry_run = env_flag(DEVICE_BRIDGE_DRY_RUN_ENV) or plan_only

    device_preflight.run_static_checks()
    device_preflight.check_iphoneos_sdk()
    launch_env = launch_environment(origin)
    backend_payload = device_preflight.check_backend_status(origin, float(os.environ.get("QIXI_DEVICE_BACKEND_TIMEOUT", "3")))
    backend_events_before: dict[str, Any] | None = None
    if not dry_run:
      backend_events_before = fetch_backend_events(origin, float(os.environ.get("QIXI_DEVICE_BACKEND_TIMEOUT", "3")))
    device_identifier, device_udid = selected_device()
    preflight_facts: dict[str, Any] = {
      "planOnly": plan_only,
      "strictPhysicalDeviceEnvironmentChecked": not plan_only,
      "signingBlockers": [],
      "notes": [],
    }
    if plan_only:
      validate_xcode_destination_for_device(device_udid)
    else:
      device_preflight.check_strict_physical_device_environment(static_project)
    development_team = os.environ.get(device_preflight.DEVICE_DEVELOPMENT_TEAM_ENV, "").strip() or None
    allow_provisioning_updates = device_preflight.provisioning_updates_allowed()
    if plan_only:
      team = development_team or device_preflight.resolve_development_team(static_project)
      blockers = collect_plan_only_signing_blockers(
        team,
        bundle_id,
        device_udid,
        allow_provisioning_updates=allow_provisioning_updates,
      )
      preflight_facts["signingBlockers"] = blockers
      if allow_provisioning_updates:
        preflight_facts["notes"].append(
          "QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES=1 is set, but plan-only mode does not run xcodebuild or create profiles."
        )

    artifact_dir.mkdir(parents=True, exist_ok=True)
    marker_ns = time.time_ns()
    xcode_args = build_xcodebuild_args(
      device_udid,
      derived_data,
      development_team,
      bundle_id=bundle_id,
      allow_provisioning_updates=allow_provisioning_updates,
      disable_icloud_entitlements=disable_icloud_entitlements,
    )
    if not dry_run:
      run_timed("build", xcode_args, "device xcodebuild")
    app_path = built_app_path(derived_data)
    app_facts = {"bundleIdentifier": bundle_id, "executable": "", "infoPlist": ""}
    if not dry_run:
      app_facts = validate_built_app(app_path, marker_ns, bundle_id)

    install_json = artifact_dir / "latest-device-install.json"
    launch_json = artifact_dir / "latest-device-launch.json"
    processes_json = artifact_dir / "latest-device-processes.json"
    displays_json = artifact_dir / "latest-device-displays.json"
    copy_json = artifact_dir / "latest-device-app-support-copy.json"
    backend_events_json = artifact_dir / "latest-backend-events.json"
    failure_backend_events_json = artifact_dir / "latest-device-bridge-failure-backend-events.json"
    manifest_path = artifact_dir / "latest-device-bridge-smoke.json"
    failure_manifest_path = artifact_dir / "latest-device-bridge-failure.json"
    app_support_dir = artifact_dir / "latest-app-support"
    commands = {
      "xcodebuild": xcode_args,
      "install": devicectl_install_args(device_identifier, app_path, install_json, timeout),
      "launch": devicectl_launch_args(device_identifier, bundle_id, launch_env, launch_json, timeout),
      "processes": devicectl_processes_args(device_identifier, processes_json, timeout),
      "displays": devicectl_displays_args(device_identifier, displays_json, timeout),
      "copyAppSupport": devicectl_copy_app_support_args(device_identifier, bundle_id, app_support_dir, copy_json, timeout),
    }
    if not dry_run:
      run_timed("install", commands["install"], "devicectl install")
      run_timed("launch", commands["launch"], "devicectl launch")
      settle_started_ns = time.monotonic_ns()
      time.sleep(settle_seconds)
      timings_ms["launchSettle"] = elapsed_ms(settle_started_ns, time.monotonic_ns())
      run_timed("processes", commands["processes"], "devicectl process listing")
      run_timed("displays", commands["displays"], "devicectl display info")
      run_timed("copyAppSupport", commands["copyAppSupport"], "devicectl app support copy")
      assert backend_events_before is not None
      backend_events_after = fetch_backend_events(origin, float(os.environ.get("QIXI_DEVICE_BACKEND_TIMEOUT", "3")))
      backend_events_payload = backend_events_artifact_payload(
        origin=origin,
        launch_environment=launch_env,
        before=backend_events_before,
        after=backend_events_after,
        diagnostic_hint=runtime_diagnostic_hint(app_support_dir),
      )
      if launch_env.get("QIXI_AUTOMATION_SELECT_ENGINE") and not backend_events_payload.get("observedExpectedEngine"):
        failure_message = backend_events_failure_message(backend_events_payload)
        write_manifest(failure_backend_events_json, backend_events_payload)
        failure_manifest = {
          "schemaVersion": 1,
          "kind": "qixi-device-bridge-smoke-failure",
          "runId": run_id,
          "generatedAt": utc_timestamp(),
          "startedAt": started_at,
          "completedAt": utc_timestamp(),
          "dryRun": dry_run,
          "device": {"identifier": device_identifier, "udid": device_udid},
          "backend": {"origin": origin, "status": backend_payload},
          "app": app_facts,
          "preflight": preflight_facts,
          "signing": {
            "developmentTeamOverride": development_team or "",
            "bundleIdentifier": bundle_id,
            "iCloudEntitlementsDisabledForLocalBridge": disable_icloud_entitlements,
          },
          "failure": {
            "stage": "backendEvents",
            "message": failure_message,
          },
          "artifacts": {
            "install": str(install_json),
            "launch": str(launch_json),
            "processes": str(processes_json),
            "displays": str(displays_json),
            "appSupport": str(app_support_dir),
            "appSupportCopy": str(copy_json),
            "backendEvents": str(failure_backend_events_json),
          },
          "commands": commands,
          "timingsMs": timings_ms,
        }
        write_manifest(failure_manifest_path, failure_manifest)
        write_manifest(manifest_path, failure_manifest)
        fail(failure_message)
      write_manifest(backend_events_json, backend_events_payload)

    manifest = {
      "schemaVersion": 1,
      "kind": "qixi-device-bridge-smoke",
      "runId": run_id,
      "generatedAt": utc_timestamp(),
      "startedAt": started_at,
      "completedAt": utc_timestamp(),
      "dryRun": dry_run,
      "device": {"identifier": device_identifier, "udid": device_udid},
      "backend": {"origin": origin, "status": backend_payload},
      "app": app_facts,
      "preflight": preflight_facts,
      "signing": {
        "developmentTeamOverride": development_team or "",
        "bundleIdentifier": bundle_id,
        "iCloudEntitlementsDisabledForLocalBridge": disable_icloud_entitlements,
      },
      "artifacts": {
        "install": str(install_json),
        "launch": str(launch_json),
        "processes": str(processes_json),
        "displays": str(displays_json),
        "appSupport": str(app_support_dir),
        "appSupportCopy": str(copy_json),
        "backendEvents": str(backend_events_json),
      },
      "commands": commands,
      "timingsMs": timings_ms,
    }
    write_manifest(manifest_path, manifest)
    print(f"Device bridge smoke passed: {manifest_path}")
    return 0
  except (DeviceBridgeSmokeError, device_preflight.DeviceRunPreflightError) as exc:
    print(f"Device bridge smoke failed: {exc}", file=sys.stderr)
    return 1


if __name__ == "__main__":
  raise SystemExit(main())
