#!/usr/bin/env python3
from __future__ import annotations

import math
import pathlib
import sys
from collections import Counter

from PIL import Image


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SCREENSHOT = ROOT / "artifacts" / "screenshots" / "latest-ipad.png"
GRID_SIZE = 19
SAMPLE_MOVES = [
  ("B", 3, 15),
  ("W", 15, 3),
  ("B", 15, 15),
  ("W", 3, 3),
  ("B", 9, 15),
  ("W", 9, 3),
  ("B", 6, 12),
  ("W", 12, 6),
]


def luma(pixel: tuple[int, int, int]) -> float:
  red, green, blue = pixel
  return red * 0.299 + green * 0.587 + blue * 0.114


def is_grid_pixel(pixel: tuple[int, int, int]) -> bool:
  red, green, blue = pixel
  value = luma(pixel)
  chroma = max(red, green, blue) - min(red, green, blue)
  return value < 120.0 and chroma < 90


def projection_clusters(counter: Counter[int], threshold: int) -> list[tuple[float, int]]:
  coordinates = sorted(key for key, value in counter.items() if value >= threshold)
  groups: list[list[int]] = []
  current: list[int] = []
  for coordinate in coordinates:
    if not current or coordinate <= current[-1] + 1:
      current.append(coordinate)
    else:
      groups.append(current)
      current = [coordinate]
  if current:
    groups.append(current)

  clusters: list[tuple[float, int]] = []
  for group in groups:
    total = sum(counter[coordinate] for coordinate in group)
    center = sum(coordinate * counter[coordinate] for coordinate in group) / total
    clusters.append((center, total))
  return clusters


def weighted_line_fit(points: list[tuple[int, float, int]]) -> tuple[float, float]:
  weight_sum = sum(weight for _, _, weight in points)
  mean_index = sum(index * weight for index, _, weight in points) / weight_sum
  mean_value = sum(value * weight for _, value, weight in points) / weight_sum
  numerator = sum(weight * (index - mean_index) * (value - mean_value) for index, value, weight in points)
  denominator = sum(weight * (index - mean_index) ** 2 for index, _, weight in points)
  assert denominator > 0.0, "degenerate grid fit"
  step = numerator / denominator
  origin = mean_value - step * mean_index
  return origin, step


def fit_grid_axis(clusters: list[tuple[float, int]], min_step: float, max_step: float, axis_name: str) -> tuple[float, float, int]:
  best: tuple[tuple[int, float, float, float], float, float] | None = None
  if len(clusters) < GRID_SIZE:
    raise AssertionError(f"too few {axis_name} grid-line clusters: {len(clusters)}")

  for first_cluster_index, (first, _) in enumerate(clusters):
    for last, _ in clusters[first_cluster_index + GRID_SIZE - 1:]:
      step = (last - first) / (GRID_SIZE - 1)
      if step < min_step or step > max_step:
        continue
      tolerance = max(2.0, step * 0.07)
      used_cluster_indices: set[int] = set()
      matched: list[tuple[int, float, int]] = []

      for grid_index in range(GRID_SIZE):
        expected = first + grid_index * step
        nearest: tuple[float, int, float, int] | None = None
        for cluster_index, (center, weight) in enumerate(clusters):
          if cluster_index in used_cluster_indices:
            continue
          error = abs(center - expected)
          if error <= tolerance and (nearest is None or error < nearest[0]):
            nearest = (error, cluster_index, center, weight)
        if nearest is None:
          break
        _, cluster_index, center, weight = nearest
        used_cluster_indices.add(cluster_index)
        matched.append((grid_index, center, weight))

      if len(matched) != GRID_SIZE:
        continue

      origin, refined_step = weighted_line_fit(matched)
      if refined_step < min_step or refined_step > max_step:
        continue
      errors = [abs(center - (origin + grid_index * refined_step)) for grid_index, center, _ in matched]
      max_error = max(errors)
      mean_error = sum(errors) / len(errors)
      if max_error > max(2.0, refined_step * 0.075):
        continue
      support = sum(weight for _, _, weight in matched)
      score = (support, -max_error, -mean_error, refined_step * (GRID_SIZE - 1))
      if best is None or score > best[0]:
        best = (score, origin, refined_step)

  if best is None:
    sample = ", ".join(f"{center:.1f}" for center, _ in clusters[:30])
    raise AssertionError(f"could not fit all 19 {axis_name} grid lines; clusters=[{sample}]")

  _, origin, step = best
  return origin, step, GRID_SIZE


def detect_grid(image: Image.Image) -> tuple[float, float, float, float, int, int]:
  width, height = image.size
  right_half_x = width // 2
  right = image.crop((right_half_x, 0, width, height))
  pixels = right.load()
  x_projection: Counter[int] = Counter()
  y_projection: Counter[int] = Counter()

  for y in range(right.height):
    for x in range(right.width):
      if is_grid_pixel(pixels[x, y]):
        x_projection[x] += 1
        y_projection[y] += 1

  threshold = max(80, int(min(width, height) * 0.14))
  x_clusters = projection_clusters(x_projection, threshold)
  y_clusters = projection_clusters(y_projection, threshold)
  min_step = min(width, height) * 0.018
  max_step = min(width, height) * 0.060
  local_x0, step_x, x_matches = fit_grid_axis(x_clusters, min_step, max_step, "vertical")
  y0, step_y, y_matches = fit_grid_axis(y_clusters, min_step, max_step, "horizontal")
  return right_half_x + local_x0, y0, step_x, step_y, x_matches, y_matches


def stone_centroid(
  image: Image.Image,
  color: str,
  center_x: float,
  center_y: float,
  radius: float,
) -> tuple[float, float, int]:
  pixels = image.load()
  points: list[tuple[int, int]] = []
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
      pixel = pixels[x, y]
      value = luma(pixel)
      red, green, blue = pixel
      if color == "B":
        selected = value < 95
      else:
        selected = value > 190 and min(red, green, blue) > 170
      if selected:
        points.append((x, y))

  min_points = max(80, int(radius * radius * 0.80))
  assert len(points) >= min_points, f"too few {color} stone pixels near ({center_x:.1f},{center_y:.1f}): {len(points)}"
  centroid_x = sum(x for x, _ in points) / len(points)
  centroid_y = sum(y for _, y in points) / len(points)
  return centroid_x, centroid_y, len(points)


def inspect_board_geometry(path: pathlib.Path) -> None:
  image = Image.open(path).convert("RGB")
  grid_x0, grid_y0, step_x, step_y, x_matches, y_matches = detect_grid(image)
  assert x_matches == GRID_SIZE and y_matches == GRID_SIZE, f"board grid must be 19x19, got {x_matches}x{y_matches}"
  step = min(step_x, step_y)
  assert abs(step_x - step_y) <= step * 0.04, f"board grid is not square: stepX={step_x:.2f}, stepY={step_y:.2f}"
  radius = step * 0.43
  tolerance = max(1.75, step * 0.05)
  max_error = 0.0

  for color, x, y in SAMPLE_MOVES:
    expected_x = grid_x0 + x * step_x
    expected_y = grid_y0 + y * step_y
    centroid_x, centroid_y, _ = stone_centroid(image, color, expected_x, expected_y, radius)
    error = math.hypot(centroid_x - expected_x, centroid_y - expected_y)
    max_error = max(max_error, error)
    assert error <= tolerance, (
      f"{color} stone at ({x},{y}) is not centered on its grid point: "
      f"error={error:.2f}, tolerance={tolerance:.2f}"
    )

  print(
    f"Board geometry inspection passed: {path} "
    f"(grid matches {x_matches}x{y_matches}, max stone error {max_error:.2f}px)"
  )


def main() -> int:
  path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SCREENSHOT
  inspect_board_geometry(path)
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
