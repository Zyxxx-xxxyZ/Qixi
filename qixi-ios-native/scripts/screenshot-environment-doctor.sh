#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NATIVE_DIR="$ROOT_DIR/qixi-ios-native"
PROJECT="$NATIVE_DIR/Qixi.xcodeproj"
PYTHON_BIN="${PYTHON_BIN:-python3}"
IPAD_DEVICE="${QIXI_SIM_DEVICE:-iPad Pro 13-inch (M5)}"
IPHONE_DEVICE="${QIXI_IPHONE_SIM_DEVICE:-iPhone 17 Pro Max}"
BOOT_SIMULATORS="${QIXI_SCREENSHOT_DOCTOR_BOOT:-1}"
ARTIFACT_PATH="${QIXI_SCREENSHOT_DOCTOR_ARTIFACT:-$NATIVE_DIR/artifacts/screenshots/screenshot-environment.json}"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command for simulator screenshot QA: $command_name" >&2
    exit 2
  fi
}

require_file() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Missing required simulator screenshot QA path: $path" >&2
    exit 2
  fi
}

require_executable() {
  local path="$1"
  require_file "$path"
  if [[ ! -x "$path" ]]; then
    echo "Simulator screenshot QA script is not executable: $path" >&2
    exit 2
  fi
}

resolve_xcodebuild() {
  local xcodebuild_path
  if ! xcodebuild_path="$(command -v xcodebuild)"; then
    echo "Missing required command for simulator screenshot QA: xcodebuild" >&2
    exit 2
  fi
  if [[ "$xcodebuild_path" != "/usr/bin/xcodebuild" ]]; then
    echo "Simulator screenshot QA requires xcodebuild to resolve to /usr/bin/xcodebuild, got $xcodebuild_path; do not shadow xcodebuild in PATH" >&2
    exit 2
  fi
  printf '%s\n' "$xcodebuild_path"
}

require_command xcrun
require_command "$PYTHON_BIN"
require_file "$PROJECT"
require_executable "$SCRIPT_DIR/screenshot-sim.sh"
require_executable "$SCRIPT_DIR/screenshot-iphone-sim.sh"
require_executable "$SCRIPT_DIR/screenshot-smoke-sim.sh"
require_file "$NATIVE_DIR/tests/inspect_screenshot.py"
XCODEBUILD_BIN="$(resolve_xcodebuild)"

if ! "$XCODEBUILD_BIN" -showsdks | grep -q "iphonesimulator"; then
  echo "xcodebuild does not report an iOS Simulator SDK." >&2
  exit 2
fi

"$PYTHON_BIN" - <<'PY'
try:
  from PIL import Image, ImageChops  # noqa: F401
except Exception as exc:
  raise SystemExit(f"Python Pillow is required for screenshot crop/inspection: {exc}")
PY

XCODEBUILD_BIN="$XCODEBUILD_BIN" "$PYTHON_BIN" - "$IPAD_DEVICE" "$IPHONE_DEVICE" "$BOOT_SIMULATORS" "$ARTIFACT_PATH" <<'PY'
from __future__ import annotations

import datetime as _datetime
import json
import os
import pathlib
import stat as stat_module
import subprocess
import sys


ipad_name = sys.argv[1]
iphone_name = sys.argv[2]
boot_simulators = sys.argv[3] != "0"
artifact_path = pathlib.Path(sys.argv[4])


def run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
  return subprocess.run(args, check=check, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def fail(message: str) -> None:
  print(f"Simulator screenshot environment doctor failed: {message}", file=sys.stderr)
  raise SystemExit(2)


ALLOWED_PLATFORM_SYMLINK_ALIASES = {
  pathlib.Path("/var"): pathlib.Path("/private/var"),
  pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
  pathlib.Path("/etc"): pathlib.Path("/private/etc"),
}


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


def reject_symlink_components(path: pathlib.Path) -> pathlib.Path:
  candidate = normalized_path(path)
  current = pathlib.Path(candidate.anchor) if candidate.anchor else pathlib.Path()
  for part in candidate.parts:
    if part == candidate.anchor or not part or part == ".":
      continue
    if part == "..":
      fail(f"screenshot environment artifact path must not contain parent-directory traversal: {candidate}")
    current = current / part
    if current.is_symlink() and not is_allowed_platform_symlink_alias(current):
      fail(f"screenshot environment artifact path must not contain symbolic links: {current}")
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


def prepare_artifact_target(path: pathlib.Path) -> pathlib.Path:
  checked_path = reject_symlink_components(path)
  write_target = canonicalize_allowed_platform_alias_prefix(checked_path)
  checked_parent = reject_symlink_components(checked_path.parent)
  write_parent = reject_symlink_components(write_target.parent)
  try:
    write_parent.mkdir(parents=True, exist_ok=True)
  except OSError as exc:
    fail(f"could not create screenshot environment artifact directory {write_parent}: {exc}")
  reject_symlink_components(checked_parent)
  reject_symlink_components(write_parent)
  if not write_parent.is_dir():
    fail(f"screenshot environment artifact parent must be a directory: {write_parent}")
  try:
    existing = write_target.lstat()
  except FileNotFoundError:
    return write_target
  if stat_module.S_ISLNK(existing.st_mode):
    fail(f"screenshot environment artifact target must not be a symbolic link: {write_target}")
  if not stat_module.S_ISREG(existing.st_mode):
    fail(f"screenshot environment artifact target must be a regular file: {write_target}")
  return write_target


def fsync_parent_directory(path: pathlib.Path) -> None:
  flags = os.O_RDONLY
  if hasattr(os, "O_DIRECTORY"):
    flags |= os.O_DIRECTORY
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
  parent_fd = os.open(path.parent, flags)
  try:
    os.fsync(parent_fd)
  finally:
    os.close(parent_fd)


def write_artifact_atomically(path: pathlib.Path, payload: dict[str, object]) -> pathlib.Path:
  checked_path = prepare_artifact_target(path)
  data = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
  tmp_path = checked_path.parent / f".{checked_path.name}.{os.getpid()}.tmp"
  flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
  fd: int | None = None
  try:
    fd = os.open(tmp_path, flags, 0o600)
    written = 0
    view = memoryview(data)
    while written < len(data):
      written += os.write(fd, view[written:])
    stat_after_write = os.fstat(fd)
    if not stat_module.S_ISREG(stat_after_write.st_mode):
      fail(f"screenshot environment artifact temporary file must be regular: {tmp_path}")
    if stat_after_write.st_size != len(data):
      fail(
        "screenshot environment artifact byte count drift after writing: "
        f"{tmp_path} expected {len(data)} got {stat_after_write.st_size}"
      )
    os.fsync(fd)
    os.close(fd)
    fd = None
    os.replace(tmp_path, checked_path)
    try:
      fsync_parent_directory(checked_path)
    except OSError as exc:
      fail(f"could not fsync parent directory after screenshot environment artifact replace: {exc}")
  except OSError as exc:
    fail(f"could not write screenshot environment artifact atomically: {exc}")
  finally:
    if fd is not None:
      os.close(fd)
    try:
      if tmp_path.exists() or tmp_path.is_symlink():
        tmp_path.unlink()
    except OSError:
      pass
  return checked_path


try:
  devices_payload = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"]).stdout)
except subprocess.CalledProcessError as exc:
  fail(exc.stderr.strip() or exc.stdout.strip() or "could not list simulators")
except json.JSONDecodeError as exc:
  fail(f"simctl returned non-JSON device list: {exc}")

devices: list[dict[str, str]] = []
for runtime, runtime_devices in devices_payload.get("devices", {}).items():
  for device in runtime_devices:
    if not device.get("isAvailable", True):
      continue
    devices.append(
      {
        "name": str(device.get("name", "")),
        "udid": str(device.get("udid", "")),
        "state": str(device.get("state", "")),
        "runtime": runtime,
      }
    )


def choose_device(requested_name: str, family_prefix: str) -> dict[str, str]:
  exact = [device for device in devices if device["name"] == requested_name]
  booted_exact = [device for device in exact if device["state"] == "Booted"]
  if booted_exact:
    return booted_exact[0]
  if exact:
    return exact[0]
  family = [device for device in devices if device["name"].startswith(family_prefix)]
  booted_family = [device for device in family if device["state"] == "Booted"]
  if booted_family:
    return booted_family[0]
  if family:
    return family[0]
  available_names = ", ".join(sorted({device["name"] for device in devices})) or "(none)"
  fail(f"no available {family_prefix} simulator found; available devices: {available_names}")


selected_ipad = choose_device(ipad_name, "iPad")
selected_iphone = choose_device(iphone_name, "iPhone")


def boot_device(device: dict[str, str]) -> None:
  run(["xcrun", "simctl", "boot", device["udid"]], check=False)
  try:
    run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"])
  except subprocess.CalledProcessError as exc:
    fail(f"simulator {device['name']} did not reach booted state: {exc.stderr.strip() or exc.stdout.strip()}")
  run(["xcrun", "simctl", "ui", device["udid"], "appearance", "light"], check=False)
  device["state"] = "Booted"


if boot_simulators:
  boot_device(selected_ipad)
  if selected_iphone["udid"] != selected_ipad["udid"]:
    boot_device(selected_iphone)

try:
  xcode_version = run([os.environ["XCODEBUILD_BIN"], "-version"]).stdout.strip()
except subprocess.CalledProcessError as exc:
  fail(exc.stderr.strip() or exc.stdout.strip() or "could not read xcodebuild version")

artifact = {
  "schemaVersion": 1,
  "generatedAt": _datetime.datetime.now(_datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
  "bootSimulators": boot_simulators,
  "xcodebuildVersion": xcode_version,
  "selected": {
    "iPad": selected_ipad,
    "iPhone": selected_iphone,
  },
  "commands": {
    "fastSmoke": "qixi-ios-native/scripts/screenshot-smoke-sim.sh",
    "fullMatrix": "QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh",
    "ipadSingle": "qixi-ios-native/scripts/screenshot-sim.sh",
    "iphoneSingle": "qixi-ios-native/scripts/screenshot-iphone-sim.sh",
  },
  "limits": [
    "Simulator evidence covers SwiftUI layout, screenshots, persistence, and HTTP bridge behavior.",
    "Real ProMotion, Metal/GPU/ANE, camera, iCloud propagation, background kill, and native in-process KataGo still require physical-device evidence.",
  ],
}
written_artifact_path = write_artifact_atomically(artifact_path, artifact)

print(f"Simulator screenshot environment doctor passed")
print(f"iPad: {selected_ipad['name']} ({selected_ipad['udid']}) {selected_ipad['state']}")
print(f"iPhone: {selected_iphone['name']} ({selected_iphone['udid']}) {selected_iphone['state']}")
print(f"Evidence: {written_artifact_path}")
PY
