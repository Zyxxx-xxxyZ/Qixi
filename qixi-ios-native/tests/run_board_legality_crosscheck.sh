#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT_OUT="${TMPDIR:-/tmp}/qixi-board-legality-crosscheck-swift"
CPP_OUT="${TMPDIR:-/tmp}/qixi-board-legality-crosscheck-native"
CORE_OBJ="${TMPDIR:-/tmp}/qixi-board-legality-crosscheck-core.o"
ENGINE_OBJ="${TMPDIR:-/tmp}/qixi-board-legality-crosscheck-engine.o"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANGXX="$(xcrun --find clang++)"

"$CLANGXX" \
  -std=c++17 \
  -isysroot "$SDKROOT" \
  -mmacosx-version-min=13.0 \
  -I "$NATIVE_DIR/Qixi" \
  -c "$NATIVE_DIR/Qixi/QixiNativeKataGoCore.cpp" \
  -o "$CORE_OBJ"

"$CLANGXX" \
  -std=c++17 \
  -isysroot "$SDKROOT" \
  -mmacosx-version-min=13.0 \
  -I "$NATIVE_DIR/Qixi" \
  -c "$NATIVE_DIR/Qixi/QixiNativeKataGoEngine.cpp" \
  -o "$ENGINE_OBJ"

"$CLANGXX" \
  -std=c++17 \
  -isysroot "$SDKROOT" \
  -mmacosx-version-min=13.0 \
  -I "$NATIVE_DIR/Qixi" \
  "$SCRIPT_DIR/native_board_legality_crosscheck.cpp" \
  "$CORE_OBJ" \
  "$ENGINE_OBJ" \
  -o "$CPP_OUT"

swiftc \
  "$NATIVE_DIR/Qixi/L10n.swift" \
  "$NATIVE_DIR/Qixi/QixiModels.swift" \
  "$SCRIPT_DIR/board_legality_crosscheck.swift" \
  -o "$SWIFT_OUT"

"$SWIFT_OUT" | "$CPP_OUT"
