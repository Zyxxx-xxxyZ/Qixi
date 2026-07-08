#!/usr/bin/env python3
from __future__ import annotations

import os
import pathlib
import stat as stat_module
import sys


ALLOWED_PLATFORM_SYMLINK_ALIASES = {
  pathlib.Path("/var"): pathlib.Path("/private/var"),
  pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
  pathlib.Path("/etc"): pathlib.Path("/private/etc"),
}
MARKER_BYTES = b"qixi-build-marker\n"


class ProtectedBuildMarkerError(RuntimeError):
  pass


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


def reject_symlink_components(path: pathlib.Path, label: str) -> pathlib.Path:
  candidate = normalized_path(path)
  current = pathlib.Path(candidate.anchor) if candidate.anchor else pathlib.Path()
  for part in candidate.parts:
    if part == candidate.anchor or not part or part == ".":
      continue
    if part == "..":
      raise ProtectedBuildMarkerError(f"{label} path must not contain parent-directory traversal: {candidate}")
    current = current / part
    if current.is_symlink() and not is_allowed_platform_symlink_alias(current):
      raise ProtectedBuildMarkerError(f"{label} path must not contain symbolic links: {current}")
  return candidate


def canonicalize_allowed_platform_alias_prefix(path: pathlib.Path) -> pathlib.Path:
  candidate = normalized_path(path)
  for alias, target in ALLOWED_PLATFORM_SYMLINK_ALIASES.items():
    try:
      suffix = candidate.relative_to(alias)
    except ValueError:
      continue
    if is_allowed_platform_symlink_alias(alias):
      return target / suffix
  return candidate


def prepare_marker_target(path: pathlib.Path, label: str) -> pathlib.Path:
  checked_path = reject_symlink_components(path, label)
  marker_path = canonicalize_allowed_platform_alias_prefix(checked_path)
  reject_symlink_components(checked_path.parent, f"{label} parent")
  reject_symlink_components(marker_path.parent, f"{label} canonical parent")
  if not marker_path.parent.is_dir():
    raise ProtectedBuildMarkerError(f"{label} parent does not exist: {marker_path.parent}")
  try:
    existing = marker_path.lstat()
  except FileNotFoundError:
    return marker_path
  if stat_module.S_ISLNK(existing.st_mode):
    raise ProtectedBuildMarkerError(f"{label} must not be a symbolic link: {marker_path}")
  if not stat_module.S_ISREG(existing.st_mode):
    raise ProtectedBuildMarkerError(f"{label} exists but is not a regular file: {marker_path}")
  return marker_path


def fsync_parent_directory(path: pathlib.Path, label: str) -> None:
  flags = os.O_RDONLY
  if hasattr(os, "O_DIRECTORY"):
    flags |= os.O_DIRECTORY
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
  parent_fd = os.open(path.parent, flags)
  try:
    os.fsync(parent_fd)
  except OSError as exc:
    raise ProtectedBuildMarkerError(f"{label} could not fsync parent directory after atomic replace: {exc}") from exc
  finally:
    os.close(parent_fd)


def write_marker(path: pathlib.Path, label: str) -> pathlib.Path:
  marker_path = prepare_marker_target(path, label)
  tmp_path = marker_path.with_name(f".{marker_path.name}.{os.getpid()}.tmp")
  flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW

  fd: int | None = None
  try:
    fd = os.open(tmp_path, flags, 0o600)
    written = 0
    view = memoryview(MARKER_BYTES)
    while written < len(MARKER_BYTES):
      written += os.write(fd, view[written:])
    written_stat = os.fstat(fd)
    if not stat_module.S_ISREG(written_stat.st_mode):
      raise ProtectedBuildMarkerError(f"{label} temporary marker must be regular: {tmp_path}")
    if written_stat.st_size != len(MARKER_BYTES):
      raise ProtectedBuildMarkerError(
        f"{label} byte count drift after writing: expected {len(MARKER_BYTES)} got {written_stat.st_size}"
      )
    os.fsync(fd)
    os.close(fd)
    fd = None
    prepare_marker_target(marker_path, label)
    os.replace(tmp_path, marker_path)
    fsync_parent_directory(marker_path, label)
  except OSError as exc:
    raise ProtectedBuildMarkerError(f"{label} could not be written atomically: {exc}") from exc
  finally:
    if fd is not None:
      os.close(fd)
    try:
      if tmp_path.exists() or tmp_path.is_symlink():
        tmp_path.unlink()
    except OSError:
      pass
  return marker_path


def main(argv: list[str]) -> int:
  if len(argv) != 3:
    print("usage: protected_build_marker.py <marker-path> <label>", file=sys.stderr)
    return 2
  try:
    marker_path = write_marker(pathlib.Path(argv[1]), argv[2])
  except ProtectedBuildMarkerError as exc:
    print(f"Protected build marker failed: {exc}", file=sys.stderr)
    return 3
  print(marker_path)
  return 0


if __name__ == "__main__":
  raise SystemExit(main(sys.argv))
