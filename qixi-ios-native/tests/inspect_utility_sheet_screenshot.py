#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

from PIL import Image, ImageChops, ImageStat


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SCREENSHOT = ROOT / "artifacts" / "screenshots" / "latest-ipad-camera-sheet-zh-Hans.png"


def dark_pixel_count(image: Image.Image, threshold: int = 96) -> int:
  red, green, blue = image.convert("RGB").split()
  masks = [channel.point(lambda value: 255 if value < threshold else 0) for channel in (red, green, blue)]
  combined = ImageChops.multiply(ImageChops.multiply(masks[0], masks[1]), masks[2])
  return combined.histogram()[255]


def variance(image: Image.Image) -> float:
  return sum(ImageStat.Stat(image.convert("RGB")).stddev)


def warning_red_pixel_count(image: Image.Image) -> int:
  red, green, blue = image.convert("RGB").split()
  red_mask = red.point(lambda value: 255 if value > 135 else 0)
  green_mask = green.point(lambda value: 255 if value < 110 else 0)
  blue_mask = blue.point(lambda value: 255 if value < 130 else 0)
  combined = ImageChops.multiply(ImageChops.multiply(red_mask, green_mask), blue_mask)
  return combined.histogram()[255]


def icon_band(image: Image.Image) -> Image.Image:
  width, height = image.size
  return image.crop((
    int(width * 0.42),
    int(height * 0.56),
    int(width * 0.58),
    int(height * 0.69),
  ))


def compact_icon_band(image: Image.Image) -> Image.Image:
  width, height = image.size
  return image.crop((
    int(width * 0.38),
    int(height * 0.25),
    int(width * 0.62),
    int(height * 0.50),
  ))


def status_icon_band(image: Image.Image) -> Image.Image:
  width, height = image.size
  if width / height > 1.7:
    return compact_icon_band(image)
  return icon_band(image)


def sync_icon_blue_pixel_count(image: Image.Image) -> int:
  red, green, blue = status_icon_band(image).convert("RGB").split()
  blue_mask = blue.point(lambda value: 255 if value > 150 else 0)
  red_mask = red.point(lambda value: 255 if value < 110 else 0)
  green_mask = green.point(lambda value: 255 if value > 80 else 0)
  combined = ImageChops.multiply(ImageChops.multiply(blue_mask, red_mask), green_mask)
  return combined.histogram()[255]


def main() -> int:
  path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SCREENSHOT
  expected_state = sys.argv[2] if len(sys.argv) > 2 else ""
  image = Image.open(path).convert("RGB")
  width, height = image.size
  assert width > height, f"expected landscape utility sheet screenshot, got {width}x{height}"

  center = image.crop((width // 5, height // 5, width * 4 // 5, height * 4 // 5))
  lower = image.crop((width // 6, height // 2, width * 5 // 6, height))
  assert variance(center) > 16.0, "utility sheet center region looks flat or missing"
  assert dark_pixel_count(center, threshold=128) > 1500, "utility sheet has too little readable foreground"
  assert dark_pixel_count(lower, threshold=128) > 1200, "utility sheet action area is not detectable"
  if expected_state in {"enabled", "synced", "error", "conflict"}:
    assert sync_icon_blue_pixel_count(image) > 800, f"{expected_state} sync sheet lacks the enabled blue iCloud icon"
  if expected_state == "disabled":
    assert sync_icon_blue_pixel_count(image) < 200, "disabled sync sheet must not reuse the enabled blue iCloud icon"
  if expected_state in {"error", "conflict"}:
    assert warning_red_pixel_count(center) > 80, f"{expected_state} sync sheet warning treatment is not detectable"
  if expected_state == "synced":
    assert warning_red_pixel_count(center) < 80, "synced sync sheet must not look like an error state"

  suffix = f" [{expected_state}]" if expected_state else ""
  print(f"Utility sheet screenshot inspection passed{suffix}: {path} ({width}x{height})")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
