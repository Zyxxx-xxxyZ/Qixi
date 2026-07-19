#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$NATIVE_DIR/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
OUT="${TMPDIR:-/tmp}/qixi-analysis-service-smoke"
CORE_SMOKE_OUT="${TMPDIR:-/tmp}/qixi-native-katago-core-smoke"
BRIDGE_OBJ="${TMPDIR:-/tmp}/qixi-native-katago-bridge-smoke.o"
CORE_OBJ="${TMPDIR:-/tmp}/qixi-native-katago-core-smoke.o"
ENGINE_OBJ="${TMPDIR:-/tmp}/qixi-native-katago-engine-smoke.o"
CORE_TYPES_OBJ="${TMPDIR:-/tmp}/qixi-core-types-smoke.o"
BOARD_OBJ="${TMPDIR:-/tmp}/qixi-board-smoke.o"
MCTS_OBJ="${TMPDIR:-/tmp}/qixi-mcts-smoke.o"
REQUEST_POOL_OBJ="${TMPDIR:-/tmp}/qixi-request-pool-smoke.o"
POSITION_IDENTITY_FIXTURE="$ROOT_DIR/tests/fixtures/position_identity_cases.json"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANGXX="$(xcrun --find clang++)"

"$PYTHON_BIN" "$ROOT_DIR/tests/validate_position_identity_fixture.py" "$POSITION_IDENTITY_FIXTURE"

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
  "$SCRIPT_DIR/native_katago_core_smoke.cpp" \
  "$CORE_OBJ" \
  "$ENGINE_OBJ" \
  "$CORE_TYPES_OBJ" \
  "$BOARD_OBJ" \
  "$MCTS_OBJ" \
  "$REQUEST_POOL_OBJ" \
  -o "$CORE_SMOKE_OUT"

"$CORE_SMOKE_OUT"

"$CLANGXX" \
  -std=c++17 \
  -fobjc-arc \
  -isysroot "$SDKROOT" \
  -mmacosx-version-min=13.0 \
  -I "$NATIVE_DIR/Qixi" \
  -I "$ROOT_DIR/core/include" \
  -c "$NATIVE_DIR/Qixi/QixiNativeKataGoBridge.mm" \
  -o "$BRIDGE_OBJ"

swiftc \
  -sdk "$SDKROOT" \
  -import-objc-header "$NATIVE_DIR/Qixi/Qixi-Bridging-Header.h" \
  "$NATIVE_DIR/Qixi/L10n.swift" \
  "$NATIVE_DIR/Qixi/QixiModels.swift" \
  "$NATIVE_DIR/Qixi/CandidatePalette.swift" \
  "$NATIVE_DIR/Qixi/QixiAnalyzeDisplay.swift" \
  "$NATIVE_DIR/Qixi/QixiPersistence.swift" \
  "$NATIVE_DIR/Qixi/QixiPositionIdentity.swift" \
  "$NATIVE_DIR/Qixi/QixiNativeModelRegistry.swift" \
  "$NATIVE_DIR/Qixi/QixiNativeModelIntegrity.swift" \
  "$NATIVE_DIR/Qixi/QixiNativeModelInstaller.swift" \
  "$NATIVE_DIR/Qixi/QixiNativeModelInstallReceipt.swift" \
  "$NATIVE_DIR/Qixi/BackendClient.swift" \
  "$NATIVE_DIR/Qixi/QixiAnalysisService.swift" \
  "$NATIVE_DIR/Qixi/QixiHTTPBridgeAnalysisService.swift" \
  "$NATIVE_DIR/Qixi/QixiNativeKataGoAnalysisService.swift" \
  "$SCRIPT_DIR/analysis_service_smoke.swift" \
  "$BRIDGE_OBJ" \
  "$CORE_OBJ" \
  "$ENGINE_OBJ" \
  "$CORE_TYPES_OBJ" \
  "$BOARD_OBJ" \
  "$MCTS_OBJ" \
  "$REQUEST_POOL_OBJ" \
  -lc++ \
  -o "$OUT"

QIXI_POSITION_IDENTITY_FIXTURE="$POSITION_IDENTITY_FIXTURE" "$OUT"
