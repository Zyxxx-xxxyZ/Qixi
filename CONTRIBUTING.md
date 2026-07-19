# Contributing to Qixi

Thanks for helping improve 棋析 Qixi. The product path is **native iOS + `core::MCTSStore` + KataGo NN**. Keep changes small enough to review, and attach evidence for the behavior you touch.

## Prerequisites

- macOS with Xcode (iOS 17+ SDK)
- CMake and a C++20 compiler
- Python 3
- Optional: local KataGo `.bin` models for real-engine smoke (never commit them)

## Clone

```sh
git clone --recurse-submodules https://github.com/Zyxxx-xxxyZ/Qixi.git
cd Qixi
git submodule update --init --recursive
```

## Local version control

Git is the source of truth. Optional local mirror helpers:

```sh
scripts/qixi-local-vcs.sh status
```

See [`docs/local-version-control.md`](docs/local-version-control.md).

## Before every pull request

Read [`docs/pr-verification-matrix.md`](docs/pr-verification-matrix.md), identify every changed surface, and run the **union of required gates**. Every pull request starts with:

```sh
scripts/qixi-quality-gate.sh
```

That default gate includes `scripts/qixi-repo-hygiene-preflight.sh`. Do not commit **generated logs**, simulator screenshots, **local model packages**, Xcode archives/results, symbol bundles, or build output; they are machine-local artifacts, not reviewable source.

GitHub Actions runs `scripts/qixi_changed_surface_gate.py` on pull requests. If changed files touch native SwiftUI, assets, the Xcode project, screenshot scripts, or the screenshot manifest, CI runs the full screenshot gate automatically. If it does not, CI records an explicit **non-UI screenshot skip**. Backend, model, native KataGo, or KataGo source changes run the **real-model gate automatically**. **Real-model skips** and **NativeRelease simulator skips** are only acceptable when the change is outside that surface, or when the PR states the concrete missing artifact and the strongest substitute evidence.

## Optional escalations

| When | Command |
| --- | --- |
| UI / board / launch visuals | `QIXI_RUN_SCREENSHOT_SMOKE=1 scripts/qixi-quality-gate.sh` |
| Full screenshot coverage | `QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh` |
| Models / analysis / KataGo C++ | `QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh` |
| Native KataGo packaging | `QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh` |
| Linked NativeRelease simulator | `QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh` |

Native release linker, startup, plist, Xcode build settings, **bridging header**, native in-process runtime, **persistence/tombstone**, **position identity**, **iCloud sync**, or KataGo C++ **source/header changes** should run the NativeRelease simulator gate when those surfaces move.

## Core unit tests

```sh
cmake -S core -B core/build
cmake --build core/build
ctest --test-dir core/build --output-on-failure
```

## iOS app

1. Open `qixi-ios-native/Qixi.xcodeproj`.
2. Configure signing with **your** Apple development team (no personal team IDs are documented in-repo).
3. Prefer **`NativeRelease`** when validating the real in-process engine.
4. Follow [`docs/native-ios-runbook.md`](docs/native-ios-runbook.md) and [`docs/native-katago-integration.md`](docs/native-katago-integration.md).

`qixi-ios-sim/` is **optional** Mac-hosted bridge / simulator tooling for development. It is not the default product path.

## Evidence standards

- Prefer the **smallest focused test** or **regression test** that proves the invariant you changed.
- **Silent skips are not accepted.** List every skipped relevant check with a concrete reason.
- For performance, memory, Metal, camera, iCloud, or App Store behavior, include **real iPad/iPhone evidence** when the simulator cannot represent **device-only behavior**.

## Coding norms

- **Search** = `core::MCTSStore` only. KataGo is NN-only via the linked evaluator.
- Preserve **edge-local PUCT** and **PDA (激进度)** contracts — see [`docs/selection-edge-local-puct.md`](docs/selection-edge-local-puct.md).
- Display score uses **scoreLead** (`leadMeanWhite`), not selfplay score alone.
- Do not commit model binaries, DerivedData, secrets, or Finder `* 2*` duplicates.

## Conduct & security

- [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
- [`SECURITY.md`](SECURITY.md)
