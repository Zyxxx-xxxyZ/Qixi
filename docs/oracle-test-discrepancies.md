# Remaining discrepancies: custom vs official in the policy-only oracle test

Last updated: 2026-07-11

This document applies **only** when the oracle harness is run with
`--policy-only` (default) and both engines successfully enable
`testNnPolicyOnly`. It does **not** describe production app settings.

## What is aligned (for this test)

| Setting | Custom | Official (test policy-only path) |
| --- | --- | --- |
| Selection | NN prior sample only | NN prior sample only (same algorithm in `MCTSStore`) |
| Allow token / compile gate | `qixi_core_testing` + token | same |
| Search threads | 1 (no parallel search) | 1 |
| Root noise | 0 | 0 |
| `cpuct` / FPU (unused in policy-only select) | 1.1 / 0 | 1.1 / 0 |
| Win-loss utility factor | 1.0 | 1.0 |
| Static/dynamic score utility | 0 / 0 | 0 / 0 |
| Seed for policy sampling | `0x4f52434c45` | `0x4f52434c45` |
| Board size / line | same SGF principal line | same |
| Komi / rules from line | same `GameLine` | same |
| Model | shared `HostNNContext` / b6 | shared |
| NN path | `HostCoreEvaluator` → `NNEvaluator` | same class / same `nnEval` |
| `skipCache` | true | true |
| `includeOwnerMap` | true | true |
| `maxHistory` (NN) | `kMaxNNHistory` (5) | 5 |
| Visit budget protocol | +128 then match totals | same harness logic |

## Remaining discrepancies (all of them)

### 1. Persistence (largest structural gap)

| | Custom | Official test path |
| --- | --- | --- |
| Root change | `switchRoot` keeps the long-lived store | **Rebuilds a fresh `MCTSStore`** to the target ply (no prior search state) |
| Revisit earlier root | Accumulates visits / first-visit labels / parent-local stats | Starts from **zero** search at that root |
| Min-depth / split backup | Active across the sequence | Only applies **within** one root’s fresh tree (no cross-root inheritance) |

So even with identical selection, the **trees are different objects** after any root transfer that returns to a previously analyzed position.

### 1b. Principal-line pre-materialization

| | Custom | Official test path |
| --- | --- | --- |
| `loadLine` | Plays **entire** principal line into the store, then `switchRoot(0)` | Builds KataGo board snapshots; policy-only store starts empty |
| At root ply \(k\) | Nodes for plies \(0..N\) already exist as a chain | Fresh store only replays plies \(0..k\) |

Custom therefore already has child links along the full SGF line before any analysis; official only has the prefix to the current root.

### 2. “Official” is not upstream Search in policy-only mode

When `testNnPolicyOnly` is enabled on the official engine:

- It does **not** call `Search::runWholeSearch` / PUCT.
- It uses **`MCTSStore` + `HostCoreEvaluator`** (Qixi core code paths).
- Name becomes `official-test-policy-only`.

Upstream lightvector `Search` is only used when policy-only is **off**.

### 3. Playout counter / sampling key coupling

Policy sampling uses:

```text
seed ^ (playoutSeq * …) ^ (parentId * …) ^ POLYONLY
```

| | Custom | Official test path |
| --- | --- | --- |
| `playoutSeq` | Continuous across the whole game / root sequence | **Resets** when the store is rebuilt on each `setRootPly` |
| `parentId` (`NodeId`) | Stable in the persistent store | **Renumbered** after each rebuild |

Therefore, even at the same board and same NN priors, **the random draws for successor choice need not match** after the first root change (and often not even on the first root if node-id assignment differs).

### 4. First-visit / expansion semantics (within a root)

Both use the same `MCTSStore` code, **but**:

| | Custom across roots | Official per root |
| --- | --- | --- |
| Stored NN on a node | Reused when revisiting after root switch | Lost on rebuild (re-evaluated when expanded again) |
| `minVisitedRootDepth` | Carries across the sequence | Reset each rebuild |
| Split backup case \(d_{\min}\) finite from a **deeper** root | Can fire when a shallower root first-visits | **Never** fires for cross-root history (no deeper-root labels survive) |

### 5. Backup boundary (same code, different tree context)

Both use path backup stopping at the **current** root with split-backup rules. Differences come only from (1)/(4): whether the path nodes already carried visits/labels from other roots.

### 6. Observation / reporting

| Field | Custom | Official test path |
| --- | --- | --- |
| Winrate / score | `RootSnapshot` display (side-to-move) | same snapshot path |
| Best move | Highest **action visit** at root | same |

When policy-only selection is used, visit mass follows policy samples, not PUCT, for **both**—but visit vectors still diverge if playout trajectories diverge (item 3) or if one tree already had visits (item 1).

### 7. Legal-move / rules packaging

| | Custom board | Official rebuild uses |
| --- | --- | --- |
| Move legality | `qixi::core::BoardLogic` | same when using `MCTSStore` |
| KataGo `Board`/`BoardHistory` | Only inside `HostCoreEvaluator` for NN | same |

Residual risk: any mismatch between Qixi legality and what KataGo would allow on exotic superko positions (both sides of this test use Qixi legality for tree expansion).

### 8. Utility head from NN

`HostCoreEvaluator` sets:

```text
utilityWhite = winLossWhite * winLossUtilityFactor
```

with score utility factors forced to 0 in the aligned test params.  
Full upstream Search (PUCT mode) would blend score utilities differently; **that path is not used** under `--policy-only`.

### 9. Engine identity / harness naming

- Custom name: `custom`
- Official name under test: `official-test-policy-only`
- Production iOS runtime never links this path.

### 10. What is deliberately out of scope

- Exact match to full KataGo Search heuristics (graph search, LCB, noise, score utility, multi-thread, etc.)
- Proving Layer C equivalence while persistence still differs (item 1)
- Matching subtree visit histograms without also aligning `playoutSeq` / `NodeId` / persistence

## Minimal set of gaps that still block “same search”

If selection is policy-only on both sides, the search results can still differ solely because of:

1. **Persistence vs fresh rebuild** on every root change  
2. **`playoutSeq` + `NodeId` not shared**, so policy samples diverge  
3. **No shared stored-NN / min-depth state** across roots on the official side  

Closing (1)–(3) is required before treating remaining numerical gaps as pure implementation bugs.
