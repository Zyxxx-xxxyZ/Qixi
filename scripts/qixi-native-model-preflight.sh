#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

cd "$ROOT_DIR"

"$PYTHON_BIN" - <<'PY'
from __future__ import annotations

import os
import pathlib
import re
import sys
import hashlib
import stat as stat_module
import tempfile


TESTING_ENV = "QIXI_NATIVE_MODEL_PREFLIGHT_TESTING"
TEST_ROOT_ENV = "QIXI_NATIVE_MODEL_PREFLIGHT_TEST_ROOT"
SELFTEST_OPENED_DESCRIPTOR_ENV = "QIXI_NATIVE_MODEL_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR"
SOURCE_TEXT_MAX_BYTES = 4 * 1024 * 1024
MODEL_FILE_MAX_BYTES = 512 * 1024 * 1024
HASH_CHUNK_BYTES = 1024 * 1024


def fail(message: str) -> None:
  print(f"Native model preflight failed: {message}", file=sys.stderr)
  raise SystemExit(1)


def configured_root() -> pathlib.Path:
  override = pathlib.Path.cwd()
  raw_override = os.environ.get(TEST_ROOT_ENV, "").strip()
  if not raw_override:
    return override
  if os.environ.get(TESTING_ENV) != "1":
    fail(f"{TEST_ROOT_ENV} may only be used with {TESTING_ENV}=1")
  return pathlib.Path(raw_override).expanduser()


ROOT = configured_root()
REGISTRY = ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelRegistry.swift"
INTEGRITY = ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelIntegrity.swift"
INSTALLER = ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelInstaller.swift"
RECEIPT = ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeModelInstallReceipt.swift"
PROJECT = ROOT / "qixi-ios-native" / "Qixi.xcodeproj" / "project.pbxproj"
DOC = ROOT / "docs" / "native-katago-integration.md"

EXPECTED = {
  "b6": {
    "resource": "g170-b6c96-s175395328-d26788732.bin.gz",
    "path": ROOT / "KataGo" / "cpp" / "tests" / "models" / "g170-b6c96-s175395328-d26788732.bin.gz",
    "size": 3827339,
    "sha256": "f5d32604e3675c480c7c8f6aa579a1ea857135628a0afccc8fa56330fbacd38d",
    "minimum": 256,
    "recommended": 512,
    "maximum": 768,
  },
  "b18nbt": {
    "resource": "b18nbt.bin",
    "path": ROOT / "b18nbt.bin",
    "size": 105532578,
    "sha256": "46a623a366ef6ef423fa2055f1b094fd8f64c518c065e7d254a9e0829c192c5c",
    "minimum": 1024,
    "recommended": 1536,
    "maximum": 2048,
  },
  "b28nbt": {
    "resource": "b28nbt.bin",
    "path": ROOT / "b28nbt.bin",
    "size": 291771656,
    "sha256": "053d2411c311b5cb8f44d9960e431371460169561401ea35088a030b87337770",
    "minimum": 2048,
    "recommended": 3072,
    "maximum": 4096,
  },
}


def _is_allowed_platform_symlink_alias(path: pathlib.Path) -> bool:
  if sys.platform != "darwin":
    return False
  allowed_aliases = {
    pathlib.Path("/var"): pathlib.Path("/private/var"),
    pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
    pathlib.Path("/etc"): pathlib.Path("/private/etc"),
  }
  expected_target = allowed_aliases.get(path)
  if expected_target is None:
    return False
  try:
    return path.resolve(strict=True) == expected_target
  except OSError:
    return False


def reject_symlink_path(path: pathlib.Path, label: str) -> None:
  if path.is_symlink() and not _is_allowed_platform_symlink_alias(path):
    fail(f"{label} must not contain symbolic links: {path}")


def reject_symlink_components(path: pathlib.Path, label: str) -> None:
  current = pathlib.Path(path.anchor) if path.anchor else pathlib.Path()
  for part in path.parts:
    if part == path.anchor or not part:
      continue
    current = current / part
    reject_symlink_path(current, label)


def validate_regular_file(path: pathlib.Path, label: str) -> None:
  reject_symlink_components(path, label)
  if not path.exists():
    try:
      display_path = path.relative_to(ROOT)
    except ValueError:
      display_path = path
    fail(f"missing {display_path}")
  if not path.is_file():
    fail(f"{label} is not a regular file: {path}")


def opened_regular_file_stat(handle, path: pathlib.Path, label: str) -> os.stat_result:
  try:
    opened_stat = os.fstat(handle.fileno())
  except OSError as exc:
    fail(f"{label} could not be inspected after opening: {path}: {exc}")
  if not stat_module.S_ISREG(opened_stat.st_mode):
    fail(f"{label} must be a regular file after opening: {path}")
  return opened_stat


def bounded_bytes(path: pathlib.Path, label: str, max_bytes: int) -> bytes:
  validate_regular_file(path, label)
  try:
    size = path.stat().st_size
  except OSError as exc:
    fail(f"{label} could not be statted: {path}: {exc}")
  if size > max_bytes:
    fail(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {path}")
  try:
    with path.open("rb") as handle:
      opened_stat = opened_regular_file_stat(handle, path, label)
      if opened_stat.st_size > max_bytes:
        fail(f"{label} exceeds bounded size of {max_bytes} bytes after opening: {path}")
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    fail(f"{label} could not be read: {path}: {exc}")
  if len(data) > max_bytes:
    fail(f"{label} exceeds bounded size of {max_bytes} bytes before loading: {path}")
  return data


def read(path: pathlib.Path) -> str:
  label = f"source file {path.relative_to(ROOT)}"
  try:
    return bounded_bytes(path, label, SOURCE_TEXT_MAX_BYTES).decode("utf-8")
  except UnicodeDecodeError as exc:
    fail(f"{label} must be valid UTF-8: {path}: {exc}")


def sha256(path: pathlib.Path, label: str, max_bytes: int) -> str:
  validate_regular_file(path, label)
  try:
    size = path.stat().st_size
  except OSError as exc:
    fail(f"{label} could not be statted before hashing: {path}: {exc}")
  if size > max_bytes:
    fail(f"{label} exceeds bounded size of {max_bytes} bytes before hashing: {path}")
  digest = hashlib.sha256()
  bytes_read = 0
  try:
    with path.open("rb") as handle:
      opened_stat = opened_regular_file_stat(handle, path, label)
      if opened_stat.st_size > max_bytes:
        fail(f"{label} exceeds bounded size of {max_bytes} bytes after opening: {path}")
      for chunk in iter(lambda: handle.read(HASH_CHUNK_BYTES), b""):
        bytes_read += len(chunk)
        if bytes_read > max_bytes:
          fail(f"{label} exceeds bounded size of {max_bytes} bytes while hashing: {path}")
        digest.update(chunk)
  except OSError as exc:
    fail(f"{label} could not be hashed: {path}: {exc}")
  if bytes_read != opened_stat.st_size:
    fail(f"{label} opened-byte-count drift while hashing: opened={opened_stat.st_size}, read={bytes_read}")
  return digest.hexdigest()


def selftest_opened_descriptor_recheck() -> None:
  if os.environ.get(SELFTEST_OPENED_DESCRIPTOR_ENV) != "1":
    return
  if os.environ.get(TESTING_ENV) != "1":
    fail(f"{SELFTEST_OPENED_DESCRIPTOR_ENV} may only be used with {TESTING_ENV}=1")
  with tempfile.TemporaryDirectory() as raw_dir:
    directory = pathlib.Path(raw_dir)
    fd = os.open(directory, os.O_RDONLY)
    try:
      class DirectoryHandle:
        def fileno(self) -> int:
          return fd

      opened_regular_file_stat(DirectoryHandle(), directory / "QixiNativeModelRegistry.swift", "native model registry")
    finally:
      os.close(fd)
  fail("opened descriptor self-test did not reject a directory descriptor")


selftest_opened_descriptor_recheck()


registry = read(REGISTRY)
integrity = read(INTEGRITY)
installer = read(INSTALLER)
receipt = read(RECEIPT)
project = read(PROJECT)
doc = read(DOC)

for engine, expected in EXPECTED.items():
  case_pattern = re.compile(
    rf"case \.{re.escape(engine)}:\s*"
    rf"return NativeKataGoModelSpec\(\s*"
    rf"engine: engine,\s*"
    rf'resourceName: "([^"]+)",\s*'
    rf"expectedByteCount: ([0-9]+),\s*"
    rf'sha256HexDigest: "([0-9a-f]{{64}})",\s*'
    rf"minimumMemoryMB: ([0-9]+),\s*"
    rf"recommendedMemoryMB: ([0-9]+),\s*"
    rf"maximumMemoryMB: ([0-9]+)",
    re.S,
  )
  match = case_pattern.search(registry)
  if not match:
    fail(f"registry is missing native model spec for {engine}")

  resource, byte_count, sha256_digest, minimum, recommended, maximum = match.groups()
  byte_count = int(byte_count)
  minimum = int(minimum)
  recommended = int(recommended)
  maximum = int(maximum)

  if resource != expected["resource"]:
    fail(f"{engine} resource mismatch: registry={resource}, expected={expected['resource']}")
  if byte_count != expected["size"]:
    fail(f"{engine} expectedByteCount drifted: registry={byte_count}, expected={expected['size']}")
  if sha256_digest != expected["sha256"]:
    fail(f"{engine} sha256 digest drifted in registry")
  if (minimum, recommended, maximum) != (
    expected["minimum"],
    expected["recommended"],
    expected["maximum"],
  ):
    fail(f"{engine} memory budget drifted without updating preflight")
  if not (0 < minimum <= recommended <= maximum):
    fail(f"{engine} memory budget must satisfy 0 < minimum <= recommended <= maximum")

  model_path = expected["path"]
  validate_regular_file(model_path, f"{engine} model file")
  actual_size = model_path.stat().st_size
  if actual_size != expected["size"]:
    fail(f"{engine} model size changed: {actual_size} != {expected['size']}")
  if actual_size > MODEL_FILE_MAX_BYTES:
    fail(f"{engine} model file exceeds bounded size of {MODEL_FILE_MAX_BYTES} bytes before hashing")
  actual_sha256 = sha256(model_path, f"{engine} model file", MODEL_FILE_MAX_BYTES)
  if actual_sha256 != expected["sha256"]:
    fail(f"{engine} model SHA-256 changed: {actual_sha256} != {expected['sha256']}")
  if actual_size >= minimum * 1024 * 1024:
    fail(f"{engine} minimum memory budget is too small for the model file size")

  if expected["resource"] in project:
    fail(
      f"{expected['resource']} is referenced by the Xcode project; "
      "large native models need an explicit bundled/on-demand packaging plan"
    )
  if expected["resource"] not in doc:
    fail(f"native integration doc does not mention {expected['resource']}")

if "AnalysisEngine.allCases.compactMap(spec(for:))" not in registry:
  fail("registry allSpecs must derive from AnalysisEngine.allCases")
if "struct QixiNativeDeviceMemoryPolicy" not in registry or "ProcessInfo.processInfo.physicalMemory" not in registry:
  fail("registry must define a native device memory policy using physical device memory")
if "defaultReservedSystemMemoryMB = 1024" not in registry or "availableMemoryMB" not in registry:
  fail("native memory policy must reserve system memory before allowing model loads")
if "report(for: spec).availableMemoryMB >= spec.minimumMemoryMB" not in registry:
  fail("native memory policy must gate loads on each model minimum memory budget")
if "modelFileMatchesManifest(candidate, spec: spec)" not in registry:
  fail("model store must reject files that do not match the native model manifest")
if "QixiNativeModelIntegrity.byteCountMatchesManifest" not in registry:
  fail("model store must delegate byte-count checks to QixiNativeModelIntegrity")
if "trustedInstallReceiptDirectories" not in registry or "QixiNativeModelInstallReceiptStore.receiptMatchesManifest" not in registry:
  fail("model store must require matching install receipts for trusted managed directories")
if "NativeKataGoCoreMLPackageSpec" not in registry or "coreMLPackages: [NativeKataGoCoreMLPackageSpec] = []" not in registry:
  fail("registry must support optional preconverted CoreML package specs")
if "QixiNativeCoreMLPackageInstallReceiptStore.receiptMatchesManifest" not in registry:
  fail("model store must require matching install receipts for trusted managed CoreML package directories")
if "resolvedCoreMLPackageURLs" not in registry or "coreMLPackageURLs" not in registry:
  fail("model store must refuse raw models whose required CoreML packages are missing")
if "cleanupTrustedInstallArtifacts()" not in registry or "QixiNativeModelInstallArtifactCleaner.cleanupOrphanedArtifacts" not in registry:
  fail("model store must clean stale installer artifacts in trusted managed directories before resolving")
if "cleanupCoreMLPackageArtifactsIfTrusted" not in registry or "cleanupOrphanedCoreMLPackageArtifacts" not in registry:
  fail("model store must clean stale trusted CoreML package artifacts before resolving")
if "import CryptoKit" not in integrity:
  fail("native model integrity verifier must use CryptoKit for SHA-256")
if "FileHandle(forReadingFrom: url)" not in integrity or "readData(ofLength: chunkByteCount)" not in integrity:
  fail("native model integrity verifier must hash models in streaming chunks")
if "validateRegularOpenModelFile" not in integrity or "fstat(handle.fileDescriptor, &statBuffer)" not in integrity:
  fail("native model integrity verifier must fstat the opened model file before trusting byte count or hash input")
if "statBuffer.st_size" not in integrity or "spec.expectedByteCount" not in integrity:
  fail("native model integrity verifier must check byte count before resolving a model")
if "verifyModel" not in integrity or "sha256Mismatch" not in integrity:
  fail("native model integrity verifier must expose strong install-time verification")
if "QixiNativeCoreMLPackageIntegrity" not in integrity or "verifyPackage" not in integrity or "packageTreeDigest" not in integrity:
  fail("native CoreML package integrity verifier must expose recursive tree-digest verification")
if "unsupportedPackageEntry" not in integrity or "sha256TreeDigest" not in integrity:
  fail("native CoreML package integrity verifier must reject unsupported entries and compare tree digests")
if "validateRegularOpenPackageFile" not in integrity or "fstat(handle.fileDescriptor, &statBuffer)" not in integrity:
  fail("native CoreML package integrity verifier must fstat opened package files before hashing")
if "maxFileCount: packageSpec.expectedFileCount" not in integrity or "maxTotalByteCount: packageSpec.expectedTotalByteCount" not in integrity:
  fail("native CoreML package integrity verifier must pass manifest file and byte budgets into package enumeration")
if "if let maxFileCount, fileCount > maxFileCount" not in integrity or "if let maxTotalByteCount, totalByteCount > maxTotalByteCount" not in integrity:
  fail("native CoreML package integrity verifier must reject file and byte budget overflow during enumeration")
if "QixiNativeModelInstaller.swift in Sources" not in project:
  fail("native model installer must be compiled into the app target")
if "QixiNativeModelInstallReceipt.swift in Sources" not in project:
  fail("native model receipt store must be compiled into the app target")
if "QixiNativeModelIntegrity.verifyModel" not in installer:
  fail("native model installer must strongly verify source and staged model files")
if "QixiNativeModelInstallArtifactCleaner.cleanupOrphanedArtifacts" not in installer or "excluding: [sourceURL]" not in installer:
  fail("native model installer must clean stale install artifacts before staging a new model")
if "enum QixiNativeModelInstallArtifactCleaner" not in installer or "cleanupOrphanedArtifacts" not in installer:
  fail("native model installer artifact cleanup must be shared with runtime model resolution")
if "isInstallerArtifact" not in installer or ".skipsSubdirectoryDescendants" not in installer:
  fail("native model installer artifact cleanup must be whitelist-based and non-recursive")
if "isRemovableInstallerArtifact" not in installer or ".isRegularFileKey" not in installer or ".isSymbolicLinkKey" not in installer:
  fail("native model installer artifact cleanup must only remove regular file artifacts, not directories or symlinks")
if "cleanupOrphanedCoreMLPackageArtifacts" not in installer or "coreml-package-tmp" not in installer or "coreml-package-backup" not in installer:
  fail("native model installer must clean directory-shaped CoreML package temp and backup artifacts explicitly")
if "isRemovableCoreMLPackageArtifact" not in installer or ".isDirectoryKey" not in installer:
  fail("native CoreML package artifact cleanup must explicitly handle directories without following symlinks")
if "copyItem(at: sourceURL, to: temporaryURL)" not in installer:
  fail("native model installer must stage copies through a temporary file")
if "markExcludedFromBackup(temporaryURL)" not in installer:
  fail("native model installer must exclude temporary staged model files from iCloud backup")
if "moveItem(at: temporaryURL, to: destinationURL)" not in installer:
  fail("native model installer must commit staged models into the managed directory")
if "moveItem(at: destinationURL, to: backupURL)" not in installer:
  fail("native model installer must move the previous model to an explicit backup while replacing")
if "moveItem(at: receiptURL, to: receiptBackupURL)" not in installer:
  fail("native model installer must move the previous receipt to an explicit backup while replacing")
if "didMoveReceiptToBackup" not in installer or "didStartWritingNewReceipt" not in installer:
  fail("native model installer must track install stages before restoring receipt backups")
if "markExcludedFromBackup(backupURL)" not in installer or "markExcludedFromBackup(receiptBackupURL)" not in installer:
  fail("native model installer must exclude temporary backup artifacts from iCloud backup")
if "isExcludedFromBackup = true" not in installer:
  fail("native model installer must exclude managed model files from iCloud backup")
if "QixiNativeModelInstallReceiptStore.writeReceipt" not in installer:
  fail("native model installer must write a verified install receipt after commit")
if "QixiNativeCoreMLPackageInstallReceiptStore.writeReceipt" not in installer:
  fail("native model installer must write a verified CoreML package install receipt after commit")
if "recognizedCoreMLPackageMatch" not in installer or "installVerifiedCoreMLPackage" not in installer:
  fail("native model installer must recognize and install preconverted CoreML package manifests")
if "try? fileManager.removeItem(at: destinationURL)" not in installer:
  fail("native model installer must remove a committed model if receipt writing fails")
if "try? fileManager.moveItem(at: backupURL, to: destinationURL)" not in installer:
  fail("native model installer must restore the previous model if receipt writing fails during replacement")
if "try? fileManager.moveItem(at: receiptBackupURL, to: receiptURL)" not in installer:
  fail("native model installer must restore the previous receipt if replacement fails")
if "struct NativeKataGoModelInstallReceipt" not in receipt or "Codable, Equatable" not in receipt:
  fail("native model install receipt must have a codable stable schema")
if "struct NativeKataGoCoreMLPackageInstallReceipt" not in receipt or "QixiNativeCoreMLPackageInstallReceiptStore" not in receipt:
  fail("native CoreML package install receipt must have a codable stable schema")
if "static let schemaVersion = 3" not in receipt or "qixi-model-receipt.json" not in receipt:
  fail("native model install receipt must have a versioned hidden receipt filename")
if "qixi-coreml-package-receipt.json" not in receipt or "installedFileCount" not in receipt or "installedTotalByteCount" not in receipt:
  fail("native CoreML package install receipt must record a versioned hidden package fingerprint")
if "installedByteCount: UInt64" not in receipt or "installedModificationTimeSince1970: TimeInterval" not in receipt:
  fail("native model install receipt must record cheap installed-file time and size fingerprints")
if "installedDeviceID: Int64" not in receipt or "installedFileID: Int64" not in receipt:
  fail("native model install receipt must record cheap installed-file identity fingerprints")
if "openedRegularModelStat(at: modelURL)" not in receipt or "statBuffer.st_ino" not in receipt:
  fail("native model install receipt must derive its fingerprint from opened fstat metadata")
if "receiptMatchesManifest" not in receipt or "existing == expected" not in receipt:
  fail("native model install receipt must compare against the current model manifest and installed-file fingerprint")
if "markExcludedFromBackup(receiptDirectory)" not in receipt or "markExcludedFromBackup(receiptURL)" not in receipt:
  fail("native model install receipt writer must exclude receipt directories and files from iCloud backup")
if "QixiNativeModelRegistry" not in doc or "memory budgets" not in doc:
  fail("native integration doc must describe native model registry and memory budgets")
if "SHA-256" not in doc or "expected byte count" not in doc or "QixiNativeModelIntegrity" not in doc:
  fail("native integration doc must describe model byte-count and SHA-256 validation")
if "QixiNativeModelInstaller" not in doc or "iCloud backup" not in doc:
  fail("native integration doc must describe verified native model installation")
if "install receipt" not in doc or "trusted managed" not in doc:
  fail("native integration doc must describe managed model install receipts")
if "QixiNativeDeviceMemoryPolicy" not in doc or "minimum memory budget" not in doc:
  fail("native integration doc must describe the native device memory gate")
if "NativeKataGoCoreMLPackageSpec" not in doc or "QixiNativeCoreMLPackageIntegrity" not in doc:
  fail("native integration doc must describe preconverted CoreML package manifests and verification")
if ".mlpackage" not in doc or ".mlmodelc" not in doc or "QixiNativeCoreMLPackageInstallReceiptStore" not in doc:
  fail("native integration doc must describe CoreML package import and receipts")
if "coreMLPackagePaths" not in doc or "NativeKataGoModelConfig" not in doc:
  fail("native integration doc must describe passing verified CoreML package paths into native model config")

print("Native model preflight passed")
PY
