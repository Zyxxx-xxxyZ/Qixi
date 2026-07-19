## Summary

Product docs: `README.md`, `docs/architecture.md`, `docs/search-engine.md`. Gates: `docs/pr-verification-matrix.md`, `docs/quality-gates.md`.


- 

## Changed Surface

Use `docs/pr-verification-matrix.md` to decide which boxes apply. Check every
surface touched by this pull request.

- [ ] Native SwiftUI UI/layout/localization
- [ ] Board geometry, stones, candidates, territory, or variation tree
- [ ] App lifecycle, autosave, restore, persistence, or tombstone behavior
- [ ] Backend API bridge or model selection
- [ ] KataGo search, persistent MCTS, export/import, or Metal mux path
- [ ] iCloud sync, import/export, or board recognition
- [ ] Documentation, CI, scripts, or contributor workflow

## Verification

- [ ] `scripts/qixi-quality-gate.sh`
- [ ] `QIXI_RUN_SCREENSHOT_SMOKE=1 scripts/qixi-quality-gate.sh` if UI, board geometry, launch, or simulator performance behavior changed
- [ ] `QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh` if UI, localization, persistence, or launch behavior changed
- [ ] `QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh` if native KataGo, iOS model packaging, raw/ONNX/CoreML package artifact paths, Metal/CoreML, or KataGo C++ build behavior changed
- [ ] `QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh` if native release linker, startup, plist, Xcode build settings, or native in-process runtime behavior changed
- [ ] `QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh` if backend, model, analysis, or KataGo behavior changed
- [ ] `QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW=1 scripts/qixi-release-evidence-gate.sh` if this PR claims release/App Store readiness
- [ ] `QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json scripts/qixi-real-device-evidence-preflight.sh` if real-device evidence is cited
- [ ] `scripts/qixi-device-signing-doctor.sh` and `QIXI_RUN_DEVICE_BRIDGE_SMOKE=1 QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 scripts/qixi-quality-gate.sh` if device preflight/signing doctor/bridge smoke contracts changed or Mac-hosted bridge behavior is cited
- [ ] Real iPad/iPhone smoke test if performance, memory, Metal, camera, iCloud, or App Store behavior changed
- [ ] Confirmed release/App Store evidence did not set development skip switches such as `QIXI_SKIP_XCODEBUILD`
- [ ] Confirmed release/App Store evidence ran repository hygiene with `QIXI_REQUIRE_TRACKED_FILE_AUDIT=1`
- [ ] Checked `docs/pr-verification-matrix.md` and ran the full union of required gates for the changed surfaces
- [ ] Confirmed the GitHub changed-surface classifier either ran the screenshot gate or recorded a non-UI screenshot skip
- [ ] Confirmed the GitHub changed-surface classifier either ran the real-model gate or recorded a non-backend/model/KataGo skip
- [ ] Confirmed the GitHub changed-surface classifier either ran the iOS KataGo CMake gate or recorded a non-native-KataGo skip
- [ ] Confirmed the GitHub changed-surface classifier either ran the NativeRelease simulator gate or recorded a non-native-release skip
- [ ] Confirmed the GitHub changed-surface classifier either recorded release-sensitive review files or recorded a release-sensitive skip

## Evidence

- Screenshots or visual diff:
- Parser/recognition/correctness tests:
- Persistence or tombstone evidence:
- Real-model analysis evidence:
- Real-device iPad/iPhone evidence:
- Memory, launch time, or performance note:
- iCloud or multi-device sync evidence:

## Skipped checks

List every skipped relevant check, with a concrete reason and substitute evidence.

- 

## Reviewer Notes

- 
