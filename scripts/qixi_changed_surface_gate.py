#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import pathlib
import subprocess
import sys
from dataclasses import dataclass


ROOT = pathlib.Path(__file__).resolve().parents[1]

MODEL_ARTIFACT_PATTERNS = (
  "*.bin",
  "*.bin.gz",
  "*.txt.gz",
  "*.onnx",
  "*.mlmodel",
  "*.mlmodelc",
  "*.mlmodelc/**",
  "*.mlpackage",
  "*.mlpackage/**",
  "Models/**",
)

SCREENSHOT_RELEVANT_PATTERNS = (
  "qixi-ios-native/Qixi/*.swift",
  "qixi-ios-native/Qixi/Resources/**",
  "qixi-ios-native/Qixi.xcodeproj/**",
  "qixi-ios-native/scripts/build_screenshot_review_board.py",
  "qixi-ios-native/scripts/performance-smoke-sim.sh",
  "qixi-ios-native/scripts/persistence-smoke-sim.sh",
  "qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh",
  "qixi-ios-native/scripts/screenshot*.sh",
  "qixi-ios-native/tests/inspect_*screenshot*.py",
  "qixi-ios-native/tests/screenshot_manifest_json.py",
  "qixi-ios-native/tests/screenshot_coverage_manifest.json",
  "qixi-ios-native/tests/test_screenshot*.py",
  "qixi-ios-native/tests/test_frontend_contract.py",
  "qixi-ios-native/tests/test_localization_contract.py",
)

REAL_MODEL_RELEVANT_PATTERNS = (
  *MODEL_ARTIFACT_PATTERNS,
  "KataGo/cpp/**",
  "qixi-ios-sim/backend/**",
  "qixi-ios-sim/configs/**",
  "qixi-ios-sim/tests/integration*.py",
  "qixi-ios-sim/tests/test_backend_contract.py",
  "tests/fixtures/position_identity_cases.json",
  "tests/validate_position_identity_fixture.py",
  "tests/test_position_identity_fixture_validator.py",
  "qixi-ios-native/Qixi/BackendClient.swift",
  "qixi-ios-native/Qixi/QixiAnalysisService.swift",
  "qixi-ios-native/Qixi/QixiHTTPBridgeAnalysisService.swift",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.swift",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.h",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.hpp",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.mm",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.cpp",
  "qixi-ios-native/Qixi/Qixi-Bridging-Header.h",
  "qixi-ios-native/Qixi/QixiNativeModel*.swift",
  "qixi-ios-native/Qixi/QixiPositionIdentity.swift",
  "qixi-ios-native/Qixi/QixiModels.swift",
  "qixi-ios-native/tests/run_analysis_service_smoke.sh",
  "qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh",
  "qixi-ios-native/tests/native_katago*.cpp",
  "qixi-ios-native/scripts/native-release-sim-smoke.sh",
  "scripts/qixi-ios-katago-cmake-preflight.sh",
  "scripts/qixi-native-inprocess-contract-preflight.sh",
  "scripts/qixi-native-linked-build-preflight.sh",
  "scripts/qixi-native-release-build-preflight.sh",
  "scripts/qixi-native-model-preflight.sh",
)

IOS_KATAGO_CMAKE_RELEVANT_PATTERNS = (
  *MODEL_ARTIFACT_PATTERNS,
  "KataGo/cpp/**",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.swift",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.h",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.hpp",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.mm",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.cpp",
  "qixi-ios-native/Qixi/Qixi-Bridging-Header.h",
  "qixi-ios-native/Qixi/QixiNativeModel*.swift",
  "qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh",
  "qixi-ios-native/tests/native_katago*.cpp",
  "qixi-ios-native/scripts/native-release-sim-smoke.sh",
  "scripts/qixi-ios-katago-cmake-preflight.sh",
  "scripts/qixi-native-inprocess-contract-preflight.sh",
  "scripts/qixi-native-linked-build-preflight.sh",
  "scripts/qixi-native-release-build-preflight.sh",
  "scripts/qixi-native-model-preflight.sh",
)

NATIVE_RELEASE_SIM_RELEVANT_PATTERNS = (
  *MODEL_ARTIFACT_PATTERNS,
  "KataGo/cpp/**",
  "qixi-ios-native/Qixi.xcodeproj/**",
  "qixi-ios-native/Qixi/Info.plist",
  "qixi-ios-native/Qixi/NativeReleaseInfo.plist",
  "qixi-ios-native/Qixi/Qixi-Bridging-Header.h",
  "qixi-ios-native/Qixi/QixiAnalysisService.swift",
  "qixi-ios-native/Qixi/QixiApp.swift",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.swift",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.h",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.hpp",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.mm",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.cpp",
  "qixi-ios-native/Qixi/QixiNativeModel*.swift",
  "qixi-ios-native/Qixi/QixiPersistence.swift",
  "qixi-ios-native/Qixi/QixiPositionIdentity.swift",
  "qixi-ios-native/Qixi/QixiRealDeviceEvidence.swift",
  "qixi-ios-native/Qixi/QixiSync.swift",
  "qixi-ios-native/Qixi/QixiViewModel.swift",
  "qixi-ios-native/scripts/native-release-sim-smoke.sh",
  "scripts/qixi-ios-katago-cmake-preflight.sh",
  "scripts/qixi-native-linked-build-preflight.sh",
  "scripts/qixi-native-release-build-preflight.sh",
  "scripts/qixi-device-bridge-smoke.sh",
  "scripts/qixi_device_bridge_smoke.py",
  "scripts/qixi-device-signing-doctor.sh",
  "scripts/qixi_device_signing_doctor.py",
  "scripts/qixi-device-bridge-plan-inspect.sh",
  "scripts/qixi-device-bridge-smoke-inspect.sh",
  "scripts/qixi-device-bridge-failure-inspect.sh",
  "scripts/qixi_device_bridge_smoke_inspect.py",
  "scripts/qixi-quality-gate.sh",
)

RELEASE_SENSITIVE_PATTERNS = (
  *MODEL_ARTIFACT_PATTERNS,
  "README.md",
  ".gitignore",
  ".github/workflows/qixi-quality.yml",
  ".github/pull_request_template.md",
  "docs/app-store-readiness.md",
  "docs/native-ios-runbook.md",
  "docs/native-katago-integration.md",
  "docs/pr-verification-matrix.md",
  "docs/quality-gates.md",
  "scripts/qixi-appstore-archive-preflight.sh",
  "scripts/qixi-appstore-preflight.sh",
  "scripts/qixi-release-evidence-gate.sh",
  "scripts/qixi-real-device-evidence-preflight.sh",
  "scripts/qixi-real-device-evidence-template.py",
  "scripts/qixi-real-device-run-kit-preflight.sh",
  "scripts/qixi_real_device_evidence_preflight.py",
  "scripts/qixi_real_device_run_kit_preflight.py",
  "scripts/qixi_release_evidence_archive_match.py",
  "scripts/qixi-native-linked-build-preflight.sh",
  "scripts/qixi-native-release-build-preflight.sh",
  "scripts/qixi-device-run-preflight.sh",
  "scripts/qixi_device_run_preflight.py",
  "scripts/qixi-device-bridge-smoke.sh",
  "scripts/qixi_device_bridge_smoke.py",
  "scripts/qixi-device-signing-doctor.sh",
  "scripts/qixi_device_signing_doctor.py",
  "scripts/qixi-device-bridge-plan-inspect.sh",
  "scripts/qixi-device-bridge-smoke-inspect.sh",
  "scripts/qixi-device-bridge-failure-inspect.sh",
  "scripts/qixi_device_bridge_smoke_inspect.py",
  "scripts/qixi-ios-katago-cmake-preflight.sh",
  "qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh",
  "qixi-ios-native/scripts/native-release-sim-smoke.sh",
  "scripts/qixi-quality-gate.sh",
  "scripts/qixi-repo-hygiene-preflight.sh",
  "scripts/qixi_changed_surface_gate.py",
  "tests/test_project_quality_contract.py",
  "tests/test_repo_hygiene_preflight.py",
  "tests/test_quality_gate_skip_audit.py",
  "tests/fixtures/position_identity_cases.json",
  "tests/validate_position_identity_fixture.py",
  "tests/test_position_identity_fixture_validator.py",
  "tests/test_real_device_evidence_preflight.py",
  "tests/test_real_device_evidence_template.py",
  "tests/test_real_device_run_kit_preflight.py",
  "tests/test_device_run_preflight.py",
  "tests/test_device_signing_doctor.py",
  "tests/test_device_bridge_smoke.py",
  "tests/test_device_bridge_smoke_inspector.py",
  "tests/test_release_evidence_archive_match.py",
  "tests/test_changed_surface_gate.py",
  "qixi-ios-native/Qixi.xcodeproj/**",
  "qixi-ios-native/Qixi/Info.plist",
  "qixi-ios-native/Qixi/NativeReleaseInfo.plist",
  "qixi-ios-native/Qixi/PrivacyInfo.xcprivacy",
  "qixi-ios-native/Qixi/Qixi.entitlements",
  "qixi-ios-native/Qixi/Qixi-Bridging-Header.h",
  "qixi-ios-native/Qixi/QixiAnalysisService.swift",
  "qixi-ios-native/Qixi/QixiApp.swift",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.swift",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.h",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.hpp",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.mm",
  "qixi-ios-native/Qixi/QixiNativeKataGo*.cpp",
  "qixi-ios-native/Qixi/QixiNativeModel*.swift",
  "qixi-ios-native/Qixi/QixiNativeModelRegistry.swift",
  "qixi-ios-native/Qixi/QixiPersistence.swift",
  "qixi-ios-native/Qixi/QixiPositionIdentity.swift",
  "qixi-ios-native/Qixi/QixiRealDeviceEvidence.swift",
  "qixi-ios-native/Qixi/QixiSync.swift",
  "qixi-ios-native/Qixi/QixiViewModel.swift",
  "qixi-ios-native/README.md",
  "qixi-ios-sim/README.md",
)


class ChangedSurfaceGateError(RuntimeError):
  pass


@dataclass(frozen=True)
class ChangedSurfaceClassification:
  changed_files: tuple[str, ...]
  screenshot_relevant_files: tuple[str, ...]
  real_model_relevant_files: tuple[str, ...]
  ios_katago_cmake_relevant_files: tuple[str, ...]
  native_release_sim_relevant_files: tuple[str, ...]
  release_sensitive_files: tuple[str, ...]

  @property
  def requires_screenshots(self) -> bool:
    return bool(self.screenshot_relevant_files)

  @property
  def requires_real_models(self) -> bool:
    return bool(self.real_model_relevant_files)

  @property
  def requires_ios_katago_cmake(self) -> bool:
    return bool(self.ios_katago_cmake_relevant_files)

  @property
  def requires_native_release_sim(self) -> bool:
    return bool(self.native_release_sim_relevant_files)

  @property
  def requires_release_review(self) -> bool:
    return bool(self.release_sensitive_files)

  def as_json(self) -> dict:
    return {
      "changedFiles": list(self.changed_files),
      "requiresScreenshots": self.requires_screenshots,
      "screenshotRelevantFiles": list(self.screenshot_relevant_files),
      "requiresRealModels": self.requires_real_models,
      "realModelRelevantFiles": list(self.real_model_relevant_files),
      "requiresIOSKataGoCMake": self.requires_ios_katago_cmake,
      "iosKataGoCMakeRelevantFiles": list(self.ios_katago_cmake_relevant_files),
      "requiresNativeReleaseSim": self.requires_native_release_sim,
      "nativeReleaseSimRelevantFiles": list(self.native_release_sim_relevant_files),
      "requiresReleaseReview": self.requires_release_review,
      "releaseSensitiveFiles": list(self.release_sensitive_files),
    }


def normalize_changed_path(path: str) -> str:
  if "\\" in path:
    raise ChangedSurfaceGateError(f"changed file path must use POSIX separators and must not contain backslashes: {path!r}")
  normalized = path
  while normalized.startswith("./"):
    normalized = normalized[2:]
  if not normalized:
    return ""
  if normalized != normalized.strip():
    raise ChangedSurfaceGateError(f"changed file path must not contain surrounding whitespace: {path!r}")
  if normalized.startswith("/") or normalized.startswith("~"):
    raise ChangedSurfaceGateError(f"changed file path must be repository-relative: {path!r}")
  if any(ord(character) < 32 or ord(character) == 127 for character in normalized):
    raise ChangedSurfaceGateError(f"changed file path must not contain control characters: {path!r}")
  parts = normalized.split("/")
  if any(part in ("", ".", "..") for part in parts):
    raise ChangedSurfaceGateError(f"changed file path must not contain empty, current-directory, or parent-directory segments: {path!r}")
  return normalized


def split_changed_files(raw: str) -> list[str]:
  if "\0" in raw:
    pieces = raw.split("\0")
  elif "\n" in raw:
    pieces = raw.splitlines()
  else:
    pieces = raw.split(",")
  return [normalized for piece in pieces if (normalized := normalize_changed_path(piece))]


def path_matches_any(path: str, patterns: tuple[str, ...]) -> bool:
  return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


def classify_changed_files(paths: list[str]) -> ChangedSurfaceClassification:
  normalized_paths: list[str] = []
  for path in paths:
    normalized_path = normalize_changed_path(path)
    if normalized_path:
      normalized_paths.append(normalized_path)
  normalized = tuple(dict.fromkeys(normalized_paths))
  screenshot_files = tuple(
    path for path in normalized
    if path_matches_any(path, SCREENSHOT_RELEVANT_PATTERNS)
  )
  real_model_files = tuple(
    path for path in normalized
    if path_matches_any(path, REAL_MODEL_RELEVANT_PATTERNS)
  )
  ios_katago_cmake_files = tuple(
    path for path in normalized
    if path_matches_any(path, IOS_KATAGO_CMAKE_RELEVANT_PATTERNS)
  )
  native_release_sim_files = tuple(
    path for path in normalized
    if path_matches_any(path, NATIVE_RELEASE_SIM_RELEVANT_PATTERNS)
  )
  release_files = tuple(
    path for path in normalized
    if path_matches_any(path, RELEASE_SENSITIVE_PATTERNS)
  )
  return ChangedSurfaceClassification(
    changed_files=normalized,
    screenshot_relevant_files=screenshot_files,
    real_model_relevant_files=real_model_files,
    ios_katago_cmake_relevant_files=ios_katago_cmake_files,
    native_release_sim_relevant_files=native_release_sim_files,
    release_sensitive_files=release_files,
  )


def changed_files_from_env() -> list[str] | None:
  raw = os.environ.get("QIXI_CHANGED_FILES", "")
  if not raw:
    return None
  return split_changed_files(raw)


def run_git_diff(args: list[str]) -> list[str]:
  result = subprocess.run(
    ["git", *args],
    cwd=ROOT,
    text=True,
    capture_output=True,
    check=False,
  )
  if result.returncode != 0:
    detail = result.stderr.strip() or result.stdout.strip()
    raise ChangedSurfaceGateError(f"git {' '.join(args)} failed: {detail}")
  return split_changed_files(result.stdout)


def changed_files_from_git(base_ref: str | None) -> list[str]:
  if base_ref:
    candidates = [
      f"origin/{base_ref}...HEAD",
      f"{base_ref}...HEAD",
    ]
    failures: list[str] = []
    for candidate in candidates:
      try:
        return run_git_diff(["diff", "--name-only", "-z", candidate])
      except ChangedSurfaceGateError as exc:
        failures.append(str(exc))
    raise ChangedSurfaceGateError(
      "could not classify changed files against base ref "
      f"{base_ref!r}; tried {', '.join(candidates)}. Details: {' | '.join(failures)}"
    )
  return run_git_diff(["diff", "--name-only", "-z", "HEAD~1...HEAD"])


def github_output_delimiter(name: str, value: str) -> str:
  digest = hashlib.sha256(f"{name}\0{value}".encode("utf-8")).hexdigest()
  lines = set(value.splitlines())
  normalized_name = "".join(character if character.isalnum() else "_" for character in name.upper())
  for suffix in range(1000):
    delimiter = f"QIXI_{normalized_name}_{digest}_{suffix}_EOF"
    if delimiter not in lines:
      return delimiter
  raise ChangedSurfaceGateError(f"could not choose a safe GitHub output delimiter for {name}")


def write_multiline_github_output(out, name: str, lines: tuple[str, ...]) -> None:
  value = "\n".join(lines)
  delimiter = github_output_delimiter(name, value)
  out.write(f"{name}<<{delimiter}\n")
  out.write(value)
  if value:
    out.write("\n")
  out.write(f"{delimiter}\n")


def write_github_output(path: pathlib.Path, classification: ChangedSurfaceClassification) -> None:
  with path.open("a", encoding="utf-8") as out:
    out.write(f"requires_screenshots={'true' if classification.requires_screenshots else 'false'}\n")
    write_multiline_github_output(out, "screenshot_relevant_files", classification.screenshot_relevant_files)
    out.write(f"requires_real_models={'true' if classification.requires_real_models else 'false'}\n")
    write_multiline_github_output(out, "real_model_relevant_files", classification.real_model_relevant_files)
    out.write(f"requires_ios_katago_cmake={'true' if classification.requires_ios_katago_cmake else 'false'}\n")
    write_multiline_github_output(out, "ios_katago_cmake_relevant_files", classification.ios_katago_cmake_relevant_files)
    out.write(f"requires_native_release_sim={'true' if classification.requires_native_release_sim else 'false'}\n")
    write_multiline_github_output(out, "native_release_sim_relevant_files", classification.native_release_sim_relevant_files)
    out.write(f"requires_release_review={'true' if classification.requires_release_review else 'false'}\n")
    write_multiline_github_output(out, "release_sensitive_files", classification.release_sensitive_files)


def main() -> int:
  parser = argparse.ArgumentParser(description="Classify changed Qixi surfaces for expensive evidence gates.")
  parser.add_argument("--base-ref", default=os.environ.get("GITHUB_BASE_REF") or os.environ.get("QIXI_BASE_REF"))
  parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
  parser.add_argument("--json", action="store_true", help="Print machine-readable classification JSON.")
  args = parser.parse_args()

  try:
    changed_files = changed_files_from_env()
    if changed_files is None:
      changed_files = changed_files_from_git(args.base_ref)
    classification = classify_changed_files(changed_files)
    if args.github_output:
      write_github_output(pathlib.Path(args.github_output), classification)
  except ChangedSurfaceGateError as exc:
    print(f"Changed-surface gate failed: {exc}", file=sys.stderr)
    return 1

  if args.json:
    print(json.dumps(classification.as_json(), indent=2, sort_keys=True))
  elif classification.requires_screenshots:
    print("Screenshot gate required for changed files:")
    for path in classification.screenshot_relevant_files:
      print(f"- {path}")
    if classification.requires_real_models:
      print("Real-model gate also required for changed files:")
      for path in classification.real_model_relevant_files:
        print(f"- {path}")
    if classification.requires_ios_katago_cmake:
      print("iOS KataGo CMake gate also required for changed files:")
      for path in classification.ios_katago_cmake_relevant_files:
        print(f"- {path}")
    if classification.requires_native_release_sim:
      print("NativeRelease simulator gate also required for changed files:")
      for path in classification.native_release_sim_relevant_files:
        print(f"- {path}")
    if classification.requires_release_review:
      print("Release/App Store review also required for changed files:")
      for path in classification.release_sensitive_files:
        print(f"- {path}")
  elif classification.requires_real_models:
    print("Real-model gate required for changed files:")
    for path in classification.real_model_relevant_files:
      print(f"- {path}")
    if classification.requires_release_review:
      print("Release/App Store review also required for changed files:")
      for path in classification.release_sensitive_files:
        print(f"- {path}")
    if classification.requires_ios_katago_cmake:
      print("iOS KataGo CMake gate also required for changed files:")
      for path in classification.ios_katago_cmake_relevant_files:
        print(f"- {path}")
    if classification.requires_native_release_sim:
      print("NativeRelease simulator gate also required for changed files:")
      for path in classification.native_release_sim_relevant_files:
        print(f"- {path}")
  elif classification.requires_ios_katago_cmake:
    print("iOS KataGo CMake gate required for changed files:")
    for path in classification.ios_katago_cmake_relevant_files:
      print(f"- {path}")
    if classification.requires_native_release_sim:
      print("NativeRelease simulator gate also required for changed files:")
      for path in classification.native_release_sim_relevant_files:
        print(f"- {path}")
    if classification.requires_release_review:
      print("Release/App Store review also required for changed files:")
      for path in classification.release_sensitive_files:
        print(f"- {path}")
  elif classification.requires_native_release_sim:
    print("NativeRelease simulator gate required for changed files:")
    for path in classification.native_release_sim_relevant_files:
      print(f"- {path}")
    if classification.requires_release_review:
      print("Release/App Store review also required for changed files:")
      for path in classification.release_sensitive_files:
        print(f"- {path}")
  elif classification.requires_release_review:
    print("Release/App Store review required for changed files:")
    for path in classification.release_sensitive_files:
      print(f"- {path}")
  else:
    print("Screenshot, real-model, iOS KataGo CMake, NativeRelease simulator, and release/App Store review gates not required by changed-file classification.")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
