#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import hashlib
import io
import json
import os
import pathlib
import sys
import tempfile
import time
import unittest
from unittest import mock

from PIL import Image


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "build_screenshot_review_board.py"
INSPECTOR = ROOT / "tests" / "inspect_screenshot_review_board.py"


def load_builder_module():
  spec = importlib.util.spec_from_file_location("build_screenshot_review_board", SCRIPT)
  if spec is None or spec.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
  module = importlib.util.module_from_spec(spec)
  sys.modules[spec.name] = module
  spec.loader.exec_module(module)
  return module


def load_inspector_module():
  spec = importlib.util.spec_from_file_location("inspect_screenshot_review_board", INSPECTOR)
  if spec is None or spec.loader is None:
    raise RuntimeError(f"could not load {INSPECTOR}")
  module = importlib.util.module_from_spec(spec)
  sys.modules[spec.name] = module
  spec.loader.exec_module(module)
  return module


class DriftHandle:
  def __init__(self, backing_file: pathlib.Path) -> None:
    self.fd = os.open(backing_file, os.O_RDONLY)
    self.did_read = False

  def fileno(self) -> int:
    return self.fd

  def read(self, _size: int = -1) -> bytes:
    if self.did_read:
      return b""
    self.did_read = True
    return b""

  def __enter__(self) -> "DriftHandle":
    return self

  def __exit__(self, _exc_type: object, _exc: object, _traceback: object) -> None:
    os.close(self.fd)


def write_png(path: pathlib.Path, color: tuple[int, int, int]) -> None:
  path.parent.mkdir(parents=True, exist_ok=True)
  Image.new("RGB", (120, 80), color).save(path)


def sha256_hex_digest(path: pathlib.Path) -> str:
  digest = hashlib.sha256()
  with path.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
      digest.update(chunk)
  return digest.hexdigest()


def png_header_fixture(builder: object, *, width: int, height: int, ihdr_length: int = 13) -> bytes:
  return b"".join(
    [
      builder.PNG_SIGNATURE,
      ihdr_length.to_bytes(4, "big"),
      b"IHDR",
      width.to_bytes(4, "big"),
      height.to_bytes(4, "big"),
      b"\x08\x02\x00\x00\x00",
      b"\x00\x00\x00\x00",
    ]
  )


def padded_png_header_fixture(module: object, *, width: int, height: int, minimum_size: int) -> bytes:
  data = png_header_fixture(module, width=width, height=height)
  return data + (b"\0" * max(0, minimum_size - len(data)))


def write_detailed_png(path: pathlib.Path, seed: int) -> None:
  path.parent.mkdir(parents=True, exist_ok=True)
  width = 720
  height = 540
  image = Image.new("RGB", (width, height))
  pixels = image.load()
  for y in range(height):
    for x in range(width):
      pixels[x, y] = (
        (x * 3 + y + seed * 17) % 256,
        (x + y * 2 + seed * 29) % 256,
        (x * 5 + y * 7 + seed * 11) % 256,
      )
  image.save(path)


def write_manifest(
  root: pathlib.Path,
  *,
  duplicate_path: bool = False,
  required_count: int = 2,
  screenshot: str | None = None,
  environment: object | None = None,
) -> pathlib.Path:
  manifest = {
    "version": 1,
    "languages": ["zh-Hans", "en"],
    "requiredStateCount": required_count,
    "matrices": [
      {
        "id": "tiny-main",
        "description": "Tiny review-board fixture.",
        "scripts": ["scripts/screenshot-sim.sh"],
        "inspector": "tests/inspect_screenshot.py",
        "dimensions": {
          "language": ["zh-Hans", "en"],
        },
        "screenshot": screenshot if screenshot is not None else (
          "artifacts/screenshots/reused.png"
          if duplicate_path
          else "artifacts/screenshots/tiny-{language}.png"
        ),
        "environment": environment if environment is not None else {"QIXI_APP_LANGUAGE": "{language}"},
      }
    ],
  }
  manifest_path = root / "tests" / "screenshot_coverage_manifest.json"
  manifest_path.parent.mkdir(parents=True, exist_ok=True)
  manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
  return manifest_path


class ScreenshotReviewBoardTests(unittest.TestCase):
  def test_builds_paginated_review_board_from_manifest(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", (30, 90, 160))
      write_png(root / "artifacts" / "screenshots" / "tiny-en.png", (160, 90, 30))

      pages, json_path, html_path = builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=root / "review",
        columns=1,
        rows=1,
        thumbnail_width=80,
        thumbnail_height=60,
      )

      self.assertEqual(len(pages), 2)
      self.assertTrue(html_path.exists())
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      self.assertEqual(payload["schemaVersion"], 1)
      self.assertRegex(payload["generatedAt"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$")
      self.assertRegex(payload["manifestSha256HexDigest"], r"^[0-9a-f]{64}$")
      self.assertEqual(payload["stateCount"], 2)
      self.assertEqual(payload["pageCount"], 2)
      self.assertEqual([state["id"] for state in payload["states"]], ["tiny-main-zh-Hans", "tiny-main-en"])
      self.assertEqual(payload["states"][0]["width"], 120)
      self.assertEqual(payload["states"][0]["height"], 80)
      self.assertRegex(payload["states"][0]["sha256HexDigest"], r"^[0-9a-f]{64}$")
      self.assertRegex(payload["pages"][0]["sha256HexDigest"], r"^[0-9a-f]{64}$")
      self.assertGreater(payload["pages"][0]["byteCount"], 0)
      self.assertGreater(payload["pages"][0]["width"], 0)
      self.assertGreater(payload["pages"][0]["height"], 0)
      for page in pages:
        self.assertTrue(page.path.exists())
        self.assertGreater(page.path.stat().st_size, 0)

  def test_generated_review_board_artifacts_pass_inspection(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"

      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )

      inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_builder_and_inspector_reject_bad_manifest_environment(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root, environment={"QIXI_APP_LANGUAGE": "{locale}"})
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)

      with self.assertRaisesRegex(builder.ReviewBoardError, "environment references unknown dimensions"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=root / "review",
          columns=3,
          rows=4,
          thumbnail_width=360,
          thumbnail_height=240,
        )
      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "environment references unknown dimensions"):
        inspector.expected_states_from_manifest(manifest_path)

  def test_review_board_builder_and_inspector_reject_empty_manifest_matrix_even_with_zero_count(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = root / "tests" / "screenshot_coverage_manifest.json"
      manifest_path.parent.mkdir(parents=True, exist_ok=True)
      manifest_path.write_text(
        json.dumps(
          {
            "version": 1,
            "languages": ["en"],
            "requiredStateCount": 0,
            "matrices": [],
          }
        ),
        encoding="utf-8",
      )

      with self.assertRaisesRegex(builder.ReviewBoardError, "requiredStateCount must be a positive integer"):
        builder.expanded_states(builder.load_manifest_json(manifest_path), root)
      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "requiredStateCount must be a positive integer"):
        inspector.expected_states_from_manifest(manifest_path)

  def test_review_board_builder_and_inspector_reject_unsafe_manifest_screenshot_paths(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    for unsafe in (
      "/tmp/tiny-{language}.png",
      "../artifacts/screenshots/tiny-{language}.png",
      "artifacts/screenshots//tiny-{language}.png",
      "artifacts/screenshots/./tiny-{language}.png",
      "artifacts/tiny-{language}.png",
      "artifacts/screenshots/tiny-{language}.jpg",
    ):
      with self.subTest(unsafe=unsafe):
        with tempfile.TemporaryDirectory() as tmp:
          root = pathlib.Path(tmp)
          manifest_path = write_manifest(root, screenshot=unsafe)
          with self.assertRaisesRegex(builder.ReviewBoardError, "screenshot must"):
            builder.expanded_states(builder.load_manifest_json(manifest_path), root)
          with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "screenshot must"):
            inspector.expected_states_from_manifest(manifest_path)

  def test_tail_review_board_page_with_one_state_stays_inspectable(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      slots = [f"{index:02d}" for index in range(13)]
      manifest = {
        "version": 1,
        "languages": ["en"],
        "requiredStateCount": len(slots),
        "matrices": [
          {
            "id": "tail-page",
            "description": "Forces a one-state final review-board page.",
            "scripts": ["scripts/screenshot-sim.sh"],
            "inspector": "tests/inspect_screenshot.py",
            "dimensions": {"slot": slots},
            "screenshot": "artifacts/screenshots/tail-{slot}.png",
            "environment": {"QIXI_SKIP_ONBOARDING": "1"},
          }
        ],
      }
      manifest_path = root / "tests" / "screenshot_coverage_manifest.json"
      manifest_path.parent.mkdir(parents=True, exist_ok=True)
      manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
      for index, slot in enumerate(slots):
        write_detailed_png(root / "artifacts" / "screenshots" / f"tail-{slot}.png", index + 10)

      pages, _, _ = builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=root / "review",
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )

      self.assertEqual([page.state_count for page in pages], [12, 1])
      self.assertGreaterEqual(pages[-1].byte_count, inspector.MIN_PAGE_BYTES)
      inspector.inspect_review_board(root / "review", manifest_path)

  def test_review_board_inspector_rejects_ambiguous_json(self) -> None:
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      review_dir = root / "review"
      review_dir.mkdir()
      (review_dir / "latest-screenshot-review-board.json").write_text(
        '{"schemaVersion":1,"schemaVersion":2}\n',
        encoding="utf-8",
      )

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "duplicate key"):
        inspector.inspect_review_board(review_dir, manifest_path)

  def test_review_board_inspector_rejects_invalid_utf8_json_before_parse(self) -> None:
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      path = pathlib.Path(tmp) / "latest-screenshot-review-board.json"
      path.write_bytes(b"\xff\xfe\xfd")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "JSON must be valid UTF-8"):
        inspector.load_strict_json_object(path)

  def test_review_board_reader_rechecks_opened_descriptor_is_regular(self) -> None:
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      fd = os.open(tmp, os.O_RDONLY)
      try:
        class DirectoryHandle:
          def fileno(self) -> int:
            return fd

        with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "regular file after opening"):
          inspector.opened_regular_file_stat(DirectoryHandle(), pathlib.Path(tmp), "directory fixture")
      finally:
        os.close(fd)

  def test_review_board_builder_rechecks_opened_descriptor_is_regular(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      fd = os.open(tmp, os.O_RDONLY)
      try:
        class DirectoryHandle:
          def fileno(self) -> int:
            return fd

        with self.assertRaisesRegex(builder.ReviewBoardError, "regular file after opening"):
          builder.opened_regular_file_stat(DirectoryHandle(), pathlib.Path(tmp), "directory fixture")
      finally:
        os.close(fd)

  def test_review_board_builder_atomic_write_refuses_symlink_target(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      target_payload = root / "redirected.json"
      target_payload.write_text("keep me\n", encoding="utf-8")
      symlink_path = root / "latest-screenshot-review-board.json"
      try:
        symlink_path.symlink_to(target_payload.name)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")

      with self.assertRaisesRegex(builder.ReviewBoardError, "target must not be a symbolic link"):
        builder.write_atomic_text(
          symlink_path,
          '{"schemaVersion":1}\n',
          "review-board JSON index",
          builder.MAX_REVIEW_JSON_BYTES,
        )

      self.assertEqual(target_payload.read_text(encoding="utf-8"), "keep me\n")
      self.assertTrue(symlink_path.is_symlink())

  def test_review_board_builder_atomic_write_cleans_temp_on_payload_failure(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      artifact_path = root / "latest-screenshot-review-board.html"

      def fail_after_write(handle: object) -> None:
        handle.write(b"partial")
        raise RuntimeError("synthetic writer failure")

      with self.assertRaisesRegex(RuntimeError, "synthetic writer failure"):
        builder.write_atomic_artifact(
          artifact_path,
          "review-board HTML index",
          builder.MAX_REVIEW_HTML_BYTES,
          fail_after_write,
        )

      self.assertFalse(artifact_path.exists())
      self.assertEqual(list(root.glob(".latest-screenshot-review-board.html.*.tmp")), [])

  def test_review_board_builder_atomic_bytes_rejects_short_write(self) -> None:
    builder = load_builder_module()

    class ShortWriteHandle:
      def __init__(self, real_handle: object) -> None:
        self.real_handle = real_handle

      def write(self, data: bytes) -> int:
        return self.real_handle.write(data[: max(0, len(data) // 2)])

      def flush(self) -> None:
        self.real_handle.flush()

      def fileno(self) -> int:
        return self.real_handle.fileno()

      def __enter__(self) -> "ShortWriteHandle":
        return self

      def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.real_handle.close()

    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      artifact_path = root / "latest-screenshot-review-board.html"
      original_fdopen = os.fdopen

      def fake_fdopen(fd: int, *args: object, **kwargs: object) -> object:
        return ShortWriteHandle(original_fdopen(fd, *args, **kwargs))

      with mock.patch.object(builder.os, "fdopen", side_effect=fake_fdopen):
        with self.assertRaisesRegex(builder.ReviewBoardError, "byte count drift after writing"):
          builder.write_atomic_bytes(
            artifact_path,
            b"0123456789",
            "review-board HTML index",
            builder.MAX_REVIEW_HTML_BYTES,
          )

      self.assertFalse(artifact_path.exists())
      self.assertEqual(list(root.glob(".latest-screenshot-review-board.html.*.tmp")), [])

  def test_review_board_builder_atomic_write_reports_parent_fsync_failure(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      artifact_path = root / "latest-screenshot-review-board.html"

      with mock.patch.object(
        builder,
        "fsync_parent_directory",
        side_effect=builder.ReviewBoardError("synthetic parent fsync failure"),
      ):
        with self.assertRaisesRegex(builder.ReviewBoardError, "synthetic parent fsync failure"):
          builder.write_atomic_bytes(
            artifact_path,
            b"0123456789",
            "review-board HTML index",
            builder.MAX_REVIEW_HTML_BYTES,
          )

  def test_review_board_inspector_rejects_invalid_generated_at(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      payload["generatedAt"] = "not-a-timestamp"
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "generatedAt must be"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_stale_generated_at_when_marker_is_set(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    previous_marker = os.environ.get("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH")
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      payload["generatedAt"] = "2000-01-01T00:00:00Z"
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
      os.environ["QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH"] = str(time.time() - 1.0)
      try:
        with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "stale review-board generatedAt"):
          inspector.inspect_review_board(output_dir, manifest_path)
      finally:
        if previous_marker is None:
          os.environ.pop("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH", None)
        else:
          os.environ["QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH"] = previous_marker

  def test_review_board_inspector_accepts_generated_at_after_marker_with_microsecond_precision(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    previous_marker = os.environ.get("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH")
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      payload = json.loads((output_dir / "latest-screenshot-review-board.json").read_text(encoding="utf-8"))
      generated_at = inspector.dt.datetime.fromisoformat(payload["generatedAt"][:-1] + "+00:00")
      try:
        inspector.inspect_generated_at(payload["generatedAt"], generated_at.timestamp() - 0.000001)
      finally:
        if previous_marker is None:
          os.environ.pop("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH", None)
        else:
          os.environ["QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH"] = previous_marker

  def test_review_board_inspector_rejects_generated_at_far_in_the_future(self) -> None:
    inspector = load_inspector_module()
    now = inspector.dt.datetime(2026, 7, 5, 12, 0, 0, tzinfo=inspector.dt.timezone.utc)
    future = now + inspector.dt.timedelta(
      seconds=inspector.REVIEW_BOARD_GENERATED_AT_MAX_FUTURE_SKEW_SECONDS + 1
    )
    generated_at = future.isoformat(timespec="microseconds").replace("+00:00", "Z")

    with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "too far in the future"):
      inspector.inspect_generated_at(generated_at, None, now_epoch=now.timestamp())

  def test_review_board_inspector_accepts_generated_at_within_future_skew(self) -> None:
    inspector = load_inspector_module()
    now = inspector.dt.datetime(2026, 7, 5, 12, 0, 0, tzinfo=inspector.dt.timezone.utc)
    future = now + inspector.dt.timedelta(
      seconds=inspector.REVIEW_BOARD_GENERATED_AT_MAX_FUTURE_SKEW_SECONDS
    )
    generated_at = future.isoformat(timespec="microseconds").replace("+00:00", "Z")

    inspector.inspect_generated_at(generated_at, None, now_epoch=now.timestamp())

  def test_review_board_inspector_rejects_manifest_digest_drift(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      payload["manifestSha256HexDigest"] = "0" * 64
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "manifest digest drift"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_missing_page_image(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      pages, _, _ = builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      pages[0].path.unlink()

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "missing review-board page image"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_state_count_drift(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", (30, 90, 160))
      write_png(root / "artifacts" / "screenshots" / "tiny-en.png", (160, 90, 30))
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      payload["stateCount"] = 1
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "stateCount"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_unsafe_source_paths(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      payload["states"][0]["screenshot"] = "artifacts/screenshots/../../escape.png"
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "must not contain"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_ambiguous_source_path_components(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    for unsafe in (
      "artifacts/screenshots//tiny-zh-Hans.png",
      "artifacts/screenshots/./tiny-zh-Hans.png",
      "artifacts/screenshots/tiny-zh-Hans.png/",
    ):
      with self.subTest(unsafe=unsafe), tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        manifest_path = write_manifest(root)
        write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
        write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
        output_dir = root / "review"
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=output_dir,
          columns=3,
          rows=4,
          thumbnail_width=360,
          thumbnail_height=240,
        )
        json_path = output_dir / "latest-screenshot-review-board.json"
        payload = json.loads(json_path.read_text(encoding="utf-8"))
        payload["states"][0]["screenshot"] = unsafe
        json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

        with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "must not contain"):
          inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_source_metadata_drift(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      payload["states"][0]["byteCount"] += 1
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "byte count drift"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_source_digest_drift(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      payload["states"][0]["sha256HexDigest"] = "0" * 64
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "source digest drift"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_page_digest_drift(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      payload["pages"][0]["sha256HexDigest"] = "0" * 64
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "page digest drift"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_png_opened_byte_count_drift(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      first_source = root / "artifacts" / "screenshots" / "tiny-zh-Hans.png"
      write_detailed_png(first_source, 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      page_path = output_dir / "latest-screenshot-review-board-page-01.png"
      original_open = pathlib.Path.open

      for target, pattern in (
        (page_path, "review-board page image .* opened-byte-count drift while reading"),
        (first_source, "review-board state source screenshot .* opened-byte-count drift while reading"),
      ):
        with self.subTest(target=target.name):
          def fake_open(path: pathlib.Path, *args: object, **kwargs: object) -> object:
            if path == target:
              return DriftHandle(target)
            return original_open(path, *args, **kwargs)

          with mock.patch.object(pathlib.Path, "open", fake_open):
            with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, pattern):
              inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_decodes_same_bounded_png_bytes(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      opened_from: list[object] = []
      original_image_open = inspector.Image.open

      def fake_image_open(file: object, *args: object, **kwargs: object) -> object:
        opened_from.append(file)
        return original_image_open(file, *args, **kwargs)

      with mock.patch.object(inspector.Image, "open", side_effect=fake_image_open):
        inspector.inspect_review_board(output_dir, manifest_path)

      self.assertGreaterEqual(len(opened_from), 4)
      self.assertTrue(all(isinstance(file, io.BytesIO) for file in opened_from))

  def test_review_board_inspector_rejects_ambiguous_page_path_components(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    for unsafe in (
      "latest-screenshot-review-board-page-01.png/",
      "./latest-screenshot-review-board-page-01.png",
      "latest-screenshot-review-board-page-01.png//",
    ):
      with self.subTest(unsafe=unsafe), tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        manifest_path = write_manifest(root)
        write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
        write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
        output_dir = root / "review"
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=output_dir,
          columns=3,
          rows=4,
          thumbnail_width=360,
          thumbnail_height=240,
        )
        json_path = output_dir / "latest-screenshot-review-board.json"
        payload = json.loads(json_path.read_text(encoding="utf-8"))
        payload["pages"][0]["path"] = unsafe
        json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

        with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "must not contain"):
          inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_header_only_page_image_even_when_metadata_matches(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      page_record = payload["pages"][0]
      page_path = output_dir / page_record["path"]
      page_path.write_bytes(
        padded_png_header_fixture(
          inspector,
          width=page_record["width"],
          height=page_record["height"],
          minimum_size=inspector.MIN_PAGE_BYTES,
        )
      )
      page_record["byteCount"] = page_path.stat().st_size
      page_record["sha256HexDigest"] = sha256_hex_digest(page_path)
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "decodable PNG image"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_oversized_page_dimensions_before_decode(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      page_record = payload["pages"][0]
      page_path = output_dir / page_record["path"]
      page_path.write_bytes(
        padded_png_header_fixture(
          inspector,
          width=20_000,
          height=20_000,
          minimum_size=inspector.MIN_PAGE_BYTES,
        )
      )
      page_record["width"] = 20_000
      page_record["height"] = 20_000
      page_record["byteCount"] = page_path.stat().st_size
      page_record["sha256HexDigest"] = sha256_hex_digest(page_path)
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "too large for bounded visual inspection"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_oversized_page_bytes_before_digest(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      page_record = payload["pages"][0]
      page_path = output_dir / page_record["path"]
      with page_path.open("wb") as handle:
        handle.truncate(inspector.REVIEW_BOARD_IMAGE_MAX_BYTES + 1)
      page_record["byteCount"] = page_path.stat().st_size
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "exceeds byte budget"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_unreferenced_page_images(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      Image.new("RGB", (1200, 1200), (20, 40, 80)).save(
        output_dir / "latest-screenshot-review-board-page-99.png"
      )

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "unreferenced page images"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_unexpected_artifacts(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      (output_dir / "old-review.html").write_text("stale", encoding="utf-8")
      (output_dir / "old-review.json").write_text('{"stale":true}\n', encoding="utf-8")
      Image.new("RGB", (120, 120), (20, 40, 80)).save(output_dir / "old-review.png")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "unexpected artifacts"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_generator_removes_stale_review_board_artifacts_before_rendering(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      output_dir.mkdir()
      stale_page = output_dir / "latest-screenshot-review-board-page-99.png"
      Image.new("RGB", (1200, 1200), (20, 40, 80)).save(stale_page)
      (output_dir / "latest-screenshot-review-board.html").write_text("stale", encoding="utf-8")
      (output_dir / "latest-screenshot-review-board.json").write_text('{"stale":true}\n', encoding="utf-8")

      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )

      self.assertFalse(stale_page.exists())
      inspector.inspect_review_board(output_dir, manifest_path)

  def test_generator_refuses_directory_shaped_review_board_artifacts(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      (output_dir / "latest-screenshot-review-board-page-99.png").mkdir(parents=True)

      with self.assertRaisesRegex(builder.ReviewBoardError, "directory-shaped review-board artifact"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=output_dir,
          columns=3,
          rows=4,
          thumbnail_width=360,
          thumbnail_height=240,
        )

  def test_generator_refuses_symlink_output_directory(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      target_dir = root / "real-review"
      target_dir.mkdir()
      output_dir = root / "review-link"
      try:
        output_dir.symlink_to(target_dir, target_is_directory=True)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")

      with self.assertRaisesRegex(builder.ReviewBoardError, "symbolic link"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=output_dir,
          columns=3,
          rows=4,
          thumbnail_width=360,
          thumbnail_height=240,
        )

  def test_generator_refuses_symlink_output_parent_component(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      real_parent = root / "real-output-parent"
      real_parent.mkdir()
      linked_parent = root / "linked-output-parent"
      try:
        linked_parent.symlink_to(real_parent, target_is_directory=True)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")

      with self.assertRaisesRegex(builder.ReviewBoardError, "symbolic links"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=linked_parent / "review",
          columns=3,
          rows=4,
          thumbnail_width=360,
          thumbnail_height=240,
        )

  def test_review_board_inspector_rejects_manifest_state_order_drift(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      payload["states"] = list(reversed(payload["states"]))
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "state order or id drift"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_manifest_screenshot_path_drift(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      payload["states"][0]["screenshot"] = "artifacts/screenshots/tiny-en.png"
      payload["states"][0]["byteCount"] = payload["states"][1]["byteCount"]
      payload["states"][0]["width"] = payload["states"][1]["width"]
      payload["states"][0]["height"] = payload["states"][1]["height"]
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "screenshot path drift"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_symlink_page_images(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      pages, _, _ = builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      page = pages[0].path
      target = output_dir / "page-target.png"
      page.rename(target)
      try:
        page.symlink_to(target.name)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "symbolic link"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_symlink_source_screenshots(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      source = root / "artifacts" / "screenshots" / "tiny-zh-Hans.png"
      write_detailed_png(source, 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      target = source.with_name("source-target.png")
      source.rename(target)
      try:
        source.symlink_to(target.name)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "symbolic link"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_header_only_source_screenshot_before_digest(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      source = root / "artifacts" / "screenshots" / "tiny-zh-Hans.png"
      write_detailed_png(source, 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      state_record = payload["states"][0]
      source.write_bytes(
        padded_png_header_fixture(
          inspector,
          width=state_record["width"],
          height=state_record["height"],
          minimum_size=inspector.PNG_HEADER_BYTES,
        )
      )
      state_record["byteCount"] = source.stat().st_size
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "decodable PNG image"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_oversized_source_bytes_before_digest(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      source = root / "artifacts" / "screenshots" / "tiny-zh-Hans.png"
      write_detailed_png(source, 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      json_path = output_dir / "latest-screenshot-review-board.json"
      payload = json.loads(json_path.read_text(encoding="utf-8"))
      state_record = payload["states"][0]
      with source.open("wb") as handle:
        handle.truncate(inspector.REVIEW_BOARD_IMAGE_MAX_BYTES + 1)
      state_record["byteCount"] = source.stat().st_size
      json_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "exceeds byte budget"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_stale_artifacts_when_marker_is_set(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    previous_marker = os.environ.get("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH")
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      stale_time = time.time() - 120.0
      for artifact in output_dir.iterdir():
        os.utime(artifact, (stale_time, stale_time))
      os.environ["QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH"] = str(time.time() - 1.0)
      try:
        with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "stale review-board"):
          inspector.inspect_review_board(output_dir, manifest_path)
      finally:
        if previous_marker is None:
          os.environ.pop("QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH", None)
        else:
          os.environ["QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH"] = previous_marker

  def test_review_board_inspector_rejects_empty_html_artifact(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      (output_dir / "latest-screenshot-review-board.html").write_text("", encoding="utf-8")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "HTML is empty"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_oversized_html_before_reading(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      with (output_dir / "latest-screenshot-review-board.html").open("wb") as handle:
        handle.truncate(inspector.MAX_REVIEW_HTML_BYTES + 1)

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "HTML exceeds"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_review_board_inspector_rejects_invalid_utf8_html_before_scanning_links(self) -> None:
    builder = load_builder_module()
    inspector = load_inspector_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", 1)
      write_detailed_png(root / "artifacts" / "screenshots" / "tiny-en.png", 2)
      output_dir = root / "review"
      builder.build_review_board(
        root=root,
        manifest_path=manifest_path,
        output_dir=output_dir,
        columns=3,
        rows=4,
        thumbnail_width=360,
        thumbnail_height=240,
      )
      (output_dir / "latest-screenshot-review-board.html").write_bytes(b"\xff\xfe\xfd")

      with self.assertRaisesRegex(inspector.ReviewBoardArtifactError, "HTML must be valid UTF-8"):
        inspector.inspect_review_board(output_dir, manifest_path)

  def test_missing_screenshot_artifact_fails_loudly(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", (30, 90, 160))

      with self.assertRaisesRegex(builder.ReviewBoardError, "missing screenshot artifact"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=root / "review",
          columns=2,
          rows=1,
          thumbnail_width=80,
          thumbnail_height=60,
        )

  def test_builder_rejects_source_screenshot_opened_byte_count_drift(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      source = root / "artifacts" / "screenshots" / "tiny-zh-Hans.png"
      write_png(source, (30, 90, 160))
      write_png(root / "artifacts" / "screenshots" / "tiny-en.png", (160, 90, 30))
      original_open = pathlib.Path.open

      def fake_open(path: pathlib.Path, *args: object, **kwargs: object) -> object:
        if path == source:
          return DriftHandle(source)
        return original_open(path, *args, **kwargs)

      with mock.patch.object(pathlib.Path, "open", fake_open):
        with self.assertRaisesRegex(builder.ReviewBoardError, "opened-byte-count drift while reading"):
          builder.build_review_board(
            root=root,
            manifest_path=manifest_path,
            output_dir=root / "review",
            columns=2,
            rows=1,
            thumbnail_width=80,
            thumbnail_height=60,
          )

  def test_builder_decodes_source_screenshots_from_same_bounded_bytes(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      write_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", (30, 90, 160))
      write_png(root / "artifacts" / "screenshots" / "tiny-en.png", (160, 90, 30))
      opened_from: list[object] = []
      original_image_open = builder.Image.open

      def fake_image_open(file: object, *args: object, **kwargs: object) -> object:
        opened_from.append(file)
        return original_image_open(file, *args, **kwargs)

      with mock.patch.object(builder.Image, "open", side_effect=fake_image_open):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=root / "review",
          columns=2,
          rows=1,
          thumbnail_width=80,
          thumbnail_height=60,
        )

      self.assertGreaterEqual(len(opened_from), 4)
      self.assertTrue(all(isinstance(file, io.BytesIO) for file in opened_from))

  def test_builder_rejects_symlink_source_screenshot(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      source = root / "artifacts" / "screenshots" / "tiny-zh-Hans.png"
      target = source.with_name("source-target.png")
      write_png(target, (30, 90, 160))
      write_png(root / "artifacts" / "screenshots" / "tiny-en.png", (160, 90, 30))
      try:
        source.symlink_to(target.name)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")

      with self.assertRaisesRegex(builder.ReviewBoardError, "symbolic link"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=root / "review",
          columns=2,
          rows=1,
          thumbnail_width=80,
          thumbnail_height=60,
        )

  def test_builder_rejects_symlink_source_screenshot_parent_component(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      real_artifacts = root / "real-artifacts"
      real_screenshots = real_artifacts / "screenshots"
      write_png(real_screenshots / "tiny-zh-Hans.png", (30, 90, 160))
      write_png(real_screenshots / "tiny-en.png", (160, 90, 30))
      try:
        (root / "artifacts").symlink_to(real_artifacts, target_is_directory=True)
      except OSError as exc:
        self.skipTest(f"symlink creation unavailable: {exc}")

      with self.assertRaisesRegex(builder.ReviewBoardError, "symbolic links"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=root / "review",
          columns=2,
          rows=1,
          thumbnail_width=80,
          thumbnail_height=60,
        )

  def test_builder_rejects_non_png_source_screenshot(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      source = root / "artifacts" / "screenshots" / "tiny-zh-Hans.png"
      source.parent.mkdir(parents=True, exist_ok=True)
      source.write_bytes(b"not a png")
      write_png(root / "artifacts" / "screenshots" / "tiny-en.png", (160, 90, 30))

      with self.assertRaisesRegex(builder.ReviewBoardError, "must be a PNG file"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=root / "review",
          columns=2,
          rows=1,
          thumbnail_width=80,
          thumbnail_height=60,
        )

  def test_builder_rejects_header_only_source_screenshot_before_rendering(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      source = root / "artifacts" / "screenshots" / "tiny-zh-Hans.png"
      source.parent.mkdir(parents=True, exist_ok=True)
      source.write_bytes(png_header_fixture(builder, width=120, height=80))
      write_png(root / "artifacts" / "screenshots" / "tiny-en.png", (160, 90, 30))

      with self.assertRaisesRegex(builder.ReviewBoardError, "decodable PNG image"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=root / "review",
          columns=2,
          rows=1,
          thumbnail_width=80,
          thumbnail_height=60,
        )

  def test_builder_rejects_oversized_source_dimensions_before_decode(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      source = root / "artifacts" / "screenshots" / "tiny-zh-Hans.png"
      source.parent.mkdir(parents=True, exist_ok=True)
      source.write_bytes(png_header_fixture(builder, width=20_000, height=20_000))
      write_png(root / "artifacts" / "screenshots" / "tiny-en.png", (160, 90, 30))

      with self.assertRaisesRegex(builder.ReviewBoardError, "too large for bounded review-board rendering"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=root / "review",
          columns=2,
          rows=1,
          thumbnail_width=80,
          thumbnail_height=60,
        )

  def test_builder_rejects_oversized_source_bytes_before_header(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root)
      source = root / "artifacts" / "screenshots" / "tiny-zh-Hans.png"
      source.parent.mkdir(parents=True, exist_ok=True)
      with source.open("wb") as handle:
        handle.truncate(builder.SCREENSHOT_ARTIFACT_MAX_BYTES + 1)
      write_png(root / "artifacts" / "screenshots" / "tiny-en.png", (160, 90, 30))

      with self.assertRaisesRegex(builder.ReviewBoardError, "exceeds byte budget"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=root / "review",
          columns=2,
          rows=1,
          thumbnail_width=80,
          thumbnail_height=60,
        )

  def test_duplicate_screenshot_artifact_fails_loudly(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root, duplicate_path=True)
      write_png(root / "artifacts" / "screenshots" / "reused.png", (30, 90, 160))

      with self.assertRaisesRegex(builder.ReviewBoardError, "reuses screenshot artifact"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=root / "review",
          columns=2,
          rows=1,
          thumbnail_width=80,
          thumbnail_height=60,
        )

  def test_required_state_count_must_match_manifest_expansion(self) -> None:
    builder = load_builder_module()
    with tempfile.TemporaryDirectory() as tmp:
      root = pathlib.Path(tmp)
      manifest_path = write_manifest(root, required_count=3)
      write_png(root / "artifacts" / "screenshots" / "tiny-zh-Hans.png", (30, 90, 160))
      write_png(root / "artifacts" / "screenshots" / "tiny-en.png", (160, 90, 30))

      with self.assertRaisesRegex(builder.ReviewBoardError, "expected requiredStateCount=3"):
        builder.build_review_board(
          root=root,
          manifest_path=manifest_path,
          output_dir=root / "review",
          columns=2,
          rows=1,
          thumbnail_width=80,
          thumbnail_height=60,
        )


if __name__ == "__main__":
  unittest.main()
