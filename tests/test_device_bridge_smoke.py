#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import json
import os
import pathlib
import plistlib
import sys
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import qixi_device_bridge_smoke as smoke  # noqa: E402


@contextlib.contextmanager
def patched_env(**updates: str):
  previous = {key: os.environ.get(key) for key in updates}
  try:
    for key, value in updates.items():
      os.environ[key] = value
    yield
  finally:
    for key, value in previous.items():
      if value is None:
        os.environ.pop(key, None)
      else:
        os.environ[key] = value


class DeviceBridgeSmokeTests(unittest.TestCase):
  def test_xcodebuild_args_target_physical_udid_and_allow_team_override(self) -> None:
    args = smoke.build_xcodebuild_args(
      "00008142-000E25660120401C",
      pathlib.Path("/tmp/qixi-device-derived"),
      "ABCDE12345",
      bundle_id="com.example.qixi.local-device",
      disable_icloud_entitlements=True,
    )
    self.assertIn("-destination", args)
    self.assertIn("id=00008142-000E25660120401C", args)
    self.assertIn("-derivedDataPath", args)
    self.assertIn("/tmp/qixi-device-derived", args)
    self.assertIn("DEVELOPMENT_TEAM=ABCDE12345", args)
    self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=com.example.qixi.local-device", args)
    self.assertIn("CODE_SIGN_ENTITLEMENTS=", args)

    args_without_team = smoke.build_xcodebuild_args(
      "00008142-000E25660120401C",
      pathlib.Path("/tmp/qixi-device-derived"),
      None,
    )
    self.assertNotIn("DEVELOPMENT_TEAM=", " ".join(args_without_team))
    self.assertNotIn("PRODUCT_BUNDLE_IDENTIFIER=", " ".join(args_without_team))
    self.assertNotIn("CODE_SIGN_ENTITLEMENTS=", " ".join(args_without_team))
    self.assertNotIn("-allowProvisioningUpdates", args_without_team)

    args_with_provisioning_updates = smoke.build_xcodebuild_args(
      "00008142-000E25660120401C",
      pathlib.Path("/tmp/qixi-device-derived"),
      "ABCDE12345",
      allow_provisioning_updates=True,
    )
    self.assertIn("-allowProvisioningUpdates", args_with_provisioning_updates)
    self.assertIn("-allowProvisioningDeviceRegistration", args_with_provisioning_updates)
    self.assertLess(args_with_provisioning_updates.index("-allowProvisioningUpdates"), args_with_provisioning_updates.index("build"))

  def test_bundle_override_requires_explicit_icloud_entitlement_choice(self) -> None:
    with self.assertRaisesRegex(smoke.DeviceBridgeSmokeError, "QIXI_DEVICE_DISABLE_ICLOUD_ENTITLEMENTS=1"):
      smoke.validate_bridge_signing_overrides("com.example.qixi.local-device", False)

    smoke.validate_bridge_signing_overrides("com.example.qixi.local-device", True)
    smoke.validate_bridge_signing_overrides(smoke.DEFAULT_BUNDLE_ID, False)
    with patched_env(**{smoke.DEVICE_ALLOW_BUNDLE_OVERRIDE_WITH_ICLOUD_ENV: "1"}):
      smoke.validate_bridge_signing_overrides("com.example.qixi.local-device", False)

  def test_plan_only_signing_blockers_are_collected_without_building(self) -> None:
    identity_output = """
  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Qixi Developer (ABCDE12345)"
     1 valid identities found
""".strip()
    with tempfile.TemporaryDirectory() as tmpdir:
      with patched_env(**{smoke.device_preflight.DEVICE_PROVISIONING_PROFILE_DIR_ENV: tmpdir}):
        blockers = smoke.collect_plan_only_signing_blockers(
          "ABCDE12345",
          "com.example.qixi.local-device",
          "00008142-000E25660120401C",
          identity_output=identity_output,
        )
    self.assertEqual(len(blockers), 1)
    self.assertIn("no installed iOS App Development provisioning profile", blockers[0])
    self.assertIn("com.example.qixi.local-device", blockers[0])

    with tempfile.TemporaryDirectory() as tmpdir:
      with patched_env(**{smoke.device_preflight.DEVICE_PROVISIONING_PROFILE_DIR_ENV: tmpdir}):
        blockers = smoke.collect_plan_only_signing_blockers(
          "ABCDE12345",
          "com.example.qixi.local-device",
          "00008142-000E25660120401C",
          allow_provisioning_updates=True,
          identity_output=identity_output,
        )
    self.assertEqual(len(blockers), 1)
    self.assertIn("automatic provisioning is requested", blockers[0])
    self.assertIn("plan-only mode found no installed iOS App Development provisioning profile", blockers[0])
    self.assertIn("real bridge smoke", blockers[0])

    no_identity = "     0 valid identities found\n"
    with tempfile.TemporaryDirectory() as tmpdir:
      with patched_env(**{smoke.device_preflight.DEVICE_PROVISIONING_PROFILE_DIR_ENV: tmpdir}):
        blockers = smoke.collect_plan_only_signing_blockers(
          "ABCDE12345",
          "com.example.qixi.local-device",
          "00008142-000E25660120401C",
          identity_output=no_identity,
        )
    self.assertTrue(any("no Apple Development code-signing identities" in blocker for blocker in blockers))
    self.assertTrue(any("no installed iOS App Development provisioning profile" in blocker for blocker in blockers))

  def test_devicectl_install_launch_and_copy_commands_are_machine_readable(self) -> None:
    install = smoke.devicectl_install_args(
      "21ABE4B1-1509-5D45-9645-75A52D050D68",
      pathlib.Path("/tmp/Qixi.app"),
      pathlib.Path("/tmp/install.json"),
      30,
    )
    self.assertEqual(install[:5], ["xcrun", "devicectl", "device", "install", "app"])
    self.assertIn("--json-output", install)
    self.assertIn("/tmp/install.json", install)

    launch_env = {
      "QIXI_ANALYSIS_RUNTIME": "httpBridge",
      "QIXI_BACKEND_URL": "http://192.168.3.61:8765",
      "QIXI_SKIP_ONBOARDING": "1",
      "QIXI_APP_LANGUAGE": "zh-Hans",
    }
    launch = smoke.devicectl_launch_args(
      "21ABE4B1-1509-5D45-9645-75A52D050D68",
      smoke.DEFAULT_BUNDLE_ID,
      launch_env,
      pathlib.Path("/tmp/launch.json"),
      30,
    )
    self.assertEqual(launch[:5], ["xcrun", "devicectl", "device", "process", "launch"])
    self.assertIn("--terminate-existing", launch)
    encoded_env = launch[launch.index("--environment-variables") + 1]
    self.assertEqual(json.loads(encoded_env), launch_env)
    self.assertIn(smoke.DEFAULT_BUNDLE_ID, launch)

    copy = smoke.devicectl_copy_app_support_args(
      "21ABE4B1-1509-5D45-9645-75A52D050D68",
      smoke.DEFAULT_BUNDLE_ID,
      pathlib.Path("/tmp/app-support"),
      pathlib.Path("/tmp/copy.json"),
      30,
    )
    for token in (
      "copy",
      "from",
      "--domain-type",
      "appDataContainer",
      "--domain-identifier",
      smoke.DEFAULT_BUNDLE_ID,
      "Library/Application Support/Qixi",
      "--remove-existing-content",
      "true",
    ):
      self.assertIn(token, copy)

  def test_validate_built_app_requires_fresh_executable_and_bundle_id(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      app = pathlib.Path(tmpdir) / "Qixi.app"
      app.mkdir()
      executable = app / "Qixi"
      executable.write_text("#!/bin/sh\n", encoding="utf-8")
      executable.chmod(0o755)
      with (app / "Info.plist").open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": smoke.DEFAULT_BUNDLE_ID}, handle)

      marker_ns = executable.stat().st_mtime_ns - 1
      facts = smoke.validate_built_app(app, marker_ns, smoke.DEFAULT_BUNDLE_ID)
      self.assertEqual(facts["bundleIdentifier"], smoke.DEFAULT_BUNDLE_ID)

      # Incremental xcodebuild may reuse an app executable older than this smoke
      # run's marker when the built app is still newer than every source input.
      smoke.validate_built_app(app, executable.stat().st_mtime_ns + 10_000, smoke.DEFAULT_BUNDLE_ID)

      os.utime(executable, ns=(1, 1))
      with self.assertRaisesRegex(smoke.DeviceBridgeSmokeError, "stale relative to app inputs"):
        smoke.validate_built_app(app, time.time_ns(), smoke.DEFAULT_BUNDLE_ID)

      now_ns = time.time_ns()
      os.utime(executable, ns=(now_ns, now_ns))
      with self.assertRaisesRegex(smoke.DeviceBridgeSmokeError, "bundle id mismatch"):
        smoke.validate_built_app(app, now_ns - 1, "com.example.other")

  def test_launch_environment_is_bridge_only_and_language_configurable(self) -> None:
    previous_language = os.environ.get("QIXI_DEVICE_APP_LANGUAGE")
    previous_skip = os.environ.get("QIXI_DEVICE_SKIP_ONBOARDING")
    previous_engine = os.environ.get(smoke.DEVICE_AUTOMATION_SELECT_ENGINE_ENV)
    try:
      os.environ["QIXI_DEVICE_APP_LANGUAGE"] = "en"
      os.environ["QIXI_DEVICE_SKIP_ONBOARDING"] = "0"
      os.environ[smoke.DEVICE_AUTOMATION_SELECT_ENGINE_ENV] = "b18nbt"
      env = smoke.launch_environment("http://192.168.3.61:8765")
    finally:
      if previous_language is None:
        os.environ.pop("QIXI_DEVICE_APP_LANGUAGE", None)
      else:
        os.environ["QIXI_DEVICE_APP_LANGUAGE"] = previous_language
      if previous_skip is None:
        os.environ.pop("QIXI_DEVICE_SKIP_ONBOARDING", None)
      else:
        os.environ["QIXI_DEVICE_SKIP_ONBOARDING"] = previous_skip
      if previous_engine is None:
        os.environ.pop(smoke.DEVICE_AUTOMATION_SELECT_ENGINE_ENV, None)
      else:
        os.environ[smoke.DEVICE_AUTOMATION_SELECT_ENGINE_ENV] = previous_engine

    self.assertEqual(env["QIXI_ANALYSIS_RUNTIME"], "httpBridge")
    self.assertEqual(env["QIXI_BACKEND_URL"], "http://192.168.3.61:8765")
    self.assertEqual(env["QIXI_APP_LANGUAGE"], "en")
    self.assertEqual(env["QIXI_SKIP_ONBOARDING"], "0")
    self.assertEqual(env["QIXI_AUTOMATION_SELECT_ENGINE"], "b18nbt")

  def test_launch_environment_rejects_unknown_automation_engine(self) -> None:
    previous_engine = os.environ.get(smoke.DEVICE_AUTOMATION_SELECT_ENGINE_ENV)
    try:
      os.environ[smoke.DEVICE_AUTOMATION_SELECT_ENGINE_ENV] = "mock"
      with self.assertRaisesRegex(smoke.DeviceBridgeSmokeError, "QIXI_DEVICE_AUTOMATION_SELECT_ENGINE"):
        smoke.launch_environment("http://192.168.3.61:8765")
    finally:
      if previous_engine is None:
        os.environ.pop(smoke.DEVICE_AUTOMATION_SELECT_ENGINE_ENV, None)
      else:
        os.environ[smoke.DEVICE_AUTOMATION_SELECT_ENGINE_ENV] = previous_engine

  def test_backend_events_artifact_payload_requires_selected_engine_event(self) -> None:
    before = {"schemaVersion": 1, "latestSequence": 4, "count": 1, "events": []}
    after = {
      "schemaVersion": 1,
      "latestSequence": 6,
      "count": 2,
      "events": [
        {"sequence": 5, "kind": "engine", "path": "/api/engine", "engine": "b6"},
        {"sequence": 6, "kind": "analyze", "path": "/api/analyze", "engine": "b6"},
      ],
    }
    payload = smoke.backend_events_artifact_payload(
      origin="http://192.168.3.61:8765",
      launch_environment={"QIXI_AUTOMATION_SELECT_ENGINE": "b6"},
      before=before,
      after=after,
    )
    self.assertEqual(payload["expectedEngine"], "b6")
    self.assertTrue(payload["observedExpectedEngine"])
    self.assertEqual(payload["diagnosticCategory"], "none")
    self.assertEqual([event["sequence"] for event in payload["newEvents"]], [5, 6])

    missing = smoke.backend_events_artifact_payload(
      origin="http://192.168.3.61:8765",
      launch_environment={"QIXI_AUTOMATION_SELECT_ENGINE": "b18nbt"},
      before=before,
      after=after,
      diagnostic_hint="runtime diagnostic event=analysisFailed success=False: Denied over Wi-Fi",
    )
    self.assertFalse(missing["observedExpectedEngine"])
    self.assertIn("Denied over Wi-Fi", missing["diagnosticHint"])
    self.assertEqual(missing["diagnosticCategory"], "iosLocalNetworkDenied")
    self.assertIn("did not observe", smoke.backend_events_failure_message(missing))

    runtime_failure = smoke.backend_events_artifact_payload(
      origin="http://192.168.3.61:8765",
      launch_environment={"QIXI_AUTOMATION_SELECT_ENGINE": "b18nbt"},
      before=before,
      after=after,
      diagnostic_hint="runtime diagnostic event=analysisFailed success=False: generic bridge failure",
    )
    self.assertEqual(runtime_failure["diagnosticCategory"], "appRuntimeDiagnostic")

  def test_runtime_diagnostic_hint_is_bounded_and_single_line(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      app_support = pathlib.Path(tmpdir)
      (app_support / "runtime-diagnostics.qixi-state.json").write_text(
        json.dumps({
          "event": "analysisFailed",
          "success": False,
          "message": "Denied over Wi-Fi\nwith newline",
        }),
        encoding="utf-8",
      )
      hint = smoke.runtime_diagnostic_hint(app_support)
    self.assertIn("analysisFailed", hint)
    self.assertIn("Denied over Wi-Fi with newline", hint)

  def test_bridge_run_id_is_canonical_or_rejected(self) -> None:
    previous_run_id = os.environ.get("QIXI_DEVICE_BRIDGE_RUN_ID")
    try:
      os.environ["QIXI_DEVICE_BRIDGE_RUN_ID"] = "0123456789abcdef0123456789abcdef"
      self.assertEqual(smoke.bridge_run_id(), "0123456789abcdef0123456789abcdef")

      os.environ["QIXI_DEVICE_BRIDGE_RUN_ID"] = "01234567-89ab-cdef-0123-456789abcdef"
      with self.assertRaisesRegex(smoke.DeviceBridgeSmokeError, "32-character lowercase hex"):
        smoke.bridge_run_id()

      os.environ.pop("QIXI_DEVICE_BRIDGE_RUN_ID")
      generated = smoke.bridge_run_id()
      self.assertRegex(generated, r"^[0-9a-f]{32}$")
    finally:
      if previous_run_id is None:
        os.environ.pop("QIXI_DEVICE_BRIDGE_RUN_ID", None)
      else:
        os.environ["QIXI_DEVICE_BRIDGE_RUN_ID"] = previous_run_id

  def test_write_manifest_is_atomic_and_rejects_symlink_paths(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      directory = pathlib.Path(tmpdir)
      manifest = directory / "latest-device-bridge-smoke.json"
      smoke.write_manifest(manifest, {"schemaVersion": 1, "kind": "test"})
      self.assertEqual(json.loads(manifest.read_text(encoding="utf-8"))["kind"], "test")
      self.assertFalse((directory / f".{manifest.name}.{os.getpid()}.tmp").exists())

      target = directory / "target.json"
      target.write_text("{}", encoding="utf-8")
      linked_manifest = directory / "linked.json"
      try:
        linked_manifest.symlink_to(target)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")
      with self.assertRaisesRegex(smoke.device_preflight.DeviceRunPreflightError, "manifest path must not contain symbolic links"):
        smoke.write_manifest(linked_manifest, {"schemaVersion": 1})

  def test_write_manifest_uses_exclusive_temporary_file(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      directory = pathlib.Path(tmpdir)
      manifest = directory / "latest-device-bridge-smoke.json"
      stale_tmp = directory / f".{manifest.name}.{os.getpid()}.tmp"
      stale_tmp.write_text("stale", encoding="utf-8")
      with self.assertRaisesRegex(smoke.DeviceBridgeSmokeError, "manifest could not be written"):
        smoke.write_manifest(manifest, {"schemaVersion": 1})
      self.assertEqual(stale_tmp.read_text(encoding="utf-8"), "stale")

  def test_plan_only_manifest_records_preflight_blockers_and_stays_dry_run(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      manifest = pathlib.Path(tmpdir) / "latest-device-bridge-smoke.json"
      payload = {
        "schemaVersion": 1,
        "kind": "qixi-device-bridge-smoke",
        "dryRun": True,
        "preflight": {
          "planOnly": True,
          "strictPhysicalDeviceEnvironmentChecked": False,
          "signingBlockers": ["missing profile"],
          "notes": [],
        },
      }
      smoke.write_manifest(manifest, payload)
      written = json.loads(manifest.read_text(encoding="utf-8"))
      self.assertTrue(written["dryRun"])
      self.assertTrue(written["preflight"]["planOnly"])
      self.assertFalse(written["preflight"]["strictPhysicalDeviceEnvironmentChecked"])
      self.assertEqual(written["preflight"]["signingBlockers"], ["missing profile"])


if __name__ == "__main__":
  unittest.main()
