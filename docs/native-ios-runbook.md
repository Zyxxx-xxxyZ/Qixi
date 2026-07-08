# Native iOS Runbook

This runbook explains how to run Qixi as a native SwiftUI app on the iOS
Simulator and on a physical iPad or iPhone. It also states what each path proves.

## Prerequisites

- Xcode with iOS Simulator support
- Python 3 for the local backend bridge
- The local KataGo Metal mux binary and models when real analysis is required
- A physical device and signing team for real iPad/iPhone smoke tests

## Choose The Right Run Path

| Path | Use it for | Does not prove |
| --- | --- | --- |
| `scripts/qixi-quality-gate.sh` | deterministic local contracts, parsers, persistence, native bridge shape, App Store static checks, simulator build | screenshots, real KataGo models, real device behavior |
| `QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh` | independent iPad/iPhone Simulator screenshot inspection, localization, launch autosave, utility sheets | real iPad GPU/ANE performance, real camera, real iCloud, OS background kill behavior |
| `QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh` | iOS Simulator and iPhoneOS `katago_core` static-library buildability through CMake/Metal/Swift targets | app target linkage, nativeInProcess runtime behavior, real iPad performance |
| `QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh` | Mac-hosted b6/b18nbt/b28nbt KataGo Metal mux integration | in-process iPad KataGo execution |
| Xcode run on device with `QIXI_BACKEND_URL=http://<mac-lan-ip>:8765` | physical iPad/iPhone SwiftUI app, touch, permissions, local-network bridge | App-Store-ready fully on-device KataGo; use `NativeRelease` with explicit iOS KataGo artifacts for that |

## Build The Native App For Simulator

```sh
cd /Users/zyx/Desktop/projects/Qixi
xcodebuild \
  -project qixi-ios-native/Qixi.xcodeproj \
  -scheme Qixi \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  -derivedDataPath /private/tmp/qixi-derived-sim \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Run The Native App Interactively On Mac

For a one-command interactive iPad Simulator run:

```sh
cd /Users/zyx/Desktop/projects/Qixi
qixi-ios-native/scripts/run-native-sim.sh
```

`run-native-sim.sh` selects `QIXI_SIM_DEVICE` or an available iPad simulator,
boots it, builds the `Qixi` scheme, installs `Qixi.app`, and launches
`com.qixi.localanalysis` with:

```text
QIXI_ANALYSIS_RUNTIME=httpBridge
QIXI_BACKEND_URL=http://127.0.0.1:8765
QIXI_SKIP_ONBOARDING=1
```

It preserves the simulator app container by default so autosave and launch
restore can be inspected. Use `QIXI_SIM_RESET_APP=1` for a clean install,
`QIXI_APP_LANGUAGE=zh-Hans`, `zh-Hant`, or `en` for locale-specific inspection,
`QIXI_BACKEND_URL=http://127.0.0.1:8765` to override the backend endpoint, and
`QIXI_SIM_RUN_CONSOLE=1` to attach app stdout/stderr. The script performs a
bounded `/api/status` health check and warns if the backend is offline, but it
still launches the UI so layout can be inspected without a running engine.
For build evidence, the script requires `xcodebuild` to resolve to
`/usr/bin/xcodebuild`; a shadowed tool earlier in `PATH` is rejected. It also
writes a per-run build marker through an exclusive no-follow temporary file,
byte-count verification, fsync, atomic replace, and parent-directory fsync
before invoking Xcode, then refuses to install the simulator app unless
`Qixi.app/Qixi` is a fresh, non-symbolic-link executable newer than that marker.

## Run Screenshot QA On Mac

First verify and boot the screenshot environment:

```sh
cd /Users/zyx/Desktop/projects/Qixi
qixi-ios-native/scripts/screenshot-environment-doctor.sh
```

Like the screenshot capture scripts, the doctor requires `xcodebuild` to resolve
to `/usr/bin/xcodebuild`, so screenshot evidence cannot be produced with a
shadowed build tool.

```text
qixi-ios-native/artifacts/screenshots/screenshot-environment.json
```

The doctor checks Xcode, the iOS Simulator SDK, Python/Pillow screenshot
dependencies, the native screenshot scripts, and the selected iPad/iPhone
simulators. It writes the machine-readable environment artifact above through a
same-directory temporary file opened with exclusive no-follow flags, verifies
the written byte count, fsyncs the file and parent directory, and atomically
replaces the final JSON after rejecting unsafe symbolic-link path components.

`qixi-ios-native/tests/inspect_screenshot_environment.py` verifies this artifact
in the quality gate, including strict JSON, fresh mtime, UTC `generatedAt`
freshness/future-skew checks, symbolic-link path-component rejection, selected
simulator UDIDs, documented entrypoint commands, and the simulator-vs-device
limitation caveats. If
`QIXI_SCREENSHOT_DOCTOR_ARTIFACT` is set, the same path is passed to the
inspector so the generated and verified evidence stays bound together.

Then run the targeted screenshot captures:

```sh
cd /Users/zyx/Desktop/projects/Qixi
qixi-ios-native/scripts/screenshot-sim.sh
qixi-ios-native/scripts/screenshot-iphone-sim.sh
```

To point the simulator app at a running backend during screenshot inspection:

```sh
QIXI_BACKEND_URL=http://127.0.0.1:8765 qixi-ios-native/scripts/screenshot-sim.sh
```

Screenshot capture uses the same freshness guard as the interactive run: the
app bundle path is checked for symbolic-link components, `Qixi.app/Info.plist`
must exist, and `Qixi.app/Qixi` must be a non-empty executable newer than the
current screenshot build marker before the app is installed or captured. That
marker is written with the same protected no-follow atomic marker writer. The
capture script also rejects symbolic-link components in screenshot and metrics
output paths before writing, captures raw PNGs into same-directory temporary
files, atomically replaces the raw and cropped PNG artifacts, and writes the
per-launch metrics JSON through an exclusive no-follow temporary file with
fsync plus parent-directory fsync.

For the full screenshot and persistence matrix:

```sh
QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh
```

This proves layout, localization, screenshot smoke checks, app launch, and
simulator persistence. It does not prove iPad GPU/ANE performance, camera
behavior, iCloud behavior, background survival, or memory pressure.
After every manifest screenshot passes its inspector, the full gate also writes
paginated review-board images, an HTML index, and a JSON index under:

```text
qixi-ios-native/artifacts/screenshots/review-board
```

Open `latest-screenshot-review-board.html` for a quick human visual pass across
all required states. The gate also runs
`qixi-ios-native/tests/inspect_screenshot_review_board.py` after generation, so
the review board itself must have a valid JSON index, valid HTML page links,
nonblank page PNGs, manifest-matching state counts, and fresh artifact mtimes
for the current run. It also re-expands the screenshot manifest and compares
each review-board state id, dimensions object, and screenshot path in order,
then verifies SHA-256 digests for the screenshot manifest, source screenshots,
and page images.

The screenshot gate also runs a simulator launch/memory smoke and writes:

```text
qixi-ios-native/artifacts/performance/latest-sim-performance.json
```

That artifact records simulator launch-command time, screenshot-verified visual
readiness time, and host RSS for the simulator app process. It is a regression
tripwire for obvious simulator slowdowns. The final performance JSON is also
written through an exclusive no-follow temporary file and atomic replace after
the output path is checked for symbolic-link components. It is not a substitute
for real-device Instruments evidence.

## Run The Mac-Hosted Backend

Build KataGo with the Metal backend if the local binary is not present:

```sh
cd /Users/zyx/Desktop/projects/Qixi/KataGo
/opt/homebrew/bin/cmake -G Ninja -S cpp -B cpp/build-metal-mux -DUSE_BACKEND=METAL -DCMAKE_BUILD_TYPE=Release -DNO_GIT_REVISION=1
/opt/homebrew/bin/cmake --build cpp/build-metal-mux --target katago -j 6
```

Start the development backend:

```sh
cd /Users/zyx/Desktop/projects/Qixi
export QIXI_KATAGO_BIN=/Users/zyx/Desktop/projects/Qixi/KataGo/cpp/build-metal-mux/katago
export QIXI_KATAGO_CONFIG=/Users/zyx/Desktop/projects/Qixi/KataGo/cpp/configs/analysis_example.cfg
export QIXI_KATAGO_OVERRIDE="$(cat /Users/zyx/Desktop/projects/Qixi/qixi-ios-sim/configs/metal-mux.override)"
python3 qixi-ios-sim/backend/qixi_backend.py --host 0.0.0.0 --port 8765
```

The backend defaults to these local model files when the corresponding engine is
selected:

- b6: `KataGo/cpp/tests/models/g170-b6c96-s175395328-d26788732.bin.gz`
- b18nbt: `b18nbt.bin`
- b28nbt: `b28nbt.bin`

## Install Native Model Packages In The App Sandbox

The iOS app can install native model packages from Files through the `导入 /
Import` sheet. Use this path for b6, b18nbt, and b28nbt model files, plus any
required preconverted `.mlpackage` or `.mlmodelc` CoreML companion packages, on
a physical iPad or iPhone once the native runtime is being tested.

The import path does not trust filenames alone. It asks
`QixiNativeModelInstaller` to match the selected `.bin`, `.bin.gz`,
`.mlpackage`, or `.mlmodelc` file against the Swift manifest by byte count and
SHA-256 digest, or by recursive CoreML package file count, total byte count, and
tree digest. It stages the copy in `Application Support/Qixi/Models`, writes a
model or CoreML package install receipt, and excludes the managed artifacts from
iCloud backup. Manually dropped files in the managed directory are intentionally
rejected unless they have the matching receipt, including the installed file
metadata fingerprint or package tree digest. The raw model receipt records byte
count, mtime, device id, and file id from `fstat`, so same-size model
replacement with a restored mtime still fails startup resolution without
rehashing the whole model on every launch. The installer also rejects symbolic-link raw
model sources, symbolic-link managed model/CoreML package directories, and
symbolic-link receipt files or receipt write paths before treating an import as
trusted.

Health-check the backend from the Mac:

```sh
curl http://127.0.0.1:8765/api/status
```

Health-check it from a physical iPad or iPhone by opening this URL in Safari:

```text
http://<mac-lan-ip>:8765/api/status
```

Before recording that a physical-device bridge smoke passed, run the device
signing doctor and preflight from the Mac:

```sh
scripts/qixi-device-signing-doctor.sh
QIXI_DEVICE_STRICT=1 \
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_ID=<devicectl-identifier-if-needed> \
QIXI_DEVICE_DEVELOPMENT_TEAM=<team-id-if-not-set-in-project> \
scripts/qixi-device-run-preflight.sh
```

The physical-device backend URL must not use localhost or loopback. The script
rejects `127.0.0.1`, `::1`, `localhost`, and `0.0.0.0`, then checks
`/api/status` with a bounded `application/json` response, strict JSON parsing,
and typed status fields so review evidence cannot accidentally describe a
simulator-only or Mac-only path as an iPad/iPhone run. Before checking the
network path, strict mode also uses `devicectl` to require a physical
iPad/iPhone whose device-details output proves Developer Mode enabled,
Developer Disk Image services available, active CoreDevice transport, and
install/launch capabilities. This matters because recent CoreDevice builds can
show a usable network-paired iPad as `available (paired)` in
`devicectl list devices` while `devicectl device info details` proves the
tunnel and DDI services are live. Automatic device selection only considers
detail-probeable list states such as `connected`, `connected (no DDI)`, and
`available (paired)`, then lets the details check reject devices without DDI,
Developer Mode, active transport, or install/launch capability. `connecting`
and `unavailable` devices are never selected. When no usable device is selected,
the preflight error and signing doctor report the visible `devicectl` devices
with their state, identifier, and model so a disconnected iPad is not confused
with a signing failure. Setting `QIXI_DEVICE_ID` only resolves ambiguity between
devices; the selected identifier must still be visible in `devicectl list
devices` and probeable by `devicectl device info details`. It also resolves
the app `PRODUCT_BUNDLE_IDENTIFIER` and requires an
installed iOS App Development provisioning profile whose team, bundle id,
physical-device UDID, and expiration date match the run. If you want Xcode to
create or refresh that profile automatically, first add a valid Xcode account
for the selected team, then set `QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES=1`; the
bridge smoke will pass `-allowProvisioningUpdates` and
`-allowProvisioningDeviceRegistration` to `xcodebuild`. When automatic
provisioning is enabled, strict preflight and the signing doctor also run a
real `xcodebuild build` signing probe in temporary DerivedData and reject
invalid Xcode credentials or profile creation failures such as
`DVTDeveloperAccountManager`, missing `Xcode-Username`, `No Accounts`, or
`No profiles for` diagnostics before the bridge smoke install/launch stages.
The signing doctor is the more verbose diagnostic
entrypoint: it prints the resolved bundle id, team, selected device UDID,
visible `devicectl` device states, visible-device transport details such as
`developerModeStatus`, `ddiServicesAvailable`, `tunnelState` or
`transportType`, install/launch capability flags, Apple Development identity
counts, available Apple Development team identifiers, scanned provisioning
profiles, per-profile mismatch reasons, and the Xcode automatic-provisioning
account probe. The JSON output also includes stable `recommendedActions` codes
such as `device.coredevice_transport_not_ready`,
`signing.team_identity_missing`, `signing.profile_missing`, and
`signing.xcode_account_probe_failed` so scripts and release checklists can react
without brittle string matching. Device-related recommended actions are bound to
the selected device identifier/UDID, so an unrelated visible iPad or iPhone
cannot make a ready selected device look blocked; use
`scripts/qixi-device-signing-doctor.sh --json` when a machine-readable report is
needed. It also rejects
symbolic-link local project inputs and reads the app
`Info.plist`, Xcode project, runbook, and quality-gate docs through bounded
file-size guards that recheck the opened descriptors with `fstat`. The native Swift
`BackendClient` mirrors that response-side posture during app execution by
rejecting non-2xx bridge responses, non-`application/json` response bodies,
duplicate JSON keys, `NaN`/`Infinity`, non-object JSON, and response bodies larger than 1 MiB before decoding them into app state.

Once strict preflight passes, run the reproducible physical-device bridge smoke:

```sh
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_DEVELOPMENT_TEAM=<team-id-if-not-set-in-project> \
scripts/qixi-device-bridge-smoke.sh
```

If the repository's project team is not installed on the Mac, keep the default
project settings intact and use an explicit local bundle id for bridge/UI
debugging on the physical device:

```sh
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_DEVELOPMENT_TEAM=<available-team-id> \
QIXI_DEVICE_BUNDLE_ID=com.example.qixi.local-device \
QIXI_DEVICE_DISABLE_ICLOUD_ENTITLEMENTS=1 \
scripts/qixi-device-bridge-smoke.sh
```

The signing doctor, strict preflight, and bridge smoke build all resolve
`QIXI_DEVICE_BUNDLE_ID`, validate it as a concrete reverse-DNS bundle
identifier, and pass it to `xcodebuild` as `PRODUCT_BUNDLE_IDENTIFIER`. When the
bundle id differs from `com.qixi.localanalysis`, the bridge smoke requires an
explicit iCloud-entitlement choice: use
`QIXI_DEVICE_DISABLE_ICLOUD_ENTITLEMENTS=1` for local UI/bridge debugging, or
only set `QIXI_DEVICE_ALLOW_BUNDLE_OVERRIDE_WITH_ICLOUD=1` after the selected
team owns the existing iCloud entitlements. The disabled-entitlement path must
not be cited as iCloud sync, App Store, or release evidence.

For a no-side-effect command preview, add `QIXI_DEVICE_BRIDGE_PLAN_ONLY=1`.
Plan-only mode still checks the backend URL, selected physical device,
Developer Mode/CoreDevice readiness, and Xcode destination, then writes the
bridge command manifest with `dryRun=true` plus `preflight.signingBlockers`.
It does not build, install, launch, copy app data, create provisioning profiles,
or satisfy `scripts/qixi-device-bridge-smoke-inspect.sh`; validate the diagnostic
manifest with `scripts/qixi-device-bridge-plan-inspect.sh`.
To run the same diagnostic from the full gate, use:

```sh
QIXI_RUN_DEVICE_BRIDGE_PLAN=1 \
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_DEVELOPMENT_TEAM=<available-team-id> \
QIXI_DEVICE_BUNDLE_ID=com.example.qixi.local-device \
QIXI_DEVICE_DISABLE_ICLOUD_ENTITLEMENTS=1 \
scripts/qixi-quality-gate.sh
```

For automatic signing/profile creation, use the same command with:

```sh
QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES=1 \
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_DEVELOPMENT_TEAM=<team-id-if-not-set-in-project> \
scripts/qixi-device-bridge-smoke.sh
```

That smoke builds the Debug `iphoneos` app for the connected device, rejects a
stale or wrong-bundle `Qixi.app`, installs it with `devicectl device install
app`, launches it with `QIXI_ANALYSIS_RUNTIME=httpBridge` and the non-loopback
backend URL through `devicectl device process launch`, records machine-readable
install, launch, process, and display JSON artifacts, and copies
`Library/Application Support/Qixi` from the app data container into
`qixi-ios-native/artifacts/device-bridge`. The manifest includes a per-run
`runId`, UTC `generatedAt` / `startedAt` / `completedAt` timestamps, and
per-stage `timingsMs` for build, install, launch, process listing, display
query, and app-container copy. Set `QIXI_DEVICE_BRIDGE_RUN_ID` to a canonical
32-character lowercase hex value when a surrounding evidence run must bind this
bridge smoke to other artifacts. It still proves the Mac-hosted bridge path,
not fully native `nativeInProcess` KataGo.

Inspect the recorded bridge smoke artifacts before citing them:

```sh
scripts/qixi-device-bridge-plan-inspect.sh
scripts/qixi-device-bridge-smoke-inspect.sh
```

If the run launched the app with `QIXI_DEVICE_AUTOMATION_SELECT_ENGINE` but the
Mac backend did not observe that engine selection, the smoke writes
`latest-device-bridge-failure.json` plus
`latest-device-bridge-failure-backend-events.json`. Validate that failure path
before citing it:

```sh
scripts/qixi-device-bridge-failure-inspect.sh \
  qixi-ios-native/artifacts/device-bridge/latest-device-bridge-failure.json
```

This failure artifact keeps a structured `diagnosticCategory`, such as
`iosLocalNetworkDenied`, plus the copied app-side runtime diagnostic bound to
the backend event log that showed no matching engine request.

The full quality gate can run the live bridge path when a signed physical device
and reachable Mac-hosted backend are available:

```sh
QIXI_RUN_DEVICE_BRIDGE_SMOKE=1 \
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_DEVELOPMENT_TEAM=<team-id-if-not-set-in-project> \
scripts/qixi-quality-gate.sh
```

For real KataGo Metal mux analysis, build KataGo and export the variables shown
in `qixi-ios-sim/README.md`, then run:

```sh
QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh
```

This proves the Mac-hosted backend bridge can route b6, b18nbt, and b28nbt
through the local KataGo Metal mux path. It does not prove that KataGo is running
inside the iOS app process.

For native-engine development changes, also run:

```sh
QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh
```

That builds the `katago_core` static-library target for both the iOS Simulator
and `iphoneos` arm64. It proves the local CMake/Swift/Metal build path for the
future in-process library is still viable, but it does not prove the Qixi app
target is linked to that library or that `nativeInProcess` ran on a physical
iPad.

For NativeRelease startup and linker smoke before using a physical device, run:

```sh
QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh
```

That builds a simulator `katago_core` artifact, validates the fresh
`libkatago_core.a` and matching `libKataGoSwift.a` sidecar with `lipo`/`otool`
for arm64 iOS Simulator Mach-O platform output, links `NativeRelease` against
those artifacts, validates the app executable with the same iOS Simulator
architecture/platform checks, rejects backend/placeholder strings, launches
without backend environment variables, and checks a simulator screenshot for
nonblank landscape content. The full-frame screenshot and cropped content
screenshot are captured through protected same-directory temporary PNGs,
rejected if their output paths contain symbolic-link components, and atomically
replaced before inspection. It is useful because it exercises the same
`QIXI_NATIVE_RELEASE` Swift branch and native adapter linkage in a runnable app
bundle, but it still cannot prove real iPad memory pressure, frame pacing,
camera, iCloud, background restore, or App Store archive identity.

## Prepare Native Release Evidence On A Physical Device

Before a `nativeInProcess` iPad/iPhone release run, create a run-kit template:

```sh
cd /Users/zyx/Desktop/projects/Qixi
scripts/qixi-real-device-evidence-template.py \
  --output-dir /tmp/qixi-real-device-run
```

The template is deliberately not evidence. It writes the expected environment
keys, artifact filenames, and placeholder JSON schemas, but it does not write
`real-device-evidence.qixi-release.json`, `real-device-evidence.export.json`,
the final screenshot, performance, or device-log artifact files, and it refuses
to run if `QIXI_BACKEND_URL` or `QIXI_DEVICE_BACKEND_URL` is set. Fill the measured
launch, memory, frame-pacing, lifecycle, camera, iCloud, model-import,
screenshot, and performance facts from the physical run. The run-kit sets
`QIXI_AUTOMATION_SELECT_ENGINE=b6` by default so the app starts a real
nativeInProcess analysis without a manual tap; change it to `b18nbt` or
`b28nbt` when that model is the evidence target. Run the app once without
`QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH` so analysis, autosave, and
tombstone export complete. Then place the measured screenshot and performance
artifacts in the run-kit staging directory, generating the run kit after those
measurements or refreshing its `runId` / `recordedAt` seed before preflight. Use the filled environment template
for the finalization launch, and let the app write the matching device-log
artifact and final evidence file from the same evidence object. Before that
finalization launch, validate the filled run-kit staging directory:

```sh
scripts/qixi-real-device-run-kit-preflight.sh /tmp/qixi-real-device-run
```

That preflight rejects inherited backend URLs, unfilled `<placeholder>` values,
template performance JSON, missing or weak screenshot/performance artifacts, and
pre-existing app-written final evidence/export-audit/device-log files. After the
app writes the final evidence file, validate it with:

```sh
QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess \
QIXI_REAL_DEVICE_EVIDENCE=/absolute/path/to/real-device-evidence.qixi-release.json \
scripts/qixi-real-device-evidence-preflight.sh
```

For a release/App Store claim, run `scripts/qixi-release-evidence-gate.sh` with
the same evidence file and the matching `.xcarchive`.

## Run On A Physical iPad Or iPhone

1. Open the Xcode project:

   ```sh
   open /Users/zyx/Desktop/projects/Qixi/qixi-ios-native/Qixi.xcodeproj
   ```

2. Select the `Qixi` scheme and the connected iPad or iPhone.

3. Set a signing team in Xcode. If the bundle identifier conflicts, change
   `com.qixi.localanalysis` to a unique identifier owned by the team.

   Before trying to run, check the exact signing state:

   ```sh
   scripts/qixi-device-signing-doctor.sh
   ```

   If it reports no matching profile, add the Xcode account for that team or
   generate/install an iOS App Development profile for the connected device.
   If the device appears in `devicectl list devices` but the doctor reports
   `tunnelState=unavailable` or `ddiServicesAvailable=false`, the device is
   still not usable evidence: unlock it, keep it connected, trust this Mac,
   wait for Xcode/CoreDevice to mount the Developer Disk Image, and rerun the
   doctor until it reports active transport plus install and launch
   capabilities. If the doctor lists Apple Development team identifiers that
   do not include the project team, either add the Apple ID for the project
   team in Xcode or set `QIXI_DEVICE_DEVELOPMENT_TEAM=<available-team-id>` only
   when that team is the intended signing owner. For local bridge/UI debugging
   with that available team, also set a unique `QIXI_DEVICE_BUNDLE_ID` and
   `QIXI_DEVICE_DISABLE_ICLOUD_ENTITLEMENTS=1`; that does not verify iCloud sync.

4. Start the backend on the Mac:

   ```sh
   cd /Users/zyx/Desktop/projects/Qixi
   python3 qixi-ios-sim/backend/qixi_backend.py --host 0.0.0.0 --port 8765
   ```

5. Find the Mac LAN address:

   ```sh
   ipconfig getifaddr en0
   ```

6. In Xcode, open `Product > Scheme > Edit Scheme > Run > Arguments` and add:

   ```text
   QIXI_ANALYSIS_RUNTIME=httpBridge
   QIXI_BACKEND_URL=http://<mac-lan-ip>:8765
   ```

7. Run the app on device.

Do not use `127.0.0.1` for a physical device. On device, `127.0.0.1` points to
the iPad or iPhone itself, not the Mac.

If the app cannot reach the backend:

- Confirm the Mac and the device are on the same network.
- Open `http://<mac-lan-ip>:8765/api/status` in Safari on the device.
- Allow the Python process through the macOS firewall.
- Confirm `NSLocalNetworkUsageDescription` is present in `Qixi/Info.plist`.
- Keep `QIXI_ANALYSIS_RUNTIME=httpBridge` for this bridge smoke path. It is
  separate from the `NativeRelease` path that links explicit iOS KataGo
  artifacts and must not set backend URLs.

If signing fails because of iCloud, use a bundle identifier and iCloud container
owned by the selected development team. For local UI-only debugging, the iCloud
capability can be disabled temporarily, but that does not count as sync
verification.

## Simulation Fidelity And Limits

The iOS Simulator is valuable, but it is not a substitute for device evidence.

Reliable in the simulator:

- SwiftUI layout, landscape constraints, localization, and sheet presentation
- Board geometry and screenshot-level visual regressions
- File persistence, autosave, backup snapshot recovery, and the injected
  lifecycle tombstone path used by the simulator smoke
- HTTP bridge request/response behavior against a Mac-hosted backend

Before autosave, backup, iCloud sync, lifecycle tombstone, or native engine audit
JSON is decoded during restore, Swift runs a strict object parser that rejects
duplicate keys, `NaN`/`Infinity`, non-object JSON, and oversized files. This
prevents parser-specific last-key-wins behavior from changing launch restore or
iCloud reconciliation state. File-backed restore paths check the file byte
count, then read at most `maxBytes + 1` through `FileHandle`, and reject
opened-byte-count drift if the actual read length differs from the opened
descriptor's `fstat` size. A corrupted, concurrently enlarged, or concurrently
truncated autosave, sync snapshot, tombstone, audit, or real-device evidence
artifact is rejected without creating a large `Data` allocation or entering
restore.
Swift also rejects symbolic-link snapshot, tombstone, audit, and sync file and
directory paths before load or write, while permitting the standard Darwin
`/var`, `/tmp`, and `/etc` container aliases. File-backed restore also rejects
non-regular autosave, sync snapshot, tombstone, and audit paths before
`FileHandle` reads, then verifies the opened descriptor is still a regular file
with `fstat`.
App-written autosave, backup, iCloud sync, lifecycle tombstone, native engine
audit, release evidence, device-log, and native model/CoreML receipt files use
the shared Swift atomic writer: a same-directory temporary file opened with
exclusive no-follow flags, full-byte writes, post-write `fstat` byte-count
verification, `F_FULLFSYNC`/`fsync`, atomic `rename`, and parent-directory
`fsync` after replacement.

Needs a physical iPad or iPhone:

- ProMotion feel, frame pacing, Metal/GPU/ANE behavior, thermal throttling, and
  realistic memory pressure
- Camera capture, photo-library permissions, and real-world board photos
  beyond the synthetic recognition smoke, which covers downsampled large photos
  oversized-photo rejection before decode/load, and EXIF-oriented images but
  not real lighting, blur, hands, or lens geometry. The PhotosPicker path imports
  a temporary file through `FileRepresentation`; URL-based photo recognition
  uses ImageIO directly from that file URL without first creating a full
  compressed-image `Data` allocation.
  It rejects symbolic-link and directory photo URLs before ImageIO decode.
  Recognition currently previews visible stones only; it must not be treated as
  a move-history or analysis-root import because same stones with different
  histories are different positions.
- iCloud account availability and multi-device document propagation
- Background suspension, system kill, foreground restore, and long idle periods
- The eventual `QIXI_ANALYSIS_RUNTIME=nativeInProcess` path with KataGo running
  inside the app process

## What Physical-Device Smoke Should Record

For pull requests that touch device-specific behavior, record:

- Device model and iOS version
- Whether analysis used mock mode or real Mac-hosted KataGo
- Launch time observation
- Memory observation for at least one analysis session
- Camera/photo import result when recognition changed
- iCloud sync result when sync changed
- Background/foreground restore result when persistence changed

## Current Limitation

Debug/Release development runs still use the Mac-hosted backend for real KataGo
analysis. The `NativeRelease` configuration can link a real iPhoneOS
`libkatago_core.a` or XCFramework plus the matching `libKataGoSwift.a` sidecar
for the fully in-process iPad KataGo engine, and
`scripts/qixi-native-release-build-preflight.sh` verifies that the app target
builds as `nativeInProcess` without backend or placeholder strings. That is
necessary build evidence, but it is still not a substitute for a signed archive
and physical iPad/iPhone evidence proving `nativeInProcess` analysis, frame
pacing, memory, camera, iCloud, background restore, and model import on real
hardware. Without that signed archive and real-device evidence, the build is
not an App-Store-ready on-device KataGo runtime.
