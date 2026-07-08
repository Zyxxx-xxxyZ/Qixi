#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import io
import itertools
import json
import os
import pathlib
import string
import stat as stat_module
import sys
from dataclasses import dataclass
from typing import Any, Callable

from PIL import Image, ImageDraw, ImageFont, ImageOps


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "tests" / "screenshot_coverage_manifest.json"
DEFAULT_OUTPUT_DIR = ROOT / "artifacts" / "screenshots" / "review-board"
GENERATED_INDEX_FILENAMES = {
  "latest-screenshot-review-board.html",
  "latest-screenshot-review-board.json",
}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_HEADER_BYTES = 33
SCREENSHOT_ARTIFACT_MAX_BYTES = 64 * 1024 * 1024
SCREENSHOT_MAX_PIXELS = 16 * 1024 * 1024
MAX_REVIEW_JSON_BYTES = 4 * 1024 * 1024
MAX_REVIEW_HTML_BYTES = 4 * 1024 * 1024
TESTS_DIR = ROOT / "tests"
if str(TESTS_DIR) not in sys.path:
  sys.path.insert(0, str(TESTS_DIR))

from screenshot_manifest_json import (  # noqa: E402
  MAX_SCREENSHOT_MANIFEST_BYTES,
  ScreenshotManifestJSONError,
  load_manifest_json,
  validate_manifest_environment,
  validate_manifest_relative_path,
  validate_manifest_structure,
)


class ReviewBoardError(RuntimeError):
  pass


ALLOWED_PLATFORM_SYMLINK_ALIASES = {
  pathlib.Path("/var"): pathlib.Path("/private/var"),
  pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
  pathlib.Path("/etc"): pathlib.Path("/private/etc"),
}


@dataclass(frozen=True)
class ScreenshotState:
  state_id: str
  matrix_id: str
  description: str
  screenshot: pathlib.Path
  dimensions: dict[str, str]


@dataclass(frozen=True)
class RenderedPage:
  index: int
  path: pathlib.Path
  state_count: int
  width: int
  height: int
  byte_count: int
  sha256_hex_digest: str


@dataclass(frozen=True)
class ScreenshotMetadata:
  width: int
  height: int
  byte_count: int
  mtime: float
  sha256_hex_digest: str


@dataclass(frozen=True)
class ScreenshotEvidence:
  metadata: ScreenshotMetadata
  image_data: bytes


def normalized_path(path: pathlib.Path) -> pathlib.Path:
  expanded = path.expanduser()
  if expanded.is_absolute():
    return expanded
  return pathlib.Path.cwd() / expanded


def is_allowed_platform_symlink_alias(path: pathlib.Path) -> bool:
  expected_target = ALLOWED_PLATFORM_SYMLINK_ALIASES.get(path)
  if expected_target is None:
    return False
  try:
    return path.resolve(strict=True) == expected_target
  except OSError:
    return False


def reject_symlink_path(path: pathlib.Path, label: str) -> None:
  if path.is_symlink() and not is_allowed_platform_symlink_alias(path):
    raise ReviewBoardError(f"{label} must not contain symbolic links: {path}")


def reject_symlink_components(path: pathlib.Path, label: str) -> pathlib.Path:
  candidate = normalized_path(path)
  current = pathlib.Path(candidate.anchor) if candidate.anchor else pathlib.Path()
  for part in candidate.parts:
    if part == candidate.anchor or not part:
      continue
    if part == "..":
      raise ReviewBoardError(f"{label} must not contain parent-directory traversal: {path}")
    current = current / part
    reject_symlink_path(current, label)
  return candidate


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
    raise ReviewBoardError(f"{label} could not be inspected after opening: {path}: {exc}") from exc
  if not stat_module.S_ISREG(opened_stat.st_mode):
    raise ReviewBoardError(f"{label} must be a regular file after opening: {path}")
  if not allow_empty and opened_stat.st_size <= 0:
    raise ReviewBoardError(f"{label} is empty after opening: {path}")
  if max_bytes is not None and opened_stat.st_size > max_bytes:
    raise ReviewBoardError(f"{label} exceeds {max_bytes} bytes after opening: {path}")
  return opened_stat


def sha256_hex_digest(path: pathlib.Path, label: str, max_bytes: int) -> str:
  digest = hashlib.sha256()
  checked_path = reject_symlink_components(path, label)
  bytes_read = 0
  try:
    with checked_path.open("rb") as handle:
      opened_stat = opened_regular_file_stat(handle, checked_path, label, max_bytes=max_bytes)
      for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        bytes_read += len(chunk)
        if bytes_read > max_bytes:
          raise ReviewBoardError(f"{label} exceeded bounded hash limit of {max_bytes} bytes: {checked_path}")
        digest.update(chunk)
  except OSError as exc:
    raise ReviewBoardError(f"{label} could not be hashed: {checked_path}: {exc}") from exc
  if bytes_read != opened_stat.st_size:
    raise ReviewBoardError(
      f"{label} opened-byte-count drift while hashing: stat={opened_stat.st_size} read={bytes_read} {checked_path}"
    )
  return digest.hexdigest()


def require_atomic_target(path: pathlib.Path, label: str) -> pathlib.Path:
  checked_path = normalized_path(path)
  if any(part == ".." for part in checked_path.parts):
    raise ReviewBoardError(f"{label} must not contain parent-directory traversal: {path}")
  parent = reject_symlink_components(checked_path.parent, f"{label} parent")
  if not parent.exists():
    raise ReviewBoardError(f"{label} parent does not exist: {parent}")
  if not parent.is_dir():
    raise ReviewBoardError(f"{label} parent is not a directory: {parent}")
  try:
    target_stat = checked_path.lstat()
  except FileNotFoundError:
    return checked_path
  if stat_module.S_ISLNK(target_stat.st_mode):
    raise ReviewBoardError(f"{label} target must not be a symbolic link: {checked_path}")
  if stat_module.S_ISDIR(target_stat.st_mode):
    raise ReviewBoardError(f"{label} target must not be a directory-shaped artifact: {checked_path}")
  if not stat_module.S_ISREG(target_stat.st_mode):
    raise ReviewBoardError(f"{label} target must be a regular file when replacing: {checked_path}")
  return checked_path


def atomic_temp_path(target: pathlib.Path, attempt: int) -> pathlib.Path:
  return target.with_name(f".{target.name}.{os.getpid()}.{attempt}.tmp")


def fsync_parent_directory(path: pathlib.Path, label: str) -> None:
  parent = reject_symlink_components(path.parent, f"{label} parent after atomic replace")
  flags = os.O_RDONLY
  if hasattr(os, "O_CLOEXEC"):
    flags |= os.O_CLOEXEC
  if hasattr(os, "O_DIRECTORY"):
    flags |= os.O_DIRECTORY
  parent_fd: int | None = None
  try:
    parent_fd = os.open(parent, flags)
    os.fsync(parent_fd)
  except OSError as exc:
    raise ReviewBoardError(f"{label} could not fsync parent directory after atomic replace: {parent}: {exc}") from exc
  finally:
    if parent_fd is not None:
      try:
        os.close(parent_fd)
      except OSError:
        pass


def write_atomic_artifact(
  path: pathlib.Path,
  label: str,
  max_bytes: int,
  write_payload: Callable[[Any], None],
  *,
  expected_byte_count: int | None = None,
) -> None:
  if max_bytes <= 0:
    raise ReviewBoardError(f"{label} has invalid byte budget")
  if expected_byte_count is not None and expected_byte_count > max_bytes:
    raise ReviewBoardError(f"{label} expected byte count exceeds {max_bytes}: {expected_byte_count}")
  target = require_atomic_target(path, label)
  flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
  if hasattr(os, "O_CLOEXEC"):
    flags |= os.O_CLOEXEC
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW

  fd: int | None = None
  tmp_path: pathlib.Path | None = None
  try:
    for attempt in range(100):
      candidate = atomic_temp_path(target, attempt)
      reject_symlink_components(candidate, f"{label} atomic-write temporary path")
      try:
        fd = os.open(candidate, flags, 0o600)
      except FileExistsError:
        continue
      tmp_path = candidate
      break
    if fd is None or tmp_path is None:
      raise ReviewBoardError(f"{label} could not allocate an atomic-write temporary file: {target}")

    with os.fdopen(fd, "wb") as handle:
      fd = None
      write_payload(handle)
      handle.flush()
      os.fsync(handle.fileno())
      temporary_stat = opened_regular_file_stat(
        handle,
        tmp_path,
        f"{label} atomic-write temporary file",
        max_bytes=max_bytes,
      )
      if expected_byte_count is not None and temporary_stat.st_size != expected_byte_count:
        raise ReviewBoardError(
          f"{label} byte count drift after writing: "
          f"expected {expected_byte_count} bytes, wrote {temporary_stat.st_size} bytes"
        )

    require_atomic_target(target, label)
    os.replace(tmp_path, target)
    fsync_parent_directory(target, label)
    tmp_path = None
  except ReviewBoardError:
    raise
  except OSError as exc:
    raise ReviewBoardError(f"{label} could not be written atomically: {target}: {exc}") from exc
  finally:
    if fd is not None:
      try:
        os.close(fd)
      except OSError:
        pass
    if tmp_path is not None:
      try:
        tmp_path.unlink()
      except OSError:
        pass


def write_atomic_bytes(path: pathlib.Path, data: bytes, label: str, max_bytes: int) -> None:
  if not data:
    raise ReviewBoardError(f"{label} payload is empty")
  if len(data) > max_bytes:
    raise ReviewBoardError(f"{label} payload exceeds {max_bytes} bytes before writing: {path}")

  def write_payload(handle: Any) -> None:
    handle.write(data)

  write_atomic_artifact(path, label, max_bytes, write_payload, expected_byte_count=len(data))


def write_atomic_text(path: pathlib.Path, text: str, label: str, max_bytes: int) -> None:
  write_atomic_bytes(path, text.encode("utf-8"), label, max_bytes)


def cleanup_review_board_artifacts(output_dir: pathlib.Path) -> None:
  checked_output_dir = reject_symlink_components(output_dir, "review-board output path")
  checked_output_dir.mkdir(parents=True, exist_ok=True)
  checked_output_dir = reject_symlink_components(checked_output_dir, "review-board output path")
  if checked_output_dir.is_symlink():
    raise ReviewBoardError(f"review-board output path must not be a symbolic link: {checked_output_dir}")
  if not checked_output_dir.is_dir():
    raise ReviewBoardError(f"review-board output path is not a directory: {checked_output_dir}")

  candidates = [checked_output_dir / name for name in GENERATED_INDEX_FILENAMES]
  candidates.extend(sorted(checked_output_dir.glob("latest-screenshot-review-board-page-*.png")))
  for path in candidates:
    try:
      path.lstat()
    except FileNotFoundError:
      continue
    if path.is_dir() and not path.is_symlink():
      raise ReviewBoardError(f"refusing to remove directory-shaped review-board artifact: {path}")
    if path.is_symlink() or path.is_file():
      path.unlink()
      continue
    raise ReviewBoardError(f"refusing to remove non-file review-board artifact: {path}")


def placeholders(template: str) -> set[str]:
  formatter = string.Formatter()
  return {name for _, name, _, _ in formatter.parse(template) if name}


def render_template(template: str, values: dict[str, str]) -> str:
  try:
    return template.format(**values)
  except KeyError as exc:
    raise ReviewBoardError(f"template {template!r} references unknown dimension {exc}") from exc


def declared_screenshot_path(matrix_id: str, rendered_screenshot: str, root: pathlib.Path) -> pathlib.Path:
  try:
    path = validate_manifest_relative_path(
      rendered_screenshot,
      matrix_id=matrix_id,
      field="screenshot",
      required_prefix=("artifacts", "screenshots"),
      required_suffix=".png",
    )
  except ScreenshotManifestJSONError as exc:
    raise ReviewBoardError(str(exc)) from exc
  return root / pathlib.Path(*path.parts)


def dimension_rows(dimensions: dict[str, list[str]]) -> list[dict[str, str]]:
  names = list(dimensions)
  return [
    dict(zip(names, values, strict=True))
    for values in itertools.product(*(dimensions[name] for name in names))
  ]


def expanded_states(manifest: dict, root: pathlib.Path) -> list[ScreenshotState]:
  try:
    validate_manifest_structure(manifest)
  except ScreenshotManifestJSONError as exc:
    raise ReviewBoardError(str(exc)) from exc
  states: list[ScreenshotState] = []
  for matrix in manifest.get("matrices", []):
    matrix_id = matrix.get("id", "<missing-id>")
    description = str(matrix.get("description", ""))
    dimensions = matrix.get("dimensions", {})
    screenshot_template = matrix.get("screenshot", "")
    if not isinstance(dimensions, dict):
      raise ReviewBoardError(f"{matrix_id} dimensions must be an object")
    if not isinstance(screenshot_template, str) or not screenshot_template:
      raise ReviewBoardError(f"{matrix_id} screenshot must be a non-empty string")

    unknown = placeholders(screenshot_template) - set(dimensions)
    if unknown:
      raise ReviewBoardError(f"{matrix_id} references unknown dimensions: {sorted(unknown)}")
    try:
      validate_manifest_environment(
        str(matrix_id),
        matrix.get("environment", {}),
        known_dimensions=set(dimensions),
      )
    except ScreenshotManifestJSONError as exc:
      raise ReviewBoardError(str(exc)) from exc

    for row in dimension_rows(dimensions):
      state_id = "-".join([matrix_id, *[row[name] for name in dimensions]])
      screenshot = declared_screenshot_path(str(matrix_id), render_template(screenshot_template, row), root)
      states.append(
        ScreenshotState(
          state_id=state_id,
          matrix_id=str(matrix_id),
          description=description,
          screenshot=screenshot,
          dimensions=row,
        )
      )
  return states


def inspect_png_header(state: ScreenshotState, stat: os.stat_result, root: pathlib.Path) -> tuple[bytes, tuple[int, int], os.stat_result]:
  relative = state.screenshot.relative_to(root)
  if stat.st_size > SCREENSHOT_ARTIFACT_MAX_BYTES:
    raise ReviewBoardError(
      f"{state.state_id} screenshot artifact exceeds byte budget: "
      f"{relative} size={stat.st_size} max={SCREENSHOT_ARTIFACT_MAX_BYTES}"
    )
  with state.screenshot.open("rb") as handle:
    opened_stat = opened_regular_file_stat(
      handle,
      state.screenshot,
      f"{state.state_id} screenshot artifact",
      max_bytes=SCREENSHOT_ARTIFACT_MAX_BYTES,
    )
    if opened_stat.st_size != stat.st_size:
      raise ReviewBoardError(f"{state.state_id} screenshot artifact byte count drift after opening: {relative}")
    image_data = handle.read(SCREENSHOT_ARTIFACT_MAX_BYTES + 1)
  if len(image_data) > SCREENSHOT_ARTIFACT_MAX_BYTES:
    raise ReviewBoardError(
      f"{state.state_id} screenshot artifact exceeded bounded image read limit of "
      f"{SCREENSHOT_ARTIFACT_MAX_BYTES} bytes: {relative}"
    )
  if len(image_data) != opened_stat.st_size:
    raise ReviewBoardError(
      f"{state.state_id} screenshot artifact opened-byte-count drift while reading: "
      f"stat={opened_stat.st_size} read={len(image_data)} {relative}"
    )
  header = image_data[:PNG_HEADER_BYTES]
  if len(header) < PNG_HEADER_BYTES or header[: len(PNG_SIGNATURE)] != PNG_SIGNATURE:
    raise ReviewBoardError(f"{state.state_id} screenshot artifact must be a PNG file: {relative}")
  ihdr_length = int.from_bytes(header[8:12], "big")
  ihdr_kind = header[12:16]
  if ihdr_length != 13 or ihdr_kind != b"IHDR":
    raise ReviewBoardError(f"{state.state_id} screenshot artifact must have a valid PNG IHDR: {relative}")
  width = int.from_bytes(header[16:20], "big")
  height = int.from_bytes(header[20:24], "big")
  if width <= 0 or height <= 0:
    raise ReviewBoardError(f"{state.state_id} screenshot artifact has invalid PNG dimensions: {relative}")
  if width * height > SCREENSHOT_MAX_PIXELS:
    raise ReviewBoardError(
      f"{state.state_id} screenshot artifact is too large for bounded review-board rendering: "
      f"{width}x{height} {relative}"
    )
  return image_data, (width, height), opened_stat


def inspect_png_decodes(state: ScreenshotState, image_data: bytes, expected_size: tuple[int, int], root: pathlib.Path) -> None:
  relative = state.screenshot.relative_to(root)
  try:
    with Image.open(io.BytesIO(image_data)) as image:
      decoded_size = image.size
      image_format = image.format
      image.verify()
  except Exception as exc:
    raise ReviewBoardError(
      f"{state.state_id} screenshot artifact must be a decodable PNG image: {relative}: {exc}"
    ) from exc
  if image_format != "PNG":
    raise ReviewBoardError(f"{state.state_id} screenshot artifact must decode as PNG: {relative}")
  if decoded_size != expected_size:
    raise ReviewBoardError(
      f"{state.state_id} screenshot artifact decoded dimensions do not match PNG IHDR: "
      f"decoded={decoded_size[0]}x{decoded_size[1]} ihdr={expected_size[0]}x{expected_size[1]} {relative}"
    )


def inspect_screenshot_evidence(state: ScreenshotState, root: pathlib.Path) -> ScreenshotEvidence:
  reject_symlink_components(state.screenshot, f"{state.state_id} screenshot artifact")
  if not state.screenshot.exists():
    raise ReviewBoardError(f"{state.state_id} missing screenshot artifact: {state.screenshot.relative_to(root)}")
  if state.screenshot.is_symlink():
    raise ReviewBoardError(f"{state.state_id} screenshot artifact must not be a symbolic link: {state.screenshot.relative_to(root)}")
  if not state.screenshot.is_file():
    raise ReviewBoardError(f"{state.state_id} screenshot artifact is not a file: {state.screenshot.relative_to(root)}")
  stat = state.screenshot.stat()
  if stat.st_size <= 0:
    raise ReviewBoardError(f"{state.state_id} screenshot artifact is empty: {state.screenshot.relative_to(root)}")
  image_data, size, opened_stat = inspect_png_header(state, stat, root)
  inspect_png_decodes(state, image_data, size, root)
  return ScreenshotEvidence(
    metadata=ScreenshotMetadata(
      width=size[0],
      height=size[1],
      byte_count=len(image_data),
      mtime=opened_stat.st_mtime,
      sha256_hex_digest=hashlib.sha256(image_data).hexdigest(),
    ),
    image_data=image_data,
  )


def require_complete_artifacts(states: list[ScreenshotState], root: pathlib.Path) -> dict[pathlib.Path, ScreenshotMetadata]:
  seen: set[pathlib.Path] = set()
  metadata: dict[pathlib.Path, ScreenshotMetadata] = {}
  for state in states:
    if state.screenshot in seen:
      raise ReviewBoardError(f"{state.state_id} reuses screenshot artifact: {state.screenshot.relative_to(root)}")
    seen.add(state.screenshot)
    metadata[state.screenshot] = inspect_screenshot_evidence(state, root).metadata
  return metadata


def wrapped_lines(text: str, max_chars: int) -> list[str]:
  words = text.split()
  if not words:
    return [""]
  lines: list[str] = []
  current = words[0]
  for word in words[1:]:
    if len(current) + 1 + len(word) <= max_chars:
      current += " " + word
    else:
      lines.append(current)
      current = word
  lines.append(current)
  return lines


def relative_to(path: pathlib.Path, base: pathlib.Path) -> str:
  try:
    return str(path.relative_to(base))
  except ValueError:
    return str(path)


def render_pages(
  states: list[ScreenshotState],
  *,
  root: pathlib.Path,
  output_dir: pathlib.Path,
  columns: int,
  rows: int,
  thumbnail_width: int,
  thumbnail_height: int,
) -> tuple[list[RenderedPage], dict[pathlib.Path, ScreenshotMetadata]]:
  checked_output_dir = reject_symlink_components(output_dir, "review-board output directory")
  checked_output_dir.mkdir(parents=True, exist_ok=True)
  checked_output_dir = reject_symlink_components(checked_output_dir, "review-board output directory")
  page_size = columns * rows
  if page_size <= 0:
    raise ReviewBoardError("columns * rows must be positive")

  font = ImageFont.load_default()
  header_font = ImageFont.load_default()
  padding = 16
  label_height = 64
  header_height = 54
  cell_width = thumbnail_width + padding * 2
  cell_height = thumbnail_height + label_height + padding * 2
  page_width = columns * cell_width
  page_height = header_height + rows * cell_height
  pages: list[RenderedPage] = []
  source_metadata: dict[pathlib.Path, ScreenshotMetadata] = {}

  total_pages = (len(states) + page_size - 1) // page_size
  for page_index in range(total_pages):
    page_states = states[page_index * page_size : (page_index + 1) * page_size]
    page = Image.new("RGB", (page_width, page_height), (246, 243, 236))
    draw = ImageDraw.Draw(page)
    draw.rectangle((0, 0, page_width, header_height), fill=(230, 224, 214))
    draw.text(
      (padding, 18),
      f"Qixi screenshot review board page {page_index + 1}/{total_pages} - {len(states)} states",
      fill=(30, 32, 36),
      font=header_font,
    )

    for index in range(page_size):
      col = index % columns
      row = index // columns
      x = col * cell_width + padding
      y = header_height + row * cell_height + padding
      frame_x0 = x
      frame_y0 = y
      frame_x1 = x + thumbnail_width
      frame_y1 = y + thumbnail_height
      draw.rectangle((frame_x0 - 1, frame_y0 - 1, frame_x1 + 1, frame_y1 + 1), fill=(222, 217, 207))
      draw.rectangle((frame_x0, frame_y0, frame_x1, frame_y1), fill=(255, 255, 255))
      if index >= len(page_states):
        draw.rectangle((frame_x0, frame_y0, frame_x1, frame_y1), fill=(250, 248, 242))
        slot = page_index * page_size + index + 1
        for offset in range(-thumbnail_height, thumbnail_width, 12):
          shade = 226 + ((slot + offset // 12) % 4) * 4
          draw.line(
            (frame_x0 + offset, frame_y1, frame_x0 + offset + thumbnail_height, frame_y0),
            fill=(shade, max(218, shade - 9), 205),
          )
        for offset in range(0, thumbnail_width + thumbnail_height, 28):
          shade = 236 - ((slot + offset // 28) % 3) * 5
          draw.line(
            (frame_x0 + offset - thumbnail_height, frame_y0, frame_x0 + offset, frame_y1),
            fill=(shade, shade, max(214, shade - 14)),
          )
        draw.text(
          (x, y + thumbnail_height + 8),
          f"empty review slot {slot}",
          fill=(115, 110, 100),
          font=font,
        )
        continue

      state = page_states[index]
      evidence = inspect_screenshot_evidence(state, root)
      source_metadata[state.screenshot] = evidence.metadata
      with Image.open(io.BytesIO(evidence.image_data)) as image:
        thumb = ImageOps.contain(image.convert("RGB"), (thumbnail_width, thumbnail_height))
      image_x = x + (thumbnail_width - thumb.width) // 2
      image_y = y + (thumbnail_height - thumb.height) // 2
      page.paste(thumb, (image_x, image_y))

      label_y = y + thumbnail_height + 8
      label = f"{state.state_id}  {state.screenshot.name}"
      for line in wrapped_lines(label, 45)[:3]:
        draw.text((x, label_y), line, fill=(36, 39, 44), font=font)
        label_y += 14

    page_path = checked_output_dir / f"latest-screenshot-review-board-page-{page_index + 1:02d}.png"
    page_buffer = io.BytesIO()
    page.save(page_buffer, format="PNG")
    page_data = page_buffer.getvalue()
    write_atomic_bytes(
      page_path,
      page_data,
      f"review-board page image {page_path.name}",
      SCREENSHOT_ARTIFACT_MAX_BYTES,
    )
    pages.append(
      RenderedPage(
        index=page_index + 1,
        path=page_path,
        state_count=len(page_states),
        width=page_width,
        height=page_height,
        byte_count=len(page_data),
        sha256_hex_digest=hashlib.sha256(page_data).hexdigest(),
      )
    )
  return pages, source_metadata


def write_index_files(
  states: list[ScreenshotState],
  pages: list[RenderedPage],
  *,
  root: pathlib.Path,
  manifest_path: pathlib.Path,
  output_dir: pathlib.Path,
  source_metadata: dict[pathlib.Path, ScreenshotMetadata],
) -> tuple[pathlib.Path, pathlib.Path]:
  generated_at = dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
  state_rows = []
  for state in states:
    metadata = source_metadata[state.screenshot]
    state_rows.append(
      {
        "id": state.state_id,
        "matrixId": state.matrix_id,
        "description": state.description,
        "dimensions": state.dimensions,
        "screenshot": relative_to(state.screenshot, root),
        "width": metadata.width,
        "height": metadata.height,
        "byteCount": metadata.byte_count,
        "mtime": metadata.mtime,
        "sha256HexDigest": metadata.sha256_hex_digest,
      }
    )

  payload = {
    "schemaVersion": 1,
    "generatedAt": generated_at,
    "manifest": relative_to(manifest_path, root),
    "manifestSha256HexDigest": sha256_hex_digest(
      manifest_path,
      "screenshot coverage manifest",
      MAX_SCREENSHOT_MANIFEST_BYTES,
    ),
    "stateCount": len(states),
    "pageCount": len(pages),
    "pages": [
      {
        "index": page.index,
        "path": relative_to(page.path, output_dir),
        "stateCount": page.state_count,
        "width": page.width,
        "height": page.height,
        "byteCount": page.byte_count,
        "sha256HexDigest": page.sha256_hex_digest,
      }
      for page in pages
    ],
    "states": state_rows,
  }
  json_path = output_dir / "latest-screenshot-review-board.json"
  write_atomic_text(
    json_path,
    json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n",
    "review-board JSON index",
    MAX_REVIEW_JSON_BYTES,
  )

  html_path = output_dir / "latest-screenshot-review-board.html"
  page_items = "\n".join(
    f'<section><h2>Page {page.index}</h2><img src="{html.escape(page.path.name)}" alt="Review board page {page.index}"></section>'
    for page in pages
  )
  state_items = "\n".join(
    f"<li><code>{html.escape(row['id'])}</code> "
    f"<span>{html.escape(row['screenshot'])}</span> "
    f"<small>{row['width']}x{row['height']}</small></li>"
    for row in state_rows
  )
  write_atomic_text(
    html_path,
    "\n".join(
      [
        "<!doctype html>",
        "<meta charset=\"utf-8\">",
        "<title>Qixi Screenshot Review Board</title>",
        "<style>",
        "body{margin:24px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;background:#f6f3ec;color:#20242a}",
        "img{max-width:100%;height:auto;border:1px solid #d8d1c4}",
        "section{margin:0 0 28px}",
        "li{margin:4px 0}",
        "code{font-weight:600}",
        "small{color:#667085}",
        "</style>",
        f"<h1>Qixi Screenshot Review Board</h1>",
        f"<p>Generated {html.escape(generated_at)} from <code>{html.escape(relative_to(manifest_path, root))}</code>.</p>",
        f"<p>{len(states)} states across {len(pages)} page images.</p>",
        page_items,
        "<h2>States</h2>",
        "<ol>",
        state_items,
        "</ol>",
      ]
    )
    + "\n",
    "review-board HTML index",
    MAX_REVIEW_HTML_BYTES,
  )
  return json_path, html_path


def build_review_board(
  *,
  root: pathlib.Path,
  manifest_path: pathlib.Path,
  output_dir: pathlib.Path,
  columns: int,
  rows: int,
  thumbnail_width: int,
  thumbnail_height: int,
) -> tuple[list[RenderedPage], pathlib.Path, pathlib.Path]:
  checked_output_dir = reject_symlink_components(output_dir, "review-board output path")
  manifest = load_manifest_json(manifest_path)
  states = expanded_states(manifest, root)
  expected_count = manifest.get("requiredStateCount")
  if len(states) != expected_count:
    raise ReviewBoardError(f"manifest expands to {len(states)} states, expected requiredStateCount={expected_count}")
  require_complete_artifacts(states, root)
  cleanup_review_board_artifacts(checked_output_dir)
  pages, source_metadata = render_pages(
    states,
    root=root,
    output_dir=checked_output_dir,
    columns=columns,
    rows=rows,
    thumbnail_width=thumbnail_width,
    thumbnail_height=thumbnail_height,
  )
  json_path, html_path = write_index_files(
    states,
    pages,
    root=root,
    manifest_path=manifest_path,
    output_dir=checked_output_dir,
    source_metadata=source_metadata,
  )
  return pages, json_path, html_path


def parse_args(argv: list[str]) -> argparse.Namespace:
  parser = argparse.ArgumentParser(description="Build a paginated Qixi screenshot review board from the screenshot coverage manifest.")
  parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
  parser.add_argument("--output-dir", type=pathlib.Path, default=DEFAULT_OUTPUT_DIR)
  parser.add_argument("--columns", type=int, default=4)
  parser.add_argument("--rows", type=int, default=5)
  parser.add_argument("--thumbnail-width", type=int, default=360)
  parser.add_argument("--thumbnail-height", type=int, default=240)
  return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
  args = parse_args(sys.argv[1:] if argv is None else argv)
  try:
    pages, json_path, html_path = build_review_board(
      root=ROOT,
      manifest_path=args.manifest,
      output_dir=args.output_dir,
      columns=args.columns,
      rows=args.rows,
      thumbnail_width=args.thumbnail_width,
      thumbnail_height=args.thumbnail_height,
    )
  except Exception as exc:
    print(f"Screenshot review board generation failed: {exc}", file=sys.stderr)
    return 1
  print(f"Screenshot review board generated: {len(pages)} pages")
  print(json_path)
  print(html_path)
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
