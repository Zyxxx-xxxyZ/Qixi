# Qixi Native SwiftUI Frontend

This is the native SwiftUI frontend for the local iPad/iPhone analysis app.

## Build

```sh
cd /Users/zyx/Desktop/projects/katago2
xcodebuild -project qixi-ios-native/Qixi.xcodeproj -scheme Qixi -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath /private/tmp/qixi-derived-sim CODE_SIGNING_ALLOWED=NO build
```

For a physical iPad or iPhone, open `qixi-ios-native/Qixi.xcodeproj` in Xcode,
select your device, set the signing team, and run. The signing team also needs
a matching iOS App Development provisioning profile for
`com.qixi.localanalysis`; run `scripts/qixi-device-signing-doctor.sh` and then
`scripts/qixi-device-run-preflight.sh` from the repository root before treating
a device run as evidence. A device that is listed by `devicectl` is not enough:
the signing doctor must also show active transport, Developer Disk Image
services, install/launch capability, and an Apple Development identity for the
selected team. The app is landscape-only.
The full simulator, backend, and physical-device runbook lives at
`../docs/native-ios-runbook.md`.

## Run In The iOS Simulator

For interactive Mac-side inspection of the native SwiftUI app:

```sh
cd /Users/zyx/Desktop/projects/katago2
qixi-ios-native/scripts/run-native-sim.sh
```

The script boots an available iPad simulator, builds and installs the app,
launches it with `QIXI_ANALYSIS_RUNTIME=httpBridge`, and points it at
`QIXI_BACKEND_URL=http://127.0.0.1:8765` by default. It preserves the simulator
app container so launch-restore and autosave behavior can be inspected across
runs. Set `QIXI_SIM_RESET_APP=1` for a clean install, `QIXI_APP_LANGUAGE` to
`zh-Hans`, `zh-Hant`, or `en`, and `QIXI_SIM_RUN_CONSOLE=1` when stdout/stderr
should stay attached. The script rejects shadowed `xcodebuild` binaries and
refuses to install a simulator app whose `Qixi.app/Qixi` executable is missing,
empty, symbolic-linked, or older than the current run's build marker.

The current backend bridge defaults to `http://127.0.0.1:8765`, which works for
the iOS Simulator when the local Python backend is running on the Mac. For a
physical device, run the backend with `--host 0.0.0.0`, find the Mac LAN address,
and set the Xcode Run scheme environment variable `QIXI_BACKEND_URL` to
`http://<mac-lan-ip>:8765`. The app also accepts the same value from
`UserDefaults` key `qixi.backendBaseURL`; both override the `QixiBackendBaseURL`
default in `Info.plist`.

The analysis runtime is explicit. Current development device smoke tests should
use `QIXI_ANALYSIS_RUNTIME=httpBridge`. The `nativeInProcess` runtime entrypoint
is compiled through the Objective-C++ `QixiNativeKataGoBridge`; Debug/Release
diagnostic builds intentionally fail with `libraryNotLinked`, while
`NativeRelease` must be built with an explicit iOS KataGo artifact and matching
`libKataGoSwift.a` sidecar via `scripts/qixi-native-release-build-preflight.sh`.

Photo recognition is intentionally treated as a visible-stone preview until a
history-preserving import flow exists. A board photo cannot reconstruct the
ordered move history, and Qixi must not turn same-stones/different-history
positions into the same analysis root.

## Test

```sh
python3 qixi-ios-native/tests/test_frontend_contract.py
python3 qixi-ios-native/tests/test_localization_contract.py
qixi-ios-native/tests/run_sgf_parser_smoke.sh
qixi-ios-native/tests/run_board_recognition_smoke.sh
qixi-ios-native/tests/run_variation_tree_layout_smoke.sh
qixi-ios-native/tests/run_analysis_service_smoke.sh
qixi-ios-native/tests/run_persistence_sync_smoke.sh
```

`run_analysis_service_smoke.sh` first invokes the shared
`tests/validate_position_identity_fixture.py` validator before compiling the
Swift smoke driver, so standalone native analysis tests use the same strict
position-identity fixture gate as the default project quality gate. That
validator reads the shared fixture through a bounded UTF-8 load, rejects
symbolic-link and non-regular fixture paths, and rechecks the opened descriptor
with `fstat` before strict JSON parsing.

## Screenshot QA

```sh
qixi-ios-native/scripts/screenshot-sim.sh
```

For a fast local visual smoke that captures and inspects the iPad landscape
surface, the iPhone landscape surface, and the simulator launch/RSS performance
artifact in one pass:

```sh
qixi-ios-native/scripts/screenshot-smoke-sim.sh
```

The same smoke can be run through the project quality gate:

```sh
QIXI_RUN_SCREENSHOT_SMOKE=1 scripts/qixi-quality-gate.sh
```

The required screenshot matrix is declared in
`qixi-ios-native/tests/screenshot_coverage_manifest.json`. It currently expands
to 145 required frontend states covering iPad, iPhone, all three supported
languages, onboarding, Hermes status, explicit b6/b18nbt/b28nbt engine-selection
states, board overlays, board-recognition preview, captured-stone replay,
utility sheets, native model-install statuses, native engine and Local Network
failure reasons on iPad and iPhone, iCloud sync success/failure/conflict states, and the simulator
real-device evidence negative, persistence, and performance smoke states. The full screenshot
gate finishes by running `inspect_screenshot_manifest_artifacts.py`, which
first reads the manifest through a bounded non-symbolic-link regular-file guard,
rechecks the opened file descriptor with `fstat` before reading,
then re-expands the manifest, verifies every declared screenshot script is an
in-tree executable regular file, constrains declared inspector and screenshot
artifact paths to the expected in-tree directories and suffixes, validates
declared `QIXI_` environment controls and their dimension placeholders, rejects
symbolic links, verifies every expected PNG exists, reads each PNG through an
opened-descriptor bounded byte buffer, rejects opened-byte-count drift, uses
that same buffer to enforce IHDR byte and pixel budgets, verifies each PNG is
decodable from that same buffer with decoded dimensions matching IHDR, and
re-runs the declared inspector for each
state. It also compares engine error variants so the
library-not-linked, model-missing, insufficient-memory, and local-network-denied
banners remain visibly distinct in each supported language. Utility sheet, model install, and
iCloud sync variants are compared as well, so those states cannot collapse into
one generic sheet.
After that inspection passes, the full gate runs
`qixi-ios-native/scripts/build_screenshot_review_board.py` to write paginated
contact sheets plus `latest-screenshot-review-board.html` and
`latest-screenshot-review-board.json` indexes in
`qixi-ios-native/artifacts/screenshots/review-board`, giving reviewers a single
place to scan every required frontend state without weakening the per-state
inspectors. The builder reads each source screenshot through an
opened-descriptor bounded byte buffer, rejects opened-byte-count drift, and uses
the same bytes for PNG IHDR checks, decode, thumbnail rendering, and source
digest metadata. Generated page images are saved to bounded bytes first, then
written atomically and hashed from those same bytes. The manifest hash still
uses bounded streaming with opened-byte-count drift checks. It writes generated
page images, JSON, and HTML through same-directory atomic temporary files opened
with exclusive no-follow flags, verifies the temporary file byte count exactly
matches the payload before replacement, fsyncs the parent directory after
replacement, and refuses symbolic-link or directory-shaped targets.
The gate immediately checks those review-board artifacts with
`qixi-ios-native/tests/inspect_screenshot_review_board.py`, verifying the JSON
index, HTML references, page images, 145-state coverage, and artifact freshness
for the current full-screenshot run. That inspector reads both page images and
source screenshots through opened-descriptor bounded byte buffers, rejects
opened-byte-count drift, and uses the same bytes for PNG IHDR checks, decode,
visual page statistics, and recorded digest comparison before trusting
review-board JSON metadata, rejects ambiguous JSON paths with empty, current-directory, or
parent-directory components, validates `generatedAt` as fresh microsecond UTC
run metadata, rejects timestamps that are stale or too far in the future, and
enforces a bounded HTML size before reading review-board links. Review-board
JSON and HTML indexes are read through bounded UTF-8 loads that recheck opened
descriptors with `fstat`; SHA-256 digest recomputation uses the same
opened-descriptor guard and rejects opened-byte-count drift while streaming.
It re-expands the screenshot manifest and
checks each review-board state in order, including dimensions and screenshot
path, so the board cannot pass with swapped or substituted states. The JSON
index also stores SHA-256 digests for the screenshot manifest, source
screenshots, and generated page images, and the inspector recomputes them.

The script boots an available iPad simulator if needed, builds the SwiftUI app,
installs it, launches it, and writes:

```text
qixi-ios-native/artifacts/screenshots/latest-ipad.png
```

It also keeps the unmodified device framebuffer at:

```text
qixi-ios-native/artifacts/screenshots/latest-ipad.raw.png
```

Screenshot and interactive simulator scripts require `xcodebuild` to resolve to
`/usr/bin/xcodebuild`; a shadowed tool earlier in `PATH` fails instead of
producing stale or fake visual evidence. Both paths also validate the built
`Qixi.app` before install/capture, including a fresh executable mtime check
against the current build marker so stale DerivedData output cannot be reused as
new screenshot evidence.

Use `QIXI_SIM_DEVICE` or `QIXI_SIM_UDID` to target another simulator.
Use `QIXI_APP_LANGUAGE=zh-Hans`, `QIXI_APP_LANGUAGE=zh-Hant`, or
`QIXI_APP_LANGUAGE=en` to force a language for that simulator launch.
Use `QIXI_BACKEND_URL=http://<host>:8765` to point the installed simulator app
at a non-default backend endpoint.
Use `QIXI_HERMES_STATUS=ready`, `QIXI_HERMES_STATUS=loading`, or
`QIXI_HERMES_STATUS=offline` to freeze the Hermes engine status badge for
visual inspection.
Use `QIXI_ENGINE_ERROR=library-not-linked`, `model-missing`,
`insufficient-memory`, or `local-network-denied` to freeze visible native engine
and Local Network failure reasons for visual inspection.
Use `QIXI_ICLOUD_SYNC_ENABLED=0` or `QIXI_ICLOUD_SYNC_ENABLED=1` to freeze the
iCloud sync setting for utility-sheet visual inspection.
Use `QIXI_OPEN_UTILITY_SHEET=import` with
`QIXI_IMPORT_SHEET_STATUS=verifying`, `installed-b18nbt`, or `failed` to freeze
native model-install states inside the import sheet.
Use `QIXI_ANALYSIS_FIXTURE=board-overlays` with `QIXI_SHOW_TERRITORY=1` to
freeze candidate-move circles and MCTS territory markers for visual inspection.
Use `QIXI_ANALYSIS_FIXTURE=board-capture-replay` to freeze a captured-stone board
state for visual inspection.

Then run the image-level smoke inspection:

```sh
python3 qixi-ios-native/tests/inspect_screenshot.py
```

To cover every supported UI language in one pass:

```sh
qixi-ios-native/scripts/screenshot-all-locales.sh
```

To cover the Hermes ready/loading/offline engine status badge in every
supported UI language:

```sh
qixi-ios-native/scripts/screenshot-hermes-statuses.sh
```

To cover candidate-move circles and MCTS territory markers in every supported
UI language:

```sh
qixi-ios-native/scripts/screenshot-board-overlays.sh
```

To cover captured-stone board replay in every supported UI language:

```sh
qixi-ios-native/scripts/screenshot-board-capture-replay.sh
```

To cover the first-launch language and iCloud setup screen in every supported
UI language:

```sh
qixi-ios-native/scripts/screenshot-onboarding-all-locales.sh
```

To cover the iPhone landscape layout:

```sh
qixi-ios-native/scripts/screenshot-iphone-sim.sh
```

To cover the iPhone first-launch language and iCloud setup screen:

```sh
qixi-ios-native/scripts/screenshot-iphone-onboarding-sim.sh
```

To cover the iPhone landscape layout in every supported UI language:

```sh
qixi-ios-native/scripts/screenshot-iphone-all-locales.sh
```

To cover the iPhone first-launch screen in every supported UI language:

```sh
qixi-ios-native/scripts/screenshot-iphone-onboarding-all-locales.sh
```

To cover iPhone landscape native engine error states in every supported UI
language:

```sh
qixi-ios-native/scripts/screenshot-iphone-engine-errors.sh
```

To cover the iPhone utility sheets for photo scan, SGF import, native model
install, and iCloud sync:

```sh
qixi-ios-native/scripts/screenshot-iphone-utility-sheets.sh
```

To cover the utility sheets for photo scan, SGF import, native model install,
and iCloud sync. The sync sheet is captured in disabled, enabled, synced,
failure, and conflict states, and model install is captured in verifying,
installed, and failed states:

```sh
qixi-ios-native/scripts/screenshot-utility-sheets.sh
```

To verify that the simulator app actually creates its launch autosave snapshot:

```sh
qixi-ios-native/scripts/persistence-smoke-sim.sh
```

Every successful autosave writes both `autosave.qixi-state.json` and
`autosave.qixi-state.backup.json`. Launch restore reads every valid local
autosave candidate and restores the newest `savedAt`, so a corrupted,
schema-incompatible, or stale primary file does not erase the user's last
recoverable state.
Autosave, backup, sync, lifecycle tombstone, native engine audit, evidence,
device-log, and native model/CoreML receipt writes use the shared Swift atomic
writer: a same-directory temporary file opened with exclusive no-follow flags,
full-byte writes, post-write `fstat` byte-count verification,
`F_FULLFSYNC`/`fsync`, atomic `rename`, and parent-directory `fsync` after
replacement.
Background, inactive, and termination lifecycle paths write the latest autosave
snapshot immediately and then mark `lifecycle-tombstone.qixi-state.json` beside
it. The tombstone is a small audit record that points back to
`autosave.qixi-state.json`, so a device killed while backgrounded still has a
fresh recoverable snapshot on disk.
The simulator persistence smoke injects
`QIXI_LIFECYCLE_TOMBSTONE_ON_LAUNCH=automation.lifecycle` to prove the installed
app process can write both files into its container and that the tombstone points
to the same saved snapshot.
It launches with `QIXI_ANALYSIS_RUNTIME=nativeInProcess` by default and also
verifies that the installed app writes `native-engine-tombstone.qixi-native`
through the native engine tombstone path. It also verifies
`native-engine-tombstone.export.json`, proving that the lifecycle-triggered
engine export completed for the same reason recorded by
`lifecycle-tombstone.qixi-state.json`. The same smoke seeds an existing native
tombstone before launch and verifies
`native-engine-tombstone.restore.json`, proving that startup restore actually
crossed the native engine tombstone service boundary instead of only writing a
new lifecycle marker. The restore audit records both the tombstone filename and
the target engine so b6, b18nbt, b28nbt, and no-engine restore evidence cannot
be conflated.
The full screenshot/persistence gate also runs
`qixi-ios-native/scripts/real-device-evidence-negative-smoke-sim.sh`, which
proves a Simulator launch cannot create release-valid real-device evidence even
when automation supplies plausible metrics and placeholder artifacts. The app
must instead write `real-device-evidence.export.json` with `status = failed`.
For a physical `nativeInProcess` release run, first generate a non-evidence run
kit with:

```sh
scripts/qixi-real-device-evidence-template.py --output-dir /tmp/qixi-real-device-run
```

That template lists the required environment values and artifact filenames while
refusing inherited backend URLs or stale final evidence/artifact files:
`real-device-evidence.qixi-release.json`, `real-device-evidence.export.json`,
`real-device-main.png`, `real-device-performance.json`, and
`real-device-log.json`. It writes only template files such as
`real-device-performance.template.json` and `real-device-log.template.json`;
the app writes the matching final device-log artifact from the same evidence
object, and the final `real-device-evidence.qixi-release.json` must still be
generated on a real iPad or iPhone and validated with
`scripts/qixi-real-device-evidence-preflight.sh`. The run kit sets
`QIXI_AUTOMATION_SELECT_ENGINE=b6` by default so a real nativeInProcess analysis
can be selected without a manual model-selection tap; change it to `b18nbt` or
`b28nbt` when validating those models. First run the app without
`QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH` so the native analysis cache,
autosave, and tombstone export exist. After collecting the real screenshot and
performance artifacts, generate or refresh the run-kit `runId` / `recordedAt`
seed, then run
`scripts/qixi-real-device-run-kit-preflight.sh /tmp/qixi-real-device-run`; it
rejects inherited backend URLs, unfilled placeholders, template performance
JSON, missing or weak screenshot/performance artifacts, and pre-existing
app-written final evidence/export-audit/device-log files before the
finalization launch. The app-side
automation export also rejects `QIXI_BACKEND_URL` and `QIXI_DEVICE_BACKEND_URL` for
`nativeInProcess` before validating custom evidence output paths, constructing
evidence, or fingerprinting artifacts.

## Native KataGo iOS Build Gate

For changes touching native KataGo, Metal/CoreML integration, iOS model
packaging, or KataGo C++ sources, run:

```sh
QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh
```

The gate builds `katago_core` for both the iOS Simulator and `iphoneos` arm64
and validates the resulting static libraries with Apple toolchain metadata. It
does not prove the app target is linked to that library; release readiness still
requires `scripts/qixi-native-linked-build-preflight.sh` and real-device
`nativeInProcess` evidence.

For a runnable pre-device `NativeRelease` smoke on the iPad simulator:

```sh
QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh
```

This builds the simulator `katago_core`, validates the fresh `libkatago_core.a`
and matching `libKataGoSwift.a` sidecar with `lipo`/`otool` for arm64 iOS
Simulator Mach-O platform output, links `NativeRelease` against those artifacts,
validates the app executable with the same iOS Simulator architecture/platform
checks, launches without backend environment variables, and checks a screenshot
for nonblank landscape content.

## iCloud Sync Notes

The native app target includes the iCloud Documents entitlement in
`Qixi/Qixi.entitlements` for container `iCloud.com.qixi.localanalysis`. At
runtime the app mirrors the autosave snapshot to the iCloud ubiquity container
when available and falls back to `Application Support/Qixi/SyncFallback` when
iCloud is unavailable, such as in many simulator or unsigned local builds.
Remote sync writes both `autosave.qixi-state.json` and
`autosave.qixi-state.backup.json`, matching the local autosave main/backup
shape. Remote restore reads both copies and chooses the newest valid snapshot,
so a missing or unreadable primary sync file can recover from the remote backup.
If both remote copies are incompatible, unreadable, or timestamp-conflicting,
the error is still surfaced and local data is not allowed to silently overwrite
the damaged remote state.
If a remote sync snapshot exists but cannot be decoded by the current app
schema, reconciliation fails without overwriting it. This protects state written
by a newer app build or a partially unreadable remote file from being silently
replaced by older local data.
If local and remote snapshots have the same timestamp but different content,
reconciliation also fails without overwriting either side; identical snapshots
with the same timestamp are treated as already synced.
Launch restore uses the same strict remote-read rules. If the remote snapshot is
incompatible, unreadable, or timestamp-conflicting, the app falls back to the
local snapshot and records the sync error instead of silently treating the remote
as absent.
Launch restore only considers that remote sync snapshot when the user has
enabled iCloud sync. If the first-launch iCloud setup is skipped or sync is
disabled, startup restore uses only the local autosave snapshot, so stale,
newer, conflicting, or unreadable sync files cannot override the device-local
state.
Manual sync preserves the persisted local snapshot timestamp when the in-memory
restorable state has not changed. This prevents a tap on "Sync Now" from
refreshing old local state to the current time and accidentally overwriting a
newer remote snapshot from another device.
First-launch iCloud enablement uses that same manual-sync handshake. The app
marks onboarding complete locally, but it does not persist the iCloud-sync flag
as enabled until reconciliation succeeds, so a default first-launch position
cannot be promoted over an existing remote archive merely because the user
enabled sync.
Autosave mirroring also treats sync as bidirectional. If reconciliation finds a
newer remote snapshot, the view model applies it to the live UI only when the
current restorable state still matches the queued autosave snapshot; stale
mirror tasks are ignored instead of overwriting newer local interaction.
When a restored or synced snapshot has no selected engine, or when the current
position has no valid cached analysis, the visible candidate moves and territory
overlay are cleared before the local chart anchor is refreshed. This prevents
stale analysis overlays from surviving branch edits, SGF imports, or remote
snapshot restores.
Snapshot application is guarded as a batch update: property observers for komi,
root-noise, and territory visibility do not enqueue autosaves or analysis
refreshes while the imported state is only partially applied. Pending save and
analysis-refresh tasks are cancelled before the restored state is installed.
After a remote snapshot is imported through manual sync or autosave mirroring,
the app resumes analysis for the imported selected engine directly through the
analysis runner. It does not route that recovery through the user-facing engine
switch path, so the imported snapshot is not immediately re-saved with a fresh
timestamp before analysis restarts.
Wide-root-noise is intentionally non-persistent. It is not encoded in
`QixiAppSnapshot`, and applying a restored or imported snapshot resets the live
root-noise control to its default before analysis resumes.
