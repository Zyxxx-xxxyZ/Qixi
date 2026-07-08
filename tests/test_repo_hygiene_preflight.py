#!/usr/bin/env python3
from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "qixi-repo-hygiene-preflight.sh"

VALID_GITIGNORE = "\n".join((
  ".DS_Store",
  "__pycache__/",
  "*.pyc",
  ".pytest_cache/",
  ".mypy_cache/",
  ".ruff_cache/",
  ".coverage",
  "coverage.xml",
  "node_modules/",
  "npm-debug.log*",
  "yarn-debug.log*",
  "yarn-error.log*",
  "pnpm-debug.log*",
  "analysis_logs/",
  "qixi-ios-native/artifacts/",
  "qixi-ios-sim/artifacts/",
  "DerivedData/",
  "build/",
  "*.xcuserdata/",
  "*.xcuserstate",
  "*.xcresult",
  "*.xcarchive",
  "*.ipa",
  "*.dSYM/",
  "*.tmp",
  "*.moved-aside",
  "/*.bin",
  "/*.bin.gz",
  "/*.txt.gz",
  "/*.onnx",
  "/*.mlmodel",
  "/*.mlmodelc/",
  "/*.mlpackage/",
  "/Models/",
  "KataGo/cpp/build-*/",
  "KataGo/cpp/tests/results/",
)) + "\n"


def write_minimal_repo(root: pathlib.Path, gitignore: str = VALID_GITIGNORE) -> None:
  (root / ".gitignore").write_text(gitignore, encoding="utf-8")
  (root / "qixi-ios-native" / "tests").mkdir(parents=True)
  (root / "qixi-ios-native" / "artifacts").mkdir(parents=True)
  (root / "KataGo" / "cpp").mkdir(parents=True)


def run_hygiene(root: pathlib.Path, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
  env = os.environ.copy()
  env["QIXI_HYGIENE_ROOT"] = str(root)
  env["PYTHONDONTWRITEBYTECODE"] = "1"
  if extra_env:
    env.update(extra_env)
  return subprocess.run(
    [str(SCRIPT)],
    cwd=ROOT,
    text=True,
    capture_output=True,
    env=env,
    check=False,
  )


class RepoHygienePreflightTests(unittest.TestCase):
  def test_clean_non_git_root_passes_with_fallback_audit_message(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)

      result = run_hygiene(root)

      self.assertEqual(result.returncode, 0, result.stderr)
      self.assertIn("fallback source-path audit completed: not inside a git worktree", result.stderr)
      self.assertIn("Repository hygiene preflight passed", result.stdout)

  def test_non_git_strict_mode_fails_tracked_audit(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)

      result = run_hygiene(root, {"QIXI_REQUIRE_TRACKED_FILE_AUDIT": "1"})

      self.assertNotEqual(result.returncode, 0)
      self.assertIn("requires a git worktree", result.stderr)

  def test_source_pollution_fails_even_without_git(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)
      pycache = root / "qixi-ios-native" / "tests" / "__pycache__"
      pycache.mkdir()
      (pycache / "test.cpython-311.pyc").write_bytes(b"pyc")

      result = run_hygiene(root)

      self.assertNotEqual(result.returncode, 0)
      self.assertIn("Generated source-control pollution must be removed", result.stderr)
      self.assertIn("qixi-ios-native/tests/__pycache__", result.stderr)

  def test_recoverable_source_artifact_fails_even_without_git(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)
      docs = root / "docs"
      docs.mkdir()
      (docs / "release-notes.tmp").write_text("partial", encoding="utf-8")

      result = run_hygiene(root)

      self.assertNotEqual(result.returncode, 0)
      self.assertIn("Generated or recoverable artifacts must not live in non-ignored source paths", result.stderr)
      self.assertIn("docs/release-notes.tmp", result.stderr)

  def test_macos_finder_metadata_fails_in_source_paths_even_without_git(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)
      docs = root / "docs"
      docs.mkdir()
      (docs / ".DS_Store").write_text("finder metadata", encoding="utf-8")

      result = run_hygiene(root)

      self.assertNotEqual(result.returncode, 0)
      self.assertIn("Generated or recoverable artifacts must not live in non-ignored source paths", result.stderr)
      self.assertIn("docs/.DS_Store", result.stderr)

  def test_common_tool_caches_fail_in_source_paths_even_without_git(self) -> None:
    fixtures = (
      ("docs/.pytest_cache", True),
      ("docs/.mypy_cache", True),
      ("docs/.ruff_cache", True),
      ("docs/node_modules", True),
      ("docs/.coverage", False),
      ("docs/coverage.xml", False),
      ("docs/npm-debug.log", False),
      ("docs/yarn-debug.log", False),
      ("docs/yarn-error.log", False),
      ("docs/pnpm-debug.log", False),
    )
    for relative, is_directory in fixtures:
      with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temp_dir:
        root = pathlib.Path(temp_dir)
        write_minimal_repo(root)
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if is_directory:
          path.mkdir()
        else:
          path.write_text("cache", encoding="utf-8")

        result = run_hygiene(root)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Generated or recoverable artifacts must not live in non-ignored source paths", result.stderr)
        self.assertIn(relative, result.stderr)

  def test_local_model_artifacts_fail_in_source_paths_even_without_git(self) -> None:
    fixtures = (
      ("docs/local-b6.bin", False),
      ("docs/local-b6.bin.gz", False),
      ("docs/local-b6.txt.gz", False),
      ("docs/local-network.onnx", False),
      ("docs/local-network.mlmodel", False),
      ("docs/local-network.mlmodelc", True),
      ("docs/local-network.mlpackage", True),
    )
    for relative, is_directory in fixtures:
      with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temp_dir:
        root = pathlib.Path(temp_dir)
        write_minimal_repo(root)
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if is_directory:
          path.mkdir()
          (path / "metadata.json").write_text("{}", encoding="utf-8")
        else:
          path.write_text("model", encoding="utf-8")

        result = run_hygiene(root)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
          "Local model, CoreML, and ONNX artifacts must stay in ignored top-level model locations",
          result.stderr,
        )
        self.assertIn(relative, result.stderr)

  def test_top_level_local_model_artifacts_are_ignored_for_source_path_audit(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)
      for relative in ("b18nbt.bin", "b28nbt.bin", "b6.onnx", "b6.mlmodel"):
        (root / relative).write_text("local model", encoding="utf-8")
      for relative in ("b6.mlmodelc", "b6.mlpackage"):
        path = root / relative
        path.mkdir()
        (path / "metadata.json").write_text("{}", encoding="utf-8")
      managed = root / "Models" / "b6.bin.gz"
      managed.parent.mkdir()
      managed.write_text("installed model", encoding="utf-8")

      result = run_hygiene(root)

      self.assertEqual(result.returncode, 0, result.stderr)

  def test_katago_test_model_fixtures_are_allowed_for_source_path_audit(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)
      fixtures = root / "KataGo" / "cpp" / "tests" / "models"
      fixtures.mkdir(parents=True)
      (fixtures / "fixture.bin.gz").write_text("upstream test fixture", encoding="utf-8")
      (fixtures / "fixture.txt.gz").write_text("upstream test fixture", encoding="utf-8")

      result = run_hygiene(root)

      self.assertEqual(result.returncode, 0, result.stderr)

  def test_ignored_artifact_directories_do_not_count_as_source_pollution(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)
      (root / "qixi-ios-native" / "artifacts" / ".DS_Store").write_text("ignored", encoding="utf-8")
      (root / "qixi-ios-native" / "artifacts" / "__pycache__").mkdir()

      result = run_hygiene(root)

      self.assertEqual(result.returncode, 0, result.stderr)

  def test_missing_python_cache_ignore_pattern_fails(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root, VALID_GITIGNORE.replace("__pycache__/\n", ""))

      result = run_hygiene(root)

      self.assertNotEqual(result.returncode, 0)
      self.assertIn("Missing .gitignore pattern: __pycache__/", result.stderr)

  def test_tracked_generated_artifact_fails_inside_git_worktree(self) -> None:
    if shutil.which("git") is None:
      self.skipTest("git is required for tracked-file hygiene coverage")

    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)
      artifact = root / "qixi-ios-native" / "artifacts" / "latest-ipad.png"
      artifact.write_bytes(b"png")
      subprocess.run(["git", "init"], cwd=root, text=True, capture_output=True, check=True)
      subprocess.run(["git", "add", ".gitignore"], cwd=root, text=True, capture_output=True, check=True)
      subprocess.run(["git", "add", "-f", str(artifact.relative_to(root))], cwd=root, text=True, capture_output=True, check=True)

      result = run_hygiene(root)

      self.assertNotEqual(result.returncode, 0)
      self.assertIn("Generated or recoverable large artifacts must not be tracked", result.stderr)
      self.assertIn("qixi-ios-native/artifacts/latest-ipad.png", result.stderr)

  def test_tracked_nested_tool_cache_fails_inside_git_worktree(self) -> None:
    if shutil.which("git") is None:
      self.skipTest("git is required for tracked-file hygiene coverage")

    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)
      tracked_paths = [
        root / "docs" / "node_modules" / "leftpad" / "index.js",
        root / "docs" / ".pytest_cache" / "v" / "cache",
        root / "docs" / ".coverage",
        root / "docs" / "yarn-error.log",
      ]
      for path in tracked_paths:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("cache", encoding="utf-8")

      subprocess.run(["git", "init"], cwd=root, text=True, capture_output=True, check=True)
      subprocess.run(["git", "add", ".gitignore"], cwd=root, text=True, capture_output=True, check=True)
      subprocess.run(
        ["git", "add", "-f", *(str(path.relative_to(root)) for path in tracked_paths)],
        cwd=root,
        text=True,
        capture_output=True,
        check=True,
      )
      shutil.rmtree(root / "docs")

      result = run_hygiene(root)

      self.assertNotEqual(result.returncode, 0)
      self.assertIn("Generated or recoverable large artifacts must not be tracked", result.stderr)
      for expected in (
        "docs/node_modules/leftpad/index.js",
        "docs/.pytest_cache/v/cache",
        "docs/.coverage",
        "docs/yarn-error.log",
      ):
        self.assertIn(expected, result.stderr)

  def test_tracked_nested_xcode_artifacts_fail_inside_git_worktree(self) -> None:
    if shutil.which("git") is None:
      self.skipTest("git is required for tracked-file hygiene coverage")

    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)
      tracked_paths = [
        root / "docs" / "Qixi.xcarchive" / "Info.plist",
        root / "docs" / "Qixi.xcresult" / "Info.plist",
        root / "docs" / "Qixi.dSYM" / "Contents" / "Info.plist",
        root / "docs" / "Qixi.ipa",
      ]
      for path in tracked_paths:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("artifact", encoding="utf-8")

      subprocess.run(["git", "init"], cwd=root, text=True, capture_output=True, check=True)
      subprocess.run(["git", "add", ".gitignore"], cwd=root, text=True, capture_output=True, check=True)
      subprocess.run(
        ["git", "add", "-f", *(str(path.relative_to(root)) for path in tracked_paths)],
        cwd=root,
        text=True,
        capture_output=True,
        check=True,
      )
      shutil.rmtree(root / "docs")

      result = run_hygiene(root)

      self.assertNotEqual(result.returncode, 0)
      self.assertIn("Generated or recoverable large artifacts must not be tracked", result.stderr)
      for expected in (
        "docs/Qixi.xcarchive/Info.plist",
        "docs/Qixi.xcresult/Info.plist",
        "docs/Qixi.dSYM/Contents/Info.plist",
        "docs/Qixi.ipa",
      ):
        self.assertIn(expected, result.stderr)

  def test_tracked_nested_model_artifacts_fail_inside_git_worktree(self) -> None:
    if shutil.which("git") is None:
      self.skipTest("git is required for tracked-file hygiene coverage")

    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)
      tracked_paths = [
        root / "docs" / "local-b6.bin",
        root / "docs" / "local-b6.bin.gz",
        root / "docs" / "local-b6.txt.gz",
        root / "docs" / "network.onnx",
        root / "docs" / "network.mlmodel",
        root / "docs" / "network.mlmodelc" / "Info.plist",
        root / "docs" / "network.mlpackage" / "Manifest.json",
      ]
      for path in tracked_paths:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("model", encoding="utf-8")

      subprocess.run(["git", "init"], cwd=root, text=True, capture_output=True, check=True)
      subprocess.run(["git", "add", ".gitignore"], cwd=root, text=True, capture_output=True, check=True)
      subprocess.run(
        ["git", "add", "-f", *(str(path.relative_to(root)) for path in tracked_paths)],
        cwd=root,
        text=True,
        capture_output=True,
        check=True,
      )
      shutil.rmtree(root / "docs")

      result = run_hygiene(root)

      self.assertNotEqual(result.returncode, 0)
      self.assertIn("Generated or recoverable large artifacts must not be tracked", result.stderr)
      for expected in (
        "docs/local-b6.bin",
        "docs/local-b6.bin.gz",
        "docs/local-b6.txt.gz",
        "docs/network.onnx",
        "docs/network.mlmodel",
        "docs/network.mlmodelc/Info.plist",
        "docs/network.mlpackage/Manifest.json",
      ):
        self.assertIn(expected, result.stderr)

  def test_tracked_katago_test_model_fixtures_are_allowed_inside_git_worktree(self) -> None:
    if shutil.which("git") is None:
      self.skipTest("git is required for tracked-file hygiene coverage")

    with tempfile.TemporaryDirectory() as temp_dir:
      root = pathlib.Path(temp_dir)
      write_minimal_repo(root)
      tracked_paths = [
        root / "KataGo" / "cpp" / "tests" / "models" / "fixture.bin.gz",
        root / "KataGo" / "cpp" / "tests" / "models" / "fixture.txt.gz",
      ]
      for path in tracked_paths:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("upstream test fixture", encoding="utf-8")

      subprocess.run(["git", "init"], cwd=root, text=True, capture_output=True, check=True)
      subprocess.run(["git", "add", ".gitignore"], cwd=root, text=True, capture_output=True, check=True)
      subprocess.run(
        ["git", "add", "-f", *(str(path.relative_to(root)) for path in tracked_paths)],
        cwd=root,
        text=True,
        capture_output=True,
        check=True,
      )
      shutil.rmtree(root / "KataGo" / "cpp" / "tests" / "models")

      result = run_hygiene(root)

      self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
  unittest.main()
