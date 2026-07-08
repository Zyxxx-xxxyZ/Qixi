#!/usr/bin/env python3
from __future__ import annotations

import datetime
import hashlib
import os
import pathlib
import plistlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import qixi_device_run_preflight as preflight  # noqa: E402
import qixi_device_signing_doctor as doctor  # noqa: E402


class DeviceSigningDoctorTests(unittest.TestCase):
  def tearDown(self) -> None:
    doctor.preflight.run_xcode_automatic_provisioning_probe = preflight.run_xcode_automatic_provisioning_probe

  def test_profile_summary_reports_actionable_mismatch_reasons(self) -> None:
    now = datetime.datetime(2026, 7, 6, tzinfo=datetime.timezone.utc)
    summary = doctor.profile_summary(
      pathlib.Path("/tmp/bad.mobileprovision"),
      {
        "Name": "Wrong Team",
        "UUID": "PROFILE-UUID",
        "TeamIdentifier": ["OTHERTEAM"],
        "ExpirationDate": now - datetime.timedelta(days=1),
        "ProvisionedDevices": ["OTHERDEVICE"],
        "Entitlements": {"application-identifier": "OTHERTEAM.com.example.other"},
      },
      team="ABCDE12345",
      bundle_id="com.qixi.localanalysis",
      device_udid="00008142-000E25660120401C",
      now=now,
    )
    self.assertFalse(summary["matches"])
    self.assertIn("team ABCDE12345 is not listed in TeamIdentifier", summary["failures"])
    self.assertIn("profile is expired", summary["failures"])
    self.assertIn("device 00008142-000E25660120401C is not listed in ProvisionedDevices", summary["failures"])
    self.assertTrue(
      any("application-identifier" in failure and "does not match" in failure for failure in summary["failures"])
    )

  def test_profile_summary_accepts_matching_development_profile(self) -> None:
    now = datetime.datetime(2026, 7, 6, tzinfo=datetime.timezone.utc)
    certificate = b"qixi profile certificate"
    certificate_sha1 = hashlib.sha1(certificate).hexdigest().upper()
    summary = doctor.profile_summary(
      pathlib.Path("/tmp/good.mobileprovision"),
      {
        "Name": "Qixi Development",
        "UUID": "PROFILE-UUID",
        "TeamIdentifier": ["ABCDE12345"],
        "ExpirationDate": now + datetime.timedelta(days=10),
        "ProvisionedDevices": ["00008142-000E25660120401C"],
        "DeveloperCertificates": [certificate],
        "Entitlements": {"application-identifier": "ABCDE12345.com.qixi.localanalysis"},
      },
      team="ABCDE12345",
      bundle_id="com.qixi.localanalysis",
      device_udid="00008142-000E25660120401C",
      identity_output=f'1) {certificate_sha1} "Apple Development: Alice (OTHERTEAM)"',
      now=now,
    )
    self.assertTrue(summary["matches"])
    self.assertEqual(summary["failures"], [])
    self.assertEqual(summary["expirationDate"], "2026-07-16T00:00:00Z")
    self.assertEqual(summary["developerCertificateSha1s"], [certificate_sha1])
    self.assertEqual(summary["installedDeveloperCertificateSha1s"], [certificate_sha1])
    self.assertTrue(summary["installedCertificateMatches"])

  def test_preflight_rejects_profile_without_expiration_date(self) -> None:
    failures = preflight.provisioning_profile_match_failures(
      {
        "TeamIdentifier": ["ABCDE12345"],
        "ProvisionedDevices": ["00008142-000E25660120401C"],
        "Entitlements": {"application-identifier": "ABCDE12345.com.qixi.localanalysis"},
      },
      team="ABCDE12345",
      bundle_id="com.qixi.localanalysis",
      device_udid="00008142-000E25660120401C",
      now=datetime.datetime(2026, 7, 6, tzinfo=datetime.timezone.utc),
    )
    self.assertIn("ExpirationDate is missing or not a date", failures)
    self.assertFalse(
      preflight.provisioning_profile_matches(
        {
          "TeamIdentifier": ["ABCDE12345"],
          "ProvisionedDevices": ["00008142-000E25660120401C"],
          "Entitlements": {"application-identifier": "ABCDE12345.com.qixi.localanalysis"},
        },
        team="ABCDE12345",
        bundle_id="com.qixi.localanalysis",
        device_udid="00008142-000E25660120401C",
      )
    )

  def test_scan_profiles_lists_matching_and_nonmatching_profiles(self) -> None:
    previous_dir = os.environ.get(preflight.DEVICE_PROVISIONING_PROFILE_DIR_ENV)
    now = datetime.datetime(2026, 7, 6, tzinfo=datetime.timezone.utc)
    certificate = b"qixi scan certificate"
    certificate_sha1 = hashlib.sha1(certificate).hexdigest().upper()
    try:
      with tempfile.TemporaryDirectory() as tmpdir:
        profile_dir = pathlib.Path(tmpdir)
        os.environ[preflight.DEVICE_PROVISIONING_PROFILE_DIR_ENV] = str(profile_dir)
        with (profile_dir / "good.mobileprovision").open("wb") as handle:
          plistlib.dump(
            {
              "Name": "Qixi Good",
              "UUID": "GOOD",
              "TeamIdentifier": ["ABCDE12345"],
              "ExpirationDate": now + datetime.timedelta(days=5),
              "ProvisionedDevices": ["00008142-000E25660120401C"],
              "DeveloperCertificates": [certificate],
              "Entitlements": {"application-identifier": "ABCDE12345.com.qixi.localanalysis"},
            },
            handle,
          )
        with (profile_dir / "bad.mobileprovision").open("wb") as handle:
          plistlib.dump(
            {
              "Name": "Qixi Bad",
              "UUID": "BAD",
              "TeamIdentifier": ["ABCDE12345"],
              "ExpirationDate": now + datetime.timedelta(days=5),
              "ProvisionedDevices": ["OTHERDEVICE"],
              "Entitlements": {"application-identifier": "ABCDE12345.com.qixi.localanalysis"},
            },
            handle,
          )

        facts = doctor.scan_profiles(
          team="ABCDE12345",
          bundle_id="com.qixi.localanalysis",
          device_udid="00008142-000E25660120401C",
          identity_output=f'1) {certificate_sha1} "Apple Development: Alice (OTHERTEAM)"',
          now=now,
        )
        self.assertEqual(facts["scanned"], 2)
        self.assertEqual(len(facts["profiles"]), 2)
        self.assertEqual(facts["matchingProfiles"], [str(profile_dir / "good.mobileprovision")])
        self.assertEqual(facts["directories"], [str(profile_dir)])
        self.assertTrue(facts["matchingProfileInstalledCertificateMatches"])
        bad = next(profile for profile in facts["profiles"] if profile["name"] == "Qixi Bad")
        self.assertIn("device 00008142-000E25660120401C is not listed in ProvisionedDevices", bad["failures"])
    finally:
      if previous_dir is None:
        os.environ.pop(preflight.DEVICE_PROVISIONING_PROFILE_DIR_ENV, None)
      else:
        os.environ[preflight.DEVICE_PROVISIONING_PROFILE_DIR_ENV] = previous_dir

  def test_identity_summary_counts_matching_team_identities(self) -> None:
    summary = doctor.identity_summary(
      "ABCDE12345",
      """
  1) HASH "Apple Development: Alice (ABCDE12345)"
  2) HASH "Apple Development: Bob (OTHERTEAM)"
     2 valid identities found
""",
    )
    self.assertEqual(summary["appleDevelopmentIdentityCount"], 2)
    self.assertEqual(summary["availableTeamIdentifiers"], ["ABCDE12345", "OTHERTEAM"])
    self.assertEqual(summary["appleDevelopmentIdentitySha1s"], [])
    self.assertEqual(summary["matchingTeamIdentityCount"], 1)
    self.assertIn("Alice", summary["matchingTeamIdentities"][0])

  def test_device_detail_summary_extracts_coredevice_readiness_fields(self) -> None:
    summary = doctor.device_detail_summary(
      "21ABE4B1-1509-5D45-9645-75A52D050D68",
      """
Current device information:
• identifier: 21ABE4B1-1509-5D45-9645-75A52D050D68
▿ hardwareProperties:
    • deviceType: iPad
    • marketingName: iPad Pro 13-inch (M5)
    • productType: iPad17,4
    • reality: physical
    • udid: 00008142-000E25660120401C
▿ deviceProperties:
    • ddiServicesAvailable: false
    • developerModeStatus: enabled
▿ connectionProperties:
    • tunnelState: unavailable
▿ capabilities:
    • Install Application (com.apple.coredevice.feature.install-app)
""",
    )
    self.assertEqual(summary["status"], "ok")
    self.assertEqual(summary["udid"], "00008142-000E25660120401C")
    self.assertEqual(summary["deviceType"], "iPad")
    self.assertEqual(summary["marketingName"], "iPad Pro 13-inch (M5)")
    self.assertEqual(summary["productType"], "iPad17,4")
    self.assertEqual(summary["reality"], "physical")
    self.assertEqual(summary["developerModeStatus"], "enabled")
    self.assertEqual(summary["ddiServicesAvailable"], "false")
    self.assertEqual(summary["tunnelState"], "unavailable")
    self.assertTrue(summary["installApplicationCapable"])
    self.assertFalse(summary["launchApplicationCapable"])

  def test_collect_facts_reports_visible_unusable_device_states(self) -> None:
    saved = {
      "read": doctor.preflight.read,
      "resolve_development_team": doctor.preflight.resolve_development_team,
      "resolve_product_bundle_identifier": doctor.preflight.resolve_product_bundle_identifier,
      "check_iphoneos_sdk": doctor.preflight.check_iphoneos_sdk,
      "command_output": doctor.preflight.command_output,
    }
    previous_device_id = os.environ.get(preflight.DEVICE_ID_ENV)
    device_list = """
Name       Hostname                            Identifier                             State                Model
--------   ---------------------------------   ------------------------------------   ------------------   -------------------------------
iPhone     iPhone.coredevice.local             00FDDA18-29B3-50C5-AFE3-3E634086C367   connected (no DDI)   iPhone 17 Pro Max (iPhone18,2)
曾逸轩的iPad   cengyixuandeiPad.coredevice.local   21ABE4B1-1509-5D45-9645-75A52D050D68   available (paired)   iPad Pro 13-inch (M5)
Offline    offline.coredevice.local            33ABE4B1-1509-5D45-9645-75A52D050D68   unavailable          iPad Pro 11-inch (M5)
""".strip()
    try:
      os.environ.pop(preflight.DEVICE_ID_ENV, None)
      doctor.preflight.read = lambda path, label=None: "project"
      doctor.preflight.resolve_development_team = lambda project_text: "ABCDE12345"
      doctor.preflight.resolve_product_bundle_identifier = lambda project_text: "com.qixi.localanalysis"
      doctor.preflight.check_iphoneos_sdk = lambda: None

      def command_output(args, label, timeout=15):
        if args[:3] == ["xcrun", "devicectl", "list"]:
          return device_list
        if args[:5] == ["xcrun", "devicectl", "device", "info", "details"]:
          identifier = args[-1]
          tunnel = "connected" if identifier.startswith("21") else "unavailable"
          ddi = "true" if identifier.startswith("21") else "false"
          return f"""
Current device information:
• identifier: {identifier}
▿ hardwareProperties:
    • deviceType: iPad
    • marketingName: iPad Pro
    • reality: physical
    • udid: 00008142-000E25660120401C
▿ deviceProperties:
    • ddiServicesAvailable: {ddi}
    • developerModeStatus: enabled
▿ connectionProperties:
    • tunnelState: {tunnel}
▿ capabilities:
    • Install Application (com.apple.coredevice.feature.install-app)
    • Launch Application (com.apple.coredevice.feature.launch-app)
"""
        if args[:3] == ["security", "find-identity", "-v"]:
          return '1) HASH "Apple Development: Alice (ABCDE12345)"'
        return ""

      doctor.preflight.command_output = command_output
      facts = doctor.collect_facts(now=datetime.datetime(2026, 7, 6, tzinfo=datetime.timezone.utc))
      self.assertFalse(facts["ready"])
      self.assertEqual(len(facts["device"]["visibleDevices"]), 3)
      self.assertEqual(facts["device"]["visibleDevices"][0]["state"], "connected (no DDI)")
      self.assertEqual(facts["device"]["visibleDevices"][1]["state"], "available (paired)")
      self.assertEqual(facts["device"]["visibleDevices"][2]["state"], "unavailable")
      self.assertTrue(
        any(
          "visible devices" in error and "available (paired)" in error and "unavailable" in error
          for error in facts["errors"]
        )
      )
      detail_summaries = facts["device"]["detailSummaries"]
      self.assertEqual(len(detail_summaries), 3)
      self.assertEqual(detail_summaries[1]["identifier"], "21ABE4B1-1509-5D45-9645-75A52D050D68")
      self.assertEqual(detail_summaries[1]["tunnelState"], "connected")
      self.assertEqual(detail_summaries[1]["ddiServicesAvailable"], "true")
      self.assertTrue(detail_summaries[1]["installApplicationCapable"])
      self.assertTrue(detail_summaries[1]["launchApplicationCapable"])
      self.assertEqual(detail_summaries[2]["tunnelState"], "unavailable")
      action_codes = {action["code"] for action in facts["recommendedActions"]}
      self.assertIn("device.coredevice_transport_not_ready", action_codes)
    finally:
      if previous_device_id is None:
        os.environ.pop(preflight.DEVICE_ID_ENV, None)
      else:
        os.environ[preflight.DEVICE_ID_ENV] = previous_device_id
      doctor.preflight.read = saved["read"]
      doctor.preflight.resolve_development_team = saved["resolve_development_team"]
      doctor.preflight.resolve_product_bundle_identifier = saved["resolve_product_bundle_identifier"]
      doctor.preflight.check_iphoneos_sdk = saved["check_iphoneos_sdk"]
      doctor.preflight.command_output = saved["command_output"]

  def test_auto_provisioning_requires_clean_xcode_account_probe(self) -> None:
    previous_allow = os.environ.get(preflight.DEVICE_ALLOW_PROVISIONING_UPDATES_ENV)
    previous_disable_icloud = os.environ.get(preflight.DEVICE_DISABLE_ICLOUD_ENTITLEMENTS_ENV)
    captured_probe: dict[str, object] = {}
    saved = {
      "read": doctor.preflight.read,
      "resolve_development_team": doctor.preflight.resolve_development_team,
      "resolve_product_bundle_identifier": doctor.preflight.resolve_product_bundle_identifier,
      "check_iphoneos_sdk": doctor.preflight.check_iphoneos_sdk,
      "select_physical_device_identifier": doctor.preflight.select_physical_device_identifier,
      "command_output": doctor.preflight.command_output,
      "validated_physical_device_udid": doctor.preflight.validated_physical_device_udid,
      "check_apple_development_identity": doctor.preflight.check_apple_development_identity,
      "run_xcode_automatic_provisioning_probe": doctor.preflight.run_xcode_automatic_provisioning_probe,
      "scan_profiles": doctor.scan_profiles,
    }
    try:
      os.environ[preflight.DEVICE_ALLOW_PROVISIONING_UPDATES_ENV] = "1"
      os.environ[preflight.DEVICE_DISABLE_ICLOUD_ENTITLEMENTS_ENV] = "1"
      doctor.preflight.read = lambda path, label=None: "project"
      doctor.preflight.resolve_development_team = lambda project_text: "ABCDE12345"
      doctor.preflight.resolve_product_bundle_identifier = lambda project_text: "com.example.qixi.local-device"
      doctor.preflight.check_iphoneos_sdk = lambda: None
      doctor.preflight.select_physical_device_identifier = lambda: "DEVICEID"
      doctor.preflight.command_output = lambda args, label, timeout=15: (
        "reality: physical\nudid: 00008142-000E25660120401C\nddiServicesAvailable: true\ndeveloperModeStatus: enabled"
        if "devicectl" in args
        else '1) HASH "Apple Development: Alice (ABCDE12345)"'
      )
      doctor.preflight.validated_physical_device_udid = lambda details: "00008142-000E25660120401C"
      doctor.preflight.check_apple_development_identity = lambda team, identity_output, profile_payload=None: None
      doctor.scan_profiles = lambda **kwargs: {
        "directory": "/tmp/profiles",
        "exists": True,
        "isDirectory": True,
        "scanned": 0,
        "decodeErrors": [],
        "profiles": [],
        "matchingProfiles": [],
      }
      def fake_probe(team, device_udid, **kwargs):
        captured_probe.update({"team": team, "device_udid": device_udid, **kwargs})
        return {
          "checked": True,
          "ok": False,
          "returnCode": 0,
          "derivedData": "/tmp/qixi-probe",
          "problems": ["DVTDeveloperAccountManager: Failed to load credentials"],
        }

      doctor.preflight.run_xcode_automatic_provisioning_probe = fake_probe
      facts = doctor.collect_facts(now=datetime.datetime(2026, 7, 6, tzinfo=datetime.timezone.utc))
      self.assertFalse(facts["xcodeAccountProbe"]["ok"])
      self.assertFalse(facts["ready"])
      self.assertIn("Failed to load credentials", facts["xcodeAccountProbe"]["problems"][0])
      self.assertEqual(captured_probe["bundle_id"], "com.example.qixi.local-device")
      self.assertTrue(captured_probe["disable_icloud_entitlements"])
      self.assertTrue(any("automatic provisioning was requested" in error for error in facts["errors"]))
      action_codes = {action["code"] for action in facts["recommendedActions"]}
      self.assertIn("signing.xcode_account_probe_failed", action_codes)
    finally:
      if previous_allow is None:
        os.environ.pop(preflight.DEVICE_ALLOW_PROVISIONING_UPDATES_ENV, None)
      else:
        os.environ[preflight.DEVICE_ALLOW_PROVISIONING_UPDATES_ENV] = previous_allow
      if previous_disable_icloud is None:
        os.environ.pop(preflight.DEVICE_DISABLE_ICLOUD_ENTITLEMENTS_ENV, None)
      else:
        os.environ[preflight.DEVICE_DISABLE_ICLOUD_ENTITLEMENTS_ENV] = previous_disable_icloud
      doctor.preflight.read = saved["read"]
      doctor.preflight.resolve_development_team = saved["resolve_development_team"]
      doctor.preflight.resolve_product_bundle_identifier = saved["resolve_product_bundle_identifier"]
      doctor.preflight.check_iphoneos_sdk = saved["check_iphoneos_sdk"]
      doctor.preflight.select_physical_device_identifier = saved["select_physical_device_identifier"]
      doctor.preflight.command_output = saved["command_output"]
      doctor.preflight.validated_physical_device_udid = saved["validated_physical_device_udid"]
      doctor.preflight.check_apple_development_identity = saved["check_apple_development_identity"]
      doctor.preflight.run_xcode_automatic_provisioning_probe = saved["run_xcode_automatic_provisioning_probe"]
      doctor.scan_profiles = saved["scan_profiles"]

  def test_recommended_actions_report_team_mismatch_and_missing_profile(self) -> None:
    facts = {
      "ready": False,
      "project": {"team": "Q795QF39Y5", "bundleIdentifier": "com.qixi.localanalysis"},
      "device": {
        "udid": "00008142-000E25660120401C",
        "visibleDevices": [],
        "detailSummaries": [],
      },
      "identities": {
        "matchingTeamIdentityCount": 0,
        "availableTeamIdentifiers": ["CL4J6FUCTT", "CTUFVJ5XX2"],
      },
      "profiles": {
        "exists": True,
        "matchingProfiles": [],
      },
      "environment": {"allowProvisioningUpdates": False},
      "xcodeAccountProbe": {"checked": False, "ok": None},
    }
    actions = doctor.recommended_actions(facts)
    action_codes = {action["code"] for action in actions}
    self.assertIn("device.not_visible", action_codes)
    self.assertIn("signing.team_identity_missing", action_codes)
    self.assertIn("signing.profile_missing", action_codes)
    team_action = next(action for action in actions if action["code"] == "signing.team_identity_missing")
    self.assertIn("QIXI_DEVICE_DEVELOPMENT_TEAM", team_action["message"])
    self.assertIn("CL4J6FUCTT", team_action["message"])

  def test_recommended_actions_accept_profile_certificate_identity_match(self) -> None:
    facts = {
      "ready": False,
      "project": {"team": "Q795QF39Y5", "bundleIdentifier": "com.zyx.qixi.local-device"},
      "device": {
        "identifier": "21ABE4B1-1509-5D45-9645-75A52D050D68",
        "udid": "00008142-000E25660120401C",
        "visibleDevices": [
          {
            "identifier": "21ABE4B1-1509-5D45-9645-75A52D050D68",
            "state": "connected",
          }
        ],
        "detailSummaries": [
          {
            "identifier": "21ABE4B1-1509-5D45-9645-75A52D050D68",
            "status": "ok",
            "udid": "00008142-000E25660120401C",
            "developerModeStatus": "enabled",
            "ddiServicesAvailable": "true",
            "tunnelState": "connected",
            "installApplicationCapable": True,
            "launchApplicationCapable": True,
          }
        ],
      },
      "identities": {
        "matchingTeamIdentityCount": 0,
        "availableTeamIdentifiers": ["CTUFVJ5XX2"],
      },
      "profiles": {
        "exists": True,
        "matchingProfiles": ["/tmp/xcode-managed.mobileprovision"],
        "matchingProfileInstalledCertificateMatches": True,
      },
      "environment": {"allowProvisioningUpdates": False},
      "xcodeAccountProbe": {"checked": False, "ok": None},
    }
    action_codes = {action["code"] for action in doctor.recommended_actions(facts)}
    self.assertNotIn("signing.team_identity_missing", action_codes)
    self.assertNotIn("signing.identity_missing", action_codes)
    self.assertNotIn("signing.profile_missing", action_codes)

  def test_recommended_actions_ignore_unselected_unavailable_devices(self) -> None:
    facts = {
      "ready": False,
      "project": {"team": "Q795QF39Y5", "bundleIdentifier": "com.qixi.localanalysis"},
      "device": {
        "identifier": "21ABE4B1-1509-5D45-9645-75A52D050D68",
        "udid": "00008142-000E25660120401C",
        "visibleDevices": [
          {
            "identifier": "00FDDA18-29B3-50C5-AFE3-3E634086C367",
            "state": "unavailable",
          },
          {
            "identifier": "21ABE4B1-1509-5D45-9645-75A52D050D68",
            "state": "available (paired)",
          },
        ],
        "detailSummaries": [
          {
            "identifier": "00FDDA18-29B3-50C5-AFE3-3E634086C367",
            "status": "ok",
            "udid": "00008150-0012612121B8C01C",
            "developerModeStatus": "disabled",
            "ddiServicesAvailable": "false",
            "tunnelState": "unavailable",
            "installApplicationCapable": False,
            "launchApplicationCapable": False,
          },
          {
            "identifier": "21ABE4B1-1509-5D45-9645-75A52D050D68",
            "status": "ok",
            "udid": "00008142-000E25660120401C",
            "developerModeStatus": "enabled",
            "ddiServicesAvailable": "true",
            "tunnelState": "connected",
            "installApplicationCapable": True,
            "launchApplicationCapable": True,
          },
        ],
      },
      "identities": {
        "matchingTeamIdentityCount": 0,
        "availableTeamIdentifiers": ["CL4J6FUCTT", "CTUFVJ5XX2"],
      },
      "profiles": {
        "exists": False,
        "matchingProfiles": [],
      },
      "environment": {"allowProvisioningUpdates": False},
      "xcodeAccountProbe": {"checked": False, "ok": None},
    }
    actions = doctor.recommended_actions(facts)
    action_codes = {action["code"] for action in actions}
    self.assertNotIn("device.coredevice_transport_not_ready", action_codes)
    self.assertNotIn("device.not_probeable", action_codes)
    self.assertNotIn("device.not_visible", action_codes)
    self.assertIn("signing.team_identity_missing", action_codes)
    self.assertIn("signing.profile_missing", action_codes)

  def test_recommended_actions_report_selected_device_transport_blocker(self) -> None:
    facts = {
      "ready": False,
      "project": {"team": "ABCDE12345", "bundleIdentifier": "com.qixi.localanalysis"},
      "device": {
        "identifier": "21ABE4B1-1509-5D45-9645-75A52D050D68",
        "udid": "00008142-000E25660120401C",
        "visibleDevices": [
          {
            "identifier": "21ABE4B1-1509-5D45-9645-75A52D050D68",
            "state": "available (paired)",
          },
        ],
        "detailSummaries": [
          {
            "identifier": "21ABE4B1-1509-5D45-9645-75A52D050D68",
            "status": "ok",
            "udid": "00008142-000E25660120401C",
            "developerModeStatus": "enabled",
            "ddiServicesAvailable": "false",
            "tunnelState": "unavailable",
            "installApplicationCapable": True,
            "launchApplicationCapable": False,
          },
        ],
      },
      "identities": {
        "matchingTeamIdentityCount": 1,
        "availableTeamIdentifiers": ["ABCDE12345"],
      },
      "profiles": {
        "exists": True,
        "matchingProfiles": [],
      },
      "environment": {"allowProvisioningUpdates": False},
      "xcodeAccountProbe": {"checked": False, "ok": None},
    }
    actions = doctor.recommended_actions(facts)
    action_codes = {action["code"] for action in actions}
    self.assertIn("device.coredevice_transport_not_ready", action_codes)
    self.assertIn("signing.profile_missing", action_codes)

  def test_recommended_actions_are_empty_when_ready(self) -> None:
    self.assertEqual(doctor.recommended_actions({"ready": True}), [])


if __name__ == "__main__":
  unittest.main()
