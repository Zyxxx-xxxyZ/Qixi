#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

from PIL import Image

from inspect_board_geometry_screenshot import detect_grid, luma, stone_centroid


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SCREENSHOT = ROOT / "artifacts" / "screenshots" / "latest-ipad-board-capture-replay-zh-Hans.png"
BLACK_STONES = [(8, 9), (10, 9), (9, 8), (9, 10)]
CAPTURED_WHITE = (9, 9)


def intersection(grid_x0: float, grid_y0: float, step_x: float, step_y: float, x: int, y: int) -> tuple[float, float]:
  return grid_x0 + x * step_x, grid_y0 + y * step_y


def white_stone_pixel_count(image: Image.Image, center_x: float, center_y: float, radius: float) -> int:
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
      if luma((red, green, blue)) > 190 and max(red, green, blue) - min(red, green, blue) < 25:
        count += 1
  return count


def exposed_grid_pixel_count(image: Image.Image, center_x: float, center_y: float, radius: float) -> int:
  pixels = image.load()
  count = 0
  min_x = max(0, int(center_x - radius))
  max_x = min(image.width - 1, int(center_x + radius) + 1)
  min_y = max(0, int(center_y - radius))
  max_y = min(image.height - 1, int(center_y + radius) + 1)
  for y in range(min_y, max_y + 1):
    for x in range(min_x, max_x + 1):
      in_cross = abs(x - center_x) <= 1.5 or abs(y - center_y) <= 1.5
      if not in_cross:
        continue
      red, green, blue = pixels[x, y]
      if max(red, green, blue) < 80:
        count += 1
  return count


def main() -> int:
  path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SCREENSHOT
  image = Image.open(path).convert("RGB")
  width, height = image.size
  assert width > height, f"expected landscape capture-replay screenshot, got {width}x{height}"

  grid_x0, grid_y0, step_x, step_y, _, _ = detect_grid(image)
  step = min(step_x, step_y)
  radius = step * 0.43
  empty_radius = step * 0.34
  max_empty_white_pixels = max(20, int(empty_radius * empty_radius * 0.04))
  min_exposed_grid_pixels = max(45, int(empty_radius * empty_radius * 0.08))

  black_counts = []
  for x, y in BLACK_STONES:
    center_x, center_y = intersection(grid_x0, grid_y0, step_x, step_y, x, y)
    _, _, count = stone_centroid(image, "B", center_x, center_y, radius)
    black_counts.append(count)

  captured_x, captured_y = intersection(grid_x0, grid_y0, step_x, step_y, *CAPTURED_WHITE)
  captured_white_pixels = white_stone_pixel_count(image, captured_x, captured_y, empty_radius)
  captured_grid_pixels = exposed_grid_pixel_count(image, captured_x, captured_y, empty_radius)
  assert captured_white_pixels <= max_empty_white_pixels, (
    "captured white stone is still visibly rendered at "
    f"{CAPTURED_WHITE}: {captured_white_pixels} > {max_empty_white_pixels}"
  )
  assert captured_grid_pixels >= min_exposed_grid_pixels, (
    "captured intersection does not expose enough grid pixels at "
    f"{CAPTURED_WHITE}: {captured_grid_pixels} < {min_exposed_grid_pixels}"
  )

  print(
    f"Board capture replay inspection passed: {path} "
    f"(black pixels={black_counts}, captured white pixels={captured_white_pixels}, "
    f"captured grid pixels={captured_grid_pixels})"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
