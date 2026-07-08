# Qixi Quality Gates

This project treats tests as part of the product. A pull request that changes
UI, persistence, backend analysis, model routing, or project infrastructure must
say which gates were run and why any expensive gate was skipped.

Use `docs/pr-verification-matrix.md` to map changed surfaces to required gates.

## Default gate

```sh
scripts/qixi-quality-gate.sh
```

The default gate runs deterministic checks that should be practical for every
normal pull request:

- project quality contract
- changed-surface gate contract for PR screenshot classification
- position identity fixture contract:
  `tests/validate_position_identity_fixture.py` first parses the shared fixture
  as standards-compliant JSON, rejects duplicate object keys and
  `NaN`/`Infinity`, verifies the schema, closed case/relation references,
  legal pass/coordinate shapes, fixed engine-to-backend identity mapping, and
  the required `sameVisibleStones=true` but `equal=false` relations before any
  backend or Swift smoke test consumes the data. Before that JSON parse, it
  performs a bounded UTF-8 fixture read, rejects symbolic-link and non-regular
  fixture paths, and rechecks the opened descriptor with `fstat`, so fixture
  validation cannot be redirected through an untrusted path or unbounded input.
  The validator also replays each fixture history
  on a 19x19 board, rejects occupied-point moves, suicide, and
  immediate simple-ko recapture, and verifies every relation's
  `sameVisibleStones` value matches the replayed final stones and every
  `sameNextPlayer` value matches the replayed next player.
- backend API and position-key contract, including the shared
  `tests/fixtures/position_identity_cases.json` equality-partition fixture used
  by both the Python backend contract and the Swift analysis-service smoke. The
  shared fixture also verifies `sameVisibleStones`, so same-stones/different-history
  cases remain true same-stone cases instead of weak inequality examples. It
  includes a `ko-history-after-passes` relation whose visible stones and next
  player match, so ko-context history cannot collapse into a board-only cache key.
  Position identity builds ordered-history keys with a single reserved String builder without allocating an intermediate per-move string array.
  Analysis setting changes immediately restore a matching cached analysis or
  clear candidates and territory before the debounced engine refresh, so the
  same root under different komi or root-noise settings cannot display stale
  candidate or ownership data.
  Disabled-analysis paths also refresh the local chart anchor, so no-engine
  play or pass cannot leave stale winrate or score anchors after the current
  ply changes.
  Non-none engine selection is saved immediately after `selectedEngine` changes
  and before engine loading or analysis starts, so launch restore preserves the
  user's selected model even when model loading or analysis later fails.
- Mac-hosted backend bridge request guards:
  `qixi-ios-sim/backend/qixi_backend.py` accepts only bounded `application/json` POST bodies, rejects duplicate JSON keys and
  `NaN`/`Infinity`, and requires top-level request objects before analysis,
  engine switching, or control actions run. The same strict JSON object parser
  guards KataGo analysis stdout responses before they are converted into Qixi
  analysis results.
- native Swift HTTP bridge response guards: `BackendClient` rejects non-2xx
  responses, non-`application/json` responses, duplicate JSON keys,
  `NaN`/`Infinity`, non-object JSON, and response bodies larger than 1 MiB
  before decoding them into app state.
- native Swift in-process bridge response guards:
  `NativeKataGoBridgeResponseValidator` rejects duplicate JSON keys,
  `NaN`/`Infinity`, non-object JSON, and response bodies larger than 1 MiB
  before `NativeKataGoAnalysisService` decodes adapter output into app state.
  The duplicate-key scanner reads the response `Data` through `withUnsafeBytes`
  so validating a native adapter response does not allocate a second full byte
  array.
- native persistence and iCloud sync JSON guards:
  `QixiStrictJSONDocumentValidator` rejects duplicate JSON keys,
  `NaN`/`Infinity`, non-object JSON, and oversized autosave, backup, sync,
  lifecycle tombstone, and native engine audit files before they are decoded
  into restored app state. File-backed restore paths check the file byte count,
  then read at most `maxBytes + 1` through `FileHandle`, and reject
  opened-byte-count drift if the actual read length differs from the opened
  descriptor's `fstat` size. A corrupted, concurrently enlarged, or
  concurrently truncated autosave, sync snapshot, tombstone, audit, or
  real-device evidence artifact is therefore rejected without creating a large
  `Data` allocation or entering restore. The validator scans `Data` through
  `withUnsafeBytes` rather than copying the entire document into a second byte
  array, keeping snapshot restore peak memory bounded by the configured
  file-size limits. Shared file-path guards reject symbolic-link snapshot, tombstone, audit, and sync paths, including both file and directory paths, before load or write, while allowing the
  standard Darwin `/var`, `/tmp`, and `/etc` aliases used by app containers. File-backed restore also rejects non-regular autosave, sync snapshot, tombstone, and audit paths before `FileHandle` reads, then verifies the opened descriptor is still a regular file with `fstat`.
  App-written autosave, backup, iCloud sync, lifecycle tombstone, native engine
  audit, real-device evidence, device-log, and native model/CoreML receipt files
  use `QixiTrustedFilePath.writeProtectedDataAtomically`: a same-directory
  temporary file opened with `O_EXCL` and `O_NOFOLLOW`, full-byte `write` loops,
  post-write `fstat` byte-count verification, `F_FULLFSYNC`/`fsync`, atomic
  `rename`, and parent-directory `fsync` after replacement.
  Manual iCloud sync and autosave mirroring only persist the enabled preference
  when reconciliation reports the `.iCloud` provider. If the app falls back to the local
  `SyncFallback` directory because no iCloud container is available, the UI
  must leave iCloud disabled and surface sync attention instead of presenting
  the fallback as successful iCloud sync. Screenshot automation values for
  `QIXI_ICLOUD_SYNC_ENABLED` and `QIXI_SYNC_STATUS` pin sync visual state so
  launch autosave cannot race the screenshot and rewrite the intended sheet.
  Snapshot analysis caches must also keep every cache key in the matching
  `analysisByEngine` engine partition, so a self-consistent b18nbt cache entry
  cannot be imported under b6 or another engine. Cache keys must keep the
  `QixiPositionIdentity` semantic structure with rules, komi bits,
  root-noise bits, and ordered-history entries. The komi and root-noise fields
  must use canonical UInt64 bit-pattern hex without extra leading zeroes and
  without exceeding 16 hex digits, then decode back to finite values inside the
  supported `QixiAnalysisLimits` komi and root-noise ranges. A snapshot may
  preserve multiple valid history and setting identities in the same engine
  cache, including same-stones/different-history and different valid settings.
  Every decoded semantic cache history must pass the same board-legality check
  used for imported main lines, so a prefix-only, overlong, non-finite,
  out-of-range, illegal-history, or otherwise malformed semantic cache key
  cannot be restored or synced.
- native C++ persistent-MCTS tombstone guards: `NativeKataGoCore` rejects
  missing, empty, non-regular, symbolic-link, directory, and over-256-MiB engine
  tombstone files before restore reaches the adapter, clears the loaded engine
  identity, and calls `NativeKataGoEngine::unloadModel` on failed real-engine
  restores so corrupted lifecycle state does not leave b6/b18nbt/b28nbt resident
  under a no-engine state. The linked adapter rejects non-regular internal
  `.persistent-mcts.tmp`, `.persistent-mcts.restore.tmp`, and atomic-write
  `.tmp` paths before writing raw persistent-MCTS payloads, creates atomic-write
  `.tmp` files with exclusive no-follow opens, flushes them with
  `F_FULLFSYNC`/`fsync` before rename, and opens persistent-MCTS tombstones with
  no-follow descriptor checks plus `fstat` before fixed-chunk JSON reads. The
  adapter rejects opened-byte-count drift while reading, verifies temporary-file
  byte counts after writing, rejects symbolic-link or directory-shaped final
  tombstone targets, bounds atomic-write payload size, and preserves the old
  tombstone if `rename` fails.
- web simulator math/color/history contract when Node.js is available
- native SwiftUI contract
- native localization contract for complete Simplified Chinese, Traditional
  Chinese, and English keys plus matching format placeholders
- native board geometry detector contract, including rejection of missing
  grid-line evidence
- native utility-sheet screenshot inspector contract, including synthetic
  positive and negative cases for sync and model-install state icons
- native screenshot manifest artifact-inspector contract for complete artifact,
  missing artifact, failing inspector, and required-count mismatch paths
- native screenshot coverage manifest audit for the 145 declared frontend states
- native SGF parser smoke test, including bounded UTF-8/Latin-1 file loading
  and oversized SGF rejection before file data is loaded. SGF URL import rejects symbolic-link and non-regular SGF URLs before `FileHandle` reads. SGF URL import reads at most `maxInputBytes + 1` through `FileHandle` and never memory-maps the entire selected file. SGF parsing scans `String.UnicodeScalarView` directly without copying the whole text into an array.
- native board legality crosscheck smoke, proving Swift board replay and the C++
  native request parser agree on legal captures, repeated coordinates after
  capture, occupied points, suicide, and immediate simple-ko recapture:
  `qixi-ios-native/tests/run_board_legality_crosscheck.sh`
  Swift `firstIllegalMoveIndex` validates histories in a single pass while
  retaining only the current board and previous board for simple-ko checks, so
  long imported lines and semantic cache histories do not replay every prefix or
  retain all board snapshots during validation.
  `visibleStones`, `isOccupied`, and `isLegalMove` share the same bounded replay
  state instead of retaining all board snapshots for UI or touch-path queries.
  Board neighbor lookup uses one precomputed 361-point adjacency table instead
  of allocating a fresh neighbor array during group, liberty, or capture checks.
  Group and liberty scans use a fixed 361-entry visited table plus array-backed
  group storage rather than hash sets on the board hot path.
- native board recognition smoke test using the shipped board and stone assets,
  including empty-board false-positive, standard, dimmed, dense-stone,
  padded-photo, light-rotation correction, and lightweight perspective
  rectification cases, plus glare false-positive protection, large-photo
  downsampling, oversized-photo rejection before ImageIO decode or file-data loading,
  symbolic-link and non-regular photo URL rejection before ImageIO decode,
  EXIF orientation correction, and a UI/source contract that photo
  recognition previews visible stones without changing ordered history or the
  current analysis root. The UI contract also requires that the recognition
  preview is cleared on every current-position identity change, including
  stepping, jumping, pass/play moves, SGF import, and imported sync snapshots.
  The PhotosPicker path imports a temporary file via
  `FileRepresentation` and uses ImageIO directly from that URL, without creating
  a full compressed-image `Data` allocation. The full screenshot gate also captures the
  `board-recognition-preview` fixture on iPad and iPhone in every supported
  language and verifies the Hermes-blue preview rings on the board.
- native candidate-overlay hot-path contract:
  Candidate overlay refresh keeps the current best winrate and visible candidate list cached, with preformatted candidate labels and color components cached, without allocating per-frame winrate, label-formatting, color-interpolation, or sorted visible-candidate arrays, so 120 Hz
  candidate labels, colors, and deltas do not rescan candidate winrates or
  rebuild the visible move list for every drawn frame.
- native ProMotion lifecycle contract:
  The 120 Hz preference uses a UIUpdateLink passive observer with a 80-120 Hz
  preferred range, explicitly avoids continuous, low-latency, or
  immediate-presentation updates while idle, is released when its host view
  leaves the window, and the board/variation-tree hot canvases do not use an
  always-on 120 Hz `TimelineView` to redraw without new model state.
- native board-rendering hot-path contract:
  Board move prefixes are cached; visible stones and occupied-point indexes are cached so
  stones, territory overlays, recognition previews, and candidate analysis checks reuse the current root move slice
  without allocating `Array(mainLine.prefix(currentPly))` from board rendering.
- native variation tree layout smoke for horizontal spacing, branch lanes,
  touch-target separation, and allowed connector directions
- native analysis service smoke test
  - independently invokes `tests/validate_position_identity_fixture.py` before
    compiling/running the Swift smoke driver, so a standalone
    `qixi-ios-native/tests/run_analysis_service_smoke.sh` cannot consume a weak
    or non-standards-compliant shared position fixture.
  - verifies that native memory-budget refusal happens before `configureModel` or any real-engine load; it must not enter a partially configured native engine state
- native in-process integration contract preflight, proving the planned iOS
  adapter boundary stays on KataGo `Setup`/`AsyncBot`/`Search` APIs and not on
  GTP, subprocesses, HTTP, or the Mac-hosted backend. It reads the audited
  source and contract-document inputs through bounded UTF-8 loads, rejects
  symbolic-link path components, and rechecks opened descriptors with `fstat`.
- native KataGo adapter compile probe, proving Qixi's parsed native request can
  still compile against KataGo `Board`, `BoardHistory`, `AsyncBot`, and
  `Search` APIs for root setup, persistent MCTS root switching, analysis JSON,
  and MCTS ownership extraction
- native model preflight for b6, b18nbt, and b28nbt manifest integrity
  - native model preflight rejects symbolic links in source/model paths, reads
    Swift source and manifest inputs through bounded byte loads, checks model
    files against a bounded maximum before hashing, and hashes them in fixed
    chunks instead of loading a model into memory. Model byte-count and hash
    paths verify the opened descriptor with `fstat` before trusting it, and the
    hash path rejects opened-byte-count drift after streaming. Runtime model
    integrity also rejects symbolic-link raw model path components before byte
    count or hash reads. CoreML package integrity rejects symbolic-link package
    source path components before footprinting or hashing, and tree-digest
    hashing also verifies each opened package descriptor with `fstat` before
    hashing file contents.
  - native model and CoreML package install receipts are read through bounded
    `FileHandle` reads capped at `maxReceiptBytes + 1` before strict JSON
    object validation and `JSONDecoder`; receipt readers reject symbolic links
    and non-regular receipt files before opening, then recheck the opened
    descriptor with `fstat`, while receipt writers use the shared exclusive
    no-follow atomic writer with parent-directory `fsync`, so startup trust checks cannot allocate an
    unbounded receipt file, trust a directory/special-file replacement, or
    publish a partially written receipt. Raw model receipt v3 records byte
    count, mtime, device id, and file id from opened `fstat` metadata, so
    same-size managed-model replacement with restored mtime is rejected without
    hashing hundreds of megabytes on every launch.
- Device run preflight for the physical iPad/iPhone bridge path, including
  guards against treating localhost or loopback backend URLs as real-device
  evidence
- real-device evidence preflight contract tests, proving release evidence JSON
  rejects Simulator runs, loopback backend URLs, missing artifacts, and weak
  launch/memory/frame-pacing measurements without requiring every PR to attach
  real-device evidence. The Python preflight derives the b6, b18nbt, and b28nbt
  release-evidence manifest from `QixiNativeModelRegistry.swift`, including
  memory budgets and CoreML companion package specs, and the same test verifies
  that parser rejects a Swift registry missing any release engine.
- real-device evidence template contract tests, proving
  `scripts/qixi-real-device-evidence-template.py` rejects inherited backend
  transport settings for native release evidence, refuses symlink or already
  populated output paths, creates only non-evidence run-kit templates, and never
  writes `real-device-evidence.qixi-release.json`.
- real-device run-kit preflight contract tests, proving
  `scripts/qixi-real-device-run-kit-preflight.sh` rejects inherited backend
  transport settings, unfilled placeholders, template performance JSON, missing
  or weak screenshot/performance artifacts, and pre-existing app-written final
  evidence/export-audit/device-log files before a physical-device run starts.
  Screenshot visual inspection decodes the same bounded PNG byte buffer that
  supplied IHDR dimensions, so the preflight cannot inspect one screenshot
  path for dimensions and a different replacement path for visual content.
- real-model artifact inspector contract tests, using fake local files to prove
  malformed real-model evidence is rejected even when `QIXI_RUN_REAL_MODELS` is
  not enabled for the current PR.
- native persistence smoke coverage for App-written
  `real-device-evidence.qixi-release.json`, including a cross-language pass
  through `scripts/qixi-real-device-evidence-preflight.sh`
- Repository hygiene preflight for generated logs, screenshot artifacts, local
  model packages, Xcode archives/results, symbol bundles, and build output
- native persistence and sync runtime smoke for snapshot encoding, schema
  rejection, local save/load, primary/backup snapshot recovery, lifecycle
  tombstone marking, sync reconciliation, remote sync primary/backup recovery,
  remote sync mirror repair for missing or corrupted backup snapshots when the
  primary sync snapshot is valid,
  provider-aware iCloud enablement decisions that keep local `SyncFallback`
  writes from being persisted or displayed as enabled iCloud sync while still
  allowing explicit screenshot automation overrides,
  wrong-engine analysis-cache rejection, malformed semantic analysis-cache rejection,
  canonical UInt64 bit-pattern semantic cache fields, finite in-range semantic
  cache settings, distinct same-stones/different-history and different valid-setting
  semantic caches, illegal semantic-cache history rejection, long mixed-history
  bounded legality validation, and restore behavior without silently overwriting damaged remote state
- App Store static preflight for privacy manifest, permissions, local networking,
  export-compliance metadata, iCloud entitlements, orientation, and build
  settings. The static preflight reads the Xcode project, Info.plist,
  entitlements, privacy manifest, native engine source, and Swift sources
  through bounded local file-size guards before parsing, and rejects symbolic-link
  path components before load, then rechecks opened descriptors with `fstat`.
- native iOS Simulator build when Xcode is available

When the default gate attempts that native Xcode build, `xcodebuild` must
resolve to `/usr/bin/xcodebuild`; a shadowed `xcodebuild` earlier in `PATH`
fails the gate instead of creating fake build evidence. Machines without
`xcodebuild` still report an explicit development skip.

Set `QIXI_XCODEBUILD_VERBOSE=1` when debugging an Xcode build failure and the
quiet log is not enough.

For changes touching native KataGo, the iOS Metal build, CMake/Swift target
settings, or native model packaging, also run:

```sh
QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh
```

That optional gate runs the normal quality gate plus the iOS KataGo CMake
preflight twice: once for `iphonesimulator` and once for `iphoneos`, both using
the `katago_core` static-library target. This keeps a native-engine PR from
passing without proving that the local KataGo C++/Swift/Metal code still builds
for Apple iOS platforms. It is still not release evidence that the app target is
linked to the library or that KataGo ran inside a physical iPad process.

For native release linker, startup, or release-plist changes, also run:

```sh
QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh
```

That optional gate builds the simulator `katago_core` artifact, validates the
fresh `libkatago_core.a` and matching `libKataGoSwift.a` sidecar with
`lipo`/`otool` for arm64 iOS Simulator Mach-O platform output, links the Qixi
`NativeRelease` simulator app against those artifacts, validates the app
executable with the same iOS Simulator architecture/platform checks, rejects
development bridge strings in the executable, installs and launches the app
without backend environment variables, and inspects a simulator screenshot for
nonblank landscape app content. It is a pre-device regression tripwire; it does
not replace a signed archive or physical iPad/iPhone `nativeInProcess` evidence.

The default App Store preflight is development-facing and should keep the
current Mac-hosted backend defaults explicit. A submission-facing archive must
also run:

```sh
QIXI_APPSTORE_SUBMISSION=1 scripts/qixi-appstore-preflight.sh
```

That strict mode checks the native release plist, requires `nativeInProcess`,
requires the `NativeRelease` build to define `QIXI_ENABLE_NATIVE_KATAGO=1`, and
requires the development placeholder native engine to be excluded behind
`#if !QIXI_ENABLE_NATIVE_KATAGO`. A default gate pass is therefore not evidence
that the app is ready to submit.

## Screenshot gate

For a fast local visual smoke before the full matrix, run:

```sh
qixi-ios-native/scripts/screenshot-environment-doctor.sh
qixi-ios-native/scripts/screenshot-smoke-sim.sh
```

The environment doctor verifies Xcode, the iOS Simulator SDK, Python/Pillow,
the screenshot scripts, and selected iPad/iPhone simulator UDIDs, then writes
`qixi-ios-native/artifacts/screenshots/screenshot-environment.json` through a
same-directory temporary file opened with exclusive no-follow flags, written in
full, fsynced together with its parent directory, and atomically replaced after
unsafe symbolic-link path components are rejected. The quality gate immediately
verifies that artifact with
`qixi-ios-native/tests/inspect_screenshot_environment.py`, including strict JSON,
fresh mtime, UTC `generatedAt` freshness/future-skew checks, symbolic-link
path-component rejection, selected simulator UDIDs, documented entrypoint
commands, and the simulator-vs-device limitation caveats.
If `QIXI_SCREENSHOT_DOCTOR_ARTIFACT`
overrides the doctor output path, the quality gate passes the same path to the
inspector so the generated and verified environment evidence cannot diverge.
The smoke
captures and inspects the iPad main landscape surface, the iPhone landscape
surface, and the simulator launch/RSS performance artifact. It is a quick regression tripwire, not a replacement for the full matrix below.
To run it through the project quality gate and preserve the same surrounding
contract checks:

```sh
QIXI_RUN_SCREENSHOT_SMOKE=1 scripts/qixi-quality-gate.sh
```

```sh
QIXI_RUN_SCREENSHOTS=1 scripts/qixi-quality-gate.sh
```

This boots iPad and iPhone simulators, installs the native SwiftUI app, captures
all supported UI languages on the iPad main screen, captures the first-launch
onboarding screen in all supported UI languages, captures the iPhone landscape
layout and first-launch screen in all supported UI languages, captures the photo scan, SGF import,
native model-install status, board overlays, board-recognition preview,
captured-stone board replay, and iCloud sync on iPad and iPhone where
applicable,
utility sheets on both iPad and iPhone including synced/failure/conflict states,
native engine failure reasons on iPad and iPhone, performs image-level screenshot inspection, and verifies the
simulator app creates its launch autosave snapshot. It also records a simulator
launch/memory smoke artifact at
`qixi-ios-native/artifacts/performance/latest-sim-performance.json`; the default
budgets can be overridden with `QIXI_PERF_MAX_LAUNCH_COMMAND_MS`,
`QIXI_PERF_MAX_VISUAL_READY_MS`, and `QIXI_PERF_MAX_RSS_MB`. The screenshot
capture scripts reject symbolic-link components before writing raw PNG, cropped
PNG, or metrics JSON outputs; raw/cropped PNGs are published by same-directory
temporary files plus atomic replace, and metrics JSON artifacts use exclusive
no-follow temporary files with fsync and parent-directory fsync. The simulator
run and screenshot build freshness markers are also written through an exclusive
no-follow atomic marker helper before any build is trusted. Main-screen
screenshot inspection also fits the rendered 19x19 grid and checks that the
sample stones' visual centers sit on their grid intersections.
The full screenshot gate exports `QIXI_SCREENSHOT_MANIFEST_MIN_MTIME_EPOCH`
before running the matrix, and the final manifest artifact inspector rejects
any required screenshot whose mtime is older than that run marker. This ensures
stale artifacts cannot mask a state that stopped being captured.
Do not parallelize screenshot scripts that target the same Simulator device.
Each script installs and launches the same bundle with scenario-specific
environment variables, so concurrent runs can race and capture the wrong
scenario. Parallel screenshot jobs must use distinct `QIXI_SIM_UDID` or
`QIXI_IPHONE_SIM_DEVICE`/`QIXI_SIM_DEVICE` targets.
The full simulator gate also runs a negative smoke for
`QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_ANALYSIS=1`: it seeds placeholder evidence
artifacts, asks the app to export, and requires the Simulator run to write
`real-device-evidence.export.json` with `status = failed` instead of creating a
release-valid `real-device-evidence.qixi-release.json`. That negative state is
also declared in the screenshot manifest, so its visible UI is re-inspected by
the final artifact pass after the evidence audit succeeds.

The required screenshot matrix is explicit in
`qixi-ios-native/tests/screenshot_coverage_manifest.json`. The manifest expands
to 145 frontend states, including explicit b6/b18nbt/b28nbt engine-selection
states, and is audited by the default gate before any expensive
simulator work begins. The manifest is parsed as standards-compliant JSON that
rejects duplicate object keys and non-standard `NaN`/`Infinity` constants, so
coverage cannot depend on parser-specific last-key-wins behavior. Before JSON
parsing, the shared loader rejects missing, empty, non-regular, symbolic-link,
non-UTF-8, or over-budget manifest files, and rechecks the opened file
descriptor with `fstat` as a non-empty regular file within the same byte budget
before reading so a stat/open race cannot change what gets parsed. When
`QIXI_RUN_SCREENSHOTS=1` is enabled, the gate also runs
`qixi-ios-native/tests/inspect_screenshot_manifest_artifacts.py` after the
individual screenshot, persistence, and performance scripts. That final pass
re-expands the manifest, verifies that every declared screenshot script is an
in-tree executable regular file, constrains declared inspector and screenshot
artifact paths to the expected in-tree directories and suffixes, rejects
non-`QIXI_` environment controls or environment placeholders that do not come
from that matrix's dimensions, rejects symbolic links, verifies that every declared PNG artifact exists, reads each
PNG through an opened-descriptor bounded byte buffer, rejects opened-byte-count
drift, uses that same buffer to enforce IHDR byte and pixel budgets before
image decode, verifies each PNG is decodable from that same buffer with decoded dimensions matching IHDR, re-runs the declared inspector with the
declared arguments for each state, and compares engine error variants so
library-not-linked, model-missing, insufficient-memory, and local-network-denied
cannot collapse into the same visible banner. It also compares utility sheet, model install, and
iCloud sync variants so camera/import, verifying/installed/failed, and
disabled/enabled/synced/error/conflict states cannot all pass as the same generic
sheet. The utility-sheet inspector also checks the enabled sync states for the
blue iCloud icon and rejects disabled sync sheets that reuse that enabled icon,
and it checks model-install states for orange progress, green installed, and red
failure icons, so these states cannot differ only by a tiny localized word.
Only after that machine inspection passes, the gate runs
`qixi-ios-native/scripts/build_screenshot_review_board.py`, which generates
paginated contact sheets plus `latest-screenshot-review-board.html` and
`latest-screenshot-review-board.json` under
`qixi-ios-native/artifacts/screenshots/review-board` for a fast human scan of
the complete frontend state matrix. The builder reads each source screenshot
through an opened-descriptor bounded byte buffer, rejects opened-byte-count
drift, and uses the same bytes for PNG IHDR checks, decode, thumbnail
rendering, and source digest metadata. Generated page images are saved to
bounded bytes first, then written atomically and hashed from those same bytes.
The manifest hash still uses bounded streaming with opened-byte-count drift
checks. It writes generated page images, JSON, and
HTML through same-directory atomic temporary files opened with exclusive
no-follow flags, verifies the temporary file byte count exactly matches the
payload before replacement, fsyncs the parent directory after replacement, and
refuses symbolic-link or directory-shaped targets. The generated board is then
checked by
`qixi-ios-native/tests/inspect_screenshot_review_board.py`, which rejects
ambiguous JSON, missing or tiny page images, broken HTML references, duplicate
states, and page state counts that do not sum to the manifest's required state
count. It reads both page images and source screenshots through
opened-descriptor bounded byte buffers, rejects opened-byte-count drift, and
uses those same bytes for PNG IHDR checks, decode, visual page statistics, and
recorded digest comparison before trusting review-board JSON metadata, rejects ambiguous JSON
paths with empty, current-directory, or parent-directory components, and
validates `generatedAt` as fresh microsecond UTC run metadata, rejects
timestamps that are stale or too far in the future, and enforces a bounded HTML
size before reading review-board links. Review-board JSON and HTML are read
through bounded UTF-8 loads that recheck opened descriptors with `fstat`, and
SHA-256 digest recomputation streams through the same opened-descriptor guard
while rejecting opened-byte-count drift. It also re-expands
`screenshot_coverage_manifest.json` and compares
each review-board state id, matrix id, dimensions object, description, and
screenshot path in order, so a board cannot pass by merely containing the right
number of plausible-looking entries. The review-board JSON records SHA-256 digests for
the screenshot manifest, every source screenshot, and every generated page
image, and the inspector recomputes those digests so manifest drift or same-size
substitutions cannot pass as valid evidence. The
inspector also rejects unreferenced old page PNGs left in the review-board
directory, so a human reviewer cannot accidentally open a stale extra page. The
generator clears only its own prior `latest-screenshot-review-board.*` artifacts
before rendering and refuses directory-shaped artifacts instead of recursively
deleting them. It also rejects a symbolic-link output directory, and the
review-board inspector rejects symbolic-link JSON, HTML, page PNG, and source
screenshot evidence paths. The inspector treats the review-board directory as a
closed evidence set: only the current JSON index, HTML index, and referenced
page PNGs may be present. The quality gate exports
`QIXI_SCREENSHOT_REVIEW_BOARD_MIN_MTIME_EPOCH`
immediately before generation, so stale review-board JSON, HTML, or page PNGs
from an earlier run cannot satisfy the current full-screenshot gate.

GitHub pull requests run `scripts/qixi_changed_surface_gate.py` before the
screenshot job. Any change to `qixi-ios-native/Qixi/*.swift`, native image
assets, the Xcode project, screenshot scripts, screenshot review-board/performance/persistence
helper scripts, screenshot inspectors, or the screenshot manifest automatically
runs the full `QIXI_RUN_SCREENSHOTS=1` gate.
Non-UI PRs still record an explicit classification skip in the screenshot job
log, so the absence of screenshots is evidence-backed rather than silent.
The classifier accepts only repository-relative POSIX changed-file paths;
absolute paths, home-relative paths, empty segments, `.`, `..`, backslashes,
control characters, and surrounding whitespace fail the classifier instead of
being normalized into a different review surface.
The same classifier also emits a release-sensitive surface for App Store,
App Store archive preflight, Qixi README files, release runbooks,
native engine integration docs, device preflight/signing doctor/bridge smoke contracts,
real-device evidence negative simulator smoke, privacy, entitlement,
release-evidence, position identity fixtures, native model manifest,
raw/ONNX/CoreML package artifact paths, `.gitignore`, and CI/PR verification
changes. GitHub Actions records those files in a dedicated release-sensitive
review job, so a release/App Store claim cannot hide inside an ordinary docs or
script change.

Run this for any change touching:

- SwiftUI layout, typography, color, symbols, assets, or localization
- board geometry, tree layout, candidate rendering, territory rendering
- app lifecycle, persistence, launch restore, background save behavior
- backup snapshot recovery when the primary autosave is corrupted or
  schema-incompatible
- lifecycle tombstone behavior for background, inactive, and termination saves
- simulator-level launch or memory regressions

## Real-model gate

```sh
QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh
```

This starts the local backend and verifies real KataGo Metal mux integration for
b6, b18nbt, and b28nbt models when the models and local binary are present.
The real-model integration scripts read backend status and analysis responses
with bounded `application/json` response bodies and strict object JSON parsing,
rejecting duplicate keys, `NaN`/`Infinity`, and non-object responses before any
winrate, ownership, or position-key evidence is accepted.
The b6/b18nbt/b28nbt integration also writes
`qixi-ios-sim/artifacts/real-models/latest-real-model-integration.json` with a
machine-readable record of the exact KataGo binary path, model byte counts,
per-model engine-switch timings, per-position analysis case timings, root
visits, candidate count, ownership range, best move summaries, off-engine
isolation checks, and unique position keys. The default run requires at least
8 visits per case and records case definitions for the opening position plus a
same-visible-stones/different-history pair. The artifact also records an
explicit same-visible/different-history check for each model, proving that
those two histories have equal final stones but distinct position keys. Treat
that artifact as debugging evidence, not as a tracked source file. The same gate then runs
`qixi-ios-sim/tests/inspect_real_model_integration_artifact.py`, which rejects
missing or stale artifacts, non-standards-compliant JSON with duplicate object
keys or `NaN`/`Infinity` constants, wrong schema/kind, missing b6/b18nbt/b28nbt
entries, mismatched model or KataGo binary byte counts, non-finite winrate or
score fields, non-361-point ownership summaries, missing analysis cases,
low-visit evidence, collapsed same-visible/different-history position keys,
duplicate real-model position keys, and off-engine isolation checks that still
look like a loaded model. The inspector bounds the artifact JSON read, rejects symbolic-link or
non-regular artifact, KataGo binary, config, and model paths before trusting
byte counts, and requires every referenced local path to stay inside the
repository root. It therefore cannot satisfy evidence by following a symlink,
loading an unbounded local file, or pointing the artifact at an unrelated
same-size file elsewhere on the machine. The integration publishes the artifact
through a same-directory exclusive no-follow temporary file, `fsync`, atomic
replace, and parent-directory `fsync`, so interrupted or redirected writes do
not become passing evidence. The real-model gate also exports
`QIXI_REAL_MODEL_ARTIFACT_MIN_MTIME_EPOCH` before launching the model
integrations, and the artifact inspector rejects any integration JSON older
than that run marker, so a recent but pre-existing artifact cannot stand in for
the current real-model run.
GitHub pull requests use the same changed-surface classifier for real-model
risk. Any backend, model, native KataGo, KataGo source, or raw/ONNX/CoreML package
artifact path change automatically runs
`QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh`; if the models or Metal
mux binary are absent, the job fails with that concrete missing artifact instead
of silently accepting weaker evidence. Changes to the shared
`tests/fixtures/position_identity_cases.json` fixture, its
`tests/validate_position_identity_fixture.py` validator, or that validator's
tests also trigger the real-model gate, because those files define and guard
the frontend/backend equality partition for same-stones, different-history
positions.
Native release linker, startup, plist, Xcode build setting, native in-process
runtime, and KataGo C++ source changes also trigger the GitHub
`QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh` job, so a PR cannot
alter the NativeRelease launch/link path while relying only on static CMake or
real-model evidence.

Run this for any change touching:

- KataGo process launch or configuration
- model selection
- analysis request/response parsing
- position identity, move history, ownership, or score/winrate handling
- shared position-identity fixtures
- persistent MCTS import/export or tombstone behavior
- native C++ tombstone size/read limits or restore failure semantics

## Release evidence gate

```sh
QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess \
QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json \
QIXI_APPSTORE_ARCHIVE_PATH=/path/to/Qixi.xcarchive \
QIXI_CONFIRM_APPSTORE_ARCHIVE_REVIEW=1 \
scripts/qixi-release-evidence-gate.sh
```

This is the non-skippable gate for release candidates, App Store submission
claims, or any statement that Qixi is ready for real iPad/iPhone users. It first
rejects missing required environment inputs, backend transport leakage, and
development skip switches before Xcode discovery. The archive preflight then
validates `QIXI_APPSTORE_ARCHIVE_PATH` as a real `.xcarchive` whose top-level
archive `Info.plist` has `ArchiveVersion`, plist `CreationDate`, `SchemeName = Qixi`,
non-empty `ApplicationProperties.SigningIdentity`, `ApplicationProperties.Team`, and app-matching version fields, containing
`Products/Applications/Qixi.app`, the archived app `Info.plist`, and the bundled
`PrivacyInfo.xcprivacy`; it rejects symbolic links in archive input paths,
bounds archive plist reads and the app executable read before loading, requires
`ApplicationProperties.ApplicationPath` to stay inside `Products`, and also rejects archives whose app is not an iPhoneOS app executable with an arm64 iOS device `MH_EXECUTE` Mach-O slice, whose app executable contains forbidden development bridge or placeholder strings, whose app code signature does not pass `codesign --verify --deep --strict`, whose release evidence signature is ad-hoc instead of `Apple Distribution` or `iPhone Distribution`, whose archived `Info.plist` omits camera/photo/local-network usage descriptions, safe ATS local-network policy, export-compliance metadata, ProMotion support, version strings, exact `CFBundleSupportedPlatforms = [iPhoneOS]`, exact `UIDeviceFamily = [1,2]`, or `MinimumOSVersion >= 17.0`, or whose archived `PrivacyInfo.xcprivacy` omits required-reason API coverage for UserDefaults reason `CA92.1`, or whose signed entitlements omit the Qixi iCloud containers, `CloudDocuments`, team identifier, bundle-suffixed `application-identifier`, or disabled `get-task-allow`. It then runs
`scripts/qixi_release_evidence_archive_match.py`, which first requires the archive top-level
`ApplicationProperties.CFBundleIdentifier`,
`ApplicationProperties.CFBundleShortVersionString`, and
`ApplicationProperties.CFBundleVersion` to match the archived app `Info.plist`,
then requires the real-device evidence to use the current
`qixi-real-device-evidence` schema/kind before comparing
`app.bundleIdentifier`, `app.version`,
`app.build`, `app.analysisRuntime`, and `app.executableSHA256HexDigest` fields to exactly match the archived app
`Info.plist` `CFBundleIdentifier`, `CFBundleShortVersionString`,
`CFBundleVersion`, `QixiAnalysisRuntime`, and archived executable SHA-256. Both
runtime fields must be one of `httpBridge` or `nativeInProcess`; when
`QIXI_REAL_DEVICE_EXPECT_RUNTIME` is set, the same match step also requires
that evidence/archive runtime to equal the expected runtime, so evidence from one build cannot be paired with another submitted archive or a different runtime. The match step rejects symbolic links in release input paths, bounds the evidence JSON and archive plist reads before parsing, hashes the archived app executable in bounded chunks, requires archive `ApplicationPath` to stay inside `Products`, and requires archive `ApplicationPath` and `CFBundleExecutable` to stay inside the app bundle. It then validates the recorded fully native
`QIXI_REAL_DEVICE_EVIDENCE` JSON with `scripts/qixi-real-device-evidence-preflight.sh`, then runs the
`QIXI_APPSTORE_SUBMISSION=1` submission preflight,
`scripts/qixi-native-linked-build-preflight.sh`,
`QIXI_IOS_SDK=iphoneos QIXI_IOS_KATAGO_BUILD_TARGET=katago_core scripts/qixi-ios-katago-cmake-preflight.sh`,
the full screenshot matrix, the full Simulator+device
`QIXI_RUN_IOS_KATAGO_CMAKE=1` quality-gate CMake path, the runnable linked
`QIXI_RUN_NATIVE_RELEASE_SIM=1` NativeRelease simulator smoke, the real-model
integration gate, and the screenshot manifest artifact re-inspection.

Before collecting release evidence, generate a non-evidence run kit with
`scripts/qixi-real-device-evidence-template.py --output-dir /tmp/qixi-real-device-run`.
The run kit provides the environment keys and artifact schemas for a
`nativeInProcess` physical-device run, rejects inherited backend environment,
and deliberately does not create or retain the final evidence JSON, export
audit, screenshot, measured performance artifact, or app-generated device-log
artifact. At template-generation time, the forbidden final files are
`real-device-evidence.qixi-release.json`, `real-device-evidence.export.json`,
`real-device-main.png`, `real-device-performance.json`, and
`real-device-log.json`. After filling the environment values and adding the
real screenshot/performance artifacts, run
`scripts/qixi-real-device-run-kit-preflight.sh /tmp/qixi-real-device-run` before
the finalization launch; generate or refresh the run-kit `runId` / `recordedAt`
seed after measurement collection so the seed is not older than the staged
performance artifact. Only the physical-device app export plus
`scripts/qixi-real-device-evidence-preflight.sh` can turn a run into acceptable
evidence.
The app-side export path also validates `QIXI_REAL_DEVICE_EVIDENCE_OUTPUT`:
relative outputs must be portable POSIX paths without traversal, absolute
outputs must name regular `.json` files, and the export-audit filename is
rejected before evidence is written. The app-side automation export also rejects
`QIXI_BACKEND_URL` and `QIXI_DEVICE_BACKEND_URL` for `nativeInProcess` before it
validates custom evidence output paths, constructs evidence, fingerprints
artifacts, or touches native model/tombstone state.

The machine-checkable evidence JSON must name a physical iPad or iPhone, not a
Simulator, include the app runtime, real KataGo engine/model analysis, MCTS
ownership source, positive-integer visits and candidate counts, finite
launch/memory/frame-pacing measurements, background/autosave/tombstone restore
results, camera recognition, iCloud sync, model import checks, and
screenshot/performance/device-log artifacts. The evidence JSON and every JSON
artifact must be standards-compliant JSON that rejects duplicate object keys and
non-standard `NaN`/`Infinity` constants, so parser-specific last-key-wins or
non-finite-number behavior cannot change release evidence semantics. The
Swift evidence store also applies bounded strict object parsing to the evidence
file, export audit, performance artifact, and device-log artifact before release
evidence is accepted by the native app. It also rejects symbolic links in the
real-device evidence and export-audit file and directory paths before loading or
writing those files, matching the Python release preflight's release-bundle path posture. The Python release preflight mirrors the
same bounded JSON reads for the evidence, performance artifact, and device-log
artifact before release evidence is accepted by CI or a local release review,
and reads `QixiNativeModelRegistry.swift` through bounded source loading with
symbolic-link rejection before deriving the native model release manifest. Swift
rechecks each artifact's byte count and SHA-256 after content validation, so an
app-side evidence export cannot hash one artifact file and validate another if
the artifact changes between the fingerprint and content reads. Performance and
device-log JSON artifact validators also parse the same strict `Data` whose
SHA-256 is compared with the recorded artifact fingerprint. The
nativeInProcess peak and post-analysis RSS measurements must also stay within
the selected engine's `maximumMemoryMB` from `QixiNativeModelRegistry.swift`.
The evidence `recordedAt` timestamp must be recent and must not be in the future
beyond the release clock-skew budget, so an old device run cannot be reused as a
fresh release proof. The top-level `runId` must be a canonical lowercase UUID,
and the performance and device-log artifacts must carry the same `runId`.
Performance artifacts may be staged before the final app-side evidence export,
but their `recordedAt` must not be newer than the evidence and must stay within
the bounded staging window; device-log artifacts are app-generated from the
final evidence object and must carry the exact same `recordedAt`. This prevents
attachments from different device runs from being stitched into one release
proof while still allowing Instruments or MetricKit data to be collected before
the finalization launch. The
artifact paths must be unique portable relative paths beside the evidence JSON;
absolute paths, home-relative paths, backslash separators, empty segments,
`.` segments, and parent-directory traversal are rejected so evidence stays portable.
Reserved release evidence and export-audit filenames are rejected as artifact
paths, and artifact paths must not resolve to the current evidence JSON path.
Symbolic links are rejected
for every evidence JSON, evidence directory, ancestor directory, and artifact
path component, and the Python release preflight rejects evidence-path symbolic
links before reading the evidence JSON. Final artifacts must be regular files, so relative evidence paths cannot escape the evidence bundle. Each artifact entry must record file byte count and lowercase SHA-256 digest, and the preflight
recomputes both before inspecting artifact content. Swift and Python check each
required artifact kind's byte budget before recomputing SHA-256, so oversized
screenshot, performance, or device-log artifacts are rejected before
fingerprinting. The
screenshot artifact must be a PNG with landscape dimensions large enough for
the recorded device class. Swift and Python read only the fixed PNG header bytes
to get dimensions, reject screenshots above the bounded pixel budget before any
bitmap allocation, must then decode successfully, and must contain enough
visual variance plus dark board/grid detail that a blank, flat, or header-only placeholder image cannot satisfy release evidence, and oversized screenshots cannot reach bitmap allocation. The performance artifact must be
structured JSON with `schemaVersion = 1`,
`kind = qixi-real-device-performance`, a trusted
measurement source of `instruments`, `xctrace`, or `metricKit`, nested launch,
memory, and frame-pacing measurements, plus `measurements.framePacing` values,
a matching `runId`, and a bounded staged `recordedAt` that is no newer than the
final evidence and no older than the
bounded staging window, so a placeholder or stale performance file cannot
satisfy release evidence either. The preflight validates
`performance artifact.source` explicitly. The
device-log artifact must be structured JSON with
`schemaVersion = 1`, `kind = qixi-real-device-log`, matching `runId`, exact matching `recordedAt`, and matching device, app executable SHA-256,
backend/runtime, analysis, lifecycle, and feature facts. For `nativeInProcess`,
the evidence and device-log artifact must also carry matching
`analysis.positionIdentity` fields: the current root key, a
same-visible-stones/different-history fixture, and a proof that those two
fixture histories keep distinct position keys, including
`sameVisibleHistoryKeysDistinct = true`. For `nativeInProcess`,
device-log artifacts must also carry matching `analysis.nativeEngine` engine id,
model digest, `analysis.nativeEngine.coreMLPackages` package tree-digest
metadata, and tombstone export/restore audit fields, including
`analysis.nativeEngine.engineId`,
`analysis.nativeEngine.modelSHA256HexDigest`,
`analysis.nativeEngine.coreMLPackages`, and
`analysis.nativeEngine.tombstoneRestoredAt`.
Release evidence must set `QIXI_REAL_DEVICE_EXPECT_RUNTIME=nativeInProcess`,
must omit the `backend` object entirely, and must not set
`QIXI_DEVICE_BACKEND_URL` or `QIXI_BACKEND_URL`. The
Mac-hosted `httpBridge` path is still useful development evidence; verify it
with:

```sh
QIXI_DEVICE_STRICT=1 QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 scripts/qixi-device-run-preflight.sh
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 QIXI_REAL_DEVICE_EVIDENCE=/path/to/bridge-evidence.json scripts/qixi-real-device-evidence-preflight.sh
```

Do not use bridge evidence to claim release/App Store readiness.

This gate is expected to fail in the current development state until a signed
archive and physical-device `nativeInProcess` evidence are supplied. The normal
Debug/Release app configuration intentionally remains on the Mac-hosted
HTTP bridge for development, while the separate `NativeRelease` configuration
uses `Qixi/NativeReleaseInfo.plist`, defaults `QixiAnalysisRuntime` to
`nativeInProcess`, omits
`QixiBackendBaseURL`, defines `QIXI_ENABLE_NATIVE_KATAGO=1`, defines
`QIXI_NATIVE_RELEASE` through `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and
`OTHER_SWIFT_FLAGS = -D QIXI_NATIVE_RELEASE`, excludes the development HTTP
bridge Swift source files from the native release configuration, exposes KataGo
headers, and links Metal/Accelerate/CoreML/MPS/MPSGraph plus zlib and the
configured KataGo library setting.
It defaults `QixiAnalysisRuntime` to `nativeInProcess` only for that native
release configuration.
The development placeholder native engine remains available only when
`QIXI_ENABLE_NATIVE_KATAGO=0`; submission static preflight rejects it if it is
not excluded by that guard.
The release gate rejects development skip switches such as `QIXI_SKIP_XCODEBUILD`;
release proof must include the native Xcode build inside
`scripts/qixi-quality-gate.sh`, not only the static preflights, and it fails
early if `xcodebuild` is not in `PATH`, if `xcodebuild` does not resolve to `/usr/bin/xcodebuild`
because a shadowed `xcodebuild` appears earlier in `PATH`, or if `xcodebuild -showsdks` does not
report an `iphoneos` SDK, because the default quality gate's development-friendly
Xcode skip is not release evidence.
It also runs the
full quality gate with `QIXI_REQUIRE_TRACKED_FILE_AUDIT=1`,
`QIXI_RUN_IOS_KATAGO_CMAKE=1`, `QIXI_RUN_NATIVE_RELEASE_SIM=1`,
`QIXI_RUN_SCREENSHOTS=1`, and `QIXI_RUN_REAL_MODELS=1`, so repository hygiene
cannot silently skip the tracked-file audit and the release pass cannot omit the
Simulator+device iOS KataGo CMake path, runnable linked NativeRelease Simulator
smoke, screenshot matrix, or real-model integrations. The
native linked build preflight still fails until the release evidence
environment points `QIXI_KATAGO_IOS_XCFRAMEWORK` at an existing built iOS KataGo
XCFramework, or points `QIXI_KATAGO_IOS_LIBRARY` at `libkatago_core.a` and
`QIXI_KATAGO_IOS_LIBRARY_DIR` at the directory containing the matching `libKataGoSwift.a` sidecar. That is the real iOS KataGo library or XCFramework
boundary. The linked preflight requires exactly one of the XCFramework or
static-library inputs, requires configured native artifact paths to be absolute,
rejects symbolic links in configured artifact paths, bounds source/plist reads before loading,
rechecks opened descriptors with `fstat`, validates the Swift sidecar when a static `libkatago_core.a` is used, and requires
XCFramework `LibraryIdentifier` plus `LibraryPath` entries
to remain inside the XCFramework. The linked artifact is also checked for a
substantial defined-symbol surface and KataGo-like C++ symbol density after
demangling, so a small iOS archive that only exports broad fragment names cannot
satisfy release evidence. Set
`QIXI_NATIVE_LINKED_PREFLIGHT_REPORT=/path/to/native-linked-report.json` to
write a machine-readable blocker report with schema version, timestamp, inputs,
status, and the exact failing release-link requirements. The report path also
rejects symbolic links and is written through an exclusive flushed temporary
file plus atomic replace, so diagnostics cannot be redirected through a
symlinked report. `scripts/qixi-native-release-build-preflight.sh` then performs
the native release Xcode build preflight: it reruns the linked-artifact preflight,
requires `/usr/bin/xcodebuild` with an `iphoneos` SDK, builds the `Qixi` scheme
with `-configuration NativeRelease` for `generic/platform=iOS`, validates the
`NativeRelease-iphoneos/Qixi.app` Info.plist as `nativeInProcess` without
`QixiBackendBaseURL` using bounded reads that recheck the opened descriptor with
`fstat`, checks the executable through the same descriptor guard as arm64 iOS
device Mach-O output, and rejects development bridge or placeholder strings such
as `BackendClient`,
`HTTPBridgeAnalysisService`, `Qixi HTTP bridge response`,
`qixi.backendBaseURL`, `QIXI_ANALYSIS_RUNTIME`, and local backend URLs in the
built app. That failure is intentional.
The iOS KataGo CMake preflight configures the Metal build with
`CMAKE_SYSTEM_NAME=iOS`, `KATAGO_METAL_ENABLE_COREML_CONVERSION=0`, and an
explicit Swift target, then compiles the requested target. Daily development
runs default to `CMAKE_OSX_SYSROOT=iphonesimulator` with
`CMAKE_Swift_COMPILER_TARGET=arm64-apple-ios17.0-simulator`; release evidence
forces `CMAKE_OSX_SYSROOT=iphoneos` with
`CMAKE_Swift_COMPILER_TARGET=arm64-apple-ios17.0`. That keeps Protobuf/abseil
and the `katagocoreml` converter out of the iOS runtime build; ANE/CoreML
threads must use preconverted `.mlpackage` or `.mlmodelc` model packages. Its
temporary CMake build directory must stay directly under `/private/tmp` or
`/tmp`, use the `qixi-ios-katago-cmake-preflight-` prefix, contain no symbolic-link
path components, and pass validation that must reject symbolic-link
path components before the script removes or recreates that directory. After
the build, the preflight validates the produced `libkatago_core.a`, or an explicitly requested `libKataGoSwift.a` or
`katago.app/katago` artifact with `lipo` and `otool`, requiring the configured
architecture and the expected iOS/iOS Simulator Mach-O platform before accepting
the build, with no non-target platform object files mixed into the artifact. A
native-engine development PR should normally run
`QIXI_RUN_IOS_KATAGO_CMAKE=1 scripts/qixi-quality-gate.sh`, which performs that
preflight for both the Simulator and device `katago_core` static-library
targets before any release archive exists, and
`QIXI_RUN_NATIVE_RELEASE_SIM=1 scripts/qixi-quality-gate.sh`, which validates the
fresh simulator `libkatago_core.a` plus matching `libKataGoSwift.a` sidecar and
the linked `NativeRelease` simulator app executable before launching without
backend environment variables. Its full-frame and content-cropped simulator
screenshots are written through protected temporary PNGs and atomically replaced
after symbolic-link output paths are rejected. Default, screenshot, real-model, iOS CMake, or
NativeRelease Simulator gate passes are strong development evidence, but none of them proves
fully in-process KataGo execution on a physical iPad or App Store submission
readiness.

## Repository hygiene preflight

The default gate also runs:

```sh
scripts/qixi-repo-hygiene-preflight.sh
```

This check verifies that generated logs, simulator screenshots, Xcode build
artifacts, local model packages, native model staging directories, KataGo build
directories, Python bytecode caches, `.DS_Store`, coverage outputs, JS/Python
tool caches, and temporary recovery files remain ignored and are not already
tracked by git. Root-level local model files and the ignored `/Models/` staging
directory may exist for development, but `.bin`, `.bin.gz`, `.txt.gz`, `.onnx`,
`.mlmodel`, `.mlmodelc`, and `.mlpackage` artifacts are rejected from source
directories and from tracked files; only KataGo's upstream test fixtures under
`KataGo/cpp/tests/models/` are exempted. It also scans non-ignored source paths for Python bytecode caches,
Xcode user/build result bundles, Finder `.DS_Store`, coverage outputs,
`node_modules`, JS package-manager debug logs, temporary files, and recovery files even when launched outside a git worktree, while still
requiring a real git worktree when `QIXI_REQUIRE_TRACKED_FILE_AUDIT=1`. The
default quality gate removes Finder `.DS_Store` metadata and lightweight tool
caches before the hygiene preflight and again on exit, so source-path cache
artifacts found by the standalone hygiene script are treated as local pollution
rather than accepted platform noise. These files are either recoverable,
machine-local, or too large for normal review, so a pull request must never rely
on them being committed.

## Device run preflight

The default gate also runs the static part of:

```sh
scripts/qixi-device-run-preflight.sh
```

Before recording real iPad/iPhone bridge evidence, run the strict live backend
check with the Mac's LAN address. Use the signing doctor first when device
signing is not already known-good:

```sh
scripts/qixi-device-signing-doctor.sh
QIXI_DEVICE_STRICT=1 \
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_ID=<devicectl-identifier-if-needed> \
QIXI_DEVICE_DEVELOPMENT_TEAM=<team-id-if-not-set-in-project> \
scripts/qixi-device-run-preflight.sh
```

This check refuses `localhost`, `127.0.0.1`, `::1`, and `0.0.0.0` because those
addresses do not prove that a physical device can reach the Mac-hosted backend.
Before those network checks, strict mode uses `devicectl` to require a physical
iPad/iPhone whose `devicectl device info details` output proves Developer Mode
enabled, Developer Disk Image services available, active CoreDevice transport,
and install/launch capabilities. It still lists devices first for diagnostics
and ambiguity detection, but it does not trust the list-state string alone:
recent CoreDevice builds can show a usable network-paired iPad as
`available (paired)` while the details output proves the tunnel and DDI services
are live. Automatic selection only considers detail-probeable list states such
as `connected`, `connected (no DDI)`, and `available (paired)`, then lets the
details check reject devices without DDI, Developer Mode, active transport, or
install/launch capability. `connecting` and `unavailable` devices are never
selected.
When no usable device is selected, the preflight error and signing doctor list
visible `devicectl` devices with state, identifier, and model before reporting
signing/profile blockers. A manually supplied `QIXI_DEVICE_ID` is not a bypass:
it must still appear in `devicectl list devices` and be probeable by
`devicectl device info details`. It also resolves `PRODUCT_BUNDLE_IDENTIFIER`
and requires an
installed iOS App Development provisioning profile whose team, bundle id,
physical-device UDID, and expiration date match the run unless
`QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES=1` is explicitly set for a configured
Xcode account. When automatic provisioning is enabled, the strict preflight also
runs a real `xcodebuild build` signing probe in temporary DerivedData with
`-allowProvisioningUpdates` and rejects `DVTDeveloperAccountManager`, missing
`Xcode-Username`, `No Accounts`, `No profiles for`, or other credential/profile
diagnostics before the bridge smoke reaches install/launch. It also reads local Info.plist, Xcode
project, runbook, and quality-gate inputs through bounded file-size guards and
rejects symbolic-link path components, then rechecks opened descriptors with
`fstat`.
The signing doctor has its own unit contract and reports the resolved bundle
id, team, physical-device UDID, Apple Development identity counts, available
Apple Development team identifiers, scanned
provisioning profile count, matching profile paths, and per-profile mismatch
reasons plus the Xcode automatic-provisioning account probe. Its JSON output
also carries stable `recommendedActions` codes such as
`device.coredevice_transport_not_ready`, `signing.team_identity_missing`,
`signing.profile_missing`, and `signing.xcode_account_probe_failed` so failed
device setup is inspectable and scriptable before the strict preflight.
Device-related recommended actions are bound to the selected device
identifier/UDID, so unrelated visible devices cannot pollute the diagnosis for a
ready selected iPad or iPhone.
It then calls `/api/status`, requires a bounded
`application/json` response, rejects duplicate JSON keys and `NaN`/`Infinity`,
and verifies the expected typed Qixi backend status shape.

After strict preflight succeeds, use the physical-device bridge smoke to produce
machine-readable run artifacts:

```sh
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_DEVELOPMENT_TEAM=<team-id-if-not-set-in-project> \
scripts/qixi-device-bridge-smoke.sh
```

For a local physical-device bridge/UI run on a Mac that lacks the repository's
project team, set `QIXI_DEVICE_BUNDLE_ID=<personal.reverse.dns.id>` and
`QIXI_DEVICE_DISABLE_ICLOUD_ENTITLEMENTS=1` together with an available
`QIXI_DEVICE_DEVELOPMENT_TEAM`. The signing doctor, strict preflight, and bridge
smoke build all use the same bundle identifier override. Disabling iCloud
entitlements is deliberately local bridge evidence only; it cannot satisfy
iCloud sync, App Store, or native release evidence requirements.

`QIXI_DEVICE_BRIDGE_PLAN_ONLY=1` is available when a reviewer needs the exact
bridge commands and current signing blockers without mutating Xcode profiles or
installing the app. That manifest is explicitly `dryRun=true`; the bridge smoke
plan inspector (`scripts/qixi-device-bridge-plan-inspect.sh`) validates it, and
the real bridge smoke artifact inspector rejects it, so it is diagnostic output
rather than passable device evidence.
Set `QIXI_RUN_DEVICE_BRIDGE_PLAN=1` on `scripts/qixi-quality-gate.sh` to run
that diagnostic as an optional quality-gate step before attempting live bridge
smoke.

With `QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES=1`, the bridge smoke passes
`-allowProvisioningUpdates` and `-allowProvisioningDeviceRegistration` to
`xcodebuild`; without it, the preflight fails early when no matching installed
profile exists.

The bridge smoke manifest carries a per-run `runId`, UTC `generatedAt` /
`startedAt` / `completedAt` timestamps, and per-stage `timingsMs`. Set
`QIXI_DEVICE_BRIDGE_RUN_ID` to a canonical 32-character lowercase hex value
when a surrounding evidence run must bind this bridge smoke to other artifacts.
Inspect the resulting artifact bundle with:

```sh
scripts/qixi-device-bridge-plan-inspect.sh
scripts/qixi-device-bridge-smoke-inspect.sh
```

If a selected-engine launch fails before the Mac backend observes the expected
engine request, inspect that failure artifact explicitly instead of treating the
terminal log as evidence:

```sh
scripts/qixi-device-bridge-failure-inspect.sh \
  qixi-ios-native/artifacts/device-bridge/latest-device-bridge-failure.json
```

The default quality gate can run this failure inspection as an opt-in step with
`QIXI_RUN_DEVICE_BRIDGE_FAILURE_INSPECT=1`; set
`QIXI_DEVICE_BRIDGE_FAILURE_ARTIFACT` when the failure manifest is not at the
default artifact path. The failure backend-events artifact carries both
`observedExpectedEngine=false` and a structured `diagnosticCategory` such as
`iosLocalNetworkDenied`, while the inspector verifies that this category is
backed by the copied app-side runtime diagnostic.

The default quality gate runs `tests/test_device_bridge_smoke.py` and
`tests/test_device_bridge_smoke_inspector.py` to keep this script's command
construction, bundle validation, launch environment, app container artifact
contract, and artifact inspector from drifting. The inspector bounds the
manifest and `devicectl` JSON artifacts, rejects symbolic-link artifact paths,
rejects duplicate keys and `NaN`/`Infinity`, and applies the same strict bounded
JSON-object parsing to the launch command's embedded environment string so
bridge evidence cannot hide an alternate runtime or backend behind last-key-wins
JSON behavior. It also requires the recorded `xcodebuild` and `devicectl`
commands to be structured string arrays with the expected prefixes, validates
that the Xcode build targeted the recorded device UDID, and checks that the app
container copy command references the Qixi app-support path. Each recorded
`devicectl` command must also target the manifest device identifier and write
its `--json-output` to the matching manifest artifact path, while launch/copy
commands must reference the validated bundle id. The live smoke itself is opt-in
because it requires a connected physical device, signing identity, and reachable
Mac-hosted backend:

```sh
QIXI_RUN_DEVICE_BRIDGE_SMOKE=1 \
QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 \
QIXI_DEVICE_DEVELOPMENT_TEAM=<team-id-if-not-set-in-project> \
scripts/qixi-quality-gate.sh
```

GitHub Actions also exposes a manual `workflow_dispatch` input
`run_device_bridge_smoke` for this same path. Use it only on a configured Mac
runner with a reachable backend and physical iPad/iPhone. The
`device_bridge_runner` input is a JSON runner-label array and defaults to
`["self-hosted","macOS","qixi-device"]`; retarget it only to another runner that
has the same physical-device access. Set `QIXI_DEVICE_BACKEND_URL`,
`QIXI_DEVICE_DEVELOPMENT_TEAM`, optional `QIXI_DEVICE_ID`, and optional
`QIXI_DEVICE_ALLOW_PROVISIONING_UPDATES` as repository secrets before starting
the `Device Bridge Smoke Gate`.

The release gate additionally validates recorded device evidence:

```sh
QIXI_REAL_DEVICE_EVIDENCE=/path/to/real-device-evidence.json scripts/qixi-real-device-evidence-preflight.sh
```

That JSON check rejects Simulator evidence, loopback backend URLs, missing
artifact files, missing camera/iCloud/model-import confirmations, absent
background restore/tombstone checks, weak ProMotion/frame-pacing observations,
tiny or portrait screenshot evidence, and launch or memory measurements outside
the configured budgets.

## When to run the expensive gates

If a pull request could plausibly affect a surface covered by an expensive gate,
run that gate before review. If the local machine cannot run it, the pull request
must state the exact reason and provide the strongest available substitute, such
as a focused unit test plus a reviewer note asking for simulator or real-device
verification.

## No silent skips

The default quality gate runs `tests/test_quality_gate_skip_audit.py` before the
rest of the gate suite. That audit treats `scripts/qixi-quality-gate.sh`,
`scripts/qixi-release-evidence-gate.sh`, and the Python physical-device run
preflight as source artifacts and verifies every `Skipping ...` line is either a
diagnostic environment absence such as a missing tool, or names the exact
`QIXI_RUN_*` or device backend variable that enables the gate. It also rejects
unparseable skip output, including `printf`, single-quoted text, Python
f-strings, or adjacent string fragments that would hide a runtime `Skipping ...`
message from the audit. PR authors must copy those skips into the PR checklist
when they are relevant. A skip without a reason is treated as missing
verification, not as a passed test.
