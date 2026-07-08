#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

from PIL import Image, ImageChops


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SCREENSHOT = ROOT / "artifacts" / "screenshots" / "latest-ipad-engine-error-library-not-linked-en.png"


def dark_pixel_count(image: Image.Image, threshold: int = 110) -> int:
  red, green, blue = image.convert("RGB").split()
  masks = [channel.point(lambda value: 255 if value < threshold else 0) for channel in (red, green, blue)]
  combined = ImageChops.multiply(ImageChops.multiply(masks[0], masks[1]), masks[2])
  return combined.histogram()[255]


def warning_red_pixel_count(image: Image.Image) -> int:
  red, green, blue = image.convert("RGB").split()
  red_mask = red.point(lambda value: 255 if value > 135 else 0)
  green_mask = green.point(lambda value: 255 if value < 120 else 0)
  blue_mask = blue.point(lambda value: 255 if value < 140 else 0)
  combined = ImageChops.multiply(ImageChops.multiply(red_mask, green_mask), blue_mask)
  return combined.histogram()[255]


def main() -> int:
  path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SCREENSHOT
  expected = sys.argv[2] if len(sys.argv) > 2 else "engine-error"
  image = Image.open(path).convert("RGB")
  width, height = image.size
  assert width > height, f"expected landscape engine-error screenshot, got {width}x{height}"

  right_top = image.crop((width * 5 // 8, 0, width, height // 5))
  assert warning_red_pixel_count(right_top) > 70, f"{expected} engine warning is not visibly red enough"
  assert dark_pixel_count(right_top) > 450, f"{expected} engine warning has too little readable foreground"

  print(f"Engine error screenshot inspection passed: {path} ({expected}, {width}x{height})")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
