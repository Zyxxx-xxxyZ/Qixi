#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

from PIL import Image

from inspect_board_geometry_screenshot import detect_grid, luma


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SCREENSHOT = ROOT / "artifacts" / "screenshots" / "latest-ipad-board-overlays-zh-Hans.png"


GREEN_CANDIDATE_POINTS = [(10, 10), (16, 10)]
YELLOW_CANDIDATE_POINTS = [(4, 7), (13, 13)]
WHITE_TERRITORY_POINTS = [(2, 5), (5, 5), (16, 16)]
BLACK_TERRITORY_POINTS = [(16, 5), (5, 16), (10, 2)]


def intersection(grid_x0: float, grid_y0: float, step_x: float, step_y: float, x: int, y: int) -> tuple[float, float]:
  return grid_x0 + x * step_x, grid_y0 + y * step_y


def count_candidate_pixels(image: Image.Image, center_x: float, center_y: float, radius: float, tone: str) -> int:
  pixels = image.load()
  count = 0
  min_x = max(0, int(center_x - radius))
  max_x = min(image.width - 1, int(center_x + radius) + 1)
  min_y = max(0, int(center_y - radius))
  max_y = min(image.height - 1, int(center_y + radius) + 1)
  radius_squared = radius * radius
  for y in range(min_y, max_y + 1):
    for x in range(min_x, max_x + 1):
      dx = x - center_x
      dy = y - center_y
      if dx * dx + dy * dy > radius_squared:
        continue
      red, green, blue = pixels[x, y]
      if tone == "green":
        selected = green > 105 and green > red * 1.08 and green > blue * 1.20
      else:
        selected = red > 150 and green > 125 and blue < 170 and max(red, green, blue) - min(red, green, blue) > 45
      if selected:
        count += 1
  return count


def patch_luma(image: Image.Image, center_x: float, center_y: float, half_side: int) -> float:
  pixels = image.load()
  samples = []
  for y in range(max(0, int(center_y) - half_side), min(image.height - 1, int(center_y) + half_side) + 1):
    for x in range(max(0, int(center_x) - half_side), min(image.width - 1, int(center_x) + half_side) + 1):
      samples.append(luma(pixels[x, y]))
  assert samples, "empty patch"
  return sum(samples) / len(samples)


def territory_marker_luma(
  image: Image.Image,
  grid_x0: float,
  grid_y0: float,
  step_x: float,
  step_y: float,
  x: int,
  y: int,
  tone: str,
) -> float:
  center_x, center_y = intersection(grid_x0, grid_y0, step_x, step_y, x, y)
  step = min(step_x, step_y)
  square = step / 6.0
  offset = square * (0.45 if tone == "white" else 0.20)
  return patch_luma(image, center_x + offset, center_y + offset, 1)


def main() -> int:
  path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SCREENSHOT
  image = Image.open(path).convert("RGB")
  width, height = image.size
  assert width > height, f"expected landscape board overlay screenshot, got {width}x{height}"

  grid_x0, grid_y0, step_x, step_y, _, _ = detect_grid(image)
  step = min(step_x, step_y)
  candidate_radius = step * 0.62
  minimum_candidate_pixels = max(90, int(candidate_radius * candidate_radius * 0.10))

  for point in GREEN_CANDIDATE_POINTS:
    center_x, center_y = intersection(grid_x0, grid_y0, step_x, step_y, *point)
    count = count_candidate_pixels(image, center_x, center_y, candidate_radius, "green")
    assert count >= minimum_candidate_pixels, f"green candidate {point} is not visible enough: {count}"

  for point in YELLOW_CANDIDATE_POINTS:
    center_x, center_y = intersection(grid_x0, grid_y0, step_x, step_y, *point)
    count = count_candidate_pixels(image, center_x, center_y, candidate_radius, "yellow")
    assert count >= minimum_candidate_pixels, f"yellow candidate {point} is not visible enough: {count}"

  white_lumas = [
    territory_marker_luma(image, grid_x0, grid_y0, step_x, step_y, x, y, "white")
    for x, y in WHITE_TERRITORY_POINTS
  ]
  black_lumas = [
    territory_marker_luma(image, grid_x0, grid_y0, step_x, step_y, x, y, "black")
    for x, y in BLACK_TERRITORY_POINTS
  ]
  assert min(white_lumas) > 230.0, f"white territory markers are too faint: {white_lumas}"
  assert max(black_lumas) < 70.0, f"black territory markers are too faint: {black_lumas}"

  print(
    f"Board overlay inspection passed: {path} "
    f"(white luma={white_lumas}, black luma={black_lumas})"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
