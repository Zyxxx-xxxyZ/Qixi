#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "protected_build_marker.py"


class ProtectedBuildMarkerTests(unittest.TestCase):
  def run_helper(self, path: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
      ["python3", str(HELPER), str(path), "test build marker"],
      cwd=ROOT.parent,
      text=True,
      capture_output=True,
      check=False,
    )

  def test_writes_regular_marker_atomically(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      marker = pathlib.Path(tmpdir) / "build-marker"
      result = self.run_helper(marker)
      self.assertEqual(result.returncode, 0, result.stderr)
      self.assertEqual(marker.read_bytes(), b"qixi-build-marker\n")
      self.assertFalse(marker.is_symlink())
      self.assertFalse(list(pathlib.Path(tmpdir).glob(".build-marker.*.tmp")))

  def test_rejects_symlink_marker_without_writing_target(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      root = pathlib.Path(tmpdir)
      target = root / "target-marker"
      marker = root / "linked-marker"
      marker.symlink_to(target)
      result = self.run_helper(marker)
      self.assertNotEqual(result.returncode, 0)
      self.assertIn("symbolic links", result.stderr)
      self.assertFalse(target.exists())

  def test_rejects_symlink_parent_without_writing_through(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      root = pathlib.Path(tmpdir)
      real_parent = root / "real-parent"
      real_parent.mkdir()
      linked_parent = root / "linked-parent"
      linked_parent.symlink_to(real_parent, target_is_directory=True)
      result = self.run_helper(linked_parent / "build-marker")
      self.assertNotEqual(result.returncode, 0)
      self.assertIn("symbolic links", result.stderr)
      self.assertFalse((real_parent / "build-marker").exists())

  def test_allows_standard_tmp_alias_when_available(self) -> None:
    tmp_alias = pathlib.Path("/tmp")
    if not (tmp_alias.is_symlink() and tmp_alias.resolve(strict=True) == pathlib.Path("/private/tmp")):
      self.skipTest("/tmp is not the standard Darwin alias on this host")
    with tempfile.TemporaryDirectory(dir="/tmp") as tmpdir:
      marker = pathlib.Path(tmpdir) / "build-marker"
      result = self.run_helper(marker)
      self.assertEqual(result.returncode, 0, result.stderr)
      self.assertEqual(marker.read_bytes(), b"qixi-build-marker\n")

  def test_rejects_missing_parent(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      marker = pathlib.Path(tmpdir) / "missing" / "build-marker"
      result = self.run_helper(marker)
      self.assertNotEqual(result.returncode, 0)
      self.assertIn("parent does not exist", result.stderr)


if __name__ == "__main__":
  unittest.main()
