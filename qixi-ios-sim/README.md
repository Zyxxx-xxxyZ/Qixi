# Qixi iOS simulator / Mac bridge (optional)

> **Not the default product path.** The shipping app is `qixi-ios-native` with in-process `core::MCTSStore` + linked KataGo NN (`NativeRelease`).
> This tree is for Mac-hosted HTTP bridge and web simulator development tooling.

# Qixi iOS Local Analysis Simulator

This directory is a lightweight iPad-shaped simulator for integrating the local
KataGo engine into "棋析" before a signed native iOS target is wired up.

It provides:

- A touch-oriented board UI using the requested board and stone assets.
- A local HTTP backend that the UI talks to.
- A KataGo analysis-process bridge that can run the Metal mux path when a model
  is supplied.
- A deterministic mock engine fallback so the UI can be tested without a model.

## Run Locally

```sh
cd $(git rev-parse --show-toplevel)
python3 qixi-ios-sim/backend/qixi_backend.py --host 0.0.0.0 --port 8765
```

Then open:

```text
http://127.0.0.1:8765
```

To open it in the installed iPad simulator:

```sh
xcrun simctl boot "iPad Pro 13-inch (M5)" || true
xcrun simctl openurl booted http://127.0.0.1:8765
```

To open it on a physical iPad, put the Mac and iPad on the same network and open
`http://<mac-lan-ip>:8765` in Safari.

## Run With KataGo Metal Mux

Build KataGo first:

```sh
cd $(git rev-parse --show-toplevel)/KataGo
/opt/homebrew/bin/cmake -G Ninja -S cpp -B cpp/build-metal-mux -DUSE_BACKEND=METAL -DCMAKE_BUILD_TYPE=Release -DNO_GIT_REVISION=1
/opt/homebrew/bin/cmake --build cpp/build-metal-mux --target katago -j 6
```

The backend defaults to the real models in this checkout when these engines are
selected:

```text
b6     $(git rev-parse --show-toplevel)/KataGo/cpp/tests/models/g170-b6c96-s175395328-d26788732.bin.gz
b18nbt $(git rev-parse --show-toplevel)/b18nbt.bin
b28nbt $(git rev-parse --show-toplevel)/b28nbt.bin
```

To force a specific model and optional config:

```sh
export QIXI_KATAGO_BIN=$(git rev-parse --show-toplevel)/KataGo/cpp/build-metal-mux/katago
export QIXI_KATAGO_MODEL=$(git rev-parse --show-toplevel)/KataGo/cpp/tests/models/g170-b6c96-s175395328-d26788732.bin.gz
export QIXI_KATAGO_CONFIG=$(git rev-parse --show-toplevel)/KataGo/cpp/configs/analysis_example.cfg
export QIXI_KATAGO_OVERRIDE="$(cat $(git rev-parse --show-toplevel)/qixi-ios-sim/configs/metal-mux.override)"
python3 $(git rev-parse --show-toplevel)/qixi-ios-sim/backend/qixi_backend.py --host 0.0.0.0 --port 8765
```

Optional per-engine overrides:

```sh
export QIXI_KATAGO_B6_MODEL=/path/to/b6.bin.gz
export QIXI_KATAGO_B18_MODEL=/path/to/b18nbt.bin
export QIXI_KATAGO_B28_MODEL=/path/to/b28nbt.bin
```

`metalDeviceToUseThread0/1 = 0` routes two server threads through Metal GPU
MPSGraph. `metalDeviceToUseThread2/3 = 100` routes two server threads through
CoreML CPU+ANE. That is the mux mode fixed by lightvector/KataGo#1205.

## Native iPad Target Notes

A signed native iPad build still needs an Xcode app target and an iOS static
library or framework build of KataGo. The production bridge should call KataGo's
search APIs directly instead of shelling out, because iOS apps cannot spawn an
arbitrary bundled command-line engine the way this Mac-hosted simulator can.

For a physical iPad smoke test today, use the Safari flow above. For the native
app, follow `docs/native-ios-runbook.md`.
