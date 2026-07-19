# Qixi architecture

Last updated: 2026-07-19

## Purpose

棋析 Qixi is an on-device Go analysis app. Product **search** is owned by
`qixi::core::MCTSStore`. KataGo is used only for **neural-network evaluation**.

## Runtime path

```text
SwiftUI (qixi-ios-native)
  └─ QixiViewModel / analysis service
       └─ Native bridge (QixiNativeKataGo*)
            ├─ core::BackendWorker / core::MCTSStore   ← search + tree persistence
            └─ NativeKataGoEngine (NN only)
                 └─ KataGo NNEvaluator + LinkedCoreEvaluator
```

Live UI fields (candidates, winrate, score lead, ownership, variations) come from
**core root snapshots**, not from stock KataGo `Search::getAnalysisJson`.

## Repository layout

| Path | Role |
| --- | --- |
| `qixi-ios-native/` | Product SwiftUI app, localization, camera/SGF/iCloud surfaces |
| `core/` | Persistent MCTS, request pool, analysis API types, unit tests |
| `KataGo/` | Submodule: NN stack (and Qixi link surface). Not product search |
| `qixi-ios-sim/` | Optional Mac HTTP bridge / web sim for development |
| `tests/`, `scripts/` | Quality gates, hygiene, changed-surface CI helpers |
| `docs/` | Design and verification documentation |
| `needsupport/` | Board-locator ground-truth fixtures |

## Key product contracts

1. **Search mandate** — [`search-engine.md`](search-engine.md)  
2. **Persistence correctness** — [`correctness-persistent-mcts.md`](correctness-persistent-mcts.md)  
3. **Edge-local PUCT + PDA (激进度)** — [`selection-edge-local-puct.md`](selection-edge-local-puct.md)  
4. **Display score** — HUD uses **scoreLead** (`leadMeanWhite`), not selfplay score alone  

## Configuration surfaces (user-facing)

- Visit budget / continuous analysis controls (UI)
- Wide root noise (search breadth at root)
- Episode degree / 激进度 → `playoutDoublingAdvantage` (rekeys analysis store)
- Model selection (local nets; packaging is build-time / device install)

## Persistence

- App autosave / backup / optional iCloud sync of game + analysis identity
- Lifecycle **tombstones** export/import **core** tree state (not KataGo Search trees)
- Position identity is history- and settings-sensitive (see fixture under `tests/fixtures/`)

## Non-goals

- Bit-identical trajectories vs official KataGo full search
- Shipping large network weights in git
- Replacing the SwiftUI layout without an explicit product request

## Related runbooks

- iOS build/run: [`native-ios-runbook.md`](native-ios-runbook.md)  
- NN integration / NativeRelease: [`native-katago-integration.md`](native-katago-integration.md)  
- PR gates: [`pr-verification-matrix.md`](pr-verification-matrix.md), [`quality-gates.md`](quality-gates.md)  
