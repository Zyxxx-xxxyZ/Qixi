#!/usr/bin/env python3
from __future__ import annotations

import itertools
import pathlib
import re
import tempfile
import unittest

from screenshot_manifest_json import (
  ScreenshotManifestJSONError,
  load_manifest_json,
  manifest_placeholders,
  validate_manifest_environment,
  validate_manifest_relative_path,
  validate_manifest_structure,
)


ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parent
MANIFEST = ROOT / "tests" / "screenshot_coverage_manifest.json"


def read(path: pathlib.Path) -> str:
  return path.read_text(encoding="utf-8")


def load_manifest() -> dict:
  return load_manifest_json(MANIFEST)


def placeholders(template: str) -> set[str]:
  return manifest_placeholders(template)


def render(template: str, values: dict[str, str]) -> str:
  return template.format(**values)


def dimension_rows(dimensions: dict[str, list[str]]) -> list[dict[str, str]]:
  names = list(dimensions)
  return [
    dict(zip(names, values, strict=True))
    for values in itertools.product(*(dimensions[name] for name in names))
  ]


class ScreenshotCoverageManifestTests(unittest.TestCase):
  def setUp(self) -> None:
    self.manifest = load_manifest()

  def test_manifest_expands_to_unique_required_frontend_states(self) -> None:
    self.assertEqual(self.manifest["version"], 1)
    languages = self.manifest["languages"]
    self.assertEqual(languages, ["zh-Hans", "zh-Hant", "en"])
    matrix_by_id = {matrix["id"]: matrix for matrix in self.manifest["matrices"]}
    self.assertIn("ipad-engine-selection", matrix_by_id)
    self.assertNotIn("ipad-model-install-sheet", matrix_by_id)
    self.assertIn("ipad-engine-error", matrix_by_id)
    self.assertIn("ipad-real-device-evidence-negative", matrix_by_id)
    self.assertIn("ipad-real-device-evidence-negative-legacy", matrix_by_id)
    self.assertIn("ipad-persistence-smoke", matrix_by_id)
    self.assertIn("ipad-performance-smoke", matrix_by_id)
    self.assertIn("iphone-onboarding", matrix_by_id)
    self.assertIn("iphone-engine-selection", matrix_by_id)
    self.assertIn("iphone-engine-error", matrix_by_id)
    self.assertIn("iphone-board-recognition-preview", matrix_by_id)
    self.assertIn("iphone-board-overlays", matrix_by_id)
    self.assertIn("iphone-board-capture-replay", matrix_by_id)
    self.assertIn("iphone-utility-sheet", matrix_by_id)
    self.assertNotIn("iphone-model-install-sheet", matrix_by_id)
    self.assertIn("iphone-sync-sheet-synced", matrix_by_id)
    self.assertIn("iphone-sync-sheet-attention", matrix_by_id)
    self.assertIn("ipad-sync-sheet-synced", matrix_by_id)
    self.assertIn("ipad-sync-sheet-attention", matrix_by_id)
    self.assertEqual(
      matrix_by_id["ipad-engine-selection"]["dimensions"]["engine"],
      ["b6", "b18nbt", "b28nbt"],
    )
    self.assertEqual(
      matrix_by_id["ipad-engine-selection"]["environment"]["QIXI_AUTOMATION_SELECT_ENGINE"],
      "{engine}",
    )
    self.assertIsNone(matrix_by_id["ipad-utility-sheet"].get("inspectorArguments"))
    self.assertEqual(
      matrix_by_id["ipad-engine-error"]["dimensions"]["engineError"],
      ["library-not-linked", "model-missing", "insufficient-memory", "local-network-denied"],
    )
    self.assertEqual(
      matrix_by_id["ipad-engine-error"]["environment"]["QIXI_ENGINE_ERROR"],
      "{engineError}",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative"]["environment"]["QIXI_ANALYSIS_FIXTURE"],
      "real-device-evidence",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative"]["environment"]["QIXI_ANALYSIS_RUNTIME"],
      "nativeInProcess",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative"]["environment"]["QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_ANALYSIS"],
      "1",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative"]["environment"]["QIXI_DEVICE_BACKEND_URL"],
      "http://192.168.1.23:8765",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative"]["environment"]["QIXI_BACKEND_URL"],
      "",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative"]["environment"]["QIXI_REAL_DEVICE_RUN_ID"],
      "00000000-0000-4000-8000-000000000001",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative-legacy"]["screenshot"],
      "artifacts/screenshots/latest-ipad-real-device-evidence-negative-legacy.png",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative-legacy"]["environment"]["QIXI_ANALYSIS_RUNTIME"],
      "nativeInProcess",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative-legacy"]["environment"]["QIXI_ANALYSIS_FIXTURE"],
      "real-device-evidence",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative-legacy"]["environment"]["QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_ANALYSIS"],
      "1",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative-legacy"]["environment"]["QIXI_DEVICE_BACKEND_URL"],
      "",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative-legacy"]["environment"]["QIXI_BACKEND_URL"],
      "http://192.168.1.23:8765",
    )
    self.assertEqual(
      matrix_by_id["ipad-real-device-evidence-negative-legacy"]["environment"]["QIXI_REAL_DEVICE_RUN_ID"],
      "00000000-0000-4000-8000-000000000002",
    )
    self.assertEqual(
      matrix_by_id["ipad-persistence-smoke"]["screenshot"],
      "artifacts/screenshots/latest-ipad-persistence.png",
    )
    self.assertEqual(
      matrix_by_id["ipad-persistence-smoke"]["environment"]["QIXI_ANALYSIS_RUNTIME"],
      "nativeInProcess",
    )
    self.assertEqual(
      matrix_by_id["ipad-performance-smoke"]["screenshot"],
      "artifacts/screenshots/latest-ipad-performance.png",
    )
    self.assertEqual(
      matrix_by_id["ipad-performance-smoke"]["environment"]["QIXI_SKIP_ONBOARDING"],
      "1",
    )
    self.assertEqual(
      matrix_by_id["iphone-engine-selection"]["dimensions"]["engine"],
      ["b6", "b18nbt", "b28nbt"],
    )
    self.assertEqual(
      matrix_by_id["iphone-engine-selection"]["environment"]["QIXI_AUTOMATION_SELECT_ENGINE"],
      "{engine}",
    )
    self.assertEqual(
      matrix_by_id["iphone-engine-error"]["dimensions"]["engineError"],
      ["library-not-linked", "model-missing", "insufficient-memory", "local-network-denied"],
    )
    self.assertEqual(
      matrix_by_id["iphone-engine-error"]["environment"]["QIXI_ENGINE_ERROR"],
      "{engineError}",
    )
    self.assertEqual(
      matrix_by_id["iphone-onboarding"]["environment"]["QIXI_SKIP_ONBOARDING"],
      "0",
    )
    self.assertEqual(
      matrix_by_id["iphone-engine-error"]["environment"]["QIXI_SCREENSHOT_AUTO_ROTATE"],
      "1",
    )
    self.assertEqual(
      matrix_by_id["iphone-board-recognition-preview"]["environment"]["QIXI_ANALYSIS_FIXTURE"],
      "board-recognition-preview",
    )
    self.assertEqual(
      matrix_by_id["iphone-board-recognition-preview"]["environment"]["QIXI_SCREENSHOT_AUTO_ROTATE"],
      "1",
    )
    self.assertEqual(
      matrix_by_id["iphone-board-overlays"]["environment"]["QIXI_ANALYSIS_FIXTURE"],
      "board-overlays",
    )
    self.assertEqual(
      matrix_by_id["iphone-board-overlays"]["environment"]["QIXI_SHOW_TERRITORY"],
      "1",
    )
    self.assertEqual(
      matrix_by_id["iphone-board-capture-replay"]["environment"]["QIXI_ANALYSIS_FIXTURE"],
      "board-capture-replay",
    )
    self.assertIsNone(matrix_by_id["iphone-utility-sheet"].get("inspectorArguments"))
    self.assertEqual(
      matrix_by_id["iphone-sync-sheet-synced"]["environment"]["QIXI_SYNC_STATUS"],
      "synced",
    )
    self.assertEqual(matrix_by_id["iphone-sync-sheet-disabled"]["inspectorArguments"], ["disabled"])
    self.assertEqual(matrix_by_id["iphone-sync-sheet-enabled"]["inspectorArguments"], ["enabled"])
    self.assertEqual(
      matrix_by_id["iphone-sync-sheet-attention"]["dimensions"]["syncStatus"],
      ["error", "conflict"],
    )
    self.assertEqual(
      matrix_by_id["ipad-sync-sheet-synced"]["environment"]["QIXI_SYNC_STATUS"],
      "synced",
    )
    self.assertEqual(matrix_by_id["ipad-sync-sheet-disabled"]["inspectorArguments"], ["disabled"])
    self.assertEqual(matrix_by_id["ipad-sync-sheet-enabled"]["inspectorArguments"], ["enabled"])
    self.assertEqual(
      matrix_by_id["ipad-sync-sheet-attention"]["dimensions"]["syncStatus"],
      ["error", "conflict"],
    )
    self.assertEqual(
      matrix_by_id["ipad-sync-sheet-attention"]["environment"]["QIXI_SYNC_STATUS"],
      "{syncStatus}",
    )

    states: list[tuple[str, str]] = []
    for matrix in self.manifest["matrices"]:
      dimensions = matrix["dimensions"]
      environment = matrix["environment"]
      if "language" in dimensions:
        self.assertEqual(dimensions["language"], languages, matrix["id"])
      self.assertIsInstance(environment, dict, matrix["id"])
      for key, value in environment.items():
        self.assertIsInstance(key, str, matrix["id"])
        self.assertTrue(key.startswith("QIXI_"), matrix["id"])
        self.assertIsInstance(value, str, matrix["id"])
        self.assertLessEqual(placeholders(value), set(dimensions), matrix["id"])
      template_names = placeholders(matrix["screenshot"])
      for row in dimension_rows(dimensions):
        self.assertEqual(template_names, template_names & row.keys(), matrix["id"])
        screenshot = render(matrix["screenshot"], row)
        state_id = "-".join([matrix["id"], *[row[name] for name in dimensions]])
        states.append((state_id, screenshot))

    self.assertEqual(len(states), self.manifest["requiredStateCount"])
    self.assertEqual(len({state for state, _ in states}), len(states))
    self.assertEqual(len({screenshot for _, screenshot in states}), len(states))

    for _, screenshot in states:
      path = pathlib.PurePosixPath(screenshot)
      self.assertEqual(path.parts[:2], ("artifacts", "screenshots"))
      self.assertEqual(path.suffix, ".png")

  def test_declared_scripts_and_inspectors_exist_and_are_part_of_the_gate(self) -> None:
    quality_gate = read(REPO / "scripts" / "qixi-quality-gate.sh")
    artifact_inspector = read(ROOT / "tests" / "inspect_screenshot_manifest_artifacts.py")
    manifest_json = read(ROOT / "tests" / "screenshot_manifest_json.py")
    review_board = read(ROOT / "scripts" / "build_screenshot_review_board.py")
    review_board_inspector = read(ROOT / "tests" / "inspect_screenshot_review_board.py")
    helper_scripts = {
      "scripts/screenshot-sim.sh",
      "scripts/screenshot-iphone-sim.sh",
      "scripts/screenshot-onboarding-sim.sh",
      "scripts/screenshot-iphone-onboarding-sim.sh",
    }
    top_level_scripts = {
      script_name
      for matrix in self.manifest["matrices"]
      for script_name in matrix["scripts"]
      if script_name not in helper_scripts
    }
    full_matrix_start = quality_gate.index('if [[ "${QIXI_RUN_SCREENSHOTS:-0}" == "1" ]]; then')
    full_matrix_else = quality_gate.index("else", full_matrix_start)
    full_matrix_gate = quality_gate[full_matrix_start:full_matrix_else]
    quality_gate_scripts = set(re.findall(r"qixi-ios-native/(scripts/[A-Za-z0-9_.-]+\.sh)", full_matrix_gate))

    self.assertIn("inspect_screenshot_manifest_artifacts.py", quality_gate)
    self.assertIn("test_utility_sheet_screenshot_inspector.py", quality_gate)
    self.assertIn("build_screenshot_review_board.py", quality_gate)
    self.assertIn("inspect_screenshot_review_board.py", quality_gate)
    self.assertEqual(quality_gate_scripts, top_level_scripts)
    self.assertIn("scripts/screenshot-board-recognition-preview.sh", top_level_scripts)
    self.assertIn("Screenshot manifest artifact inspection passed", artifact_inspector)
    self.assertIn("requiredStateCount", artifact_inspector)
    self.assertIn("expanded_states(manifest)", artifact_inspector)
    self.assertIn("subprocess.run(command", artifact_inspector)
    self.assertIn("missing screenshot artifact", artifact_inspector)
    self.assertIn("inspect_declared_scripts", artifact_inspector)
    self.assertIn("inspect_declared_inspector", artifact_inspector)
    self.assertIn("inspect_declared_environment", artifact_inspector)
    self.assertIn("validate_manifest_environment", artifact_inspector)
    self.assertIn("validate_manifest_environment", manifest_json)
    self.assertIn("validate_manifest_relative_path", manifest_json)
    self.assertIn("validate_manifest_structure", manifest_json)
    self.assertIn("validate_manifest_structure", artifact_inspector)
    self.assertIn("MAX_SCREENSHOT_MANIFEST_BYTES", manifest_json)
    self.assertIn("must not be a symbolic link", manifest_json)
    self.assertIn("must be a regular file", manifest_json)
    self.assertIn("screenshot coverage manifest is empty", manifest_json)
    self.assertIn("screenshot coverage manifest exceeds", manifest_json)
    self.assertIn("screenshot coverage manifest must be UTF-8", manifest_json)
    self.assertIn("os.fstat(handle.fileno())", manifest_json)
    self.assertIn("stat_module.S_ISREG", manifest_json)
    self.assertIn("after opening", manifest_json)
    self.assertIn("environment variables must begin with QIXI_", manifest_json)
    self.assertIn("environment references unknown dimensions", manifest_json)
    self.assertIn("environment value for", manifest_json)
    self.assertIn("declared_screenshot_path", artifact_inspector)
    self.assertIn("must be a non-empty list", artifact_inspector)
    self.assertIn("missing screenshot script", artifact_inspector)
    self.assertIn("screenshot script is not executable", artifact_inspector)
    self.assertIn("screenshot artifact must not be a symbolic link", artifact_inspector)
    self.assertIn("inspect_png_header", artifact_inspector)
    self.assertIn("inspect_png_decodes", artifact_inspector)
    self.assertIn("PNG_HEADER_BYTES", artifact_inspector)
    self.assertIn("SCREENSHOT_ARTIFACT_MAX_BYTES", artifact_inspector)
    self.assertIn("SCREENSHOT_MAX_PIXELS", artifact_inspector)
    self.assertIn("os.fstat(handle.fileno())", artifact_inspector)
    self.assertIn("stat_module.S_ISREG", artifact_inspector)
    self.assertIn("handle.read(SCREENSHOT_ARTIFACT_MAX_BYTES + 1)", artifact_inspector)
    self.assertIn("opened-byte-count drift while reading", artifact_inspector)
    self.assertIn("Image.open(io.BytesIO(image_data))", artifact_inspector)
    self.assertIn("screenshot artifact must be a PNG file", artifact_inspector)
    self.assertIn("screenshot artifact must have a valid PNG IHDR", artifact_inspector)
    self.assertIn("screenshot artifact must be a decodable PNG image", artifact_inspector)
    self.assertIn("decoded dimensions do not match PNG IHDR", artifact_inspector)
    self.assertIn("too large for bounded visual inspection", artifact_inspector)
    self.assertIn("inspector must not be a symbolic link", artifact_inspector)
    self.assertIn("required_prefix", artifact_inspector)
    self.assertIn("required_suffix", artifact_inspector)
    self.assertIn("raw_path.split(\"/\")", manifest_json)
    self.assertIn("must not contain empty, current-directory, or parent-directory components", manifest_json)
    self.assertIn("QIXI_SCREENSHOT_MANIFEST_MIN_MTIME_EPOCH", quality_gate)
    self.assertIn("QIXI_SCREENSHOT_MANIFEST_MIN_MTIME_EPOCH", artifact_inspector)
    self.assertIn("stale screenshot artifact", artifact_inspector)
    self.assertIn("inspect_engine_error_variants_are_distinct(states)", artifact_inspector)
    self.assertIn("inspect_sheet_variants_are_distinct(states)", artifact_inspector)
    self.assertIn("inspect_variant_group_is_distinct", artifact_inspector)
    self.assertIn("UTILITY_SHEET_RE", artifact_inspector)
    self.assertNotIn("MODEL_INSTALL_RE", artifact_inspector)
    self.assertIn("SYNC_SHEET_RE", artifact_inspector)
    self.assertIn("visual_difference_score", artifact_inspector)
    self.assertIn("changedPixels", artifact_inspector)
    self.assertIn("requiredStateCount", review_board)
    self.assertIn("validate_manifest_environment", review_board)
    self.assertIn("validate_manifest_relative_path", review_board)
    self.assertIn("validate_manifest_structure", review_board)
    self.assertIn("require_complete_artifacts", review_board)
    self.assertIn('isoformat(timespec="microseconds")', review_board)
    self.assertIn("ScreenshotMetadata", review_board)
    self.assertIn("ScreenshotEvidence", review_board)
    self.assertIn("inspect_png_header", review_board)
    self.assertIn("inspect_png_decodes", review_board)
    self.assertIn("PNG_HEADER_BYTES", review_board)
    self.assertIn("SCREENSHOT_ARTIFACT_MAX_BYTES", review_board)
    self.assertIn("SCREENSHOT_MAX_PIXELS", review_board)
    self.assertIn("handle.read(SCREENSHOT_ARTIFACT_MAX_BYTES + 1)", review_board)
    self.assertIn("opened-byte-count drift while reading", review_board)
    self.assertIn("Image.open(io.BytesIO(image_data))", review_board)
    self.assertIn("Image.open(io.BytesIO(evidence.image_data))", review_board)
    self.assertIn("hashlib.sha256(image_data).hexdigest()", review_board)
    self.assertIn("hashlib.sha256(page_data).hexdigest()", review_board)
    self.assertIn("screenshot artifact must be a PNG file", review_board)
    self.assertIn("screenshot artifact must be a decodable PNG image", review_board)
    self.assertIn("decoded dimensions do not match PNG IHDR", review_board)
    self.assertIn("latest-screenshot-review-board.html", review_board)
    self.assertIn("latest-screenshot-review-board.json", review_board)
    self.assertIn("sha256HexDigest", review_board)
    self.assertIn("manifestSha256HexDigest", review_board)
    self.assertIn("MAX_SCREENSHOT_MANIFEST_BYTES", review_board)
    self.assertIn("opened_regular_file_stat", review_board)
    self.assertIn("os.fstat(handle.fileno())", review_board)
    self.assertIn("stat_module.S_ISREG", review_board)
    self.assertIn("reject_symlink_components", review_board)
    self.assertIn("opened-byte-count drift while hashing", review_board)
    self.assertIn("byte count drift after opening", review_board)
    self.assertIn("MAX_REVIEW_JSON_BYTES", review_board)
    self.assertIn("MAX_REVIEW_HTML_BYTES", review_board)
    self.assertIn("write_atomic_artifact", review_board)
    self.assertIn("write_atomic_text", review_board)
    self.assertIn("expected_byte_count", review_board)
    self.assertIn("byte count drift after writing", review_board)
    self.assertIn("os.O_EXCL", review_board)
    self.assertIn("os.O_NOFOLLOW", review_board)
    self.assertIn("os.fsync(handle.fileno())", review_board)
    self.assertIn("os.replace", review_board)
    self.assertIn("fsync_parent_directory", review_board)
    self.assertIn("os.fsync(parent_fd)", review_board)
    self.assertIn("could not fsync parent directory after atomic replace", review_board)
    self.assertIn("atomic-write temporary file", review_board)
    self.assertIn("target must not be a symbolic link", review_board)
    self.assertIn("cleanup_review_board_artifacts", review_board)
    self.assertIn("directory-shaped review-board artifact", review_board)
    self.assertIn("symbolic link", review_board)
    self.assertNotIn("Image.open(handle)", review_board)
    self.assertIn("load_strict_json_object", review_board_inspector)
    self.assertIn("MAX_REVIEW_HTML_BYTES", review_board_inspector)
    self.assertIn("read_bounded_utf8", review_board_inspector)
    self.assertIn("opened_regular_file_stat", review_board_inspector)
    self.assertIn("os.fstat(handle.fileno())", review_board_inspector)
    self.assertIn("stat_module.S_ISREG", review_board_inspector)
    self.assertIn("handle.read(max_bytes + 1)", review_board_inspector)
    self.assertIn("review-board {label} is empty", review_board_inspector)
    self.assertIn("review-board {label} exceeds", review_board_inspector)
    self.assertIn("opened-byte-count drift while reading", review_board_inspector)
    self.assertIn("opened-byte-count drift while hashing", review_board_inspector)
    self.assertNotIn('path.read_text(encoding="utf-8")', review_board_inspector)
    self.assertIn("inspect_generated_at", review_board_inspector)
    self.assertIn("REVIEW_BOARD_GENERATED_AT_MAX_FUTURE_SKEW_SECONDS", review_board_inspector)
    self.assertIn("too far in the future", review_board_inspector)
    self.assertIn("generatedAt must be a UTC ISO-8601 timestamp ending in Z", review_board_inspector)
    self.assertIn("stale review-board generatedAt", review_board_inspector)
    self.assertIn("inspect_png_header", review_board_inspector)
    self.assertIn("inspect_png_decodes", review_board_inspector)
    self.assertIn("inspect_png_artifact", review_board_inspector)
    self.assertIn("PNG_HEADER_BYTES", review_board_inspector)
    self.assertIn("REVIEW_BOARD_IMAGE_MAX_BYTES", review_board_inspector)
    self.assertIn("REVIEW_BOARD_IMAGE_MAX_PIXELS", review_board_inspector)
    self.assertIn("handle.read(REVIEW_BOARD_IMAGE_MAX_BYTES + 1)", review_board_inspector)
    self.assertIn("Image.open(io.BytesIO(image_data))", review_board_inspector)
    self.assertIn("hashlib.sha256(image_data).hexdigest()", review_board_inspector)
    self.assertIn("must be a decodable PNG image", review_board_inspector)
    self.assertIn("decoded dimensions do not match PNG IHDR", review_board_inspector)
    self.assertIn("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH", review_board_inspector)
    self.assertIn("stale review-board", review_board_inspector)
    self.assertIn("MIN_PAGE_STDDEV", review_board_inspector)
    self.assertIn("review-board page state counts must sum to stateCount", review_board_inspector)
    self.assertIn("safe_posix_parts", review_board_inspector)
    self.assertIn("must not contain empty, current-directory, or parent-directory components", review_board_inspector)
    self.assertIn("require_relative_screenshot_path", review_board_inspector)
    self.assertIn("expected_states_from_manifest", review_board_inspector)
    self.assertIn("validate_manifest_environment", review_board_inspector)
    self.assertIn("validate_manifest_relative_path", review_board_inspector)
    self.assertIn("validate_manifest_structure", review_board_inspector)
    self.assertIn("state order or id drift", review_board_inspector)
    self.assertIn("screenshot path drift", review_board_inspector)
    self.assertIn("review-board byte count drift", review_board_inspector)
    self.assertIn("require_sha256_hex_digest", review_board_inspector)
    self.assertIn("manifest digest drift", review_board_inspector)
    self.assertIn("require_real_directory", review_board_inspector)
    self.assertIn("require_real_file", review_board_inspector)
    self.assertIn("symbolic link", review_board_inspector)
    self.assertIn("page digest drift", review_board_inspector)
    self.assertIn("source digest drift", review_board_inspector)
    self.assertIn("unreferenced page images", review_board_inspector)
    self.assertIn("unexpected artifacts", review_board_inspector)

    for matrix in self.manifest["matrices"]:
      inspector = ROOT / matrix["inspector"]
      self.assertTrue(inspector.exists(), matrix["inspector"])
      self.assertIn("passed", read(inspector), matrix["inspector"])

      matrix_gate_scripts = set(matrix["scripts"]) - helper_scripts
      self.assertTrue(matrix_gate_scripts, matrix["id"])
      for script_name in matrix["scripts"]:
        script = ROOT / script_name
        self.assertTrue(script.exists(), script_name)
        self.assertTrue(script.stat().st_mode & 0o111, script_name)
      for script_name in matrix_gate_scripts:
        self.assertIn(script_name, quality_gate_scripts, matrix["id"])

    for script_name in top_level_scripts:
      self.assertIn(f"qixi-ios-native/{script_name}", quality_gate)

    manifest_inspector_index = quality_gate.index("qixi-ios-native/tests/inspect_screenshot_manifest_artifacts.py")
    review_board_marker_index = quality_gate.index("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH")
    review_board_index = quality_gate.index("qixi-ios-native/scripts/build_screenshot_review_board.py")
    review_board_inspector_index = quality_gate.index("qixi-ios-native/tests/inspect_screenshot_review_board.py")
    self.assertLess(manifest_inspector_index, review_board_marker_index)
    self.assertLess(review_board_marker_index, review_board_index)
    self.assertLess(manifest_inspector_index, review_board_index)
    self.assertLess(review_board_index, review_board_inspector_index)
    for script_name in top_level_scripts:
      self.assertLess(
        quality_gate.index(f"qixi-ios-native/{script_name}"),
        manifest_inspector_index,
        script_name,
      )

  def test_script_contracts_match_declared_environment_controls(self) -> None:
    for matrix in self.manifest["matrices"]:
      script_text = "\n".join(read(ROOT / script_name) for script_name in matrix["scripts"])
      self.assertIn(pathlib.PurePosixPath(matrix["inspector"]).name, script_text, matrix["id"])

      for key, value in matrix["environment"].items():
        self.assertIn(key, script_text, f"{matrix['id']} missing {key}")
        if "{" not in value:
          self.assertIn(value, script_text, f"{matrix['id']} missing {key}={value}")

      for name, values in matrix["dimensions"].items():
        if name == "language":
          for language in values:
            self.assertIn(language, script_text, matrix["id"])
        else:
          for value in values:
            self.assertIn(value, script_text, matrix["id"])

  def test_manifest_is_documented_for_human_reviewers(self) -> None:
    readme = read(ROOT / "README.md")
    docs = read(REPO / "docs" / "quality-gates.md")
    required_count = str(self.manifest["requiredStateCount"])
    for text in (readme, docs):
      self.assertIn("screenshot_coverage_manifest.json", text)
      self.assertIn(required_count, text)
      self.assertIn("inspect_screenshot_manifest_artifacts.py", text)
      self.assertIn("review-board", text)
      self.assertIn("latest-screenshot-review-board", text)
      self.assertIn("engine error", text)
      self.assertIn("model install", text)
      self.assertIn("iCloud sync", text)
      self.assertIn("persistence", text)
      self.assertIn("performance", text)
      self.assertIn("in-tree executable regular file", text)
    self.assertIn("stale artifacts cannot mask a state that stopped being captured", docs)
    self.assertNotIn("required 120", docs)
    self.assertNotIn("containing 120", docs)

  def test_manifest_json_loader_rejects_ambiguous_or_non_standard_json(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      path = pathlib.Path(raw_dir) / "manifest.json"
      path.write_text('{"version":1,"version":1,"matrices":[]}\n', encoding="utf-8")
      with self.assertRaisesRegex(ScreenshotManifestJSONError, "duplicate JSON key 'version'"):
        load_manifest_json(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      path = pathlib.Path(raw_dir) / "manifest.json"
      path.write_text('{"version":1,"requiredStateCount":NaN,"matrices":[]}\n', encoding="utf-8")
      with self.assertRaisesRegex(ScreenshotManifestJSONError, "non-standard JSON constant NaN"):
        load_manifest_json(path)

  def test_manifest_json_loader_rejects_unsafe_or_oversized_manifest_files(self) -> None:
    import screenshot_manifest_json

    with tempfile.TemporaryDirectory() as raw_dir:
      path = pathlib.Path(raw_dir) / "empty.json"
      path.write_text("", encoding="utf-8")
      with self.assertRaisesRegex(ScreenshotManifestJSONError, "manifest is empty"):
        load_manifest_json(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      path = pathlib.Path(raw_dir) / "manifest-directory.json"
      path.mkdir()
      with self.assertRaisesRegex(ScreenshotManifestJSONError, "must be a regular file"):
        load_manifest_json(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      path = pathlib.Path(raw_dir) / "oversized.json"
      with path.open("wb") as handle:
        handle.truncate(screenshot_manifest_json.MAX_SCREENSHOT_MANIFEST_BYTES + 1)
      with self.assertRaisesRegex(ScreenshotManifestJSONError, "manifest exceeds"):
        load_manifest_json(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      path = pathlib.Path(raw_dir) / "non-utf8.json"
      path.write_bytes(b"\xff\xfe\x00")
      with self.assertRaisesRegex(ScreenshotManifestJSONError, "must be UTF-8"):
        load_manifest_json(path)

    with tempfile.TemporaryDirectory() as raw_dir:
      target = pathlib.Path(raw_dir) / "target.json"
      link = pathlib.Path(raw_dir) / "linked.json"
      target.write_text('{"version":1,"languages":["en"],"requiredStateCount":1,"matrices":[]}\n', encoding="utf-8")
      try:
        link.symlink_to(target)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")
      with self.assertRaisesRegex(ScreenshotManifestJSONError, "must not be a symbolic link"):
        load_manifest_json(link)

  def test_shared_manifest_environment_validator_rejects_unsafe_controls(self) -> None:
    validate_manifest_environment(
      "ok",
      {"QIXI_APP_LANGUAGE": "{language}", "QIXI_SKIP_ONBOARDING": "1"},
      known_dimensions={"language"},
    )
    with self.assertRaisesRegex(ScreenshotManifestJSONError, "environment references unknown dimensions"):
      validate_manifest_environment("bad", {"QIXI_APP_LANGUAGE": "{locale}"}, known_dimensions={"language"})
    with self.assertRaisesRegex(ScreenshotManifestJSONError, "environment variables must begin with QIXI_"):
      validate_manifest_environment("bad", {"PATH": "{language}"}, known_dimensions={"language"})
    with self.assertRaisesRegex(ScreenshotManifestJSONError, "environment value for QIXI_APP_LANGUAGE must be a string"):
      validate_manifest_environment("bad", {"QIXI_APP_LANGUAGE": 1}, known_dimensions={"language"})

  def test_shared_manifest_relative_path_validator_rejects_unsafe_paths(self) -> None:
    path = validate_manifest_relative_path(
      "artifacts/screenshots/latest-ipad-en.png",
      matrix_id="ok",
      field="screenshot",
      required_prefix=("artifacts", "screenshots"),
      required_suffix=".png",
    )
    self.assertEqual(path.as_posix(), "artifacts/screenshots/latest-ipad-en.png")
    for unsafe in (
      "/tmp/latest-ipad-en.png",
      "../latest-ipad-en.png",
      "artifacts/screenshots//latest-ipad-en.png",
      "artifacts/screenshots/./latest-ipad-en.png",
      "artifacts/latest-ipad-en.png",
      "artifacts/screenshots/latest-ipad-en.jpg",
    ):
      with self.subTest(unsafe=unsafe):
        with self.assertRaises(ScreenshotManifestJSONError):
          validate_manifest_relative_path(
            unsafe,
            matrix_id="bad",
            field="screenshot",
            required_prefix=("artifacts", "screenshots"),
            required_suffix=".png",
          )

  def test_shared_manifest_structure_validator_rejects_empty_or_ambiguous_matrices(self) -> None:
    valid_matrix = {
      "id": "tiny-main",
      "description": "Tiny state.",
      "scripts": ["scripts/screenshot-sim.sh"],
      "inspector": "tests/inspect_screenshot.py",
      "dimensions": {"language": ["en"]},
      "screenshot": "artifacts/screenshots/tiny-{language}.png",
      "environment": {"QIXI_APP_LANGUAGE": "{language}"},
    }
    validate_manifest_structure(
      {
        "version": 1,
        "languages": ["en"],
        "requiredStateCount": 1,
        "matrices": [valid_matrix],
      }
    )
    cases = (
      (
        {
          "version": 1,
          "languages": ["en"],
          "requiredStateCount": 0,
          "matrices": [],
        },
        "requiredStateCount must be a positive integer",
      ),
      (
        {
          "version": 1,
          "languages": ["en"],
          "requiredStateCount": 1,
          "matrices": [],
        },
        "matrices must be a non-empty list",
      ),
      (
        {
          "version": 1,
          "languages": ["en"],
          "requiredStateCount": 2,
          "matrices": [valid_matrix, dict(valid_matrix)],
        },
        "matrix id must be unique",
      ),
      (
        {
          "version": 1,
          "languages": ["en"],
          "requiredStateCount": 1,
          "matrices": [
            {
              **valid_matrix,
              "dimensions": {"language": ["en/../../outside"]},
            }
          ],
        },
        "unsafe value",
      ),
    )
    for manifest, message in cases:
      with self.subTest(message=message):
        with self.assertRaisesRegex(ScreenshotManifestJSONError, message):
          validate_manifest_structure(manifest)


if __name__ == "__main__":
  unittest.main()
