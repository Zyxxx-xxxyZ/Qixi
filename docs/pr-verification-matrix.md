# Qixi Pull Request Verification Matrix

Every pull request must name the surfaces it changes and attach evidence for the
matching gates below. When a change touches multiple surfaces, run the union of
their gates.

## Required For Every Pull Request

- `scripts/qixi-quality-gate.sh`
- A short description of the user-visible behavior or invariant being changed
- A note explaining every skipped relevant gate
- GitHub Actions changed-surface classification. PRs touching native SwiftUI,
  native assets, the Xcode project, screenshot scripts, screenshot
  review-board/performance/persistence helper scripts, screenshot inspectors,
  or the screenshot manifest automatically run `QIXI_RUN_SCREENSHOTS=1
  scripts/qixi-quality-gate.sh`. Any backend, model, native KataGo, or KataGo
  source change automatically runs `QIXI_RUN_REAL_MODELS=1
  scripts/qixi-quality-gate.sh`. Native KataGo, iOS model packaging, raw/ONNX/CoreML package
  artifact paths, CMake, or KataGo C++ source changes also automatically run
  `QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh`. Native release
  linker, startup, plist, Xcode build setting, bridging header, native
  in-process runtime, persistence/tombstone, position identity, iCloud sync, or
  KataGo C++ source/header changes automatically run
  `QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh`. Changes to
  release/App Store evidence gates, App Store archive preflight, Qixi README files,
  runbooks, native engine integration docs, device preflight/signing doctor/bridge smoke contracts,
  real-device evidence negative simulator smoke, privacy metadata, entitlements, persistence/tombstone, position identity fixtures, position identity,
  iCloud sync, bridging headers, native model manifests, raw/ONNX/CoreML package artifact paths, `.gitignore`, or CI/PR verification rules are classified as release-sensitive and must carry explicit App
  Store/release evidence when they claim release readiness; other PRs record
  explicit screenshot, real-model, iOS CMake, NativeRelease simulator, and
  release-sensitive skips.
  The classifier accepts only repository-relative POSIX changed-file paths and
  rejects absolute paths, home-relative paths, empty segments, `.`, `..`,
  backslashes, control characters, and surrounding whitespace rather than
  trying to guess a safer path.

## Change-To-Gate Matrix

| Changed surface | Required evidence |
| --- | --- |
| SwiftUI layout, localization, symbols, colors, assets, first launch, onboarding | `QIXI_RUN_SCREENSHOT_SMOKE=1 scripts/qixi-quality-gate.sh` for fast iPad/iPhone visual evidence; `QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh` for full review coverage; before/after screenshots when visual intent changed |
| Board geometry, stone placement, candidate labels, territory heatmap, variation tree | Screenshot smoke plus full screenshot gate; coordinate or geometry-focused test; keep board move-prefix, visible-stone, occupied-point, and candidate-overlay best-winrate/visible-list/preformatted candidate labels and color components cached so stone placement, territory, and candidate labels/colors refresh without allocating per-frame root-move, winrate, label-formatting, color-interpolation, or sorted visible-candidate arrays; keep the 120 Hz UIUpdateLink passive, without continuous, low-latency, or immediate-presentation updates, released when its host view leaves the window, and never paired with an always-on 120 Hz `TimelineView` that redraws board or variation-tree canvases while idle; reviewer note for touch target spacing |
| App lifecycle, autosave, restore, background save, tombstone behavior, persisted analysis | Default gate; screenshot/persistence gate; snapshot compatibility note; keep native engine tombstone restore/export guards for missing, empty, non-regular, symlink, directory, oversized, and bounded chunk-read cases |
| SGF import, photo recognition, camera/photo permissions | Default gate; focused parser or recognition smoke; screenshot gate for sheet/UI changes; keep SGF/photo input-size guards intact, including symbolic-link and non-regular SGF URL rejection before `FileHandle` reads, bounded SGF `FileHandle` reads, direct `String.UnicodeScalarView` parsing without whole-text scalar-array copies, PhotosPicker `FileRepresentation` transfer, and URL-based photo ImageIO decoding without full compressed-image `Data` allocation; preserve the visible-stone-preview boundary and clear stale recognition previews on every current-position identity change unless the PR adds a history-preserving import path |
| iCloud sync or multi-device state reconciliation | Default gate; simulator fallback evidence; real-device iCloud smoke when behavior can differ on device; local `SyncFallback` writes must never be presented or persisted as iCloud enabled state |
| Backend API bridge, model switching, response parsing, position identity | Default gate; keep position identity on the ordered-history cache-key path with a single reserved String builder and no intermediate per-move string array; analysis setting changes must immediately restore a matching cached analysis or clear candidates and territory before the debounced engine refresh, so the same root under different komi or root-noise settings never displays stale candidate or ownership data; disabled-analysis paths preserve the visible analysis so switching to no engine does not erase the current analysis while the model is unloaded; non-none engine selection must be saved before engine loading or analysis starts, so launch restore preserves the selected model even if loading or analysis fails; `QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh` when local models are available |
| KataGo Metal mux, neural-network config, ownership, score, winrate, persistent MCTS | Real-model gate; deterministic correctness or regression test; memory note for long runs; persistent-MCTS tombstone PRs must preserve bounded 256 MiB chunked reads before JSON parsing |
| Native iPad engine integration, Metal/CoreML/GPU/ANE performance, native model or CoreML package manifests, memory, launch time | `qixi-ios-native/tests/run_analysis_service_smoke.sh` including CoreML package install/receipt/tree-digest coverage; `scripts/qixi-native-inprocess-contract-preflight.sh`; `qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh`; `QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh` for simulator+device `katago_core` static-library build evidence; `QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh` for runnable linked `NativeRelease` simulator smoke; `scripts/qixi-native-linked-build-preflight.sh` with exactly one absolute native artifact path; `scripts/qixi-native-release-build-preflight.sh` for the native release Xcode build preflight when iOS KataGo artifacts are supplied; `scripts/qixi-ios-katago-cmake-preflight.sh`; `scripts/qixi-native-model-preflight.sh`; `scripts/qixi-device-signing-doctor.sh` for physical-device signing/profile diagnostics; `scripts/qixi-device-run-preflight.sh`; `QIXI_RUN_DEVICE_BRIDGE_PLAN=1 scripts/qixi-quality-gate.sh` plus `scripts/qixi-device-bridge-plan-inspect.sh` for no-side-effect physical-device bridge command previews; `scripts/qixi-device-bridge-smoke.sh` plus `scripts/qixi-device-bridge-smoke-inspect.sh` when Mac-hosted bridge behavior is cited; `scripts/qixi-device-bridge-failure-inspect.sh` when a failed selected-engine bridge launch is cited, including its structured `diagnosticCategory` such as `iosLocalNetworkDenied`; `QIXI_RUN_DEVICE_BRIDGE_SMOKE=1 scripts/qixi-quality-gate.sh` when a signed physical device and reachable backend are available; set `QIXI_DEVICE_BRIDGE_RUN_ID` when bridge smoke must be bound to a surrounding evidence run; `scripts/qixi-real-device-evidence-template.py` before physical-device release evidence collection; `scripts/qixi-real-device-run-kit-preflight.sh` after filling the run-kit staging directory; `scripts/qixi-real-device-evidence-preflight.sh`; `QIXI_RUN_SCREENSHOT_SMOKE=1 scripts/qixi-quality-gate.sh` for fast simulator launch/RSS evidence; `QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh` for full simulator evidence; real iPad/iPhone smoke with machine-checkable evidence JSON; Instruments or equivalent memory/performance artifact; any skipped simulator gap called out |
| App Store privacy, permissions, entitlements, bundle metadata, network policy, or release-readiness claim | `scripts/qixi-appstore-preflight.sh`; `QIXI_APPSTORE_SUBMISSION=1 scripts/qixi-appstore-preflight.sh` when submission-facing; `scripts/qixi_release_evidence_archive_match.py` when real-device evidence and an archive are cited; `scripts/qixi-release-evidence-gate.sh` before claiming release/App Store readiness; update `docs/app-store-readiness.md`; archive/privacy-report note when submission-facing |
| CI, scripts, docs, contribution workflow | Default gate; repository hygiene preflight; exact command or rendered-doc evidence for changed workflow |

## Evidence Quality

Evidence must prove the changed behavior, not only show that the app still
launches. Use focused tests for invariants, screenshots for layout, real-model
tests for KataGo behavior, and real devices for OS behaviors the simulator cannot
faithfully represent.

Do not mark a gate as passed when it was skipped by environment. Copy the skip
message, state why it is acceptable for this pull request, and provide the
strongest substitute evidence available.
