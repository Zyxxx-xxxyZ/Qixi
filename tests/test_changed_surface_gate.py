#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import pathlib
import re
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "qixi_changed_surface_gate.py"

spec = importlib.util.spec_from_file_location("qixi_changed_surface_gate", SCRIPT)
assert spec is not None and spec.loader is not None
gate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gate
spec.loader.exec_module(gate)


class ChangedSurfaceGateTests(unittest.TestCase):
  def multiline_header(self, text: str, name: str) -> tuple[str, list[str]]:
    lines = text.splitlines()
    header = next(line for line in lines if line.startswith(f"{name}<<"))
    delimiter = header.split("<<", 1)[1]
    start = lines.index(header) + 1
    end = lines.index(delimiter, start)
    return delimiter, lines[start:end]

  def test_swiftui_and_resource_changes_require_screenshot_gate(self) -> None:
    classification = gate.classify_changed_files([
      "qixi-ios-native/Qixi/RootView.swift",
      "qixi-ios-native/Qixi/Resources/Images/board06InkPaper.png",
      "docs/native-ios-runbook.md",
    ])

    self.assertTrue(classification.requires_screenshots)
    self.assertFalse(classification.requires_real_models)
    self.assertEqual(
      classification.screenshot_relevant_files,
      (
        "qixi-ios-native/Qixi/RootView.swift",
        "qixi-ios-native/Qixi/Resources/Images/board06InkPaper.png",
      ),
    )

  def test_screenshot_manifest_and_inspector_changes_require_screenshot_gate(self) -> None:
    classification = gate.classify_changed_files([
      "./qixi-ios-native/tests/screenshot_coverage_manifest.json",
      "qixi-ios-native/tests/screenshot_manifest_json.py",
      "qixi-ios-native/tests/inspect_engine_error_screenshot.py",
      "qixi-ios-native/scripts/screenshot-hermes-statuses.sh",
      "qixi-ios-native/scripts/screenshot-iphone-utility-sheets.sh",
      "qixi-ios-native/scripts/build_screenshot_review_board.py",
      "qixi-ios-native/scripts/performance-smoke-sim.sh",
      "qixi-ios-native/scripts/persistence-smoke-sim.sh",
      "qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh",
    ])

    self.assertTrue(classification.requires_screenshots)
    self.assertEqual(
      classification.screenshot_relevant_files,
      (
        "qixi-ios-native/tests/screenshot_coverage_manifest.json",
        "qixi-ios-native/tests/screenshot_manifest_json.py",
        "qixi-ios-native/tests/inspect_engine_error_screenshot.py",
        "qixi-ios-native/scripts/screenshot-hermes-statuses.sh",
        "qixi-ios-native/scripts/screenshot-iphone-utility-sheets.sh",
        "qixi-ios-native/scripts/build_screenshot_review_board.py",
        "qixi-ios-native/scripts/performance-smoke-sim.sh",
        "qixi-ios-native/scripts/persistence-smoke-sim.sh",
        "qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh",
      ),
    )

  def test_backend_and_katago_changes_require_real_model_gate(self) -> None:
    classification = gate.classify_changed_files([
      "KataGo/cpp/neuralnet/metalbackend.cpp",
      "qixi-ios-sim/backend/qixi_backend.py",
      "docs/native-katago-integration.md",
    ])

    self.assertFalse(classification.requires_screenshots)
    self.assertEqual(classification.screenshot_relevant_files, ())
    self.assertTrue(classification.requires_real_models)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.real_model_relevant_files,
      (
        "KataGo/cpp/neuralnet/metalbackend.cpp",
        "qixi-ios-sim/backend/qixi_backend.py",
      ),
    )
    self.assertTrue(classification.requires_ios_katago_cmake)
    self.assertEqual(
      classification.ios_katago_cmake_relevant_files,
      ("KataGo/cpp/neuralnet/metalbackend.cpp",),
    )
    self.assertEqual(
      classification.native_release_sim_relevant_files,
      ("KataGo/cpp/neuralnet/metalbackend.cpp",),
    )
    self.assertEqual(
      classification.release_sensitive_files,
      ("docs/native-katago-integration.md",),
    )

  def test_native_model_changes_require_both_screenshot_and_real_model_gates(self) -> None:
    classification = gate.classify_changed_files([
      "qixi-ios-native/Qixi/QixiNativeModelRegistry.swift",
      "qixi-ios-native/Qixi/RootView.swift",
    ])

    self.assertTrue(classification.requires_screenshots)
    self.assertTrue(classification.requires_real_models)
    self.assertTrue(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertIn("qixi-ios-native/Qixi/QixiNativeModelRegistry.swift", classification.real_model_relevant_files)
    self.assertIn("qixi-ios-native/Qixi/QixiNativeModelRegistry.swift", classification.ios_katago_cmake_relevant_files)
    self.assertIn("qixi-ios-native/Qixi/QixiNativeModelRegistry.swift", classification.native_release_sim_relevant_files)

  def test_position_identity_fixture_change_requires_real_model_gate(self) -> None:
    classification = gate.classify_changed_files([
      "tests/fixtures/position_identity_cases.json",
      "tests/validate_position_identity_fixture.py",
      "tests/test_position_identity_fixture_validator.py",
    ])

    self.assertFalse(classification.requires_screenshots)
    self.assertTrue(classification.requires_real_models)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertFalse(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.real_model_relevant_files,
      (
        "tests/fixtures/position_identity_cases.json",
        "tests/validate_position_identity_fixture.py",
        "tests/test_position_identity_fixture_validator.py",
      ),
    )
    self.assertEqual(
      classification.release_sensitive_files,
      (
        "tests/fixtures/position_identity_cases.json",
        "tests/validate_position_identity_fixture.py",
        "tests/test_position_identity_fixture_validator.py",
      ),
    )

  def test_docs_only_change_requires_no_expensive_gate(self) -> None:
    classification = gate.classify_changed_files([
      "docs/ordinary-user-note.md",
      "notes/ordinary-design-note.md",
    ])

    self.assertFalse(classification.requires_screenshots)
    self.assertFalse(classification.requires_real_models)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertFalse(classification.requires_native_release_sim)
    self.assertFalse(classification.requires_release_review)

  def test_release_sensitive_changes_require_release_review(self) -> None:
    classification = gate.classify_changed_files([
      "scripts/qixi-appstore-archive-preflight.sh",
      "scripts/qixi-release-evidence-gate.sh",
      "scripts/qixi-appstore-preflight.sh",
      "scripts/qixi-real-device-evidence-template.py",
      "scripts/qixi-real-device-run-kit-preflight.sh",
      "scripts/qixi-device-run-preflight.sh",
      "scripts/qixi_device_run_preflight.py",
      "scripts/qixi_real_device_evidence_preflight.py",
      "scripts/qixi_real_device_run_kit_preflight.py",
      "scripts/qixi_release_evidence_archive_match.py",
      "tests/test_repo_hygiene_preflight.py",
      "tests/test_quality_gate_skip_audit.py",
      "tests/test_real_device_evidence_template.py",
      "tests/test_real_device_run_kit_preflight.py",
      "tests/test_device_run_preflight.py",
      "tests/test_device_signing_doctor.py",
      "tests/test_release_evidence_archive_match.py",
      "qixi-ios-native/Qixi/PrivacyInfo.xcprivacy",
      "qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh",
      "docs/native-ios-runbook.md",
      "docs/native-katago-integration.md",
    ])

    self.assertTrue(classification.requires_screenshots)
    self.assertFalse(classification.requires_real_models)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertFalse(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.screenshot_relevant_files,
      ("qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh",),
    )
    self.assertEqual(
      classification.release_sensitive_files,
      (
        "scripts/qixi-appstore-archive-preflight.sh",
        "scripts/qixi-release-evidence-gate.sh",
        "scripts/qixi-appstore-preflight.sh",
        "scripts/qixi-real-device-evidence-template.py",
        "scripts/qixi-real-device-run-kit-preflight.sh",
        "scripts/qixi-device-run-preflight.sh",
        "scripts/qixi_device_run_preflight.py",
        "scripts/qixi_real_device_evidence_preflight.py",
        "scripts/qixi_real_device_run_kit_preflight.py",
        "scripts/qixi_release_evidence_archive_match.py",
        "tests/test_repo_hygiene_preflight.py",
        "tests/test_quality_gate_skip_audit.py",
        "tests/test_real_device_evidence_template.py",
        "tests/test_real_device_run_kit_preflight.py",
        "tests/test_device_run_preflight.py",
        "tests/test_device_signing_doctor.py",
        "tests/test_release_evidence_archive_match.py",
        "qixi-ios-native/Qixi/PrivacyInfo.xcprivacy",
        "qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh",
        "docs/native-ios-runbook.md",
        "docs/native-katago-integration.md",
      ),
    )

  def test_device_signing_doctor_implementation_change_requires_release_review(self) -> None:
    classification = gate.classify_changed_files([
      "scripts/qixi_device_signing_doctor.py",
      "tests/test_device_signing_doctor.py",
    ])

    self.assertFalse(classification.requires_screenshots)
    self.assertFalse(classification.requires_real_models)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.native_release_sim_relevant_files,
      ("scripts/qixi_device_signing_doctor.py",),
    )
    self.assertEqual(
      classification.release_sensitive_files,
      (
        "scripts/qixi_device_signing_doctor.py",
        "tests/test_device_signing_doctor.py",
      ),
    )

  def test_device_bridge_smoke_implementation_change_requires_release_review(self) -> None:
    classification = gate.classify_changed_files([
      "scripts/qixi_device_bridge_smoke.py",
      "scripts/qixi-device-bridge-plan-inspect.sh",
      "scripts/qixi-device-bridge-failure-inspect.sh",
      "scripts/qixi_device_bridge_smoke_inspect.py",
      "tests/test_device_bridge_smoke.py",
      "tests/test_device_bridge_smoke_inspector.py",
    ])

    self.assertFalse(classification.requires_screenshots)
    self.assertFalse(classification.requires_real_models)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.native_release_sim_relevant_files,
      (
        "scripts/qixi_device_bridge_smoke.py",
        "scripts/qixi-device-bridge-plan-inspect.sh",
        "scripts/qixi-device-bridge-failure-inspect.sh",
        "scripts/qixi_device_bridge_smoke_inspect.py",
      ),
    )
    self.assertEqual(
      classification.release_sensitive_files,
      (
        "scripts/qixi_device_bridge_smoke.py",
        "scripts/qixi-device-bridge-plan-inspect.sh",
        "scripts/qixi-device-bridge-failure-inspect.sh",
        "scripts/qixi_device_bridge_smoke_inspect.py",
        "tests/test_device_bridge_smoke.py",
        "tests/test_device_bridge_smoke_inspector.py",
      ),
    )

  def test_native_ios_runbook_change_is_release_sensitive_only(self) -> None:
    classification = gate.classify_changed_files(["docs/native-ios-runbook.md"])

    self.assertFalse(classification.requires_screenshots)
    self.assertFalse(classification.requires_real_models)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertFalse(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(classification.release_sensitive_files, ("docs/native-ios-runbook.md",))

  def test_native_katago_integration_doc_change_is_release_sensitive_only(self) -> None:
    classification = gate.classify_changed_files(["docs/native-katago-integration.md"])

    self.assertFalse(classification.requires_screenshots)
    self.assertFalse(classification.requires_real_models)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertFalse(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(classification.release_sensitive_files, ("docs/native-katago-integration.md",))

  def test_qixi_readmes_are_release_sensitive_only(self) -> None:
    classification = gate.classify_changed_files([
      "README.md",
      "qixi-ios-native/README.md",
      "qixi-ios-sim/README.md",
    ])

    self.assertFalse(classification.requires_screenshots)
    self.assertFalse(classification.requires_real_models)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertFalse(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.release_sensitive_files,
      (
        "README.md",
        "qixi-ios-native/README.md",
        "qixi-ios-sim/README.md",
      ),
    )

  def test_native_model_registry_change_is_real_model_and_release_sensitive(self) -> None:
    classification = gate.classify_changed_files([
      "qixi-ios-native/Qixi/QixiNativeModelRegistry.swift",
    ])

    self.assertTrue(classification.requires_screenshots)
    self.assertTrue(classification.requires_real_models)
    self.assertTrue(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.screenshot_relevant_files,
      ("qixi-ios-native/Qixi/QixiNativeModelRegistry.swift",),
    )
    self.assertEqual(
      classification.real_model_relevant_files,
      ("qixi-ios-native/Qixi/QixiNativeModelRegistry.swift",),
    )
    self.assertEqual(
      classification.ios_katago_cmake_relevant_files,
      ("qixi-ios-native/Qixi/QixiNativeModelRegistry.swift",),
    )
    self.assertEqual(
      classification.native_release_sim_relevant_files,
      ("qixi-ios-native/Qixi/QixiNativeModelRegistry.swift",),
    )
    self.assertEqual(
      classification.release_sensitive_files,
      ("qixi-ios-native/Qixi/QixiNativeModelRegistry.swift",),
    )

  def test_local_model_and_coreml_artifact_paths_are_release_sensitive(self) -> None:
    classification = gate.classify_changed_files([
      "b18nbt.bin",
      "Models/b6/raw-model.bin.gz",
      "converted/b6/network.onnx",
      "converted/b6/network.mlmodel",
      "converted/b6/network.mlmodelc/Info.plist",
      "converted/b6/network.mlpackage/Manifest.json",
    ])

    self.assertFalse(classification.requires_screenshots)
    self.assertTrue(classification.requires_real_models)
    self.assertTrue(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    expected = (
      "b18nbt.bin",
      "Models/b6/raw-model.bin.gz",
      "converted/b6/network.onnx",
      "converted/b6/network.mlmodel",
      "converted/b6/network.mlmodelc/Info.plist",
      "converted/b6/network.mlpackage/Manifest.json",
    )
    self.assertEqual(classification.real_model_relevant_files, expected)
    self.assertEqual(classification.ios_katago_cmake_relevant_files, expected)
    self.assertEqual(classification.native_release_sim_relevant_files, expected)
    self.assertEqual(classification.release_sensitive_files, expected)

  def test_gitignore_change_is_release_sensitive_hygiene_surface(self) -> None:
    classification = gate.classify_changed_files([".gitignore"])

    self.assertFalse(classification.requires_screenshots)
    self.assertFalse(classification.requires_real_models)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertFalse(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(classification.release_sensitive_files, (".gitignore",))

  def test_changed_file_parser_normalizes_deduplicates_and_supports_commas(self) -> None:
    parsed = gate.split_changed_files(
      "./qixi-ios-native/Qixi/BoardView.swift,"
      "qixi-ios-native/Qixi/BoardView.swift,"
      "qixi-ios-native/Qixi/Resources/Assets.xcassets/Contents.json"
    )
    classification = gate.classify_changed_files(parsed)

    self.assertEqual(
      classification.changed_files,
      (
        "qixi-ios-native/Qixi/BoardView.swift",
        "qixi-ios-native/Qixi/Resources/Assets.xcassets/Contents.json",
      ),
    )
    self.assertTrue(classification.requires_screenshots)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertFalse(classification.requires_native_release_sim)

  def test_changed_file_parser_preserves_nul_separated_special_paths(self) -> None:
    parsed = gate.split_changed_files(
      "docs/name,with-comma.md\0"
      "converted/b6/network.mlpackage/Manifest.json\0"
    )
    self.assertEqual(
      parsed,
      [
        "docs/name,with-comma.md",
        "converted/b6/network.mlpackage/Manifest.json",
      ],
    )
    classification = gate.classify_changed_files(parsed)

    self.assertTrue(classification.requires_real_models)
    self.assertTrue(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertIn("converted/b6/network.mlpackage/Manifest.json", classification.real_model_relevant_files)

  def test_changed_file_parser_rejects_untrusted_paths(self) -> None:
    for raw, message in (
      ("/qixi-ios-native/Qixi/RootView.swift", "repository-relative"),
      ("~/qixi-ios-native/Qixi/RootView.swift", "repository-relative"),
      ("../qixi-ios-native/Qixi/RootView.swift", "parent-directory"),
      ("qixi-ios-native//Qixi/RootView.swift", "empty"),
      ("qixi-ios-native/./Qixi/RootView.swift", "current-directory"),
      ("qixi-ios-native/Qixi/Root\nView.swift\0", "control characters"),
      ("qixi-ios-native\\Qixi\\RootView.swift", "POSIX separators"),
    ):
      with self.subTest(raw=raw):
        with self.assertRaisesRegex(gate.ChangedSurfaceGateError, message):
          gate.split_changed_files(raw)

  def test_changed_file_classifier_rejects_backslashes_in_tokenized_paths(self) -> None:
    with self.assertRaisesRegex(gate.ChangedSurfaceGateError, "backslashes"):
      gate.classify_changed_files(["qixi-ios-native\\Qixi\\RootView.swift"])

  def test_changed_file_parser_rejects_surrounding_whitespace_in_tokenized_paths(self) -> None:
    for paths in (
      [" qixi-ios-native/Qixi/RootView.swift"],
      ["qixi-ios-native/Qixi/RootView.swift "],
    ):
      with self.subTest(paths=paths):
        with self.assertRaisesRegex(gate.ChangedSurfaceGateError, "surrounding whitespace"):
          gate.classify_changed_files(paths)

  def test_changed_file_parser_rejects_surrounding_whitespace_in_comma_input(self) -> None:
    for raw in (
      " qixi-ios-native/Qixi/RootView.swift",
      "qixi-ios-native/Qixi/RootView.swift ",
      "qixi-ios-native/Qixi/RootView.swift, qixi-ios-native/Qixi/BoardView.swift",
    ):
      with self.subTest(raw=raw):
        with self.assertRaisesRegex(gate.ChangedSurfaceGateError, "surrounding whitespace"):
          gate.split_changed_files(raw)

  def test_changed_files_from_env_rejects_whitespace_only_value(self) -> None:
    with mock.patch.dict(gate.os.environ, {"QIXI_CHANGED_FILES": " "}, clear=False):
      with self.assertRaisesRegex(gate.ChangedSurfaceGateError, "surrounding whitespace"):
        gate.changed_files_from_env()

  def test_git_diff_rejects_surrounding_whitespace_in_nul_terminated_name(self) -> None:
    completed = gate.subprocess.CompletedProcess(
      args=["git", "diff", "--name-only", "-z", "HEAD"],
      returncode=0,
      stdout="qixi-ios-native/Qixi/RootView.swift \0",
      stderr="",
    )
    with mock.patch.object(gate.subprocess, "run", return_value=completed):
      with self.assertRaisesRegex(gate.ChangedSurfaceGateError, "surrounding whitespace"):
        gate.run_git_diff(["diff", "--name-only", "-z", "HEAD"])

  def test_git_diff_uses_nul_terminated_name_output(self) -> None:
    with mock.patch.object(gate, "run_git_diff", return_value=[]) as run_git_diff:
      gate.changed_files_from_git("main")
    self.assertEqual(run_git_diff.call_args.args[0], ["diff", "--name-only", "-z", "origin/main...HEAD"])

    with mock.patch.object(gate, "run_git_diff", return_value=[]) as run_git_diff:
      gate.changed_files_from_git(None)
    self.assertEqual(run_git_diff.call_args.args[0], ["diff", "--name-only", "-z", "HEAD~1...HEAD"])

  def test_run_git_diff_parses_nul_terminated_names(self) -> None:
    completed = gate.subprocess.CompletedProcess(
      args=["git", "diff", "--name-only", "-z", "HEAD"],
      returncode=0,
      stdout="docs/name,with-comma.md\0qixi-ios-native/Qixi/RootView.swift\0",
      stderr="",
    )
    with mock.patch.object(gate.subprocess, "run", return_value=completed):
      parsed = gate.run_git_diff(["diff", "--name-only", "-z", "HEAD"])

    self.assertEqual(parsed, ["docs/name,with-comma.md", "qixi-ios-native/Qixi/RootView.swift"])

  def test_run_git_diff_rejects_backslashes_in_nul_terminated_names(self) -> None:
    completed = gate.subprocess.CompletedProcess(
      args=["git", "diff", "--name-only", "-z", "HEAD"],
      returncode=0,
      stdout="qixi-ios-native\\Qixi\\RootView.swift\0",
      stderr="",
    )
    with mock.patch.object(gate.subprocess, "run", return_value=completed):
      with self.assertRaisesRegex(gate.ChangedSurfaceGateError, "backslashes"):
        gate.run_git_diff(["diff", "--name-only", "-z", "HEAD"])

  def test_github_output_records_boolean_and_triggering_files(self) -> None:
    classification = gate.classify_changed_files([
      "qixi-ios-native/Qixi/LeftAnalysisPane.swift",
      "notes/ordinary-design-note.md",
    ])
    with tempfile.TemporaryDirectory() as temp_dir:
      output = pathlib.Path(temp_dir) / "github-output"
      gate.write_github_output(output, classification)
      text = output.read_text(encoding="utf-8")

    self.assertIn("requires_screenshots=true", text)
    self.assertIn("requires_real_models=false", text)
    self.assertIn("requires_ios_katago_cmake=false", text)
    self.assertIn("requires_native_release_sim=false", text)
    self.assertIn("requires_release_review=false", text)
    for output_name in (
      "screenshot_relevant_files",
      "real_model_relevant_files",
      "ios_katago_cmake_relevant_files",
      "native_release_sim_relevant_files",
      "release_sensitive_files",
    ):
      self.assertRegex(text, rf"{output_name}<<QIXI_{output_name.upper()}_[0-9a-f]{{64}}_0_EOF")
    self.assertIn("qixi-ios-native/Qixi/LeftAnalysisPane.swift", text)

  def test_github_output_uses_content_unique_delimiters(self) -> None:
    classification = gate.ChangedSurfaceClassification(
      changed_files=("QIXI_EOF",),
      screenshot_relevant_files=("QIXI_EOF",),
      real_model_relevant_files=("QIXI_EOF",),
      ios_katago_cmake_relevant_files=("QIXI_EOF",),
      native_release_sim_relevant_files=("QIXI_EOF",),
      release_sensitive_files=("QIXI_EOF",),
    )
    with tempfile.TemporaryDirectory() as temp_dir:
      output = pathlib.Path(temp_dir) / "github-output"
      gate.write_github_output(output, classification)
      text = output.read_text(encoding="utf-8")

    self.assertNotIn("<<QIXI_EOF\n", text)
    for output_name in (
      "screenshot_relevant_files",
      "real_model_relevant_files",
      "ios_katago_cmake_relevant_files",
      "native_release_sim_relevant_files",
      "release_sensitive_files",
    ):
      delimiter, values = self.multiline_header(text, output_name)
      self.assertNotEqual(delimiter, "QIXI_EOF")
      self.assertEqual(values, ["QIXI_EOF"])
      self.assertTrue(re.fullmatch(rf"QIXI_{output_name.upper()}_[0-9a-f]{{64}}_0_EOF", delimiter))

  def test_native_katago_changes_require_ios_cmake_gate(self) -> None:
    classification = gate.classify_changed_files([
      "qixi-ios-native/Qixi/QixiNativeKataGoEngine.cpp",
      "qixi-ios-native/Qixi/QixiNativeKataGoCore.hpp",
      "scripts/qixi-ios-katago-cmake-preflight.sh",
      "qixi-ios-native/tests/native_katago_adapter_compile_probe.cpp",
    ])

    self.assertTrue(classification.requires_real_models)
    self.assertTrue(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertEqual(
      classification.ios_katago_cmake_relevant_files,
      (
        "qixi-ios-native/Qixi/QixiNativeKataGoEngine.cpp",
        "qixi-ios-native/Qixi/QixiNativeKataGoCore.hpp",
        "scripts/qixi-ios-katago-cmake-preflight.sh",
        "qixi-ios-native/tests/native_katago_adapter_compile_probe.cpp",
      ),
    )
    self.assertEqual(
      classification.native_release_sim_relevant_files,
      (
        "qixi-ios-native/Qixi/QixiNativeKataGoEngine.cpp",
        "qixi-ios-native/Qixi/QixiNativeKataGoCore.hpp",
        "scripts/qixi-ios-katago-cmake-preflight.sh",
      ),
    )

  def test_native_hpp_and_bridging_header_require_native_build_gates(self) -> None:
    classification = gate.classify_changed_files([
      "qixi-ios-native/Qixi/QixiNativeKataGoCore.hpp",
      "qixi-ios-native/Qixi/Qixi-Bridging-Header.h",
    ])

    self.assertFalse(classification.requires_screenshots)
    self.assertTrue(classification.requires_real_models)
    self.assertTrue(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.real_model_relevant_files,
      (
        "qixi-ios-native/Qixi/QixiNativeKataGoCore.hpp",
        "qixi-ios-native/Qixi/Qixi-Bridging-Header.h",
      ),
    )
    self.assertEqual(
      classification.ios_katago_cmake_relevant_files,
      (
        "qixi-ios-native/Qixi/QixiNativeKataGoCore.hpp",
        "qixi-ios-native/Qixi/Qixi-Bridging-Header.h",
      ),
    )
    self.assertEqual(
      classification.native_release_sim_relevant_files,
      (
        "qixi-ios-native/Qixi/QixiNativeKataGoCore.hpp",
        "qixi-ios-native/Qixi/Qixi-Bridging-Header.h",
      ),
    )
    self.assertEqual(
      classification.release_sensitive_files,
      (
        "qixi-ios-native/Qixi/QixiNativeKataGoCore.hpp",
        "qixi-ios-native/Qixi/Qixi-Bridging-Header.h",
      ),
    )

  def test_native_release_sim_smoke_is_real_model_ios_cmake_and_release_sensitive(self) -> None:
    classification = gate.classify_changed_files([
      "qixi-ios-native/scripts/native-release-sim-smoke.sh",
      "scripts/qixi-native-release-build-preflight.sh",
      "scripts/qixi-quality-gate.sh",
    ])

    self.assertFalse(classification.requires_screenshots)
    self.assertTrue(classification.requires_real_models)
    self.assertTrue(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.real_model_relevant_files,
      (
        "qixi-ios-native/scripts/native-release-sim-smoke.sh",
        "scripts/qixi-native-release-build-preflight.sh",
      ),
    )
    self.assertEqual(
      classification.ios_katago_cmake_relevant_files,
      (
        "qixi-ios-native/scripts/native-release-sim-smoke.sh",
        "scripts/qixi-native-release-build-preflight.sh",
      ),
    )
    self.assertEqual(
      classification.release_sensitive_files,
      (
        "qixi-ios-native/scripts/native-release-sim-smoke.sh",
        "scripts/qixi-native-release-build-preflight.sh",
        "scripts/qixi-quality-gate.sh",
      ),
    )
    self.assertEqual(
      classification.native_release_sim_relevant_files,
      (
        "qixi-ios-native/scripts/native-release-sim-smoke.sh",
        "scripts/qixi-native-release-build-preflight.sh",
        "scripts/qixi-quality-gate.sh",
      ),
    )

  def test_xcode_project_change_requires_native_release_sim_and_release_review(self) -> None:
    classification = gate.classify_changed_files([
      "qixi-ios-native/Qixi.xcodeproj/project.pbxproj",
    ])

    self.assertTrue(classification.requires_screenshots)
    self.assertFalse(classification.requires_real_models)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.native_release_sim_relevant_files,
      ("qixi-ios-native/Qixi.xcodeproj/project.pbxproj",),
    )
    self.assertEqual(
      classification.release_sensitive_files,
      ("qixi-ios-native/Qixi.xcodeproj/project.pbxproj",),
    )

  def test_native_runtime_and_evidence_export_changes_are_release_sensitive(self) -> None:
    classification = gate.classify_changed_files([
      "qixi-ios-native/Qixi/QixiRealDeviceEvidence.swift",
      "qixi-ios-native/Qixi/QixiViewModel.swift",
      "qixi-ios-native/Qixi/QixiNativeKataGoEngine.mm",
      "qixi-ios-native/Qixi/QixiNativeModelRegistry.swift",
    ])

    self.assertTrue(classification.requires_screenshots)
    self.assertTrue(classification.requires_real_models)
    self.assertTrue(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.native_release_sim_relevant_files,
      (
        "qixi-ios-native/Qixi/QixiRealDeviceEvidence.swift",
        "qixi-ios-native/Qixi/QixiViewModel.swift",
        "qixi-ios-native/Qixi/QixiNativeKataGoEngine.mm",
        "qixi-ios-native/Qixi/QixiNativeModelRegistry.swift",
      ),
    )
    self.assertEqual(
      classification.release_sensitive_files,
      (
        "qixi-ios-native/Qixi/QixiRealDeviceEvidence.swift",
        "qixi-ios-native/Qixi/QixiViewModel.swift",
        "qixi-ios-native/Qixi/QixiNativeKataGoEngine.mm",
        "qixi-ios-native/Qixi/QixiNativeModelRegistry.swift",
      ),
    )

  def test_lifecycle_persistence_sync_and_identity_changes_are_release_sensitive(self) -> None:
    classification = gate.classify_changed_files([
      "qixi-ios-native/Qixi/QixiApp.swift",
      "qixi-ios-native/Qixi/QixiPersistence.swift",
      "qixi-ios-native/Qixi/QixiPositionIdentity.swift",
      "qixi-ios-native/Qixi/QixiSync.swift",
    ])

    self.assertTrue(classification.requires_screenshots)
    self.assertTrue(classification.requires_real_models)
    self.assertFalse(classification.requires_ios_katago_cmake)
    self.assertTrue(classification.requires_native_release_sim)
    self.assertTrue(classification.requires_release_review)
    self.assertEqual(
      classification.real_model_relevant_files,
      ("qixi-ios-native/Qixi/QixiPositionIdentity.swift",),
    )
    self.assertEqual(
      classification.native_release_sim_relevant_files,
      (
        "qixi-ios-native/Qixi/QixiApp.swift",
        "qixi-ios-native/Qixi/QixiPersistence.swift",
        "qixi-ios-native/Qixi/QixiPositionIdentity.swift",
        "qixi-ios-native/Qixi/QixiSync.swift",
      ),
    )
    self.assertEqual(
      classification.release_sensitive_files,
      (
        "qixi-ios-native/Qixi/QixiApp.swift",
        "qixi-ios-native/Qixi/QixiPersistence.swift",
        "qixi-ios-native/Qixi/QixiPositionIdentity.swift",
        "qixi-ios-native/Qixi/QixiSync.swift",
      ),
    )


if __name__ == "__main__":
  unittest.main()
