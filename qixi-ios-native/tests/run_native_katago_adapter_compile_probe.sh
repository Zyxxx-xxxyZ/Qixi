#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CXX_BIN="${CXX:-clang++}"

"$CXX_BIN" \
  -std=c++20 \
  -fsyntax-only \
  -Wno-deprecated-literal-operator \
  -DCOMPILE_MAX_BOARD_LEN=19 \
  -I"$ROOT_DIR/KataGo/cpp" \
  -I"$ROOT_DIR/qixi-ios-native/Qixi" \
  "$ROOT_DIR/qixi-ios-native/tests/native_katago_adapter_compile_probe.cpp"

echo "Native KataGo adapter compile probe passed"
