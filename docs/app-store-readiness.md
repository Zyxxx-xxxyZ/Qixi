# App Store Readiness

This checklist tracks the submission-facing pieces that must stay explicit while
Qixi moves from simulator and Mac-hosted backend validation toward a production
iPad/iPhone app.

Apple's privacy manifest documentation requires a bundled `PrivacyInfo.xcprivacy`
file to describe data collection and required reason API usage:

- https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk
- https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest

## Static Preflight

Run:

```sh
scripts/qixi-appstore-preflight.sh
```

The default quality gate also runs this script. It verifies:

- `PrivacyInfo.xcprivacy` exists and is copied into the app resources
- `NSPrivacyTracking` is false and no tracking domains are declared
- current `UserDefaults` usage is declared with
  `NSPrivacyAccessedAPICategoryUserDefaults` and reason `CA92.1`
- camera, photo library, and local network usage descriptions are present
- App Transport Security allows local networking but not arbitrary loads
- `ITSAppUsesNonExemptEncryption=false` is present for the current app, which
  uses SHA-256 only for model/package integrity and does not include custom
  non-exempt encryption
- iCloud Documents entitlements are present
- iPhone/iPad device family, landscape orientation, and ProMotion keys are set

The script treats local project metadata as an input boundary. It rejects
symbolic-link path components and reads the Xcode project, `Info.plist`,
entitlements, `PrivacyInfo.xcprivacy`, native engine source, and Swift source
files only through bounded local file-size guards before decode or text scans,
then rechecks opened descriptors with `fstat`.
Its temporary root override is available only under an explicit test-mode
environment variable, so production preflights always inspect the checked-out
project.

The default invocation is a development preflight. It intentionally expects the
current Mac-hosted HTTP bridge defaults to remain explicit, and it also verifies
that the development placeholder native engine reports `libraryNotLinked`
instead of silently falling back when `QIXI_ENABLE_NATIVE_KATAGO=0`.

For a submission-facing archive, run the strict mode:

```sh
QIXI_APPSTORE_SUBMISSION=1 scripts/qixi-appstore-preflight.sh
```

Strict mode reads the native release plist when it exists, so
`Qixi/NativeReleaseInfo.plist` must default to `nativeInProcess` and must not
ship `QixiBackendBaseURL`. It also verifies that `NativeRelease` defines
`QIXI_ENABLE_NATIVE_KATAGO=1`, sets the Swift condition
`QIXI_NATIVE_RELEASE` through both `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and
`OTHER_SWIFT_FLAGS = -D QIXI_NATIVE_RELEASE`, excludes the development HTTP
bridge Swift source files from that configuration, that the linked adapter is present, and that the
development placeholder native engine plus its `libraryNotLinked` diagnostic
are excluded behind `#if !QIXI_ENABLE_NATIVE_KATAGO`. This prevents an App Store
checklist from passing while the production build would still compile a
placeholder adapter, without rejecting a guarded Debug-only diagnostic path.
When diagnosing a candidate archive, set
`QIXI_NATIVE_LINKED_PREFLIGHT_REPORT=/path/to/native-linked-report.json` for the
linked-build preflight. The JSON report records the schema version, timestamp,
inputs, status, and exact blockers, rejects symbolic-link report paths, and is
written through an exclusive flushed temporary file plus atomic replace, so
release notes can distinguish "not linked yet" from weaker simulator or
Mac-hosted evidence without trusting a redirected report file.

Before calling a build submission-ready, also run:

```sh
scripts/qixi-native-linked-build-preflight.sh
scripts/qixi-ios-katago-cmake-preflight.sh
QIXI_IOS_SDK=iphoneos QIXI_IOS_KATAGO_BUILD_TARGET=katago_core scripts/qixi-ios-katago-cmake-preflight.sh
QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess \
QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json \
QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive \
QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW=1 \
scripts/qixi-release-evidence-gate.sh
```

Do not set development skip switches such as `QIXI_SKIP_XCODEBUILD` for this
gate. Submission evidence must include the native Xcode build performed inside
`scripts/qixi-quality-gate.sh`; static preflights alone are not enough. The
release gate fails before Xcode discovery if `QIXI_APPSTORE_ARCHIVE_PATH` is
omitted, so a missing archive cannot be hidden behind local toolchain failures.
The release gate also fails early if `xcodebuild` is not in `PATH`, because a
release run must never inherit the default quality gate's development-friendly
Xcode skip. It also fails if `xcodebuild` does not resolve to `/usr/bin/xcodebuild`,
so a shadowed `xcodebuild` in `PATH` cannot fake release evidence, and requires
`xcodebuild -showsdks` to report an `iphoneos` SDK before release validation
continues. The
release gate also forces `QIXI_REQUIRE_TRACKED_FILE_AUDIT=1` for repository
hygiene, so generated artifacts and local model packages cannot evade the
tracked-file audit by running outside a git worktree. It also forces
`QIXI_RUN_IOS_KATAGO_CMAKE=1`, `QIXI_RUN_NATIVE_RELEASE_SIM=1`,
`QIXI_RUN_SCREENSHOTS=1`, and `QIXI_RUN_REAL_MODELS=1` for the final
quality-gate pass, so release evidence cannot omit the Simulator+device iOS
KataGo CMake path, runnable linked NativeRelease Simulator smoke, full
screenshot matrix, or real-model integrations. The hygiene preflight also
rejects Finder `.DS_Store`, Python bytecode caches, coverage outputs,
`node_modules`, and Python/JS tool-cache logs in non-ignored source paths before
the tracked-file audit, so local Finder/tooling noise cannot become release
evidence by accident.
The release gate also requires `QIXI_APPSTORE_ARCHIVE_PATH` to point at an
existing `.xcarchive`. `scripts/qixi-appstore-archive-preflight.sh` parses the
archive `Info.plist`, verifies `ArchiveVersion`, plist `CreationDate`,
`SchemeName = Qixi`, non-empty `ApplicationProperties.SigningIdentity`,
`ApplicationProperties.Team`, and app-matching version fields, verifies
`Products/Applications/Qixi.app`, rejects symbolic links in archive input paths,
bounds archive plist reads and the app executable read before loading, rechecks
every opened archive plist and app executable descriptor with `fstat` as a
regular file before reading, requires
`ApplicationProperties.ApplicationPath` to stay inside `Products`, checks the
archived app bundle identifier/orientation/runtime, verifies an iPhoneOS app executable with an arm64 iOS device `MH_EXECUTE` Mach-O slice, scans the executable for forbidden development bridge or placeholder strings, rejects archived `QixiBackendBaseURL`, requires the archived app code signature to pass `codesign --verify --deep --strict`, rejects ad-hoc release signatures unless `codesign` reports an `Apple Distribution` or `iPhone Distribution` identity, verifies the archived `Info.plist` contains camera/photo/local-network usage descriptions, safe ATS local-network policy, export-compliance metadata, ProMotion support, version strings, exact `CFBundleSupportedPlatforms = [iPhoneOS]`, exact `UIDeviceFamily = [1,2]`, and `MinimumOSVersion >= 17.0`, verifies the signed entitlements include the Qixi iCloud containers, `CloudDocuments`, team identifier, bundle-suffixed `application-identifier`, and disabled `get-task-allow`, and
verifies the bundled `PrivacyInfo.xcprivacy` includes required-reason API coverage for UserDefaults reason `CA92.1` while declaring no tracking domains or collected data.
The archive/evidence identity match rejects stale or non-Qixi evidence before
identity comparison by requiring the current real-device evidence schema and kind,
specifically the current `qixi-real-device-evidence` schema/kind.

That stricter release preflight verifies the Qixi Xcode target defines
`QIXI_ENABLE_NATIVE_KATAGO=1`, defines `QIXI_NATIVE_RELEASE` for Swift,
excludes the development HTTP bridge Swift source files, exposes KataGo headers,
links a real iOS KataGo library or XCFramework,
links Metal/Accelerate/CoreML/MPS/MPSGraph plus zlib, and
defaults `QixiAnalysisRuntime` to `nativeInProcess` without shipping
`QixiBackendBaseURL`. It also requires
`QIXI_KATAGO_IOS_XCFRAMEWORK=/path/to/KataGo.xcframework` or
`QIXI_KATAGO_IOS_LIBRARY=/path/to/libkatago_core.a` plus
`QIXI_KATAGO_IOS_LIBRARY_DIR=/path/to/cmake-build` to point at existing built
iOS artifacts, including the matching `libKataGoSwift.a` sidecar, so a release
checklist cannot pass merely because the project contains placeholder link
strings. The linked-artifact evidence must choose exactly one of the
XCFramework path or the static-library path, and every configured native
artifact path must be absolute so release review cannot depend on the caller's
current working directory. The XCFramework path is parsed through its
`Info.plist` and must contain an `AvailableLibraries` iOS device `arm64` slice
whose `LibraryIdentifier` and `LibraryPath` resolve to a real library or
framework. The linked preflight bounds source and plist reads and rechecks each
opened descriptor with `fstat` before trusting it. After that linked-artifact pass, `scripts/qixi-native-release-build-preflight.sh`
builds the `Qixi` scheme with `-configuration NativeRelease` for `generic/platform=iOS`,
passes through the selected `QIXI_KATAGO_IOS_XCFRAMEWORK` or
`QIXI_KATAGO_IOS_LIBRARY` settings, rejects shadowed `xcodebuild`, validates the
`NativeRelease-iphoneos/Qixi.app` Info.plist runtime through bounded reads that
recheck the opened descriptor with `fstat`, rejects
`QixiBackendBaseURL`, checks the executable for arm64 iOS device Mach-O output,
reads the executable through the same opened-descriptor guard, and scans out
development bridge or placeholder strings such as `BackendClient`,
`HTTPBridgeAnalysisService`, `Qixi HTTP bridge response`,
`qixi.backendBaseURL`, `QIXI_ANALYSIS_RUNTIME`, and local backend URLs before
release evidence continues.
framework. The linked-build preflight rejects symbolic links in the configured
library/XCFramework paths, bounds source/plist reads before loading, and rejects
XCFramework `LibraryIdentifier` or `LibraryPath` entries that traverse outside
the XCFramework. The referenced binary is then checked with `lipo` and `otool`
so it must contain `arm64` and target the iOS device platform, not macOS or iOS
Simulator. It is also checked with `nm` for KataGo core symbol fragments such as
`AsyncBot`, `BoardHistory`, `NNEvaluator`, and `Search`, so an empty or unrelated
iOS library cannot satisfy the release linked-build proof. The symbol pass also
requires a substantial defined-symbol surface and a minimum density of
KataGo-like C++ symbols after demangling with `c++filt`, so a tiny iOS static
library that merely exports every broad fragment name still fails the release
proof. Raw library paths go through the same Mach-O and symbol checks.
The CMake preflight separately configures KataGo's Metal/CoreML path for iOS
with an explicit Swift target, disables runtime CoreML conversion with
`KATAGO_METAL_ENABLE_COREML_CONVERSION=0`, and verifies the iOS build path does
not require Protobuf/abseil or the `katagocoreml` converter at runtime. Daily
development runs use `CMAKE_OSX_SYSROOT=iphonesimulator` and
`CMAKE_Swift_COMPILER_TARGET=arm64-apple-ios17.0-simulator`; release evidence
uses `QIXI_IOS_SDK=iphoneos`, `CMAKE_OSX_SYSROOT=iphoneos`, and
`CMAKE_Swift_COMPILER_TARGET=arm64-apple-ios17.0`. The preflight only removes
and recreates CMake build directories that are directly under `/private/tmp` or
`/tmp`, start with `qixi-ios-katago-cmake-preflight-`, and contain no symbolic-link
path components. It also validates the produced `libkatago_core.a`, or an explicitly requested `libKataGoSwift.a` or
`katago.app/katago` artifact with `lipo` and `otool`, requiring the configured
architecture and the expected iOS/iOS Simulator Mach-O platform before accepting
the build, with no non-target platform object files mixed into the artifact.

Real-device evidence must be recorded as machine-checkable JSON instead of a
free-form note. `scripts/qixi-real-device-evidence-preflight.sh` requires a
physical iPad/iPhone model, iOS/iPadOS version, app runtime, real model analysis
with MCTS ownership, positive-integer visits and candidate counts, finite
launch/memory/frame-pacing measurements, lifecycle autosave/tombstone restore
results, camera recognition, iCloud sync, model import checks, and exactly one
existing non-empty artifact for each required kind: `screenshot`,
`performance`, and `device-log`. The evidence JSON and every JSON artifact must
be standards-compliant JSON that rejects duplicate object keys and non-standard
`NaN`/`Infinity` constants, so parser-specific last-key-wins or
non-finite-number behavior cannot change release evidence semantics. The native
Swift evidence store applies bounded strict object parsing to the evidence file,
export audit, performance artifact, and device-log artifact before accepting
release proof; file-backed JSON paths read at most `maxBytes + 1` through
`FileHandle` after the byte-count check, reject opened-byte-count drift from the
opened descriptor, and therefore do not become unbounded `Data` allocations or
accept concurrently truncated JSON. The Swift store also rejects symbolic links
in the real-device evidence and export-audit file and directory paths before
loading or writing those files, and writes app-generated evidence, export audit,
and device-log files through the shared exclusive no-follow atomic writer with
post-write `fstat` byte-count verification, `F_FULLFSYNC`/`fsync`, atomic
`rename`, and parent-directory `fsync` after replacement, so an app-side release
evidence export cannot follow a container symlink to a different target or
publish a partial JSON artifact. The Python release preflight mirrors
that posture with bounded JSON reads for the evidence, performance artifact,
and device-log artifact, and it also reads `QixiNativeModelRegistry.swift`
through the same symbolic-link rejection and bounded source-load guard before
deriving the native model release manifest. Both Python bounded readers recheck
the opened descriptor with `fstat` as a regular file before reading, so a
stat/open race cannot swap in a directory or special file after the byte-budget
check. The top-level
`nativeInProcess` memory measurements must not exceed the selected model's
`maximumMemoryMB` from `QixiNativeModelRegistry.swift`, so release evidence for
b6, b18nbt, and b28nbt cannot reuse a generic memory ceiling that is too loose
for the selected engine. The top-level
`recordedAt` timestamp must be recent and must not be in the future beyond the
release clock-skew budget, so stale real-device runs cannot be relabeled as
current release evidence. The top-level `runId` must be a canonical lowercase
UUID, and the performance and device-log artifacts must carry the same `runId`,
so artifacts from different device runs cannot be stitched into one release
bundle. Unknown or duplicated
artifact kinds are rejected so evidence cannot imply extra unchecked artifact
semantics. Artifact paths must be unique portable relative paths beside the
evidence JSON; absolute paths, home-relative paths, backslash separators,
empty segments, `.` segments, and parent-directory traversal are rejected so a release evidence bundle can be
re-validated on another machine. Artifact paths must also not use reserved
release evidence or export-audit filenames, and they must not resolve to the
current evidence JSON path, so saving evidence cannot overwrite an artifact that
was just fingerprinted. Artifact paths must not contain symbolic links;
the evidence JSON path, evidence directory, and their ancestor path components
must not contain symbolic links either, and the Python release preflight rejects
those paths before reading the evidence JSON. Every artifact must be a regular file, so a portable relative artifact
entry cannot secretly point outside the evidence bundle. Each artifact entry must also record the file
byte count and lowercase SHA-256 digest, and the preflight
recomputes both from disk so tampered or swapped artifact files cannot satisfy
release evidence. Swift rechecks each artifact's byte count and SHA-256 after
content validation as well, so app-side release evidence cannot hash one file
and validate another if an artifact changes between the fingerprint and content
reads. For performance and device-log JSON artifacts, Swift parses the same
strictly loaded `Data` whose SHA-256 is compared to the recorded artifact
fingerprint, so JSON content validation is bound to the artifact bytes it
fingerprinted.
Swift and the Python release preflight both apply the artifact kind's bounded
byte budget before computing the artifact SHA-256, so an oversized screenshot,
performance export, or device log cannot make release-evidence validation spend
time fingerprinting an artifact that will be rejected anyway.
Screenshot artifacts must have a PNG signature and landscape dimensions
matching the recorded device class: at least `1000x700` for iPad evidence and
at least `800x350` for iPhone evidence. Swift reads only the fixed PNG header
bytes to discover dimensions, rejects images above the screenshot pixel budget
before bitmap allocation, and only then decodes the image for visual inspection;
the Python release preflight follows the same fixed-header and pixel-budget
order. They must also decode as real PNG images and contain enough
visual variance plus dark board/grid detail, so a blank, flat, or header-only placeholder cannot satisfy release evidence, and oversized screenshots cannot reach bitmap allocation.
Performance artifacts must be JSON objects with
`schemaVersion = 1`, `kind = qixi-real-device-performance`, a trusted measurement source of `instruments`, `xctrace`, or `metricKit`, and nested `measurements.launch`, `measurements.memory`, and
`measurements.framePacing` values, a matching `runId`, and a bounded staged `recordedAt`
that is no newer than the final evidence and no older than the staging window,
so a placeholder or stale Instruments export cannot satisfy release evidence. Device-log artifacts must be JSON objects with
`schemaVersion = 1` and `kind = qixi-real-device-log`; their `runId`, exact `recordedAt`, device, app executable SHA-256,
backend/runtime, analysis, lifecycle, and feature facts must match the evidence
JSON, so a generic text log or a log from another run cannot be reused as
release evidence. The analysis evidence must include `analysis.positionIdentity`
with the current root key plus a same-visible-stones/different-history fixture
whose two position keys remain distinct, including
`sameVisibleHistoryKeysDistinct = true`, and the device-log artifact must match
those fields exactly. This prevents a release claim from hiding a position-key
implementation that collapses history into only the visible board.
nativeInProcess device-log artifacts must also carry matching
`analysis.nativeEngine.engineId`, model digest, and tombstone export/restore
audit fields plus `analysis.nativeEngine.coreMLPackages` package metadata,
including `modelSHA256HexDigest`, CoreML package resource name, variant, file
count, total byte count, and tree digest, `tombstoneExportedAt`, and
`tombstoneRestoredAt`.
Bridge evidence must use the Mac LAN origin, never `localhost`, and
`backend.status.engine` plus `backend.status.engineId` must match
`analysis.engineId` exactly. Bridge evidence must not include
`analysis.nativeEngine`, and it remains only development smoke evidence. The
release gate requires fully native evidence: set
`QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess`, do not set
`QIXI_DEVICE_BACKEND_URL` or `QIXI_BACKEND_URL`, and do not include the
`backend` object in the evidence JSON. Fully native evidence must include
`analysis.nativeEngine` with model digest, CoreML package, tombstone export, and
tombstone restore proof. The native app must stream-verify the selected model's SHA-256 digest at evidence export time, verify every declared CoreML package tree
digest, and write the model resource name, byte count, SHA-256 digest,
CoreML package resource name, variant, file count, total byte count, and tree digest, native tombstone filename, tombstone export timestamp, and tombstone
restore timestamp into the evidence JSON. The preflight rejects native evidence
whose model metadata or CoreML package metadata does not match the engine
manifest, whose tombstone filename does not match the native tombstone store, or
whose tombstone audit timestamps are newer than the evidence record or older
than the release evidence freshness window.
The standalone real-device evidence preflight enforces the same
runtime/transport split when `QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess`
is set.
The release gate also runs
`scripts/qixi_release_evidence_archive_match.py` after archive validation and
before real-device evidence validation. That cross-check requires the evidence
`app.bundleIdentifier`, `app.version`, `app.build`, `app.analysisRuntime`, and
`app.executableSHA256HexDigest`
fields to exactly match the archived app `Info.plist` `CFBundleIdentifier`,
`CFBundleShortVersionString`, `CFBundleVersion`, `QixiAnalysisRuntime`, and
archived executable SHA-256. Both runtime fields must be one of `httpBridge` or
`nativeInProcess`. It
also checks that the archive top-level
`ApplicationProperties.CFBundleIdentifier`,
`ApplicationProperties.CFBundleShortVersionString`, and
`ApplicationProperties.CFBundleVersion` agree with the archived app
`Info.plist`. When `QIXI_REAL_DEVICE_EXPECT_RUNTIME` is set, the same match
step also requires the evidence/archive `QixiAnalysisRuntime` to equal that
expected runtime, so a real iPad run from an older, different, or non-native
build cannot be reused for the archive being reviewed. The match step rejects
symbolic links in release input paths, bounds the evidence JSON and archive
plist reads before parsing, hashes the archived app executable in bounded
chunks, rechecks every opened descriptor with `fstat` as a regular file, fails
if the executable grows beyond the hash byte budget while streaming, and
requires archive `ApplicationPath` and `CFBundleExecutable` to stay
inside the app bundle so a crafted archive cannot bind evidence to an escaped app
bundle.
The native app has a matching `QixiRealDeviceEvidenceStore` that writes
`real-device-evidence.qixi-release.json` under Application Support/Qixi with the
same schema; the persistence smoke test saves that Swift payload and then runs
the Python preflight against the generated file.
`QixiViewModel.exportCurrentRealDeviceEvidence` is the App-side collection
boundary for real-device smoke runs: callers supply externally observed device,
backend, measurement, lifecycle, feature, and artifact facts, while the method
derives the analysis section from the currently cached root analysis and, for
`nativeInProcess`, from the installed model and native tombstone audits.
Before starting a physical-device release run, generate a non-evidence run kit:

```sh
scripts/qixi-real-device-evidence-template.py \
  --output-dir /tmp/qixi-real-device-run
```

The generated directory intentionally contains only `README.md`,
`xcode-run-env-template.txt`, `artifact-requirements.json`, and
`.template.json` files. It must not contain
`real-device-evidence.qixi-release.json`, `real-device-evidence.export.json`,
`real-device-main.png`, `real-device-performance.json`, or
`real-device-log.json` at template-generation time. The performance artifact
must come from real measurements, while the final device-log artifact is written
by the app from the same evidence object it later saves; the
`real-device-log.template.json` file is only a schema reference. The template generator fails immediately if
`QIXI_BACKEND_URL` or `QIXI_DEVICE_BACKEND_URL` is present, so a release run kit
cannot silently inherit development bridge transport settings.
After filling the environment values and staging the real screenshot and
performance artifact, run
`scripts/qixi-real-device-run-kit-preflight.sh /tmp/qixi-real-device-run`. It
rejects unfilled placeholders, template performance JSON, backend transport,
missing or weak screenshot/performance artifacts, and stale app-written final
evidence/export-audit/device-log files before the finalization launch.
The app-side automation export repeats the same boundary: when the selected
analysis runtime is `nativeInProcess`, it rejects `QIXI_BACKEND_URL` and
`QIXI_DEVICE_BACKEND_URL` before validating custom evidence output paths,
constructing evidence, fingerprinting artifacts, or touching native
model/tombstone state.
For automation, a real-device run can set
`QIXI_AUTOMATION_SELECT_ENGINE=b6`, `b18nbt`, or `b28nbt` plus
`QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH=1` for the finalization launch;
first run without that export flag so nativeInProcess analysis, autosave, and
tombstone export are cached. After the measured screenshot and performance
artifacts are staged, the finalization launch restores the cached analysis and
tombstone audit, then writes evidence to
`QIXI_REAL_DEVICE_EVIDENCE_OUTPUT` or to the default Application Support/Qixi
evidence path. The final evidence `recordedAt` is taken no earlier than the
actual finalization export, while staged performance artifacts may be earlier
within the bounded staging window; generate or refresh the run-kit `runId` /
`recordedAt` seed after measurement collection and before finalization preflight.
The run must also set
`QIXI_REAL_DEVICE_RUN_ID`,
`QIXI_REAL_DEVICE_RECORDED_AT` plus the measured launch, memory, frame-pacing,
background, feature, and artifact
environment values such as `QIXI_REAL_DEVICE_COLD_LAUNCH_MS`,
`QIXI_REAL_DEVICE_PEAK_RSS_MB`, `QIXI_REAL_DEVICE_OBSERVED_REFRESH_HZ`,
`QIXI_REAL_DEVICE_SCREENSHOT_ARTIFACT`,
`QIXI_REAL_DEVICE_PERFORMANCE_ARTIFACT`, and
`QIXI_REAL_DEVICE_DEVICE_LOG_ARTIFACT`; missing values make the export fail
instead of silently fabricating evidence. The app fingerprints the screenshot
and performance artifacts first, auto-writes the device-log artifact from the
same analysis/device/app/lifecycle/feature facts, fingerprints that generated
file, and only then saves the final evidence JSON.
When `QIXI_REAL_DEVICE_EVIDENCE_OUTPUT` is set, relative paths must be portable
POSIX paths without empty, `.`, `..`, `~`, or backslash components; absolute
paths must still name a regular `.json` file. The app rejects directory outputs,
non-JSON outputs, symbolic-link output paths, and the export-audit filename
before writing evidence, so evidence export cannot overwrite its own audit.
The full simulator screenshot/persistence gate also exercises this export path
as a negative smoke: it seeds placeholder artifact files and requests evidence
export, but the app must reject the Simulator device and write
`real-device-evidence.export.json` with `status = failed` instead of producing a
release-valid evidence file.

## Current Privacy Position

The current native app does not include analytics, ads, third-party tracking, or
tracking domains. Board photos and SGF files are selected by the user and
processed by the app with bounded local file-size guards before decode/import.
App state may be mirrored to the user's iCloud container when iCloud sync is
enabled.

If a future pull request adds analytics, crash reporting, remote sync, account
identity, third-party SDKs, custom cryptography, non-exempt encryption, or any
new data flow, it must update:

- `qixi-ios-native/Qixi/PrivacyInfo.xcprivacy`
- `qixi-ios-native/Qixi/Info.plist` export-compliance metadata when encryption
  behavior changes
- App Store privacy label notes
- `scripts/qixi-appstore-preflight.sh`
- `docs/pr-verification-matrix.md`
- focused tests proving the new declaration is present

## Submission Blockers Still Open

- The production app still needs fully in-process KataGo execution on a physical iPad: the
  real iOS KataGo library must be linked behind the existing `nativeInProcess`
  analysis-service entrypoint instead of the Mac-hosted backend bridge.
  `scripts/qixi-native-linked-build-preflight.sh` must validate the submitted
  library or XCFramework as an iOS device arm64 artifact and reject dummy
  libraries that only spoof broad symbol names. The artifact must expose the
  concrete KataGo **NN** adapter boundary used by Qixi (e.g.
  `initializeNNEvaluator`, `loadSingleParams`, `NNEvaluator`, `BoardHistory`).
  Product search is `core::MCTSStore` only—not KataGo `Search` /
  `runWholeSearch` / Search persistent-MCTS tombstones.
- The production model package flow must generate, import, digest-check, and
  retain preconverted `.mlpackage` or `.mlmodelc` files for every supported
  KataGo model and board/batch/precision variant used by ANE/CoreML mux
  threads. The Swift manifest must represent those files with
  `NativeKataGoCoreMLPackageSpec`; import must pass through
  `QixiNativeCoreMLPackageIntegrity`, `recognizedCoreMLPackageMatch`, and
  `QixiNativeCoreMLPackageInstallReceiptStore`, so same-size package mutation,
  missing companion packages, and stale installer-owned CoreML package artifacts
  cannot survive startup resolution. Raw model install receipts must store byte
  count, mtime, device id, and file id from `fstat`, so same-size raw
  model replacement with a restored mtime cannot survive startup resolution
  without requiring a full-model SHA-256 hash on every launch. The receipt readers use bounded `FileHandle` reads capped at `maxReceiptBytes + 1`, reject symbolic-link and non-regular receipt files before opening, and recheck the opened descriptor with `fstat`, so malformed,
  directory-shaped, special-file, or concurrently enlarged receipt files cannot
  become trusted startup metadata or unbounded startup allocations. Receipt writers use the same shared exclusive no-follow atomic writer as app state and evidence JSON, with post-write `fstat` byte-count verification, `F_FULLFSYNC`/`fsync`, atomic `rename`, and parent-directory `fsync` after replacement, so native model trust metadata is not published partially. Integrity validation rejects CoreML package source path components that traverse symbolic links and rejects CoreML packages whose recursive file count or total byte count exceeds the manifest before tree-digest hashing, which prevents malformed package imports from forcing unbounded file-list growth. Raw model imports, raw model source path components, model install directories, and receipt paths reject symbolic links before staging, reading, or writing native model trust metadata. Raw model byte-count and SHA-256 paths also verify the opened descriptor with `fstat`; the SHA-256 path rejects opened-byte-count drift after streaming before trusting model bytes.
  CoreML package hashing also rechecks each opened package file descriptor with `fstat` and rejects opened-byte-count drift before the bytes enter the tree digest.
  Repository hygiene intentionally keeps these raw model, ONNX, and CoreML
  package artifacts out of source directories and tracked files; release
  candidates must install or supply them through the documented native model
  package flow instead of committing local conversion outputs.
- iCloud behavior must be smoke-tested on real signed devices and the production
  iCloud container must be confirmed.
- Camera/photo board recognition needs real-device photo tests beyond synthetic
  image smoke coverage.
- Memory, launch time, background restore, and long-running analysis behavior
  need real-device evidence.
- App Store privacy labels must be finalized from an archived build privacy
  report before submission.
