# Qixi Project Handoff for Grok 4.5

Last updated: 2026-07-10

This document describes the repository as it exists in the local working tree. It is
intended to let a new model continue the work without reconstructing months of design
discussion or mistaking partial verification for production readiness.

## 1. Executive Summary

Qixi is a native SwiftUI iPhone/iPad Go analysis application. Its intended product
architecture is fully local: the UI, persistent MCTS state, KataGo neural-network
evaluation, Metal mux/CoreML execution, SGF handling, photo recognition, and iCloud
document coordination all run on the Apple device.

The current branch contains a substantial but uncommitted integration of a new C++17
persistent MCTS core into the Swift application. The new core has deterministic unit and
invariant tests, a strict FIFO backend worker, history-sensitive positions, root
switching, multi-configuration stores, and binary export/import. The Swift layer has
been changed to serialize backend mutations, apply legal moves optimistically, poll
read-only snapshots, block interaction during critical transitions, and include the
new core state in `.qixi-mcts` document packages.

The project is **not yet correctness-complete or release-ready**. In particular:

- The new MCTS search policy is a custom PUCT implementation, not an exact copy of
  official KataGo Search.
- There is no oracle test proving that it produces the same result as official KataGo
  for identical models, roots, seeds, and playout counts.
- Real Metal mux inference with b6, b18nbt, and b28nbt has not been validated on a
  physical iPad in the latest verification run.
- Background termination, memory pressure, real iCloud behavior, and long-running
  search still need physical-device testing.
- The current implementation is present only in a dirty working tree. It must be
  reviewed and committed deliberately before broad refactoring.

Current status by area:

| Area | Status | Confidence |
| --- | --- | --- |
| Custom persistent MCTS data model | Implemented | Unit/invariant tested |
| Root-switch ancestor isolation | Implemented | Focused C++ tests pass |
| FIFO mutation serialization | Implemented in C++ and Swift | Focused tests pass |
| MCTS state export/import | Implemented, including multi-store bundles | Round-trip and corruption tests pass |
| SwiftUI integration | Implemented in the dirty tree | Simulator build/launch tested |
| Metal mux evaluator bridge | Implemented | Compile/link tested; device inference pending |
| Official KataGo result equivalence | Not implemented | Blocking correctness gap |
| Physical-device lifecycle and memory validation | Not completed | Blocking release gap |
| Real iCloud multi-device validation | Not completed | Simulator/local tests only |
| Photo recognition | Implemented with crop selection and Imago-inspired classification | Synthetic tests only; real-photo acceptance remains open |

## 2. Repository and Git State

Primary repository:

- Local path: `/Users/zyx/Desktop/projects/Qixi`
- Branch: `main`
- Remote: `https://github.com/Zyxxx-xxxyZ/Qixi.git`
- The working tree is dirty and the current integration has not been committed.
- `core/` is currently untracked. It contains the new persistent MCTS implementation
  and must not be lost during cleanup, rebasing, or branch changes.

Tracked modifications currently span the following areas:

- `docs/` verification rules
- `qixi-ios-native/Qixi.xcodeproj`
- SwiftUI board, root view, utility sheets, localization, persistence, view model, and
  analysis service files
- Objective-C++/C++ native bridge, core adapter, and KataGo engine adapter files
- Native and Swift smoke tests
- Project quality-contract tests

Before this handoff document was added, the tracked diff contained approximately 2,940
insertions and 346 deletions across 29 files. That count excludes the untracked `core/`
directory.

Two scripts are deleted in the current working tree:

- `scripts/qixi-persistent-mcts-audit.sh`
- `scripts/qixi_persistent_mcts_architecture_audit.py`

Those deletions predate this handoff. Do not restore them automatically or use a blanket
reset. First determine whether their deletion is intentional in the user's current
working state.

The KataGo submodule is clean:

- Path: `KataGo/`
- Branch: `codex/persistent-mcts-export-import`
- HEAD: `e358643c84e7c7182108ae129dc8dce429024eb1`
- Previous feature commit: `394bb035 Add persistent MCTS export/import support`
- Upstream comparison base: `9c38e44d` from `lightvector/KataGo`
- Fork remote: `https://github.com/Zyxxx-xxxyZ/KataGo.git`
- Upstream remote: `https://github.com/lightvector/KataGo.git`

Relative to the upstream base, the submodule changes roughly 30 files with 4,416
insertions and 151 deletions. Those changes include Metal/CoreML work, Metal mux fixes,
official-Search persistence/tombstone code, tests, and documentation.

No credential or GitHub token should be written into source, documentation, shell
history, or a commit. Treat any credential previously pasted into conversation as
compromised and out of scope for this handoff.

## 3. Product Requirements That Drive the Architecture

The backend is expected to satisfy all of the following:

1. A model is loaded once and remains resident while selected.
2. A search tree is long-lived rather than reconstructed for each UI refresh batch.
3. Switching the root is a lightweight view change and does not delete unrelated
   persistent nodes.
4. Search performed from an ancestor may contribute information to descendants.
5. Search performed with a descendant as root must not back up into that descendant's
   ancestors.
6. Returning to an earlier root must not suddenly add descendant-root visits to the
   earlier root's outgoing move distribution.
7. The same visible stones do not necessarily identify the same position. Ordered move
   history, next player, ko/superko context, rules, komi, root-noise setting, and model
   identity matter.
8. Analysis state must be exportable, importable, autosaved, and recoverable after
   background termination.
9. Engine/model/settings analysis must remain partitioned. Results from b6, b18nbt,
   b28nbt, different komi, or different wide-root-noise values must not mix.
10. Backend mutations must be linearized even if the user taps rapidly, changes engine,
    imports data, backgrounds the app, and immediately foregrounds it.
11. The UI should respond immediately to a legal move, but the corresponding backend
    mutation may wait in FIFO order.
12. Illegal moves must be rejected in the frontend before they appear, while the backend
    independently validates them as a safety boundary.

The new `core/` implementation was built around these requirements. Passing its tests
does not by itself prove equivalence to standard KataGo search.

## 4. Runtime Architecture

The new integrated path is:

```text
SwiftUI views
    |
    v
QixiViewModel on the main actor
    |  optimistic board changes + Swift FIFO mutation queue
    v
QixiCoreBackendService / QixiNativeKataGoAnalysisService actor
    |
    v
Objective-C++ bridge (QixiNativeKataGoBridge)
    |
    v
QixiNativeKataGoCore
    |
    v
qixi::core::BackendWorker (one serialized worker thread)
    |
    +--> qixi::core::MCTSStore (persistent nodes, actions, arenas, root)
    |
    +--> LinkedCoreEvaluator
             |
             v
         KataGo NNEvaluator
             |
             v
         Metal mux / CoreML backend on physical Apple hardware
```

Platform-owned work remains outside the C++ core:

- Swift SGF parsing and variation-tree presentation
- PhotosPicker, image decoding, crop selection, and board recognition
- iCloud document coordination and conflict/fallback behavior
- SwiftUI lifecycle overlays and user-interaction blocking
- App snapshots and package manifests

These platform operations eventually submit concrete core mutations or checkpoint
requests through the same serialized application flow.

## 5. Two Different Persistent Search Implementations Exist

This distinction is critical.

### 5.1 Modified KataGo Search in the submodule

The `KataGo/` submodule contains an older persistence/tombstone implementation built by
modifying KataGo's official `Search` and `SearchNode` code. It adds persistent MCTS
export/import behavior and related tests. The legacy native API still uses this route for
legacy `analyze()` and native tombstone operations.

`LinkedNativeKataGoEngine::loadModel` still constructs an `AsyncBot`, and the engine
object retains it. This means official-derived Search machinery can still consume memory
even when the new custom core only needs the shared neural-network evaluator.

### 5.2 New custom C++ core

The untracked `core/` directory contains a separate C++17 MCTS and request worker. The
new Swift `QixiCoreBackendService` integration is wired to this core. It shares KataGo's
`NNEvaluator` through `LinkedCoreEvaluator`, but its tree, selection, backup, snapshots,
and persistence format are Qixi-specific.

Do not describe the custom core as "official KataGo Search with persistence." It is not.
Do not delete the legacy path until its remaining fallback and tombstone responsibilities
are understood and corresponding device tests exist.

## 6. Custom Core Data Model

The implementation lives under `core/` and builds as C++17.

### 6.1 Fixed constants and supported domain

- Board size: fixed 19x19
- Board points: 361
- Pass move index: 361
- Policy move count: 362, including pass
- Ownership dimensions: 361 floats
- Neural-network history limit passed by the native adapter: 5
- Search thread count: 1
- Backend request queue maximum: 512
- Optimistic pending-move limit: 128
- Snapshot target: 120 frames per second
- Autosave interval: 1,200 seconds
- Persistence writer version: 3
- Minimum readable persistence version: 2
- Core-state file limit: 512 MiB

The five-move neural-network history limit is not the position identity. Full ordered
move history and board/situation hash history are retained for lineage identity and
legality. Two positions with identical stones but different histories remain distinct.

### 6.2 Node and action ownership

Each `Node` stores one copy of node-local state:

- Stable `NodeId`
- Parent node and move from parent
- Player who made the move and next player
- Ply/depth
- Expansion state
- Policy-arena offset
- First action and action count
- Ancestor-arena offset and count
- Visit count and float scalar statistics
- Aggregated ownership-arena offset
- History-sensitive lineage hash

Each `Action` is parent-local and represents one `(parent node, move)` relationship. It
stores the child node, visits, and float scalar statistics. A parent's child selection
uses these parent-local action statistics. Descendant-root search therefore cannot
silently inflate an ancestor's outgoing action visits.

The store owns contiguous arenas:

- `policyArena`: 362 floats for every expanded node
- `ownershipArena`: 361 floats for every visited node with ownership
- `ancestorArena`: contiguous `NodeId` entries for each node's ancestor chain
- `visible`: one byte per node indicating whether it belongs in the UI tree

An `unordered_map` indexes `(parent, move)` to child. A second visible-lineage index
supports UI root references.

Ancestor membership is checked from the contiguous ancestor pool using depth rather
than repeatedly following parent pointers. This gives constant-time membership after
the node has been built, at the cost of storing one ancestor ID per depth per node.

### 6.3 Statistics and neural-network payloads

`LeafPayload`, `ScalarStats`, policy, and ownership all use `float`. The implementation
does not quantize ownership. A visited node stores its aggregated ownership as a running
weighted mean, and scalar statistics are updated during backup.

The custom core does not maintain a separate MCTS or NN-output cache. An unexpanded node
is evaluated once, and its policy/value/score/ownership output is stored on that node.
`LinkedCoreEvaluator` calls KataGo `NNEvaluator::evaluate` with `skipCache=true` and
`includeOwnerMap=true`.

The root snapshot reports:

- Root ID, lineage hash, visits, win rate, and score mean
- Candidate moves with prior, visits, win rate, score, and utility
- Visible variation-tree nodes
- Aggregated MCTS ownership for the current root

Tree-node color quality is derived from the parent's action statistics. It is not read
from the child's root statistics. Unanalyzed visible nodes have no quality delta and are
presented as unanalyzed by the UI.

### 6.4 Root switching and backup boundary

`MCTSStore::switchRoot` changes the active root and materializes its board state. It does
not delete the old root, siblings, or descendants.

Every playout starts at the current root. Its path contains only nodes and actions
selected at or below that root. Backup iterates only that path and stops at the current
root. Therefore, if A is an ancestor of B:

1. Search rooted at A may update A's action toward B and may update B and its subtree.
2. Search rooted at B updates B and nodes/actions below B.
3. It does not update A or A's action toward B.
4. Switching back to A immediately preserves A's old outgoing visit distribution.
5. B's own local distribution remains available if a later A-root playout reaches B.

Point 5 is deliberate in the current design: node-local statistics are treated as
root-independent once legally accumulated without crossing the active root boundary.
An official-KataGo oracle test is still required to prove that this reuse produces the
desired full-search behavior for arbitrary root sequences.

The current root board is materialized by walking/replaying lineage from the initial
position. Depth is bounded in practice, but this has not yet been profiled against a
checkpointed materialization strategy.

### 6.5 Search policy

The custom core currently implements a simplified PUCT policy with configurable:

- `cpuct`
- FPU value
- Wide-root noise and noise weight
- Win/loss and score utility factors
- Deterministic seed

It does not reproduce every official KataGo search heuristic, RNG draw, score utility
update, dynamic score center, rules encore phase, or dead-stone behavior. This is the
largest current correctness risk.

## 7. Serialized Request Processing

`qixi::core::BackendWorker` owns one worker thread, one queue, and one mutable backend
context. State-mutating requests run in FIFO order. Background playouts occur only while
the request queue is empty. Successful playouts continue without an artificial 1 ms
sleep; the worker waits only when it cannot search or has work to process.

The core request vocabulary is:

- Boot
- Configure iCloud
- Import SGF
- Select engine
- Export analysis state
- Enter background
- Enter foreground
- Autosave tick
- Set komi
- Set wide-root noise
- New game
- Play move
- Undo / redo
- Jump to node / line point
- Set territory mode
- Import analysis state
- Export SGF
- Recognize photo
- Apply recognized board
- iCloud sync now

Raw SGF import/export and raw photo recognition deliberately fail closed in the C++
library because parsing and image work are platform responsibilities. Swift parses or
recognizes first, then submits concrete board, move, or state requests.

Each frontend request includes a request ID, monotonic sequence, expected backend epoch,
kind, and typed payload. Results include the resulting epoch, revision, engine/store
state, optional committed UI intent, and optional snapshot.

Epochs invalidate stale commands after operations that replace the logical backend
state, such as model/settings store changes, imports, or a new game. Revisions track
committed mutations. `UiIntentId` allows optimistic Swift moves to refer to parents that
have not yet received a concrete native `NodeId`.

The Swift `QixiViewModel` adds a second application-level FIFO around native calls. A
legal tap changes the visible board immediately, then queues the backend mutation. If a
mutation fails, queued dependent mutations are abandoned and the latest committed
snapshot is reapplied. Engine selection uses the same serialized path.

Critical transitions expose a blocking SwiftUI overlay. Boot/restore, engine switching,
state import/export, model installation, and similar barriers prevent conflicting user
operations even though ordinary legal moves remain optimistically responsive.

## 8. Model and Settings Partitioning

Persistent stores are keyed by:

- Game ID
- Model ID
- Rules hash
- Canonical komi key
- Canonical wide-root-noise key

Changing model, komi, or wide-root noise checkpoints the active store and switches to a
matching existing store or creates a separate one. Statistics are not copied between
keys. Returning to a previously used key restores that key's store.

Selecting `none` unloads analysis but preserves the current visible analysis and stored
state. Selecting another real model switches to that model's independent store. This
matches the product requirement that "no engine" must not erase analysis, while loading
a different engine must not display the previous engine's statistics as current.

## 9. Persistence, Tombstones, and iCloud

### 9.1 Core persistence

`MCTSStore` has a versioned binary serializer with structural and numeric validation.
Validation includes:

- Finite/range checks
- Node/action ownership and index bounds
- Arena offset ownership, gaps, and aliasing checks
- Action-list consistency
- Lineage and root validity
- Full current-root materialization matching the serialized board and history

The core can export one store or a multi-store bundle. Bundle export gathers stores for
the current game across model/komi/noise keys. Bundle import validates all entries and
all destination collisions before writing. The active-store index is the final commit
point; failed installation attempts remove newly written entries.

Writes use atomic replacement. Input and output are bounded to 512 MiB. The serializer
still builds a complete byte vector in memory, so export/import peak memory can be much
higher than steady-state tree memory.

### 9.2 App document package

The Swift document package extension is `.qixi-mcts`, with content type
`com.zyx.qixi.mcts-state`. A package can contain:

- `manifest.json`
- The Swift app snapshot
- `core-state.bin` for the new custom core
- An optional legacy native-engine tombstone

Import validates package shape, manifest/snapshot agreement, regular files, symlink
boundaries, and size limits before committing backend state. The core is quiesced before
replacement and the selected engine/settings are restored afterward.

### 9.3 Lifecycle behavior

- Entering the background queues a core checkpoint.
- A Swift app snapshot is saved synchronously first so there is a recoverable UI state
  even if iOS suspends work quickly.
- A lifecycle tombstone and native/core state are maintained for restoration.
- A periodic autosave request is scheduled every 20 minutes.
- Creating a new game archives meaningful current MCTS state before reset.
- Launch and foreground restoration use a blocking progress overlay.

These paths have deterministic tests, but true iOS suspension/termination timing and
memory-pressure behavior have not been proven on a physical device.

### 9.4 iCloud behavior

iCloud coordination remains in Swift. Manual sync checkpoints the core, builds the
visible `.qixi-mcts` package, and mirrors it through the platform sync store. A local
fallback directory must not be presented or persisted as successful iCloud enablement.

The previous user-visible symptom was that analysis archives did not appear in the
iCloud document picker after starting a new game. The current dirty changes add explicit
package mirroring/archiving, but this has not yet been verified with a signed app, a real
iCloud account, and multiple devices. Treat the fix as implemented but device-unverified.

## 10. Native KataGo and Model Loading

The native model registry currently defines:

| Model | Expected bytes | SHA-256 | Min / recommended / max memory budget |
| --- | ---: | --- | --- |
| b6 | 3,827,339 | `f5d32604e3675c480c7c8f6aa579a1ea857135628a0afccc8fa56330fbacd38d` | 256 / 512 / 768 MiB |
| b18nbt | 105,532,578 | `46a623a366ef6ef423fa2055f1b094fd8f64c518c065e7d254a9e0829c192c5c` | 1024 / 1536 / 2048 MiB |
| b28nbt | 291,771,656 | `053d2411c311b5cb8f44d9960e431371460169561401ea35088a030b87337770` | 2048 / 3072 / 4096 MiB |

The b6 file is present under KataGo's test models. Local b18nbt and b28nbt `.bin` files
exist in the project directory but root-level `*.bin` model files are ignored and should
not be assumed to exist in a fresh clone.

Models are resolved from the bundle, configured search directories, or Application
Support under `Qixi/Models`. File size, SHA-256, optional CoreML package tree digest, and
trusted install receipts are checked before use.

Native configuration sets `numSearchThreads=1`. This was a deliberate stability choice
for the current persistent-search integration.

`LinkedCoreEvaluator` reconstructs KataGo `Board` and `BoardHistory`, sets the adapter's
maximum NN history to five moves, asks for ownership, and maps KataGo policy/value/score
output into `LeafPayload`.

On the iOS Simulator, selected real models fail closed before entering MPSGraph. This
guard exists because the simulator framework raised an uncaught device-construction
exception when a real b6 model was injected. The simulator is useful for SwiftUI,
bridge, persistence, and linked-binary smoke tests, but not as evidence of working Metal
mux inference. Real model inference must be tested on physical hardware.

## 11. SwiftUI and Platform Status

The current app is native SwiftUI, not a web wrapper. The existing surface includes the
board, live candidate overlays, MCTS ownership heatmap, move controls, line chart,
variation tree, model selector, komi/root-noise controls, photo import, SGF/state import,
iCloud sync, and new-game handling.

Relevant integration changes include:

- Frontend legality and the C++ backend legality path are cross-checked.
- Recognized boards are applied as setup stones with no invented move order.
- Applying a recognized board clears move/hash history and starts a new setup position.
- PhotosPicker uses file transfer and URL-based bounded ImageIO decoding rather than
  loading the complete compressed image with `Data(contentsOf:)`.
- The photo UI supports selecting a board quadrilateral before recognition.
- The classifier contains an Imago-inspired intersection clustering port; it is not a
  direct dependency on the complete upstream Imago application.
- Snapshot polling is approximately 120 Hz and is read-only; it does not restart search.
- Visible candidate and tree values are refreshed from core snapshots.
- Chart points only exist where cached analysis exists.
- Jumping through chart/tree controls submits a root change so board, tree, chart, and
  heatmap can follow the same position.

Synthetic recognition tests pass for generated empty, standard, dimmed, dense, padded,
rotated, perspective, glare, large, and EXIF-oriented images. The four difficult laptop
screen photos supplied earlier are not present in the repository test fixtures and were
not revalidated in the final run. Do not claim stable real-photo acceptance yet.

The most recent NativeRelease simulator screenshot check found a 19x19 grid and a
maximum stone-center error of 0.87 px. This proves basic rendered geometry for that
fixture, not full visual acceptance on every iPad/iPhone size.

## 12. Verification Completed on the Current Integration

The following evidence was completed during the final local verification before this
handoff document. Rerun it after any substantive edit.

### 12.1 Custom core

- Normal CTest: 3 of 3 tests passed, approximately 11.8 seconds.
- AddressSanitizer + UndefinedBehaviorSanitizer CTest: 3 of 3 tests passed,
  approximately 33.5 seconds.
- Tests cover legality, capture/ko history, root-switch isolation, persistence round
  trips, corrupt-import rejection, bundle collision behavior, FIFO optimistic move
  chaining, store partitioning, and engine-switch failure recovery.

### 12.2 Project/static contracts

- Combined Python verification: 123 tests passed.
- The same run reported 100 nested subtests passed.
- Many of these are source/contract tests. They are valuable regression guards but are
  not substitutes for running the actual engine on device.

### 12.3 Focused native/Swift smoke tests

- Board-recognition smoke passed.
- Analysis-service smoke passed.
- Swift/C++ board-legality crosscheck passed.
- Persistence and iCloud smoke passed in the controlled test environment.
- SGF parser smoke passed.
- Variation-tree layout smoke passed.

### 12.4 Apple build and launch evidence

- Debug iOS Simulator `xcodebuild` passed.
- NativeRelease simulator smoke passed after building and linking simulator-arm64
  `libkatago_core.a` and `libKataGoSwift.a`.
- The NativeRelease app installed and launched in the simulator and survived the launch
  check.
- Injecting the real b6 model confirmed the new simulator guard: the process stayed alive
  and displayed an explicit offline error instead of crashing in MPSGraph.
- No real model inference was performed in the simulator, by design.

### 12.5 Repository hygiene

- `git diff --check` passed before this document was added.
- No `TODO`, `FIXME`, or placeholder handler remained in `core/`; platform-owned raw SGF
  and photo handlers reject explicitly.

## 13. What Has Not Been Proven

The following are open correctness or release blockers:

1. **Official KataGo oracle equivalence.** There is no harness that loads the same model
   into official Search and the custom store, aligns all random seeds, executes arbitrary
   root sequences, matches effective inherited visit counts, and compares candidate
   distributions, root win rate, score, and MCTS ownership.
2. **Exact search semantics.** Simplified custom PUCT can diverge materially from KataGo
   even when persistence invariants are correct.
3. **Mathematical proof.** There is no Lean proof. Existing tests demonstrate selected
   invariants, not universal equivalence over all trees and root-switch sequences.
4. **Physical-device inference.** b6/b18nbt/b28nbt model load, Metal mux CPU+GPU behavior,
   sustained search, and model switching remain unverified in the latest build.
5. **Lifecycle/tombstone stress.** Rapid foreground/background transitions, suspension,
   force termination, and restoration under real iOS deadlines remain unverified.
6. **Memory pressure.** No current long-duration Instruments trace proves that the new
   store, old AsyncBot, model, snapshots, and export buffers fit safely on target iPads.
7. **Real iCloud.** Signed-device document visibility, account availability, conflict
   reconciliation, and multi-device sync remain unverified.
8. **Real-photo recognition.** Synthetic coverage does not establish stable recognition
   of the four previously supplied photographs or arbitrary perspective/glare cases.
9. **Full visual review.** Simulator smoke does not satisfy the user's five-minute manual
   acceptance criterion across iPad and iPhone hardware.

## 14. Performance and Memory Risks

The implementation avoids rebuilding the full MCTS for every UI batch, but it still has
important costs:

- Every expanded node stores 362 policy floats, about 1,448 bytes.
- Every ownership-bearing visited node stores 361 ownership floats, about 1,444 bytes.
- Every node stores its complete ancestor sequence in the contiguous ancestor arena.
  This is O(node count times average depth), bounded by Go game depth but significant.
- `unordered_map` child and lineage indexes add substantial allocator/hash overhead.
- The old `AsyncBot` may remain allocated beside the custom core.
- Serialization creates a complete byte vector before writing, and multi-store export
  may hold multiple encoded stores. The 512 MiB file cap does not cap transient process
  memory to 512 MiB.
- Snapshot data is copied through a JSON bridge at up to 120 Hz.
- The core state mutex currently spans search work, including NN evaluation, so a slow
  evaluation can delay snapshot reads and queued mutations.

Before optimizing, establish correctness baselines and capture physical-device memory
traces. Avoid replacing these costs with caches or duplicated statistics that make root
semantics harder to reason about.

## 15. Recommended Takeover Order

The safest continuation sequence is:

1. Preserve the dirty tree on a dedicated `codex/` branch or an explicit reviewed
   checkpoint commit. Do not use a destructive reset.
2. Rerun the existing normal and sanitizer core tests and the project contract suite.
3. Build an official KataGo oracle harness before changing the search algorithm.
4. The oracle must use the same model, rules, komi, root noise, seed, initial history,
   playout count, and arbitrary root sequence for both implementations.
5. At each root, compare candidate visits/distribution, root win rate, score mean, and
   361-point MCTS ownership using `atol=1e-4`, `rtol=1e-3` unless exact equality is
   available.
6. Include export, process-memory clearing, import, and continuation at several points in
   every generated root sequence.
7. Only after the oracle exists, decide whether to make the custom policy match official
   Search or replace more of it with reusable upstream KataGo selection/backup code.
8. Run b6 first on a physical iPad, then b18nbt and b28nbt according to device memory.
9. Capture Instruments memory/CPU traces for long searches, root switching, state export,
   background checkpoints, engine switching, and restore.
10. Validate signed iCloud import/export on real accounts and confirm `.qixi-mcts`
    packages are visible after analysis and after New Game.
11. Add the four real photos as opt-in local test fixtures if licensing/privacy permits,
    and record expected stone sets rather than synthetic move histories.
12. Remove the legacy `AsyncBot` allocation only after proving no required fallback or
    tombstone API depends on it.
13. Perform iPad and iPhone screenshot/manual review after backend correctness and
    device stability are established.

## 16. Reproduction Commands

Run these from the repository root.

### 16.1 Core build and tests

```sh
cmake -S core -B /private/tmp/qixi_core_build
cmake --build /private/tmp/qixi_core_build --parallel
ctest --test-dir /private/tmp/qixi_core_build --output-on-failure
```

### 16.2 Sanitizer build and tests

```sh
cmake -S core -B /private/tmp/qixi_core_sanitized \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer'
cmake --build /private/tmp/qixi_core_sanitized --parallel
ctest --test-dir /private/tmp/qixi_core_sanitized --output-on-failure
```

### 16.3 Focused project contracts

```sh
/Users/zyx/.hermes/hermes-agent/venv/bin/python3 -m pytest \
  qixi-ios-native/tests/test_frontend_contract.py \
  qixi-ios-native/tests/test_localization_contract.py \
  qixi-ios-native/tests/test_protected_build_marker.py \
  tests/test_project_quality_contract.py \
  tests/test_changed_surface_gate.py -q
```

### 16.4 Debug simulator build

```sh
/usr/bin/xcodebuild -quiet \
  -project qixi-ios-native/Qixi.xcodeproj \
  -scheme Qixi \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/qixi-debug-final-derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

### 16.5 NativeRelease simulator smoke

```sh
env PATH=/Users/zyx/.hermes/hermes-agent/venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  qixi-ios-native/scripts/native-release-sim-smoke.sh
```

### 16.6 Focused Swift/native smokes

```sh
qixi-ios-native/tests/run_analysis_service_smoke.sh
qixi-ios-native/tests/run_board_legality_crosscheck.sh
qixi-ios-native/tests/run_persistence_sync_smoke.sh
qixi-ios-native/tests/run_sgf_parser_smoke.sh
qixi-ios-native/tests/run_variation_tree_layout_smoke.sh
```

The recognition smoke may need the Hermes Python/Pillow environment on `PATH`:

```sh
env PATH=/Users/zyx/.hermes/hermes-agent/venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  qixi-ios-native/tests/run_board_recognition_smoke.sh
```

## 17. Key Files

New custom core:

- `core/include/qixi/core_types.hpp`
- `core/include/qixi/board.hpp`
- `core/include/qixi/mcts.hpp`
- `core/include/qixi/request_pool.hpp`
- `core/src/board.cpp`
- `core/src/mcts.cpp`
- `core/src/request_pool.cpp`
- `core/tests/qixi_core_invariants.cpp`
- `core/tests/qixi_core_smoke.cpp`
- `core/tests/qixi_core_store_bundle.cpp`

Native integration:

- `qixi-ios-native/Qixi/QixiNativeKataGoEngine.cpp`
- `qixi-ios-native/Qixi/QixiNativeKataGoCore.hpp`
- `qixi-ios-native/Qixi/QixiNativeKataGoCore.cpp`
- `qixi-ios-native/Qixi/QixiNativeKataGoBridge.h`
- `qixi-ios-native/Qixi/QixiNativeKataGoBridge.mm`
- `qixi-ios-native/Qixi/QixiNativeKataGoAnalysisService.swift`
- `qixi-ios-native/Qixi/QixiAnalysisService.swift`

Swift state, persistence, and UI:

- `qixi-ios-native/Qixi/QixiViewModel.swift`
- `qixi-ios-native/Qixi/QixiPersistence.swift`
- `qixi-ios-native/Qixi/RootView.swift`
- `qixi-ios-native/Qixi/BoardView.swift`
- `qixi-ios-native/Qixi/QixiUtilitySheets.swift`
- `qixi-ios-native/Qixi/QixiBoardImageRecognizer.swift`
- `qixi-ios-native/Qixi/QixiNativeModelRegistry.swift`

Modified KataGo persistence and Metal path:

- `KataGo/cpp/search/search.cpp`
- `KataGo/cpp/search/search.h`
- `KataGo/cpp/search/searchnode.cpp`
- `KataGo/cpp/search/searchnode.h`
- `KataGo/cpp/neuralnet/metalbackend.cpp`
- `KataGo/cpp/neuralnet/metalbackend.swift`
- `KataGo/cpp/neuralnet/metallayers.swift`
- `KataGo/docs/persistent-mcts.md`

Verification documentation:

- `docs/quality-gates.md`
- `docs/pr-verification-matrix.md`
- `docs/native-ios-runbook.md`
- `docs/native-katago-integration.md`

## 18. Handoff Guardrails

- Do not claim official KataGo equivalence until an oracle test proves it.
- Do not use simulator launch success as evidence of Metal mux inference.
- Do not collapse position identity to board stones or the last five moves.
- Do not let descendant-root backup update ancestor nodes or ancestor actions.
- Do not add a generic MCTS cache or duplicate node statistics to hide performance
  problems.
- Do not parallelize state writes, store release, model switching, import, or lifecycle
  checkpoint operations outside the FIFO without a new ownership proof and stress tests.
- Do not synthesize move history from a recognized still image.
- Do not mix model, komi, or root-noise stores.
- Do not restore or discard unrelated dirty-tree changes without inspecting them.
- Do not commit local model binaries or credentials.

The next implementation milestone should be the official-KataGo equivalence harness,
followed by physical-iPad inference and memory/lifecycle evidence. Until those exist,
the honest project classification is: **well-integrated prototype with tested persistence
invariants, but incomplete search-equivalence and device-release validation**.
