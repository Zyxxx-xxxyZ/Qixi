#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import qixi_release_evidence_archive_match as matcher  # noqa: E402


def write_sparse_file(path: pathlib.Path, byte_count: int) -> None:
  with path.open("wb") as handle:
    handle.seek(byte_count - 1)
    handle.write(b"\0")


class DirectoryHandle:
  def __init__(self, directory: pathlib.Path) -> None:
    self.fd = os.open(directory, os.O_RDONLY)

  def fileno(self) -> int:
    return self.fd

  def read(self, _byte_count: int) -> bytes:
    raise AssertionError("reader must reject the opened descriptor before reading")

  def __enter__(self) -> "DirectoryHandle":
    return self

  def __exit__(self, _exc_type: object, _exc: object, _traceback: object) -> None:
    os.close(self.fd)


class DriftHandle:
  def __init__(self, backing_file: pathlib.Path) -> None:
    self.fd = os.open(backing_file, os.O_RDONLY)
    self.did_read = False

  def fileno(self) -> int:
    return self.fd

  def read(self, _byte_count: int) -> bytes:
    if self.did_read:
      return b""
    self.did_read = True
    return b""

  def __enter__(self) -> "DriftHandle":
    return self

  def __exit__(self, _exc_type: object, _exc: object, _traceback: object) -> None:
    os.close(self.fd)


def write_minimal_archive(
  directory: pathlib.Path,
  *,
  bundle_identifier: str = "com.qixi.localanalysis",
  version: str = "1.0",
  build: str = "1",
  runtime: str = "nativeInProcess",
) -> pathlib.Path:
  archive = directory / "Qixi.xcarchive"
  app = archive / "Products" / "Applications" / "Qixi.app"
  app.mkdir(parents=True)
  executable = app / "Qixi"
  executable.write_bytes(b"qixi executable bytes\n")
  with (archive / "Info.plist").open("wb") as plist_file:
    plistlib.dump(
      {
        "ApplicationProperties": {
          "ApplicationPath": "Applications/Qixi.app",
          "CFBundleIdentifier": bundle_identifier,
          "CFBundleShortVersionString": version,
          "CFBundleVersion": build,
        }
      },
      plist_file,
    )
  with (app / "Info.plist").open("wb") as plist_file:
    plistlib.dump(
      {
        "CFBundleIdentifier": bundle_identifier,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "CFBundleExecutable": "Qixi",
        "QixiAnalysisRuntime": runtime,
      },
      plist_file,
    )
  return archive


def write_minimal_evidence(
  directory: pathlib.Path,
  *,
  bundle_identifier: str = "com.qixi.localanalysis",
  version: str = "1.0",
  build: str = "1",
  runtime: str = "nativeInProcess",
  executable_sha256: str | None = None,
) -> pathlib.Path:
  executable_sha256 = executable_sha256 or hashlib.sha256(b"qixi executable bytes\n").hexdigest()
  evidence = directory / "real-device-evidence.json"
  evidence.write_text(
    json.dumps(
      {
        "schemaVersion": matcher.REAL_DEVICE_EVIDENCE_SCHEMA_VERSION,
        "kind": matcher.REAL_DEVICE_EVIDENCE_KIND,
        "app": {
          "bundleIdentifier": bundle_identifier,
          "version": version,
          "build": build,
          "analysisRuntime": runtime,
          "executableSHA256HexDigest": executable_sha256,
        },
      },
      sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
  )
  return evidence


class ReleaseEvidenceArchiveMatchTests(unittest.TestCase):
  def test_accepts_matching_archive_identity(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = write_minimal_evidence(directory)
      summary = matcher.validate_archive_match(evidence, archive, expected_runtime="nativeInProcess")
    self.assertEqual(summary["bundleIdentifier"], "com.qixi.localanalysis")
    self.assertEqual(summary["version"], "1.0")
    self.assertEqual(summary["build"], "1")
    self.assertEqual(summary["analysisRuntime"], "nativeInProcess")
    self.assertEqual(summary["executableSHA256HexDigest"], hashlib.sha256(b"qixi executable bytes\n").hexdigest())

  def test_rejects_expected_runtime_mismatch_even_when_archive_and_evidence_match(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory, runtime="httpBridge")
      evidence = write_minimal_evidence(directory, runtime="httpBridge")
      with self.assertRaisesRegex(
        matcher.ReleaseEvidenceArchiveMatchError,
        "QIXI_REAL_DEVICE_EXPECT_RUNTIME",
      ):
        matcher.validate_archive_match(evidence, archive, expected_runtime="nativeInProcess")

  def test_rejects_invalid_expected_runtime(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = write_minimal_evidence(directory)
      with self.assertRaisesRegex(
        matcher.ReleaseEvidenceArchiveMatchError,
        "must be httpBridge or nativeInProcess",
      ):
        matcher.validate_archive_match(evidence, archive, expected_runtime="native")

  def test_rejects_invalid_evidence_or_archive_runtime_without_expected_runtime(self) -> None:
    with self.subTest("same invalid runtime"):
      with tempfile.TemporaryDirectory() as raw_dir:
        directory = pathlib.Path(raw_dir)
        archive = write_minimal_archive(directory, runtime="sidecarRuntime")
        evidence = write_minimal_evidence(directory, runtime="sidecarRuntime")
        with self.assertRaisesRegex(
          matcher.ReleaseEvidenceArchiveMatchError,
          "real-device evidence app.analysisRuntime must be httpBridge or nativeInProcess",
        ):
          matcher.validate_archive_match(evidence, archive)

    with self.subTest("invalid archive runtime"):
      with tempfile.TemporaryDirectory() as raw_dir:
        directory = pathlib.Path(raw_dir)
        archive = write_minimal_archive(directory, runtime="sidecarRuntime")
        evidence = write_minimal_evidence(directory)
        with self.assertRaisesRegex(
          matcher.ReleaseEvidenceArchiveMatchError,
          "archive app Info.plist QixiAnalysisRuntime must be httpBridge or nativeInProcess",
        ):
          matcher.validate_archive_match(evidence, archive)

  def test_rejects_duplicate_json_keys_in_real_device_evidence(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = directory / "real-device-evidence.json"
      evidence.write_text(
        f"""
{{
  "schemaVersion": {matcher.REAL_DEVICE_EVIDENCE_SCHEMA_VERSION},
  "kind": "qixi-real-device-evidence",
  "app": {{
    "bundleIdentifier": "com.qixi.localanalysis",
    "version": "1.0",
    "version": "1.0",
    "build": "1",
    "analysisRuntime": "nativeInProcess"
  }}
}}
""".lstrip(),
        encoding="utf-8",
      )
      with self.assertRaisesRegex(
        matcher.ReleaseEvidenceArchiveMatchError,
        "duplicate JSON key 'version'",
      ):
        matcher.validate_archive_match(evidence, archive, expected_runtime="nativeInProcess")

  def test_rejects_non_standard_json_constants_in_real_device_evidence(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = directory / "real-device-evidence.json"
      evidence.write_text(
        '{"schemaVersion":NaN,"kind":"qixi-real-device-evidence","app":{}}\n',
        encoding="utf-8",
      )
      with self.assertRaisesRegex(
        matcher.ReleaseEvidenceArchiveMatchError,
        "non-standard JSON constant NaN",
      ):
        matcher.validate_archive_match(evidence, archive, expected_runtime="nativeInProcess")

  def test_rejects_stale_schema_or_wrong_kind_before_archive_identity_match(self) -> None:
    with self.subTest("stale schema"):
      with tempfile.TemporaryDirectory() as raw_dir:
        directory = pathlib.Path(raw_dir)
        archive = write_minimal_archive(directory)
        stale_schema = write_minimal_evidence(directory)
        payload = json.loads(stale_schema.read_text(encoding="utf-8"))
        payload["schemaVersion"] = matcher.REAL_DEVICE_EVIDENCE_SCHEMA_VERSION - 1
        stale_schema.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(
          matcher.ReleaseEvidenceArchiveMatchError,
          f"schemaVersion must be {matcher.REAL_DEVICE_EVIDENCE_SCHEMA_VERSION}",
        ):
          matcher.validate_archive_match(stale_schema, archive, expected_runtime="nativeInProcess")

    with self.subTest("wrong kind"):
      with tempfile.TemporaryDirectory() as raw_dir:
        directory = pathlib.Path(raw_dir)
        archive = write_minimal_archive(directory)
        wrong_kind = write_minimal_evidence(directory)
        payload = json.loads(wrong_kind.read_text(encoding="utf-8"))
        payload["kind"] = "qixi-device-log"
        wrong_kind.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(
          matcher.ReleaseEvidenceArchiveMatchError,
          f"kind must be {matcher.REAL_DEVICE_EVIDENCE_KIND}",
        ):
          matcher.validate_archive_match(wrong_kind, archive, expected_runtime="nativeInProcess")

  def test_cli_accepts_environment_paths(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = write_minimal_evidence(directory)
      env = os.environ.copy()
      env["QIXI_APPSTORE_ARCHIVE_PATH"] = str(archive)
      env["QIXI_REAL_DEVICE_EVIDENCE"] = str(evidence)
      env["QIXI_REAL_DEVICE_EXPECT_RUNTIME"] = "nativeInProcess"
      result = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "qixi_release_evidence_archive_match.py")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertIn("Release evidence/archive match passed:", result.stdout)
    self.assertIn("runtime=nativeInProcess", result.stdout)

  def test_cli_rejects_expected_runtime_mismatch_from_environment(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory, runtime="httpBridge")
      evidence = write_minimal_evidence(directory, runtime="httpBridge")
      env = os.environ.copy()
      env["QIXI_APPSTORE_ARCHIVE_PATH"] = str(archive)
      env["QIXI_REAL_DEVICE_EVIDENCE"] = str(evidence)
      env["QIXI_REAL_DEVICE_EXPECT_RUNTIME"] = "nativeInProcess"
      result = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "qixi_release_evidence_archive_match.py")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("QIXI_REAL_DEVICE_EXPECT_RUNTIME", result.stderr)
    self.assertIn("httpBridge", result.stderr)
    self.assertIn("nativeInProcess", result.stderr)

  def test_rejects_symlink_release_inputs_before_loading(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = write_minimal_evidence(directory)
      evidence.write_text("{not-json}\n", encoding="utf-8")
      linked_evidence = directory / "linked-real-device-evidence.json"
      linked_evidence.symlink_to(evidence)
      with self.assertRaisesRegex(matcher.ReleaseEvidenceArchiveMatchError, "symbolic links"):
        matcher.validate_archive_match(linked_evidence, archive, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      root = pathlib.Path(raw_dir)
      real_archive = write_minimal_archive(root / "real")
      evidence = write_minimal_evidence(root)
      linked_archive = root / "linked-Qixi.xcarchive"
      linked_archive.symlink_to(real_archive, target_is_directory=True)
      with self.assertRaisesRegex(matcher.ReleaseEvidenceArchiveMatchError, "symbolic links"):
        matcher.validate_archive_match(evidence, linked_archive, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = write_minimal_evidence(directory)
      app = archive / "Products" / "Applications" / "Qixi.app"
      target = archive / "Products" / "Applications" / "Qixi-target.app"
      app.rename(target)
      app.symlink_to(target, target_is_directory=True)
      with self.assertRaisesRegex(matcher.ReleaseEvidenceArchiveMatchError, "symbolic links"):
        matcher.validate_archive_match(evidence, archive, expected_runtime="nativeInProcess")

  def test_rejects_oversized_release_match_inputs_before_loading(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = directory / "real-device-evidence.json"
      write_sparse_file(evidence, matcher.REAL_DEVICE_EVIDENCE_MAX_BYTES + 1)
      with self.assertRaisesRegex(matcher.ReleaseEvidenceArchiveMatchError, "real-device evidence JSON exceeds bounded size"):
        matcher.validate_archive_match(evidence, archive, expected_runtime="nativeInProcess")

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = write_minimal_evidence(directory)
      write_sparse_file(archive / "Info.plist", matcher.ARCHIVE_PLIST_MAX_BYTES + 1)
      with self.assertRaisesRegex(matcher.ReleaseEvidenceArchiveMatchError, "archive plist exceeds bounded size"):
        matcher.validate_archive_match(evidence, archive, expected_runtime="nativeInProcess")

  def test_bounded_readers_recheck_opened_descriptor_is_regular(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      path = directory / "input.bin"
      path.write_bytes(b"qixi\n")

      def fake_open(_path: pathlib.Path, *_args: object, **_kwargs: object) -> DirectoryHandle:
        return DirectoryHandle(directory)

      with mock.patch.object(pathlib.Path, "open", fake_open):
        with self.assertRaisesRegex(matcher.ReleaseEvidenceArchiveMatchError, "real-device evidence JSON must be a regular file after opening"):
          matcher._bounded_bytes(path, "real-device evidence JSON", matcher.REAL_DEVICE_EVIDENCE_MAX_BYTES)
        with self.assertRaisesRegex(matcher.ReleaseEvidenceArchiveMatchError, "archive app executable must be a regular file after opening"):
          matcher._sha256_hex_digest(path, "archive app executable", matcher.ARCHIVE_EXECUTABLE_MAX_BYTES)

  def test_bounded_readers_recheck_opened_descriptor_byte_count(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      path = directory / "input.bin"
      path.write_bytes(b'{"kind":"qixi-real-device-evidence"}\n')

      def fake_open(_path: pathlib.Path, *_args: object, **_kwargs: object) -> DriftHandle:
        return DriftHandle(path)

      with mock.patch.object(pathlib.Path, "open", fake_open):
        with self.assertRaisesRegex(
          matcher.ReleaseEvidenceArchiveMatchError,
          "real-device evidence JSON opened-byte-count drift while reading",
        ):
          matcher._bounded_bytes(path, "real-device evidence JSON", matcher.REAL_DEVICE_EVIDENCE_MAX_BYTES)

  def test_hash_rechecks_opened_descriptor_byte_count(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      path = directory / "input.bin"
      path.write_bytes(b"qixi executable bytes\n")

      def fake_open(_path: pathlib.Path, *_args: object, **_kwargs: object) -> DriftHandle:
        return DriftHandle(path)

      with mock.patch.object(pathlib.Path, "open", fake_open):
        with self.assertRaisesRegex(
          matcher.ReleaseEvidenceArchiveMatchError,
          "archive app executable opened-byte-count drift while hashing",
        ):
          matcher._sha256_hex_digest(path, "archive app executable", matcher.ARCHIVE_EXECUTABLE_MAX_BYTES)

  def test_rejects_archive_identity_mismatches(self) -> None:
    cases = (
      ("bundle_identifier", "com.qixi.other", "app.bundleIdentifier"),
      ("version", "2.0", "app.version"),
      ("build", "99", "app.build"),
      ("runtime", "httpBridge", "app.analysisRuntime"),
      ("executable_sha256", "0" * 64, "app.executableSHA256HexDigest"),
    )
    for field, mismatched_evidence_value, expected_error in cases:
      with self.subTest(field=field):
        with tempfile.TemporaryDirectory() as raw_dir:
          directory = pathlib.Path(raw_dir)
          archive = write_minimal_archive(directory)
          kwargs = {field: mismatched_evidence_value}
          evidence = write_minimal_evidence(directory, **kwargs)
          with self.assertRaisesRegex(
            matcher.ReleaseEvidenceArchiveMatchError,
            expected_error,
          ):
            matcher.validate_archive_match(evidence, archive)

  def test_rejects_invalid_or_unsafe_archive_executable_identity(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = write_minimal_evidence(directory, executable_sha256="0" * 64)
      with self.assertRaisesRegex(
        matcher.ReleaseEvidenceArchiveMatchError,
        "archive app executable SHA-256",
      ):
        matcher.validate_archive_match(evidence, archive)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = write_minimal_evidence(directory, executable_sha256="ABC")
      with self.assertRaisesRegex(
        matcher.ReleaseEvidenceArchiveMatchError,
        "executableSHA256HexDigest must be a lowercase SHA-256",
      ):
        matcher.validate_archive_match(evidence, archive)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = write_minimal_evidence(directory)
      app_info_path = archive / "Products" / "Applications" / "Qixi.app" / "Info.plist"
      app_info = plistlib.loads(app_info_path.read_bytes())
      app_info["CFBundleExecutable"] = "../Qixi"
      with app_info_path.open("wb") as plist_file:
        plistlib.dump(app_info, plist_file)
      with self.assertRaisesRegex(
        matcher.ReleaseEvidenceArchiveMatchError,
        "CFBundleExecutable must be a plain executable filename",
      ):
        matcher.validate_archive_match(evidence, archive)

  def test_rejects_archive_application_properties_that_disagree_with_app_info(self) -> None:
    cases = (
      ("CFBundleIdentifier", "com.qixi.other", "ApplicationProperties.CFBundleIdentifier"),
      ("CFBundleShortVersionString", "2.0", "ApplicationProperties.CFBundleShortVersionString"),
      ("CFBundleVersion", "99", "ApplicationProperties.CFBundleVersion"),
    )
    for key, mismatched_archive_value, expected_error in cases:
      with self.subTest(key=key):
        with tempfile.TemporaryDirectory() as raw_dir:
          directory = pathlib.Path(raw_dir)
          archive = write_minimal_archive(directory)
          evidence = write_minimal_evidence(directory)
          archive_info_path = archive / "Info.plist"
          archive_info = plistlib.loads(archive_info_path.read_bytes())
          archive_info["ApplicationProperties"][key] = mismatched_archive_value
          with archive_info_path.open("wb") as plist_file:
            plistlib.dump(archive_info, plist_file)
          with self.assertRaisesRegex(
            matcher.ReleaseEvidenceArchiveMatchError,
            expected_error,
          ):
            matcher.validate_archive_match(evidence, archive)

  def test_rejects_archive_path_that_does_not_resolve_to_app_bundle(self) -> None:
    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = write_minimal_evidence(directory)
      archive_info_path = archive / "Info.plist"
      archive_info = plistlib.loads(archive_info_path.read_bytes())
      archive_info["ApplicationProperties"]["ApplicationPath"] = "Applications/Missing.app"
      with archive_info_path.open("wb") as plist_file:
        plistlib.dump(archive_info, plist_file)
      with self.assertRaisesRegex(
        matcher.ReleaseEvidenceArchiveMatchError,
        "ApplicationProperties.ApplicationPath",
      ):
        matcher.validate_archive_match(evidence, archive)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      archive = write_minimal_archive(directory)
      evidence = write_minimal_evidence(directory)
      outside = archive / "Escaped.app"
      outside.mkdir()
      with (outside / "Info.plist").open("wb") as plist_file:
        plistlib.dump(
          {
            "CFBundleIdentifier": "com.qixi.localanalysis",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "QixiAnalysisRuntime": "nativeInProcess",
          },
          plist_file,
        )
      archive_info_path = archive / "Info.plist"
      archive_info = plistlib.loads(archive_info_path.read_bytes())
      archive_info["ApplicationProperties"]["ApplicationPath"] = "../Escaped.app"
      with archive_info_path.open("wb") as plist_file:
        plistlib.dump(archive_info, plist_file)
      with self.assertRaisesRegex(
        matcher.ReleaseEvidenceArchiveMatchError,
        "must not traverse outside Products",
      ):
        matcher.validate_archive_match(evidence, archive)

  def test_cli_requires_both_paths(self) -> None:
    env = os.environ.copy()
    env.pop("QIXI_APPSTORE_ARCHIVE_PATH", None)
    env.pop("QIXI_REAL_DEVICE_EVIDENCE", None)
    result = subprocess.run(
      [sys.executable, str(ROOT / "scripts" / "qixi_release_evidence_archive_match.py")],
      cwd=ROOT,
      env=env,
      text=True,
      capture_output=True,
      check=False,
    )
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json is required", result.stderr)

    with tempfile.TemporaryDirectory() as raw_dir:
      directory = pathlib.Path(raw_dir)
      evidence = write_minimal_evidence(directory)
      env = os.environ.copy()
      env["QIXI_REAL_DEVICE_EVIDENCE"] = str(evidence)
      env.pop("QIXI_APPSTORE_ARCHIVE_PATH", None)
      result = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "qixi_release_evidence_archive_match.py")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
      )
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive is required", result.stderr)


if __name__ == "__main__":
  unittest.main()
