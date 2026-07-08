#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

from PIL import Image

from inspect_board_geometry_screenshot import detect_grid


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SCREENSHOT = ROOT / "artifacts" / "screenshots" / "latest-ipad-board-recognition-preview-zh-Hans.png"
PREVIEW_POINTS = [(3, 3), (15, 3), (10, 10), (16, 16)]


def intersection(grid_x0: float, grid_y0: float, step_x: float, step_y: float, x: int, y: int) -> tuple[float, float]:
  return grid_x0 + x * step_x, grid_y0 + y * step_y


def count_preview_blue_pixels(image: Image.Image, center_x: float, center_y: float, radius: float) -> int:
  pixels = image.load()
  count = 0
  min_x = max(0, int(center_x - radius))
  max_x = min(image.width - 1, int(center_x + radius) + 1)
  min_y = max(0, int(center_y - radius))
  max_y = min(image.height - 1, int(center_y + radius) + 1)
  outer_radius_sq = radius * radius
  inner_radius_sq = (radius * 0.70) * (radius * 0.70)
  for y in range(min_y, max_y + 1):
    for x in range(min_x, max_x + 1):
      dx = x - center_x
      dy = y - center_y
      distance_sq = dx * dx + dy * dy
      if distance_sq > outer_radius_sq or distance_sq < inner_radius_sq:
        continue
      red, green, blue = pixels[x, y]
      if blue > 170 and blue > red * 1.55 and blue > green * 1.20:
        count += 1
  return count


def main() -> int:
  path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SCREENSHOT
  image = Image.open(path).convert("RGB")
  width, height = image.size
  assert width > height, f"expected landscape recognition-preview screenshot, got {width}x{height}"

  grid_x0, grid_y0, step_x, step_y, _, _ = detect_grid(image)
  step = min(step_x, step_y)
  radius = step * 0.48
  minimum_blue_pixels = max(18, int(step * 0.34))
  counts = []
  for point in PREVIEW_POINTS:
    center_x, center_y = intersection(grid_x0, grid_y0, step_x, step_y, *point)
    count = count_preview_blue_pixels(image, center_x, center_y, radius)
    counts.append(count)
    assert count >= minimum_blue_pixels, (
      f"recognition preview ring at {point} is not visible enough: "
      f"{count} < {minimum_blue_pixels}"
    )

  print(f"Board recognition preview inspection passed: {path} (blue ring pixels={counts})")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
