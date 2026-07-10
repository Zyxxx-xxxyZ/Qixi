#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$NATIVE_DIR/.." && pwd)"
SWIFT_OUT="${TMPDIR:-/tmp}/qixi-board-legality-crosscheck-swift"
CPP_OUT="${TMPDIR:-/tmp}/qixi-board-legality-crosscheck-native"
CORE_OBJ="${TMPDIR:-/tmp}/qixi-board-legality-crosscheck-core.o"
ENGINE_OBJ="${TMPDIR:-/tmp}/qixi-board-legality-crosscheck-engine.o"
CORE_TYPES_OBJ="${TMPDIR:-/tmp}/qixi-board-legality-core-types.o"
BOARD_OBJ="${TMPDIR:-/tmp}/qixi-board-legality-board.o"
MCTS_OBJ="${TMPDIR:-/tmp}/qixi-board-legality-mcts.o"
REQUEST_POOL_OBJ="${TMPDIR:-/tmp}/qixi-board-legality-request-pool.o"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANGXX="$(xcrun --find clang++)"

"$CLANGXX" \
  -std=c++17 \
  -isysroot "$SDKROOT" \
  -mmacosx-version-min=13.0 \
  -I "$NATIVE_DIR/Qixi" \
  -I "$ROOT_DIR/core/include" \
  -c "$NATIVE_DIR/Qixi/QixiNativeKataGoCore.cpp" \
  -o "$CORE_OBJ"

"$CLANGXX" \
  -std=c++17 \
  -isysroot "$SDKROOT" \
  -mmacosx-version-min=13.0 \
  -I "$NATIVE_DIR/Qixi" \
  -I "$ROOT_DIR/core/include" \
  -c "$NATIVE_DIR/Qixi/QixiNativeKataGoEngine.cpp" \
  -o "$ENGINE_OBJ"

"$CLANGXX" -std=c++17 -isysroot "$SDKROOT" -mmacosx-version-min=13.0 \
  -I "$ROOT_DIR/core/include" -c "$ROOT_DIR/core/src/core_types.cpp" -o "$CORE_TYPES_OBJ"
"$CLANGXX" -std=c++17 -isysroot "$SDKROOT" -mmacosx-version-min=13.0 \
  -I "$ROOT_DIR/core/include" -c "$ROOT_DIR/core/src/board.cpp" -o "$BOARD_OBJ"
"$CLANGXX" -std=c++17 -isysroot "$SDKROOT" -mmacosx-version-min=13.0 \
  -I "$ROOT_DIR/core/include" -c "$ROOT_DIR/core/src/mcts.cpp" -o "$MCTS_OBJ"
"$CLANGXX" -std=c++17 -isysroot "$SDKROOT" -mmacosx-version-min=13.0 \
  -I "$ROOT_DIR/core/include" -c "$ROOT_DIR/core/src/request_pool.cpp" -o "$REQUEST_POOL_OBJ"

"$CLANGXX" \
  -std=c++17 \
  -isysroot "$SDKROOT" \
  -mmacosx-version-min=13.0 \
  -I "$NATIVE_DIR/Qixi" \
  -I "$ROOT_DIR/core/include" \
  "$SCRIPT_DIR/native_board_legality_crosscheck.cpp" \
  "$CORE_OBJ" \
  "$ENGINE_OBJ" \
  "$CORE_TYPES_OBJ" \
  "$BOARD_OBJ" \
  "$MCTS_OBJ" \
  "$REQUEST_POOL_OBJ" \
  -o "$CPP_OUT"

swiftc \
  "$NATIVE_DIR/Qixi/L10n.swift" \
  "$NATIVE_DIR/Qixi/QixiModels.swift" \
  "$SCRIPT_DIR/board_legality_crosscheck.swift" \
  -o "$SWIFT_OUT"

"$SWIFT_OUT" | "$CPP_OUT"
