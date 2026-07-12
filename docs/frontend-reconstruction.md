# Frontend reconstruction (in progress)

Last updated: 2026-07-12

## Kept

- **Main page UI design only**: split analysis workbench (chart, variation tree,
  engine/settings/utilities, Hermes, board, board controls). Colors and layout
  unchanged.

## Landed in this slice

### Core / bridge

- `MCTSStore::snapshotLight(maxCandidates, maxVisibleNodes, includeOwnership)` —
  caps variation tree for UI polls; keeps path to current root.
- `BackendWorker::latestLightSnapshot` used by `latestCoreSnapshotJSON` (32
  candidates, 4096 visible nodes).
- Product core-state byte cap **384 MiB** (`kMaxCoreStateBytes`).
- `BackendWorker` I/O progress (`currentIoProgress`) updated during
  export/import; exposed as `coreIoProgressJSON` on the native bridge.

### Swift UI (main page chrome only)

- `QixiBlockingJob` + `QixiMainPageProgressChrome` — determinate progress when
  fraction/bytes known; paper/Hermes styling.
- ViewModel maps backend transitions to `activeBlockingJob` and polls core I/O
  progress during MCTS package import/export.
- Variation layout still bounded at 4096 nodes on the main thread.

## ViewModel split (landed)

`QixiViewModel` remains the main-page `ObservableObject` façade (views unchanged).
Logic extracted into:

| Module | Role |
| --- | --- |
| `QixiVariationModel` | Variation tree projection / rebuild from light snapshots |
| `QixiBlockingSession` | Blocking jobs + I/O progress polling |
| `QixiCoreMutationQueue` | FIFO core mutations / engine selection pump |
| `QixiBlockingJob` | Progress chrome model (existing) |

## Not yet done (next slices)

- Further slimming: analysis cache module, persistence coordinator, feature plugins.
- Streaming deserialize / true byte-progress during parse.
- Incremental variation projection (diff apply).
- OOM unload policy wired to memory pressure.
- ~~Delete dual HTTP analysis path from product session~~ **done** (factory + ViewModel core-only; HTTP sources excluded from app target).

See the plan discussion in session notes for full architecture.
