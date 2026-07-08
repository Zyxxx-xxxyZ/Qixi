#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

from PIL import Image, ImageChops, ImageStat


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SCREENSHOT = ROOT / "artifacts" / "screenshots" / "latest-ipad-onboarding.png"


def dark_pixel_count(image: Image.Image, threshold: int = 96) -> int:
  red, green, blue = image.convert("RGB").split()
  masks = [channel.point(lambda value: 255 if value < threshold else 0) for channel in (red, green, blue)]
  combined = ImageChops.multiply(ImageChops.multiply(masks[0], masks[1]), masks[2])
  return combined.histogram()[255]


def variance(image: Image.Image) -> float:
  stat = ImageStat.Stat(image.convert("RGB"))
  return sum(stat.stddev)


def main() -> int:
  path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SCREENSHOT
  image = Image.open(path).convert("RGB")
  width, height = image.size
  assert width > height, f"expected landscape onboarding screenshot, got {width}x{height}"

  edge_samples = []
  for x in range(width):
    edge_samples.append(image.getpixel((x, 0)))
    edge_samples.append(image.getpixel((x, height - 1)))
  black_edges = sum(1 for pixel in edge_samples if max(pixel) < 8)
  assert black_edges / max(1, len(edge_samples)) < 0.02, "onboarding screenshot still has letterbox bars"

  center = image.crop((width // 4, height // 4, width * 3 // 4, height * 3 // 4))
  assert dark_pixel_count(center) > 3000, "onboarding center panel has too little readable foreground"
  assert variance(center) > 18.0, "onboarding center panel looks flat or missing"

  lower = center.crop((0, center.height * 2 // 3, center.width, center.height))
  assert dark_pixel_count(lower, threshold=144) > 900, "onboarding action row is not detectable"

  print(f"Onboarding screenshot inspection passed: {path} ({width}x{height})")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
