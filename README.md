# 棋析 Qixi

棋析 is an iPad/iPhone Go analysis project built around a native SwiftUI front
end and KataGo analysis. The current workspace contains:

- `qixi-ios-native`: native SwiftUI iPad/iPhone app shell, localization, visual
  assets, simulator screenshot inspection, and app-state persistence smoke tests.
- `qixi-ios-sim`: local backend bridge and web simulator used for KataGo Metal
  mux integration testing; `NativeRelease` links explicit iOS KataGo artifacts
  for the fully in-process path when those artifacts are supplied.
- `KataGo`: the local KataGo engine checkout and modifications.

## Quality Gate

Run the default deterministic checks:

```sh
scripts/qixi-quality-gate.sh
```

The default gate includes repository hygiene. Root-level local KataGo models
such as `b18nbt.bin` and the ignored `/Models/` staging directory may exist for
development, but `.bin`, `.bin.gz`, `.txt.gz`, `.onnx`, `.mlmodel`,
`.mlmodelc`, and `.mlpackage` artifacts must not appear in source directories or
tracked files. The only raw model fixtures exempted from this tracked-file audit
are KataGo's own upstream test models under `KataGo/cpp/tests/models/`.

The default gate includes the native localization contract:

```sh
python3 qixi-ios-native/tests/test_localization_contract.py
```

It also validates `tests/fixtures/position_identity_cases.json` with
`tests/validate_position_identity_fixture.py` before backend or Swift smoke tests
consume it. The validator performs a bounded UTF-8 fixture read, rejects
symbolic-link and non-regular fixture paths, rechecks the opened descriptor with
`fstat`, and then rejects duplicate JSON keys, `NaN`/`Infinity`, unknown relation
targets, and missing same-visible/different-history identity cases. The fixture
also checks `sameNextPlayer` and includes a `ko-history-after-passes` case, so
same visible stones with the same next player still cannot share analysis when
ko-context history differs.

The Mac-hosted backend bridge uses the same strict posture for request parsing:
`qixi-ios-sim/backend/qixi_backend.py` accepts only bounded `application/json` POST bodies, rejects duplicate JSON keys and `NaN`/`Infinity`, and requires
top-level request objects before analysis or engine switching runs. The same
strict JSON object parser guards KataGo analysis stdout responses before Qixi
converts them into app-facing analysis results.
On the native Swift side, `BackendClient` also rejects non-2xx bridge
responses, non-`application/json` response bodies, duplicate JSON keys,
`NaN`/`Infinity`, non-object JSON, and response bodies larger than 1 MiB before
decoding them into app state.
The in-process native bridge path applies the same defensive posture to
`QixiNativeKataGoBridge` analysis output: duplicate JSON keys,
`NaN`/`Infinity`, non-object JSON, and response bodies larger than 1 MiB are
rejected before Swift decodes adapter output into app state.
Native persistent-MCTS tombstone reads are chunked, bounded, opened with
descriptor `fstat` checks, and reject opened-byte-count drift; native tombstone
writes use exclusive no-follow temporary files, verify written byte counts,
reject symbolic-link or directory-shaped final targets, and preserve the
previous tombstone if atomic replacement fails.
Autosave, backup, iCloud sync, lifecycle tombstone, and native engine audit
JSON files also pass a strict object parser before restore, so duplicate keys,
`NaN`/`Infinity`, non-object JSON, and oversized files cannot silently change
launch or sync state. File-backed restore paths check byte counts before
reading at most `maxBytes + 1` through `FileHandle`, then reject
opened-byte-count drift if the bytes actually read do not match the opened
descriptor's `fstat` size. This keeps corrupted, concurrently enlarged, or
concurrently truncated state files from creating large `Data` allocations or
entering restore on iPad. Shared path guards reject symbolic-link autosave,
sync, tombstone, and audit files and directories before load or write, while
allowing normal Darwin container path aliases such as `/var`. App-written
autosave, backup, iCloud sync, lifecycle tombstone, native engine audit,
release evidence, device-log, and native model/CoreML receipt files use the
shared Swift atomic writer: a same-directory temporary file opened with
exclusive no-follow flags, full-byte writes, post-write `fstat` byte-count
verification, `F_FULLFSYNC`/`fsync`, atomic `rename`, and parent-directory
`fsync` after replacement.
Real-device release evidence, its export audit, and performance/device-log
artifact JSON pass the same bounded strict object parser before Swift accepts
them as release proof; Swift rechecks artifact byte counts and SHA-256 digests
after content validation so evidence cannot hash one artifact file and validate
another, and JSON artifact content is parsed from the same strict `Data` whose
SHA-256 is compared with the recorded fingerprint. Evidence and export-audit file
and directory paths also reject symbolic links before load or write. Screenshot evidence reads only fixed PNG header bytes for
dimensions and rejects over-budget images before bitmap allocation, so malformed
large screenshots cannot spike iPad memory during release validation. Simulator
screenshot capture also rejects symbolic-link components before writing raw PNG,
cropped PNG, or metrics JSON artifacts, then publishes those artifacts through
same-directory temporary files and atomic replace.

Run simulator screenshot and persistence checks:

```sh
qixi-ios-native/scripts/screenshot-environment-doctor.sh
QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh
```

The screenshot environment artifact is verified by
`qixi-ios-native/tests/inspect_screenshot_environment.py`, so stale or malformed
environment evidence, stale `generatedAt`, future-dated `generatedAt`, or a
symbolic-link path cannot stand in for a fresh simulator setup. The environment
doctor also writes that artifact through a same-directory temporary file opened
with exclusive no-follow flags, verifies the written byte count, fsyncs the file
and parent directory, and atomically replaces the final JSON after rejecting
unsafe symbolic-link path components. If
`QIXI_SCREENSHOT_DOCTOR_ARTIFACT` is set, the same path is passed to the
inspector so generated and verified environment evidence cannot diverge.

The full screenshot gate also generates paginated review-board contact sheets
and HTML/JSON indexes under
`qixi-ios-native/artifacts/screenshots/review-board`, so reviewers can scan the
complete frontend state matrix after the per-state inspectors pass. It then
runs `qixi-ios-native/tests/inspect_screenshot_review_board.py` to verify the
review-board JSON, HTML, page PNGs, manifest-matching state counts, and current
run freshness. The inspector re-expands the screenshot manifest and requires
each review-board state to match the declared state id, dimensions, and
screenshot path in order. It also verifies SHA-256 digests for source
screenshots, generated page images, and the screenshot manifest. The manifest
artifact pass also verifies every declared screenshot script as an in-tree
executable regular file, constrains declared inspector and screenshot artifact
paths to the expected in-tree directories and suffixes, validates that declared
environment controls are `QIXI_` variables whose placeholders come from that
matrix's dimensions, and rejects symbolic links before trusting generated screenshots. The capture path itself also writes raw/cropped PNGs and metrics JSON
through protected temporary artifacts before atomic replacement, and its build
freshness markers are written through the same exclusive no-follow atomic marker
guard. It reads each PNG through an opened-descriptor bounded byte buffer,
rejects opened-byte-count drift, uses that same buffer for IHDR byte and pixel
budgets, then verifies the PNG is decodable from that same buffer and that
decoded dimensions match IHDR before any state inspector can trust the image. The review-board builder reads each source screenshot through an opened-descriptor
bounded byte buffer, rejects opened-byte-count drift, and uses the same bytes for
IHDR checks, decode, thumbnail rendering, and source digest metadata. Generated
page images are saved to bounded bytes first, then written atomically and hashed
from those same bytes. The manifest hash still uses bounded streaming with
opened-byte-count drift checks. It writes generated page images, JSON, and
HTML through same-directory atomic temporary files opened with exclusive
no-follow flags, verifies the temporary file byte count exactly matches the
payload before replacement, fsyncs the parent directory after replacement, and
refuses symbolic-link or directory-shaped targets.
The review-board inspector reads both page images and
source screenshots through opened-descriptor bounded byte buffers, rejects
opened-byte-count drift, and uses the same bytes for PNG IHDR checks, decode,
visual page statistics, and recorded digest comparison before trusting review-board JSON metadata,
rejects ambiguous JSON paths with empty, current-directory, or parent-directory
components, validates `generatedAt` as fresh microsecond UTC run metadata, and
rejects timestamps that are stale or too far in the future, and enforces a
bounded HTML size before reading review-board links. Review-board JSON and HTML
indexes are read through bounded UTF-8 loads that recheck opened descriptors
with `fstat`; digest recomputation uses the same opened-descriptor guard and
rejects opened-byte-count drift while streaming.

Pull requests are also classified by `scripts/qixi_changed_surface_gate.py`.
The classifier accepts only repository-relative POSIX changed-file paths; it
rejects absolute paths, home-relative paths, empty path segments, `.`, `..`,
backslashes, control characters, and surrounding whitespace instead of silently
weakening gate selection.
When a PR touches the native SwiftUI surface, image assets, Xcode project,
screenshot scripts, screenshot review-board/performance/persistence helper
scripts, screenshot inspectors, or the screenshot manifest, GitHub Actions
automatically runs the full screenshot gate instead of relying on a manual
reviewer reminder.
When a PR touches backend analysis, model selection, native KataGo integration,
KataGo source, local model manifests, or raw/ONNX/CoreML package artifact paths,
GitHub Actions automatically runs the real-model gate as well. If the required
local models or Metal mux binary are not available in CI, that gate fails loudly
instead of turning missing model evidence into a green check.
Native release linker, startup, plist, Xcode build setting, bridging header,
native in-process runtime, persistence/tombstone, position identity, iCloud
sync, or KataGo C++ source/header changes also automatically run the linked
NativeRelease simulator smoke through
`QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh`.
When a PR touches App Store/release evidence scripts, the App Store archive
preflight, device preflight/signing doctor/bridge smoke contracts, the real-device evidence negative
simulator smoke, privacy metadata, entitlements, CI verification rules,
native runtime/evidence export files, persistence/tombstone, position identity, iCloud
sync, bridging headers, release runbooks such as `docs/native-ios-runbook.md`,
native engine integration docs such as `docs/native-katago-integration.md`,
Qixi README files, position identity fixtures, native model manifests, or
raw/ONNX/CoreML package artifact paths, GitHub Actions also records a release-sensitive review
classification so release readiness claims must carry explicit App Store/device evidence.

The screenshot gate is declared in
`qixi-ios-native/tests/screenshot_coverage_manifest.json`. It currently expands
to 145 required frontend states across iPad, iPhone, three UI languages,
onboarding, Hermes status, explicit b6/b18nbt/b28nbt engine-selection states,
board overlays, board-recognition preview, captured-stone replay, utility
sheets, native model-install statuses, native engine and Local Network failure
reasons on iPad and iPhone, iCloud sync success/failure/conflict states, and the simulator
real-device evidence negative, persistence, and performance smoke states. The
manifest itself must be a non-empty regular file, not a symbolic link, and stay
within the manifest byte budget before the manifest itself is parsed as standards-compliant JSON,
rejecting duplicate
object keys and `NaN`/`Infinity` constants before any state expansion. The loader
also rechecks the opened file descriptor as a non-empty regular file within the
same byte budget before reading, so a stat/open race cannot swap in an unsafe
manifest. The screenshot gate then
re-expands that manifest and re-runs each declared image inspector against every
expected artifact, so a newly declared frontend state cannot quietly miss its
captured PNG.

Run real-model backend integration checks:

```sh
QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh
```

On success, the b6/b18nbt/b28nbt integration writes
`qixi-ios-sim/artifacts/real-models/latest-real-model-integration.json` with
per-model timing, model byte counts, multi-position analysis case summaries,
root visits, candidate counts, ownership range, best move summaries, and
position-key isolation evidence for debugging and PR review. The default
real-model evidence uses at least 8 visits per case and covers the opening
position plus a same-visible-stones/different-history pair, so model switching
cannot pass by returning one low-effort response or by collapsing history into
only the visible board. The integration scripts read backend responses through bounded
`application/json` strict object parsing, so duplicate keys, `NaN`/`Infinity`,
or non-object response bodies cannot become accepted evidence. The quality gate immediately re-reads that file with
`qixi-ios-sim/tests/inspect_real_model_integration_artifact.py`, so stale,
missing, non-standards-compliant JSON, incomplete, or internally inconsistent
real-model evidence fails the same run. The inspector uses bounded artifact
JSON reads and rejects symbolic-link or non-regular artifact, KataGo binary,
config, and model paths before trusting local byte counts; referenced files must
stay inside the repository root. The integration publishes that artifact with a
same-directory exclusive no-follow temporary file, file `fsync`, atomic replace,
and parent-directory `fsync`, so a partial or redirected evidence file is not
silently accepted. The gate also stamps the start of the
real-model integration phase and rejects any artifact whose file mtime predates
that marker, so a recent artifact from an earlier run cannot satisfy the
current check.

Run the iOS KataGo CMake build gate for native-engine changes:

```sh
QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh
```

This explicitly builds and validates the `katago_core` static-library target for
both `iphonesimulator` and `iphoneos`, then checks the produced Mach-O platform
and architecture with `lipo`/`otool`. It proves the local KataGo Metal/iOS
library build path is still viable, but it is not a substitute for linking that
library into the Qixi app target or for recording nativeInProcess evidence from
a physical iPad or iPhone.

Run the NativeRelease simulator smoke after native linker, release-plist, or
startup changes:

```sh
QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh
```

That smoke builds the simulator `katago_core` artifact, validates the fresh
`libkatago_core.a` and matching `libKataGoSwift.a` sidecar with `lipo`/`otool`
for arm64 iOS Simulator Mach-O platform output, links the `NativeRelease`
simulator app against those artifacts, validates the app executable with the
same iOS Simulator architecture/platform checks, rejects development bridge
strings in the executable, launches without backend environment variables, and
inspects a screenshot for nonblank landscape content. The full-frame and
content-cropped simulator screenshots are written to protected same-directory
temporary PNGs and atomically replaced after symbolic-link output paths are
rejected. It is still not
physical-device `nativeInProcess` evidence.

Run the non-skippable release evidence gate before claiming the app is ready for
submission or production device evidence:

```sh
QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess \
QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json \
QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive \
QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW=1 \
scripts/qixi-release-evidence-gate.sh
```

This gate is expected to fail until a signed `NativeRelease` archive, a linked
iOS KataGo artifact, and physical-device `nativeInProcess` evidence are all
provided. The development placeholder native engine remains compiled only when
`QIXI_ENABLE_NATIVE_KATAGO=0`; it is useful for Debug/Release diagnostics, but
it is not release evidence. Do not set `QIXI_DEVICE_BACKEND_URL` or
`QIXI_BACKEND_URL` when running this release gate; any backend transport belongs
only to development bridge evidence. The real-device run-kit sets
`QIXI_AUTOMATION_SELECT_ENGINE=b6` and
`QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH=1` for the finalization launch;
change the engine to `b18nbt` or `b28nbt` when validating those larger models.
Run the physical app once without `QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH`
so native analysis, autosave, and tombstone export complete, collect the real
screenshot/performance artifacts, generate or refresh the run-kit `runId` /
`recordedAt` seed, then run
`scripts/qixi-real-device-run-kit-preflight.sh /tmp/qixi-real-device-run` before
the finalization launch so unfilled placeholders, backend URLs, template
performance JSON, missing screenshot/performance artifacts, and pre-existing
app-written evidence files are rejected. The release gate forces the final quality
gate to run tracked-file audit, full screenshots, real-model integrations, the
Simulator+device iOS KataGo CMake path, and the runnable linked NativeRelease
Simulator smoke, and it fails if `xcodebuild` is not
available, if `xcodebuild` does not resolve to `/usr/bin/xcodebuild` because a
shadowed `xcodebuild` appears earlier in `PATH`, or if `xcodebuild -showsdks` does not report an `iphoneos` SDK,
instead of accepting a skipped native Xcode build.

Check the native iPad model manifest against the local model files:

```sh
scripts/qixi-native-model-preflight.sh
```

This preflight deliberately treats model metadata as an untrusted input
boundary. Swift source and manifest files are read through bounded loads, model
paths must not traverse symbolic links, and each model is size-checked before
hashing so a malformed package cannot turn a review or CI run
into an unbounded memory read. The preflight rechecks opened descriptors with
`fstat` and rejects opened-byte-count drift after streaming model hash chunks.
The native in-app installer applies the same
posture to imported raw model files, managed model/CoreML package directories,
and install receipt read/write paths.

Check that the planned native adapter still compiles against KataGo's
Board/BoardHistory/AsyncBot/Search APIs:

```sh
qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh
```

The native in-process contract preflight also reads its audited source and
contract-document inputs through bounded UTF-8 loads, rejects symbolic-link path
components, and rechecks opened descriptors with `fstat`.

Check that a release candidate is configured to link a real iOS KataGo library
or XCFramework instead of the development bridge/placeholder path:

```sh
QIXI_KATAGO_IOS_XCFRAMEWORK=/path/to/KataGo.xcframework \
scripts/qixi-native-linked-build-preflight.sh
```

Release linkage evidence must identify exactly one native KataGo artifact:
set either `QIXI_KATAGO_IOS_XCFRAMEWORK` or `QIXI_KATAGO_IOS_LIBRARY`, not
both, and use absolute paths. When using `QIXI_KATAGO_IOS_LIBRARY`, also set
absolute `QIXI_KATAGO_IOS_LIBRARY_DIR` to the directory containing the matching
`libKataGoSwift.a` Metal sidecar.

The Xcode project keeps Debug/Release on the development bridge and uses a
separate `NativeRelease` configuration with `Qixi/NativeReleaseInfo.plist`,
`QIXI_ENABLE_NATIVE_KATAGO=1`, `QIXI_NATIVE_RELEASE` Swift compilation guards,
an explicit exclusion for the development HTTP bridge Swift source files,
KataGo header search paths, and Metal/Accelerate plus CoreML/MPS/MPSGraph/zlib
linkage for the native path.
`QIXI_KATAGO_IOS_LIBRARY=/path/to/libkatago_core.a` is accepted when the Xcode
target is wired to a static library instead of an XCFramework.
Set `QIXI_NATIVE_LINKED_PREFLIGHT_REPORT=/path/to/native-linked-report.json` to
write the linked-build blocker list as JSON for release review. The report path
rejects symbolic links and is written through an exclusive flushed temporary
file plus atomic replace. The linked preflight also bounds source/plist reads
and rechecks opened descriptors with `fstat` before trusting release-linkage
metadata.
After the linked-artifact preflight, run the native release Xcode build
preflight to prove the `Qixi` app target itself builds with those artifacts:

```sh
QIXI_KATAGO_IOS_LIBRARY=/path/to/libkatago_core.a \
QIXI_KATAGO_IOS_LIBRARY_DIR=/path/to/cmake-build \
scripts/qixi-native-release-build-preflight.sh
```

That script builds `NativeRelease` for `generic/platform=iOS`, rejects shadowed
`xcodebuild`, validates the built `NativeRelease-iphoneos/Qixi.app` as
`nativeInProcess` without `QixiBackendBaseURL`, checks arm64 iOS Mach-O output,
and scans out development bridge or placeholder strings such as `BackendClient`,
`HTTPBridgeAnalysisService`, `Qixi HTTP bridge response`,
`qixi.backendBaseURL`, `QIXI_ANALYSIS_RUNTIME`, and local backend URLs.

Check the iOS Simulator Metal/CoreML CMake configure path for the eventual
on-device KataGo library:

```sh
scripts/qixi-ios-katago-cmake-preflight.sh
```

For release evidence, build the full iOS device KataGo target:

```sh
QIXI_IOS_SDK=iphoneos QIXI_IOS_KATAGO_BUILD_TARGET=katago_core scripts/qixi-ios-katago-cmake-preflight.sh
```

Check the physical-device bridge run path before recording iPad/iPhone evidence:

```sh
scripts/qixi-device-signing-doctor.sh
scripts/qixi-device-run-preflight.sh
QIXI_DEVICE_STRICT=1 \
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_ID=<devicectl-identifier-if-needed> \
QIXI_DEVICE_DEVELOPMENT_TEAM=<team-id-if-not-set-in-project> \
scripts/qixi-device-run-preflight.sh
```

Strict physical-device preflight requires a connected iPad/iPhone with Developer
Mode enabled, Developer Disk Image services available, an Xcode iOS destination
for that UDID, and an Apple Development signing identity for the configured
development team before any iPad/iPhone evidence can be treated as real. It
also requires an installed iOS App Development provisioning profile matching the
team, `PRODUCT_BUNDLE_IDENTIFIER`, physical-device UDID, and expiration date.
`scripts/qixi-device-signing-doctor.sh` prints the resolved bundle id, team,
device UDID, Apple Development identities, scanned provisioning profiles, and
per-profile mismatch reasons before the stricter pass/fail preflight is used.
With `QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES=1`, it also runs a real
`xcodebuild build` signing probe in temporary DerivedData so invalid Xcode
credentials, `No Accounts`, or `No profiles for` failures surface before the
bridge install/launch stages.
Set `QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES=1` only after adding a valid Xcode
account for that team; the bridge smoke will then pass
`-allowProvisioningUpdates` and `-allowProvisioningDeviceRegistration` to
`xcodebuild`.

After strict preflight passes, run the reproducible bridge smoke:

```sh
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_DEVELOPMENT_TEAM=<team-id-if-not-set-in-project> \
scripts/qixi-device-bridge-smoke.sh
```

To make the installed iPad/iPhone app select and autosave a specific engine
during that launch, add `QIXI_DEVICE_AUTOMATION_SELECT_ENGINE=b6`,
`QIXI_DEVICE_AUTOMATION_SELECT_ENGINE=b18nbt`, or
`QIXI_DEVICE_AUTOMATION_SELECT_ENGINE=b28nbt`. The artifact inspector then
checks the copied `Library/Application Support/Qixi` autosave and backup
snapshots, the app-side `runtime-diagnostics.qixi-state.json`, and the
Mac-hosted backend `/api/events` request log, not only the launch command.
If the smoke reports `Denied over Wi-Fi interface`, enable Local Network access
for the installed Qixi app in iPadOS Settings and rerun the smoke; iOS local
network privacy can block the bridge before any KataGo request reaches the Mac.
Even on that failure path, `latest-device-bridge-failure-backend-events.json`
is written with `observedExpectedEngine=false`, a structured
`diagnosticCategory` such as `iosLocalNetworkDenied`, and the copied app-side
diagnostic hint so the run can be audited after the terminal log scrolls away.
Inspect a recorded failure explicitly with:

```sh
scripts/qixi-device-bridge-failure-inspect.sh \
  qixi-ios-native/artifacts/device-bridge/latest-device-bridge-failure.json
```

When the checked-out project team is not available on the Mac, use an explicit
personal bundle identifier for local physical-device bridge/UI debugging:

```sh
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_DEVELOPMENT_TEAM=<available-team-id> \
QIXI_DEVICE_BUNDLE_ID=com.example.qixi.local-device \
QIXI_DEVICE_DISABLE_ICLOUD_ENTITLEMENTS=1 \
scripts/qixi-device-bridge-smoke.sh
```

`QIXI_DEVICE_BUNDLE_ID` is resolved by the signing doctor, strict preflight, and
the bridge smoke build itself, so the profile lookup, built app validation, and
`devicectl` launch all agree on one bundle identifier. Disabling iCloud
entitlements is only for local bridge smoke with a personal bundle id; that run
does not count as iCloud sync, App Store, or release evidence.

To preview the exact physical-device bridge commands and current signing
blockers without building, installing, launching, or creating provisioning
profiles, add `QIXI_DEVICE_BRIDGE_PLAN_ONLY=1`. The resulting manifest is
written with `dryRun=true` and records `preflight.signingBlockers`; validate it
with `scripts/qixi-device-bridge-plan-inspect.sh`. The real bridge artifact
inspector deliberately rejects the same manifest as device evidence.
The same preview can run inside the quality gate with
`QIXI_RUN_DEVICE_BRIDGE_PLAN=1 scripts/qixi-quality-gate.sh`.

If Xcode should create or refresh the development profile during the smoke, add
`QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES=1` to that command after the account is
configured in Xcode.

It builds, installs, and launches the Debug `iphoneos` app on the physical
device with the Mac-hosted backend URL, then writes install, launch, process,
display, and app-container artifacts under
`qixi-ios-native/artifacts/device-bridge`. The bridge manifest includes a
per-run `runId`, UTC `generatedAt` / `startedAt` / `completedAt` timestamps,
and per-stage `timingsMs`. Set `QIXI_DEVICE_BRIDGE_RUN_ID` to a canonical
32-character lowercase hex value when a surrounding evidence run must bind this
bridge smoke to other artifacts.

Validate those artifacts before citing them:

```sh
scripts/qixi-device-bridge-plan-inspect.sh
scripts/qixi-device-bridge-smoke-inspect.sh
QIXI_RUN_DEVICE_BRIDGE_SMOKE=1 \
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_DEVELOPMENT_TEAM=<team-id-if-not-set-in-project> \
scripts/qixi-quality-gate.sh
```

The GitHub workflow also has a manual `run_device_bridge_smoke` dispatch input
for a configured Mac runner. Its `device_bridge_runner` input is a JSON
runner-label array and defaults to `["self-hosted","macOS","qixi-device"]`.
Retarget it only to another runner with the same physical-device access. Set
`QIXI_DEVICE_BACKEND_URL`, `QIXI_DEVICE_DEVELOPMENT_TEAM`, optional
`QIXI_DEVICE_ID`, and optional `QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES` as
repository secrets before using that `Device Bridge Smoke Gate`.

Check the recorded real-device evidence JSON before using it in a release claim:

```sh
QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess \
QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json \
scripts/qixi-real-device-evidence-preflight.sh
```

Check that generated logs, screenshots, local model packages, Xcode archives,
symbol bundles, build output, `.DS_Store`, Python bytecode caches, coverage
outputs, and JS/Python tool caches are ignored and not tracked; local metadata,
coverage outputs, and tool caches are also rejected from
non-ignored source paths:

```sh
scripts/qixi-repo-hygiene-preflight.sh
```

See `docs/quality-gates.md` for when each gate is required.

Pull request authors should use `docs/pr-verification-matrix.md` to map each
changed surface to required tests, screenshots, real-model checks, and real-device
evidence.

Submission-facing privacy and App Store checks are tracked in
`docs/app-store-readiness.md`.

## Native App

Native app instructions live in `qixi-ios-native/README.md`.
For simulator and physical-device smoke testing, see
`docs/native-ios-runbook.md`.
For an interactive native iPad Simulator run on Mac:

```sh
qixi-ios-native/scripts/run-native-sim.sh
```

The production in-process engine boundary is tracked in
`docs/native-katago-integration.md`.

## Backend Simulator

Backend simulator and Metal mux instructions live in `qixi-ios-sim/README.md`.
