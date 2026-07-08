#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
import re
import string
import stat as stat_module
from typing import Any


class ScreenshotManifestJSONError(RuntimeError):
  pass


DIMENSION_VALUE_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
MAX_SCREENSHOT_MANIFEST_BYTES = 1024 * 1024


def manifest_placeholders(template: str) -> set[str]:
  formatter = string.Formatter()
  return {name for _, name, _, _ in formatter.parse(template) if name}


def validate_manifest_environment(
  matrix_id: str,
  environment: object,
  *,
  known_dimensions: set[str],
) -> None:
  if not isinstance(environment, dict):
    raise ScreenshotManifestJSONError(f"{matrix_id} environment must be an object")
  for key, value in environment.items():
    if not isinstance(key, str) or key == "":
      raise ScreenshotManifestJSONError(f"{matrix_id} environment keys must be non-empty strings")
    if not key.startswith("QIXI_"):
      raise ScreenshotManifestJSONError(f"{matrix_id} environment variables must begin with QIXI_: {key}")
    if not isinstance(value, str):
      raise ScreenshotManifestJSONError(f"{matrix_id} environment value for {key} must be a string")
    unknown = manifest_placeholders(value) - known_dimensions
    if unknown:
      raise ScreenshotManifestJSONError(
        f"{matrix_id} environment references unknown dimensions in {key}: {sorted(unknown)}"
      )


def validate_manifest_relative_path(
  raw_path: object,
  *,
  matrix_id: str,
  field: str,
  required_prefix: tuple[str, ...] | None = None,
  required_suffix: str | None = None,
) -> pathlib.PurePosixPath:
  if not isinstance(raw_path, str) or raw_path == "":
    raise ScreenshotManifestJSONError(f"{matrix_id} {field} must be a non-empty relative path")
  if raw_path.startswith("/"):
    raise ScreenshotManifestJSONError(f"{matrix_id} {field} must not be absolute: {raw_path}")
  raw_parts = raw_path.split("/")
  if any(part in ("", ".", "..") for part in raw_parts):
    raise ScreenshotManifestJSONError(
      f"{matrix_id} {field} must not contain empty, current-directory, or parent-directory components: {raw_path}"
    )
  path = pathlib.PurePosixPath(raw_path)
  if required_prefix is not None and path.parts[:len(required_prefix)] != required_prefix:
    raise ScreenshotManifestJSONError(
      f"{matrix_id} {field} must stay under {'/'.join(required_prefix)}: {raw_path}"
    )
  if required_suffix is not None and path.suffix != required_suffix:
    raise ScreenshotManifestJSONError(f"{matrix_id} {field} must end with {required_suffix}: {raw_path}")
  return path


def validate_manifest_structure(manifest: object) -> None:
  if not isinstance(manifest, dict):
    raise ScreenshotManifestJSONError("screenshot coverage manifest must be a JSON object")
  if manifest.get("version") != 1:
    raise ScreenshotManifestJSONError("screenshot coverage manifest version must be 1")
  languages = manifest.get("languages")
  if not isinstance(languages, list) or not languages:
    raise ScreenshotManifestJSONError("screenshot coverage manifest languages must be a non-empty list")
  if any(not isinstance(language, str) or language == "" for language in languages):
    raise ScreenshotManifestJSONError("screenshot coverage manifest languages must contain non-empty strings")
  if len(set(languages)) != len(languages):
    raise ScreenshotManifestJSONError("screenshot coverage manifest languages must be unique")
  required_count = manifest.get("requiredStateCount")
  if not isinstance(required_count, int) or isinstance(required_count, bool) or required_count <= 0:
    raise ScreenshotManifestJSONError("screenshot coverage manifest requiredStateCount must be a positive integer")
  matrices = manifest.get("matrices")
  if not isinstance(matrices, list) or not matrices:
    raise ScreenshotManifestJSONError("screenshot coverage manifest matrices must be a non-empty list")

  seen_matrix_ids: set[str] = set()
  for index, matrix in enumerate(matrices):
    if not isinstance(matrix, dict):
      raise ScreenshotManifestJSONError(f"screenshot coverage manifest matrix[{index}] must be an object")
    matrix_id = matrix.get("id")
    if not isinstance(matrix_id, str) or matrix_id == "":
      raise ScreenshotManifestJSONError(f"screenshot coverage manifest matrix[{index}] id must be a non-empty string")
    if matrix_id in seen_matrix_ids:
      raise ScreenshotManifestJSONError(f"screenshot coverage manifest matrix id must be unique: {matrix_id}")
    seen_matrix_ids.add(matrix_id)
    description = matrix.get("description")
    if not isinstance(description, str) or description == "":
      raise ScreenshotManifestJSONError(f"{matrix_id} description must be a non-empty string")
    scripts = matrix.get("scripts")
    if not isinstance(scripts, list) or not scripts:
      raise ScreenshotManifestJSONError(f"{matrix_id} scripts must be a non-empty list")
    if any(not isinstance(script, str) or script == "" for script in scripts):
      raise ScreenshotManifestJSONError(f"{matrix_id} scripts must contain non-empty strings")
    inspector = matrix.get("inspector")
    if not isinstance(inspector, str) or inspector == "":
      raise ScreenshotManifestJSONError(f"{matrix_id} inspector must be a non-empty string")
    inspector_arguments = matrix.get("inspectorArguments", [])
    if not isinstance(inspector_arguments, list):
      raise ScreenshotManifestJSONError(f"{matrix_id} inspectorArguments must be a list")
    if any(not isinstance(argument, str) for argument in inspector_arguments):
      raise ScreenshotManifestJSONError(f"{matrix_id} inspectorArguments must contain strings")
    screenshot = matrix.get("screenshot")
    if not isinstance(screenshot, str) or screenshot == "":
      raise ScreenshotManifestJSONError(f"{matrix_id} screenshot must be a non-empty string")
    dimensions = matrix.get("dimensions")
    if not isinstance(dimensions, dict):
      raise ScreenshotManifestJSONError(f"{matrix_id} dimensions must be an object")
    for dimension_name, values in dimensions.items():
      if not isinstance(dimension_name, str) or dimension_name == "":
        raise ScreenshotManifestJSONError(f"{matrix_id} dimension names must be non-empty strings")
      if not isinstance(values, list) or not values:
        raise ScreenshotManifestJSONError(f"{matrix_id} dimension {dimension_name} must be a non-empty list")
      if any(not isinstance(value, str) or value == "" for value in values):
        raise ScreenshotManifestJSONError(f"{matrix_id} dimension {dimension_name} must contain non-empty strings")
      if len(set(values)) != len(values):
        raise ScreenshotManifestJSONError(f"{matrix_id} dimension {dimension_name} values must be unique")
      for value in values:
        if not DIMENSION_VALUE_RE.fullmatch(value):
          raise ScreenshotManifestJSONError(
            f"{matrix_id} dimension {dimension_name} contains unsafe value {value!r}"
          )
    known_dimensions = set(dimensions)
    unknown = (
      manifest_placeholders(screenshot)
      | manifest_placeholders(inspector)
      | set().union(*(manifest_placeholders(argument) for argument in inspector_arguments))
    ) - known_dimensions
    if unknown:
      raise ScreenshotManifestJSONError(f"{matrix_id} references unknown dimensions: {sorted(unknown)}")
    validate_manifest_environment(
      matrix_id,
      matrix.get("environment", {}),
      known_dimensions=known_dimensions,
    )


def load_manifest_json(path: pathlib.Path) -> dict[str, Any]:
  def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
      if key in result:
        raise ScreenshotManifestJSONError(
          f"screenshot coverage manifest must not contain duplicate JSON key {key!r}"
        )
      result[key] = value
    return result

  def reject_non_standard_constant(value: str) -> None:
    raise ScreenshotManifestJSONError(
      f"screenshot coverage manifest must not contain non-standard JSON constant {value}"
    )

  try:
    try:
      path.lstat()
    except FileNotFoundError as exc:
      raise ScreenshotManifestJSONError(f"screenshot coverage manifest is missing: {path}") from exc
    if path.is_symlink():
      raise ScreenshotManifestJSONError(f"screenshot coverage manifest must not be a symbolic link: {path}")
    if not path.is_file():
      raise ScreenshotManifestJSONError(f"screenshot coverage manifest must be a regular file: {path}")
    byte_count = path.stat().st_size
    if byte_count <= 0:
      raise ScreenshotManifestJSONError(f"screenshot coverage manifest is empty: {path}")
    if byte_count > MAX_SCREENSHOT_MANIFEST_BYTES:
      raise ScreenshotManifestJSONError(
        f"screenshot coverage manifest exceeds {MAX_SCREENSHOT_MANIFEST_BYTES} bytes: {path}"
      )
    with path.open("rb") as handle:
      opened_stat = os.fstat(handle.fileno())
      if not stat_module.S_ISREG(opened_stat.st_mode):
        raise ScreenshotManifestJSONError(f"screenshot coverage manifest must be a regular file: {path}")
      if opened_stat.st_size <= 0:
        raise ScreenshotManifestJSONError(f"screenshot coverage manifest is empty: {path}")
      if opened_stat.st_size > MAX_SCREENSHOT_MANIFEST_BYTES:
        raise ScreenshotManifestJSONError(
          f"screenshot coverage manifest exceeds {MAX_SCREENSHOT_MANIFEST_BYTES} bytes after opening: {path}"
        )
      data = handle.read(MAX_SCREENSHOT_MANIFEST_BYTES + 1)
    if len(data) > MAX_SCREENSHOT_MANIFEST_BYTES:
      raise ScreenshotManifestJSONError(
        f"screenshot coverage manifest exceeds {MAX_SCREENSHOT_MANIFEST_BYTES} bytes while reading: {path}"
      )
    try:
      text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
      raise ScreenshotManifestJSONError(f"screenshot coverage manifest must be UTF-8: {path}") from exc
    payload = json.loads(
      text,
      object_pairs_hook=reject_duplicate_keys,
      parse_constant=reject_non_standard_constant,
    )
  except ScreenshotManifestJSONError:
    raise
  except Exception as exc:
    raise ScreenshotManifestJSONError(f"could not parse screenshot coverage manifest {path}: {exc}") from exc

  if not isinstance(payload, dict):
    raise ScreenshotManifestJSONError("screenshot coverage manifest must be a JSON object")
  return payload
