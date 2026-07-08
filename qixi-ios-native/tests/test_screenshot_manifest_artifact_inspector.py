#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import contextlib
import io
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from PIL import Image


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSPECTOR_PATH = ROOT / "tests" / "inspect_screenshot_manifest_artifacts.py"


def load_artifact_inspector():
  spec = importlib.util.spec_from_file_location("screenshot_manifest_artifact_inspector", INSPECTOR_PATH)
  assert spec and spec.loader
  module = importlib.util.module_from_spec(spec)
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


class ScreenshotManifestArtifactInspectorTests(unittest.TestCase):
  def setUp(self) -> None:
    self.module = load_artifact_inspector()
    self.tempdir = tempfile.TemporaryDirectory()
    self.addCleanup(self.tempdir.cleanup)
    self.root = pathlib.Path(self.tempdir.name)
    (self.root / "tests").mkdir(parents=True)
    (self.root / "artifacts" / "screenshots").mkdir(parents=True)
    self.module.ROOT = self.root
    self.module.MANIFEST = self.root / "tests" / "screenshot_coverage_manifest.json"

  def write_inspector(
    self,
    *,
    should_pass: bool = True,
    as_directory: bool = False,
    as_symlink: bool = False,
  ) -> pathlib.Path:
    inspector = self.root / "tests" / "fake_inspector.py"
    if as_directory:
      inspector.mkdir(parents=True)
      return inspector
    if as_symlink:
      target = self.root / "real_fake_inspector.py"
      target.write_text("#!/usr/bin/env python3\nraise SystemExit(0)\n", encoding="utf-8")
      inspector.symlink_to(target)
      return inspector
    if should_pass:
      inspector.write_text(
        "\n".join(
          [
            "#!/usr/bin/env python3",
            "import pathlib",
            "import sys",
            "assert pathlib.Path(sys.argv[1]).exists()",
            "assert sys.argv[2:] == ['ready']",
            "print('fake inspector passed')",
          ]
        ),
        encoding="utf-8",
      )
    else:
      inspector.write_text(
        "\n".join(
          [
            "#!/usr/bin/env python3",
            "import sys",
            "print('synthetic inspector failure', file=sys.stderr)",
            "raise SystemExit(17)",
          ]
        ),
        encoding="utf-8",
      )
    return inspector

  def write_script(
    self,
    *,
    executable: bool = True,
    as_directory: bool = False,
    as_symlink: bool = False,
  ) -> pathlib.Path:
    script = self.root / "scripts" / "fake.sh"
    script.parent.mkdir(parents=True, exist_ok=True)
    if as_directory:
      script.mkdir()
      return script
    if as_symlink:
      target = self.root / "real_fake_script.sh"
      target.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
      target.chmod(0o755)
      script.symlink_to(target)
      return script
    script.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    script.chmod(0o755 if executable else 0o644)
    return script

  def write_manifest(
    self,
    *,
    required_count: int = 1,
    script: str = "scripts/fake.sh",
    inspector: str = "tests/fake_inspector.py",
    screenshot: str = "artifacts/screenshots/fake-{status}.png",
    environment: object | None = None,
  ) -> None:
    manifest = {
      "version": 1,
      "languages": ["en"],
      "requiredStateCount": required_count,
      "matrices": [
        {
          "id": "fake",
          "description": "Fake manifest state.",
          "scripts": [script],
          "inspector": inspector,
          "inspectorArguments": ["{status}"],
          "dimensions": {"status": ["ready"]},
          "screenshot": screenshot,
          "environment": environment if environment is not None else {"QIXI_FAKE_STATUS": "{status}"},
        }
      ],
    }
    self.module.MANIFEST.write_text(json.dumps(manifest), encoding="utf-8")
    if script == "scripts/fake.sh":
      self.write_script()

  def write_screenshot(
    self,
    *,
    as_directory: bool = False,
    as_symlink: bool = False,
    data: bytes | None = None,
    sparse_size: int | None = None,
  ) -> pathlib.Path:
    screenshot = self.root / "artifacts" / "screenshots" / "fake-ready.png"
    if as_directory:
      screenshot.mkdir(parents=True)
      return screenshot
    if as_symlink:
      target = self.root / "real_fake_screenshot.png"
      target.write_bytes(b"not empty")
      screenshot.symlink_to(target)
      return screenshot
    if sparse_size is not None:
      with screenshot.open("wb") as handle:
        handle.truncate(sparse_size)
      return screenshot
    if data is not None:
      screenshot.write_bytes(data)
      return screenshot
    Image.new("RGB", (48, 32), (244, 244, 244)).save(screenshot)
    return screenshot

  def png_header_fixture(self, *, width: int, height: int, ihdr_length: int = 13, ihdr_kind: bytes = b"IHDR") -> bytes:
    return b"".join(
      [
        self.module.PNG_SIGNATURE,
        ihdr_length.to_bytes(4, "big"),
        ihdr_kind,
        width.to_bytes(4, "big"),
        height.to_bytes(4, "big"),
        b"\x08\x02\x00\x00\x00",
        b"\x00\x00\x00\x00",
      ]
    )

  def run_main_silently(self) -> int:
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
      return self.module.main()

  def test_manifest_artifact_inspector_accepts_complete_artifacts(self) -> None:
    self.write_manifest()
    self.write_inspector()
    self.write_screenshot()

    self.assertEqual(self.run_main_silently(), 0)

  def test_manifest_artifact_inspector_rejects_missing_screenshot(self) -> None:
    self.write_manifest()
    self.write_inspector()

    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_failing_state_inspector(self) -> None:
    self.write_manifest()
    self.write_inspector(should_pass=False)
    self.write_screenshot()

    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_required_count_mismatch(self) -> None:
    self.write_manifest(required_count=2)
    self.write_inspector()
    self.write_screenshot()

    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_empty_manifest_matrix_even_with_zero_count(self) -> None:
    self.module.MANIFEST.write_text(
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

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "requiredStateCount must be a positive integer"):
      self.module.expanded_states(self.module.load_manifest())
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_stale_screenshot_artifacts(self) -> None:
    self.write_manifest()
    self.write_inspector()
    screenshot = self.write_screenshot()
    minimum_mtime = screenshot.stat().st_mtime + 10.0

    with mock.patch.dict(
      os.environ,
      {"QIXI_SCREENSHOT_MANIFEST_MIN_MTIME_EPOCH": str(minimum_mtime)},
    ):
      self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_missing_declared_script(self) -> None:
    self.write_manifest(script="scripts/missing.sh")
    self.write_inspector()
    self.write_screenshot()

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "missing screenshot script"):
      self.module.expanded_states(self.module.load_manifest())
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_non_executable_declared_script(self) -> None:
    self.write_manifest()
    self.write_script(executable=False)
    self.write_inspector()
    self.write_screenshot()

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "screenshot script is not executable"):
      self.module.expanded_states(self.module.load_manifest())
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_directory_declared_script(self) -> None:
    self.write_manifest()
    script = self.root / "scripts" / "fake.sh"
    script.unlink()
    self.write_script(as_directory=True)
    self.write_inspector()
    self.write_screenshot()

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "screenshot script is not a file"):
      self.module.expanded_states(self.module.load_manifest())
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_symlink_declared_script(self) -> None:
    self.write_manifest()
    script = self.root / "scripts" / "fake.sh"
    script.unlink()
    self.write_script(as_symlink=True)
    self.write_inspector()
    self.write_screenshot()

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "screenshot script must not be a symbolic link"):
      self.module.expanded_states(self.module.load_manifest())
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_unsafe_declared_script_path(self) -> None:
    for unsafe in ("/tmp/fake.sh", "../fake.sh", "scripts//fake.sh", "scripts/./fake.sh", "helpers/fake.sh", "scripts/fake.py"):
      with self.subTest(unsafe=unsafe):
        self.write_manifest(script=unsafe)
        self.write_inspector()
        self.write_screenshot()
        with self.assertRaisesRegex(
          self.module.ManifestArtifactError,
          "script must",
        ):
          self.module.expanded_states(self.module.load_manifest())
        self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_unsafe_inspector_path(self) -> None:
    for unsafe in ("/tmp/fake.py", "../fake.py", "tests//fake.py", "tests/./fake.py", "scripts/fake.py", "tests/fake.txt"):
      with self.subTest(unsafe=unsafe):
        self.write_manifest(inspector=unsafe)
        self.write_inspector()
        self.write_screenshot()
        with self.assertRaisesRegex(
          self.module.ManifestArtifactError,
          "inspector must",
        ):
          self.module.expanded_states(self.module.load_manifest())
        self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_unknown_environment_placeholders(self) -> None:
    self.write_manifest(environment={"QIXI_FAKE_STATUS": "{missing}"})
    self.write_inspector()
    self.write_screenshot()

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "environment references unknown dimensions"):
      self.module.expanded_states(self.module.load_manifest())
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_non_qixi_environment_variables(self) -> None:
    self.write_manifest(environment={"PATH": "{status}"})
    self.write_inspector()
    self.write_screenshot()

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "environment variables must begin with QIXI_"):
      self.module.expanded_states(self.module.load_manifest())
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_non_string_environment_values(self) -> None:
    self.write_manifest(environment={"QIXI_FAKE_STATUS": 1})
    self.write_inspector()
    self.write_screenshot()

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "environment value for QIXI_FAKE_STATUS must be a string"):
      self.module.expanded_states(self.module.load_manifest())
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_unsafe_screenshot_path(self) -> None:
    for unsafe in (
      "/tmp/fake.png",
      "../fake.png",
      "artifacts/screenshots//fake.png",
      "artifacts/screenshots/./fake.png",
      "artifacts/fake.png",
      "artifacts/screenshots/fake.jpg",
    ):
      with self.subTest(unsafe=unsafe):
        self.write_manifest(screenshot=unsafe)
        self.write_inspector()
        self.write_screenshot()
        with self.assertRaisesRegex(
          self.module.ManifestArtifactError,
          "screenshot must",
        ):
          self.module.expanded_states(self.module.load_manifest())
        self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_symlink_inspector(self) -> None:
    self.write_manifest()
    self.write_inspector(as_symlink=True)
    self.write_screenshot()

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "inspector must not be a symbolic link"):
      self.module.expanded_states(self.module.load_manifest())
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_symlink_screenshot_artifact(self) -> None:
    self.write_manifest()
    self.write_inspector()
    self.write_screenshot(as_symlink=True)

    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_non_png_screenshot_artifact(self) -> None:
    self.write_manifest()
    self.write_inspector()
    self.write_screenshot(data=b"not a png")

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "screenshot artifact must be a PNG file"):
      self.module.inspect_state(
        "fake",
        self.root / "artifacts" / "screenshots" / "fake-ready.png",
        self.root / "tests" / "fake_inspector.py",
        ["ready"],
      )
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_invalid_png_ihdr(self) -> None:
    self.write_manifest()
    self.write_inspector()
    self.write_screenshot(data=self.png_header_fixture(width=48, height=32, ihdr_length=12))

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "valid PNG IHDR"):
      self.module.inspect_state(
        "fake",
        self.root / "artifacts" / "screenshots" / "fake-ready.png",
        self.root / "tests" / "fake_inspector.py",
        ["ready"],
      )
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_header_only_png_before_state_inspector(self) -> None:
    self.write_manifest()
    self.write_inspector()
    self.write_screenshot(data=self.png_header_fixture(width=48, height=32))

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "decodable PNG image"):
      self.module.inspect_state(
        "fake",
        self.root / "artifacts" / "screenshots" / "fake-ready.png",
        self.root / "tests" / "fake_inspector.py",
        ["ready"],
      )
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_screenshot_byte_count_drift(self) -> None:
    self.write_manifest()
    self.write_inspector()
    screenshot = self.write_screenshot()
    original_open = pathlib.Path.open

    def fake_open(path: pathlib.Path, *args: object, **kwargs: object) -> object:
      if path == screenshot:
        return DriftHandle(screenshot)
      return original_open(path, *args, **kwargs)

    with mock.patch.object(pathlib.Path, "open", fake_open):
      with self.assertRaisesRegex(self.module.ManifestArtifactError, "opened-byte-count drift while reading"):
        self.module.inspect_state(
          "fake",
          screenshot,
          self.root / "tests" / "fake_inspector.py",
          ["ready"],
        )
      self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_decodes_same_bounded_bytes(self) -> None:
    self.write_manifest()
    self.write_inspector()
    screenshot = self.write_screenshot()
    opened_from: list[object] = []
    original_image_open = self.module.Image.open

    def fake_image_open(file: object, *args: object, **kwargs: object) -> object:
      opened_from.append(file)
      return original_image_open(file, *args, **kwargs)

    with mock.patch.object(self.module.Image, "open", side_effect=fake_image_open):
      self.module.inspect_state(
        "fake",
        screenshot,
        self.root / "tests" / "fake_inspector.py",
        ["ready"],
      )

    self.assertEqual(len(opened_from), 1)
    self.assertIsInstance(opened_from[0], io.BytesIO)

  def test_manifest_artifact_inspector_rejects_too_large_png_dimensions_before_decode(self) -> None:
    self.write_manifest()
    self.write_inspector()
    self.write_screenshot(data=self.png_header_fixture(width=20_000, height=20_000))

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "too large for bounded visual inspection"):
      self.module.inspect_state(
        "fake",
        self.root / "artifacts" / "screenshots" / "fake-ready.png",
        self.root / "tests" / "fake_inspector.py",
        ["ready"],
      )
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_oversized_screenshot_bytes_before_header(self) -> None:
    self.write_manifest()
    self.write_inspector()
    self.write_screenshot(sparse_size=self.module.SCREENSHOT_ARTIFACT_MAX_BYTES + 1)

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "exceeds byte budget"):
      self.module.inspect_state(
        "fake",
        self.root / "artifacts" / "screenshots" / "fake-ready.png",
        self.root / "tests" / "fake_inspector.py",
        ["ready"],
      )
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_ambiguous_manifest_json(self) -> None:
    self.module.MANIFEST.write_text('{"version":1,"version":1,"matrices":[]}\n', encoding="utf-8")

    with self.assertRaisesRegex(self.module.ManifestArtifactError, "duplicate JSON key 'version'"):
      self.module.load_manifest()
    self.assertEqual(self.run_main_silently(), 1)

  def test_manifest_artifact_inspector_rejects_collapsed_utility_sheet_variants(self) -> None:
    screenshot_dir = self.root / "artifacts" / "screenshots"
    camera = screenshot_dir / "latest-ipad-camera-sheet-en.png"
    imported = screenshot_dir / "latest-ipad-import-sheet-en.png"
    Image.new("RGB", (400, 260), (244, 244, 244)).save(camera)
    Image.new("RGB", (400, 260), (244, 244, 244)).save(imported)
    states = [
      ("camera", camera, self.root / "tests" / "fake_inspector.py", []),
      ("import", imported, self.root / "tests" / "fake_inspector.py", []),
    ]

    with self.assertRaises(self.module.ManifestArtifactError):
      self.module.inspect_sheet_variants_are_distinct(states)


if __name__ == "__main__":
  unittest.main()
