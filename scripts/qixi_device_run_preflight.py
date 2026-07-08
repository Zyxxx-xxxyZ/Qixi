#!/usr/bin/env python3
from __future__ import annotations

import ipaddress
import json
import os
import pathlib
import plistlib
import re
import shutil
import stat as stat_module
import subprocess
import sys
import datetime
import hashlib
import urllib.error
import urllib.parse
import urllib.request


DEFAULT_ROOT = pathlib.Path(__file__).resolve().parents[1]
TEST_ROOT_ENV = "QIXI_DEVICE_PREFLIGHT_TEST_ROOT"
TESTING_ENV = "QIXI_DEVICE_PREFLIGHT_TESTING"
SOURCE_TEXT_MAX_BYTES = 4 * 1024 * 1024
PLIST_MAX_BYTES = 1 * 1024 * 1024
ALLOWED_PLATFORM_SYMLINK_ALIASES = {
  pathlib.Path("/var"): pathlib.Path("/private/var"),
  pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
  pathlib.Path("/etc"): pathlib.Path("/private/etc"),
}


class DeviceRunPreflightError(RuntimeError):
  pass


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


def reject_symlink_path(path: pathlib.Path, label: str) -> None:
  if path.is_symlink() and not is_allowed_platform_symlink_alias(path):
    raise DeviceRunPreflightError(f"{label} must not contain symbolic links: {path}")


def reject_symlink_components(path: pathlib.Path, label: str) -> pathlib.Path:
  candidate = normalized_path(path)
  current = pathlib.Path(candidate.anchor) if candidate.anchor else pathlib.Path()
  for part in candidate.parts:
    if part == candidate.anchor or not part:
      continue
    current = current / part
    reject_symlink_path(current, label)
  return candidate


def preflight_root() -> pathlib.Path:
  override = os.environ.get(TEST_ROOT_ENV, "").strip()
  if not override:
    return reject_symlink_components(DEFAULT_ROOT, "repository root")
  if os.environ.get(TESTING_ENV) != "1":
    raise DeviceRunPreflightError(f"{TEST_ROOT_ENV} may only be used with {TESTING_ENV}=1")
  return reject_symlink_components(pathlib.Path(override), "test repository root")


ROOT_INIT_ERROR: DeviceRunPreflightError | None = None
try:
  ROOT = preflight_root()
except DeviceRunPreflightError as exc:
  ROOT_INIT_ERROR = exc
  ROOT = DEFAULT_ROOT
NATIVE = ROOT / "qixi-ios-native"
SRC = NATIVE / "Qixi"
INFO = SRC / "Info.plist"
PROJECT = NATIVE / "Qixi.xcodeproj" / "project.pbxproj"
RUNBOOK = ROOT / "docs" / "native-ios-runbook.md"
QUALITY_DOC = ROOT / "docs" / "quality-gates.md"
STATUS_RESPONSE_MAX_BYTES = 64 * 1024
DEVICE_ID_ENV = "QIXI_DEVICE_ID"
DEVICE_DEVELOPMENT_TEAM_ENV = "QIXI_DEVICE_DEVELOPMENT_TEAM"
DEVICE_BUNDLE_ID_ENV = "QIXI_DEVICE_BUNDLE_ID"
DEVICE_DISABLE_ICLOUD_ENTITLEMENTS_ENV = "QIXI_DEVICE_DISABLE_ICLOUD_ENTITLEMENTS"
DEVICE_ALLOW_PROVISIONING_UPDATES_ENV = "QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES"
DEVICE_PROVISIONING_PROFILE_DIR_ENV = "QIXI_DEVICE_PROVISIONING_PROFILE_DIR"
DEVICE_XCODE_PROVISIONING_PROFILE_DIR_ENV = "QIXI_DEVICE_XCODE_PROVISIONING_PROFILE_DIR"
DEVICE_XCODE_ACCOUNT_PROBE_DERIVED_DATA_ENV = "QIXI_DEVICE_XCODE_ACCOUNT_PROBE_DERIVED_DATA"
DEVICE_IDENTIFIER_RE = re.compile(
  r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"
)
DEVICE_LIST_ROW_RE = re.compile(
  r"^\s*(?P<name>.*?)\s{2,}(?P<hostname>\S+)\s{2,}"
  r"(?P<identifier>[0-9A-Fa-f-]{36})\s{2,}(?P<state>.*?)\s{2,}(?P<model>.+?)\s*$"
)
DEVICE_LIST_IDENTIFIER_RE = re.compile(
  r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
DETAIL_PROBE_DEVICE_STATES = frozenset(("connected", "connected (no DDI)", "available (paired)"))
UNUSABLE_DEVICE_STATES = frozenset(("connecting", "unavailable"))
DEVICE_UDID_RE = re.compile(r"\budid:\s*([0-9A-Fa-f-]+)")
DEVELOPMENT_TEAM_RE = re.compile(r"\bDEVELOPMENT_TEAM\s*=\s*([^;]+);")
PRODUCT_BUNDLE_IDENTIFIER_RE = re.compile(r"\bPRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);")
BUNDLE_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$")
CODE_SIGNING_SHA1_RE = re.compile(r"\b[0-9A-Fa-f]{40}\b")


def display_path(path: pathlib.Path) -> str:
  try:
    return str(path.relative_to(ROOT))
  except ValueError:
    return str(path)


def validate_regular_file(path: pathlib.Path, label: str) -> pathlib.Path:
  checked_path = reject_symlink_components(path, label)
  if not checked_path.exists():
    raise DeviceRunPreflightError(f"missing {display_path(checked_path)}")
  if not checked_path.is_file():
    raise DeviceRunPreflightError(f"{label} is not a regular file: {checked_path}")
  return checked_path


def opened_regular_file_stat(handle, path: pathlib.Path, label: str) -> os.stat_result:
  try:
    opened_stat = os.fstat(handle.fileno())
  except OSError as exc:
    raise DeviceRunPreflightError(f"{label} could not be inspected after opening: {path}: {exc}") from exc
  if not stat_module.S_ISREG(opened_stat.st_mode):
    raise DeviceRunPreflightError(f"{label} must be a regular file after opening: {path}")
  return opened_stat


def bounded_bytes(path: pathlib.Path, label: str, max_bytes: int) -> bytes:
  if max_bytes <= 0:
    raise DeviceRunPreflightError(f"{label} has invalid byte budget")
  checked_path = validate_regular_file(path, label)
  try:
    file_stat = checked_path.stat()
  except OSError as exc:
    raise DeviceRunPreflightError(f"{label} could not be statted: {checked_path}: {exc}") from exc
  if file_stat.st_size > max_bytes:
    raise DeviceRunPreflightError(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {checked_path}")
  try:
    with checked_path.open("rb") as handle:
      opened_stat = opened_regular_file_stat(handle, checked_path, label)
      if opened_stat.st_size > max_bytes:
        raise DeviceRunPreflightError(
          f"{label} exceeds bounded size of {max_bytes} bytes after opening: {checked_path}"
        )
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    raise DeviceRunPreflightError(f"{label} could not be read: {checked_path}: {exc}") from exc
  if len(data) > max_bytes:
    raise DeviceRunPreflightError(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {checked_path}")
  return data


def read(path: pathlib.Path, label: str | None = None) -> str:
  label = label or f"file {display_path(path)}"
  try:
    return bounded_bytes(path, label, SOURCE_TEXT_MAX_BYTES).decode("utf-8")
  except UnicodeDecodeError as exc:
    raise DeviceRunPreflightError(f"{label} must be UTF-8: {path}: {exc}") from exc


def load_plist(path: pathlib.Path, label: str | None = None) -> dict:
  label = label or f"plist {display_path(path)}"
  try:
    payload = plistlib.loads(bounded_bytes(path, label, PLIST_MAX_BYTES))
  except Exception as exc:
    if isinstance(exc, DeviceRunPreflightError):
      raise
    raise DeviceRunPreflightError(f"invalid plist {display_path(path)}: {exc}") from exc
  if not isinstance(payload, dict):
    raise DeviceRunPreflightError(f"{label} must be a dictionary: {path}")
  return payload


def host_is_loopback_or_unspecified(host: str) -> bool:
  normalized = host.strip("[]").lower()
  if normalized in {"localhost", "localhost.localdomain"} or normalized.endswith(".localhost"):
    return True
  try:
    address = ipaddress.ip_address(normalized)
  except ValueError:
    return False
  return address.is_loopback or address.is_unspecified


def validate_physical_device_backend_url(raw_url: str) -> str:
  parsed = urllib.parse.urlparse(raw_url)
  if parsed.scheme not in {"http", "https"}:
    raise DeviceRunPreflightError("QIXI_DEVICE_BACKEND_URL must use http or https")
  if not parsed.netloc or not parsed.hostname:
    raise DeviceRunPreflightError("QIXI_DEVICE_BACKEND_URL must include a host")
  if host_is_loopback_or_unspecified(parsed.hostname):
    raise DeviceRunPreflightError("physical-device backend URL must not use localhost or loopback")
  if parsed.path not in {"", "/"}:
    raise DeviceRunPreflightError("QIXI_DEVICE_BACKEND_URL should be the backend origin, not a nested endpoint")
  return urllib.parse.urlunparse((parsed.scheme, parsed.netloc, "", "", "", ""))


def status_url_for(origin: str) -> str:
  return urllib.parse.urljoin(origin.rstrip("/") + "/", "/api/status")


def load_status_json(body: bytes, label: str) -> dict:
  def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    result: dict[str, object] = {}
    for key, value in pairs:
      if key in result:
        raise DeviceRunPreflightError(f"{label} must not contain duplicate JSON key {key!r}")
      result[key] = value
    return result

  def reject_non_standard_constant(value: str) -> None:
    raise DeviceRunPreflightError(f"{label} must not contain non-standard JSON constant {value}")

  try:
    payload = json.loads(
      body.decode("utf-8"),
      object_pairs_hook=reject_duplicate_keys,
      parse_constant=reject_non_standard_constant,
    )
  except DeviceRunPreflightError:
    raise
  except Exception as exc:
    raise DeviceRunPreflightError(f"{label} did not return JSON: {exc}") from exc
  if not isinstance(payload, dict):
    raise DeviceRunPreflightError(f"{label} status payload must be a JSON object")
  return payload


def check_backend_status(origin: str, timeout: float) -> dict:
  url = status_url_for(origin)
  request = urllib.request.Request(url, headers={"Accept": "application/json"})
  try:
    with urllib.request.urlopen(request, timeout=timeout) as response:
      content_type = response.headers.get("Content-Type", "")
      media_type = content_type.split(";", 1)[0].strip().lower()
      if media_type != "application/json":
        raise DeviceRunPreflightError(
          f"{url} must return application/json, got {content_type or '(missing Content-Type)'}"
        )
      body = response.read(STATUS_RESPONSE_MAX_BYTES + 1)
  except urllib.error.URLError as exc:
    raise DeviceRunPreflightError(f"cannot reach {url}: {exc}") from exc
  if len(body) > STATUS_RESPONSE_MAX_BYTES:
    raise DeviceRunPreflightError(
      f"{url} status response is too large: exceeds {STATUS_RESPONSE_MAX_BYTES} bytes"
    )
  payload = load_status_json(body, url)
  for key in ("engine", "engineId", "state", "running", "paused"):
    if key not in payload:
      raise DeviceRunPreflightError(f"{url} status payload is missing {key!r}")
  for key in ("engine", "engineId", "state"):
    if not isinstance(payload[key], str) or not payload[key].strip():
      raise DeviceRunPreflightError(f"{url} status payload field {key!r} must be a non-empty string")
  for key in ("running", "paused"):
    if not isinstance(payload[key], bool):
      raise DeviceRunPreflightError(f"{url} status payload field {key!r} must be a boolean")
  if payload["state"] not in {"ready", "running", "paused"}:
    raise DeviceRunPreflightError(f"{url} status payload has unexpected state {payload['state']!r}")
  return payload


def require_command(name: str) -> None:
  if shutil.which(name) is None:
    raise DeviceRunPreflightError(f"{name} is required for strict physical-device preflight")


def command_output(args: list[str], label: str, timeout: float = 15) -> str:
  try:
    result = subprocess.run(
      args,
      text=True,
      capture_output=True,
      timeout=timeout,
      check=False,
    )
  except FileNotFoundError as exc:
    raise DeviceRunPreflightError(f"{args[0]} is required for strict physical-device preflight") from exc
  except subprocess.TimeoutExpired as exc:
    raise DeviceRunPreflightError(f"{label} timed out after {timeout:g}s") from exc
  if result.returncode != 0:
    detail = (result.stderr.strip() or result.stdout.strip())[:4000]
    raise DeviceRunPreflightError(f"{label} failed: {detail}")
  return result.stdout


def check_iphoneos_sdk() -> None:
  require_command("xcodebuild")
  result = subprocess.run(
    ["xcodebuild", "-showsdks"],
    text=True,
    capture_output=True,
    check=False,
  )
  if result.returncode != 0:
    raise DeviceRunPreflightError(
      f"xcodebuild -showsdks failed: {result.stderr.strip() or result.stdout.strip()}"
    )
  if "iphoneos" not in result.stdout.lower():
    raise DeviceRunPreflightError("xcodebuild does not report an iphoneos SDK")


def devicectl_device_rows_from_list(output: str) -> list[dict[str, str]]:
  rows: list[dict[str, str]] = []
  for line in output.splitlines():
    match = DEVICE_LIST_ROW_RE.match(line)
    if match is None:
      continue
    identifier = match.group("identifier").strip()
    if DEVICE_LIST_IDENTIFIER_RE.match(identifier) is None:
      continue
    rows.append(
      {
        "name": match.group("name").strip(),
        "hostname": match.group("hostname").strip(),
        "identifier": identifier,
        "state": match.group("state").strip(),
        "model": match.group("model").strip(),
      }
    )
  return rows


def connected_device_identifiers_from_devicectl_list(output: str) -> list[str]:
  identifiers: list[str] = []
  for row in devicectl_device_rows_from_list(output):
    state = row["state"]
    if state != "connected":
      continue
    identifiers.append(row["identifier"])
  return identifiers


def detail_probe_device_identifiers_from_devicectl_list(output: str) -> list[str]:
  identifiers: list[str] = []
  for row in devicectl_device_rows_from_list(output):
    state = row["state"]
    if state in UNUSABLE_DEVICE_STATES:
      continue
    if state not in DETAIL_PROBE_DEVICE_STATES:
      continue
    identifiers.append(row["identifier"])
  return identifiers


def devicectl_device_state_summary_from_list(output: str) -> str:
  rows = devicectl_device_rows_from_list(output)
  if not rows:
    return "no parseable iPad/iPhone rows"
  summaries: list[str] = []
  for row in rows:
    summaries.append(
      f"{row['name'] or '(unnamed device)'} [{row['state']}] "
      f"{row['identifier']} {row['model']}"
    )
  return "; ".join(summaries)


def require_devicectl_identifier_detail_probeable(output: str, identifier: str) -> str:
  rows = devicectl_device_rows_from_list(output)
  for row in rows:
    if row["identifier"] != identifier:
      continue
    state = row["state"]
    if state in UNUSABLE_DEVICE_STATES or state not in DETAIL_PROBE_DEVICE_STATES:
      raise DeviceRunPreflightError(
        f"{DEVICE_ID_ENV} selected device is not probeable by devicectl device details, got state {state!r}; "
        f"visible devices: {devicectl_device_state_summary_from_list(output)}"
      )
    return identifier
  raise DeviceRunPreflightError(
    f"{DEVICE_ID_ENV} selected device is not visible to devicectl list devices: {identifier}; "
    f"visible devices: {devicectl_device_state_summary_from_list(output)}"
  )


def select_physical_device_identifier() -> str:
  explicit = os.environ.get(DEVICE_ID_ENV, "").strip()
  output = command_output(["xcrun", "devicectl", "list", "devices"], "devicectl device list")
  if explicit:
    return require_devicectl_identifier_detail_probeable(output, explicit)
  identifiers = detail_probe_device_identifiers_from_devicectl_list(output)
  if not identifiers:
    raise DeviceRunPreflightError(
      f"strict physical-device preflight requires a detail-probeable iPad or iPhone visible to devicectl; "
      f"set {DEVICE_ID_ENV}=<devicectl-identifier> if auto-selection is ambiguous; "
      f"visible devices: {devicectl_device_state_summary_from_list(output)}"
    )
  if len(identifiers) > 1:
    raise DeviceRunPreflightError(
      f"strict physical-device preflight found multiple detail-probeable devices; set {DEVICE_ID_ENV}=<devicectl-identifier>; "
      f"visible devices: {devicectl_device_state_summary_from_list(output)}"
    )
  return identifiers[0]


def validated_physical_device_udid(device_details: str) -> str:
  if "reality: physical" not in device_details:
    raise DeviceRunPreflightError("strict physical-device preflight selected device must be physical hardware")
  if "developerModeStatus: enabled" not in device_details:
    raise DeviceRunPreflightError("strict physical-device preflight requires Developer Mode enabled on the iPad/iPhone")
  if "ddiServicesAvailable: true" not in device_details:
    raise DeviceRunPreflightError(
      "strict physical-device preflight requires Developer Disk Image services available on the iPad/iPhone"
    )
  if not any(needle in device_details for needle in ("tunnelState: connected", "transportType: usb", "transportType: wired")):
    raise DeviceRunPreflightError("strict physical-device preflight requires an active CoreDevice transport")
  if "Install Application (" not in device_details:
    raise DeviceRunPreflightError("strict physical-device preflight requires devicectl Install Application capability")
  if "Launch Application (" not in device_details:
    raise DeviceRunPreflightError("strict physical-device preflight requires devicectl Launch Application capability")
  match = DEVICE_UDID_RE.search(device_details)
  if match is None:
    raise DeviceRunPreflightError("strict physical-device preflight could not read the physical device UDID")
  return match.group(1)


def xcode_destinations_include_device(output: str, udid: str) -> bool:
  needle = f"id:{udid}"
  return any("{ platform:iOS," in line and needle in line for line in output.splitlines())


def project_development_teams(project_text: str) -> list[str]:
  teams: list[str] = []
  for raw_team in DEVELOPMENT_TEAM_RE.findall(project_text):
    team = raw_team.strip().strip('"')
    if team and team not in teams:
      teams.append(team)
  return teams


def project_bundle_identifiers(project_text: str) -> list[str]:
  bundle_ids: list[str] = []
  for raw_bundle_id in PRODUCT_BUNDLE_IDENTIFIER_RE.findall(project_text):
    bundle_id = raw_bundle_id.strip().strip('"')
    if bundle_id and bundle_id not in bundle_ids:
      bundle_ids.append(bundle_id)
  return bundle_ids


def validate_bundle_identifier(value: str, label: str) -> str:
  bundle_id = value.strip()
  if not bundle_id:
    raise DeviceRunPreflightError(f"{label} must not be empty")
  if len(bundle_id) > 255:
    raise DeviceRunPreflightError(f"{label} is too long")
  if not BUNDLE_IDENTIFIER_RE.fullmatch(bundle_id):
    raise DeviceRunPreflightError(
      f"{label} must be a concrete reverse-DNS bundle identifier with non-empty alphanumeric segments"
    )
  return bundle_id


def resolve_product_bundle_identifier(project_text: str) -> str:
  explicit = os.environ.get(DEVICE_BUNDLE_ID_ENV, "").strip()
  if explicit:
    return validate_bundle_identifier(explicit, DEVICE_BUNDLE_ID_ENV)
  bundle_ids = project_bundle_identifiers(project_text)
  if len(bundle_ids) == 1:
    return validate_bundle_identifier(bundle_ids[0], "PRODUCT_BUNDLE_IDENTIFIER")
  if not bundle_ids:
    raise DeviceRunPreflightError("strict physical-device preflight requires PRODUCT_BUNDLE_IDENTIFIER")
  raise DeviceRunPreflightError(
    "strict physical-device preflight found multiple PRODUCT_BUNDLE_IDENTIFIER values"
  )


def resolve_development_team(project_text: str) -> str:
  explicit = os.environ.get(DEVICE_DEVELOPMENT_TEAM_ENV, "").strip()
  if explicit:
    return explicit
  teams = project_development_teams(project_text)
  if len(teams) == 1:
    return teams[0]
  if not teams:
    raise DeviceRunPreflightError(
      f"strict physical-device preflight requires DEVELOPMENT_TEAM; set {DEVICE_DEVELOPMENT_TEAM_ENV}=<team-id> "
      "or configure Xcode Signing & Capabilities"
    )
  raise DeviceRunPreflightError(
    f"strict physical-device preflight found multiple DEVELOPMENT_TEAM values; set {DEVICE_DEVELOPMENT_TEAM_ENV}=<team-id>"
  )


def apple_development_identities(identity_output: str) -> list[str]:
  return [
    line.strip()
    for line in identity_output.splitlines()
    if "Apple Development:" in line and "CSSMERR_TP_CERT_REVOKED" not in line
  ]


def apple_development_team_identifier(identity: str) -> str | None:
  if "(" not in identity or ")" not in identity:
    return None
  candidate = identity.rsplit("(", 1)[1].split(")", 1)[0].strip()
  return candidate or None


def apple_development_team_identifiers(identity_output: str) -> list[str]:
  teams: list[str] = []
  for identity in apple_development_identities(identity_output):
    team = apple_development_team_identifier(identity)
    if team and team not in teams:
      teams.append(team)
  return teams


def apple_development_identity_sha1s(identity_output: str) -> set[str]:
  sha1s: set[str] = set()
  for identity in apple_development_identities(identity_output):
    match = CODE_SIGNING_SHA1_RE.search(identity)
    if match:
      sha1s.add(match.group(0).upper())
  return sha1s


def profile_developer_certificate_sha1s(payload: dict) -> list[str]:
  certificates = payload.get("DeveloperCertificates")
  if not isinstance(certificates, list):
    return []
  sha1s: list[str] = []
  for certificate in certificates:
    if isinstance(certificate, bytes):
      data = certificate
    elif isinstance(certificate, bytearray):
      data = bytes(certificate)
    else:
      try:
        data = bytes(certificate)
      except Exception:
        continue
    sha1 = hashlib.sha1(data).hexdigest().upper()
    if sha1 not in sha1s:
      sha1s.append(sha1)
  return sha1s


def profile_installed_developer_certificate_sha1s(payload: dict, identity_output: str) -> list[str]:
  installed_sha1s = apple_development_identity_sha1s(identity_output)
  return [sha1 for sha1 in profile_developer_certificate_sha1s(payload) if sha1 in installed_sha1s]


def profile_has_installed_development_certificate(payload: dict, identity_output: str) -> bool:
  return bool(profile_installed_developer_certificate_sha1s(payload, identity_output))


def check_apple_development_identity(
  team: str | None,
  identity_output: str,
  profile_payload: dict | None = None,
) -> None:
  identities = apple_development_identities(identity_output)
  if not identities:
    raise DeviceRunPreflightError(
      "strict physical-device preflight found no Apple Development code-signing identities in the login keychain"
    )
  if team and any(f"({team})" in identity for identity in identities):
    return
  if team and profile_payload is not None and profile_has_installed_development_certificate(profile_payload, identity_output):
    return
  if team:
    available_teams = apple_development_team_identifiers(identity_output)
    available_suffix = ""
    if available_teams:
      available_suffix = "; available Apple Development team identifiers on this Mac: " + ", ".join(available_teams)
    raise DeviceRunPreflightError(
      f"strict physical-device preflight found no Apple Development code-signing identity for team {team}"
      f"{available_suffix}"
    )


def provisioning_updates_allowed(environment: dict[str, str] | None = None) -> bool:
  env = environment or os.environ
  return env.get(DEVICE_ALLOW_PROVISIONING_UPDATES_ENV, "").strip().lower() in {
    "1",
    "true",
    "yes",
    "y",
    "on",
  }


def icloud_entitlements_disabled(environment: dict[str, str] | None = None) -> bool:
  env = environment or os.environ
  return env.get(DEVICE_DISABLE_ICLOUD_ENTITLEMENTS_ENV, "").strip().lower() in {
    "1",
    "true",
    "yes",
    "y",
    "on",
  }


def provisioning_profile_directory(environment: dict[str, str] | None = None) -> pathlib.Path:
  directories = provisioning_profile_directories(environment)
  return directories[0]


def provisioning_profile_directories(environment: dict[str, str] | None = None) -> list[pathlib.Path]:
  env = environment or os.environ
  override = env.get(DEVICE_PROVISIONING_PROFILE_DIR_ENV, "").strip()
  if override:
    return [reject_symlink_components(pathlib.Path(override), "device provisioning profile directory")]
  candidates = [
    pathlib.Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles",
  ]
  xcode_override = env.get(DEVICE_XCODE_PROVISIONING_PROFILE_DIR_ENV, "").strip()
  if xcode_override:
    candidates.append(pathlib.Path(xcode_override))
  else:
    candidates.append(pathlib.Path.home() / "Library" / "Developer" / "Xcode" / "UserData" / "Provisioning Profiles")
  directories: list[pathlib.Path] = []
  seen: set[pathlib.Path] = set()
  for candidate in candidates:
    checked = reject_symlink_components(candidate, "device provisioning profile directory")
    if checked in seen:
      continue
    seen.add(checked)
    directories.append(checked)
  return directories


def decode_mobileprovision(path: pathlib.Path) -> dict:
  try:
    raw = bounded_bytes(path, "iOS provisioning profile", PLIST_MAX_BYTES)
  except DeviceRunPreflightError:
    raise
  try:
    payload = plistlib.loads(raw)
  except Exception:
    result = subprocess.run(
      ["security", "cms", "-D", "-i", str(path)],
      text=False,
      capture_output=True,
      check=False,
    )
    if result.returncode != 0:
      raise DeviceRunPreflightError(
        f"could not decode iOS provisioning profile {path}: {result.stderr.decode('utf-8', errors='replace').strip()}"
      )
    try:
      payload = plistlib.loads(result.stdout)
    except Exception as exc:
      raise DeviceRunPreflightError(f"decoded iOS provisioning profile is not a plist: {path}: {exc}") from exc
  if not isinstance(payload, dict):
    raise DeviceRunPreflightError(f"decoded iOS provisioning profile must be a dictionary: {path}")
  return payload


def provisioning_profile_matches(
  payload: dict,
  *,
  team: str,
  bundle_id: str,
  device_udid: str,
  now: datetime.datetime | None = None,
) -> bool:
  return not provisioning_profile_match_failures(
    payload,
    team=team,
    bundle_id=bundle_id,
    device_udid=device_udid,
    now=now,
  )


def provisioning_profile_match_failures(
  payload: dict,
  *,
  team: str,
  bundle_id: str,
  device_udid: str,
  now: datetime.datetime | None = None,
) -> list[str]:
  failures: list[str] = []
  now = now or datetime.datetime.now(datetime.timezone.utc)
  team_identifiers = payload.get("TeamIdentifier")
  if not isinstance(team_identifiers, list) or team not in team_identifiers:
    failures.append(f"team {team} is not listed in TeamIdentifier")
  expiration = payload.get("ExpirationDate")
  if not isinstance(expiration, datetime.datetime):
    failures.append("ExpirationDate is missing or not a date")
  else:
    normalized_expiration = expiration
    if normalized_expiration.tzinfo is None:
      normalized_expiration = normalized_expiration.replace(tzinfo=datetime.timezone.utc)
    if normalized_expiration <= now:
      failures.append("profile is expired")
  provisioned_devices = payload.get("ProvisionedDevices")
  if not isinstance(provisioned_devices, list) or device_udid not in provisioned_devices:
    failures.append(f"device {device_udid} is not listed in ProvisionedDevices")
  entitlements = payload.get("Entitlements")
  if not isinstance(entitlements, dict):
    failures.append("Entitlements is missing or not a dictionary")
  else:
    application_identifier = entitlements.get("application-identifier")
    if not isinstance(application_identifier, str):
      failures.append("application-identifier entitlement is missing")
    elif application_identifier not in {f"{team}.{bundle_id}", f"{team}.*"}:
      failures.append(
        f"application-identifier {application_identifier!r} does not match {team}.{bundle_id} or {team}.*"
      )
  return failures


def find_matching_development_profile_payload(
  team: str,
  bundle_id: str,
  device_udid: str,
) -> tuple[pathlib.Path, dict] | None:
  for profile_dir in provisioning_profile_directories():
    if not profile_dir.exists():
      continue
    if not profile_dir.is_dir():
      raise DeviceRunPreflightError(f"device provisioning profile path is not a directory: {profile_dir}")
    for profile_path in sorted(profile_dir.glob("*.mobileprovision")):
      checked_profile = reject_symlink_components(profile_path, "iOS provisioning profile")
      if not checked_profile.is_file():
        continue
      try:
        payload = decode_mobileprovision(checked_profile)
      except DeviceRunPreflightError:
        continue
      if provisioning_profile_matches(payload, team=team, bundle_id=bundle_id, device_udid=device_udid):
        return checked_profile, payload
  return None


def find_matching_development_profile(team: str, bundle_id: str, device_udid: str) -> pathlib.Path | None:
  match = find_matching_development_profile_payload(team, bundle_id, device_udid)
  if match is None:
    return None
  return match[0]


def check_development_provisioning_profile(team: str, bundle_id: str, device_udid: str) -> None:
  if provisioning_updates_allowed():
    return
  profile = find_matching_development_profile_payload(team, bundle_id, device_udid)
  if profile is not None:
    return
  raise DeviceRunPreflightError(
    "strict physical-device preflight found no installed iOS App Development provisioning profile "
    f"for team {team}, bundle {bundle_id}, and device {device_udid}; "
    f"install a matching profile or set {DEVICE_ALLOW_PROVISIONING_UPDATES_ENV}=1 after adding a valid Xcode account"
  )


def xcode_account_probe_problem_messages(output: str) -> list[str]:
  problem_needles = (
    "DVTDeveloperAccountManager",
    "Failed to load credentials",
    "Invalid credentials",
    "missing Xcode-Username",
    "No Account for Team",
    "No Accounts",
    "No profiles for",
    "There are no accounts registered with Xcode",
    "requires a development team",
    "authentication",
  )
  problems: list[str] = []
  for raw_line in output.splitlines():
    line = raw_line.strip()
    if not line:
      continue
    if any(needle in line for needle in problem_needles) and line not in problems:
      problems.append(line[:800])
  return problems


def xcode_account_probe_derived_data_path() -> pathlib.Path:
  override = os.environ.get(DEVICE_XCODE_ACCOUNT_PROBE_DERIVED_DATA_ENV, "").strip()
  if override:
    return reject_symlink_components(pathlib.Path(override), "Xcode account probe derived data path")
  return pathlib.Path("/private/tmp/qixi-device-signing-doctor-xcode-account-probe")


def run_xcode_automatic_provisioning_probe(
  team: str,
  device_udid: str,
  *,
  bundle_id: str | None = None,
  disable_icloud_entitlements: bool = False,
  timeout: float = 120,
) -> dict:
  derived_data = xcode_account_probe_derived_data_path()
  args = [
    "xcodebuild",
    "-project",
    str(NATIVE / "Qixi.xcodeproj"),
    "-scheme",
    "Qixi",
    "-destination",
    f"id={device_udid}",
    "-configuration",
    "Debug",
    "-derivedDataPath",
    str(derived_data),
    "-allowProvisioningUpdates",
    "-allowProvisioningDeviceRegistration",
    "build",
    f"DEVELOPMENT_TEAM={team}",
  ]
  if bundle_id:
    args.append(f"PRODUCT_BUNDLE_IDENTIFIER={bundle_id}")
  if disable_icloud_entitlements:
    args.append("CODE_SIGN_ENTITLEMENTS=")
  try:
    result = subprocess.run(
      args,
      text=True,
      capture_output=True,
      timeout=timeout,
      check=False,
    )
  except FileNotFoundError as exc:
    return {
      "checked": True,
      "ok": False,
      "returnCode": None,
      "action": "build",
      "derivedData": str(derived_data),
      "problems": [f"xcodebuild is required for automatic provisioning account probe: {exc}"],
    }
  except subprocess.TimeoutExpired:
    return {
      "checked": True,
      "ok": False,
      "returnCode": None,
      "action": "build",
      "derivedData": str(derived_data),
      "problems": [f"xcodebuild automatic provisioning probe timed out after {timeout:g}s"],
    }
  combined_output = "\n".join(part for part in (result.stderr, result.stdout) if part)
  problems = xcode_account_probe_problem_messages(combined_output)
  if result.returncode != 0:
    detail = (result.stderr.strip() or result.stdout.strip())[:1200]
    problems.insert(0, f"xcodebuild automatic provisioning probe exited with {result.returncode}: {detail}")
  return {
    "checked": True,
    "ok": not problems,
    "returnCode": result.returncode,
    "action": "build",
    "derivedData": str(derived_data),
    "problems": problems,
  }


def check_xcode_automatic_provisioning_account(team: str, device_udid: str, bundle_id: str | None = None) -> None:
  if not provisioning_updates_allowed():
    return
  probe = run_xcode_automatic_provisioning_probe(
    team,
    device_udid,
    bundle_id=bundle_id,
    disable_icloud_entitlements=icloud_entitlements_disabled(),
  )
  if probe.get("ok") is True:
    return
  problems = probe.get("problems")
  if not isinstance(problems, list) or not problems:
    problems = ["Xcode automatic provisioning account probe reported an unknown failure"]
  raise DeviceRunPreflightError(
    "automatic provisioning was requested, but Xcode account credentials are not usable for this team: "
    + "; ".join(str(problem) for problem in problems[:3])
  )


def check_strict_physical_device_environment(project_text: str) -> None:
  require_command("xcrun")
  require_command("xcodebuild")
  require_command("security")

  device_identifier = select_physical_device_identifier()
  device_details = command_output(
    ["xcrun", "devicectl", "device", "info", "details", "--device", device_identifier],
    "devicectl device details",
  )
  device_udid = validated_physical_device_udid(device_details)
  destinations = command_output(
    ["xcodebuild", "-project", str(NATIVE / "Qixi.xcodeproj"), "-scheme", "Qixi", "-showdestinations"],
    "xcodebuild destination discovery",
  )
  if not xcode_destinations_include_device(destinations, device_udid):
    raise DeviceRunPreflightError(
      f"strict physical-device preflight could not find iOS destination id:{device_udid} for the Qixi scheme"
    )

  errors: list[str] = []
  team: str | None = None
  bundle_id: str | None = None
  try:
    team = resolve_development_team(project_text)
  except DeviceRunPreflightError as exc:
    errors.append(str(exc))
  try:
    bundle_id = resolve_product_bundle_identifier(project_text)
  except DeviceRunPreflightError as exc:
    errors.append(str(exc))
  matching_profile: tuple[pathlib.Path, dict] | None = None
  if team and bundle_id:
    try:
      matching_profile = find_matching_development_profile_payload(team, bundle_id, device_udid)
    except DeviceRunPreflightError as exc:
      errors.append(str(exc))
  identity_output = command_output(["security", "find-identity", "-v", "-p", "codesigning"], "code-signing identity lookup")
  try:
    check_apple_development_identity(team, identity_output, matching_profile[1] if matching_profile else None)
  except DeviceRunPreflightError as exc:
    errors.append(str(exc))
  if team and bundle_id:
    if not provisioning_updates_allowed() and matching_profile is None:
      errors.append(
        "strict physical-device preflight found no installed iOS App Development provisioning profile "
        f"for team {team}, bundle {bundle_id}, and device {device_udid}; "
        f"install a matching profile or set {DEVICE_ALLOW_PROVISIONING_UPDATES_ENV}=1 after adding a valid Xcode account"
      )
  if team and provisioning_updates_allowed():
    try:
      check_xcode_automatic_provisioning_account(team, device_udid, bundle_id)
    except DeviceRunPreflightError as exc:
      errors.append(str(exc))
  if errors:
    raise DeviceRunPreflightError("; ".join(errors))
  print(f"Device signing preflight passed: udid={device_udid} team={team} bundle={bundle_id}")


def check_real_model_backend_files() -> None:
  binary = pathlib.Path(
    os.environ.get("QIXI_KATAGO_BIN", ROOT / "KataGo" / "cpp" / "build-metal-mux" / "katago")
  ).expanduser()
  config = pathlib.Path(
    os.environ.get("QIXI_KATAGO_CONFIG", ROOT / "KataGo" / "cpp" / "configs" / "analysis_example.cfg")
  ).expanduser()
  override = pathlib.Path(ROOT / "qixi-ios-sim" / "configs" / "metal-mux.override")
  model_paths = [
    pathlib.Path(
      os.environ.get(
        "QIXI_KATAGO_MODEL_B6",
        ROOT / "KataGo" / "cpp" / "tests" / "models" / "g170-b6c96-s175395328-d26788732.bin.gz",
      )
    ).expanduser(),
    pathlib.Path(os.environ.get("QIXI_KATAGO_MODEL_B18NBT", ROOT / "b18nbt.bin")).expanduser(),
    pathlib.Path(os.environ.get("QIXI_KATAGO_MODEL_B28NBT", ROOT / "b28nbt.bin")).expanduser(),
  ]
  if not binary.exists():
    raise DeviceRunPreflightError(f"QIXI_DEVICE_REQUIRE_REAL_MODELS=1 but KataGo binary is missing: {binary}")
  if not os.access(binary, os.X_OK):
    raise DeviceRunPreflightError(f"QIXI_DEVICE_REQUIRE_REAL_MODELS=1 but KataGo binary is not executable: {binary}")
  for path in [config, override, *model_paths]:
    if not path.exists():
      raise DeviceRunPreflightError(f"QIXI_DEVICE_REQUIRE_REAL_MODELS=1 but required file is missing: {path}")
  print("Device real-model backend file check passed")


def run_static_checks() -> None:
  info = load_plist(INFO)
  project = read(PROJECT)
  runbook = read(RUNBOOK)
  quality_doc = read(QUALITY_DOC)

  if info.get("QixiAnalysisRuntime") != "httpBridge":
    raise DeviceRunPreflightError(
      "development device run preflight expects QixiAnalysisRuntime=httpBridge until native KataGo is linked"
    )
  if info.get("QixiBackendBaseURL") != "http://127.0.0.1:8765":
    raise DeviceRunPreflightError(
      "simulator default backend URL should stay explicit; physical devices must override it with QIXI_DEVICE_BACKEND_URL"
    )
  ats = info.get("NSAppTransportSecurity")
  if not isinstance(ats, dict) or ats.get("NSAllowsLocalNetworking") is not True:
    raise DeviceRunPreflightError("Info.plist must allow local networking for physical-device backend smoke tests")
  if not info.get("NSLocalNetworkUsageDescription"):
    raise DeviceRunPreflightError("Info.plist must explain local-network access")
  if "TARGETED_DEVICE_FAMILY = \"1,2\";" not in project:
    raise DeviceRunPreflightError("project must target both iPhone and iPad")
  if "SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";" not in project:
    raise DeviceRunPreflightError("project must build for iphoneos and iphonesimulator")
  if "scripts/qixi-device-run-preflight.sh" not in runbook:
    raise DeviceRunPreflightError("native iOS runbook must document the device run preflight")
  if "QIXI_DEVICE_STRICT=1" not in runbook or "QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765" not in runbook:
    raise DeviceRunPreflightError("native iOS runbook must show strict non-loopback device preflight usage")
  if "Device run preflight" not in quality_doc:
    raise DeviceRunPreflightError("quality-gates doc must describe the device run preflight")


def main() -> int:
  strict = os.environ.get("QIXI_DEVICE_STRICT", "0") == "1"
  backend_url = os.environ.get("QIXI_DEVICE_BACKEND_URL", "").strip()
  timeout = float(os.environ.get("QIXI_DEVICE_BACKEND_TIMEOUT", "3"))
  require_real_models = os.environ.get("QIXI_DEVICE_REQUIRE_REAL_MODELS", "0") == "1"

  try:
    if ROOT_INIT_ERROR is not None:
      raise ROOT_INIT_ERROR
    run_static_checks()

    if strict:
      if not backend_url:
        raise DeviceRunPreflightError(
          "strict physical-device preflight requires QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765"
        )
      check_iphoneos_sdk()
      check_strict_physical_device_environment(read(PROJECT, "Xcode project for strict physical-device preflight"))

    if backend_url:
      origin = validate_physical_device_backend_url(backend_url)
      payload = check_backend_status(origin, timeout)
      print(
        f"Device backend live check passed: {status_url_for(origin)} "
        f"engineId={payload['engineId']} state={payload['state']}"
      )
    else:
      print("Skipping live device backend check. Set QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 to enable it.")

    if require_real_models:
      check_real_model_backend_files()

  except DeviceRunPreflightError as exc:
    print(f"Device run preflight failed: {exc}", file=sys.stderr)
    return 1

  print("Device run preflight passed")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
