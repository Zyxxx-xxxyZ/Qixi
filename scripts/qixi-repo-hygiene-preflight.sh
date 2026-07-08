#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

DEFAULT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="${QIXI_HYGIENE_ROOT:-$DEFAULT_ROOT_DIR}"
cd "$ROOT_DIR"

required_ignore_patterns=(
  ".DS_Store"
  "__pycache__/"
  "*.pyc"
  ".pytest_cache/"
  ".mypy_cache/"
  ".ruff_cache/"
  ".coverage"
  "coverage.xml"
  "node_modules/"
  "npm-debug.log*"
  "yarn-debug.log*"
  "yarn-error.log*"
  "pnpm-debug.log*"
  "analysis_logs/"
  "qixi-ios-native/artifacts/"
  "qixi-ios-sim/artifacts/"
  "DerivedData/"
  "build/"
  "*.xcuserdata/"
  "*.xcuserstate"
  "*.xcresult"
  "*.xcarchive"
  "*.ipa"
  "*.dSYM/"
  "*.tmp"
  "*.moved-aside"
  "/*.bin"
  "/*.bin.gz"
  "/*.txt.gz"
  "/*.onnx"
  "/*.mlmodel"
  "/*.mlmodelc/"
  "/*.mlpackage/"
  "/Models/"
  "KataGo/cpp/build-*/"
  "KataGo/cpp/tests/results/"
)

for pattern in "${required_ignore_patterns[@]}"; do
  if ! grep -Fxq "$pattern" .gitignore; then
    echo "Missing .gitignore pattern: $pattern" >&2
    exit 1
  fi
done

source_pollution="$(
  find . \
    \( \
      -path "./.git" -o \
      -path "./KataGo/.git" -o \
      -path "./node_modules" -o \
      -path "./analysis_logs" -o \
      -path "./qixi-ios-native/artifacts" -o \
      -path "./qixi-ios-sim/artifacts" -o \
      -path "./DerivedData" -o \
      -path "./build" -o \
      -path "./Models" -o \
      -path "./KataGo/cpp/build-*" -o \
      -path "./KataGo/cpp/tests/results" \
    \) -prune -o \
    \( -name "__pycache__" -print -prune \) -o \
    \( -name "*.pyc" \) -print \
    | sed 's#^\./##' \
    | sort
)"
if [[ -n "$source_pollution" ]]; then
  echo "Generated source-control pollution must be removed from non-ignored source paths:" >&2
  echo "$source_pollution" >&2
  exit 1
fi

fallback_candidate_pollution="$(
  find . \
    \( \
      -path "./.git" -o \
      -path "./KataGo/.git" -o \
      -path "./node_modules" -o \
      -path "./analysis_logs" -o \
      -path "./qixi-ios-native/artifacts" -o \
      -path "./qixi-ios-sim/artifacts" -o \
      -path "./DerivedData" -o \
      -path "./build" -o \
      -path "./Models" -o \
      -path "./KataGo/cpp/build-*" -o \
      -path "./KataGo/cpp/tests/results" \
    \) -prune -o \
    \( -name "__pycache__" -print -prune \) -o \
    \( -name ".pytest_cache" -print -prune \) -o \
    \( -name ".mypy_cache" -print -prune \) -o \
    \( -name ".ruff_cache" -print -prune \) -o \
    \( -name "node_modules" -print -prune \) -o \
    \( \
      -name ".DS_Store" -o \
      -name "*.pyc" -o \
      -name ".coverage" -o \
      -name "coverage.xml" -o \
      -name "npm-debug.log*" -o \
      -name "yarn-debug.log*" -o \
      -name "yarn-error.log*" -o \
      -name "pnpm-debug.log*" -o \
      -name "*.xcuserdata" -o \
      -name "*.xcuserstate" -o \
      -name "*.xcresult" -o \
      -name "*.xcarchive" -o \
      -name "*.dSYM" -o \
      -name "*.tmp" -o \
      -name "*.moved-aside" \
    \) -print \
    | sed 's#^\./##' \
    | sort
)"
if [[ -n "$fallback_candidate_pollution" ]]; then
  echo "Generated or recoverable artifacts must not live in non-ignored source paths:" >&2
  echo "$fallback_candidate_pollution" >&2
  exit 1
fi

model_source_pollution="$(
  find . \
    \( \
      -path "./.git" -o \
      -path "./KataGo/.git" -o \
      -path "./analysis_logs" -o \
      -path "./qixi-ios-native/artifacts" -o \
      -path "./qixi-ios-sim/artifacts" -o \
      -path "./DerivedData" -o \
      -path "./build" -o \
      -path "./Models" -o \
      -path "./KataGo/cpp/build-*" -o \
      -path "./KataGo/cpp/tests/models" -o \
      -path "./KataGo/cpp/tests/results" \
    \) -prune -o \
    \( -path "./*/*" -name "*.mlmodelc" -print -prune \) -o \
    \( -path "./*/*" -name "*.mlpackage" -print -prune \) -o \
    \( \
      -path "./*/*" -a \
      \( \
        -name "*.bin" -o \
        -name "*.bin.gz" -o \
        -name "*.txt.gz" -o \
        -name "*.onnx" -o \
        -name "*.mlmodel" \
      \) \
    \) -print \
    | sed 's#^\./##' \
    | sort
)"
if [[ -n "$model_source_pollution" ]]; then
  echo "Local model, CoreML, and ONNX artifacts must stay in ignored top-level model locations, not source paths:" >&2
  echo "$model_source_pollution" >&2
  exit 1
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  forbidden_tracked_regex='^(analysis_logs/|qixi-ios-native/artifacts/|qixi-ios-sim/artifacts/|DerivedData/|build/|Models/|(.*/)?node_modules/|KataGo/cpp/build-[^/]+/|KataGo/cpp/tests/results/|(.*/)?\.DS_Store$|(.*/)?__pycache__/|(.*/)?\.(pytest_cache|mypy_cache|ruff_cache)/|(.*/)?[^/]+\.pyc$|(.*/)?\.coverage$|(.*/)?coverage\.xml$|(.*/)?(npm-debug|yarn-debug|yarn-error|pnpm-debug)\.log[^/]*$|(.*/)?[^/]+\.(bin|bin\.gz|txt\.gz|onnx|mlmodel)$|(.*/)?[^/]+\.(mlmodelc|mlpackage)(/|$)|(.*/)?[^/]+\.ipa$|(.*/)?[^/]+\.(xcresult|xcarchive|dSYM)/|(.*/)?[^/]+\.(tmp|moved-aside)$)'
  allowed_tracked_regex='^KataGo/cpp/tests/models/'
  tracked_forbidden="$(git ls-files | grep -E "$forbidden_tracked_regex" | grep -Ev "$allowed_tracked_regex" || true)"
  if [[ -n "$tracked_forbidden" ]]; then
    echo "Generated or recoverable large artifacts must not be tracked:" >&2
    echo "$tracked_forbidden" >&2
    exit 1
  fi
else
  if [[ "${QIXI_REQUIRE_TRACKED_FILE_AUDIT:-0}" == "1" ]]; then
    echo "Repository hygiene tracked-file audit requires a git worktree when QIXI_REQUIRE_TRACKED_FILE_AUDIT=1" >&2
    exit 1
  fi
  echo "Repository hygiene fallback source-path audit completed: not inside a git worktree" >&2
fi

echo "Repository hygiene preflight passed"
