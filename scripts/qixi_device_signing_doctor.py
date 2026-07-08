#!/usr/bin/env python3
from __future__ import annotations

import datetime
import json
import os
import pathlib
import sys
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import qixi_device_run_preflight as preflight


PROFILE_SCAN_LIMIT = 200
VISIBLE_DEVICE_DETAIL_SCAN_LIMIT = 8
VISIBLE_DEVICE_DETAIL_TIMEOUT_SECONDS = 5


def iso_datetime(value: object) -> str | None:
  if not isinstance(value, datetime.datetime):
    return None
  normalized = value
  if normalized.tzinfo is None:
    normalized = normalized.replace(tzinfo=datetime.timezone.utc)
  return normalized.isoformat().replace("+00:00", "Z")


def profile_summary(
  path: pathlib.Path,
  payload: dict[str, Any],
  *,
  team: str,
  bundle_id: str,
  device_udid: str,
  identity_output: str | None = None,
  now: datetime.datetime | None = None,
) -> dict[str, Any]:
  entitlements = payload.get("Entitlements")
  application_identifier: object = None
  if isinstance(entitlements, dict):
    application_identifier = entitlements.get("application-identifier")
  team_identifiers = payload.get("TeamIdentifier")
  provisioned_devices = payload.get("ProvisionedDevices")
  failures = preflight.provisioning_profile_match_failures(
    payload,
    team=team,
    bundle_id=bundle_id,
    device_udid=device_udid,
    now=now,
  )
  developer_certificate_sha1s = preflight.profile_developer_certificate_sha1s(payload)
  installed_certificate_sha1s = (
    preflight.profile_installed_developer_certificate_sha1s(payload, identity_output)
    if identity_output is not None
    else []
  )
  return {
    "path": str(path),
    "name": payload.get("Name") if isinstance(payload.get("Name"), str) else "",
    "uuid": payload.get("UUID") if isinstance(payload.get("UUID"), str) else "",
    "teamIdentifiers": team_identifiers if isinstance(team_identifiers, list) else [],
    "applicationIdentifier": application_identifier if isinstance(application_identifier, str) else "",
    "expirationDate": iso_datetime(payload.get("ExpirationDate")),
    "containsDevice": isinstance(provisioned_devices, list) and device_udid in provisioned_devices,
    "developerCertificateSha1s": developer_certificate_sha1s,
    "installedDeveloperCertificateSha1s": installed_certificate_sha1s,
    "installedCertificateMatches": bool(installed_certificate_sha1s),
    "matches": not failures,
    "failures": failures,
  }


def scan_profiles(
  *,
  team: str,
  bundle_id: str,
  device_udid: str,
  identity_output: str | None = None,
  now: datetime.datetime | None = None,
) -> dict[str, Any]:
  profile_dirs = preflight.provisioning_profile_directories()
  directory_statuses = [
    {
      "path": str(profile_dir),
      "exists": profile_dir.exists(),
      "isDirectory": profile_dir.is_dir() if profile_dir.exists() else False,
    }
    for profile_dir in profile_dirs
  ]
  facts: dict[str, Any] = {
    "directory": str(profile_dirs[0]) if profile_dirs else "",
    "directories": [str(profile_dir) for profile_dir in profile_dirs],
    "directoryStatuses": directory_statuses,
    "exists": any(status["exists"] for status in directory_statuses),
    "isDirectory": any(status["isDirectory"] for status in directory_statuses),
    "scanned": 0,
    "decodeErrors": [],
    "profiles": [],
    "matchingProfiles": [],
    "matchingProfileInstalledCertificateMatches": False,
  }
  for profile_dir in profile_dirs:
    if facts["scanned"] >= PROFILE_SCAN_LIMIT:
      break
    if not profile_dir.exists():
      continue
    if not profile_dir.is_dir():
      facts["decodeErrors"].append({"path": str(profile_dir), "error": "profile path is not a directory"})
      continue
    remaining = PROFILE_SCAN_LIMIT - facts["scanned"]
    for profile_path in sorted(profile_dir.glob("*.mobileprovision"))[:remaining]:
      facts["scanned"] += 1
      try:
        checked_profile = preflight.reject_symlink_components(profile_path, "iOS provisioning profile")
        payload = preflight.decode_mobileprovision(checked_profile)
      except preflight.DeviceRunPreflightError as exc:
        facts["decodeErrors"].append({"path": str(profile_path), "error": str(exc)})
        continue
      summary = profile_summary(
        checked_profile,
        payload,
        team=team,
        bundle_id=bundle_id,
        device_udid=device_udid,
        identity_output=identity_output,
        now=now,
      )
      facts["profiles"].append(summary)
      if summary["matches"]:
        facts["matchingProfiles"].append(summary["path"])
        if summary["installedCertificateMatches"]:
          facts["matchingProfileInstalledCertificateMatches"] = True
  return facts


def identity_summary(team: str | None, identity_output: str) -> dict[str, Any]:
  identities = preflight.apple_development_identities(identity_output)
  matching = [identity for identity in identities if team and f"({team})" in identity]
  available_teams = preflight.apple_development_team_identifiers(identity_output)
  return {
    "appleDevelopmentIdentityCount": len(identities),
    "availableTeamIdentifiers": available_teams,
    "appleDevelopmentIdentitySha1s": sorted(preflight.apple_development_identity_sha1s(identity_output)),
    "matchingTeamIdentityCount": len(matching),
    "matchingTeamIdentities": matching,
  }


def device_detail_value(device_details: str, key: str) -> str | None:
  prefix = f"{key}:"
  for raw_line in device_details.splitlines():
    line = raw_line.strip()
    if line.startswith("•"):
      line = line[1:].strip()
    if not line.startswith(prefix):
      continue
    value = line[len(prefix):].strip()
    return value or None
  return None


def device_detail_summary(identifier: str, device_details: str) -> dict[str, Any]:
  return {
    "identifier": identifier,
    "status": "ok",
    "udid": device_detail_value(device_details, "udid"),
    "deviceType": device_detail_value(device_details, "deviceType"),
    "marketingName": device_detail_value(device_details, "marketingName"),
    "productType": device_detail_value(device_details, "productType"),
    "reality": device_detail_value(device_details, "reality"),
    "developerModeStatus": device_detail_value(device_details, "developerModeStatus"),
    "ddiServicesAvailable": device_detail_value(device_details, "ddiServicesAvailable"),
    "tunnelState": device_detail_value(device_details, "tunnelState"),
    "transportType": device_detail_value(device_details, "transportType"),
    "installApplicationCapable": "Install Application (" in device_details,
    "launchApplicationCapable": "Launch Application (" in device_details,
  }


def visible_device_detail_summaries(visible_devices: object) -> list[dict[str, Any]]:
  if not isinstance(visible_devices, list):
    return []
  summaries: list[dict[str, Any]] = []
  for visible in visible_devices[:VISIBLE_DEVICE_DETAIL_SCAN_LIMIT]:
    if not isinstance(visible, dict):
      continue
    identifier = visible.get("identifier")
    if not isinstance(identifier, str) or not identifier:
      continue
    try:
      details = preflight.command_output(
        ["xcrun", "devicectl", "device", "info", "details", "--device", identifier],
        f"devicectl device details for visible device {identifier}",
        timeout=VISIBLE_DEVICE_DETAIL_TIMEOUT_SECONDS,
      )
      summaries.append(device_detail_summary(identifier, details))
    except preflight.DeviceRunPreflightError as exc:
      summaries.append({"identifier": identifier, "status": "error", "error": str(exc)})
  return summaries


def append_action(actions: list[dict[str, str]], code: str, message: str) -> None:
  if any(action.get("code") == code for action in actions):
    return
  actions.append({"code": code, "message": message})


def detail_summary_has_coredevice_blocker(summary: dict[str, Any]) -> bool:
  if summary.get("status") != "ok":
    return True
  developer_mode_ready = summary.get("developerModeStatus") == "enabled"
  ddi_ready = summary.get("ddiServicesAvailable") == "true"
  transport_ready = summary.get("tunnelState") == "connected" or summary.get("transportType") in {"usb", "wired"}
  install_ready = summary.get("installApplicationCapable") is True
  launch_ready = summary.get("launchApplicationCapable") is True
  return not (developer_mode_ready and ddi_ready and transport_ready and install_ready and launch_ready)


def selected_device_detail_summary(device: dict[str, Any]) -> dict[str, Any] | None:
  detail_summaries = device.get("detailSummaries")
  if not isinstance(detail_summaries, list):
    return None
  selected_identifier = device.get("identifier")
  if isinstance(selected_identifier, str) and selected_identifier:
    for summary in detail_summaries:
      if isinstance(summary, dict) and summary.get("identifier") == selected_identifier:
        return summary
  selected_udid = device.get("udid")
  if isinstance(selected_udid, str) and selected_udid:
    for summary in detail_summaries:
      if isinstance(summary, dict) and summary.get("udid") == selected_udid:
        return summary
  return None


def recommended_actions(facts: dict[str, Any]) -> list[dict[str, str]]:
  if facts.get("ready"):
    return []
  actions: list[dict[str, str]] = []
  project = facts.get("project", {})
  device = facts.get("device", {})
  identities = facts.get("identities", {})
  profiles = facts.get("profiles", {})
  environment = facts.get("environment", {})
  xcode_account_probe = facts.get("xcodeAccountProbe", {})
  project_team = project.get("team")
  bundle_id = project.get("bundleIdentifier")
  selected_device_udid = device.get("udid") if isinstance(device, dict) else None

  visible_devices = device.get("visibleDevices")
  detail_summaries = device.get("detailSummaries")
  selected_summary = selected_device_detail_summary(device) if isinstance(device, dict) else None
  if selected_summary is not None and detail_summary_has_coredevice_blocker(selected_summary):
    append_action(
      actions,
      "device.coredevice_transport_not_ready",
      "Unlock and keep the intended iPad/iPhone connected, trust this Mac, wait for Xcode/CoreDevice to mount the Developer Disk Image, then rerun the doctor until transport, DDI, install, and launch are all ready.",
    )
  elif selected_summary is None and isinstance(detail_summaries, list) and any(
    isinstance(summary, dict) and detail_summary_has_coredevice_blocker(summary)
    for summary in detail_summaries
  ):
    append_action(
      actions,
      "device.coredevice_transport_not_ready",
      "Unlock and keep the intended iPad/iPhone connected, trust this Mac, wait for Xcode/CoreDevice to mount the Developer Disk Image, then rerun the doctor until transport, DDI, install, and launch are all ready.",
    )
  elif selected_summary is None and isinstance(visible_devices, list) and any(
    isinstance(visible, dict) and visible.get("state") in preflight.UNUSABLE_DEVICE_STATES for visible in visible_devices
  ):
    append_action(
      actions,
      "device.not_probeable",
      "Connect, unlock, and trust the intended iPad/iPhone until devicectl reports a detail-probeable state.",
    )
  elif isinstance(visible_devices, list) and not visible_devices:
    append_action(
      actions,
      "device.not_visible",
      "Connect the physical iPad/iPhone and make it visible to xcrun devicectl list devices before treating any run as device evidence.",
    )

  available_teams = identities.get("availableTeamIdentifiers")
  matching_profile_has_installed_certificate = bool(profiles.get("matchingProfileInstalledCertificateMatches"))
  if identities.get("matchingTeamIdentityCount") == 0 and not matching_profile_has_installed_certificate:
    if isinstance(available_teams, list) and available_teams and project_team not in available_teams:
      append_action(
        actions,
        "signing.team_identity_missing",
        f"Add the Apple ID for team {project_team} in Xcode, or set {preflight.DEVICE_DEVELOPMENT_TEAM_ENV}=<one of: {', '.join(str(team) for team in available_teams)}> only if that available team is the intended signing owner.",
      )
    else:
      append_action(
        actions,
        "signing.identity_missing",
        "Install or create an Apple Development code-signing identity for the selected team in the login keychain.",
      )

  if isinstance(profiles, dict) and project_team and bundle_id and selected_device_udid:
    matching_profiles = profiles.get("matchingProfiles")
    if isinstance(matching_profiles, list) and not matching_profiles and not environment.get("allowProvisioningUpdates"):
      append_action(
        actions,
        "signing.profile_missing",
        f"Install or generate an iOS App Development provisioning profile matching the selected team, bundle identifier, and physical device UDID; set {preflight.DEVICE_ALLOW_PROVISIONING_UPDATES_ENV}=1 only after the Xcode account for that team is valid and Xcode should create the profile.",
      )
  if environment.get("allowProvisioningUpdates") and xcode_account_probe.get("checked") and xcode_account_probe.get("ok") is not True:
    append_action(
      actions,
      "signing.xcode_account_probe_failed",
      "Fix the Xcode account credentials reported by the automatic-provisioning probe before relying on -allowProvisioningUpdates.",
    )

  return actions


def collect_facts(now: datetime.datetime | None = None) -> dict[str, Any]:
  now = now or datetime.datetime.now(datetime.timezone.utc)
  facts: dict[str, Any] = {
    "schemaVersion": 1,
    "kind": "qixi-device-signing-doctor",
    "generatedAt": iso_datetime(now),
    "environment": {
      "allowProvisioningUpdates": preflight.provisioning_updates_allowed(),
      "developmentTeamOverride": os.environ.get(preflight.DEVICE_DEVELOPMENT_TEAM_ENV, "").strip(),
      "bundleIdentifierOverride": os.environ.get(preflight.DEVICE_BUNDLE_ID_ENV, "").strip(),
      "disableICloudEntitlements": preflight.icloud_entitlements_disabled(),
      "deviceIdentifierOverride": os.environ.get(preflight.DEVICE_ID_ENV, "").strip(),
    },
    "project": {},
    "device": {},
    "identities": {},
    "profiles": {},
    "xcodeAccountProbe": {"checked": False, "ok": None, "problems": []},
    "errors": [],
    "recommendedActions": [],
    "ready": False,
  }

  project_text = ""
  try:
    project_text = preflight.read(preflight.PROJECT, "Xcode project for device signing doctor")
    team = preflight.resolve_development_team(project_text)
    bundle_id = preflight.resolve_product_bundle_identifier(project_text)
    facts["project"] = {"team": team, "bundleIdentifier": bundle_id}
  except preflight.DeviceRunPreflightError as exc:
    facts["errors"].append(str(exc))
    team = ""
    bundle_id = ""

  try:
    preflight.check_iphoneos_sdk()
  except preflight.DeviceRunPreflightError as exc:
    facts["errors"].append(str(exc))

  device_udid = ""
  try:
    device_list_output = preflight.command_output(
      ["xcrun", "devicectl", "list", "devices"],
      "devicectl device list for signing doctor",
    )
    facts["device"]["visibleDevices"] = preflight.devicectl_device_rows_from_list(device_list_output)
    facts["device"]["detailSummaries"] = visible_device_detail_summaries(facts["device"]["visibleDevices"])
  except preflight.DeviceRunPreflightError as exc:
    facts["device"]["visibleDevices"] = []
    facts["device"]["detailSummaries"] = []
    facts["errors"].append(str(exc))

  try:
    device_identifier = preflight.select_physical_device_identifier()
    device_details = preflight.command_output(
      ["xcrun", "devicectl", "device", "info", "details", "--device", device_identifier],
      "devicectl device details",
    )
    device_udid = preflight.validated_physical_device_udid(device_details)
    facts["device"].update({"identifier": device_identifier, "udid": device_udid})
  except preflight.DeviceRunPreflightError as exc:
    facts["errors"].append(str(exc))

  identity_output: str | None = None
  identity_ok = False
  try:
    identity_output = preflight.command_output(
      ["security", "find-identity", "-v", "-p", "codesigning"],
      "code-signing identity lookup",
    )
    facts["identities"] = identity_summary(team or None, identity_output)
  except preflight.DeviceRunPreflightError as exc:
    facts["errors"].append(str(exc))

  matching_profile_payload: dict[str, Any] | None = None
  profiles_ok = False
  if team and bundle_id and device_udid:
    try:
      facts["profiles"] = scan_profiles(
        team=team,
        bundle_id=bundle_id,
        device_udid=device_udid,
        identity_output=identity_output,
        now=now,
      )
      profiles_ok = bool(facts["profiles"].get("matchingProfiles"))
      if profiles_ok:
        matching_profile = preflight.find_matching_development_profile_payload(team, bundle_id, device_udid)
        if matching_profile is not None:
          matching_profile_payload = matching_profile[1]
      if not profiles_ok and not facts["environment"]["allowProvisioningUpdates"]:
        facts["errors"].append(
          "no installed iOS App Development provisioning profile matches the selected team, bundle id, and device"
        )
    except preflight.DeviceRunPreflightError as exc:
      facts["errors"].append(str(exc))

  if identity_output is not None:
    try:
      preflight.check_apple_development_identity(team or None, identity_output, matching_profile_payload)
      identity_ok = True
    except preflight.DeviceRunPreflightError as exc:
      facts["errors"].append(str(exc))

  xcode_account_ok = True
  if team and device_udid and facts["environment"]["allowProvisioningUpdates"]:
    facts["xcodeAccountProbe"] = preflight.run_xcode_automatic_provisioning_probe(
      team,
      device_udid,
      bundle_id=bundle_id or None,
      disable_icloud_entitlements=bool(facts["environment"].get("disableICloudEntitlements")),
    )
    xcode_account_ok = facts["xcodeAccountProbe"].get("ok") is True
    if not xcode_account_ok:
      problems = facts["xcodeAccountProbe"].get("problems")
      if isinstance(problems, list) and problems:
        facts["errors"].append(
          "automatic provisioning was requested, but Xcode account credentials are not usable: "
          + "; ".join(str(problem) for problem in problems[:3])
        )
      else:
        facts["errors"].append("automatic provisioning was requested, but Xcode account probe failed")

  facts["ready"] = bool(
    team
    and bundle_id
    and device_udid
    and identity_ok
    and (profiles_ok or (facts["environment"]["allowProvisioningUpdates"] and xcode_account_ok))
  )
  facts["recommendedActions"] = recommended_actions(facts)
  return facts


def print_human(facts: dict[str, Any]) -> None:
  print("Qixi device signing doctor")
  project = facts.get("project", {})
  device = facts.get("device", {})
  identities = facts.get("identities", {})
  profiles = facts.get("profiles", {})
  xcode_account_probe = facts.get("xcodeAccountProbe", {})
  environment = facts.get("environment", {})

  print(f"- bundle: {project.get('bundleIdentifier') or '(unresolved)'}")
  print(f"- team: {project.get('team') or '(unresolved)'}")
  print(f"- device: {device.get('udid') or '(unresolved)'}")
  visible_devices = device.get("visibleDevices", [])
  if isinstance(visible_devices, list) and visible_devices:
    print("- visible devicectl devices:")
    for visible in visible_devices[:8]:
      if not isinstance(visible, dict):
        continue
      name = visible.get("name") or "(unnamed device)"
      state = visible.get("state") or "(unknown state)"
      identifier = visible.get("identifier") or "(unknown identifier)"
      model = visible.get("model") or "(unknown model)"
      print(f"  - {name}: {state}, {model}, {identifier}")
  detail_summaries = device.get("detailSummaries", [])
  if isinstance(detail_summaries, list) and detail_summaries:
    print("- visible device transport details:")
    for summary in detail_summaries[:8]:
      if not isinstance(summary, dict):
        continue
      identifier = summary.get("identifier") or "(unknown identifier)"
      if summary.get("status") != "ok":
        print(f"  - {identifier}: {summary.get('error') or 'details unavailable'}")
        continue
      developer_mode = summary.get("developerModeStatus") or "(unknown developer mode)"
      ddi = summary.get("ddiServicesAvailable") or "(unknown DDI)"
      tunnel = summary.get("tunnelState") or summary.get("transportType") or "(unknown transport)"
      install = "yes" if summary.get("installApplicationCapable") else "no"
      launch = "yes" if summary.get("launchApplicationCapable") else "no"
      print(
        f"  - {identifier}: developerMode={developer_mode}, "
        f"ddiServicesAvailable={ddi}, transport={tunnel}, install={install}, launch={launch}"
      )
  print(f"- Apple Development identities: {identities.get('appleDevelopmentIdentityCount', 0)} total, {identities.get('matchingTeamIdentityCount', 0)} matching team")
  available_teams = identities.get("availableTeamIdentifiers", [])
  if isinstance(available_teams, list) and available_teams:
    print(f"- available Apple Development team identifiers: {', '.join(str(team) for team in available_teams)}")
  directories = profiles.get("directories")
  if isinstance(directories, list) and directories:
    print("- provisioning directories:")
    for directory in directories:
      print(f"  - {directory}")
  else:
    print(f"- provisioning directory: {profiles.get('directory') or '(not scanned)'}")
  if profiles:
    print(f"- provisioning profiles scanned: {profiles.get('scanned', 0)}")
    print(f"- matching profiles: {len(profiles.get('matchingProfiles', []))}")
    if profiles.get("matchingProfileInstalledCertificateMatches"):
      print("- matching profile certificate: present in login keychain")
    print("- per-profile mismatch reasons:")
    for profile in profiles.get("profiles", [])[:10]:
      status = "match" if profile.get("matches") else "skip"
      name = profile.get("name") or pathlib.Path(profile.get("path", "")).name
      print(f"  - {status}: {name}")
      for failure in profile.get("failures", [])[:5]:
        print(f"    - {failure}")
    if profiles.get("decodeErrors"):
      print(f"- undecodable profiles: {len(profiles.get('decodeErrors', []))}")
  if environment.get("allowProvisioningUpdates"):
    print("- automatic provisioning updates: enabled")
    if xcode_account_probe.get("checked"):
      status = "ok" if xcode_account_probe.get("ok") else "failed"
      print(f"- Xcode automatic provisioning account probe: {status}")
      for problem in xcode_account_probe.get("problems", [])[:5]:
        print(f"  - {problem}")
  else:
    print("- automatic provisioning updates: disabled")

  errors = facts.get("errors", [])
  if facts.get("ready"):
    print("Result: signing inputs are ready for device bridge smoke.")
  else:
    print("Result: signing inputs are not ready.")
    for error in errors:
      print(f"- {error}")
    actions = facts.get("recommendedActions", [])
    if isinstance(actions, list) and actions:
      print("Next steps:")
      for action in actions:
        if not isinstance(action, dict):
          continue
        code = action.get("code") or "action"
        message = action.get("message") or ""
        print(f"- [{code}] {message}")


def main(argv: list[str]) -> int:
  json_output = "--json" in argv
  try:
    facts = collect_facts()
  except preflight.DeviceRunPreflightError as exc:
    facts = {
      "schemaVersion": 1,
      "kind": "qixi-device-signing-doctor",
      "ready": False,
      "errors": [str(exc)],
      "recommendedActions": [
        {
          "code": "doctor.failed",
          "message": "Fix the signing doctor failure and rerun before treating a device run as evidence.",
        }
      ],
    }
  if json_output:
    print(json.dumps(facts, indent=2, sort_keys=True) + "\n", end="")
  else:
    print_human(facts)
  return 0 if facts.get("ready") else 1


if __name__ == "__main__":
  raise SystemExit(main(sys.argv[1:]))
