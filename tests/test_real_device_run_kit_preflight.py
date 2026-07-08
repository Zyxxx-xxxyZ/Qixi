#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
import os
import pathlib
import struct
import tempfile
import unittest
import zlib
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "qixi_real_device_run_kit_preflight.py"

spec = importlib.util.spec_from_file_location("qixi_real_device_run_kit_preflight", SCRIPT)
assert spec is not None and spec.loader is not None
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


RUN_ID = "00000000-0000-4000-8000-000000000123"
RECORDED_AT = "2026-07-05T12:00:00Z"


class DriftHandle:
  def __init__(self, backing_file: pathlib.Path) -> None:
    self.fd = os.open(backing_file, os.O_RDONLY)
    self.did_read = False

  def fileno(self) -> int:
    return self.fd

  def read(self, _size: int = -1) -> bytes:
    if self.did_read:
      return b""
    self.did_read = True
    return b""

  def __enter__(self) -> "DriftHandle":
    return self

  def __exit__(self, _exc_type: object, _exc: object, _traceback: object) -> None:
    os.close(self.fd)


def png_with_dimensions(width: int = 1366, height: int = 1024, *, grid: bool = True) -> bytes:
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


def png_header_only(width: int = 1366, height: int = 1024) -> bytes:
  def chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)

  return (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    + chunk(b"IEND", b"")
  )


class RealDeviceRunKitPreflightTests(unittest.TestCase):
  def setUp(self) -> None:
    self.tempdir = tempfile.TemporaryDirectory()
    self.addCleanup(self.tempdir.cleanup)
    self.root = pathlib.Path(self.tempdir.name)
    self.run_kit_counter = 0

  def write_json(self, path: pathlib.Path, payload: object) -> None:
    path.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")

  def make_run_kit(self) -> pathlib.Path:
    self.run_kit_counter += 1
    run_kit = self.root / f"run-kit-{self.run_kit_counter}"
    run_kit.mkdir()
    self.write_json(
      run_kit / "artifact-requirements.json",
      {
        "schemaVersion": 1,
        "kind": "qixi-real-device-evidence-run-kit",
        "runtime": "nativeInProcess",
        "runId": RUN_ID,
        "recordedAt": RECORDED_AT,
        "finalEvidence": "real-device-evidence.qixi-release.json",
        "forbiddenEnvironment": ["QIXI_DEVICE_BACKEND_URL", "QIXI_BACKEND_URL"],
        "requiredArtifacts": [
          {
            "kind": "screenshot",
            "path": "real-device-main.png",
            "producer": "real physical-device landscape screenshot",
            "mustBeTemplate": False,
          },
          {
            "kind": "performance",
            "path": "real-device-performance.json",
            "producer": "Instruments, xctrace, or MetricKit measurement JSON",
            "mustBeTemplate": False,
          },
          {
            "kind": "device-log",
            "path": "real-device-log.json",
            "producer": "Qixi app auto-written structured device-log JSON matching the evidence fields",
            "mustBeTemplate": False,
          },
        ],
      },
    )
    (run_kit / "xcode-run-env-template.txt").write_text(
      "\n".join(
        [
          "QIXI_ANALYSIS_RUNTIME=nativeInProcess",
          "QIXI_AUTOMATION_SELECT_ENGINE=b6",
          "QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH=1",
          "QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess",
          f"QIXI_REAL_DEVICE_RUN_ID={RUN_ID}",
          f"QIXI_REAL_DEVICE_RECORDED_AT={RECORDED_AT}",
          "QIXI_REAL_DEVICE_EVIDENCE_OUTPUT=real-device-evidence.qixi-release.json",
          "QIXI_REAL_DEVICE_SCREENSHOT_ARTIFACT=real-device-main.png",
          "QIXI_REAL_DEVICE_PERFORMANCE_ARTIFACT=real-device-performance.json",
          "QIXI_REAL_DEVICE_DEVICE_LOG_ARTIFACT=real-device-log.json",
          "QIXI_REAL_DEVICE_TARGET_REFRESH_HZ=120",
          "QIXI_REAL_DEVICE_SIMULATOR=0",
          "QIXI_REAL_DEVICE_AUTOSAVE_WRITTEN=1",
          "QIXI_REAL_DEVICE_TOMBSTONE_WRITTEN=1",
          "QIXI_REAL_DEVICE_RESTORED_LATEST_STATE=1",
          "QIXI_REAL_DEVICE_CAMERA_RECOGNITION_TESTED=1",
          "QIXI_REAL_DEVICE_ICLOUD_SYNC_TESTED=1",
          "QIXI_REAL_DEVICE_MODEL_IMPORT_TESTED=1",
          "QIXI_REAL_DEVICE_IDIOM=iPad",
          "QIXI_REAL_DEVICE_MODEL=iPad Pro 13-inch (M5)",
          "QIXI_REAL_DEVICE_OS_VERSION=iPadOS 26.5",
          "QIXI_REAL_DEVICE_COLD_LAUNCH_MS=900",
          "QIXI_REAL_DEVICE_VISUAL_READY_MS=1400",
          "QIXI_REAL_DEVICE_PEAK_RSS_MB=620",
          "QIXI_REAL_DEVICE_POST_ANALYSIS_RSS_MB=590",
          "QIXI_REAL_DEVICE_OBSERVED_REFRESH_HZ=118",
          "QIXI_REAL_DEVICE_DROPPED_FRAME_PERCENT=1.2",
          "QIXI_REAL_DEVICE_BACKGROUNDED_SECONDS=30",
          "",
        ]
      ),
      encoding="utf-8",
    )
    (run_kit / "real-device-main.png").write_bytes(png_with_dimensions())
    self.write_json(
      run_kit / "real-device-performance.json",
      {
        "schemaVersion": 1,
        "kind": "qixi-real-device-performance",
        "source": "instruments",
        "runId": RUN_ID,
        "recordedAt": RECORDED_AT,
        "measurements": {
          "launch": {"coldLaunchMs": 900, "visualReadyMs": 1400},
          "memory": {"peakRSSMB": 620, "postAnalysisRSSMB": 590},
          "framePacing": {"targetRefreshHz": 120, "observedRefreshHz": 118, "droppedFramePercent": 1.2},
        },
      },
    )
    return run_kit

  def test_accepts_filled_run_kit_before_finalization_launch(self) -> None:
    run_kit = self.make_run_kit()

    summary = preflight.validate_run_kit(run_kit, {})

    self.assertEqual(summary["engine"], "b6")
    self.assertEqual(summary["runId"], RUN_ID)

  def test_rejects_placeholders_or_backend_transport(self) -> None:
    run_kit = self.make_run_kit()
    env_path = run_kit / "xcode-run-env-template.txt"
    env_path.write_text(env_path.read_text(encoding="utf-8") + "QIXI_REAL_DEVICE_MODEL=<iPad>\n", encoding="utf-8")
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "placeholder"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "must not inherit backend"):
      preflight.validate_run_kit(run_kit, {"QIXI_BACKEND_URL": "http://127.0.0.1:8765"})

    run_kit = self.make_run_kit()
    env_path = run_kit / "xcode-run-env-template.txt"
    env_text = env_path.read_text(encoding="utf-8")
    env_path.write_text(
      env_text.replace(
        "QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH=1",
        "QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_ANALYSIS=1",
      ),
      encoding="utf-8",
    )
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH=1"):
      preflight.validate_run_kit(run_kit, {})

  def test_bounded_readers_recheck_opened_descriptor_byte_count(self) -> None:
    run_kit = self.make_run_kit()
    manifest_path = run_kit / "artifact-requirements.json"
    original_open = pathlib.Path.open

    def fake_manifest_open(path: pathlib.Path, *args: object, **kwargs: object) -> object:
      if path == manifest_path:
        return DriftHandle(manifest_path)
      return original_open(path, *args, **kwargs)

    with mock.patch.object(pathlib.Path, "open", fake_manifest_open):
      with self.assertRaisesRegex(
        preflight.RealDeviceRunKitPreflightError,
        "artifact-requirements.json opened-byte-count drift while reading",
      ):
        preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    env_path = run_kit / "xcode-run-env-template.txt"

    def fake_env_open(path: pathlib.Path, *args: object, **kwargs: object) -> object:
      if path == env_path:
        return DriftHandle(env_path)
      return original_open(path, *args, **kwargs)

    with mock.patch.object(pathlib.Path, "open", fake_env_open):
      with self.assertRaisesRegex(
        preflight.RealDeviceRunKitPreflightError,
        "real-device run-kit Xcode environment template opened-byte-count drift while reading",
      ):
        preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    screenshot_path = run_kit / "real-device-main.png"

    def fake_screenshot_open(path: pathlib.Path, *args: object, **kwargs: object) -> object:
      if path == screenshot_path:
        return DriftHandle(screenshot_path)
      return original_open(path, *args, **kwargs)

    with mock.patch.object(pathlib.Path, "open", fake_screenshot_open):
      with self.assertRaisesRegex(
        preflight.RealDeviceRunKitPreflightError,
        "real-device screenshot artifact opened-byte-count drift while reading",
      ):
        preflight.validate_run_kit(run_kit, {})

  def test_screenshot_visual_decode_uses_same_bounded_bytes(self) -> None:
    from PIL import Image

    run_kit = self.make_run_kit()
    opened_from: list[object] = []
    original_image_open = Image.open

    def fake_image_open(file: object, *args: object, **kwargs: object) -> object:
      opened_from.append(file)
      return original_image_open(file, *args, **kwargs)

    with mock.patch("PIL.Image.open", side_effect=fake_image_open):
      summary = preflight.validate_run_kit(run_kit, {})

    self.assertEqual(summary["runId"], RUN_ID)
    self.assertEqual(len(opened_from), 1)
    self.assertIsInstance(opened_from[0], io.BytesIO)

  def test_rejects_template_or_mismatched_performance_artifact(self) -> None:
    run_kit = self.make_run_kit()
    payload = json.loads((run_kit / "real-device-performance.json").read_text(encoding="utf-8"))
    payload["templateOnly"] = True
    self.write_json(run_kit / "real-device-performance.json", payload)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "template JSON"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    payload = json.loads((run_kit / "real-device-performance.json").read_text(encoding="utf-8"))
    payload["measurements"]["memory"]["peakRSSMB"] = 621
    self.write_json(run_kit / "real-device-performance.json", payload)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "must match"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    payload = json.loads((run_kit / "real-device-performance.json").read_text(encoding="utf-8"))
    payload["recordedAt"] = "2026-07-05T12:05:00Z"
    self.write_json(run_kit / "real-device-performance.json", payload)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "must not be newer"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    payload = json.loads((run_kit / "real-device-performance.json").read_text(encoding="utf-8"))
    payload["recordedAt"] = "2026-07-04T10:59:59Z"
    self.write_json(run_kit / "real-device-performance.json", payload)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "too old"):
      preflight.validate_run_kit(run_kit, {})

  def test_rejects_ambiguous_required_artifact_manifest_entries(self) -> None:
    run_kit = self.make_run_kit()
    manifest_path = run_kit / "artifact-requirements.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["requiredArtifacts"].append(
      {"kind": "screenshot", "path": "real-device-main.png", "producer": "duplicate", "mustBeTemplate": False}
    )
    self.write_json(manifest_path, manifest)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "duplicate artifact kind: screenshot"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    manifest_path = run_kit / "artifact-requirements.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["requiredArtifacts"][1]["path"] = "real-device-main.png"
    self.write_json(manifest_path, manifest)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "duplicate artifact path"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    manifest_path = run_kit / "artifact-requirements.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["requiredArtifacts"].append(
      {"kind": "trace", "path": "trace.json", "producer": "unexpected", "mustBeTemplate": False}
    )
    self.write_json(manifest_path, manifest)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "unsupported artifact kind: trace"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    manifest_path = run_kit / "artifact-requirements.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["requiredArtifacts"] = manifest["requiredArtifacts"][:2]
    self.write_json(manifest_path, manifest)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "must contain exactly"):
      preflight.validate_run_kit(run_kit, {})

  def test_rejects_required_artifact_manifest_metadata_drift(self) -> None:
    run_kit = self.make_run_kit()
    manifest_path = run_kit / "artifact-requirements.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["requiredArtifacts"][0]["producer"] = "simulator screenshot"
    self.write_json(manifest_path, manifest)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "requiredArtifacts.screenshot.producer"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    manifest_path = run_kit / "artifact-requirements.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["requiredArtifacts"][1]["mustBeTemplate"] = True
    self.write_json(manifest_path, manifest)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "requiredArtifacts.performance.mustBeTemplate must be false"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    manifest_path = run_kit / "artifact-requirements.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["requiredArtifacts"][2].pop("mustBeTemplate")
    self.write_json(manifest_path, manifest)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "requiredArtifacts.device-log.mustBeTemplate must be a boolean"):
      preflight.validate_run_kit(run_kit, {})

  def test_rejects_preexisting_app_written_outputs(self) -> None:
    for filename in (
      "real-device-evidence.qixi-release.json",
      "real-device-evidence.export.json",
      "real-device-log.json",
    ):
      with self.subTest(filename=filename):
        run_kit = self.make_run_kit()
        (run_kit / filename).write_text("stale\n", encoding="utf-8")
        with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "must not exist before the final evidence finalization launch"):
          preflight.validate_run_kit(run_kit, {})

  def test_rejects_symlinked_artifact_and_weak_screenshot(self) -> None:
    run_kit = self.make_run_kit()
    target = self.root / "outside.png"
    target.write_bytes(png_with_dimensions())
    (run_kit / "real-device-main.png").unlink()
    (run_kit / "real-device-main.png").symlink_to(target)
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "symbolic links"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    (run_kit / "real-device-main.png").write_bytes(png_with_dimensions(width=600, height=500))
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "too small"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    (run_kit / "real-device-main.png").write_bytes(png_header_only())
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "decodable PNG"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    (run_kit / "real-device-main.png").write_bytes(png_with_dimensions(grid=False))
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "blank or nearly flat"):
      preflight.validate_run_kit(run_kit, {})

    run_kit = self.make_run_kit()
    (run_kit / "real-device-main.png").write_bytes(png_header_only(width=20_000, height=10_000))
    with self.assertRaisesRegex(preflight.RealDeviceRunKitPreflightError, "too large for bounded visual inspection"):
      preflight.validate_run_kit(run_kit, {})


if __name__ == "__main__":
  unittest.main()
