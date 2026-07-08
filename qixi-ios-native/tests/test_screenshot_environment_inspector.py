#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import datetime
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSPECTOR_PATH = ROOT / "tests" / "inspect_screenshot_environment.py"


def load_inspector():
  spec = importlib.util.spec_from_file_location("screenshot_environment_inspector", INSPECTOR_PATH)
  assert spec and spec.loader
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  return module


class ScreenshotEnvironmentInspectorTests(unittest.TestCase):
  def setUp(self) -> None:
    self.module = load_inspector()
    self.tempdir = tempfile.TemporaryDirectory()
    self.addCleanup(self.tempdir.cleanup)
    self.root = pathlib.Path(self.tempdir.name)
    self.artifact = self.root / "screenshot-environment.json"

  def payload(self) -> dict:
    return {
      "schemaVersion": 1,
      "generatedAt": "2026-07-06T12:00:00Z",
      "bootSimulators": True,
      "xcodebuildVersion": "Xcode 26.6\nBuild version 17F113",
      "selected": {
        "iPad": {
          "name": "iPad Pro 13-inch (M5)",
          "udid": "320E80FA-9340-4F4F-AF3A-9E6E772C5E22",
          "state": "Booted",
          "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        },
        "iPhone": {
          "name": "iPhone 17 Pro Max",
          "udid": "386DF3F5-2E97-44B8-8ED2-AAEA979C9574",
          "state": "Booted",
          "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        },
      },
      "commands": self.module.EXPECTED_COMMANDS,
      "limits": [
        "Simulator evidence covers SwiftUI layout, screenshots, persistence, and HTTP bridge behavior.",
        "Real ProMotion, Metal/GPU/ANE, camera, iCloud propagation, background kill, and native in-process KataGo still require physical-device evidence.",
      ],
    }

  def write_payload(self, payload: dict | None = None) -> pathlib.Path:
    self.artifact.write_text(json.dumps(payload or self.payload(), sort_keys=True), encoding="utf-8")
    return self.artifact

  def run_main_silently(self, path: pathlib.Path | None = None) -> int:
    args = [str(path or self.artifact)]
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
      return self.module.main(args)

  def test_accepts_valid_screenshot_environment_artifact(self) -> None:
    path = self.write_payload()
    self.assertEqual(self.module.inspect_artifact(path)["schemaVersion"], 1)
    self.assertEqual(self.run_main_silently(path), 0)

  def test_default_artifact_path_uses_doctor_artifact_env(self) -> None:
    path = self.write_payload()
    with mock.patch.dict(os.environ, {"QIXI_SCREENSHOT_DOCTOR_ARTIFACT": str(path)}):
      self.assertEqual(self.module.default_artifact_path(), path)
      with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        self.assertEqual(self.module.main([]), 0)

  def test_rejects_ambiguous_or_non_standard_json(self) -> None:
    self.artifact.write_text('{"schemaVersion":1,"schemaVersion":2}\n', encoding="utf-8")
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "duplicate JSON key"):
      self.module.inspect_artifact(self.artifact)

    self.artifact.write_text('{"schemaVersion":1,"generatedAt":NaN}\n', encoding="utf-8")
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "non-standard JSON constant"):
      self.module.inspect_artifact(self.artifact)

  def test_rejects_unsafe_or_oversized_artifact_files(self) -> None:
    empty = self.root / "empty.json"
    empty.write_text("", encoding="utf-8")
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "artifact is empty"):
      self.module.inspect_artifact(empty)

    directory = self.root / "directory.json"
    directory.mkdir()
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "must be a regular file"):
      self.module.inspect_artifact(directory)

    target = self.write_payload()
    symlink = self.root / "symlink.json"
    symlink.symlink_to(target)
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "path must not contain symbolic links"):
      self.module.inspect_artifact(symlink)

    oversized = self.root / "oversized.json"
    with oversized.open("wb") as handle:
      handle.truncate(self.module.MAX_ENVIRONMENT_ARTIFACT_BYTES + 1)
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "exceeds"):
      self.module.inspect_artifact(oversized)

  def test_rejects_symlink_path_components_but_allows_platform_aliases(self) -> None:
    real_dir = self.root / "real"
    real_dir.mkdir()
    symlink_dir = self.root / "linked"
    symlink_dir.symlink_to(real_dir)
    symlink_component_artifact = symlink_dir / "screenshot-environment.json"
    symlink_component_artifact.write_text(json.dumps(self.payload(), sort_keys=True), encoding="utf-8")
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "path must not contain symbolic links"):
      self.module.inspect_artifact(symlink_component_artifact)

    tmp_alias = pathlib.Path("/tmp")
    if tmp_alias.is_symlink() and tmp_alias.resolve(strict=True) == pathlib.Path("/private/tmp"):
      self.assertTrue(self.module.is_allowed_platform_symlink_alias(tmp_alias))

  def test_rejects_stale_environment_artifact(self) -> None:
    path = self.write_payload()
    min_mtime = path.stat().st_mtime + 1.0
    with mock.patch.dict(os.environ, {"QIXI_SCREENSHOT_ENVIRONMENT_MIN_MTIME_EPOCH": str(min_mtime)}):
      with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "stale for this run"):
        self.module.inspect_artifact(path)

  def test_rejects_stale_generated_at_even_when_file_mtime_is_fresh(self) -> None:
    payload = self.payload()
    payload["generatedAt"] = "2000-01-01T00:00:00Z"
    path = self.write_payload(payload)
    min_mtime = path.stat().st_mtime - 1.0
    with mock.patch.dict(os.environ, {"QIXI_SCREENSHOT_ENVIRONMENT_MIN_MTIME_EPOCH": str(min_mtime)}):
      with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "stale screenshot environment generatedAt"):
        self.module.inspect_artifact(path)

  def test_rejects_generated_at_too_far_in_the_future(self) -> None:
    payload = self.payload()
    generated_at = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(
      seconds=self.module.GENERATED_AT_MAX_FUTURE_SKEW_SECONDS + 1
    )
    payload["generatedAt"] = generated_at.isoformat().replace("+00:00", "Z")
    path = self.write_payload(payload)
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "too far in the future"):
      self.module.inspect_artifact(path)

  def test_rejects_command_drift(self) -> None:
    payload = self.payload()
    payload["commands"] = {**payload["commands"], "fastSmoke": "scripts/other.sh"}
    path = self.write_payload(payload)
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "documented screenshot entrypoints"):
      self.module.inspect_artifact(path)

  def test_rejects_selected_simulator_shape_errors(self) -> None:
    payload = self.payload()
    payload["selected"]["iPad"]["state"] = "Shutdown"
    path = self.write_payload(payload)
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "must be Booted"):
      self.module.inspect_artifact(path)

    payload = self.payload()
    payload["selected"]["iPhone"]["udid"] = "not-a-udid"
    path = self.write_payload(payload)
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "not a simulator UDID"):
      self.module.inspect_artifact(path)

  def test_rejects_missing_real_device_caveat(self) -> None:
    payload = self.payload()
    payload["limits"] = [
      "Simulator evidence covers SwiftUI layout, screenshots, persistence, and HTTP bridge behavior.",
      "Real devices are optional.",
    ]
    path = self.write_payload(payload)
    with self.assertRaisesRegex(self.module.ScreenshotEnvironmentError, "Real ProMotion"):
      self.module.inspect_artifact(path)


if __name__ == "__main__":
  unittest.main()
