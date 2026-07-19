# 棋析 Qixi

**On-device Go (Weiqi / Baduk) analysis for iPad and iPhone.**

Qixi pairs a SwiftUI client with a **persistent MCTS** engine in `core/` and **KataGo neural nets only** for evaluation — search is not stock KataGo `Search` / `AsyncBot`.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-lightgrey.svg)](qixi-ios-native/)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

## Features

- **Persistent MCTS** — first-visit / min-root-depth semantics, edge-local PUCT, resumable trees
- **Native KataGo NN** — linked in-process on device (`NativeRelease`); models are not shipped in git
- **Photo board scan** — capture or import a board photo and continue analysis
- **Archives** — SGF plus Qixi PNG archive flow; iCloud when the user enables it
- **激进度 (episode degree)** — maps to KataGo `playoutDoublingAdvantage` (PDA)
- **Localization** — Simplified Chinese, Traditional Chinese, English

## Architecture

```text
SwiftUI (qixi-ios-native)
  → Native analysis service / bridge
      → core::MCTSStore          ← only product search
      → KataGo NNEvaluator       ← NN load + evaluate only
```

| Layer | Path |
| --- | --- |
| App UI | `qixi-ios-native/` |
| MCTS + worker | `core/` |
| NN engine (submodule) | `KataGo/` |
| Optional Mac bridge / sim tooling | `qixi-ios-sim/` (dev only, not the product path) |

Product search contracts: [`docs/search-engine.md`](docs/search-engine.md), [`docs/selection-edge-local-puct.md`](docs/selection-edge-local-puct.md), [`docs/architecture.md`](docs/architecture.md).

## Requirements

- macOS with **Xcode** (iOS 17+ SDK)
- **CMake** + a C++20 toolchain (for `core/` tests)
- **Python 3** (quality gate / contracts)
- A KataGo network file locally (e.g. b18/b28 class nets) — **never commit** `*.bin` models

## Quick start

```sh
git clone --recurse-submodules https://github.com/Zyxxx-xxxyZ/Qixi.git
cd Qixi
# if you cloned without submodules:
git submodule update --init --recursive
```

### Core unit tests

```sh
cmake -S core -B core/build
cmake --build core/build
ctest --test-dir core/build --output-on-failure
```

### iOS app

1. Open `qixi-ios-native/Qixi.xcodeproj` in Xcode.
2. Select your team / signing for a development bundle id.
3. Prefer **`NativeRelease`** for the real in-process engine (not a placeholder).
4. Point the app at a local model path as documented in [`docs/native-ios-runbook.md`](docs/native-ios-runbook.md) and [`docs/native-katago-integration.md`](docs/native-katago-integration.md).

More build detail: [`qixi-ios-native/README.md`](qixi-ios-native/README.md).

### Default quality gate

```sh
scripts/qixi-quality-gate.sh
```

PR surface → gate matrix: [`docs/pr-verification-matrix.md`](docs/pr-verification-matrix.md).  
Gate catalogue: [`docs/quality-gates.md`](docs/quality-gates.md).  
Contributor workflow: [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Documentation map

| Doc | Purpose |
| --- | --- |
| [`docs/architecture.md`](docs/architecture.md) | System overview |
| [`docs/search-engine.md`](docs/search-engine.md) | Product search mandate |
| [`docs/correctness-persistent-mcts.md`](docs/correctness-persistent-mcts.md) | Persistence correctness layers |
| [`docs/selection-edge-local-puct.md`](docs/selection-edge-local-puct.md) | Edge-local PUCT + PDA |
| [`docs/native-ios-runbook.md`](docs/native-ios-runbook.md) | Build / run / device notes |
| [`docs/native-katago-integration.md`](docs/native-katago-integration.md) | NN adapter & NativeRelease |
| [`docs/app-store-readiness.md`](docs/app-store-readiness.md) | Store / privacy checklist |
| [`docs/oracle-test-discrepancies.md`](docs/oracle-test-discrepancies.md) | Policy-only oracle scope |
| [`LICENSE`](LICENSE) | MIT |

## Contributing

Issues and pull requests are welcome. Please:

1. Keep changes reviewable and focused.
2. Run `scripts/qixi-quality-gate.sh` before opening a PR.
3. Use the [verification matrix](docs/pr-verification-matrix.md) for the surfaces you touch.
4. Do not commit models, DerivedData, secrets, or Finder `* 2*` duplicates.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).  
Security reports: [`SECURITY.md`](SECURITY.md).

## License

Qixi application and `core/` code are released under the **MIT License** — see [`LICENSE`](LICENSE).

The `KataGo/` submodule retains **its own license and copyright** (see that tree). Qixi is an independent project that uses KataGo as a neural-network engine; it is **not** affiliated with or endorsed by the lightvector/KataGo authors beyond use of that software.

## Disclaimer

Qixi is an analysis tool for study and research. Strength and score estimates depend on the network, visit budget, and settings (including 激进度 / PDA). Treat outputs as advisory, not as absolute truth.
