#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "qixi-real-device-evidence-template.py"
RUN_ID = "00000000-0000-4000-8000-000000000123"
RECORDED_AT = "2026-07-05T12:00:00Z"


class RealDeviceEvidenceTemplateTests(unittest.TestCase):
  def run_script(
    self,
    *args: str,
    extra_env: dict[str, str] | None = None,
  ) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env.pop("QIXI_BACKEND_URL", None)
    env.pop("QIXI_DEVICE_BACKEND_URL", None)
    if extra_env:
      env.update(extra_env)
    return subprocess.run(
      [sys.executable, str(SCRIPT), *args],
      cwd=ROOT,
      env=env,
      text=True,
      capture_output=True,
      check=False,
    )

  def test_stdout_template_is_native_only_and_lists_all_required_inputs(self) -> None:
    result = self.run_script("--run-id", RUN_ID, "--recorded-at", RECORDED_AT)

    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertIn("QIXI_ANALYSIS_RUNTIME=nativeInProcess", result.stdout)
    self.assertIn("QIXI_AUTOMATION_SELECT_ENGINE=b6", result.stdout)
    self.assertIn("QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH=1", result.stdout)
    self.assertIn("finalization launch after native analysis and external artifacts exist", result.stdout)
    self.assertIn("QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess", result.stdout)
    self.assertIn(f"QIXI_REAL_DEVICE_RUN_ID={RUN_ID}", result.stdout)
    self.assertIn(f"QIXI_REAL_DEVICE_RECORDED_AT={RECORDED_AT}", result.stdout)
    self.assertIn("QIXI_REAL_DEVICE_TARGET_REFRESH_HZ=120", result.stdout)
    self.assertIn("QIXI_REAL_DEVICE_SCREENSHOT_ARTIFACT=real-device-main.png", result.stdout)
    self.assertIn("QIXI_REAL_DEVICE_PERFORMANCE_ARTIFACT=real-device-performance.json", result.stdout)
    self.assertIn("QIXI_REAL_DEVICE_DEVICE_LOG_ARTIFACT=real-device-log.json", result.stdout)
    self.assertIn("QIXI_REAL_DEVICE_COLD_LAUNCH_MS=<integer measured on device>", result.stdout)
    self.assertIn("QIXI_REAL_DEVICE_PEAK_RSS_MB=<finite number measured on device>", result.stdout)
    self.assertIn("QIXI_REAL_DEVICE_CAMERA_RECOGNITION_TESTED=1", result.stdout)
    self.assertIn("Keep QIXI_BACKEND_URL and QIXI_DEVICE_BACKEND_URL unset", result.stdout)
    self.assertIn(
      "does not create or retain final evidence/artifact files; use the filled template for the finalization launch",
      result.stdout,
    )

  def test_rejects_backend_environment_for_native_release_evidence(self) -> None:
    result = self.run_script(
      "--run-id",
      RUN_ID,
      "--recorded-at",
      RECORDED_AT,
      extra_env={"QIXI_BACKEND_URL": "http://127.0.0.1:8765"},
    )

    self.assertEqual(result.returncode, 2)
    self.assertIn("nativeInProcess release evidence must not inherit backend transport environment", result.stderr)
    self.assertIn("QIXI_BACKEND_URL", result.stderr)

  def test_output_dir_contains_templates_but_no_release_evidence(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      output_dir = pathlib.Path(temp_dir) / "run-kit"
      result = self.run_script(
        "--run-id",
        RUN_ID,
        "--recorded-at",
        RECORDED_AT,
        "--output-dir",
        str(output_dir),
      )

      self.assertEqual(result.returncode, 0, result.stderr)
      self.assertTrue((output_dir / "README.md").is_file())
      self.assertTrue((output_dir / "xcode-run-env-template.txt").is_file())
      self.assertTrue((output_dir / "artifact-requirements.json").is_file())
      self.assertTrue((output_dir / "real-device-performance.template.json").is_file())
      self.assertTrue((output_dir / "real-device-log.template.json").is_file())
      self.assertFalse((output_dir / "real-device-evidence.qixi-release.json").exists())
      self.assertFalse((output_dir / "real-device-evidence.export.json").exists())
      self.assertFalse((output_dir / "real-device-main.png").exists())
      self.assertFalse((output_dir / "real-device-performance.json").exists())
      self.assertFalse((output_dir / "real-device-log.json").exists())

      manifest = json.loads((output_dir / "artifact-requirements.json").read_text(encoding="utf-8"))
      self.assertEqual(manifest["kind"], "qixi-real-device-evidence-run-kit")
      self.assertEqual(manifest["runtime"], "nativeInProcess")
      self.assertEqual(manifest["runId"], RUN_ID)
      self.assertEqual(manifest["recordedAt"], RECORDED_AT)
      self.assertEqual(manifest["finalEvidence"], "real-device-evidence.qixi-release.json")
      self.assertEqual(manifest["forbiddenEnvironment"], ["QIXI_DEVICE_BACKEND_URL", "QIXI_BACKEND_URL"])
      self.assertIn("scripts/qixi-real-device-evidence-preflight.sh", manifest["validation"]["preflight"])
      self.assertIn("scripts/qixi-release-evidence-gate.sh", manifest["validation"]["releaseGate"])

      performance_template = json.loads(
        (output_dir / "real-device-performance.template.json").read_text(encoding="utf-8")
      )
      device_log_template = json.loads((output_dir / "real-device-log.template.json").read_text(encoding="utf-8"))
      self.assertTrue(performance_template["templateOnly"])
      self.assertTrue(device_log_template["templateOnly"])
      self.assertEqual(performance_template["kind"], "qixi-real-device-performance")
      self.assertEqual(device_log_template["kind"], "qixi-real-device-log")

      readme = (output_dir / "README.md").read_text(encoding="utf-8")
      self.assertIn("not release evidence", readme)
      self.assertIn("Template JSON must never", readme)

  def test_refuses_non_empty_output_dir_without_force(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      output_dir = pathlib.Path(temp_dir) / "run-kit"
      output_dir.mkdir()
      (output_dir / "existing.txt").write_text("do not clobber\n", encoding="utf-8")

      result = self.run_script(
        "--run-id",
        RUN_ID,
        "--recorded-at",
        RECORDED_AT,
        "--output-dir",
        str(output_dir),
      )

      self.assertEqual(result.returncode, 2)
      self.assertIn("output directory is not empty", result.stderr)

  def test_force_still_refuses_existing_final_evidence_or_artifact_files(self) -> None:
    for filename in (
      "real-device-evidence.qixi-release.json",
      "real-device-evidence.export.json",
      "real-device-main.png",
      "real-device-performance.json",
      "real-device-log.json",
    ):
      with self.subTest(filename=filename):
        with tempfile.TemporaryDirectory() as temp_dir:
          output_dir = pathlib.Path(temp_dir) / "run-kit"
          output_dir.mkdir()
          (output_dir / filename).write_text("stale final file\n", encoding="utf-8")

          result = self.run_script(
            "--run-id",
            RUN_ID,
            "--recorded-at",
            RECORDED_AT,
            "--output-dir",
            str(output_dir),
            "--force",
          )

          self.assertEqual(result.returncode, 2)
          self.assertIn("must not create or retain final evidence or artifact files", result.stderr)
          self.assertIn(filename, result.stderr)

  def test_rejects_noncanonical_uuid(self) -> None:
    result = self.run_script("--run-id", "AAAAAAAA-0000-4000-8000-000000000123", "--recorded-at", RECORDED_AT)

    self.assertEqual(result.returncode, 2)
    self.assertIn("canonical lowercase UUID", result.stderr)

  def test_rejects_symlink_output_dir(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      target = pathlib.Path(temp_dir) / "target"
      target.mkdir()
      link = pathlib.Path(temp_dir) / "link"
      link.symlink_to(target, target_is_directory=True)

      result = self.run_script(
        "--run-id",
        RUN_ID,
        "--recorded-at",
        RECORDED_AT,
        "--output-dir",
        str(link),
      )

      self.assertEqual(result.returncode, 2)
      self.assertIn("must not contain symbolic links", result.stderr)


if __name__ == "__main__":
  unittest.main()
