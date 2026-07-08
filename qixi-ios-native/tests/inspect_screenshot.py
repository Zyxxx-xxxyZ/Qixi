#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

from PIL import Image, ImageChops, ImageStat

from inspect_board_geometry_screenshot import inspect_board_geometry


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SCREENSHOT = ROOT / "artifacts" / "screenshots" / "latest-ipad.png"


def dark_pixel_count(image: Image.Image, threshold: int = 72) -> int:
  red, green, blue = image.convert("RGB").split()
  masks = [channel.point(lambda value: 255 if value < threshold else 0) for channel in (red, green, blue)]
  combined = ImageChops.multiply(ImageChops.multiply(masks[0], masks[1]), masks[2])
  return combined.histogram()[255]


def non_background_variance(image: Image.Image) -> float:
  stat = ImageStat.Stat(image.convert("RGB"))
  return sum(stat.stddev)


def main() -> int:
  path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SCREENSHOT
  image = Image.open(path).convert("RGB")
  width, height = image.size
  assert width > height, f"expected landscape screenshot, got {width}x{height}"

  edge_samples = []
  for x in range(width):
    edge_samples.append(image.getpixel((x, 0)))
    edge_samples.append(image.getpixel((x, height - 1)))
  black_edges = sum(1 for pixel in edge_samples if max(pixel) < 8)
  assert black_edges / max(1, len(edge_samples)) < 0.02, "screenshot still has dominant letterbox bars"

  right = image.crop((width // 2, height // 8, width, height * 7 // 8))
  assert dark_pixel_count(right) > 9000, "right pane does not contain a visible board/grid"

  center_strip = image.crop((width // 2 - 2, 0, width // 2 + 3, height))
  assert non_background_variance(center_strip) > 1.0, "center divider is not detectable"

  full_variance = non_background_variance(image)
  assert full_variance > 24.0, f"screenshot looks too flat/blank: variance={full_variance:.2f}"

  inspect_board_geometry(path)

  print(f"Screenshot inspection passed: {path} ({width}x{height})")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
