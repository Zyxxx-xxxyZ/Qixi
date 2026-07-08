#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime
import json
import os
import pathlib
import stat
import sys
import uuid


RUN_KIT_SCHEMA_VERSION = 1
RUN_KIT_KIND = "qixi-real-device-evidence-run-kit"
EVIDENCE_FILENAME = "real-device-evidence.qixi-release.json"
EXPORT_AUDIT_FILENAME = "real-device-evidence.export.json"
SCREENSHOT_ARTIFACT = "real-device-main.png"
PERFORMANCE_ARTIFACT = "real-device-performance.json"
DEVICE_LOG_ARTIFACT = "real-device-log.json"
FINAL_EVIDENCE_FILENAMES = (
  EVIDENCE_FILENAME,
  EXPORT_AUDIT_FILENAME,
  SCREENSHOT_ARTIFACT,
  PERFORMANCE_ARTIFACT,
  DEVICE_LOG_ARTIFACT,
)
BACKEND_ENV_KEYS = ("QIXI_DEVICE_BACKEND_URL", "QIXI_BACKEND_URL")
ALLOWED_PLATFORM_SYMLINK_ALIASES = {
  pathlib.Path("/var"): pathlib.Path("/private/var"),
  pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
  pathlib.Path("/etc"): pathlib.Path("/private/etc"),
}


class RealDeviceEvidenceTemplateError(RuntimeError):
  pass


def isoformat_z(value: datetime.datetime) -> str:
  return value.astimezone(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_recorded_at(raw_value: str | None) -> str:
  if raw_value is None or raw_value == "now":
    return isoformat_z(datetime.datetime.now(datetime.timezone.utc))
  normalized = raw_value.strip()
  if normalized.endswith("Z"):
    candidate = normalized[:-1] + "+00:00"
  else:
    candidate = normalized
  try:
    parsed = datetime.datetime.fromisoformat(candidate)
  except ValueError as exc:
    raise RealDeviceEvidenceTemplateError("--recorded-at must be an ISO-8601 UTC timestamp") from exc
  if parsed.tzinfo is None:
    raise RealDeviceEvidenceTemplateError("--recorded-at must include a timezone")
  return isoformat_z(parsed)


def canonical_uuid(raw_value: str | None) -> str:
  value = raw_value.strip() if raw_value else str(uuid.uuid4())
  try:
    parsed = uuid.UUID(value)
  except ValueError as exc:
    raise RealDeviceEvidenceTemplateError("--run-id must be a canonical lowercase UUID") from exc
  canonical = str(parsed)
  if value != canonical:
    raise RealDeviceEvidenceTemplateError("--run-id must be a canonical lowercase UUID")
  return canonical


def reject_backend_environment() -> None:
  polluted = [key for key in BACKEND_ENV_KEYS if os.environ.get(key, "").strip()]
  if polluted:
    joined = ", ".join(polluted)
    raise RealDeviceEvidenceTemplateError(
      f"nativeInProcess release evidence must not inherit backend transport environment: {joined}"
    )


def normalized_path(path: pathlib.Path) -> pathlib.Path:
  expanded = path.expanduser()
  if expanded.is_absolute():
    return expanded
  return pathlib.Path.cwd() / expanded


def is_allowed_platform_symlink_alias(path: pathlib.Path) -> bool:
  expected = ALLOWED_PLATFORM_SYMLINK_ALIASES.get(path)
  if expected is None:
    return False
  try:
    return path.resolve(strict=True) == expected
  except OSError:
    return False


def reject_symlink_path(path: pathlib.Path, label: str) -> None:
  if path.is_symlink() and not is_allowed_platform_symlink_alias(path):
    raise RealDeviceEvidenceTemplateError(f"{label} must not contain symbolic links: {path}")


def reject_symlink_components(path: pathlib.Path, label: str) -> pathlib.Path:
  candidate = normalized_path(path)
  current = pathlib.Path(candidate.anchor) if candidate.anchor else pathlib.Path()
  for part in candidate.parts:
    if part == candidate.anchor or not part:
      continue
    current = current / part
    if current.exists() or current.is_symlink():
      reject_symlink_path(current, label)
  return candidate


def validate_output_dir(path: pathlib.Path, force: bool) -> pathlib.Path:
  checked = reject_symlink_components(path, "real-device evidence run-kit output directory")
  parent = checked.parent
  if not parent.exists():
    raise RealDeviceEvidenceTemplateError(f"output directory parent does not exist: {parent}")
  if not parent.is_dir():
    raise RealDeviceEvidenceTemplateError(f"output directory parent is not a directory: {parent}")
  if checked.exists():
    reject_symlink_path(checked, "real-device evidence run-kit output directory")
    if not checked.is_dir():
      raise RealDeviceEvidenceTemplateError(f"output path exists but is not a directory: {checked}")
    if any(checked.iterdir()) and not force:
      raise RealDeviceEvidenceTemplateError(f"output directory is not empty; pass --force to overwrite templates: {checked}")
  else:
    checked.mkdir(mode=0o700)
  return checked


def write_text(path: pathlib.Path, body: str, *, force: bool) -> None:
  if path.exists() or path.is_symlink():
    reject_symlink_path(path, f"run-kit file {path.name}")
    if not force:
      raise RealDeviceEvidenceTemplateError(f"refusing to overwrite existing file: {path}")
    if not path.is_file():
      raise RealDeviceEvidenceTemplateError(f"refusing to overwrite non-regular file: {path}")
    mode = path.stat().st_mode
    if not stat.S_ISREG(mode):
      raise RealDeviceEvidenceTemplateError(f"refusing to overwrite non-regular file: {path}")
  path.write_text(body, encoding="utf-8")


def reject_existing_final_evidence_files(output_dir: pathlib.Path) -> None:
  for filename in FINAL_EVIDENCE_FILENAMES:
    path = output_dir / filename
    if path.exists() or path.is_symlink():
      raise RealDeviceEvidenceTemplateError(
        f"run-kit generation must not create or retain final evidence or artifact files: {path}"
      )


def json_text(payload: object) -> str:
  return json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def known_environment(run_id: str, recorded_at: str) -> list[tuple[str, str]]:
  return [
    ("QIXI_ANALYSIS_RUNTIME", "nativeInProcess"),
    ("QIXI_AUTOMATION_SELECT_ENGINE", "b6"),
    ("QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH", "1"),
    ("QIXI_REAL_DEVICE_EXPECT_RUNTIME", "nativeInProcess"),
    ("QIXI_REAL_DEVICE_RUN_ID", run_id),
    ("QIXI_REAL_DEVICE_RECORDED_AT", recorded_at),
    ("QIXI_REAL_DEVICE_EVIDENCE_OUTPUT", EVIDENCE_FILENAME),
    ("QIXI_REAL_DEVICE_SCREENSHOT_ARTIFACT", SCREENSHOT_ARTIFACT),
    ("QIXI_REAL_DEVICE_PERFORMANCE_ARTIFACT", PERFORMANCE_ARTIFACT),
    ("QIXI_REAL_DEVICE_DEVICE_LOG_ARTIFACT", DEVICE_LOG_ARTIFACT),
    ("QIXI_REAL_DEVICE_TARGET_REFRESH_HZ", "120"),
    ("QIXI_REAL_DEVICE_SIMULATOR", "0"),
    ("QIXI_REAL_DEVICE_AUTOSAVE_WRITTEN", "1"),
    ("QIXI_REAL_DEVICE_TOMBSTONE_WRITTEN", "1"),
    ("QIXI_REAL_DEVICE_RESTORED_LATEST_STATE", "1"),
    ("QIXI_REAL_DEVICE_CAMERA_RECOGNITION_TESTED", "1"),
    ("QIXI_REAL_DEVICE_ICLOUD_SYNC_TESTED", "1"),
    ("QIXI_REAL_DEVICE_MODEL_IMPORT_TESTED", "1"),
  ]


def measured_environment_template() -> list[tuple[str, str]]:
  return [
    ("QIXI_REAL_DEVICE_IDIOM", "<iPad|iPhone>"),
    ("QIXI_REAL_DEVICE_MODEL", "<hardware model from the physical device>"),
    ("QIXI_REAL_DEVICE_OS_VERSION", "<iOS or iPadOS version>"),
    ("QIXI_REAL_DEVICE_COLD_LAUNCH_MS", "<integer measured on device>"),
    ("QIXI_REAL_DEVICE_VISUAL_READY_MS", "<integer measured on device>"),
    ("QIXI_REAL_DEVICE_PEAK_RSS_MB", "<finite number measured on device>"),
    ("QIXI_REAL_DEVICE_POST_ANALYSIS_RSS_MB", "<finite number measured on device>"),
    ("QIXI_REAL_DEVICE_OBSERVED_REFRESH_HZ", "<finite number, expected >= 110 for 120 Hz evidence>"),
    ("QIXI_REAL_DEVICE_DROPPED_FRAME_PERCENT", "<finite number, expected <= 5>"),
    ("QIXI_REAL_DEVICE_BACKGROUNDED_SECONDS", "<integer background dwell time>"),
  ]


def environment_template_text(run_id: str, recorded_at: str) -> str:
  lines = [
    "# Qixi nativeInProcess real-device evidence environment template.",
    "# This file is not directly sourceable until every <placeholder> value is replaced.",
    "# Keep QIXI_BACKEND_URL and QIXI_DEVICE_BACKEND_URL unset for release evidence.",
    "# Use this filled file only for the finalization launch after native analysis, screenshot, and performance artifacts exist.",
    "",
  ]
  for key, value in known_environment(run_id, recorded_at):
    lines.append(f"{key}={value}")
  lines.append("")
  lines.append("# Fill these from the physical device run before triggering evidence export:")
  for key, value in measured_environment_template():
    lines.append(f"{key}={value}")
  lines.append("")
  return "\n".join(lines)


def artifact_manifest(run_id: str, recorded_at: str) -> dict[str, object]:
  return {
    "schemaVersion": RUN_KIT_SCHEMA_VERSION,
    "kind": RUN_KIT_KIND,
    "runtime": "nativeInProcess",
    "runId": run_id,
    "recordedAt": recorded_at,
    "finalEvidence": EVIDENCE_FILENAME,
    "forbiddenEnvironment": list(BACKEND_ENV_KEYS),
    "requiredArtifacts": [
      {
        "kind": "screenshot",
        "path": SCREENSHOT_ARTIFACT,
        "producer": "real physical-device landscape screenshot",
        "mustBeTemplate": False,
      },
      {
        "kind": "performance",
        "path": PERFORMANCE_ARTIFACT,
        "producer": "Instruments, xctrace, or MetricKit measurement JSON",
        "mustBeTemplate": False,
      },
      {
        "kind": "device-log",
        "path": DEVICE_LOG_ARTIFACT,
        "producer": "Qixi app auto-written structured device-log JSON matching the evidence fields",
        "mustBeTemplate": False,
      },
    ],
    "validation": {
      "preflight": (
        "QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess "
        f"QIXI_REAL_DEVICE_EVIDENCE=/path/to/{EVIDENCE_FILENAME} "
        "scripts/qixi-real-device-evidence-preflight.sh"
      ),
      "releaseGate": (
        "QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess "
        f"QIXI_REAL_DEVICE_EVIDENCE=/path/to/{EVIDENCE_FILENAME} "
        "QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive "
        "QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW=1 "
        "scripts/qixi-release-evidence-gate.sh"
      ),
    },
  }


def performance_template(run_id: str, recorded_at: str) -> dict[str, object]:
  return {
    "templateOnly": True,
    "templateWarning": "Replace every placeholder and write the final file as real-device-performance.json.",
    "schemaVersion": 1,
    "kind": "qixi-real-device-performance",
    "source": "<instruments|xctrace|metricKit>",
    "runId": run_id,
    "recordedAt": recorded_at,
    "measurements": {
      "launch": {
        "coldLaunchMs": "<integer>",
        "visualReadyMs": "<integer>",
      },
      "memory": {
        "peakRSSMB": "<finite number>",
        "postAnalysisRSSMB": "<finite number>",
      },
      "framePacing": {
        "targetRefreshHz": 120,
        "observedRefreshHz": "<finite number>",
        "droppedFramePercent": "<finite number>",
      },
    },
  }


def device_log_template(run_id: str, recorded_at: str) -> dict[str, object]:
  return {
    "templateOnly": True,
    "templateWarning": "Reference only. The Qixi app writes the final file as real-device-log.json from the same evidence object.",
    "schemaVersion": 1,
    "kind": "qixi-real-device-log",
    "runId": run_id,
    "recordedAt": recorded_at,
    "device": {
      "idiom": "<iPad|iPhone>",
      "model": "<physical device model>",
      "osVersion": "<iOS or iPadOS version>",
      "simulator": False,
    },
    "app": {
      "bundleIdentifier": "com.qixi.localanalysis",
      "version": "<archive CFBundleShortVersionString>",
      "build": "<archive CFBundleVersion>",
      "analysisRuntime": "nativeInProcess",
      "executableSHA256HexDigest": "<lowercase archive executable SHA-256>",
    },
    "analysis": {
      "engineId": "<b6|b18nbt|b28nbt>",
      "realModel": True,
      "visits": "<positive integer>",
      "candidateCount": "<positive integer>",
      "ownershipSource": "mcts",
      "positionIdentity": {
        "currentPositionKey": "<history-sensitive current root key>",
        "sameVisibleStones": True,
        "sameVisibleHistoryAKey": "<history-sensitive fixture key A>",
        "sameVisibleHistoryBKey": "<history-sensitive fixture key B>",
        "sameVisibleHistoryKeysDistinct": True,
      },
      "nativeEngine": {
        "modelDigestVerified": True,
        "engineId": "<b6|b18nbt|b28nbt>",
        "modelResourceName": "<manifest model resource>",
        "modelByteCount": "<manifest byte count>",
        "modelSHA256HexDigest": "<manifest model digest>",
        "coreMLPackages": [],
        "tombstoneExported": True,
        "tombstoneFilename": "persistent-mcts-tombstone.json",
        "tombstoneExportedAt": "<ISO-8601 timestamp>",
        "tombstoneRestored": True,
        "tombstoneRestoredAt": "<ISO-8601 timestamp>",
      },
    },
    "measurements": performance_template(run_id, recorded_at)["measurements"],
    "lifecycle": {
      "backgroundedSeconds": "<integer>",
      "autosaveWritten": True,
      "tombstoneWritten": True,
      "restoredLatestState": True,
    },
    "features": {
      "cameraRecognitionTested": True,
      "iCloudSyncTested": True,
      "modelImportTested": True,
    },
  }


def readme_text(run_id: str, recorded_at: str) -> str:
  return f"""# Qixi Real-Device Evidence Run Kit

This directory is a template for one physical iPad/iPhone nativeInProcess run.
It is not release evidence until the app writes `{EVIDENCE_FILENAME}` and the
release preflight accepts that file.

Run id: `{run_id}`

Recorded-at seed: `{recorded_at}`

Rules:

- Keep `QIXI_BACKEND_URL` and `QIXI_DEVICE_BACKEND_URL` unset. A backend URL
  means the run is development bridge smoke, not App-Store-ready native evidence.
- Replace every `<placeholder>` in `xcode-run-env-template.txt` before using it.
- Replace the performance `.template.json` with the measured artifact named
  `{PERFORMANCE_ARTIFACT}`. The device-log `.template.json` is only a schema
  reference; the Qixi app writes `{DEVICE_LOG_ARTIFACT}` from the same evidence
  object it later saves. Template JSON must never be cited as evidence.
- First run the physical app without `QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH`
  so native analysis, autosave, and tombstone export can complete. Then put the
  real landscape screenshot at `{SCREENSHOT_ARTIFACT}` and the measured
  performance artifact at `{PERFORMANCE_ARTIFACT}` before the finalization
  launch. Generate this run kit after those measurements, or refresh `runId` and
  `recordedAt` before preflight, so the finalization seed is not older than the
  staged performance artifact.
- The final evidence file `{EVIDENCE_FILENAME}` must be generated by the Qixi app
  during the finalization launch, after cached native analysis, model digest
  verification, artifact fingerprinting, and tombstone export/restore audit.

Validate the generated evidence:

```sh
QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess \\
QIXI_REAL_DEVICE_EVIDENCE=/absolute/path/to/{EVIDENCE_FILENAME} \\
scripts/qixi-real-device-evidence-preflight.sh
```

Before any release or App Store claim, validate the archive and evidence
together:

```sh
QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess \\
QIXI_REAL_DEVICE_EVIDENCE=/absolute/path/to/{EVIDENCE_FILENAME} \\
QIXI_APPSTORE_ARCHIVE_PATH=/absolute/path/to/Qixi.xcarchive \\
QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW=1 \\
scripts/qixi-release-evidence-gate.sh
```
"""


def render_stdout(run_id: str, recorded_at: str) -> str:
  return "\n".join(
    [
      "Qixi nativeInProcess real-device evidence run kit",
      "",
      environment_template_text(run_id, recorded_at).rstrip(),
      "",
      "Required artifact filenames:",
      f"- {SCREENSHOT_ARTIFACT}",
      f"- {PERFORMANCE_ARTIFACT}",
      f"- {DEVICE_LOG_ARTIFACT}",
      "",
      "This command does not create or retain final evidence/artifact files; use the filled template for the finalization launch after native analysis and external artifacts exist.",
      "Keep QIXI_BACKEND_URL and QIXI_DEVICE_BACKEND_URL unset.",
      "",
    ]
  )


def write_run_kit(output_dir: pathlib.Path, run_id: str, recorded_at: str, *, force: bool) -> None:
  reject_existing_final_evidence_files(output_dir)
  write_text(output_dir / "README.md", readme_text(run_id, recorded_at), force=force)
  write_text(output_dir / "xcode-run-env-template.txt", environment_template_text(run_id, recorded_at), force=force)
  write_text(output_dir / "artifact-requirements.json", json_text(artifact_manifest(run_id, recorded_at)), force=force)
  write_text(output_dir / "real-device-performance.template.json", json_text(performance_template(run_id, recorded_at)), force=force)
  write_text(output_dir / "real-device-log.template.json", json_text(device_log_template(run_id, recorded_at)), force=force)


def parse_args(argv: list[str]) -> argparse.Namespace:
  parser = argparse.ArgumentParser(
    description="Generate a non-evidence template bundle for Qixi nativeInProcess physical-device evidence."
  )
  parser.add_argument("--run-id", help="Canonical lowercase UUID. Defaults to a new UUID.")
  parser.add_argument("--recorded-at", default="now", help="ISO-8601 timestamp. Defaults to now.")
  parser.add_argument("--output-dir", type=pathlib.Path, help="Write a portable run-kit template directory.")
  parser.add_argument("--force", action="store_true", help="Overwrite existing template files in --output-dir.")
  return parser.parse_args(argv)


def main(argv: list[str]) -> int:
  try:
    reject_backend_environment()
    args = parse_args(argv)
    run_id = canonical_uuid(args.run_id)
    recorded_at = parse_recorded_at(args.recorded_at)
    if args.output_dir is not None:
      output_dir = validate_output_dir(args.output_dir, args.force)
      write_run_kit(output_dir, run_id, recorded_at, force=args.force)
      print(f"Qixi real-device evidence run-kit template written to {output_dir}")
      print(f"Run id: {run_id}")
      print(f"Recorded at: {recorded_at}")
    else:
      print(render_stdout(run_id, recorded_at), end="")
    return 0
  except RealDeviceEvidenceTemplateError as exc:
    print(f"Real-device evidence template failed: {exc}", file=sys.stderr)
    return 2


if __name__ == "__main__":
  raise SystemExit(main(sys.argv[1:]))
