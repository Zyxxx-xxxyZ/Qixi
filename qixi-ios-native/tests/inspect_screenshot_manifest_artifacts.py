#!/usr/bin/env python3
from __future__ import annotations

import itertools
import io
import os
import pathlib
import re
import stat as stat_module
import string
import subprocess
import sys

from PIL import Image, ImageChops, ImageStat
from screenshot_manifest_json import (
  ScreenshotManifestJSONError,
  load_manifest_json,
  validate_manifest_environment,
  validate_manifest_relative_path,
  validate_manifest_structure,
)


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tests" / "screenshot_coverage_manifest.json"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_HEADER_BYTES = 33
SCREENSHOT_ARTIFACT_MAX_BYTES = 64 * 1024 * 1024
SCREENSHOT_MAX_PIXELS = 16 * 1024 * 1024


class ManifestArtifactError(RuntimeError):
  pass


def load_manifest() -> dict:
  try:
    return load_manifest_json(MANIFEST)
  except Exception as exc:
    raise ManifestArtifactError(f"could not read {MANIFEST}: {exc}") from exc


def render(template: str, values: dict[str, str]) -> str:
  try:
    return template.format(**values)
  except KeyError as exc:
    raise ManifestArtifactError(f"template {template!r} references unknown dimension {exc}") from exc


def placeholders(template: str) -> set[str]:
  formatter = string.Formatter()
  return {name for _, name, _, _ in formatter.parse(template) if name}


def dimension_rows(dimensions: dict[str, list[str]]) -> list[dict[str, str]]:
  names = list(dimensions)
  return [
    dict(zip(names, values, strict=True))
    for values in itertools.product(*(dimensions[name] for name in names))
  ]


def require_manifest_relative_path(
  raw_path: object,
  *,
  matrix_id: str,
  field: str,
  required_prefix: tuple[str, ...] | None = None,
  required_suffix: str | None = None,
) -> pathlib.Path:
  try:
    path = validate_manifest_relative_path(
      raw_path,
      matrix_id=matrix_id,
      field=field,
      required_prefix=required_prefix,
      required_suffix=required_suffix,
    )
  except ScreenshotManifestJSONError as exc:
    raise ManifestArtifactError(str(exc)) from exc
  return ROOT / pathlib.Path(*path.parts)


def inspect_declared_scripts(matrix_id: str, scripts: object) -> None:
  if not isinstance(scripts, list) or not scripts:
    raise ManifestArtifactError(f"{matrix_id} scripts must be a non-empty list")
  for raw_script in scripts:
    script = require_manifest_relative_path(
      raw_script,
      matrix_id=matrix_id,
      field="script",
      required_prefix=("scripts",),
      required_suffix=".sh",
    )
    try:
      script_relative = script.relative_to(ROOT)
    except ValueError as exc:
      raise ManifestArtifactError(f"{matrix_id} script escapes screenshot root: {raw_script}") from exc
    if not script.exists():
      raise ManifestArtifactError(f"{matrix_id} missing screenshot script: {script_relative}")
    if script.is_symlink():
      raise ManifestArtifactError(f"{matrix_id} screenshot script must not be a symbolic link: {script_relative}")
    if not script.is_file():
      raise ManifestArtifactError(f"{matrix_id} screenshot script is not a file: {script_relative}")
    if not os.access(script, os.X_OK):
      raise ManifestArtifactError(f"{matrix_id} screenshot script is not executable: {script_relative}")


def inspect_declared_inspector(matrix_id: str, raw_inspector: str) -> pathlib.Path:
  inspector = require_manifest_relative_path(
    raw_inspector,
    matrix_id=matrix_id,
    field="inspector",
    required_prefix=("tests",),
    required_suffix=".py",
  )
  inspector_relative = inspector.relative_to(ROOT)
  if not inspector.exists():
    raise ManifestArtifactError(f"{matrix_id} missing inspector: {inspector_relative}")
  if inspector.is_symlink():
    raise ManifestArtifactError(f"{matrix_id} inspector must not be a symbolic link: {inspector_relative}")
  if not inspector.is_file():
    raise ManifestArtifactError(f"{matrix_id} inspector is not a file: {inspector_relative}")
  return inspector


def inspect_declared_environment(
  matrix_id: str,
  environment: object,
  *,
  known_dimensions: set[str],
) -> None:
  try:
    validate_manifest_environment(
      matrix_id,
      environment,
      known_dimensions=known_dimensions,
    )
  except ScreenshotManifestJSONError as exc:
    raise ManifestArtifactError(str(exc)) from exc


def declared_screenshot_path(matrix_id: str, raw_screenshot: str) -> pathlib.Path:
  return require_manifest_relative_path(
    raw_screenshot,
    matrix_id=matrix_id,
    field="screenshot",
    required_prefix=("artifacts", "screenshots"),
    required_suffix=".png",
  )


def expanded_states(manifest: dict) -> list[tuple[str, pathlib.Path, pathlib.Path, list[str]]]:
  try:
    validate_manifest_structure(manifest)
  except ScreenshotManifestJSONError as exc:
    raise ManifestArtifactError(str(exc)) from exc
  states: list[tuple[str, pathlib.Path, pathlib.Path, list[str]]] = []
  for matrix in manifest.get("matrices", []):
    matrix_id = matrix.get("id", "<missing-id>")
    dimensions = matrix.get("dimensions", {})
    screenshot_template = matrix.get("screenshot", "")
    inspector_template = matrix.get("inspector", "")
    inspector_arguments = matrix.get("inspectorArguments", [])
    inspect_declared_scripts(matrix_id, matrix.get("scripts"))

    if not isinstance(dimensions, dict):
      raise ManifestArtifactError(f"{matrix_id} dimensions must be an object")
    if not isinstance(inspector_arguments, list):
      raise ManifestArtifactError(f"{matrix_id} inspectorArguments must be a list")

    screenshot_placeholders = placeholders(screenshot_template)
    inspector_placeholders = placeholders(inspector_template)
    argument_placeholders = set().union(*(placeholders(str(arg)) for arg in inspector_arguments))
    known_dimensions = set(dimensions)
    inspect_declared_environment(
      matrix_id,
      matrix.get("environment", {}),
      known_dimensions=known_dimensions,
    )
    unknown = (screenshot_placeholders | inspector_placeholders | argument_placeholders) - known_dimensions
    if unknown:
      raise ManifestArtifactError(f"{matrix_id} references unknown dimensions: {sorted(unknown)}")

    for row in dimension_rows(dimensions):
      state_id = "-".join([matrix_id, *[row[name] for name in dimensions]])
      screenshot = declared_screenshot_path(matrix_id, render(screenshot_template, row))
      inspector = inspect_declared_inspector(matrix_id, render(inspector_template, row))
      rendered_args = [render(str(arg), row) for arg in inspector_arguments]
      states.append((state_id, screenshot, inspector, rendered_args))
  return states


def screenshot_min_mtime_epoch() -> float | None:
  raw = os.environ.get("QIXI_SCREENSHOT_MANIFEST_MIN_MTIME_EPOCH")
  if raw is None or raw == "":
    return None
  try:
    return float(raw)
  except ValueError as exc:
    raise ManifestArtifactError(
      "QIXI_SCREENSHOT_MANIFEST_MIN_MTIME_EPOCH must be a numeric Unix timestamp"
    ) from exc


def inspect_png_header(
  state_id: str,
  screenshot: pathlib.Path,
  screenshot_stat: os.stat_result,
) -> tuple[bytes, tuple[int, int], os.stat_result]:
  screenshot_relative = screenshot.relative_to(ROOT)
  if screenshot_stat.st_size > SCREENSHOT_ARTIFACT_MAX_BYTES:
    raise ManifestArtifactError(
      f"{state_id} screenshot artifact exceeds byte budget: "
      f"{screenshot_relative} size={screenshot_stat.st_size} max={SCREENSHOT_ARTIFACT_MAX_BYTES}"
    )
  try:
    with screenshot.open("rb") as handle:
      opened_stat = os.fstat(handle.fileno())
      if not stat_module.S_ISREG(opened_stat.st_mode):
        raise ManifestArtifactError(
          f"{state_id} screenshot artifact must be a regular file after opening: {screenshot_relative}"
        )
      if opened_stat.st_size <= 0:
        raise ManifestArtifactError(f"{state_id} screenshot artifact is empty after opening: {screenshot_relative}")
      if opened_stat.st_size > SCREENSHOT_ARTIFACT_MAX_BYTES:
        raise ManifestArtifactError(
          f"{state_id} screenshot artifact exceeds byte budget after opening: "
          f"{screenshot_relative} size={opened_stat.st_size} max={SCREENSHOT_ARTIFACT_MAX_BYTES}"
        )
      image_data = handle.read(SCREENSHOT_ARTIFACT_MAX_BYTES + 1)
  except ManifestArtifactError:
    raise
  except OSError as exc:
    raise ManifestArtifactError(f"{state_id} screenshot artifact could not be read: {screenshot_relative}: {exc}") from exc
  if len(image_data) > SCREENSHOT_ARTIFACT_MAX_BYTES:
    raise ManifestArtifactError(
      f"{state_id} screenshot artifact exceeds byte budget while reading: "
      f"{screenshot_relative} max={SCREENSHOT_ARTIFACT_MAX_BYTES}"
    )
  if len(image_data) != opened_stat.st_size:
    raise ManifestArtifactError(
      f"{state_id} screenshot artifact opened-byte-count drift while reading: "
      f"read {len(image_data)} bytes but opened descriptor reported {opened_stat.st_size} bytes"
    )
  header = image_data[:PNG_HEADER_BYTES]
  if len(header) < PNG_HEADER_BYTES or header[: len(PNG_SIGNATURE)] != PNG_SIGNATURE:
    raise ManifestArtifactError(f"{state_id} screenshot artifact must be a PNG file: {screenshot_relative}")
  ihdr_length = int.from_bytes(header[8:12], "big")
  ihdr_kind = header[12:16]
  if ihdr_length != 13 or ihdr_kind != b"IHDR":
    raise ManifestArtifactError(f"{state_id} screenshot artifact must have a valid PNG IHDR: {screenshot_relative}")
  width = int.from_bytes(header[16:20], "big")
  height = int.from_bytes(header[20:24], "big")
  if width <= 0 or height <= 0:
    raise ManifestArtifactError(f"{state_id} screenshot artifact has invalid PNG dimensions: {screenshot_relative}")
  if width * height > SCREENSHOT_MAX_PIXELS:
    raise ManifestArtifactError(
      f"{state_id} screenshot artifact is too large for bounded visual inspection: "
      f"{width}x{height} {screenshot_relative}"
    )
  return image_data, (width, height), opened_stat


def inspect_png_decodes(state_id: str, screenshot: pathlib.Path, image_data: bytes, expected_size: tuple[int, int]) -> None:
  screenshot_relative = screenshot.relative_to(ROOT)
  try:
    with Image.open(io.BytesIO(image_data)) as image:
      decoded_size = image.size
      image_format = image.format
      image.verify()
  except Exception as exc:
    raise ManifestArtifactError(
      f"{state_id} screenshot artifact must be a decodable PNG image: {screenshot_relative}: {exc}"
    ) from exc
  if image_format != "PNG":
    raise ManifestArtifactError(f"{state_id} screenshot artifact must decode as PNG: {screenshot_relative}")
  if decoded_size != expected_size:
    raise ManifestArtifactError(
      f"{state_id} screenshot artifact decoded dimensions do not match PNG IHDR: "
      f"decoded={decoded_size[0]}x{decoded_size[1]} ihdr={expected_size[0]}x{expected_size[1]} "
      f"{screenshot_relative}"
    )


def inspect_state(
  state_id: str,
  screenshot: pathlib.Path,
  inspector: pathlib.Path,
  args: list[str],
  *,
  min_mtime_epoch: float | None = None,
) -> None:
  screenshot_relative = screenshot.relative_to(ROOT)
  inspector_relative = inspector.relative_to(ROOT)
  if not screenshot.exists():
    raise ManifestArtifactError(f"{state_id} missing screenshot artifact: {screenshot_relative}")
  if screenshot.is_symlink():
    raise ManifestArtifactError(f"{state_id} screenshot artifact must not be a symbolic link: {screenshot_relative}")
  if not screenshot.is_file():
    raise ManifestArtifactError(f"{state_id} screenshot artifact is not a file: {screenshot_relative}")
  screenshot_stat = screenshot.stat()
  if screenshot_stat.st_size <= 0:
    raise ManifestArtifactError(f"{state_id} screenshot artifact is empty: {screenshot_relative}")
  png_data, png_size, opened_screenshot_stat = inspect_png_header(state_id, screenshot, screenshot_stat)
  inspect_png_decodes(state_id, screenshot, png_data, png_size)
  if min_mtime_epoch is not None and opened_screenshot_stat.st_mtime < min_mtime_epoch:
    raise ManifestArtifactError(
      f"{state_id} stale screenshot artifact: {screenshot_relative} "
      f"mtime={opened_screenshot_stat.st_mtime:.3f} before required minimum {min_mtime_epoch:.3f}"
    )
  if not inspector.exists():
    raise ManifestArtifactError(f"{state_id} missing inspector: {inspector_relative}")
  if inspector.is_symlink():
    raise ManifestArtifactError(f"{state_id} inspector must not be a symbolic link: {inspector_relative}")
  if not inspector.is_file():
    raise ManifestArtifactError(f"{state_id} inspector is not a file: {inspector_relative}")

  command = [sys.executable, str(inspector), str(screenshot), *args]
  result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)
  if result.returncode != 0:
    detail = result.stderr.strip() or result.stdout.strip()
    raise ManifestArtifactError(f"{state_id} inspector failed: {' '.join(command)}\n{detail}")


ENGINE_ERROR_RE = re.compile(
  r"^latest-(?P<device>ipad|iphone)-engine-error-"
  r"(?P<error>library-not-linked|model-missing|insufficient-memory|local-network-denied)-"
  r"(?P<language>zh-Hans|zh-Hant|en)\.png$"
)


def engine_error_banner_crop(path: pathlib.Path) -> Image.Image:
  image = Image.open(path).convert("RGB")
  width, height = image.size
  return image.crop((width * 5 // 8, 0, width, height // 5))


def sheet_content_crop(path: pathlib.Path) -> Image.Image:
  image = Image.open(path).convert("RGB")
  width, height = image.size
  return image.crop((width // 5, height // 5, width * 4 // 5, height * 4 // 5))


def visual_difference_score(lhs: Image.Image, rhs: Image.Image) -> tuple[float, int]:
  diff = ImageChops.difference(lhs, rhs).convert("L")
  mean = ImageStat.Stat(diff).mean[0]
  changed_mask = diff.point(lambda value: 255 if value > 12 else 0)
  changed_pixels = changed_mask.histogram()[255]
  return mean, changed_pixels


def inspect_engine_error_variants_are_distinct(states: list[tuple[str, pathlib.Path, pathlib.Path, list[str]]]) -> None:
  grouped: dict[tuple[str, str], dict[str, pathlib.Path]] = {}
  for _, screenshot, _, _ in states:
    match = ENGINE_ERROR_RE.match(screenshot.name)
    if not match:
      continue
    key = (match.group("device"), match.group("language"))
    grouped.setdefault(key, {})[match.group("error")] = screenshot

  expected_errors = {"library-not-linked", "model-missing", "insufficient-memory", "local-network-denied"}
  for key, paths_by_error in sorted(grouped.items()):
    if set(paths_by_error) != expected_errors:
      raise ManifestArtifactError(
        f"engine-error variants for {key[0]} {key[1]} are incomplete: {sorted(paths_by_error)}"
      )
    crops = {
      error: engine_error_banner_crop(path)
      for error, path in paths_by_error.items()
    }
    for lhs_index, lhs_error in enumerate(sorted(expected_errors)):
      for rhs_error in sorted(expected_errors)[lhs_index + 1:]:
        mean, changed_pixels = visual_difference_score(crops[lhs_error], crops[rhs_error])
        if mean <= 0.4 or changed_pixels <= 1000:
          raise ManifestArtifactError(
            f"engine-error screenshots for {key[0]} {key[1]} do not visibly distinguish "
            f"{lhs_error} from {rhs_error}: mean={mean:.3f}, changedPixels={changed_pixels}"
          )


UTILITY_SHEET_RE = re.compile(
  r"^latest-(?P<device>ipad|iphone)-(?P<variant>camera|import)-sheet-"
  r"(?P<language>zh-Hans|zh-Hant|en)\.png$"
)
SYNC_SHEET_RE = re.compile(
  r"^latest-(?P<device>ipad|iphone)-sync(?:-(?P<variant>enabled|synced|error|conflict))?-sheet-"
  r"(?P<language>zh-Hans|zh-Hant|en)\.png$"
)


def inspect_variant_group_is_distinct(
  states: list[tuple[str, pathlib.Path, pathlib.Path, list[str]]],
  *,
  label: str,
  pattern: re.Pattern[str],
  expected_variants: set[str],
  minimum_mean_difference: float,
  minimum_changed_pixels: int,
) -> None:
  grouped: dict[tuple[str, str], dict[str, pathlib.Path]] = {}
  for _, screenshot, _, _ in states:
    match = pattern.match(screenshot.name)
    if not match:
      continue
    variant = match.groupdict().get("variant") or "disabled"
    device = match.group("device")
    language = match.group("language")
    grouped.setdefault((device, language), {})[variant] = screenshot

  for (device, language), paths_by_variant in sorted(grouped.items()):
    if set(paths_by_variant) != expected_variants:
      raise ManifestArtifactError(
        f"{label} variants for {device} {language} are incomplete: {sorted(paths_by_variant)}"
      )
    crops = {
      variant: sheet_content_crop(path)
      for variant, path in paths_by_variant.items()
    }
    for lhs_variant, rhs_variant in itertools.combinations(sorted(expected_variants), 2):
      mean, changed_pixels = visual_difference_score(crops[lhs_variant], crops[rhs_variant])
      if mean <= minimum_mean_difference or changed_pixels <= minimum_changed_pixels:
        raise ManifestArtifactError(
          f"{label} screenshots for {device} {language} do not visibly distinguish "
          f"{lhs_variant} from {rhs_variant}: mean={mean:.3f}, changedPixels={changed_pixels}"
        )


def inspect_sheet_variants_are_distinct(states: list[tuple[str, pathlib.Path, pathlib.Path, list[str]]]) -> None:
  inspect_variant_group_is_distinct(
    states,
    label="utility-sheet",
    pattern=UTILITY_SHEET_RE,
    expected_variants={"camera", "import"},
    minimum_mean_difference=1.0,
    minimum_changed_pixels=10_000,
  )
  inspect_variant_group_is_distinct(
    states,
    label="sync-sheet",
    pattern=SYNC_SHEET_RE,
    expected_variants={"conflict", "disabled", "enabled", "error", "synced"},
    minimum_mean_difference=0.15,
    minimum_changed_pixels=1_200,
  )


def main() -> int:
  try:
    manifest = load_manifest()
    states = expanded_states(manifest)
    expected_count = manifest.get("requiredStateCount")
    if len(states) != expected_count:
      raise ManifestArtifactError(
        f"manifest expands to {len(states)} states, expected requiredStateCount={expected_count}"
      )

    min_mtime_epoch = screenshot_min_mtime_epoch()
    seen_screenshots: set[pathlib.Path] = set()
    for state_id, screenshot, inspector, args in states:
      if screenshot in seen_screenshots:
        raise ManifestArtifactError(f"{state_id} reuses screenshot artifact: {screenshot.relative_to(ROOT)}")
      seen_screenshots.add(screenshot)
      inspect_state(state_id, screenshot, inspector, args, min_mtime_epoch=min_mtime_epoch)
    inspect_engine_error_variants_are_distinct(states)
    inspect_sheet_variants_are_distinct(states)
  except ManifestArtifactError as exc:
    print(f"Screenshot manifest artifact inspection failed: {exc}", file=sys.stderr)
    return 1

  print(f"Screenshot manifest artifact inspection passed: {len(states)} states")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
