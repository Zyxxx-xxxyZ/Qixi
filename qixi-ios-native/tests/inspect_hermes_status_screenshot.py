#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

from PIL import Image


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SCREENSHOT = ROOT / "artifacts" / "screenshots" / "latest-ipad-hermes-ready-zh-Hans.png"


def status_pixel_counts(image: Image.Image) -> dict[str, int]:
  width, height = image.size
  badge_region = image.crop((width * 70 // 100, 0, width - 4, height * 11 // 100))
  badge_pixels = badge_region.convert("RGB").load()
  counts = {"ready": 0, "loading": 0, "offline": 0}
  for y in range(badge_region.height):
    for x in range(badge_region.width):
      red, green, blue = badge_pixels[x, y]
      if blue > 165 and red < 95 and green < 140:
        counts["ready"] += 1
      if red > 190 and green > 95 and green < 190 and blue < 80:
        counts["loading"] += 1
      if red > 145 and red < 235 and green < 95 and blue < 130:
        counts["offline"] += 1
  return counts


def main() -> int:
  path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SCREENSHOT
  expected = sys.argv[2] if len(sys.argv) > 2 else "ready"
  if expected not in {"ready", "loading", "offline"}:
    raise AssertionError(f"unsupported Hermes status: {expected}")

  image = Image.open(path).convert("RGB")
  width, height = image.size
  assert width > height, f"expected landscape Hermes screenshot, got {width}x{height}"

  counts = status_pixel_counts(image)
  minimum = 34 if expected == "loading" else 44
  assert counts[expected] >= minimum, (
    f"Hermes {expected} color is not visible enough in {path}: "
    f"counts={counts}, minimum={minimum}"
  )

  print(f"Hermes status inspection passed: {path} ({expected}, counts={counts})")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
