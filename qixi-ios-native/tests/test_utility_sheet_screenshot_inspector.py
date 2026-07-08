#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

from PIL import Image, ImageDraw


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSPECTOR_PATH = ROOT / "tests" / "inspect_utility_sheet_screenshot.py"


def load_inspector():
  spec = importlib.util.spec_from_file_location("inspect_utility_sheet_screenshot", INSPECTOR_PATH)
  assert spec is not None and spec.loader is not None
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  return module


class UtilitySheetScreenshotInspectorTests(unittest.TestCase):
  def setUp(self) -> None:
    self.module = load_inspector()
    self.tempdir = tempfile.TemporaryDirectory()
    self.addCleanup(self.tempdir.cleanup)
    self.root = pathlib.Path(self.tempdir.name)

  def write_screenshot(
    self,
    *,
    icon_color: tuple[int, int, int] | None = None,
    icon_position: str = "regular",
    action_color: tuple[int, int, int] = (28, 31, 36),
    size: tuple[int, int] = (2064, 1548),
    warning: bool = False,
  ) -> pathlib.Path:
    width, height = size
    image = Image.new("RGB", (width, height), (248, 248, 248))
    draw = ImageDraw.Draw(image)

    # Readable foreground and action-region contrast expected by the inspector.
    for index in range(14):
      x0 = width // 5 + index * 82
      draw.rectangle((x0, height // 3, x0 + 46, height // 3 + 18), fill=(28, 31, 36))
      draw.rectangle((x0, height * 2 // 3, x0 + 54, height * 2 // 3 + 20), fill=action_color)
      draw.rectangle((x0, height * 3 // 4, x0 + 54, height * 3 // 4 + 20), fill=(28, 31, 36))

    if icon_position == "compact":
      icon_rect = (
        int(width * 0.475),
        int(height * 0.33),
        int(width * 0.525),
        int(height * 0.44),
      )
    else:
      icon_rect = (
        int(width * 0.455),
        int(height * 0.59),
        int(width * 0.545),
        int(height * 0.655),
      )
    if icon_color is not None:
      draw.rectangle(icon_rect, fill=icon_color)

    if warning:
      draw.rectangle(
        (width // 2 - 30, height // 3 - 10, width // 2 + 30, height // 3 + 50),
        fill=(210, 40, 38),
      )

    path = self.root / "utility-sheet.png"
    image.save(path)
    return path

  def run_main(self, path: pathlib.Path, expected_state: str = "") -> int:
    argv = ["inspect_utility_sheet_screenshot.py", str(path)]
    if expected_state:
      argv.append(expected_state)
    with mock.patch.object(sys, "argv", argv):
      with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return self.module.main()

  def test_accepts_distinct_sync_states(self) -> None:
    cases = [
      ("", None, False),
      ("disabled", None, False),
      ("enabled", (55, 105, 245), False),
      ("synced", (55, 105, 245), False),
      ("error", (55, 105, 245), True),
      ("conflict", (55, 105, 245), True),
    ]
    for expected_state, icon_color, warning in cases:
      with self.subTest(expected_state=expected_state or "generic"):
        self.assertEqual(self.run_main(self.write_screenshot(icon_color=icon_color, warning=warning), expected_state), 0)

  def test_compact_landscape_iphone_sync_icon_detection_ignores_blue_action_area(self) -> None:
    compact_size = (2868, 1320)
    self.assertEqual(
      self.run_main(
        self.write_screenshot(
          icon_color=(140, 140, 140),
          icon_position="compact",
          action_color=(55, 105, 245),
          size=compact_size,
        ),
        "disabled",
      ),
      0,
    )
    self.assertEqual(
      self.run_main(
        self.write_screenshot(
          icon_color=(55, 105, 245),
          icon_position="compact",
          size=compact_size,
        ),
        "enabled",
      ),
      0,
    )

  def test_rejects_sync_states_without_the_required_icon_or_warning(self) -> None:
    with self.assertRaisesRegex(AssertionError, "enabled sync sheet lacks the enabled blue iCloud icon"):
      self.run_main(self.write_screenshot(), "enabled")
    with self.assertRaisesRegex(AssertionError, "disabled sync sheet must not reuse the enabled blue iCloud icon"):
      self.run_main(self.write_screenshot(icon_color=(55, 105, 245)), "disabled")
    with self.assertRaisesRegex(AssertionError, "error sync sheet warning treatment is not detectable"):
      self.run_main(self.write_screenshot(icon_color=(55, 105, 245)), "error")
    with self.assertRaisesRegex(AssertionError, "synced sync sheet must not look like an error state"):
      self.run_main(self.write_screenshot(icon_color=(55, 105, 245), warning=True), "synced")

if __name__ == "__main__":
  unittest.main()
