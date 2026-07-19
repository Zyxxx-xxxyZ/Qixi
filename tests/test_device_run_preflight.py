#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import datetime
import hashlib
import http.server
import json
import os
import pathlib
import plistlib
import sys
import tempfile
import threading
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import qixi_device_run_preflight as preflight  # noqa: E402


class StatusHandler(http.server.BaseHTTPRequestHandler):
  payload: object = {
    "engine": "none",
    "engineId": "none",
    "state": "ready",
    "running": False,
    "paused": False,
  }
  content_type = "application/json"

  def do_GET(self) -> None:
    if self.path != "/api/status":
      self.send_response(404)
      self.end_headers()
      return
    if isinstance(self.payload, bytes):
      body = self.payload
    elif isinstance(self.payload, str):
      body = self.payload.encode("utf-8")
    else:
      body = json.dumps(self.payload).encode("utf-8")
    self.send_response(200)
    if self.content_type:
      self.send_header("Content-Type", self.content_type)
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    self.wfile.write(body)

  def log_message(self, format: str, *args: object) -> None:
    return


@contextlib.contextmanager
def status_server(payload: object, *, content_type: str = "application/json"):
  class Handler(StatusHandler):
    pass

  Handler.payload = payload
  Handler.content_type = content_type
  server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
  thread = threading.Thread(target=server.serve_forever, daemon=True)
  thread.start()
  try:
    yield f"http://127.0.0.1:{server.server_port}"
  finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)


@contextlib.contextmanager
def patched_env(*, clear: tuple[str, ...] = (), **updates: str):
  previous = {key: os.environ.get(key) for key in (*clear, *updates)}
  try:
    for key in clear:
      os.environ.pop(key, None)
    for key, value in updates.items():
      os.environ[key] = value
    yield
  finally:
    for key, value in previous.items():
      if value is None:
        os.environ.pop(key, None)
      else:
        os.environ[key] = value


class DeviceRunPreflightTests(unittest.TestCase):
  def test_local_preflight_inputs_use_bounded_reads_and_reject_symlinks(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      directory = pathlib.Path(tmpdir)
      plist_path = directory / "Info.plist"
      with plist_path.open("wb") as plist_file:
        plistlib.dump({"QixiAnalysisRuntime": "nativeInProcess"}, plist_file)
      self.assertEqual(
        preflight.load_plist(plist_path, "test plist")["QixiAnalysisRuntime"],
        "nativeInProcess",
      )

      source_path = directory / "source.txt"
      source_path.write_text("Device run preflight fixture\n", encoding="utf-8")
      self.assertIn("fixture", preflight.read(source_path, "test source"))

      linked_target = directory / "target.plist"
      with linked_target.open("wb") as plist_file:
        plistlib.dump({"QixiAnalysisRuntime": "nativeInProcess"}, plist_file)
      linked_path = directory / "linked.plist"
      try:
        linked_path.symlink_to(linked_target)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "test plist must not contain symbolic links"):
        preflight.load_plist(linked_path, "test plist")

      oversized_source = directory / "oversized-source.txt"
      with oversized_source.open("wb") as handle:
        handle.seek(preflight.SOURCE_TEXT_MAX_BYTES)
        handle.write(b"\0")
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "test source exceeds bounded size"):
        preflight.read(oversized_source, "test source")

      oversized_plist = directory / "oversized.plist"
      with oversized_plist.open("wb") as handle:
        handle.seek(preflight.PLIST_MAX_BYTES)
        handle.write(b"\0")
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "test plist exceeds bounded size"):
        preflight.load_plist(oversized_plist, "test plist")

  def test_local_preflight_inputs_recheck_opened_descriptor_is_regular(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      directory = pathlib.Path(tmpdir)
      fd = os.open(directory, os.O_RDONLY)
      try:
        class DirectoryHandle:
          def fileno(self) -> int:
            return fd

        with self.assertRaisesRegex(
          preflight.DeviceRunPreflightError,
          "test source must be a regular file after opening",
        ):
          preflight.opened_regular_file_stat(DirectoryHandle(), directory / "source.txt", "test source")
      finally:
        os.close(fd)

  def test_physical_device_backend_url_rejects_loopback_and_unspecified_hosts(self) -> None:
    for url in (
      "http://127.0.0.1:8765",
      "http://[::1]:8765",
      "http://0.0.0.0:8765",
      "http://localhost:8765",
    ):
      with self.subTest(url=url):
        with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "localhost or loopback"):
          preflight.validate_physical_device_backend_url(url)

  def test_physical_device_backend_url_accepts_lan_origin_and_normalizes_path(self) -> None:
    self.assertEqual(
      preflight.validate_physical_device_backend_url("http://192.168.1.23:8765/"),
      "http://192.168.1.23:8765",
    )
    with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "backend origin"):
      preflight.validate_physical_device_backend_url("http://192.168.1.23:8765/api/status")

  def test_status_checker_accepts_real_qixi_status_shape(self) -> None:
    payload = {
      "engine": "katago-metal-mux:b6",
      "engineId": "b6",
      "state": "running",
      "running": True,
      "paused": False,
    }
    with status_server(payload) as origin:
      self.assertEqual(preflight.check_backend_status(origin, timeout=2), payload)

  def test_status_checker_rejects_missing_fields_and_bad_states(self) -> None:
    with status_server({"engine": "none", "state": "ready"}) as origin:
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "missing 'engineId'"):
        preflight.check_backend_status(origin, timeout=2)

    bad_state = {
      "engine": "none",
      "engineId": "none",
      "state": "booting",
      "running": False,
      "paused": False,
    }
    with status_server(bad_state) as origin:
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "unexpected state"):
        preflight.check_backend_status(origin, timeout=2)

  def test_status_checker_rejects_ambiguous_or_non_standard_json(self) -> None:
    duplicate_key_status = b"""
{
  "engine": "none",
  "engineId": "none",
  "state": "ready",
  "state": "running",
  "running": true,
  "paused": false
}
""".lstrip()
    with status_server(duplicate_key_status) as origin:
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "duplicate JSON key 'state'"):
        preflight.check_backend_status(origin, timeout=2)

    non_standard_status = b"""
{
  "engine": "none",
  "engineId": "none",
  "state": "ready",
  "running": true,
  "paused": NaN
}
""".lstrip()
    with status_server(non_standard_status) as origin:
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "non-standard JSON constant NaN"):
        preflight.check_backend_status(origin, timeout=2)

  def test_status_checker_rejects_wrong_field_types(self) -> None:
    wrong_engine_type = {
      "engine": 123,
      "engineId": "none",
      "state": "ready",
      "running": False,
      "paused": False,
    }
    with status_server(wrong_engine_type) as origin:
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "field 'engine' must be a non-empty string"):
        preflight.check_backend_status(origin, timeout=2)

    wrong_running_type = {
      "engine": "none",
      "engineId": "none",
      "state": "ready",
      "running": "false",
      "paused": False,
    }
    with status_server(wrong_running_type) as origin:
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "field 'running' must be a boolean"):
        preflight.check_backend_status(origin, timeout=2)

  def test_status_checker_rejects_non_json_content_type_and_large_body(self) -> None:
    payload = {
      "engine": "none",
      "engineId": "none",
      "state": "ready",
      "running": False,
      "paused": False,
    }
    with status_server(payload, content_type="text/plain") as origin:
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "must return application/json"):
        preflight.check_backend_status(origin, timeout=2)

    with status_server(payload, content_type="application/json; charset=utf-8") as origin:
      self.assertEqual(preflight.check_backend_status(origin, timeout=2), payload)

    large_status = (
      b'{"engine":"'
      + (b"x" * (preflight.STATUS_RESPONSE_MAX_BYTES + 1))
      + b'","engineId":"none","state":"ready","running":false,"paused":false}'
    )
    with status_server(large_status) as origin:
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "status response is too large"):
        preflight.check_backend_status(origin, timeout=2)

  def test_status_checker_rejects_non_json_response(self) -> None:
    with status_server("not-json-object") as origin:
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "did not return JSON"):
        preflight.check_backend_status(origin, timeout=2)

    with status_server(b'"not-json-object"') as origin:
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "must be a JSON object"):
        preflight.check_backend_status(origin, timeout=2)

  def test_devicectl_connected_device_parser_accepts_single_connected_device(self) -> None:
    output = """
Name       Hostname                            Identifier                             State                Model
--------   ---------------------------------   ------------------------------------   ------------------   -------------------------------
iPhone     iPhone.coredevice.local             00FDDA18-29B3-50C5-AFE3-3E634086C367   connected (no DDI)   iPhone 17 Pro Max (iPhone18,2)
曾逸轩的iPad   cengyixuandeiPad.coredevice.local   21ABE4B1-1509-5D45-9645-75A52D050D68   connected            iPad Pro 13-inch (M5)
OtherPad   other.coredevice.local              11ABE4B1-1509-5D45-9645-75A52D050D68   connecting           iPad Pro 11-inch (M5)
PairedPad  paired.coredevice.local             22ABE4B1-1509-5D45-9645-75A52D050D68   available (paired)   iPad Pro 13-inch (M5)
Offline    offline.coredevice.local            33ABE4B1-1509-5D45-9645-75A52D050D68   unavailable          iPad Pro 11-inch (M5)
""".strip()
    rows = preflight.devicectl_device_rows_from_list(output)
    self.assertEqual(len(rows), 5)
    self.assertEqual(rows[0]["state"], "connected (no DDI)")
    self.assertEqual(rows[3]["state"], "available (paired)")
    self.assertEqual(rows[-1]["state"], "unavailable")
    self.assertEqual(
      preflight.connected_device_identifiers_from_devicectl_list(output),
      ["21ABE4B1-1509-5D45-9645-75A52D050D68"],
    )
    self.assertEqual(
      preflight.detail_probe_device_identifiers_from_devicectl_list(output),
      [
        "00FDDA18-29B3-50C5-AFE3-3E634086C367",
        "21ABE4B1-1509-5D45-9645-75A52D050D68",
        "22ABE4B1-1509-5D45-9645-75A52D050D68",
      ],
    )
    summary = preflight.devicectl_device_state_summary_from_list(output)
    self.assertIn("iPhone [connected (no DDI)]", summary)
    self.assertIn("PairedPad [available (paired)]", summary)
    self.assertIn("OtherPad [connecting]", summary)
    self.assertIn("Offline [unavailable]", summary)

  def test_devicectl_selection_error_reports_visible_unprobeable_devices(self) -> None:
    output = """
Name       Hostname                            Identifier                             State                Model
--------   ---------------------------------   ------------------------------------   ------------------   -------------------------------
OtherPad   other.coredevice.local              11ABE4B1-1509-5D45-9645-75A52D050D68   connecting           iPad Pro 11-inch (M5)
Offline    offline.coredevice.local            33ABE4B1-1509-5D45-9645-75A52D050D68   unavailable          iPad Pro 11-inch (M5)
""".strip()
    saved_command_output = preflight.command_output
    try:
      preflight.command_output = lambda args, label, timeout=15: output
      with self.assertRaisesRegex(
        preflight.DeviceRunPreflightError,
        r"visible devices: .*connecting.*unavailable",
      ):
        preflight.select_physical_device_identifier()
    finally:
      preflight.command_output = saved_command_output

  def test_ambiguous_detail_probeable_devices_require_explicit_device_id(self) -> None:
    output = """
Name       Hostname                            Identifier                             State                Model
--------   ---------------------------------   ------------------------------------   ------------------   -------------------------------
iPhone     iPhone.coredevice.local             00FDDA18-29B3-50C5-AFE3-3E634086C367   connected (no DDI)   iPhone 17 Pro Max (iPhone18,2)
曾逸轩的iPad   cengyixuandeiPad.coredevice.local   21ABE4B1-1509-5D45-9645-75A52D050D68   available (paired)   iPad Pro 13-inch (M5)
""".strip()
    saved_command_output = preflight.command_output
    try:
      preflight.command_output = lambda args, label, timeout=15: output
      with patched_env(clear=(preflight.DEVICE_ID_ENV,)):
        with self.assertRaisesRegex(
          preflight.DeviceRunPreflightError,
          r"multiple detail-probeable devices.*connected \(no DDI\).*available \(paired\)",
        ):
          preflight.select_physical_device_identifier()
    finally:
      preflight.command_output = saved_command_output

  def test_explicit_devicectl_device_id_must_be_visible_and_detail_probeable(self) -> None:
    connected_id = "21ABE4B1-1509-5D45-9645-75A52D050D68"
    paired_id = "22ABE4B1-1509-5D45-9645-75A52D050D68"
    connecting_id = "44ABE4B1-1509-5D45-9645-75A52D050D68"
    output = f"""
Name       Hostname                            Identifier                             State                Model
--------   ---------------------------------   ------------------------------------   ------------------   -------------------------------
曾逸轩的iPad   cengyixuandeiPad.coredevice.local   {connected_id}   connected            iPad Pro 13-inch (M5)
PairedPad  paired.coredevice.local             {paired_id}   available (paired)   iPad Pro 13-inch (M5)
OtherPad   other.coredevice.local              {connecting_id}   connecting           iPad Pro 11-inch (M5)
""".strip()
    saved_command_output = preflight.command_output
    try:
      preflight.command_output = lambda args, label, timeout=15: output
      with patched_env(**{preflight.DEVICE_ID_ENV: connected_id}):
        self.assertEqual(preflight.select_physical_device_identifier(), connected_id)
      with patched_env(**{preflight.DEVICE_ID_ENV: paired_id}):
        self.assertEqual(preflight.select_physical_device_identifier(), paired_id)
      with patched_env(**{preflight.DEVICE_ID_ENV: connecting_id}):
        with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "not probeable"):
          preflight.select_physical_device_identifier()
      with patched_env(**{preflight.DEVICE_ID_ENV: "33ABE4B1-1509-5D45-9645-75A52D050D68"}):
        with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "selected device is not visible"):
          preflight.select_physical_device_identifier()
    finally:
      preflight.command_output = saved_command_output

  def test_device_detail_validation_requires_physical_developer_mode_and_ddi(self) -> None:
    details = """
▿ hardwareProperties:
    • reality: physical
    • udid: 00008142-000E25660120401C
▿ deviceProperties:
    • ddiServicesAvailable: true
    • developerModeStatus: enabled
▿ connectionProperties:
    • tunnelState: connected
▿ capabilities:
    • Install Application (com.apple.coredevice.feature.installapp)
    • Launch Application (com.apple.coredevice.feature.launchapplication)
""".strip()
    self.assertEqual(preflight.validated_physical_device_udid(details), "00008142-000E25660120401C")

    with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "Developer Mode enabled"):
      preflight.validated_physical_device_udid(details.replace("developerModeStatus: enabled", "developerModeStatus: disabled"))

    with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "Developer Disk Image"):
      preflight.validated_physical_device_udid(details.replace("ddiServicesAvailable: true", "ddiServicesAvailable: false"))

    with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "physical hardware"):
      preflight.validated_physical_device_udid(details.replace("reality: physical", "reality: virtual"))

    with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "active CoreDevice transport"):
      preflight.validated_physical_device_udid(details.replace("tunnelState: connected", "tunnelState: disconnected"))

    with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "Install Application"):
      preflight.validated_physical_device_udid(details.replace("Install Application", "Install Disabled"))

    with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "Launch Application"):
      preflight.validated_physical_device_udid(details.replace("Launch Application", "Launch Disabled"))

  def test_xcode_destination_parser_requires_physical_device_udid(self) -> None:
    destinations = """
Available destinations for the "Qixi" scheme:
    { platform:iOS, arch:arm64, id:00008142-000E25660120401C, name:曾逸轩的iPad }
    { platform:iOS Simulator, arch:arm64, id:320E80FA-9340-4F4F-AF3A-9E6E772C5E22, OS:26.5, name:iPad Pro 13-inch (M5) }
""".strip()
    self.assertTrue(preflight.xcode_destinations_include_device(destinations, "00008142-000E25660120401C"))
    self.assertFalse(preflight.xcode_destinations_include_device(destinations, "320E80FA-9340-4F4F-AF3A-9E6E772C5E22"))

  def test_development_team_resolution_uses_project_or_explicit_override(self) -> None:
    with patched_env(clear=(preflight.DEVICE_DEVELOPMENT_TEAM_ENV,)):
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "requires DEVELOPMENT_TEAM"):
        preflight.resolve_development_team('DEVELOPMENT_TEAM = "";')

      self.assertEqual(
        preflight.resolve_development_team('DEVELOPMENT_TEAM = ABCDE12345;'),
        "ABCDE12345",
      )
    with patched_env(**{preflight.DEVICE_DEVELOPMENT_TEAM_ENV: "TEAMFROMENV"}):
      self.assertEqual(preflight.resolve_development_team('DEVELOPMENT_TEAM = "";'), "TEAMFROMENV")

  def test_product_bundle_identifier_resolution_requires_single_bundle(self) -> None:
    with patched_env(clear=(preflight.DEVICE_BUNDLE_ID_ENV,)):
      self.assertEqual(
        preflight.resolve_product_bundle_identifier('PRODUCT_BUNDLE_IDENTIFIER = com.qixi.localanalysis;'),
        "com.qixi.localanalysis",
      )
      self.assertEqual(
        preflight.resolve_product_bundle_identifier(
          """
          PRODUCT_BUNDLE_IDENTIFIER = com.qixi.localanalysis;
          PRODUCT_BUNDLE_IDENTIFIER = com.qixi.localanalysis;
          """
        ),
        "com.qixi.localanalysis",
      )
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "requires PRODUCT_BUNDLE_IDENTIFIER"):
        preflight.resolve_product_bundle_identifier("")
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "multiple PRODUCT_BUNDLE_IDENTIFIER"):
        preflight.resolve_product_bundle_identifier(
          """
          PRODUCT_BUNDLE_IDENTIFIER = com.qixi.localanalysis;
          PRODUCT_BUNDLE_IDENTIFIER = com.example.other;
          """
        )

    with patched_env(**{preflight.DEVICE_BUNDLE_ID_ENV: "com.example.qixi.local-device"}):
      self.assertEqual(
        preflight.resolve_product_bundle_identifier(
          """
          PRODUCT_BUNDLE_IDENTIFIER = com.qixi.localanalysis;
          PRODUCT_BUNDLE_IDENTIFIER = com.example.other;
          """
        ),
        "com.example.qixi.local-device",
      )
    with patched_env(**{preflight.DEVICE_BUNDLE_ID_ENV: "com.example..qixi"}):
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "reverse-DNS bundle identifier"):
        preflight.resolve_product_bundle_identifier('PRODUCT_BUNDLE_IDENTIFIER = com.qixi.localanalysis;')
    with patched_env(**{preflight.DEVICE_BUNDLE_ID_ENV: "com.example.*"}):
      with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "reverse-DNS bundle identifier"):
        preflight.resolve_product_bundle_identifier('PRODUCT_BUNDLE_IDENTIFIER = com.qixi.localanalysis;')

  def test_codesigning_identity_validation_requires_apple_development_for_team(self) -> None:
    no_identity_output = "     0 valid identities found\n"
    with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "no Apple Development code-signing identities"):
      preflight.check_apple_development_identity("ABCDE12345", no_identity_output)

    identity_output = """
  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Qixi Developer (ABCDE12345)"
     1 valid identities found
""".strip()
    self.assertEqual(preflight.apple_development_team_identifiers(identity_output), ["ABCDE12345"])
    self.assertEqual(
      preflight.apple_development_identity_sha1s(identity_output),
      {"0123456789ABCDEF0123456789ABCDEF01234567"},
    )
    preflight.check_apple_development_identity("ABCDE12345", identity_output)
    with self.assertRaisesRegex(
      preflight.DeviceRunPreflightError,
      "for team OTHERTEAM; available Apple Development team identifiers on this Mac: ABCDE12345",
    ):
      preflight.check_apple_development_identity("OTHERTEAM", identity_output)

    certificate = b"qixi managed profile development certificate fixture"
    certificate_sha1 = hashlib.sha1(certificate).hexdigest().upper()
    managed_profile_identity_output = f"""
  1) {certificate_sha1} "Apple Development: Zeng Yixuan (CTUFVJ5XX2)"
     1 valid identities found
""".strip()
    profile_payload = {"DeveloperCertificates": [certificate]}
    self.assertEqual(preflight.profile_developer_certificate_sha1s(profile_payload), [certificate_sha1])
    self.assertTrue(preflight.profile_has_installed_development_certificate(profile_payload, managed_profile_identity_output))
    preflight.check_apple_development_identity("Q795QF39Y5", managed_profile_identity_output, profile_payload)
    with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "for team Q795QF39Y5"):
      preflight.check_apple_development_identity(
        "Q795QF39Y5",
        identity_output,
        {"DeveloperCertificates": [b"different certificate"]},
      )

  def test_provisioning_profile_matching_checks_team_bundle_udid_and_expiration(self) -> None:
    now = datetime.datetime(2026, 7, 6, tzinfo=datetime.timezone.utc)
    valid_payload = {
      "TeamIdentifier": ["ABCDE12345"],
      "ExpirationDate": now + datetime.timedelta(days=30),
      "ProvisionedDevices": ["00008142-000E25660120401C"],
      "Entitlements": {"application-identifier": "ABCDE12345.com.qixi.localanalysis"},
    }
    self.assertTrue(
      preflight.provisioning_profile_matches(
        valid_payload,
        team="ABCDE12345",
        bundle_id="com.qixi.localanalysis",
        device_udid="00008142-000E25660120401C",
        now=now,
      )
    )

    wildcard_payload = dict(valid_payload)
    wildcard_payload["Entitlements"] = {"application-identifier": "ABCDE12345.*"}
    self.assertTrue(
      preflight.provisioning_profile_matches(
        wildcard_payload,
        team="ABCDE12345",
        bundle_id="com.qixi.localanalysis",
        device_udid="00008142-000E25660120401C",
        now=now,
      )
    )

    wrong_team = dict(valid_payload)
    wrong_team["TeamIdentifier"] = ["OTHERTEAM"]
    self.assertFalse(
      preflight.provisioning_profile_matches(
        wrong_team,
        team="ABCDE12345",
        bundle_id="com.qixi.localanalysis",
        device_udid="00008142-000E25660120401C",
        now=now,
      )
    )

    wrong_device = dict(valid_payload)
    wrong_device["ProvisionedDevices"] = ["00000000-0000000000000000"]
    self.assertFalse(
      preflight.provisioning_profile_matches(
        wrong_device,
        team="ABCDE12345",
        bundle_id="com.qixi.localanalysis",
        device_udid="00008142-000E25660120401C",
        now=now,
      )
    )

    expired_payload = dict(valid_payload)
    expired_payload["ExpirationDate"] = now - datetime.timedelta(seconds=1)
    self.assertFalse(
      preflight.provisioning_profile_matches(
        expired_payload,
        team="ABCDE12345",
        bundle_id="com.qixi.localanalysis",
        device_udid="00008142-000E25660120401C",
        now=now,
      )
    )

  def test_development_provisioning_profile_check_uses_installed_profiles_or_explicit_xcode_updates(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      profile_dir = pathlib.Path(tmpdir)
      matching_profile = profile_dir / "matching.mobileprovision"
      with matching_profile.open("wb") as handle:
        plistlib.dump(
          {
            "TeamIdentifier": ["ABCDE12345"],
            "ExpirationDate": datetime.datetime(2035, 1, 1),
            "ProvisionedDevices": ["00008142-000E25660120401C"],
            "Entitlements": {"application-identifier": "ABCDE12345.com.qixi.localanalysis"},
          },
          handle,
        )
      other_profile = profile_dir / "other.mobileprovision"
      with other_profile.open("wb") as handle:
        plistlib.dump(
          {
            "TeamIdentifier": ["OTHERTEAM"],
            "ExpirationDate": datetime.datetime(2035, 1, 1),
            "ProvisionedDevices": ["00008142-000E25660120401C"],
            "Entitlements": {"application-identifier": "OTHERTEAM.com.example.other"},
          },
          handle,
        )

      with patched_env(**{preflight.DEVICE_PROVISIONING_PROFILE_DIR_ENV: str(profile_dir)}):
        self.assertEqual(
          preflight.find_matching_development_profile(
            "ABCDE12345",
            "com.qixi.localanalysis",
            "00008142-000E25660120401C",
          ),
          matching_profile,
        )
        preflight.check_development_provisioning_profile(
          "ABCDE12345",
          "com.qixi.localanalysis",
          "00008142-000E25660120401C",
        )
        with self.assertRaisesRegex(preflight.DeviceRunPreflightError, "no installed iOS App Development provisioning profile"):
          preflight.check_development_provisioning_profile(
            "ABCDE12345",
            "com.qixi.localanalysis",
            "MISSINGUDID",
          )

      with patched_env(
        **{
          preflight.DEVICE_PROVISIONING_PROFILE_DIR_ENV: str(profile_dir / "missing"),
          preflight.DEVICE_ALLOW_PROVISIONING_UPDATES_ENV: "1",
        }
      ):
        preflight.check_development_provisioning_profile(
          "ABCDE12345",
          "com.qixi.localanalysis",
          "MISSINGUDID",
        )

  def test_development_profile_lookup_scans_xcode_managed_profile_directory(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      home = pathlib.Path(tmpdir)
      xcode_profile_dir = home / "Library" / "Developer" / "Xcode" / "UserData" / "Provisioning Profiles"
      xcode_profile_dir.mkdir(parents=True)
      matching_profile = xcode_profile_dir / "xcode-managed.mobileprovision"
      with matching_profile.open("wb") as handle:
        plistlib.dump(
          {
            "TeamIdentifier": ["Q795QF39Y5"],
            "ExpirationDate": datetime.datetime(2035, 1, 1),
            "ProvisionedDevices": ["00008142-000E25660120401C"],
            "Entitlements": {"application-identifier": "Q795QF39Y5.com.zyx.qixi.local-device"},
          },
          handle,
        )
      with patched_env(
        clear=(
          preflight.DEVICE_PROVISIONING_PROFILE_DIR_ENV,
          preflight.DEVICE_XCODE_PROVISIONING_PROFILE_DIR_ENV,
        ),
        HOME=str(home),
      ):
        directories = preflight.provisioning_profile_directories()
        self.assertEqual(
          directories,
          [
            home / "Library" / "MobileDevice" / "Provisioning Profiles",
            xcode_profile_dir,
          ],
        )
        self.assertEqual(
          preflight.find_matching_development_profile(
            "Q795QF39Y5",
            "com.zyx.qixi.local-device",
            "00008142-000E25660120401C",
          ),
          matching_profile,
        )

  def test_xcode_account_probe_problem_parser_catches_credential_failures(self) -> None:
    output = """
2026-07-06 12:36:19.669 xcodebuild[95703:736297]  DVTDeveloperAccountManager: Failed to load credentials for UUID: Error Domain=DVTDeveloperAccountCredentialsError Code=0 "Invalid credentials in keychain, missing Xcode-Username"
error: No Account for Team "ABCDE12345". Add a new account in Accounts settings.
/Users/zyx/Desktop/projects/Qixi/qixi-ios-native/Qixi.xcodeproj: error: No Accounts: Add a new account in Accounts settings.
/Users/zyx/Desktop/projects/Qixi/qixi-ios-native/Qixi.xcodeproj: error: No profiles for 'com.qixi.localanalysis' were found.
Build settings for action build and target Qixi:
""".strip()
    problems = preflight.xcode_account_probe_problem_messages(output)
    self.assertTrue(any("DVTDeveloperAccountManager" in problem for problem in problems))
    self.assertTrue(any("No Account for Team" in problem for problem in problems))
    self.assertTrue(any("No Accounts" in problem for problem in problems))
    self.assertTrue(any("No profiles for" in problem for problem in problems))

  def test_xcode_account_probe_problem_parser_accepts_clean_show_build_settings_output(self) -> None:
    output = """
Build settings from command line:
    DEVELOPMENT_TEAM = ABCDE12345
Build settings for action build and target Qixi:
    PRODUCT_BUNDLE_IDENTIFIER = com.qixi.localanalysis
""".strip()
    self.assertEqual(preflight.xcode_account_probe_problem_messages(output), [])

  def test_xcode_account_probe_uses_bundle_and_entitlement_overrides(self) -> None:
    completed = mock.Mock()
    completed.returncode = 0
    completed.stdout = ""
    completed.stderr = ""
    with patched_env(**{preflight.DEVICE_XCODE_ACCOUNT_PROBE_DERIVED_DATA_ENV: "/private/tmp/qixi-probe-test"}):
      with mock.patch.object(preflight.subprocess, "run", return_value=completed) as run:
        result = preflight.run_xcode_automatic_provisioning_probe(
          "ABCDE12345",
          "00008142-000E25660120401C",
          bundle_id="com.example.qixi.local-device",
          disable_icloud_entitlements=True,
          timeout=7,
        )
    self.assertTrue(result["ok"])
    args = run.call_args.args[0]
    self.assertIn("DEVELOPMENT_TEAM=ABCDE12345", args)
    self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=com.example.qixi.local-device", args)
    self.assertIn("CODE_SIGN_ENTITLEMENTS=", args)
    self.assertIn("-allowProvisioningUpdates", args)
    self.assertIn("-allowProvisioningDeviceRegistration", args)
    self.assertEqual(run.call_args.kwargs["timeout"], 7)


if __name__ == "__main__":
  unittest.main()
