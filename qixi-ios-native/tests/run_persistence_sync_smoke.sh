#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${TMPDIR:-/tmp}/qixi-persistence-sync-smoke"
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/qixi-persistence-sync-home.XXXXXX")"

cleanup() {
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

swiftc \
  "$NATIVE_DIR/Qixi/L10n.swift" \
  "$NATIVE_DIR/Qixi/QixiModels.swift" \
  "$NATIVE_DIR/Qixi/QixiPositionIdentity.swift" \
  "$NATIVE_DIR/Qixi/QixiPersistence.swift" \
  "$NATIVE_DIR/Qixi/QixiBoardThumbnail.swift" \
  "$NATIVE_DIR/Qixi/QixiSync.swift" \
  "$NATIVE_DIR/Qixi/QixiNativeModelIntegrity.swift" \
  "$NATIVE_DIR/Qixi/QixiNativeModelInstallReceipt.swift" \
  "$NATIVE_DIR/Qixi/QixiNativeModelInstaller.swift" \
  "$NATIVE_DIR/Qixi/QixiNativeModelRegistry.swift" \
  "$NATIVE_DIR/Qixi/QixiRealDeviceEvidence.swift" \
  "$SCRIPT_DIR/persistence_sync_smoke.swift" \
  -o "$OUT"

CFFIXED_USER_HOME="$TEST_HOME" \
QIXI_REAL_DEVICE_PREFLIGHT_SCRIPT="$(cd "$NATIVE_DIR/.." && pwd)/scripts/qixi_real_device_evidence_preflight.py" \
"$OUT"
