#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import datetime
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSPECTOR = ROOT / "scripts" / "qixi_device_bridge_smoke_inspect.py"

spec = importlib.util.spec_from_file_location("qixi_device_bridge_smoke_inspect", INSPECTOR)
assert spec is not None and spec.loader is not None
inspector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspector)


class DeviceBridgeSmokeInspectorTests(unittest.TestCase):
  def setUp(self) -> None:
    self.previous_root = inspector.ROOT
    self.tempdir = tempfile.TemporaryDirectory()
    self.addCleanup(self.tempdir.cleanup)
    self.root = pathlib.Path(self.tempdir.name)
    inspector.ROOT = self.root
    self.addCleanup(lambda: setattr(inspector, "ROOT", self.previous_root))

  def write_json(self, relative: str, payload: object) -> pathlib.Path:
    path = self.root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
    return path

  def snapshot_payload(self, engine: str = "none") -> dict[str, object]:
    return {
      "schemaVersion": 1,
      "savedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"),
      "saveReason": "launchReady",
      "selectedEngine": engine,
      "currentPly": 8,
      "mainLine": [],
      "komi": 7.5,
      "showTerritory": False,
      "analysisByEngine": {},
    }

  def write_app_support_snapshots(self, app_support: pathlib.Path, engine: str = "none") -> None:
    app_support.mkdir(parents=True, exist_ok=True)
    payload = self.snapshot_payload(engine)
    (app_support / "autosave.qixi-state.json").write_text(
      json.dumps(payload, sort_keys=True) + "\n",
      encoding="utf-8",
    )
    (app_support / "autosave.qixi-state.backup.json").write_text(
      json.dumps(payload, sort_keys=True) + "\n",
      encoding="utf-8",
    )
    (app_support / "runtime-diagnostics.qixi-state.json").write_text(
      json.dumps(
        {
          "schemaVersion": 1,
          "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"),
          "event": "engineSelected",
          "success": True,
          "selectedEngine": engine,
          "analysisRuntime": "httpBridge",
          "backendBaseURL": "http://192.168.3.61:8765",
          "message": "Selected engine.",
        },
        sort_keys=True,
      ) + "\n",
      encoding="utf-8",
    )

  def write_backend_events_artifact(
    self,
    relative: str = "artifacts/backend-events.json",
    *,
    engine: str = "b6",
    origin: str = "http://192.168.3.61:8765",
  ) -> pathlib.Path:
    return self.write_json(
      relative,
      {
        "schemaVersion": 1,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"),
        "origin": origin,
        "beforeLatestSequence": 0,
        "afterLatestSequence": 2,
        "expectedEngine": engine,
        "observedExpectedEngine": True,
        "diagnosticHint": "",
        "diagnosticCategory": "none",
        "newEvents": [
          {
            "sequence": 1,
            "kind": "engine",
            "path": "/api/engine",
            "engine": engine,
            "client": "192.168.3.42",
            "receivedAtUnixMs": 1780000000000,
          },
          {
            "sequence": 2,
            "kind": "analyze",
            "path": "/api/analyze",
            "engine": engine,
            "moveCount": 8,
            "maxVisits": 64,
            "client": "192.168.3.42",
            "receivedAtUnixMs": 1780000000100,
          },
        ],
        "after": {
          "schemaVersion": 1,
          "latestSequence": 2,
          "count": 2,
          "events": [],
        },
      },
    )

  def build_manifest(self) -> pathlib.Path:
    now = datetime.datetime.now(datetime.timezone.utc)
    started_at = now.isoformat(timespec="microseconds").replace("+00:00", "Z")
    generated_at = (now + datetime.timedelta(milliseconds=10)).isoformat(timespec="microseconds").replace("+00:00", "Z")
    completed_at = (now + datetime.timedelta(milliseconds=20)).isoformat(timespec="microseconds").replace("+00:00", "Z")
    artifact_payload = {"items": [{"name": "ok"}]}
    paths = {
      "install": self.write_json("artifacts/install.json", artifact_payload),
      "launch": self.write_json("artifacts/launch.json", artifact_payload),
      "processes": self.write_json("artifacts/processes.json", artifact_payload),
      "displays": self.write_json("artifacts/displays.json", artifact_payload),
      "appSupportCopy": self.write_json("artifacts/copy.json", artifact_payload),
    }
    app_support = self.root / "artifacts" / "app-support"
    self.write_app_support_snapshots(app_support)
    manifest = {
      "schemaVersion": 1,
      "kind": "qixi-device-bridge-smoke",
      "runId": "0123456789abcdef0123456789abcdef",
      "generatedAt": generated_at,
      "startedAt": started_at,
      "completedAt": completed_at,
      "dryRun": False,
      "device": {
        "identifier": "21ABE4B1-1509-5D45-9645-75A52D050D68",
        "udid": "00008142-000E25660120401C",
      },
      "backend": {
        "origin": "http://192.168.3.61:8765",
        "status": {
          "engine": "none",
          "engineId": "none",
          "state": "ready",
          "running": False,
          "paused": False,
        },
      },
      "app": {
        "bundleIdentifier": "com.qixi.localanalysis",
        "executable": str(self.root / "Qixi.app" / "Qixi"),
        "infoPlist": str(self.root / "Qixi.app" / "Info.plist"),
      },
      "artifacts": {
        **{key: str(value) for key, value in paths.items()},
        "appSupport": str(app_support),
      },
      "commands": {
        "xcodebuild": ["xcodebuild", "-destination", "id=00008142-000E25660120401C", "build"],
        "install": [
          "xcrun",
          "devicectl",
          "device",
          "install",
          "app",
          "--device",
          "21ABE4B1-1509-5D45-9645-75A52D050D68",
          "/tmp/Qixi.app",
          "--json-output",
          str(paths["install"]),
        ],
        "launch": [
          "xcrun",
          "devicectl",
          "device",
          "process",
          "launch",
          "--device",
          "21ABE4B1-1509-5D45-9645-75A52D050D68",
          "--terminate-existing",
          "--environment-variables",
          json.dumps(
            {
              "QIXI_ANALYSIS_RUNTIME": "httpBridge",
              "QIXI_BACKEND_URL": "http://192.168.3.61:8765",
              "QIXI_SKIP_ONBOARDING": "1",
              "QIXI_APP_LANGUAGE": "zh-Hans",
            },
            separators=(",", ":"),
            sort_keys=True,
          ),
          "com.qixi.localanalysis",
          "--json-output",
          str(paths["launch"]),
        ],
        "processes": [
          "xcrun",
          "devicectl",
          "device",
          "info",
          "processes",
          "--device",
          "21ABE4B1-1509-5D45-9645-75A52D050D68",
          "--json-output",
          str(paths["processes"]),
        ],
        "displays": [
          "xcrun",
          "devicectl",
          "device",
          "info",
          "displays",
          "--device",
          "21ABE4B1-1509-5D45-9645-75A52D050D68",
          "--json-output",
          str(paths["displays"]),
        ],
        "copyAppSupport": [
          "xcrun",
          "devicectl",
          "device",
          "copy",
          "from",
          "--device",
          "21ABE4B1-1509-5D45-9645-75A52D050D68",
          "--domain-type",
          "appDataContainer",
          "--domain-identifier",
          "com.qixi.localanalysis",
          "--source",
          "Library/Application Support/Qixi",
          "--destination",
          str(app_support),
          "--remove-existing-content",
          "true",
          "--json-output",
          str(paths["appSupportCopy"]),
        ],
      },
      "timingsMs": {
        "build": 10,
        "install": 11,
        "launch": 12,
        "launchSettle": 13,
        "processes": 14,
        "displays": 15,
        "copyAppSupport": 16,
      },
    }
    return self.write_json("latest-device-bridge-smoke.json", manifest)

  def build_plan_manifest(self) -> pathlib.Path:
    now = datetime.datetime.now(datetime.timezone.utc)
    started_at = now.isoformat(timespec="microseconds").replace("+00:00", "Z")
    generated_at = (now + datetime.timedelta(milliseconds=10)).isoformat(timespec="microseconds").replace("+00:00", "Z")
    completed_at = (now + datetime.timedelta(milliseconds=20)).isoformat(timespec="microseconds").replace("+00:00", "Z")
    bundle_id = "com.example.qixi.local-device"
    device_identifier = "21ABE4B1-1509-5D45-9645-75A52D050D68"
    device_udid = "00008142-000E25660120401C"
    backend_origin = "http://192.168.3.61:8765"
    app_support = self.root / "artifacts" / "planned-app-support"
    manifest = {
      "schemaVersion": 1,
      "kind": "qixi-device-bridge-smoke",
      "runId": "0123456789abcdef0123456789abcdef",
      "generatedAt": generated_at,
      "startedAt": started_at,
      "completedAt": completed_at,
      "dryRun": True,
      "device": {"identifier": device_identifier, "udid": device_udid},
      "backend": {
        "origin": backend_origin,
        "status": {
          "engine": "none",
          "engineId": "none",
          "state": "ready",
          "running": False,
          "paused": False,
        },
      },
      "app": {"bundleIdentifier": bundle_id, "executable": "", "infoPlist": ""},
      "preflight": {
        "planOnly": True,
        "strictPhysicalDeviceEnvironmentChecked": False,
        "signingBlockers": [
          "strict physical-device preflight found no installed iOS App Development provisioning profile"
        ],
        "notes": [],
      },
      "signing": {
        "developmentTeamOverride": "CL4J6FUCTT",
        "bundleIdentifier": bundle_id,
        "iCloudEntitlementsDisabledForLocalBridge": True,
      },
      "artifacts": {
        "install": str(self.root / "artifacts" / "planned-install.json"),
        "launch": str(self.root / "artifacts" / "planned-launch.json"),
        "processes": str(self.root / "artifacts" / "planned-processes.json"),
        "displays": str(self.root / "artifacts" / "planned-displays.json"),
        "appSupport": str(app_support),
        "appSupportCopy": str(self.root / "artifacts" / "planned-copy.json"),
      },
      "commands": {
        "xcodebuild": [
          "xcodebuild",
          "-project",
          "/repo/qixi-ios-native/Qixi.xcodeproj",
          "-scheme",
          "Qixi",
          "-destination",
          f"id={device_udid}",
          "-configuration",
          "Debug",
          "-derivedDataPath",
          "/private/tmp/qixi-device-bridge-derived",
          "build",
          "DEVELOPMENT_TEAM=CL4J6FUCTT",
          f"PRODUCT_BUNDLE_IDENTIFIER={bundle_id}",
          "CODE_SIGN_ENTITLEMENTS=",
        ],
        "install": [
          "xcrun",
          "devicectl",
          "device",
          "install",
          "app",
          "--device",
          device_identifier,
          "/tmp/Qixi.app",
          "--json-output",
          str(self.root / "artifacts" / "planned-install.json"),
        ],
        "launch": [
          "xcrun",
          "devicectl",
          "device",
          "process",
          "launch",
          "--device",
          device_identifier,
          "--terminate-existing",
          "--environment-variables",
          json.dumps(
            {
              "QIXI_ANALYSIS_RUNTIME": "httpBridge",
              "QIXI_BACKEND_URL": backend_origin,
              "QIXI_SKIP_ONBOARDING": "1",
              "QIXI_APP_LANGUAGE": "zh-Hans",
            },
            separators=(",", ":"),
            sort_keys=True,
          ),
          bundle_id,
          "--json-output",
          str(self.root / "artifacts" / "planned-launch.json"),
        ],
        "processes": [
          "xcrun",
          "devicectl",
          "device",
          "info",
          "processes",
          "--device",
          device_identifier,
          "--json-output",
          str(self.root / "artifacts" / "planned-processes.json"),
        ],
        "displays": [
          "xcrun",
          "devicectl",
          "device",
          "info",
          "displays",
          "--device",
          device_identifier,
          "--json-output",
          str(self.root / "artifacts" / "planned-displays.json"),
        ],
        "copyAppSupport": [
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
          str(app_support),
          "--remove-existing-content",
          "true",
          "--json-output",
          str(self.root / "artifacts" / "planned-copy.json"),
        ],
      },
      "timingsMs": {},
    }
    return self.write_json("latest-device-bridge-plan.json", manifest)

  def build_failure_manifest(self) -> pathlib.Path:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    app_support = pathlib.Path(payload["artifacts"]["appSupport"])
    self.write_app_support_snapshots(app_support, engine="b6")
    diagnostic_message = (
      "Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\" "
      "UserInfo={_NSURLErrorNWPathKey=unsatisfied (Denied over Wi-Fi interface)}"
    )
    (app_support / "runtime-diagnostics.qixi-state.json").write_text(
      json.dumps(
        {
          "schemaVersion": 1,
          "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"),
          "event": "analysisFailed",
          "success": False,
          "selectedEngine": "b6",
          "analysisRuntime": "httpBridge",
          "backendBaseURL": payload["backend"]["origin"],
          "message": diagnostic_message,
        },
        sort_keys=True,
      ) + "\n",
      encoding="utf-8",
    )
    env_index = payload["commands"]["launch"].index("--environment-variables") + 1
    env = json.loads(payload["commands"]["launch"][env_index])
    env["QIXI_AUTOMATION_SELECT_ENGINE"] = "b6"
    payload["commands"]["launch"][env_index] = json.dumps(env, separators=(",", ":"), sort_keys=True)
    backend_events_path = self.write_backend_events_artifact("artifacts/failure-backend-events.json", engine="b6")
    backend_events = json.loads(backend_events_path.read_text(encoding="utf-8"))
    backend_events["afterLatestSequence"] = 0
    backend_events["observedExpectedEngine"] = False
    backend_events["diagnosticHint"] = f"runtime diagnostic event=analysisFailed success=False: {diagnostic_message[:320]}"
    backend_events["diagnosticCategory"] = "iosLocalNetworkDenied"
    backend_events["newEvents"] = []
    backend_events_path.write_text(json.dumps(backend_events, sort_keys=True) + "\n", encoding="utf-8")
    payload["kind"] = "qixi-device-bridge-smoke-failure"
    payload["failure"] = {
      "stage": "backendEvents",
      "message": (
        "device bridge smoke did not observe the launched app selecting backend engine 'b6'; "
        f"check iOS local-network permission and launch foreground state; {backend_events['diagnosticHint']}"
      ),
    }
    payload["artifacts"]["backendEvents"] = str(backend_events_path)
    return self.write_json("latest-device-bridge-failure.json", payload)

  def test_valid_manifest_passes(self) -> None:
    path = self.build_manifest()
    payload = inspector.validate_manifest(path)
    self.assertEqual(payload["kind"], "qixi-device-bridge-smoke")

  def test_failure_manifest_is_not_accepted_as_real_device_evidence(self) -> None:
    path = self.build_failure_manifest()
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "kind must be qixi-device-bridge-smoke"):
      inspector.validate_manifest(path)

  def test_valid_failure_manifest_passes_only_failure_inspector(self) -> None:
    path = self.build_failure_manifest()
    payload = inspector.validate_failure_manifest(path)
    self.assertEqual(payload["kind"], "qixi-device-bridge-smoke-failure")
    self.assertEqual(payload["failure"]["stage"], "backendEvents")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "kind must be qixi-device-bridge-smoke-failure"):
      inspector.validate_failure_manifest(self.build_manifest())

  def test_failure_manifest_rejects_contradictory_or_weak_failure_evidence(self) -> None:
    path = self.build_failure_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    backend_events_path = pathlib.Path(payload["artifacts"]["backendEvents"])
    backend_events = json.loads(backend_events_path.read_text(encoding="utf-8"))
    backend_events["observedExpectedEngine"] = True
    backend_events_path.write_text(json.dumps(backend_events), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "observedExpectedEngine=false"):
      inspector.validate_failure_manifest(path)

    path = self.build_failure_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    app_support = pathlib.Path(payload["artifacts"]["appSupport"])
    diagnostic = json.loads((app_support / "runtime-diagnostics.qixi-state.json").read_text(encoding="utf-8"))
    diagnostic["success"] = True
    (app_support / "runtime-diagnostics.qixi-state.json").write_text(json.dumps(diagnostic), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "success=false"):
      inspector.validate_failure_manifest(path)

    path = self.build_failure_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    backend_events_path = pathlib.Path(payload["artifacts"]["backendEvents"])
    backend_events = json.loads(backend_events_path.read_text(encoding="utf-8"))
    backend_events["diagnosticCategory"] = "iosLocalNetworkDenied"
    backend_events["diagnosticHint"] = "runtime diagnostic event=analysisFailed success=False: timeout"
    backend_events_path.write_text(json.dumps(backend_events), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "backed by Wi-Fi denial diagnostics"):
      inspector.validate_failure_manifest(path)

    path = self.build_failure_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    backend_events_path = pathlib.Path(payload["artifacts"]["backendEvents"])
    backend_events = json.loads(backend_events_path.read_text(encoding="utf-8"))
    backend_events["diagnosticCategory"] = "none"
    backend_events_path.write_text(json.dumps(backend_events), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "must describe an app runtime failure"):
      inspector.validate_failure_manifest(path)

  def test_selected_engine_launch_env_must_match_app_support_snapshot(self) -> None:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    app_support = pathlib.Path(payload["artifacts"]["appSupport"])
    self.write_app_support_snapshots(app_support, engine="b6")
    payload["artifacts"]["backendEvents"] = str(self.write_backend_events_artifact(engine="b6"))
    env_index = payload["commands"]["launch"].index("--environment-variables") + 1
    env = json.loads(payload["commands"]["launch"][env_index])
    env["QIXI_AUTOMATION_SELECT_ENGINE"] = "b6"
    payload["commands"]["launch"][env_index] = json.dumps(env, separators=(",", ":"), sort_keys=True)
    path.write_text(json.dumps(payload), encoding="utf-8")
    checked = inspector.validate_manifest(path)
    self.assertEqual(
      json.loads(checked["commands"]["launch"][env_index])["QIXI_AUTOMATION_SELECT_ENGINE"],
      "b6",
    )

    self.write_app_support_snapshots(app_support, engine="b18nbt")
    with self.assertRaisesRegex(
      inspector.DeviceBridgeSmokeArtifactError,
      "selectedEngine must match QIXI_AUTOMATION_SELECT_ENGINE=b6",
    ):
      inspector.validate_manifest(path)

  def test_selected_engine_launch_env_requires_backend_event_evidence(self) -> None:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    app_support = pathlib.Path(payload["artifacts"]["appSupport"])
    self.write_app_support_snapshots(app_support, engine="b6")
    env_index = payload["commands"]["launch"].index("--environment-variables") + 1
    env = json.loads(payload["commands"]["launch"][env_index])
    env["QIXI_AUTOMATION_SELECT_ENGINE"] = "b6"
    payload["commands"]["launch"][env_index] = json.dumps(env, separators=(",", ":"), sort_keys=True)
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "artifacts.backendEvents"):
      inspector.validate_manifest(path)

    payload["artifacts"]["backendEvents"] = str(self.write_backend_events_artifact(engine="b18nbt"))
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "expectedEngine must match"):
      inspector.validate_manifest(path)

    bad_events_path = self.write_backend_events_artifact("artifacts/bad-backend-events.json", engine="b6")
    bad_events = json.loads(bad_events_path.read_text(encoding="utf-8"))
    bad_events["observedExpectedEngine"] = False
    bad_events["diagnosticHint"] = "runtime diagnostic event=analysisFailed success=False: Denied over Wi-Fi"
    bad_events_path.write_text(json.dumps(bad_events), encoding="utf-8")
    payload["artifacts"]["backendEvents"] = str(bad_events_path)
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "observedExpectedEngine=true"):
      inspector.validate_manifest(path)

    bad_events_path = self.write_backend_events_artifact("artifacts/bad-backend-events-list.json", engine="b6")
    bad_events = json.loads(bad_events_path.read_text(encoding="utf-8"))
    bad_events["newEvents"] = [
      {**event, "engine": "b18nbt"} for event in bad_events["newEvents"]
    ]
    bad_events_path.write_text(json.dumps(bad_events), encoding="utf-8")
    payload["artifacts"]["backendEvents"] = str(bad_events_path)
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "selected backend engine b6"):
      inspector.validate_manifest(path)

  def test_app_support_snapshot_requires_primary_and_backup_consistency(self) -> None:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    app_support = pathlib.Path(payload["artifacts"]["appSupport"])
    self.write_app_support_snapshots(app_support, engine="b6")
    backup = app_support / "autosave.qixi-state.backup.json"
    backup.unlink()
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "autosave.qixi-state.backup.json does not exist"):
      inspector.validate_manifest(path)

    self.write_app_support_snapshots(app_support, engine="b6")
    backup_payload = self.snapshot_payload("b18nbt")
    backup.write_text(json.dumps(backup_payload, sort_keys=True) + "\n", encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "autosave and backup selectedEngine must match"):
      inspector.validate_manifest(path)

  def test_real_manifest_accepts_explicit_local_bridge_bundle(self) -> None:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    local_bundle = "com.example.qixi.local-device"
    payload["app"]["bundleIdentifier"] = local_bundle
    payload["signing"] = {
      "developmentTeamOverride": "ABCDE12345",
      "bundleIdentifier": local_bundle,
      "iCloudEntitlementsDisabledForLocalBridge": True,
    }
    payload["commands"]["xcodebuild"].extend([
      "DEVELOPMENT_TEAM=ABCDE12345",
      f"PRODUCT_BUNDLE_IDENTIFIER={local_bundle}",
      "CODE_SIGN_ENTITLEMENTS=",
    ])
    payload["commands"]["launch"][payload["commands"]["launch"].index("com.qixi.localanalysis")] = local_bundle
    payload["commands"]["copyAppSupport"][
      payload["commands"]["copyAppSupport"].index("--domain-identifier") + 1
    ] = local_bundle
    path.write_text(json.dumps(payload), encoding="utf-8")
    checked = inspector.validate_manifest(path)
    self.assertEqual(checked["app"]["bundleIdentifier"], local_bundle)

  def test_real_manifest_rejects_local_bridge_bundle_without_disabled_icloud_entitlements(self) -> None:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    local_bundle = "com.example.qixi.local-device"
    payload["app"]["bundleIdentifier"] = local_bundle
    payload["signing"] = {
      "developmentTeamOverride": "ABCDE12345",
      "bundleIdentifier": local_bundle,
      "iCloudEntitlementsDisabledForLocalBridge": False,
    }
    payload["commands"]["xcodebuild"].extend([
      "DEVELOPMENT_TEAM=ABCDE12345",
      f"PRODUCT_BUNDLE_IDENTIFIER={local_bundle}",
    ])
    payload["commands"]["launch"][payload["commands"]["launch"].index("com.qixi.localanalysis")] = local_bundle
    payload["commands"]["copyAppSupport"][
      payload["commands"]["copyAppSupport"].index("--domain-identifier") + 1
    ] = local_bundle
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(
      inspector.DeviceBridgeSmokeArtifactError,
      "local device bridge bundle overrides must disable iCloud entitlements",
    ):
      inspector.validate_manifest(path)

  def test_rejects_dry_run_loopback_and_wrong_runtime(self) -> None:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["dryRun"] = True
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "must not be dryRun"):
      inspector.validate_manifest(path)

    payload["dryRun"] = False
    payload["backend"]["origin"] = "http://127.0.0.1:8765"
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "localhost or loopback"):
      inspector.validate_manifest(path)

    payload["backend"]["origin"] = "http://192.168.3.61:8765"
    env = json.loads(payload["commands"]["launch"][payload["commands"]["launch"].index("--environment-variables") + 1])
    env["QIXI_ANALYSIS_RUNTIME"] = "nativeInProcess"
    payload["commands"]["launch"][payload["commands"]["launch"].index("--environment-variables") + 1] = json.dumps(env)
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "httpBridge"):
      inspector.validate_manifest(path)

  def test_plan_manifest_passes_only_plan_inspector(self) -> None:
    path = self.build_plan_manifest()
    payload = inspector.validate_plan_manifest(path)
    self.assertTrue(payload["dryRun"])
    self.assertTrue(payload["preflight"]["planOnly"])
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "must not be dryRun"):
      inspector.validate_manifest(path)

  def test_plan_manifest_rejects_real_evidence_shape_and_command_drift(self) -> None:
    path = self.build_plan_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["dryRun"] = False
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "plan manifest must be dryRun"):
      inspector.validate_plan_manifest(path)

    path = self.build_plan_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["preflight"]["planOnly"] = False
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "preflight.planOnly must be true"):
      inspector.validate_plan_manifest(path)

    path = self.build_plan_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["timingsMs"]["build"] = 10
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "timingsMs must be empty"):
      inspector.validate_plan_manifest(path)

    path = self.build_plan_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["commands"]["xcodebuild"].remove("CODE_SIGN_ENTITLEMENTS=")
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "disable iCloud entitlements"):
      inspector.validate_plan_manifest(path)

    path = self.build_plan_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["signing"]["bundleIdentifier"] = "com.example.other"
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "signing bundleIdentifier must match"):
      inspector.validate_plan_manifest(path)

  def test_rejects_missing_artifact_and_duplicate_keys(self) -> None:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    pathlib.Path(payload["artifacts"]["install"]).unlink()
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "does not exist"):
      inspector.validate_manifest(path)

    duplicate_path = self.root / "duplicate.json"
    duplicate_path.write_text('{"schemaVersion":1,"schemaVersion":1}\n', encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "duplicate JSON key"):
      inspector.validate_manifest(duplicate_path)

  def test_rejects_ambiguous_or_unbounded_launch_environment_json(self) -> None:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    env_index = payload["commands"]["launch"].index("--environment-variables") + 1

    payload["commands"]["launch"][env_index] = (
      '{"QIXI_ANALYSIS_RUNTIME":"nativeInProcess",'
      '"QIXI_ANALYSIS_RUNTIME":"httpBridge",'
      '"QIXI_BACKEND_URL":"http://192.168.3.61:8765",'
      '"QIXI_SKIP_ONBOARDING":"1"}'
    )
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "duplicate JSON key 'QIXI_ANALYSIS_RUNTIME'"):
      inspector.validate_manifest(path)

    payload["commands"]["launch"][env_index] = (
      '{"QIXI_ANALYSIS_RUNTIME":"httpBridge",'
      '"QIXI_BACKEND_URL":"http://192.168.3.61:8765",'
      '"QIXI_SKIP_ONBOARDING":NaN}'
    )
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "non-standard JSON constant NaN"):
      inspector.validate_manifest(path)

    payload["commands"]["launch"][env_index] = '["not", "an", "object"]'
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "launch environment JSON must be an object"):
      inspector.validate_manifest(path)

    payload["commands"]["launch"][env_index] = (
      '{"QIXI_ANALYSIS_RUNTIME":"httpBridge",'
      '"QIXI_BACKEND_URL":"http://192.168.3.61:8765",'
      '"QIXI_SKIP_ONBOARDING":"' + ("x" * inspector.MAX_LAUNCH_ENV_JSON_BYTES) + '"}'
    )
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "launch environment JSON exceeds bounded size"):
      inspector.validate_manifest(path)

  def test_rejects_malformed_or_token_stuffed_command_records(self) -> None:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["commands"]["install"] = "xcrun devicectl device install app"
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "install command must be a command list"):
      inspector.validate_manifest(path)

    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["commands"]["install"] = ["xcrun", "devicectl", "device", "launch", "app"]
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "install command must start with"):
      inspector.validate_manifest(path)

    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["commands"]["xcodebuild"] = ["xcodebuild", "-destination", "id=OTHERDEVICE", "build"]
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "target the validated device UDID"):
      inspector.validate_manifest(path)

    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["commands"]["launch"] = [
      "xcrun",
      "devicectl",
      "device",
      "process",
      "launch",
      "--device",
      "21ABE4B1-1509-5D45-9645-75A52D050D68",
      "--terminate-existing",
      "com.qixi.localanalysis",
      "--json-output",
      payload["artifacts"]["launch"],
      "--environment-variables",
    ]
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "value after --environment-variables"):
      inspector.validate_manifest(path)

  def test_rejects_command_device_artifact_and_bundle_mismatches(self) -> None:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["commands"]["launch"][payload["commands"]["launch"].index("--device") + 1] = "OTHERDEVICE"
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "launch command must set --device"):
      inspector.validate_manifest(path)

    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["commands"]["install"][payload["commands"]["install"].index("--json-output") + 1] = str(self.root / "other.json")
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "install command must set --json-output"):
      inspector.validate_manifest(path)

    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["commands"]["launch"][payload["commands"]["launch"].index("com.qixi.localanalysis")] = "com.example.other"
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "launch the validated app bundle"):
      inspector.validate_manifest(path)

    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["commands"]["copyAppSupport"][payload["commands"]["copyAppSupport"].index("--source") + 1] = "Library/Application Support/Other"
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "copyAppSupport command must set --source"):
      inspector.validate_manifest(path)

  def test_rejects_stale_timestamp_bad_run_id_and_missing_timing(self) -> None:
    path = self.build_manifest()
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["runId"] = "not-a-run-id"
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "runId"):
      inspector.validate_manifest(path)

    payload["runId"] = "0123456789abcdef0123456789abcdef"
    payload["timingsMs"].pop("build")
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "timingsMs.build"):
      inspector.validate_manifest(path)

    old = "2000-01-01T00:00:00.000000Z"
    payload["timingsMs"]["build"] = 10
    payload["startedAt"] = old
    payload["generatedAt"] = old
    payload["completedAt"] = old
    path.write_text(json.dumps(payload), encoding="utf-8")
    with self.assertRaisesRegex(inspector.DeviceBridgeSmokeArtifactError, "stale"):
      inspector.validate_manifest(path)


if __name__ == "__main__":
  unittest.main()
