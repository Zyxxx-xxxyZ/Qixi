# Native KataGo NN integration

> **Audience:** developers linking NativeRelease / NN adapters.  
> Product search is `core::MCTSStore` only — see [`search-engine.md`](search-engine.md).

# Native KataGo Integration

This document records the production path for moving Qixi from the current
Mac-hosted analysis bridge to fully in-process iPad KataGo execution.

## Current Boundary

The SwiftUI app depends on `QixiAnalysisService`.

- `QixiAnalysisService.swift` owns only the runtime enum, protocol, runtime
  configuration, and factory.
- `QixiHTTPBridgeAnalysisService.swift` is the current development and
  device-smoke path.
- `QixiNativeKataGoAnalysisService.swift` is the iPad in-process path. It must
  not import or reference `BackendClient`, `URLSession`, localhost, LAN URLs, or
  the Python backend.
- `NativeKataGoAnalysisService` calls `QixiNativeKataGoBridge`, an Objective-C++
  bridge compiled into the app target through `Qixi-Bridging-Header.h`.
- `NativeKataGoAnalysisService` is a Swift actor. Calls to model resolution,
  engine loading, bridge analysis, and `currentEngine` updates must remain
  serialized before entering the Objective-C++ bridge and C++ core.
- `QixiNativeKataGoBridge` delegates to `qixi::NativeKataGoCore`, the pure C++
  lifecycle and validation boundary.
- `qixi::NativeKataGoCore` owns engine-id validation, model-config validation,
  no-engine analysis responses, and loaded-engine state. Real KataGo linkage
  belongs behind the `qixi::NativeKataGoEngine` adapter interface, not directly
  in Swift or Objective-C++.
- `qixi::NativeKataGoEngine::unloadModel` is the explicit memory-release
  boundary. It must be idempotent, must tolerate being called before the first
  real model load, and must tear down model/search/evaluator state without
  requiring Swift to know KataGo internals.
- `QixiNativeKataGoEngine.cpp` keeps the development placeholder
  `NativeKataGoEngine` behind `#if !QIXI_ENABLE_NATIVE_KATAGO`, where it reports
  `libraryNotLinked` for Debug/Release diagnostics. The `NativeRelease` build
  defines `QIXI_ENABLE_NATIVE_KATAGO=1` and compiles the linked iOS KataGo
  adapter path for model loading, search, memory budgeting, and ownership
  aggregation.
- The native linked-build preflight must inspect the submitted iOS device
  library or XCFramework with `lipo`, `otool`, and `nm`. A candidate artifact
  is not considered a real KataGo runtime merely because it contains broad
  symbol names alone; it must also expose the concrete **NN** adapter boundary
  used by Qixi: `initializeNNEvaluator`, `loadSingleParams`, `NNEvaluator`,
  `BoardHistory`, and related eval/setup symbols. **Search is not KataGo's
  `Search` / `AsyncBot`.** Product search is `core::MCTSStore` only, fed by
  `LinkedCoreEvaluator` wrapping `NNEvaluator`. The preflight also demangles
  symbols with `c++filt` when available and requires a substantial
  defined-symbol count plus a minimum set of KataGo-like C++ symbols for the
  neural path. This prevents a tiny iOS archive that exports empty C functions
  from being treated as a linked KataGo NN runtime.
- `QixiNativeModelRegistry` is the Swift manifest for b6, b18nbt, and b28nbt
  resource names, expected byte count, SHA-256 digest, and memory budgets. Swift
  must resolve a model against that manifest before passing its filesystem path
  into the bridge. The manifest also owns optional
  `NativeKataGoCoreMLPackageSpec` entries for preconverted ANE/CoreML companion
  packages, including package resource name, variant ID, recursive file count,
  total byte count, and SHA-256 tree digest.
  - b6: `g170-b6c96-s175395328-d26788732.bin.gz`, 3,827,339 bytes,
    SHA-256 `f5d32604e3675c480c7c8f6aa579a1ea857135628a0afccc8fa56330fbacd38d`
  - b18nbt: `b18nbt.bin`, 105,532,578 bytes,
    SHA-256 `46a623a366ef6ef423fa2055f1b094fd8f64c518c065e7d254a9e0829c192c5c`
  - b28nbt: `b28nbt.bin`, 291,771,656 bytes,
    SHA-256 `053d2411c311b5cb8f44d9960e431371460169561401ea35088a030b87337770`
- `QixiNativeDeviceMemoryPolicy` is the Swift load gate for those memory
  budgets. It reads physical device memory, reserves 1024 MB for the system by
  default, and refuses to load a model unless the remaining budget satisfies the
  model's minimum memory budget. Tests may inject physical memory to cover low
  memory devices deterministically. `NativeKataGoAnalysisService` must check this
  budget after model resolution but before `configureModel` or any real-engine
  `loadEngine` call, so a too-large model can only clear stale native state and
  surface `insufficientDeviceMemory`; it must not enter a partially configured
  native engine state.
- `QixiNativeModelStore` resolves those resources from explicit test/search
  directories, the app bundle, and `Application Support/Qixi/Models` before
  Swift passes a filesystem `modelPath` into the native bridge. Runtime
  resolution rejects files whose expected byte count does not match the
  manifest; the native model preflight performs the heavier SHA-256 validation
  against the local source-of-truth files. If a model spec declares
  `coreMLPackages`, the store must resolve every required `.mlpackage` or
  `.mlmodelc` beside the raw model before accepting the raw model. It returns
  those `coreMLPackageURLs` with the resolved model. `NativeKataGoAnalysisService`
  must pass them through `QixiNativeKataGoBridge` as `coreMLPackagePaths`, and
  `NativeKataGoModelConfig` must preserve them for the real adapter and
  persistent tombstone matching. `QixiNativeKataGoEngine.cpp` then writes them
  into KataGo's `ConfigParser` as `metalCoreMLPackagePathCount` plus indexed
  `metalCoreMLPackagePathN` entries. The Metal backend must consume those
  explicit paths before falling back to model-neighbor discovery, and it must
  only accept an explicit path when it is one of the legal preconverted package
  candidates for the current model, board size, precision, mask mode, and max
  batch size.
- `QixiNativeModelIntegrity` centralizes model byte-count and SHA-256
  verification. Startup model resolution uses its byte-count path so launch
  remains cheap. First install, import, migration, or model-repair flows must
  call `QixiNativeModelIntegrity.verifyModel`, which hashes with `CryptoKit` via
  `FileHandle` streaming chunks instead of loading the whole model into memory.
  Both byte-count and hash paths verify that the opened model file descriptor is
  still a regular file with `fstat`, and the hash path rejects opened-byte-count
  drift after streaming all chunks, so a path replacement or concurrent
  truncation after the URL metadata check cannot silently change the trusted
  model input.
- `QixiNativeCoreMLPackageIntegrity` is the equivalent verifier for
  preconverted CoreML companion packages. The quick startup path checks only the
  recursive file count and total byte count; install, repair, and trusted
  receipt creation must call `verifyPackage`, which rejects symbolic-link
  package source path components, rejects symbolic links and
  unsupported entries, rejects packages as soon as recursive file count or total byte count exceeds the manifest
  before building the sorted tree-digest list or hashing file contents, sorts
  safe relative paths deterministically, and hashes a domain-separated tree
  digest through streaming file chunks. Tree-digest hashing also rechecks each opened package file descriptor with `fstat` before hashing, and rejects opened-byte-count drift against the enumerated package footprint. This makes a same-size `.mlpackage` or
  `.mlmodelc` mutation visible without loading the package into memory at
  launch.
- `QixiNativeModelInstaller` is the verified install/import boundary for native
  model files. It validates the source, stages a copied temporary file inside
  `Application Support/Qixi/Models`, verifies the staged copy, then commits it
  under the manifest resource name. Raw model imports must reject symbolic-link source files, symbolic-link raw model source path components, and any non-regular source path before byte-count matching or SHA-256 hashing, so model import cannot silently follow a link outside the selected package. The model verifier also rechecks the opened descriptor with `fstat` before trusting byte count or hash input. Managed model, CoreML package, and receipt directories must reject symbolic links before and after directory creation, and final receipt paths must reject symbolic links before write. Receipt writes must use the shared Swift exclusive no-follow atomic writer with post-write `fstat` byte-count verification, `F_FULLFSYNC`/`fsync`, atomic `rename`, and parent-directory `fsync` after replacement. Managed model directories and files must be
  excluded from iCloud backup because the model files are large and recoverable.
  Temporary staged model files must also be excluded immediately after copy, so
  an interrupted install cannot leave backup-eligible large artifacts. Before a
  new install begins, the installer must remove stale orphan `.tmp`, `.backup`,
  and `.receipt-backup` artifacts from previous interrupted installs using a
  non-recursive whitelist that only removes regular files, while protecting the
  current source file, ordinary model receipt files, directories, and symbolic
  links. If the staged copy drifts after source verification, the installer
  must leave no destination model, and must clean temporary files before
  returning the error. If initial staged-model commit fails, the installer must
  leave no destination model or install receipt, and must clean temporary files
  before returning the error. If the final install receipt cannot be written after the model is
  committed, the installer must remove that committed model before
  surfacing the error, so startup resolution never leaves a large untrusted
  managed model behind. When
  replacing an existing managed model, the installer must keep a filesystem
  backup of the previous model and its install receipt with explicit renames
  until the new receipt is written, and restore that previous model/receipt pair
  if the staged-model commit or receipt writing fails. If the previous receipt
  cannot be moved into its backup path, the installer must restore the previous
  model and preserve the previous receipt in place. If the previous model cannot
  be moved into its backup path, the installer must preserve the previous model
  and receipt in place.
- The same installer owns `.mlpackage` and `.mlmodelc` companion packages. It
  recognizes packages with `recognizedCoreMLPackageMatch`, stages them beside
  the raw model under the manifest's safe relative package path, verifies the
  staged recursive tree digest, writes a
  `QixiNativeCoreMLPackageInstallReceiptStore` receipt, and excludes package
  directories and package receipts from iCloud backup. CoreML package temp and
  backup artifacts are directory-shaped, so they use the separate
  `cleanupOrphanedCoreMLPackageArtifacts` whitelist; ordinary model cleanup must
  still avoid recursively deleting directory-shaped `.tmp` or `.backup` names.
  If the staged CoreML package copy drifts after source verification, the
  installer must leave no package destination and must clean CoreML package
  temporary artifacts before returning the error.
  If initial staged-package commit fails, the installer must leave no package
  destination or package receipt, and must clean CoreML package temporary
  artifacts before returning the error.
  If initial package receipt writing fails after the staged package is committed,
  the installer must remove both the committed package directory and the failed
  receipt path before returning the error.
  CoreML package replacement uses the same backup-and-restore discipline as raw
  model replacement: if receipt backup, staged-package commit failure, or
  replacement receipt writing fails, the installer must restore the previous
  package directory and package receipt before returning the error.
  If the previous CoreML package cannot be moved into its backup path, the
  installer must preserve the previous package directory and package receipt in
  place.
- The SwiftUI import sheet must install user-selected `.bin`, `.bin.gz`,
  `.mlpackage`, and `.mlmodelc` packages through the `QixiNativeModelInstaller`
  manifest-recognition and verified-install APIs. It must not copy model files
  directly, guess by filename alone, or accept a file that does not match a
  manifest byte count plus SHA-256 digest or CoreML package tree digest.
- If the selected model package would replace the currently selected engine's
  managed model file, Swift must cancel analysis and unload the native engine
  with `setEngine(.none)` before committing the replacement. After a successful
  install it may reload the same engine, but a live engine must never continue
  across a model-file replacement.
- If that unload or replacement fails, Swift must not leave Hermes in `loading`
  or silently lose the user's previous engine selection. It must surface an
  engine error, restore the selected engine identity, and either retry loading
  the previous model when the unload already succeeded or show Hermes `offline`
  when the unload itself failed.
- `QixiNativeModelInstallReceipt` is the small startup-time proof that a managed
  model was installed through the strong verifier. The receipt stores the
  manifest identity plus the installed file byte count, modification time,
  device id, and file id from the opened file descriptor, so common
  same-size replacement or corruption after install invalidates the cheap
  startup proof without hashing hundreds of megabytes on every launch. This
  also rejects a same-size replacement whose mtime is restored to the previous
  value, because the file identity no longer matches the receipt.
  Install receipt JSON is itself part of the trust boundary. Both raw-model and
  CoreML-package receipt readers must first apply bounded strict object parsing
  with a 64 KiB limit, read at most `maxReceiptBytes + 1` through `FileHandle`
  without trusting the initial file-size check as the only memory guard, reject
  symbolic-link and non-regular receipt files before reading, recheck the opened
  descriptor with `fstat`, reject duplicate object keys, reject non-standard
  `NaN`/`Infinity` constants, reject non-object JSON and trailing data, and only
  then hand the already-validated bytes to `JSONDecoder`. This prevents
  parser-specific last-key-wins behavior, non-finite-number handling, or a
  directory/special-file replacement from deciding which managed model package is
  trusted at startup.
  `QixiNativeModelStore` requires a matching install receipt for trusted managed
  directories, so a manually dropped same-size file in
  `Application Support/Qixi/Models` is not accepted as a native model. Receipt
  directories and receipt files must also be excluded from iCloud backup; iCloud
  sync is for app state, not recoverable native model package metadata.
  `QixiNativeCoreMLPackageInstallReceiptStore` applies the same trusted managed
  directory rule to preconverted CoreML package directories. A trusted package
  whose recursive file count and byte count still match but whose tree digest no
  longer matches its receipt must make `QixiNativeModelStore` reject the raw
  model rather than silently loading an incompatible ANE/CoreML companion.
  Runtime model resolution must also clean stale installer-owned `.tmp`,
  `.backup`, and `.receipt-backup` artifacts in trusted managed directories
  before scanning candidates, and must clean stale CoreML package
  `.coreml-package-tmp`, `.coreml-package-backup`, and
  `.coreml-package-receipt-backup` artifacts in trusted package directories
  before accepting companion packages. That startup/engine-selection cleanup
  must not run against untrusted additional search directories, because those
  locations may belong to the user or a test fixture rather than the app's
  managed installer.

When `QIXI_ENABLE_NATIVE_KATAGO=0`, the bridge reports
`QixiNativeKataGoErrorLibraryNotLinked` for real engines. This is intentional
for Debug/Release diagnostics: native runtime must fail explicitly and must never silently fall back
to the Mac-hosted HTTP bridge. `NativeRelease` sets
`QIXI_ENABLE_NATIVE_KATAGO=1` and must be built with a validated iOS KataGo
artifact plus the matching Swift/Metal sidecar before it can be used for
physical-device `nativeInProcess` evidence.

## Production Adapter Contract

The production iOS adapter belongs in `QixiNativeKataGoEngine.cpp` behind the
existing `qixi::NativeKataGoEngine` interface. It embeds KataGo **only as a
neural-network evaluator**, not as a search engine, and not by launching a
process or tunneling through a text protocol.

### Search ownership (mandatory)

- **All product MCTS** (selection, expansion, backup, ownership aggregation,
  root switch, persistence) lives in **`core::MCTSStore`**, driven by
  `core::BackendWorker` inside `qixi::NativeKataGoCore`.
- The linked adapter must **not** construct `AsyncBot`, must **not** call
  `Search::runWholeSearch`, and must **not** use KataGo Search persistent-MCTS
  export/import (`exportPersistentMCTS` / `restorePersistentMCTSTombstone`).
- `analyzeRequest` on the linked engine is **disabled**. Swift UI analysis comes
  from `submitCoreRequest` / `latestCoreSnapshot` (core snapshots → existing UI
  fields). Residual `analyze()` on `NativeKataGoAnalysisService` maps a core
  snapshot into `AnalysisResponse` without touching KataGo Search.
- Lifecycle tombstones (`exportTombstoneToFile` / `restoreTombstoneFromFile` on
  `NativeKataGoCore`) export/import **core MCTS state** (`core-state.bin`
  semantics), not Search trees.

### NN initialization (KataGo)

The adapter must initialize KataGo in-process for **weights + eval only**:

- `Board::initHash` and `ScoreValue::initTables` during adapter/session startup.
- `ConfigParser`, `Setup::initializeSession`, `Setup::loadSingleParams`, and
  `Setup::initializeNNEvaluator` for model/config initialization.
- `NNEvaluator` lifecycle owned by the adapter, with shutdown on engine unload
  via `qixi::NativeKataGoEngine::unloadModel`.
- `LinkedCoreEvaluator` implements `core::Evaluator` by rebuilding a KataGo
  `Board`/`BoardHistory` from `core::BoardState` and calling
  `NNEvaluator::evaluate` (policy, value, score, ownership).
- `SearchParams` may be loaded only as **NN/misc input knobs** for that
  evaluator (e.g. utility factors, policy temperature)—not as a live Search.

The adapter must not use `MainCmds::analysis`. The adapter must not use `MainCmds::gtp`. It also must not use a spawned `katago` executable, `popen`,
`system`, `NSTask`, `Process`, `URLSession`, localhost, LAN URLs, the Python
backend, or GTP as the iOS native analysis path. Those are development and
Mac-hosted smoke-test tools only.

The adapter must convert Qixi's native JSON request into KataGo board state with
ordered move history intact. Two positions with the same stones but different
previous move order must remain distinct; same stones but different previous move order is not the same position. Swift `QixiPositionIdentity` and the
Mac-hosted backend `position_key` may serialize keys differently, but they must
produce the same equality partition over engine, rules, ordered history, komi,
and wide-root-noise settings. Both
`qixi-ios-sim/tests/test_backend_contract.py` and
`qixi-ios-native/tests/run_analysis_service_smoke.sh` must exercise
`tests/fixtures/position_identity_cases.json` so frontend and backend cache
identity cannot drift independently. That fixture must also declare and verify
`sameVisibleStones` for each relation, so the critical same-stones/different-history
cases cannot degrade into merely different visible-board examples. It must also
declare and verify `sameNextPlayer`, including the `ko-history-after-passes`
relation where visible stones and next player match but ko-context history
differs. The shared
fixture is first checked by `tests/validate_position_identity_fixture.py`, which
rejects duplicate JSON keys, `NaN`/`Infinity`, unknown relation targets, and
missing required same-visible/different-identity relations before either backend
uses it.

Product game state and root switching live in **`core::MCTSStore`** (ordered
move history, ko/superko, Chinese rules defaults). The NN adapter rebuilds a
KataGo `BoardHistory` only inside `LinkedCoreEvaluator` for leaf evaluation,
preserving enough history for the net (`maxHistory` / core move list)—not as a
second parallel Search tree.

UI-facing analysis (candidates, visits, winrate, score mean, ownership heatmap)
comes from **`core::RootSnapshot`** via `latestCoreSnapshot` / snapshot poll.
Ownership on the board is the **core MCTS aggregated ownership**, not a raw-only
NN map and not KataGo `Search::getAverageTreeOwnership`.

Persistent MCTS state is **core-owned**. `NativeKataGoCore::exportTombstoneToFile`
and `restoreTombstoneFromFile` export/import **core MCTS state** (same backend as
`exportCoreStateToFile` / `importCoreStateFromFile` / package `core-state.bin`).
They must **not** wrap KataGo `Search::exportPersistentMCTS`. No-engine
tombstones remain a lightweight JSON placeholder. Core export paths keep
bounded writes, atomic replace, and reject symbolic-link / directory-shaped
and non-regular final targets before replacement, bound the payload size, verify
the opened temporary descriptor's byte count after writing, and preserve the old
target if `rename` fails. Internal persistent-MCTS temporary files must never follow a symlink or overwrite a
non-regular lifecycle artifact.
`restoreTombstoneFromFile` (core import) must run only after Swift has resolved,
memory-gated, configured, and loaded the requested engine when analysis under
that model is required. Model/CoreML identity is enforced at `loadModel` /
manifest resolution time, not by re-validating a Search tombstone wrapper.

Before loading a real engine, switching to `none`, or attempting a different
real model, `NativeKataGoCore` must call `NativeKataGoEngine::unloadModel` and
clear its loaded engine identity. If unload fails, the core must return that
error, must not call `loadModel` for the next engine, and must answer later
analysis requests through the no-engine path rather than a stale adapter model.
This is a memory-safety contract as much as a correctness contract: b18nbt and
b28nbt cannot be allowed to remain resident merely because Swift's selected
engine changed.

## Required Invariants

- The native runtime must not use `URLSession`, localhost, LAN URLs, or the
  Python backend.
- HTTP bridge and native-in-process service implementations must stay in
  separate Swift files so static tests can prove the native path is not coupled
  to the Mac-hosted bridge.
- The Swift service contract remains `setEngine` plus core analysis
  (`submitCoreRequest` / `latestCoreSnapshot`); residual `analyze` maps a core
  snapshot and must not invoke KataGo Search.
- `BackendStatusResponse.engineId` is always the selected model identity
  (`none`, `b6`, `b18nbt`, or `b28nbt`) in both HTTP bridge and native-in-process
  services. Runtime identity belongs to `QixiAnalysisRuntime`; it must not be
  smuggled into `engineId` as values such as `native-in-process`.
- The native-in-process service must remain actor-isolated and expose only a
  `nonisolated` runtime property. A real KataGo adapter must not be callable
  concurrently through the Swift service, because engine switching and search
  analysis share bridge/core state.
- Native analysis requests must pass the native C++ request guard before the
  no-engine path or a real `NativeKataGoEngine` adapter receives them. The guard
  requires object JSON with `moves`, `maxVisits`, `komi`, and `rootNoise`, and
  accepts an optional `rules` string only when it is exactly `Chinese`.
  `maxVisits` must be an integer in `[1, 4096]`, `komi` must be finite in
  `[-150, 150]`, and `rootNoise` must be finite and nonnegative. Each move must
  have color `B` or `W`; pass moves must use `pass: true` without coordinates,
  while board moves must include both integer coordinates in `[0, 18]`. Request
  history must not reject repeated coordinates, because captures, ko, and
  longer game histories can legally revisit a point, but it must reject
  histories where replay proves a move played on an occupied point, suicide, or
  immediate simple-ko recapture. The parsed `NativeKataGoAnalysisRequest` must
  also expose `nextPlayer`, black for an empty history and otherwise the
  opposite color of the final ordered move. Product search applies those
  fields through **`core::MCTSStore`** mutations/roots, not `AsyncBot::setPosition`.
  `LinkedCoreEvaluator` rebuilds KataGo `Board`/`BoardHistory` only for NN
  leaf eval. Legacy request parsers may still expose `finalBoard` and
  `NativeKataGoRules` for validation; live analysis does not require
  `analyzeRequestJSON`.
- Residual `AnalysisResponse` shapes (if produced from a core snapshot) must
  still decode for any residual callers; the HTTP bridge path is Debug-only.
- Before Swift decodes native bridge output, `NativeKataGoBridgeResponseValidator`
  must reject duplicate JSON keys, `NaN`/`Infinity`, non-object JSON, and
  response bodies larger than 1 MiB. This keeps a malformed successful adapter
  response from relying on parser-specific last-key-wins behavior or excessive
  allocation before the shared `AnalysisResponse` validator runs.
- Real `NativeKataGoEngine` adapter responses must pass the native C++ response
  shape guard before the Objective-C++ bridge returns them to Swift. The guard
  requires object JSON with nonempty string `engine`, `state`, and
  `positionKey`, root `winrate` in `[0, 1]`, finite root `scoreMean`,
  nonnegative integer `visits`, array `moves`, and array `ownership`. Candidate
  moves must have board coordinates in `[0, 18]`, no duplicate coordinates,
  nonnegative integer visits, winrate in `[0, 1]`, and finite score mean.
  Ownership for a loaded real adapter must be exactly 361 finite values in
  `[-1, 1]`; only the explicit no-engine path may return empty ownership. A
  malformed successful adapter response must be converted to a deterministic
  invalid-request error instead of being surfaced to Swift.
- Swift native analysis must reject any response whose `engine` does not match
  the service's currently loaded `AnalysisEngine` before applying the shared
  semantic position key or caching analysis. This prevents a stale adapter model
  from being cached under the newly selected engine after model switches,
  tombstone restores, or failed reloads.
- The native no-engine core path must return a decodable `AnalysisResponse` with
  `engine = none`, zero visits, no moves, no ownership, and a stable
  `native-none:` raw core position key. Swift maps every native UI-visible
  response, including loaded real-adapter responses, to the shared semantic
  `QixiPositionIdentity` key so cache identity is always based on engine,
  ordered move history, komi, and wide-root-noise bits rather than adapter-owned
  hashes. This locks the Swift/ObjC++/C++ JSON response shape without pretending
  that real KataGo is linked.
- The native core and bridge must expose engine tombstone export/restore methods.
  The no-engine path must write and restore a tiny versioned tombstone JSON, and
  loaded real engines must delegate tombstone export/restore to the
  `NativeKataGoEngine` adapter without going through the Mac-hosted HTTP bridge.
- Lifecycle tombstones must record the native engine tombstone filename whenever
  the selected analysis service supports engine tombstones. Launch restore must
  try to restore that native engine tombstone before resuming analysis. The
  restore call must carry the selected `AnalysisEngine`; for a real engine the
  native service must resolve, memory-gate, configure, and load that engine
  before asking the bridge to restore the tombstone, so a cold-started core does
  not misroute a b6/b18nbt/b28nbt tombstone through the no-engine path. Once a
  tombstone restore succeeds, launch analysis must reuse the already loaded
  engine instead of loading the same model a second time. Engine tombstone export
  during lifecycle events must be wrapped in an iOS background task so the system
  gives the write a short completion window after background transition.
- Position identity must continue to include ordered move history, komi, root
  noise, and engine identity.
- If the native library is unavailable, selecting b6, b18nbt, or b28nbt must
  surface a deterministic unavailable error.
- If a real engine is selected before its model manifest is configured, the
  native core must return a deterministic invalid-request error.
- When switching from one real engine to another supported real engine, the
  native core must clear the previous loaded engine and call
  `NativeKataGoEngine::unloadModel` before validating the new model config or
  asking the adapter to load the new model. If unload fails, or if the config is
  missing or the adapter load fails, subsequent analysis must return the
  no-engine response instead of silently analyzing with a stale previously loaded
  model.
- When the UI switches to no engine, it must await `setEngine(.none)` instead
  of swallowing bridge errors. The UI may clear visible analysis immediately,
  but it must not report Hermes `ready` until the unload succeeds; unload
  failure must leave the selected engine as no-engine, surface an engine error,
  and show Hermes `offline` so a stale native engine cannot hide behind a
  ready-looking disabled-analysis state. The native Swift service must clear
  `currentEngine` to `none` before calling the bridge unload, so a failed unload
  still rejects stale b6/b18nbt/b28nbt adapter responses by engine mismatch.
- If the native adapter is not linked, Swift must surface `libraryNotLinked`
  before model resolution so an unlinked development build cannot masquerade as
  a merely missing-model build. Once the adapter is linked, if a real engine's
  model file cannot be resolved locally, Swift must surface a deterministic
  `modelMissing` error before calling the native loader.
- Swift native service must map bridge errors into typed
  `QixiNativeKataGoServiceError` values: `libraryNotLinked`, `modelMissing`, and
  `invalidRequest(message)`. Native invalid-request diagnostics must not be
  surfaced only as opaque `NSError` values.
- Before any Swift-side real-engine switch validation can throw, including
  `libraryNotLinked`, `modelMissing`, and `insufficientDeviceMemory`, the native
  service must clear its `currentEngine` to `none` and ask the bridge to load
  `none`. This keeps no-engine response `positionKey` mapping, local
  `modelMissing` failures, other local failure diagnostics, and C++
  loaded-engine state aligned.
- If real-engine tombstone restore fails after the model has been loaded, the
  native service must clear the loaded engine back to `none` before surfacing the
  restore error. A partially restored or stale tree must never remain available
  for analysis under the selected engine.
- The C++ `NativeKataGoCore` must also clear its loaded engine back to `none`
  and call `NativeKataGoEngine::unloadModel` when a real adapter tombstone
  restore returns an error, so a direct bridge/core caller cannot analyze with a
  partially restored or stale native tree while Swift is unwinding the failure,
  and so a failed restore does not leave a b6/b18nbt/b28nbt model resident under
  a no-engine logical state.
- Before delegating a real-engine tombstone restore to the adapter,
  `NativeKataGoCore` must verify that the source file is readable and non-empty
  and is a regular file within the bounded 256 MiB restore limit. Missing or empty restore sources, and any oversized restore source file, must clear the
  loaded engine back to `none`, call `NativeKataGoEngine::unloadModel`, and
  return `invalidRequest` without calling the adapter restore entrypoint, so an
  absent or corrupted lifecycle artifact cannot be mistaken for a restored
  search tree or leave the previously loaded model in memory.
  Directory or symbolic-link restore sources must be rejected the same way, so a
  non-regular lifecycle artifact cannot be mistaken for a restored search tree.
- When a real adapter tombstone export reports success, `NativeKataGoCore` must
  verify that the requested tombstone file is a readable non-empty regular file
  within the same bounded 256 MiB size before returning success to Objective-C++.
  Existing export paths that are directories or symbolic links must be rejected
  before the no-engine writer or real adapter can write, so a lifecycle save
  cannot overwrite a symlink target. A lifecycle save must never be marked as
  complete when the adapter returned `ok` but produced no recoverable file or
  produced a file that exceeds the bounded tombstone size.
- Model resolution must reject wrong-size or truncated model files before the
  bridge can load them. The local preflight must additionally compare SHA-256
  digests for b6, b18nbt, and b28nbt.
- Native service must apply `QixiNativeDeviceMemoryPolicy` after model
  resolution and before bridge loading. If the available physical memory after
  the system reserve is below the selected model's minimum memory budget, Swift
  must surface `QixiNativeKataGoServiceError.insufficientDeviceMemory` instead
  of calling the bridge.
- Strong SHA-256 verification belongs on model install/import/migration, not on
  every app launch, unless the user explicitly requests a repair check.
- Installing or importing a model must never write directly to the final model
  path. It must stage a temporary file in the managed model directory, verify the
  staged copy, exclude the staged file from iCloud backup, and only then replace
  or move it into place. Before staging, it must clean stale installer-owned
  `.tmp`, `.backup`, and `.receipt-backup` artifacts left by interrupted
  installs without deleting ordinary hidden receipt files, directory-shaped
  artifact names, symbolic links, or the current import source.
- Installing or importing a model must write a versioned install receipt after
  the verified file is committed. Startup model resolution for trusted managed
  directories must require byte-count match plus a receipt whose manifest fields
  and installed-file metadata fingerprint still match the current file,
  including device id and file id so restored-mtime same-size replacement
  is rejected cheaply. Receipt
  directories and files must be excluded from iCloud backup. Receipt-write failure
  must clean up a newly committed model file before the error returns, and must
  restore the previous model and receipt when the failure happens while replacing
  an existing managed model. Backup-stage failures must not delete a previous
  receipt that has not yet been moved.
- Runtime model resolution and engine selection must clean stale installer-owned
  artifacts only in trusted managed directories. They must preserve ordinary
  hidden receipt files, directory-shaped artifact names, and symbolic links, and
  must not clean untrusted additional search directories.
- The C++ core must reject model configs whose `modelPath` is empty, does not
  end with the configured resource name, or does not point to a readable
  non-empty model file that is a regular model file. Model paths must not be
  directories or symbolic links.
- The C++ core must reject nonempty `coreMLPackagePaths` entries that are empty,
  missing, files, empty directories, or symbolic links. Swift performs package
  tree-digest and receipt validation before this boundary; C++ still verifies
  that every path handed to the production adapter is a readable non-empty
  directory. The production adapter must also pass those paths into KataGo using
  `metalCoreMLPackagePathCount` and indexed `metalCoreMLPackagePathN` keys, and
  `metalbackend.cpp` must prefer `findExplicitPreconvertedModelPackage` so a
  verified package cannot be silently ignored by the ANE/CoreML mux path.
- Model memory budgets must be positive and ordered as minimum <= recommended
  <= maximum.
- The `.mm` bridge must only include the Qixi native bridge/core headers.
  KataGo-specific headers belong behind the `NativeKataGoEngine` implementation.
- The pure C++ core must remain separately compiled and smoke-tested so that
  engine lifecycle, request validation, and adapter delegation can be tested
  without SwiftUI.

## Verification

Run the focused bridge smoke:

```sh
qixi-ios-native/tests/run_analysis_service_smoke.sh
```

Run the native in-process integration contract preflight:

```sh
scripts/qixi-native-inprocess-contract-preflight.sh
```

This preflight also scans `QixiNativeKataGoEngine.cpp` itself for forbidden
shortcuts such as `MainCmds::analysis`, `MainCmds::gtp`, `popen`, `system`,
`NSTask`, `Process`, `URLSession`, localhost, and default backend URLs. The
production adapter must stay behind the in-process `qixi::NativeKataGoEngine`
interface instead of sneaking back to subprocess, GTP, or Mac-hosted bridge
paths.

Run the native KataGo adapter compile probe:

```sh
qixi-ios-native/tests/run_native_katago_adapter_compile_probe.sh
```

This compiles the `QIXI_ENABLE_NATIVE_KATAGO` gated implementation path in
`QixiNativeKataGoEngine.cpp` against the real KataGo headers. It checks that
`LinkedNativeKataGoEngine` initializes KataGo process tables, builds a
`Setup::initializeNNEvaluator` **NN-only** model lifecycle, and that
`LinkedCoreEvaluator` type-checks against `NNEvaluator::evaluate` +
`core::Evaluator`. It must **not** require `AsyncBot`, `runWholeSearch`, or
Search persistent-MCTS APIs. It does not link a model into the iOS app or prove
runtime iPad performance; it is a compile-time tripwire for NN API drift while
the default development build still uses the explicit placeholder engine.

The release linked-build preflight goes beyond checking that a path exists. A
`QIXI_KATAGO_IOS_XCFRAMEWORK` artifact must have an `Info.plist` with
`AvailableLibraries` containing an iOS device `arm64` slice, and that slice's
`LibraryIdentifier` plus `LibraryPath` must resolve to an existing library or
framework without traversing outside the XCFramework. Configured library and
XCFramework paths must not contain symbolic links, and source/plist reads are
bounded before loading. The resolved binary, and any raw
`QIXI_KATAGO_IOS_LIBRARY`, must be readable by `lipo` and `otool`, expose
`arm64`, and carry an iOS-device Mach-O platform marker such as
`LC_BUILD_VERSION platform 2` or `LC_VERSION_MIN_IPHONEOS`. When the raw library
is `libkatago_core.a`, `QIXI_KATAGO_IOS_LIBRARY_DIR` must also contain the
matching `libKataGoSwift.a` sidecar with Swift/Metal/CoreML/MPSGraph symbols.
Empty directories, simulator-only XCFrameworks, macOS arm64 archives, symlinked artifacts,
escaped slice paths, missing sidecars, and host-only files must fail
before any App Store readiness claim.

Run the native model package preflight:

```sh
scripts/qixi-native-model-preflight.sh
```

This verifies that `QixiNativeModelRegistry` matches the local b6, b18nbt, and
b28nbt files, that memory budgets remain ordered, and that the Xcode project has
not accidentally bundled large model files without an explicit packaging plan.
The preflight rejects symbolic links in source and model paths, reads source and
manifest files only through bounded byte loads, checks each model against a
bounded maximum before hashing, and then hashes models in fixed-size streaming
chunks. It is therefore a trust-boundary gate as well as a manifest drift check.

Run the default gate:

```sh
scripts/qixi-quality-gate.sh
```

Before replacing the placeholder bridge with real KataGo calls, also run:

```sh
QIXI_RUN_REAL_MODELS=1 scripts/qixi-quality-gate.sh
```

The native adapter compile probe also pins the Qixi response boundary: the
adapter must map `Search::getAnalysisJson` root and candidate-move fields into
the Swift-visible analysis response, and its ownership array must come from
`Search::getAverageTreeOwnership` so territory overlays use the current root's
MCTS+NN tree average rather than raw neural-network ownership.

After the real iOS library exists, add a real-device native-in-process gate that
runs with:

```text
QIXI_ANALYSIS_RUNTIME=nativeInProcess
```

That gate must record device model, iOS version, memory, launch time, background
restore behavior, and at least one b6/b18nbt/b28nbt analysis result.
