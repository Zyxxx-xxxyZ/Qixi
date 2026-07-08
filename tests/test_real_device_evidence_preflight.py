#!/usr/bin/env python3
from __future__ import annotations

import json
import hashlib
import datetime
import os
import pathlib
import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import qixi_real_device_evidence_preflight as preflight  # noqa: E402


def hermetic_qixi_env(**overrides: str) -> dict[str, str]:
  env = {
    key: value
    for key, value in os.environ.items()
    if not (key.startswith("QIXI_") or key.startswith("SIMCTL_CHILD_QIXI_"))
  }
  env.update(overrides)
  return env


def png_with_dimensions(width: int, height: int, *, grid: bool = True) -> bytes:
  def chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)

  background = 0xE2
  grid_color = 0x28
  star_color = 0x18
  grid_margin_x = max(20, width // 12)
  grid_margin_y = max(20, height // 12)
  grid_span_x = max(1, width - 2 * grid_margin_x)
  grid_span_y = max(1, height - 2 * grid_margin_y)
  verticals = {
    round(grid_margin_x + grid_span_x * index / 18)
    for index in range(19)
  } if grid else set()
  horizontals = {
    round(grid_margin_y + grid_span_y * index / 18)
    for index in range(19)
  } if grid else set()
  star_points = {
    (
      round(grid_margin_x + grid_span_x * x / 18),
      round(grid_margin_y + grid_span_y * y / 18),
    )
    for x in (3, 9, 15)
    for y in (3, 9, 15)
  } if grid else set()
  rows: list[bytes] = []
  for y in range(height):
    row = bytearray()
    for x in range(width):
      value = background
      if grid and (x in verticals or y in horizontals):
        value = grid_color
      if grid and any((x - sx) ** 2 + (y - sy) ** 2 <= 16 for sx, sy in star_points):
        value = star_color
      row.append(value)
    rows.append(b"\x00" + bytes(row))
  scanlines = b"".join(rows)
  return (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(scanlines, level=1))
    + chunk(b"IEND", b"")
  )


def png_header_only(width: int, height: int) -> bytes:
  def chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)

  return (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
    + chunk(b"IEND", b"")
  )


def write_sparse_file(path: pathlib.Path, byte_count: int) -> None:
  with path.open("wb") as handle:
    handle.seek(byte_count - 1)
    handle.write(b"\0")


class DirectoryHandle:
  def __init__(self, directory: pathlib.Path) -> None:
    self.fd = os.open(directory, os.O_RDONLY)

  def fileno(self) -> int:
    return self.fd

  def read(self, _byte_count: int) -> bytes:
    raise AssertionError("reader must reject the opened descriptor before reading")

  def __enter__(self) -> "DirectoryHandle":
    return self

  def __exit__(self, _exc_type: object, _exc: object, _traceback: object) -> None:
    os.close(self.fd)


class DriftHandle:
  def __init__(self, backing_file: pathlib.Path) -> None:
    self.fd = os.open(backing_file, os.O_RDONLY)
    self.did_read = False

  def fileno(self) -> int:
    return self.fd

  def read(self, _byte_count: int) -> bytes:
    if self.did_read:
      return b""
    self.did_read = True
    return b""

  def __enter__(self) -> "DriftHandle":
    return self

  def __exit__(self, _exc_type: object, _exc: object, _traceback: object) -> None:
    os.close(self.fd)


PNG_IPAD_LANDSCAPE = png_with_dimensions(1200, 800)
PNG_IPAD_BLANK_LANDSCAPE = png_with_dimensions(1200, 800, grid=False)
PNG_IPAD_PORTRAIT = png_with_dimensions(800, 1200)
PNG_TOO_SMALL = png_with_dimensions(640, 360)
VALID_MEASUREMENTS = {
  "launch": {
    "coldLaunchMs": 900,
    "visualReadyMs": 1400,
  },
  "memory": {
    "peakRSSMB": 620,
    "postAnalysisRSSMB": 590,
  },
  "framePacing": {
    "targetRefreshHz": 120,
    "observedRefreshHz": 118,
    "droppedFramePercent": 1.2,
  },
}
FRESH_NOW = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
FRESH_RECORDED_AT = FRESH_NOW - datetime.timedelta(hours=1)
VALID_RUN_ID = "00000000-0000-4000-8000-000000000001"


def isoformat_z(value: datetime.datetime) -> str:
  return value.astimezone(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def cloned_measurements() -> dict[str, object]:
  return json.loads(json.dumps(VALID_MEASUREMENTS))


def swift_native_model_manifest() -> dict[str, dict[str, object]]:
  source = (ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelRegistry.swift").read_text(encoding="utf-8")
  case_pattern = re.compile(
    r"case \.(?P<engine>[A-Za-z0-9]+):(?P<body>.*?)(?=\n    case \.|\n    \}\n  \})",
    re.MULTILINE | re.DOTALL,
  )
  spec_pattern = re.compile(
    r"return NativeKataGoModelSpec\(\s*"
    r"engine: engine,\s*"
    r'resourceName: "(?P<resourceName>[^"]+)",\s*'
    r"expectedByteCount: (?P<byteCount>\d+),\s*"
    r'sha256HexDigest: "(?P<sha256HexDigest>[0-9a-f]{64})",\s*'
    r"minimumMemoryMB: (?P<minimumMemoryMB>\d+),\s*"
    r"recommendedMemoryMB: (?P<recommendedMemoryMB>\d+),\s*"
    r"maximumMemoryMB: (?P<maximumMemoryMB>\d+)",
    re.MULTILINE | re.DOTALL,
  )
  package_pattern = re.compile(
    r"NativeKataGoCoreMLPackageSpec\(\s*"
    r'resourceName: "(?P<resourceName>[^"]+)",\s*'
    r'variantID: "(?P<variantID>[^"]+)",\s*'
    r"expectedFileCount: (?P<fileCount>\d+),\s*"
    r"expectedTotalByteCount: (?P<totalByteCount>\d+),\s*"
    r'sha256TreeDigest: "(?P<sha256TreeDigest>[0-9a-f]{64})"',
    re.MULTILINE | re.DOTALL,
  )
  manifest: dict[str, dict[str, object]] = {}
  for case_match in case_pattern.finditer(source):
    match = spec_pattern.search(case_match.group("body"))
    if not match:
      continue
    manifest[case_match.group("engine")] = {
      "resourceName": match.group("resourceName"),
      "byteCount": int(match.group("byteCount")),
      "sha256HexDigest": match.group("sha256HexDigest"),
      "minimumMemoryMB": int(match.group("minimumMemoryMB")),
      "recommendedMemoryMB": int(match.group("recommendedMemoryMB")),
      "maximumMemoryMB": int(match.group("maximumMemoryMB")),
      "coreMLPackages": [
        {
          "resourceName": package_match.group("resourceName"),
          "variantID": package_match.group("variantID"),
          "fileCount": int(package_match.group("fileCount")),
          "totalByteCount": int(package_match.group("totalByteCount")),
          "sha256TreeDigest": package_match.group("sha256TreeDigest"),
        }
        for package_match in package_pattern.finditer(case_match.group("body"))
      ],
    }
  return manifest


def device_log_payload(evidence: dict[str, object]) -> dict[str, object]:
  payload: dict[str, object] = {
    "schemaVersion": preflight.DEVICE_LOG_ARTIFACT_SCHEMA_VERSION,
    "kind": "qixi-real-device-log",
    "runId": evidence["runId"],
    "recordedAt": evidence["recordedAt"],
  }
  for key in ("device", "app", "analysis", "lifecycle", "features"):
    payload[key] = json.loads(json.dumps(evidence[key]))
  if evidence["app"]["analysisRuntime"] == "httpBridge":
    payload["backend"] = json.loads(json.dumps(evidence["backend"]))
  return payload


def write_device_log(directory: pathlib.Path, evidence: dict[str, object]) -> None:
  (directory / "device.log").write_text(
    json.dumps(device_log_payload(evidence), sort_keys=True) + "\n",
    encoding="utf-8",
  )


def artifact_metadata(path: pathlib.Path) -> dict[str, object]:
  return {
    "byteCount": path.stat().st_size,
    "sha256HexDigest": hashlib.sha256(path.read_bytes()).hexdigest(),
  }


def refresh_artifact_metadata(directory: pathlib.Path, payload: dict[str, object], kind: str) -> None:
  for artifact in payload["artifacts"]:
    if artifact["kind"] == kind:
      artifact.update(artifact_metadata(directory / artifact["path"]))
      return
  raise AssertionError(f"missing artifact kind {kind}")


def write_artifacts(directory: pathlib.Path, evidence: dict[str, object]) -> list[dict[str, object]]:
  artifacts = []
  for kind, filename in (
    ("screenshot", "ipad-main.png"),
    ("performance", "instruments.json"),
    ("device-log", "device.log"),
  ):
    path = directory / filename
    if kind == "screenshot":
      path.write_bytes(PNG_IPAD_LANDSCAPE)
    elif kind == "performance":
      path.write_text(
        json.dumps(
          {
            "source": "instruments",
            "schemaVersion": preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION,
            "kind": "qixi-real-device-performance",
            "runId": evidence["runId"],
            "recordedAt": evidence["recordedAt"],
            "measurements": evidence["measurements"],
          },
          sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
      )
    else:
      write_device_log(directory, evidence)
    artifacts.append({"kind": kind, "path": filename, **artifact_metadata(path)})
  return artifacts


def valid_evidence(directory: pathlib.Path) -> dict[str, object]:
  measurements = cloned_measurements()
  payload: dict[str, object] = {
    "schemaVersion": preflight.REAL_DEVICE_EVIDENCE_SCHEMA_VERSION,
    "kind": preflight.REAL_DEVICE_EVIDENCE_KIND,
    "runId": VALID_RUN_ID,
    "recordedAt": isoformat_z(FRESH_RECORDED_AT),
    "device": {
      "idiom": "iPad",
      "model": "iPad Pro 13-inch (M5)",
      "osVersion": "iPadOS 26.5",
      "simulator": False,
    },
    "app": {
      "bundleIdentifier": "com.qixi.localanalysis",
      "version": "1.0",
      "build": "1",
      "analysisRuntime": "httpBridge",
      "executableSHA256HexDigest": "a" * 64,
    },
    "backend": {
      "url": "http://192.168.1.23:8765",
      "status": {
        "engine": "katago-metal-mux:b6",
        "engineId": "b6",
        "state": "running",
        "running": True,
        "paused": False,
      },
    },
    "analysis": {
      "engineId": "b6",
      "realModel": True,
      "visits": 128,
      "candidateCount": 8,
      "ownershipSource": "mcts",
      "positionIdentity": {
        "currentPositionKey": "b6|rules:Chinese|komiBits:401e000000000000|rootNoiseBits:0|history:0:B:3:3",
        "sameVisibleStones": True,
        "sameVisibleHistoryAKey": "b6|same-visible-history-a",
        "sameVisibleHistoryBKey": "b6|same-visible-history-b",
        "sameVisibleHistoryKeysDistinct": True,
      },
    },
    "measurements": measurements,
    "lifecycle": {
      "backgroundedSeconds": 30,
      "autosaveWritten": True,
      "tombstoneWritten": True,
      "restoredLatestState": True,
    },
    "features": {
      "cameraRecognitionTested": True,
      "iCloudSyncTested": True,
      "modelImportTested": True,
    },
    "artifacts": [],
  }
  payload["artifacts"] = write_artifacts(directory, payload)
  return payload


def write_evidence(directory: pathlib.Path, payload: dict[str, object]) -> pathlib.Path:
  path = directory / "real-device-evidence.json"
  path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
  return path


def valid_native_engine(
  engine_id: str = "b6",
  *,
  exported_at: str | None = None,
  restored_at: str | None = None,
) -> dict[str, object]:
  manifest = preflight.NATIVE_MODEL_MANIFEST[engine_id]
  exported_at = exported_at or isoformat_z(FRESH_RECORDED_AT - datetime.timedelta(minutes=2))
  restored_at = restored_at or isoformat_z(FRESH_RECORDED_AT - datetime.timedelta(minutes=1))
  return {
    "modelDigestVerified": True,
    "engineId": engine_id,
    "modelResourceName": manifest["resourceName"],
    "modelByteCount": manifest["byteCount"],
    "modelSHA256HexDigest": manifest["sha256HexDigest"],
    "coreMLPackages": manifest["coreMLPackages"],
    "tombstoneExported": True,
    "tombstoneFilename": preflight.NATIVE_TOMBSTONE_FILENAME,
    "tombstoneExportedAt": exported_at,
    "tombstoneRestored": True,
    "tombstoneRestoredAt": restored_at,
  }


class RealDeviceEvidencePreflightTests(unittest.TestCase):
  def test_native_model_manifest_matches_swift_registry(self) -> None:
    self.assertEqual(
      preflight.NATIVE_MODEL_MANIFEST,
      swift_native_model_manifest(),
      "release evidence preflight manifest must stay byte-for-byte aligned with QixiNativeModelRegistry",
    )

  def test_native_model_manifest_loader_rejects_missing_swift_engine(self) -> None:
    source = (ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelRegistry.swift").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory() as raw_dir:
      registry = pathlib.Path(raw_dir) / "QixiNativeModelRegistry.swift"
      registry.write_text(source.replace("case .b28nbt:", "case .b28missing:"), encoding="utf-8")
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "missing release-evidence engines: b28nbt"):
        preflight.load_native_model_manifest_from_swift_registry(registry)

  def test_native_model_manifest_loader_rejects_untrusted_registry_input_before_loading(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      target = directory / "registry-target.swift"
      target.write_text("// target must not be read through a symlink\n", encoding="utf-8")
      registry = directory / "QixiNativeModelRegistry.swift"
      registry.symlink_to(target)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "Swift native model registry must not contain symbolic links"):
        preflight.load_native_model_manifest_from_swift_registry(registry)

    with tempfile.TemporaryDirectory() as raw_dir:
      registry = pathlib.Path(raw_dir) / "QixiNativeModelRegistry.swift"
      write_sparse_file(registry, preflight.SWIFT_NATIVE_MODEL_REGISTRY_MAX_BYTES + 1)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "Swift native model registry exceeds bounded source size"):
        preflight.load_native_model_manifest_from_swift_registry(registry)

  def test_bounded_readers_recheck_opened_descriptor_is_regular(self) -> None:
    for reader, label, max_bytes in (
      (preflight._bounded_text, "real-device evidence JSON", preflight.REAL_DEVICE_EVIDENCE_MAX_BYTES),
      (preflight._bounded_source_text, "Swift native model registry", preflight.SWIFT_NATIVE_MODEL_REGISTRY_MAX_BYTES),
    ):
      with self.subTest(label=label):
        with tempfile.TemporaryDirectory() as raw_dir:
          directory = pathlib.Path(raw_dir)
          path = directory / "input.json"
          path.write_text('{"ok":true}\n', encoding="utf-8")

          def fake_open(_path: pathlib.Path, *_args: object, **_kwargs: object) -> DirectoryHandle:
            return DirectoryHandle(directory)

          with mock.patch.object(pathlib.Path, "open", fake_open):
            with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, f"{re.escape(label)} must be a regular file after opening"):
              reader(path, label, max_bytes)

  def test_bounded_readers_recheck_opened_descriptor_byte_count(self) -> None:
    for reader, label, max_bytes, expected_error in (
      (
        preflight._bounded_text,
        "real-device evidence JSON",
        preflight.REAL_DEVICE_EVIDENCE_MAX_BYTES,
        "real-device evidence JSON opened-byte-count drift while reading",
      ),
      (
        preflight._bounded_source_text,
        "Swift native model registry",
        preflight.SWIFT_NATIVE_MODEL_REGISTRY_MAX_BYTES,
        "Swift native model registry opened-byte-count drift while reading",
      ),
    ):
      with self.subTest(label=label):
        with tempfile.TemporaryDirectory() as raw_dir:
          directory = pathlib.Path(raw_dir)
          path = directory / "input.json"
          path.write_text('{"ok":true}\n', encoding="utf-8")

          def fake_open(_path: pathlib.Path, *_args: object, **_kwargs: object) -> DriftHandle:
            return DriftHandle(path)

          with mock.patch.object(pathlib.Path, "open", fake_open):
            with self.assertRaisesRegex(
              preflight.RealDeviceEvidenceError,
              expected_error,
            ):
              reader(path, label, max_bytes)

  def test_native_model_manifest_loader_extracts_coreml_package_specs(self) -> None:
    digest = "a" * 64
    source = f"""
enum QixiNativeModelRegistry {{
  static func spec(for engine: AnalysisEngine) -> NativeKataGoModelSpec? {{
    switch engine {{
    case .none:
      return nil
    case .b6:
      return NativeKataGoModelSpec(
        engine: engine,
        resourceName: "b6.bin.gz",
        expectedByteCount: 11,
        sha256HexDigest: "{digest}",
        minimumMemoryMB: 1,
        recommendedMemoryMB: 2,
        maximumMemoryMB: 3,
        coreMLPackages: [
          NativeKataGoCoreMLPackageSpec(
            resourceName: "b6.mlpackage",
            variantID: "metal-coreml-fp16",
            expectedFileCount: 7,
            expectedTotalByteCount: 999,
            sha256TreeDigest: "{'b' * 64}"
          )
        ]
      )
    case .b18nbt:
      return NativeKataGoModelSpec(
        engine: engine,
        resourceName: "b18.bin",
        expectedByteCount: 22,
        sha256HexDigest: "{'c' * 64}",
        minimumMemoryMB: 1,
        recommendedMemoryMB: 2,
        maximumMemoryMB: 3
      )
    case .b28nbt:
      return NativeKataGoModelSpec(
        engine: engine,
        resourceName: "b28.bin",
        expectedByteCount: 33,
        sha256HexDigest: "{'d' * 64}",
        minimumMemoryMB: 1,
        recommendedMemoryMB: 2,
        maximumMemoryMB: 3
      )
    }}
  }}
}}
"""
    with tempfile.TemporaryDirectory() as raw_dir:
      registry = pathlib.Path(raw_dir) / "QixiNativeModelRegistry.swift"
      registry.write_text(source, encoding="utf-8")
      manifest = preflight.load_native_model_manifest_from_swift_registry(registry)
    self.assertEqual(
      manifest["b6"]["coreMLPackages"],
      [
        {
          "resourceName": "b6.mlpackage",
          "variantID": "metal-coreml-fp16",
          "fileCount": 7,
          "totalByteCount": 999,
          "sha256TreeDigest": "b" * 64,
        }
      ],
    )
    self.assertEqual(manifest["b6"]["minimumMemoryMB"], 1)
    self.assertEqual(manifest["b6"]["recommendedMemoryMB"], 2)
    self.assertEqual(manifest["b6"]["maximumMemoryMB"], 3)
    self.assertEqual(manifest["b18nbt"]["coreMLPackages"], [])
    self.assertEqual(manifest["b28nbt"]["coreMLPackages"], [])

  def test_accepts_physical_ipad_bridge_evidence(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      path = write_evidence(directory, valid_evidence(directory))
      summary = preflight.validate_evidence(
        path,
        expected_backend_origin="http://192.168.1.23:8765",
        now=FRESH_NOW,
      )
      self.assertEqual(summary["runtime"], "httpBridge")
      self.assertEqual(summary["engineId"], "b6")
      self.assertEqual(summary["runId"], VALID_RUN_ID)

  def test_rejects_run_id_mismatches(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["runId"] = "not-a-run-id"
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "runId must be a canonical lowercase UUID"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "instruments.json").write_text(
        json.dumps(
          {
            "source": "instruments",
            "schemaVersion": preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION,
            "kind": "qixi-real-device-performance",
            "runId": "00000000-0000-4000-8000-000000000099",
            "recordedAt": payload["recordedAt"],
            "measurements": payload["measurements"],
          },
          sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "performance")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "performance artifact runId"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      log_payload = device_log_payload(payload)
      log_payload["runId"] = "00000000-0000-4000-8000-000000000099"
      (directory / "device.log").write_text(json.dumps(log_payload) + "\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact runId"):
        preflight.validate_evidence(path, now=FRESH_NOW)

  def test_rejects_app_executable_digest_mismatch_or_malformed_digest(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], executableSHA256HexDigest="ABC")
      write_device_log(directory, payload)
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "app.executableSHA256HexDigest"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      log_payload = device_log_payload(payload)
      log_payload["app"]["executableSHA256HexDigest"] = "b" * 64
      (directory / "device.log").write_text(json.dumps(log_payload, sort_keys=True) + "\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact app.executableSHA256HexDigest"):
        preflight.validate_evidence(path, now=FRESH_NOW)

  def test_accepts_native_inprocess_evidence_without_backend(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine("b6"),
      )
      write_device_log(directory, payload)
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      summary = preflight.validate_evidence(path, expected_runtime="nativeInProcess")
      self.assertEqual(summary["runtime"], "nativeInProcess")

  def test_rejects_native_inprocess_memory_above_model_manifest_budget(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine("b6"),
      )
      maximum_memory_mb = int(preflight.NATIVE_MODEL_MANIFEST["b6"]["maximumMemoryMB"])
      measurements = dict(payload["measurements"])
      measurements["memory"] = {
        "peakRSSMB": maximum_memory_mb + 1,
        "postAnalysisRSSMB": maximum_memory_mb,
      }
      payload["measurements"] = measurements
      (directory / "instruments.json").write_text(
        json.dumps(
          {
            "source": "instruments",
            "schemaVersion": preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION,
            "kind": "qixi-real-device-performance",
            "runId": payload["runId"],
            "recordedAt": payload["recordedAt"],
            "measurements": payload["measurements"],
          },
          sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
      )
      write_device_log(directory, payload)
      refresh_artifact_metadata(directory, payload, "performance")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "manifest maximumMemoryMB=768"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess", now=FRESH_NOW)

  def test_rejects_simulator_and_loopback_evidence(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["kind"] = "qixi-device-log"
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, f"kind must be {preflight.REAL_DEVICE_EVIDENCE_KIND}"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    future_recorded_at = isoformat_z(FRESH_NOW + datetime.timedelta(minutes=10))
    stale_recorded_at = isoformat_z(FRESH_NOW - datetime.timedelta(days=8))
    for recorded_at, expected_error in (
      (future_recorded_at, "recordedAt must not be in the future"),
      (stale_recorded_at, "recordedAt is too old for release evidence"),
    ):
      with tempfile.TemporaryDirectory() as raw_dir:
        directory = pathlib.Path(raw_dir)
        payload = valid_evidence(directory)
        payload["recordedAt"] = recorded_at
        (directory / "instruments.json").write_text(
          json.dumps(
            {
              "source": "instruments",
              "schemaVersion": preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION,
              "kind": "qixi-real-device-performance",
              "runId": payload["runId"],
              "recordedAt": recorded_at,
              "measurements": payload["measurements"],
            },
            sort_keys=True,
          )
          + "\n",
          encoding="utf-8",
        )
        write_device_log(directory, payload)
        refresh_artifact_metadata(directory, payload, "performance")
        refresh_artifact_metadata(directory, payload, "device-log")
        path = write_evidence(directory, payload)
        with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, expected_error):
          preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["device"] = dict(payload["device"], simulator=True)
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device.simulator must be false"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["backend"] = dict(payload["backend"], url="http://127.0.0.1:8765")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "localhost or loopback"):
        preflight.validate_evidence(path)

  def test_rejects_native_inprocess_backend_and_missing_native_engine(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine("b6"),
      )
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "must not set QIXI_DEVICE_BACKEND_URL"):
        preflight.validate_evidence(
          path,
          expected_runtime="nativeInProcess",
          expected_backend_origin="http://192.168.1.23:8765",
        )

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine("b6"),
      )
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "must omit backend entirely"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload["backend"] = {}
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine("b6"),
      )
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "must omit backend entirely"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "analysis.nativeEngine must be an object"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

  def test_cli_rejects_native_inprocess_backend_url_environment(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine("b6"),
      )
      evidence = write_evidence(directory, payload)
      env = hermetic_qixi_env(
        QIXI_REAL_DEVICE_EVIDENCE=str(evidence),
        QIXI_REAL_DEVICE_EXPECT_RUNTIME="nativeInProcess",
        QIXI_DEVICE_BACKEND_URL="http://192.168.1.23:8765",
      )
      result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-real-device-evidence-preflight.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(result.returncode, 0)
      self.assertIn("must not set QIXI_DEVICE_BACKEND_URL", result.stderr)
      self.assertIn("QIXI_BACKEND_URL", result.stderr)

      legacy_env = hermetic_qixi_env(
        QIXI_REAL_DEVICE_EVIDENCE=str(evidence),
        QIXI_REAL_DEVICE_EXPECT_RUNTIME="nativeInProcess",
        QIXI_BACKEND_URL="http://192.168.1.23:8765",
      )
      legacy_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-real-device-evidence-preflight.sh")],
        cwd=ROOT,
        env=legacy_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(legacy_result.returncode, 0)
      self.assertIn("must not set QIXI_DEVICE_BACKEND_URL", legacy_result.stderr)
      self.assertIn("QIXI_BACKEND_URL", legacy_result.stderr)

      conflicting_env = hermetic_qixi_env(
        QIXI_REAL_DEVICE_EVIDENCE=str(evidence),
        QIXI_DEVICE_BACKEND_URL="http://192.168.1.23:8765",
        QIXI_BACKEND_URL="http://192.168.1.24:8765",
      )
      conflicting_result = subprocess.run(
        [str(ROOT / "scripts" / "qixi-real-device-evidence-preflight.sh")],
        cwd=ROOT,
        env=conflicting_env,
        text=True,
        capture_output=True,
        check=False,
      )
      self.assertNotEqual(conflicting_result.returncode, 0)
      self.assertIn("must not both be set to different values", conflicting_result.stderr)

  def test_rejects_native_inprocess_manifest_and_stale_tombstone_mismatches(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine("b6"),
      )
      log_payload = device_log_payload(payload)
      log_payload["analysis"] = dict(log_payload["analysis"])
      log_payload["analysis"].pop("nativeEngine")
      (directory / "device.log").write_text(json.dumps(log_payload) + "\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact analysis.nativeEngine.modelDigestVerified"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine("b6"),
      )
      log_payload = device_log_payload(payload)
      log_payload["analysis"]["nativeEngine"]["engineId"] = "b18nbt"
      (directory / "device.log").write_text(json.dumps(log_payload) + "\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact analysis.nativeEngine.engineId"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine("b6"),
      )
      log_payload = device_log_payload(payload)
      log_payload["analysis"]["nativeEngine"]["modelSHA256HexDigest"] = "0" * 64
      (directory / "device.log").write_text(json.dumps(log_payload) + "\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact analysis.nativeEngine.modelSHA256HexDigest"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine("b6"),
      )
      log_payload = device_log_payload(payload)
      log_payload["analysis"]["nativeEngine"]["coreMLPackages"] = [
        {
          "resourceName": "unexpected.mlpackage",
          "variantID": "unexpected",
          "fileCount": 1,
          "totalByteCount": 1,
          "sha256TreeDigest": "0" * 64,
        }
      ]
      (directory / "device.log").write_text(json.dumps(log_payload) + "\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact analysis.nativeEngine.coreMLPackages"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      native = valid_native_engine("b6")
      native["modelSHA256HexDigest"] = "0" * 64
      payload["analysis"] = dict(payload["analysis"], nativeEngine=native)
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "modelSHA256HexDigest must match"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      native = valid_native_engine("b6")
      native["engineId"] = "b18nbt"
      payload["analysis"] = dict(payload["analysis"], nativeEngine=native)
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "nativeEngine.engineId must match analysis.engineId"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      native = valid_native_engine("b6")
      native.pop("engineId")
      payload["analysis"] = dict(payload["analysis"], nativeEngine=native)
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "analysis.nativeEngine.engineId must be a non-empty string"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      native = valid_native_engine("b6")
      native.pop("coreMLPackages")
      payload["analysis"] = dict(payload["analysis"], nativeEngine=native)
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "coreMLPackages must be an array"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      native = valid_native_engine("b6")
      native["coreMLPackages"] = [
        {
          "resourceName": "unexpected.mlpackage",
          "variantID": "unexpected",
          "fileCount": 1,
          "totalByteCount": 1,
          "sha256TreeDigest": "0" * 64,
        }
      ]
      payload["analysis"] = dict(payload["analysis"], nativeEngine=native)
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "coreMLPackages must match"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
      payload.pop("backend")
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine(
          "b6",
          exported_at="2026-07-01T09:58:00Z",
          restored_at="2026-07-03T09:59:00Z",
        ),
      )
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "tombstoneExportedAt is too old"):
        preflight.validate_evidence(path, expected_runtime="nativeInProcess")

    for audit_key, expected_error in (
      ("tombstoneExportedAt", "tombstoneExportedAt must not be newer than recordedAt"),
      ("tombstoneRestoredAt", "tombstoneRestoredAt must not be newer than recordedAt"),
    ):
      with tempfile.TemporaryDirectory() as raw_dir:
        directory = pathlib.Path(raw_dir)
        payload = valid_evidence(directory)
        payload["app"] = dict(payload["app"], analysisRuntime="nativeInProcess")
        payload.pop("backend")
        native = valid_native_engine("b6")
        native[audit_key] = isoformat_z(FRESH_RECORDED_AT + datetime.timedelta(minutes=2))
        payload["analysis"] = dict(payload["analysis"], nativeEngine=native)
        path = write_evidence(directory, payload)
        with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, expected_error):
          preflight.validate_evidence(path, expected_runtime="nativeInProcess")

  def test_rejects_bridge_backend_analysis_engine_mismatch(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      backend = dict(payload["backend"])
      backend["status"] = dict(backend["status"], engineId="b18nbt")
      payload["backend"] = backend
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "backend.status.engineId=b18nbt must match analysis.engineId=b6"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      backend = dict(payload["backend"])
      backend["status"] = dict(backend["status"], engine="katago-metal-mux:b18nbt")
      payload["backend"] = backend
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "backend.status.engine=katago-metal-mux:b18nbt must match katago-metal-mux:b6"):
        preflight.validate_evidence(path)

  def test_rejects_bridge_native_engine_fields(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["analysis"] = dict(
        payload["analysis"],
        nativeEngine=valid_native_engine("b6"),
      )
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "must not include analysis.nativeEngine"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["analysis"] = dict(payload["analysis"], nativeEngine=None)
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "must not include analysis.nativeEngine"):
        preflight.validate_evidence(path)

  def test_rejects_missing_or_collapsed_position_identity_evidence(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      analysis = dict(payload["analysis"])
      analysis.pop("positionIdentity")
      payload["analysis"] = analysis
      write_device_log(directory, payload)
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "analysis.positionIdentity must be an object"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      identity = dict(payload["analysis"]["positionIdentity"])
      identity["sameVisibleHistoryBKey"] = identity["sameVisibleHistoryAKey"]
      payload["analysis"] = dict(payload["analysis"], positionIdentity=identity)
      write_device_log(directory, payload)
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "same-visible history keys must be distinct"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      identity = dict(payload["analysis"]["positionIdentity"])
      identity["sameVisibleHistoryKeysDistinct"] = False
      payload["analysis"] = dict(payload["analysis"], positionIdentity=identity)
      write_device_log(directory, payload)
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "sameVisibleHistoryKeysDistinct must be true"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      log_payload = device_log_payload(payload)
      log_payload["analysis"]["positionIdentity"]["sameVisibleHistoryBKey"] = "mismatched"
      (directory / "device.log").write_text(json.dumps(log_payload, sort_keys=True) + "\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact analysis.positionIdentity.sameVisibleHistoryBKey"):
        preflight.validate_evidence(path, now=FRESH_NOW)

  def test_rejects_missing_artifacts_and_weak_measurements(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["artifacts"] = [{"kind": "screenshot", "path": "missing.png"}]
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "artifact does not exist"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      symlink_path = directory / "ipad-main-link.png"
      symlink_path.symlink_to(directory / "ipad-main.png")
      payload["artifacts"][0] = {
        **payload["artifacts"][0],
        "path": "ipad-main-link.png",
        **artifact_metadata(symlink_path),
      }
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "symbolic links"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      linked_target = directory / "linked-artifacts-target"
      linked_target.mkdir()
      (linked_target / "ipad-main.png").write_bytes(PNG_IPAD_LANDSCAPE)
      linked_dir = directory / "linked-artifacts"
      linked_dir.symlink_to(linked_target, target_is_directory=True)
      linked_artifact = linked_dir / "ipad-main.png"
      payload["artifacts"][0] = {
        **payload["artifacts"][0],
        "path": "linked-artifacts/ipad-main.png",
        **artifact_metadata(linked_artifact),
      }
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "symbolic links"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      root = pathlib.Path(raw_dir)
      real_directory = root / "real-evidence"
      real_directory.mkdir()
      payload = valid_evidence(real_directory)
      real_evidence = write_evidence(real_directory, payload)
      real_evidence.write_text("{not-json}\n", encoding="utf-8")
      linked_directory = root / "linked-evidence"
      linked_directory.symlink_to(real_directory, target_is_directory=True)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "symbolic links"):
        preflight.validate_evidence(linked_directory / "real-device-evidence.json")

    with tempfile.TemporaryDirectory() as raw_dir:
      root = pathlib.Path(raw_dir)
      real_root = root / "real-evidence-root"
      real_directory = real_root / "sub"
      real_directory.mkdir(parents=True)
      payload = valid_evidence(real_directory)
      real_evidence = write_evidence(real_directory, payload)
      real_evidence.write_text("{not-json}\n", encoding="utf-8")
      linked_root = root / "linked-evidence-root"
      linked_root.symlink_to(real_root, target_is_directory=True)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "symbolic links"):
        preflight.validate_evidence(linked_root / "sub" / "real-device-evidence.json")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      oversized_evidence = directory / "real-device-evidence.json"
      write_sparse_file(oversized_evidence, preflight.REAL_DEVICE_EVIDENCE_MAX_BYTES + 1)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "real-device evidence JSON exceeds bounded JSON size"):
        preflight.validate_evidence(oversized_evidence, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      write_sparse_file(directory / "instruments.json", preflight.PERFORMANCE_ARTIFACT_MAX_BYTES + 1)
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "artifact performance exceeds bounded artifact size"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      write_sparse_file(directory / "device.log", preflight.DEVICE_LOG_ARTIFACT_MAX_BYTES + 1)
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "artifact device-log exceeds bounded artifact size"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      write_sparse_file(directory / "ipad-main.png", preflight.SCREENSHOT_ARTIFACT_MAX_BYTES + 1)
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "artifact screenshot exceeds bounded artifact size"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "ipad-main.png").write_bytes(png_header_only(20_000, 10_000))
      refresh_artifact_metadata(directory, payload, "screenshot")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "screenshot artifact is too large for bounded visual inspection"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      artifacts = list(payload["artifacts"])
      artifacts[0] = dict(artifacts[0], byteCount=artifacts[0]["byteCount"] + 1)
      payload["artifacts"] = artifacts
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "artifact screenshot.byteCount"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "ipad-main.png").write_bytes(PNG_IPAD_LANDSCAPE[:-1] + b"x")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "artifact screenshot.sha256HexDigest"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "ipad-main.png").write_text("not png\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "screenshot")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "screenshot artifact must be a PNG file"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "ipad-main.png").write_bytes(PNG_IPAD_BLANK_LANDSCAPE)
      refresh_artifact_metadata(directory, payload, "screenshot")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "screenshot artifact looks blank"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "ipad-main.png").write_bytes(PNG_TOO_SMALL)
      refresh_artifact_metadata(directory, payload, "screenshot")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "screenshot artifact is too small for iPad"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "ipad-main.png").write_bytes(PNG_IPAD_PORTRAIT)
      refresh_artifact_metadata(directory, payload, "screenshot")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "screenshot artifact must be landscape for iPad"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "instruments.json").write_text("not json\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "performance")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "performance artifact must be JSON"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "instruments.json").write_text(
        json.dumps(
          {
            "schemaVersion": preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION + 1,
            "kind": "qixi-real-device-performance",
            "source": "instruments",
            "runId": payload["runId"],
            "recordedAt": payload["recordedAt"],
            "measurements": payload["measurements"],
          },
          sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "performance")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "performance artifact.schemaVersion"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "instruments.json").write_text(
        json.dumps(
          {
            "kind": "performance",
            "source": "instruments",
            "schemaVersion": preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION,
            "runId": payload["runId"],
            "recordedAt": payload["recordedAt"],
            "measurements": payload["measurements"],
          },
          sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "performance")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "performance artifact.kind"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "instruments.json").write_text(
        json.dumps(
          {
            "kind": "qixi-real-device-performance",
            "source": "spreadsheet",
            "schemaVersion": preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION,
            "runId": payload["runId"],
            "recordedAt": payload["recordedAt"],
            "measurements": payload["measurements"],
          },
          sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "performance")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "performance artifact.source"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "instruments.json").write_text(
        json.dumps(
          {
            "kind": "qixi-real-device-performance",
            "source": "instruments",
            "schemaVersion": preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION,
            "runId": payload["runId"],
            "recordedAt": payload["recordedAt"],
          }
        )
        + "\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "performance")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "performance artifact measurements must be an object"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "instruments.json").write_text(
        json.dumps(
          {
            "source": "instruments",
            "kind": "qixi-real-device-performance",
            "schemaVersion": preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION,
            "runId": payload["runId"],
            "recordedAt": isoformat_z(FRESH_RECORDED_AT - datetime.timedelta(minutes=5)),
            "measurements": payload["measurements"],
          },
          sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "performance")
      path = write_evidence(directory, payload)
      preflight.validate_evidence(path)

    for delta, message in (
      (datetime.timedelta(minutes=5), "must not be newer"),
      (-datetime.timedelta(hours=25), "too old"),
    ):
      with self.subTest(delta=delta):
        with tempfile.TemporaryDirectory() as raw_dir:
          directory = pathlib.Path(raw_dir)
          payload = valid_evidence(directory)
          (directory / "instruments.json").write_text(
            json.dumps(
              {
                "source": "instruments",
                "kind": "qixi-real-device-performance",
                "schemaVersion": preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION,
                "runId": payload["runId"],
                "recordedAt": isoformat_z(FRESH_RECORDED_AT + delta),
                "measurements": payload["measurements"],
              },
              sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
          )
          refresh_artifact_metadata(directory, payload, "performance")
          path = write_evidence(directory, payload)
          with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, message):
            preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      performance_measurements = cloned_measurements()
      performance_measurements["launch"]["coldLaunchMs"] = 901
      (directory / "instruments.json").write_text(
        json.dumps(
          {
            "source": "instruments",
            "kind": "qixi-real-device-performance",
            "schemaVersion": preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION,
            "runId": payload["runId"],
            "recordedAt": payload["recordedAt"],
            "measurements": performance_measurements,
          },
          sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "performance")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(
        preflight.RealDeviceEvidenceError,
        "performance artifact measurements.launch.coldLaunchMs",
      ):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "device.log").write_text("plain placeholder log\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact must be JSON"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "device.log").write_text(
        '{"schemaVersion":1,"kind":"device-log"}\n',
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact.kind must be qixi-real-device-log"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      log_payload = device_log_payload(payload)
      log_payload["schemaVersion"] = preflight.DEVICE_LOG_ARTIFACT_SCHEMA_VERSION + 1
      (directory / "device.log").write_text(json.dumps(log_payload) + "\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact.schemaVersion"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      log_payload = device_log_payload(payload)
      log_payload["recordedAt"] = isoformat_z(FRESH_RECORDED_AT - datetime.timedelta(minutes=5))
      (directory / "device.log").write_text(json.dumps(log_payload) + "\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact recordedAt"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      log_payload = device_log_payload(payload)
      log_payload["analysis"]["engineId"] = "b18nbt"
      (directory / "device.log").write_text(json.dumps(log_payload) + "\n", encoding="utf-8")
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact analysis.engineId"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      extra = directory / "trace.json"
      extra.write_text("trace\n", encoding="utf-8")
      payload["artifacts"] = list(payload["artifacts"]) + [{"kind": "trace", "path": "trace.json"}]
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "artifact kind is unsupported: trace"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      payload["artifacts"] = list(payload["artifacts"]) + [{"kind": "screenshot", "path": "ipad-main.png"}]
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "artifact kind is duplicated: screenshot"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      artifacts = list(payload["artifacts"])
      artifacts[0] = dict(artifacts[0], path=str(directory / "ipad-main.png"))
      payload["artifacts"] = artifacts
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "not an absolute path"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      artifacts = list(payload["artifacts"])
      artifacts[1] = dict(artifacts[1], path="../instruments.json")
      payload["artifacts"] = artifacts
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "must not traverse outside"):
        preflight.validate_evidence(path)

    for invalid_path in ("./ipad-main.png", "ipad-main.png/", "nested//ipad-main.png", "nested/./ipad-main.png"):
      with tempfile.TemporaryDirectory() as raw_dir:
        directory = pathlib.Path(raw_dir)
        payload = valid_evidence(directory)
        artifacts = list(payload["artifacts"])
        artifacts[0] = dict(artifacts[0], path=invalid_path)
        payload["artifacts"] = artifacts
        path = write_evidence(directory, payload)
        with self.assertRaisesRegex(
          preflight.RealDeviceEvidenceError,
          "must not contain empty or current-directory path components",
          msg=invalid_path,
        ):
          preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      artifacts = list(payload["artifacts"])
      artifacts[1] = dict(artifacts[1], path="ipad-main.png")
      payload["artifacts"] = artifacts
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "artifact path is duplicated"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      artifacts = list(payload["artifacts"])
      artifacts[0] = dict(artifacts[0], path="real-device-evidence.json")
      payload["artifacts"] = artifacts
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "must not overwrite the real-device evidence file"):
        preflight.validate_evidence(path)

    for reserved_name in ("real-device-evidence.qixi-release.json", "real-device-evidence.export.json"):
      with self.subTest(reserved_name=reserved_name):
        with tempfile.TemporaryDirectory() as raw_dir:
          directory = pathlib.Path(raw_dir)
          payload = valid_evidence(directory)
          artifacts = list(payload["artifacts"])
          artifacts[0] = dict(artifacts[0], path=reserved_name)
          payload["artifacts"] = artifacts
          path = write_evidence(directory, payload)
          with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "reserved real-device evidence filenames"):
            preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      measurements = dict(payload["measurements"])
      measurements["framePacing"] = dict(measurements["framePacing"], observedRefreshHz=80)
      payload["measurements"] = measurements
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "below required"):
        preflight.validate_evidence(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      measurements = dict(payload["measurements"])
      measurements["memory"] = dict(measurements["memory"], peakRSSMB=500, postAnalysisRSSMB=501)
      payload["measurements"] = measurements
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "postAnalysisRSSMB must be <= peakRSSMB"):
        preflight.validate_evidence(path)

  def test_artifact_fingerprinting_rechecks_opened_descriptor(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      evidence = write_evidence(directory, payload)
      screenshot = directory / "ipad-main.png"
      original_open = pathlib.Path.open

      def fake_open(path: pathlib.Path, *args: object, **kwargs: object) -> object:
        if path == screenshot:
          return DirectoryHandle(directory)
        return original_open(path, *args, **kwargs)

      with mock.patch.object(pathlib.Path, "open", fake_open):
        with self.assertRaisesRegex(
          preflight.RealDeviceEvidenceError,
          "artifact screenshot while hashing.*regular file after opening",
        ):
          preflight.validate_evidence(evidence, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      evidence = write_evidence(directory, payload)
      screenshot = directory / "ipad-main.png"
      original_open = pathlib.Path.open

      def fake_drift_open(path: pathlib.Path, *args: object, **kwargs: object) -> object:
        if path == screenshot:
          return DriftHandle(screenshot)
        return original_open(path, *args, **kwargs)

      with mock.patch.object(pathlib.Path, "open", fake_drift_open):
        with self.assertRaisesRegex(
          preflight.RealDeviceEvidenceError,
          "artifact screenshot opened-byte-count drift while hashing",
        ):
          preflight.validate_evidence(evidence, now=FRESH_NOW)

  def test_artifact_fingerprinting_rejects_oversized_opened_descriptor(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      evidence = write_evidence(directory, payload)
      screenshot = directory / "ipad-main.png"
      oversized = directory / "oversized-opened-screenshot.png"
      write_sparse_file(oversized, preflight.SCREENSHOT_ARTIFACT_MAX_BYTES + 1)
      original_open = pathlib.Path.open

      def fake_oversized_open(path: pathlib.Path, *args: object, **kwargs: object) -> object:
        if path == screenshot:
          return original_open(oversized, *args, **kwargs)
        return original_open(path, *args, **kwargs)

      with mock.patch.object(pathlib.Path, "open", fake_oversized_open):
        with self.assertRaisesRegex(
          preflight.RealDeviceEvidenceError,
          "artifact screenshot exceeds bounded artifact size.*after opening while hashing",
        ):
          preflight.validate_evidence(evidence, now=FRESH_NOW)

  def test_rejects_fractional_analysis_counts_and_non_finite_numbers(self) -> None:
    for field, value, expected_error in (
      ("visits", 128.5, "analysis.visits must be an integer"),
      ("candidateCount", 8.5, "analysis.candidateCount must be an integer"),
    ):
      with self.subTest(field=field):
        with tempfile.TemporaryDirectory() as raw_dir:
          directory = pathlib.Path(raw_dir)
          payload = valid_evidence(directory)
          payload["analysis"] = dict(payload["analysis"], **{field: value})
          path = write_evidence(directory, payload)
          with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, expected_error):
            preflight.validate_evidence(path, now=FRESH_NOW)

    for section, field in (
      ("launch", "coldLaunchMs"),
      ("framePacing", "observedRefreshHz"),
    ):
      with self.subTest(section=section, field=field):
        with tempfile.TemporaryDirectory() as raw_dir:
          directory = pathlib.Path(raw_dir)
          payload = valid_evidence(directory)
          measurements = cloned_measurements()
          measurements[section][field] = float("nan")
          payload["measurements"] = measurements
          path = write_evidence(directory, payload)
          with self.assertRaisesRegex(
            preflight.RealDeviceEvidenceError,
            "real-device evidence JSON must not contain non-standard JSON constant NaN",
          ):
            preflight.validate_evidence(path, now=FRESH_NOW)

  def test_rejects_duplicate_json_keys_in_evidence_and_artifacts(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      path = directory / "real-device-evidence.json"
      path.write_text(
        f'{{"schemaVersion":{preflight.REAL_DEVICE_EVIDENCE_SCHEMA_VERSION},"schemaVersion":{preflight.REAL_DEVICE_EVIDENCE_SCHEMA_VERSION},"kind":"qixi-real-device-evidence"}}\n',
        encoding="utf-8",
      )
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "duplicate JSON key 'schemaVersion'"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "instruments.json").write_text(
        "{"
        '"source":"instruments",'
        '"source":"xctrace",'
        f'"schemaVersion":{preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION},'
        '"kind":"qixi-real-device-performance",'
        f'"runId":{json.dumps(payload["runId"])},'
        f'"recordedAt":{json.dumps(payload["recordedAt"])},'
        f'"measurements":{json.dumps(payload["measurements"], sort_keys=True)}'
        "}\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "performance")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "performance artifact.*duplicate JSON key 'source'"):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "device.log").write_text(
        "{"
        f'"schemaVersion":{preflight.DEVICE_LOG_ARTIFACT_SCHEMA_VERSION},'
        '"kind":"qixi-real-device-log",'
        '"kind":"qixi-real-device-log",'
        f'"runId":{json.dumps(payload["runId"])},'
        f'"recordedAt":{json.dumps(payload["recordedAt"])}'
        "}\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(preflight.RealDeviceEvidenceError, "device-log artifact.*duplicate JSON key 'kind'"):
        preflight.validate_evidence(path, now=FRESH_NOW)

  def test_rejects_non_standard_json_constants_in_artifacts(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "instruments.json").write_text(
        "{"
        '"source":"instruments",'
        f'"schemaVersion":{preflight.PERFORMANCE_ARTIFACT_SCHEMA_VERSION},'
        '"kind":"qixi-real-device-performance",'
        f'"runId":{json.dumps(payload["runId"])},'
        f'"recordedAt":{json.dumps(payload["recordedAt"])},'
        '"measurements":{'
        '"launch":{"coldLaunchMs":Infinity,"visualReadyMs":1400},'
        '"memory":{"peakRSSMB":620,"postAnalysisRSSMB":590},'
        '"framePacing":{"targetRefreshHz":120,"observedRefreshHz":118,"droppedFramePercent":1.2}'
        "}"
        "}\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "performance")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(
        preflight.RealDeviceEvidenceError,
        "performance artifact.*non-standard JSON constant Infinity",
      ):
        preflight.validate_evidence(path, now=FRESH_NOW)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      payload = valid_evidence(directory)
      (directory / "device.log").write_text(
        "{"
        '"schemaVersion":NaN,'
        '"kind":"qixi-real-device-log",'
        f'"runId":{json.dumps(payload["runId"])},'
        f'"recordedAt":{json.dumps(payload["recordedAt"])}'
        "}\n",
        encoding="utf-8",
      )
      refresh_artifact_metadata(directory, payload, "device-log")
      path = write_evidence(directory, payload)
      with self.assertRaisesRegex(
        preflight.RealDeviceEvidenceError,
        "device-log artifact.*non-standard JSON constant NaN",
      ):
        preflight.validate_evidence(path, now=FRESH_NOW)

  def test_cli_requires_evidence_path(self) -> None:
    env = hermetic_qixi_env()
    result = subprocess.run(
      [str(ROOT / "scripts" / "qixi-real-device-evidence-preflight.sh")],
      cwd=ROOT,
      env=env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json is required", result.stderr)


if __name__ == "__main__":
  unittest.main()
