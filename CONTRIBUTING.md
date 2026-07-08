# Contributing To Qixi

Qixi is intended to be a serious local Go analysis app, not a demo. Please keep
changes small enough to review, and attach evidence for every behavior you touch.

Before opening a pull request, read `docs/pr-verification-matrix.md`, identify
every changed surface, and run the union of required gates. Every pull request
starts with:

```sh
scripts/qixi-quality-gate.sh
```

That default gate includes `scripts/qixi-repo-hygiene-preflight.sh`. Do not
commit generated logs, simulator screenshots, local model packages, Xcode
archives/results, symbol bundles, or build output; they are machine-local or
recoverable artifacts, not reviewable source.

For a fast iPad/iPhone simulator visual smoke after UI, board geometry, launch,
or simulator performance changes, run:

```sh
QIXI_RUN_SCREENSHOT_SMOKE=1 scripts/qixi-quality-gate.sh
```

For full UI, localization, persistence, or launch behavior coverage, also run:

```sh
QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh
```

GitHub Actions runs `scripts/qixi_changed_surface_gate.py` on pull requests. If
the changed files touch native SwiftUI, native assets, the Xcode project,
screenshot scripts, screenshot inspectors, or the screenshot manifest, CI runs
that full screenshot gate automatically. If it does not, CI records an explicit
non-UI screenshot skip; still mention any locally skipped relevant visual checks
in the PR.

For backend, model, or KataGo changes, also run:

```sh
QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh
```

The changed-surface classifier also runs the real-model gate automatically for
backend, native KataGo, model-selection, model-manifest, or KataGo source
changes. Real-model skips are only acceptable when the change is outside that
surface, or when the PR states the concrete missing artifact and the strongest
substitute evidence.

For native KataGo, iOS model packaging, Metal/CoreML, CMake, Swift target,
bridging header, or KataGo C++ source/header changes, also run:

```sh
QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh
```

For native release linker, startup, plist, Xcode build setting, in-process
runtime, persistence/tombstone, position identity, or iCloud sync changes, also run:

```sh
QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh
```

The changed-surface classifier runs both gates automatically when their files
are touched. NativeRelease simulator skips are only acceptable when the PR is
outside the native release launch/link path, or when the PR states the concrete
missing simulator/native build artifact and the strongest substitute evidence.

For camera, iCloud, Metal/CoreML/GPU/ANE, memory, launch time, App Store, or
other OS-specific behavior, include real iPad/iPhone evidence. The simulator is
useful for layout and deterministic smoke tests, but it is not proof for
device-only behavior.

If a gate cannot be run on your machine, say exactly why in the PR and provide
the strongest substitute evidence you can. Silent skips are not accepted.

When adding a new feature, add the smallest focused test that would have failed
before the feature existed, then add any screenshot, real-model, or real-device
evidence needed by the verification matrix. When fixing a bug, add a regression test
that fails on the old behavior unless the bug is inherently device-only; in that
case, document the real-device reproduction and verification steps.
