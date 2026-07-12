# Product search engine (v1 path)

Last updated: 2026-07-11

## Mandate

- **Search** = `qixi::core::MCTSStore` only (`core/`).
- **Not** forked KataGo `Search` / `AsyncBot`.
- **Not** stock lightvector `Search`.
- **KataGo** is used only for **neural-network load + `NNEvaluator::evaluate`**
  via `LinkedCoreEvaluator` (`core::Evaluator`).
- **UI design is frozen** unless the product owner explicitly asks to change it.
- **b18/b28-specific packaging/memory issues** are out of scope until reopened;
  the engine selector may still show those models.

## Runtime path

```text
SwiftUI (unchanged layout)
  → QixiViewModel
      → NativeKataGoAnalysisService
          → QixiNativeKataGoBridge
              → NativeKataGoCore
                    ├─ core::BackendWorker
                    │     └─ core::MCTSStore   ← only search
                    └─ NativeKataGoEngine (NN-only)
                          ├─ NNEvaluator
                          └─ LinkedCoreEvaluator
```

- Live analysis UI fields (candidates, winrate, score, ownership, variation
  quality) come from **core root snapshots** (`latestCoreSnapshot` / poll).
- `analyzeRequest` / `analyzeRequestJSON` do **not** run KataGo Search.
- Lifecycle tombstones on `NativeKataGoCore` export/import **core state**, not
  Search trees.

## Files of record

| Role | Location |
| --- | --- |
| MCTS | `core/src/mcts.cpp`, `core/include/qixi/mcts.hpp` |
| Worker | `core/src/request_pool.cpp` |
| NN adapter | `qixi-ios-native/Qixi/QixiNativeKataGoEngine.cpp` |
| Core glue | `qixi-ios-native/Qixi/QixiNativeKataGoCore.cpp` |
| Swift service | `qixi-ios-native/Qixi/QixiNativeKataGoAnalysisService.swift` |

## Correctness definition

See `docs/correctness-persistent-mcts.md` (Layer A/B). Product does **not**
require Layer C equivalence to official KataGo Search.
