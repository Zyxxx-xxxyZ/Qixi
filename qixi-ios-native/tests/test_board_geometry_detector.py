#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
GEOMETRY = ROOT / "tests" / "inspect_board_geometry_screenshot.py"

spec = importlib.util.spec_from_file_location("inspect_board_geometry_screenshot", GEOMETRY)
assert spec is not None and spec.loader is not None
geometry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(geometry)


class BoardGeometryDetectorTests(unittest.TestCase):
  def test_fit_grid_axis_requires_all_nineteen_lines(self) -> None:
    clusters = [(100.0 + index * 24.0, 800) for index in range(19)]
    origin, step, matches = geometry.fit_grid_axis(clusters, 18.0, 30.0, "synthetic")
    self.assertEqual(matches, 19)
    self.assertAlmostEqual(origin, 100.0, delta=0.05)
    self.assertAlmostEqual(step, 24.0, delta=0.05)

  def test_fit_grid_axis_rejects_missing_line_even_when_eighteen_lines_are_regular(self) -> None:
    clusters = [(100.0 + index * 24.0, 800) for index in range(19) if index != 11]
    with self.assertRaisesRegex(AssertionError, "too few synthetic grid-line clusters|could not fit all 19"):
      geometry.fit_grid_axis(clusters, 18.0, 30.0, "synthetic")

  def test_fit_grid_axis_ignores_unrelated_noise_clusters(self) -> None:
    clusters = [(-40.0, 1200), (12.0, 600)]
    clusters += [(100.0 + index * 24.0 + (0.18 if index % 2 else -0.12), 800) for index in range(19)]
    clusters += [(640.0, 900), (700.0, 500)]
    origin, step, matches = geometry.fit_grid_axis(clusters, 18.0, 30.0, "synthetic")
    self.assertEqual(matches, 19)
    self.assertAlmostEqual(origin, 99.9, delta=0.35)
    self.assertAlmostEqual(step, 24.0, delta=0.05)


if __name__ == "__main__":
  unittest.main()
