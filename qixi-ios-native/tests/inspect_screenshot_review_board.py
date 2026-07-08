#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import os
import pathlib
import re
import sys
import itertools
import string
import stat as stat_module
from typing import Any

from PIL import Image, ImageStat

from screenshot_manifest_json import (
  MAX_SCREENSHOT_MANIFEST_BYTES,
  ScreenshotManifestJSONError,
  load_manifest_json,
  validate_manifest_environment,
  validate_manifest_relative_path,
  validate_manifest_structure,
)


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_REVIEW_DIR = ROOT / "artifacts" / "screenshots" / "review-board"
DEFAULT_MANIFEST = ROOT / "tests" / "screenshot_coverage_manifest.json"
MAX_REVIEW_JSON_BYTES = 4 * 1024 * 1024
MAX_REVIEW_HTML_BYTES = 4 * 1024 * 1024
MIN_PAGE_BYTES = 32 * 1024
MIN_PAGE_WIDTH = 1000
MIN_PAGE_HEIGHT = 1000
MIN_PAGE_STDDEV = 8.0
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_HEADER_BYTES = 33
REVIEW_BOARD_IMAGE_MAX_BYTES = 64 * 1024 * 1024
REVIEW_BOARD_IMAGE_MAX_PIXELS = 16 * 1024 * 1024
REVIEW_BOARD_GENERATED_AT_MAX_FUTURE_SKEW_SECONDS = 5 * 60
SHA256_HEX_RE = re.compile(r"^[0-9a-f]{64}$")


class ReviewBoardArtifactError(RuntimeError):
  pass


def is_allowed_platform_symlink_alias(path: pathlib.Path) -> bool:
  allowed_aliases = {
    pathlib.Path("/var"): pathlib.Path("/private/var"),
    pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
    pathlib.Path("/etc"): pathlib.Path("/private/etc"),
  }
  target = allowed_aliases.get(path)
  if target is None:
    return False
  try:
    return path.resolve(strict=True) == target
  except OSError:
    return False


def reject_symlink_components(path: pathlib.Path, label: str) -> None:
  expanded = path.expanduser()
  current = pathlib.Path(expanded.anchor) if expanded.is_absolute() else pathlib.Path(".")
  for part in expanded.parts:
    if part == expanded.anchor or part in ("", "."):
      continue
    if part == "..":
      raise ReviewBoardArtifactError(f"review-board {label} path must not contain parent-directory traversal: {path}")
    current = current / part
    if current.is_symlink() and not is_allowed_platform_symlink_alias(current):
      raise ReviewBoardArtifactError(f"review-board {label} path must not contain symbolic links: {current}")


def require_real_directory(path: pathlib.Path, label: str) -> None:
  reject_symlink_components(path, label)
  if not path.exists():
    raise ReviewBoardArtifactError(f"missing review-board {label}: {path}")
  if path.is_symlink():
    raise ReviewBoardArtifactError(f"review-board {label} must not be a symbolic link: {path}")
  if not path.is_dir():
    raise ReviewBoardArtifactError(f"review-board {label} is not a directory: {path}")


def require_real_file(path: pathlib.Path, label: str) -> None:
  reject_symlink_components(path, label)
  if not path.exists():
    raise ReviewBoardArtifactError(f"missing review-board {label}: {path}")
  if path.is_symlink():
    raise ReviewBoardArtifactError(f"review-board {label} must not be a symbolic link: {path}")
  if not path.is_file():
    raise ReviewBoardArtifactError(f"review-board {label} is not a file: {path}")


def opened_regular_file_stat(
  handle: Any,
  path: pathlib.Path,
  label: str,
  *,
  max_bytes: int | None = None,
  allow_empty: bool = False,
) -> os.stat_result:
  try:
    opened_stat = os.fstat(handle.fileno())
  except OSError as exc:
    raise ReviewBoardArtifactError(f"could not stat opened review-board {label} descriptor: {path}: {exc}") from exc
  if not stat_module.S_ISREG(opened_stat.st_mode):
    raise ReviewBoardArtifactError(f"review-board {label} must be a regular file after opening: {path}")
  if not allow_empty and opened_stat.st_size <= 0:
    raise ReviewBoardArtifactError(f"review-board {label} is empty after opening: {path}")
  if max_bytes is not None and opened_stat.st_size > max_bytes:
    raise ReviewBoardArtifactError(f"review-board {label} exceeds {max_bytes} bytes after opening: {path}")
  return opened_stat


def read_bounded_utf8(path: pathlib.Path, label: str, max_bytes: int) -> str:
  require_real_file(path, label)
  byte_count = path.stat().st_size
  if byte_count <= 0:
    raise ReviewBoardArtifactError(f"review-board {label} is empty: {path}")
  if byte_count > max_bytes:
    raise ReviewBoardArtifactError(f"review-board {label} exceeds {max_bytes} bytes: {path}")
  try:
    with path.open("rb") as handle:
      opened_stat = opened_regular_file_stat(handle, path, label, max_bytes=max_bytes)
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    raise ReviewBoardArtifactError(f"could not read review-board {label}: {path}: {exc}") from exc
  if len(data) > max_bytes:
    raise ReviewBoardArtifactError(f"review-board {label} exceeded bounded read limit of {max_bytes} bytes: {path}")
  if len(data) != opened_stat.st_size:
    raise ReviewBoardArtifactError(
      f"review-board {label} opened-byte-count drift while reading: "
      f"read {len(data)} bytes, expected {opened_stat.st_size}: {path}"
    )
  try:
    return data.decode("utf-8")
  except UnicodeDecodeError as exc:
    raise ReviewBoardArtifactError(f"review-board {label} must be valid UTF-8: {path}: {exc}") from exc


def sha256_hex_digest(path: pathlib.Path, label: str, max_bytes: int) -> str:
  digest = hashlib.sha256()
  try:
    with path.open("rb") as handle:
      opened_stat = opened_regular_file_stat(handle, path, label, max_bytes=max_bytes)
      bytes_read = 0
      for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        bytes_read += len(chunk)
        if bytes_read > max_bytes:
          raise ReviewBoardArtifactError(f"review-board {label} exceeded bounded hash limit of {max_bytes} bytes: {path}")
        digest.update(chunk)
  except ReviewBoardArtifactError:
    raise
  except OSError as exc:
    raise ReviewBoardArtifactError(f"could not hash review-board {label}: {path}: {exc}") from exc
  if bytes_read != opened_stat.st_size:
    raise ReviewBoardArtifactError(
      f"review-board {label} opened-byte-count drift while hashing: "
      f"read {bytes_read} bytes, expected {opened_stat.st_size}: {path}"
    )
  return digest.hexdigest()


def require_sha256_hex_digest(raw_digest: object, label: str) -> str:
  if not isinstance(raw_digest, str) or not SHA256_HEX_RE.fullmatch(raw_digest):
    raise ReviewBoardArtifactError(f"review-board {label} must contain a SHA-256 hex digest")
  return raw_digest


def inspect_png_header(path: pathlib.Path, label: str, byte_count: int) -> tuple[bytes, tuple[int, int]]:
  if byte_count > REVIEW_BOARD_IMAGE_MAX_BYTES:
    raise ReviewBoardArtifactError(
      f"review-board {label} exceeds byte budget: "
      f"{path} size={byte_count} max={REVIEW_BOARD_IMAGE_MAX_BYTES}"
    )
  with path.open("rb") as handle:
    opened_stat = opened_regular_file_stat(
      handle,
      path,
      label,
      max_bytes=REVIEW_BOARD_IMAGE_MAX_BYTES,
    )
    if opened_stat.st_size != byte_count:
      raise ReviewBoardArtifactError(f"review-board {label} byte count drift after opening: {path}")
    image_data = handle.read(REVIEW_BOARD_IMAGE_MAX_BYTES + 1)
  if len(image_data) > REVIEW_BOARD_IMAGE_MAX_BYTES:
    raise ReviewBoardArtifactError(f"review-board {label} exceeded bounded image read limit of {REVIEW_BOARD_IMAGE_MAX_BYTES} bytes: {path}")
  if len(image_data) != byte_count:
    raise ReviewBoardArtifactError(
      f"review-board {label} opened-byte-count drift while reading: "
      f"read {len(image_data)} bytes, expected {byte_count}: {path}"
    )
  header = image_data[:PNG_HEADER_BYTES]
  if len(header) < PNG_HEADER_BYTES or header[: len(PNG_SIGNATURE)] != PNG_SIGNATURE:
    raise ReviewBoardArtifactError(f"review-board {label} must be a PNG file: {path}")
  ihdr_length = int.from_bytes(header[8:12], "big")
  ihdr_kind = header[12:16]
  if ihdr_length != 13 or ihdr_kind != b"IHDR":
    raise ReviewBoardArtifactError(f"review-board {label} must have a valid PNG IHDR: {path}")
  width = int.from_bytes(header[16:20], "big")
  height = int.from_bytes(header[20:24], "big")
  if width <= 0 or height <= 0:
    raise ReviewBoardArtifactError(f"review-board {label} has invalid PNG dimensions: {path}")
  if width * height > REVIEW_BOARD_IMAGE_MAX_PIXELS:
    raise ReviewBoardArtifactError(
      f"review-board {label} is too large for bounded visual inspection: "
      f"{width}x{height} {path}"
    )
  return image_data, (width, height)


def inspect_png_decodes(path: pathlib.Path, label: str, image_data: bytes, expected_size: tuple[int, int]) -> None:
  try:
    with Image.open(io.BytesIO(image_data)) as image:
      decoded_size = image.size
      image_format = image.format
      image.verify()
  except Exception as exc:
    raise ReviewBoardArtifactError(f"review-board {label} must be a decodable PNG image: {path}: {exc}") from exc
  if image_format != "PNG":
    raise ReviewBoardArtifactError(f"review-board {label} must decode as PNG: {path}")
  if decoded_size != expected_size:
    raise ReviewBoardArtifactError(
      f"review-board {label} decoded dimensions do not match PNG IHDR: "
      f"decoded={decoded_size[0]}x{decoded_size[1]} ihdr={expected_size[0]}x{expected_size[1]} {path}"
    )


def inspect_png_artifact(path: pathlib.Path, label: str, byte_count: int) -> tuple[int, int, bytes]:
  image_data, size = inspect_png_header(path, label, byte_count)
  inspect_png_decodes(path, label, image_data, size)
  return size[0], size[1], image_data


def placeholders(template: str) -> set[str]:
  formatter = string.Formatter()
  return {name for _, name, _, _ in formatter.parse(template) if name}


def render_template(template: str, values: dict[str, str]) -> str:
  try:
    return template.format(**values)
  except KeyError as exc:
    raise ReviewBoardArtifactError(f"template {template!r} references unknown dimension {exc}") from exc


def declared_manifest_screenshot_path(matrix_id: str, rendered_screenshot: str) -> str:
  try:
    path = validate_manifest_relative_path(
      rendered_screenshot,
      matrix_id=matrix_id,
      field="screenshot",
      required_prefix=("artifacts", "screenshots"),
      required_suffix=".png",
    )
  except ScreenshotManifestJSONError as exc:
    raise ReviewBoardArtifactError(str(exc)) from exc
  return path.as_posix()


def dimension_rows(dimensions: dict[str, list[str]]) -> list[dict[str, str]]:
  names = list(dimensions)
  return [
    dict(zip(names, values, strict=True))
    for values in itertools.product(*(dimensions[name] for name in names))
  ]


def expected_states_from_manifest(manifest_path: pathlib.Path) -> list[dict[str, object]]:
  manifest = load_manifest_json(manifest_path)
  try:
    validate_manifest_structure(manifest)
  except ScreenshotManifestJSONError as exc:
    raise ReviewBoardArtifactError(str(exc)) from exc
  states: list[dict[str, object]] = []
  for matrix in manifest.get("matrices", []):
    matrix_id = matrix.get("id", "<missing-id>")
    description = str(matrix.get("description", ""))
    dimensions = matrix.get("dimensions", {})
    screenshot_template = matrix.get("screenshot", "")
    if not isinstance(dimensions, dict):
      raise ReviewBoardArtifactError(f"{matrix_id} dimensions must be an object")
    if not isinstance(screenshot_template, str) or not screenshot_template:
      raise ReviewBoardArtifactError(f"{matrix_id} screenshot must be a non-empty string")
    unknown = placeholders(screenshot_template) - set(dimensions)
    if unknown:
      raise ReviewBoardArtifactError(f"{matrix_id} references unknown dimensions: {sorted(unknown)}")
    try:
      validate_manifest_environment(
        str(matrix_id),
        matrix.get("environment", {}),
        known_dimensions=set(dimensions),
      )
    except ScreenshotManifestJSONError as exc:
      raise ReviewBoardArtifactError(str(exc)) from exc
    for row in dimension_rows(dimensions):
      state_id = "-".join([str(matrix_id), *[row[name] for name in dimensions]])
      states.append(
        {
          "id": state_id,
          "matrixId": str(matrix_id),
          "description": description,
          "dimensions": row,
          "screenshot": declared_manifest_screenshot_path(str(matrix_id), render_template(screenshot_template, row)),
        }
      )
  expected_count = manifest.get("requiredStateCount")
  if len(states) != expected_count:
    raise ReviewBoardArtifactError(
      f"screenshot manifest expands to {len(states)} states, expected requiredStateCount={expected_count}"
    )
  return states


def review_board_min_mtime_epoch() -> float | None:
  raw = os.environ.get("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH")
  if raw is None or raw == "":
    return None
  try:
    return float(raw)
  except ValueError as exc:
    raise ReviewBoardArtifactError(
      "QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH must be a numeric Unix timestamp"
    ) from exc


def inspect_artifact_freshness(path: pathlib.Path, label: str, min_mtime_epoch: float | None) -> None:
  if min_mtime_epoch is None:
    return
  mtime = path.stat().st_mtime
  if mtime < min_mtime_epoch:
    raise ReviewBoardArtifactError(
      f"stale review-board {label}: {path} mtime={mtime:.3f} "
      f"before required minimum {min_mtime_epoch:.3f}"
    )


def inspect_generated_at(
  raw_generated_at: object,
  min_mtime_epoch: float | None,
  *,
  now_epoch: float | None = None,
) -> None:
  if not isinstance(raw_generated_at, str) or not raw_generated_at.endswith("Z"):
    raise ReviewBoardArtifactError("review-board generatedAt must be a UTC ISO-8601 timestamp ending in Z")
  try:
    generated_at = dt.datetime.fromisoformat(raw_generated_at[:-1] + "+00:00")
  except ValueError as exc:
    raise ReviewBoardArtifactError(
      f"review-board generatedAt must be a valid UTC ISO-8601 timestamp: {raw_generated_at!r}"
    ) from exc
  if generated_at.tzinfo != dt.timezone.utc:
    raise ReviewBoardArtifactError("review-board generatedAt must use UTC")
  generated_at_epoch = generated_at.timestamp()
  if min_mtime_epoch is not None and generated_at_epoch < min_mtime_epoch:
    raise ReviewBoardArtifactError(
      f"stale review-board generatedAt: {raw_generated_at} "
      f"before required minimum {min_mtime_epoch:.3f}"
    )
  current_epoch = now_epoch if now_epoch is not None else dt.datetime.now(dt.timezone.utc).timestamp()
  if generated_at_epoch > current_epoch + REVIEW_BOARD_GENERATED_AT_MAX_FUTURE_SKEW_SECONDS:
    raise ReviewBoardArtifactError(
      f"review-board generatedAt is too far in the future: {raw_generated_at} "
      f"now={current_epoch:.3f} maxSkew={REVIEW_BOARD_GENERATED_AT_MAX_FUTURE_SKEW_SECONDS}"
    )


def load_strict_json_object(path: pathlib.Path, *, min_mtime_epoch: float | None = None) -> dict[str, Any]:
  require_real_file(path, "JSON")
  inspect_artifact_freshness(path, "JSON", min_mtime_epoch)

  def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
      if key in result:
        raise ReviewBoardArtifactError(f"review-board JSON contains duplicate key {key!r}")
      result[key] = value
    return result

  def reject_non_standard_constant(value: str) -> None:
    raise ReviewBoardArtifactError(f"review-board JSON contains non-standard constant {value}")

  try:
    payload = json.loads(
      read_bounded_utf8(path, "JSON", MAX_REVIEW_JSON_BYTES),
      object_pairs_hook=reject_duplicate_keys,
      parse_constant=reject_non_standard_constant,
    )
  except ReviewBoardArtifactError:
    raise
  except Exception as exc:
    raise ReviewBoardArtifactError(f"could not parse review-board JSON {path}: {exc}") from exc
  if not isinstance(payload, dict):
    raise ReviewBoardArtifactError("review-board JSON must be an object")
  return payload


def expected_state_count(manifest_path: pathlib.Path) -> int:
  return len(expected_states_from_manifest(manifest_path))


def safe_posix_parts(raw_path: str, label: str) -> list[str]:
  parts = raw_path.split("/")
  if any(part in ("", ".", "..") for part in parts):
    raise ReviewBoardArtifactError(
      f"review-board {label} path must not contain empty, current-directory, or parent-directory components: {raw_path!r}"
    )
  return parts


def require_relative_page_path(raw_path: object) -> str:
  if not isinstance(raw_path, str) or not raw_path:
    raise ReviewBoardArtifactError("review-board page path must be a non-empty string")
  safe_posix_parts(raw_path, "page")
  path = pathlib.PurePosixPath(raw_path)
  if path.is_absolute() or ".." in path.parts or len(path.parts) != 1:
    raise ReviewBoardArtifactError(f"review-board page path must be a local filename: {raw_path!r}")
  if not re.fullmatch(r"latest-screenshot-review-board-page-\d{2}\.png", path.name):
    raise ReviewBoardArtifactError(f"review-board page path has unexpected name: {raw_path!r}")
  return path.name


def require_relative_screenshot_path(raw_path: object) -> pathlib.PurePosixPath:
  if not isinstance(raw_path, str) or not raw_path:
    raise ReviewBoardArtifactError("review-board state screenshot path must be a non-empty string")
  safe_posix_parts(raw_path, "state screenshot")
  path = pathlib.PurePosixPath(raw_path)
  if path.is_absolute() or ".." in path.parts:
    raise ReviewBoardArtifactError(f"review-board state screenshot path must be relative and safe: {raw_path!r}")
  if len(path.parts) < 3 or path.parts[:2] != ("artifacts", "screenshots") or path.suffix != ".png":
    raise ReviewBoardArtifactError(f"review-board state screenshot path is invalid: {raw_path!r}")
  return path


def inspect_page_image(
  path: pathlib.Path,
  *,
  expected_width: object,
  expected_height: object,
  expected_byte_count: object,
  expected_sha256: object,
  min_mtime_epoch: float | None = None,
) -> None:
  require_real_file(path, "page image")
  inspect_artifact_freshness(path, "page image", min_mtime_epoch)
  byte_count = path.stat().st_size
  if byte_count < MIN_PAGE_BYTES:
    raise ReviewBoardArtifactError(f"review-board page image is too small: {path}")
  if expected_byte_count != byte_count:
    raise ReviewBoardArtifactError(f"review-board page byte count drift: {path.name}")
  width, height, image_data = inspect_png_artifact(path, f"page image {path.name}", byte_count)
  if width < MIN_PAGE_WIDTH or height < MIN_PAGE_HEIGHT:
    raise ReviewBoardArtifactError(
      f"review-board page image is too small: {path.name} {width}x{height}"
    )
  if expected_width != width or expected_height != height:
    raise ReviewBoardArtifactError(f"review-board page dimensions drift: {path.name}")
  try:
    with Image.open(io.BytesIO(image_data)) as image:
      stat = ImageStat.Stat(image.convert("L"))
      stddev = stat.stddev[0]
  except ReviewBoardArtifactError:
    raise
  except Exception as exc:
    raise ReviewBoardArtifactError(f"could not inspect review-board page image {path}: {exc}") from exc
  if stddev < MIN_PAGE_STDDEV:
    raise ReviewBoardArtifactError(
      f"review-board page image lacks visual variance: {path.name} stddev={stddev:.3f}"
    )
  digest = require_sha256_hex_digest(expected_sha256, f"page image {path.name}")
  if hashlib.sha256(image_data).hexdigest() != digest:
    raise ReviewBoardArtifactError(f"review-board page digest drift: {path.name}")


def inspect_review_board(review_dir: pathlib.Path, manifest_path: pathlib.Path) -> None:
  require_real_directory(review_dir, "directory")
  root = manifest_path.parent.parent
  min_mtime_epoch = review_board_min_mtime_epoch()
  payload = load_strict_json_object(
    review_dir / "latest-screenshot-review-board.json",
    min_mtime_epoch=min_mtime_epoch,
  )
  expected_states = expected_states_from_manifest(manifest_path)
  expected_count = len(expected_states)
  if payload.get("schemaVersion") != 1:
    raise ReviewBoardArtifactError("review-board schemaVersion must be 1")
  inspect_generated_at(payload.get("generatedAt"), min_mtime_epoch)
  if payload.get("manifest") != "tests/screenshot_coverage_manifest.json":
    raise ReviewBoardArtifactError("review-board manifest path is incorrect")
  manifest_digest = require_sha256_hex_digest(payload.get("manifestSha256HexDigest"), "manifest")
  if sha256_hex_digest(manifest_path, "manifest", MAX_SCREENSHOT_MANIFEST_BYTES) != manifest_digest:
    raise ReviewBoardArtifactError("review-board manifest digest drift")
  if payload.get("stateCount") != expected_count:
    raise ReviewBoardArtifactError(
      f"review-board stateCount={payload.get('stateCount')!r} expected {expected_count}"
    )
  pages = payload.get("pages")
  states = payload.get("states")
  if not isinstance(pages, list) or not pages:
    raise ReviewBoardArtifactError("review-board pages must be a non-empty list")
  if not isinstance(states, list) or len(states) != expected_count:
    raise ReviewBoardArtifactError("review-board states length must match manifest requiredStateCount")
  if payload.get("pageCount") != len(pages):
    raise ReviewBoardArtifactError("review-board pageCount must equal pages length")
  if sum(page.get("stateCount", 0) for page in pages if isinstance(page, dict)) != expected_count:
    raise ReviewBoardArtifactError("review-board page state counts must sum to stateCount")

  page_names: list[str] = []
  for expected_index, page in enumerate(pages, start=1):
    if not isinstance(page, dict):
      raise ReviewBoardArtifactError("review-board page entries must be objects")
    if page.get("index") != expected_index:
      raise ReviewBoardArtifactError("review-board page indexes must be contiguous and one-based")
    page_name = require_relative_page_path(page.get("path"))
    page_names.append(page_name)
    inspect_page_image(
      review_dir / page_name,
      expected_width=page.get("width"),
      expected_height=page.get("height"),
      expected_byte_count=page.get("byteCount"),
      expected_sha256=page.get("sha256HexDigest"),
      min_mtime_epoch=min_mtime_epoch,
    )
  if len(set(page_names)) != len(page_names):
    raise ReviewBoardArtifactError("review-board page paths must be unique")
  referenced_page_names = set(page_names)
  extra_page_names = {
    path.name
    for path in review_dir.glob("latest-screenshot-review-board-page-*.png")
    if path.name not in referenced_page_names
  }
  if extra_page_names:
    raise ReviewBoardArtifactError(
      f"review-board directory contains unreferenced page images: {sorted(extra_page_names)}"
    )
  expected_artifact_names = {
    "latest-screenshot-review-board.html",
    "latest-screenshot-review-board.json",
    *referenced_page_names,
  }
  unexpected_artifact_names = {
    path.name
    for path in review_dir.iterdir()
    if path.name not in expected_artifact_names
  }
  if unexpected_artifact_names:
    raise ReviewBoardArtifactError(
      f"review-board directory contains unexpected artifacts: {sorted(unexpected_artifact_names)}"
    )

  seen_state_ids: set[str] = set()
  seen_screenshots: set[str] = set()
  for state, expected_state in zip(states, expected_states, strict=True):
    if not isinstance(state, dict):
      raise ReviewBoardArtifactError("review-board state entries must be objects")
    state_id = state.get("id")
    screenshot = state.get("screenshot")
    if not isinstance(state_id, str) or not state_id:
      raise ReviewBoardArtifactError("review-board state id must be a non-empty string")
    if state_id in seen_state_ids:
      raise ReviewBoardArtifactError(f"review-board contains duplicate state id {state_id!r}")
    seen_state_ids.add(state_id)
    if state_id != expected_state["id"]:
      raise ReviewBoardArtifactError(
        f"review-board state order or id drift: got {state_id!r}, expected {expected_state['id']!r}"
      )
    if state.get("matrixId") != expected_state["matrixId"]:
      raise ReviewBoardArtifactError(f"review-board matrixId drift for state {state_id!r}")
    if state.get("description") != expected_state["description"]:
      raise ReviewBoardArtifactError(f"review-board description drift for state {state_id!r}")
    if state.get("dimensions") != expected_state["dimensions"]:
      raise ReviewBoardArtifactError(f"review-board dimensions object drift for state {state_id!r}")
    screenshot_path = require_relative_screenshot_path(screenshot)
    screenshot = str(screenshot_path)
    if screenshot != expected_state["screenshot"]:
      raise ReviewBoardArtifactError(
        f"review-board screenshot path drift for state {state_id!r}: got {screenshot!r}, "
        f"expected {expected_state['screenshot']!r}"
      )
    if screenshot in seen_screenshots:
      raise ReviewBoardArtifactError(f"review-board reuses screenshot path {screenshot!r}")
    seen_screenshots.add(screenshot)
    if state.get("width", 0) <= 0 or state.get("height", 0) <= 0 or state.get("byteCount", 0) <= 0:
      raise ReviewBoardArtifactError(f"review-board state has invalid dimensions or byte count: {state_id!r}")
    source = root / screenshot_path
    require_real_file(source, f"state source screenshot {screenshot}")
    source_byte_count = source.stat().st_size
    if source_byte_count != state["byteCount"]:
      raise ReviewBoardArtifactError(f"review-board byte count drift for state {state_id!r}: {screenshot}")
    width, height, image_data = inspect_png_artifact(source, f"state source screenshot {state_id!r}", source_byte_count)
    expected_digest = require_sha256_hex_digest(state.get("sha256HexDigest"), f"state {state_id!r}")
    if hashlib.sha256(image_data).hexdigest() != expected_digest:
      raise ReviewBoardArtifactError(f"review-board source digest drift for state {state_id!r}: {screenshot}")
    if width != state["width"] or height != state["height"]:
      raise ReviewBoardArtifactError(f"review-board dimensions drift for state {state_id!r}: {screenshot}")

  html_path = review_dir / "latest-screenshot-review-board.html"
  require_real_file(html_path, "HTML")
  inspect_artifact_freshness(html_path, "HTML", min_mtime_epoch)
  html = read_bounded_utf8(html_path, "HTML", MAX_REVIEW_HTML_BYTES)
  for page_name in page_names:
    if page_name not in html:
      raise ReviewBoardArtifactError(f"review-board HTML does not reference {page_name}")
  for needle in ("Qixi Screenshot Review Board", f"{expected_count} states"):
    if needle not in html:
      raise ReviewBoardArtifactError(f"review-board HTML missing {needle!r}")


def parse_args(argv: list[str]) -> argparse.Namespace:
  parser = argparse.ArgumentParser(description="Inspect generated Qixi screenshot review-board artifacts.")
  parser.add_argument("review_dir", nargs="?", type=pathlib.Path, default=DEFAULT_REVIEW_DIR)
  parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
  return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
  args = parse_args(sys.argv[1:] if argv is None else argv)
  try:
    inspect_review_board(args.review_dir, args.manifest)
  except Exception as exc:
    print(f"Screenshot review-board inspection failed: {exc}", file=sys.stderr)
    return 1
  print(f"Screenshot review-board inspection passed: {args.review_dir}")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
