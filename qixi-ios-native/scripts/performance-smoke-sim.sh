#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$NATIVE_DIR/artifacts/performance"
SCREENSHOT_PATH="$NATIVE_DIR/artifacts/screenshots/latest-ipad-performance.png"
RAW_METRICS_PATH="$ARTIFACT_DIR/latest-sim-performance.raw.json"
METRICS_PATH="$ARTIFACT_DIR/latest-sim-performance.json"

MAX_LAUNCH_COMMAND_MS="${QIXI_PERF_MAX_LAUNCH_COMMAND_MS:-3000}"
MAX_VISUAL_READY_MS="${QIXI_PERF_MAX_VISUAL_READY_MS:-10000}"
MAX_RSS_MB="${QIXI_PERF_MAX_RSS_MB:-450}"

reject_symlink_components() {
  local path="$1"
  local current=""
  local target expected_target
  if [[ "$path" == /* ]]; then
    current="/"
  fi
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ -z "$part" || "$part" == "." ]] && continue
    if [[ "$part" == ".." ]]; then
      echo "Simulator performance artifact path must not contain parent-directory traversal: $path" >&2
      exit 3
    fi
    if [[ "$current" == "/" ]]; then
      current="/$part"
    elif [[ -z "$current" ]]; then
      current="$part"
    else
      current="$current/$part"
    fi
    if [[ -L "$current" ]]; then
      expected_target=""
      if [[ "$current" == "/var" ]]; then
        expected_target="/private/var"
      elif [[ "$current" == "/tmp" ]]; then
        expected_target="/private/tmp"
      elif [[ "$current" == "/etc" ]]; then
        expected_target="/private/etc"
      fi
      if [[ -n "$expected_target" ]]; then
        target="$(cd "$current" && pwd -P)"
        if [[ "$target" == "$expected_target" ]]; then
          continue
        fi
      fi
      echo "Simulator performance artifact path must not contain symbolic links: $current" >&2
      exit 3
    fi
  done
}

prepare_output_artifact() {
  local path="$1"
  local label="$2"
  local parent
  reject_symlink_components "$path"
  parent="$(dirname "$path")"
  reject_symlink_components "$parent"
  mkdir -p "$parent"
  reject_symlink_components "$parent"
  if [[ -L "$path" ]]; then
    echo "Simulator performance $label target must not be a symbolic link: $path" >&2
    exit 3
  fi
  if [[ -e "$path" && ! -f "$path" ]]; then
    echo "Simulator performance $label target must be a regular file: $path" >&2
    exit 3
  fi
}

prepare_output_artifact "$SCREENSHOT_PATH" "screenshot PNG"
prepare_output_artifact "$RAW_METRICS_PATH" "raw metrics JSON"
prepare_output_artifact "$METRICS_PATH" "metrics JSON"

QIXI_APP_LANGUAGE="${QIXI_APP_LANGUAGE:-en}" \
QIXI_SKIP_ONBOARDING="${QIXI_SKIP_ONBOARDING:-1}" \
QIXI_SCREENSHOT_METRICS_PATH="$RAW_METRICS_PATH" \
  "$SCRIPT_DIR/screenshot-sim.sh" "$SCREENSHOT_PATH" >/tmp/qixi-native-performance-screenshot.log

python3 "$NATIVE_DIR/tests/inspect_screenshot.py" "$SCREENSHOT_PATH"

python3 - "$RAW_METRICS_PATH" "$METRICS_PATH" "$MAX_LAUNCH_COMMAND_MS" "$MAX_VISUAL_READY_MS" "$MAX_RSS_MB" <<'PY'
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import stat


raw_metrics_path = pathlib.Path(sys.argv[1])
metrics_path = pathlib.Path(sys.argv[2])
max_launch_command_ms = int(sys.argv[3])
max_visual_ready_ms = int(sys.argv[4])
max_rss_mb = int(sys.argv[5])


def fail(message: str) -> None:
  print(f"Simulator performance smoke failed: {message}", file=sys.stderr)
  raise SystemExit(1)


payload = json.loads(raw_metrics_path.read_text(encoding="utf-8"))
pid = payload.get("pid")
if not isinstance(pid, int) or pid <= 0:
  fail("screenshot launch did not record a valid process id")

try:
  rss_text = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip()
except subprocess.CalledProcessError as exc:
  fail(f"could not read RSS for simulator app pid {pid}: {exc}")

if not rss_text:
  fail(f"simulator app pid {pid} is no longer running")

rss_kb = int(rss_text.splitlines()[0].strip())
rss_mb = rss_kb / 1024.0
payload.update(
  {
    "rssKB": rss_kb,
    "rssMB": round(rss_mb, 3),
    "budgets": {
      "maxLaunchCommandMs": max_launch_command_ms,
      "maxVisualReadyMs": max_visual_ready_ms,
      "maxRSSMB": max_rss_mb,
    },
    "note": "Simulator smoke; real-device launch, memory, thermal, and frame pacing still need device evidence.",
  }
)

if payload["launchCommandMs"] > max_launch_command_ms:
  fail(f"launch command took {payload['launchCommandMs']} ms, budget {max_launch_command_ms} ms")
if payload["visualReadyMs"] > max_visual_ready_ms:
  fail(f"visual readiness took {payload['visualReadyMs']} ms, budget {max_visual_ready_ms} ms")
if rss_mb > max_rss_mb:
  fail(f"RSS is {rss_mb:.1f} MB, budget {max_rss_mb} MB")

data = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
tmp_path = metrics_path.with_name(f".{metrics_path.name}.{os.getpid()}.tmp")
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
  flags |= os.O_NOFOLLOW
fd = None
try:
  fd = os.open(tmp_path, flags, 0o600)
  written = 0
  view = memoryview(data)
  while written < len(data):
    written += os.write(fd, view[written:])
  written_stat = os.fstat(fd)
  if not stat.S_ISREG(written_stat.st_mode):
    fail(f"metrics artifact temporary file must be regular: {tmp_path}")
  if written_stat.st_size != len(data):
    fail(f"metrics artifact byte count drift after writing: expected {len(data)} got {written_stat.st_size}")
  os.fsync(fd)
  os.close(fd)
  fd = None
  try:
    existing = metrics_path.lstat()
  except FileNotFoundError:
    pass
  else:
    if stat.S_ISLNK(existing.st_mode):
      fail(f"metrics artifact target must not be a symbolic link: {metrics_path}")
    if not stat.S_ISREG(existing.st_mode):
      fail(f"metrics artifact target must be a regular file: {metrics_path}")
  os.replace(tmp_path, metrics_path)
  parent_flags = os.O_RDONLY
  if hasattr(os, "O_DIRECTORY"):
    parent_flags |= os.O_DIRECTORY
  if hasattr(os, "O_NOFOLLOW"):
    parent_flags |= os.O_NOFOLLOW
  parent_fd = os.open(metrics_path.parent, parent_flags)
  try:
    os.fsync(parent_fd)
  finally:
    os.close(parent_fd)
except OSError as exc:
  fail(f"could not write metrics artifact atomically: {exc}")
finally:
  if fd is not None:
    os.close(fd)
  try:
    if tmp_path.exists() or tmp_path.is_symlink():
      tmp_path.unlink()
  except OSError:
    pass
print(
  "Simulator performance smoke passed: "
  f"launchCommandMs={payload['launchCommandMs']}, "
  f"visualReadyMs={payload['visualReadyMs']}, "
  f"rssMB={rss_mb:.1f}"
)
print(metrics_path)
PY
