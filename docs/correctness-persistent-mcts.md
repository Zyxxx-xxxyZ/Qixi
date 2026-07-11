# Correctness definition: persistent MCTS in `core/`

Last updated: 2026-07-11

## Critical distinctions

1. **Official KataGo** (`https://github.com/lightvector/KataGo`) has **no**
   persistent-MCTS support. Any persistence code under a Qixi fork of KataGo is
   **not** “official.” Correctness oracles that compare against “official”
   must use stock upstream Search (fresh tree after `setPosition`), not a fork’s
   persistence layer.

2. The **custom** persistent engine lives in `core/` (`MCTSStore`). Its
   persistence correctness is **not** “same numbers as a dual-API visit budget
   smoke test.” It is defined by the isolation + **min-root-depth visit** rules
   below.

## Layer A — Structural isolation (still required)

- Backup stops at the active root: descendant-root search must not update
  ancestor nodes’ **parent-local action** distributions in a way that rewrites
  the ancestor’s outgoing move visits.
- Root switch is a view change; unrelated structure is retained.
- Position identity is history-sensitive.

## Layer B — Min-root-depth visit criterion (required; previously under-specified)

### Vocabulary

- Each tree node \(N\) has a depth/ply \(d(N)\) along the game line from the
  initial position (the node’s `ply`).
- When a node \(R\) is the **active root**, its root-depth is \(d(R)\).
- Shallower roots have **smaller** depth (ancestors). Deeper roots have larger
  depth (descendants).

### Stored labels

For every node \(N\), store:

\[
d_{\min}(N) = \min\{\, d(R) : R \text{ visited } N \text{ while acting as root}\,\}
\]

with \(d_{\min}(N) = +\infty\) if no root has ever visited \(N\).

Also store the **raw neural-network leaf** (policy, value/score heads,
ownership) on \(N\) the first time \(N\) is expanded. The NN output is
**global** to the node and must not be discarded when the root changes.

### Definition: “root \(R\) has visited node \(N\)”

Assuming \(N\) lies in the subtree of \(R\) (including \(N = R\)):

\[
R \text{ has visited } N \;\iff\; d(R) \ge d_{\min}(N).
\]

Consequences:

| Situation | Meaning |
| --- | --- |
| Ancestor \(A\) visited \(N\), then descendant \(B\) is root | \(d(B) > d(A) = d_{\min}(N)\) ⇒ \(B\) **has visited** \(N\) (inherits the expansion) |
| Only descendant \(B\) visited \(N\), then ancestor \(A\) is root | \(d(A) < d(B) = d_{\min}(N)\) ⇒ \(A\) has **not** visited \(N\) (must first-visit) |
| No one visited \(N\) | \(d_{\min}=+\infty\) ⇒ no root has visited \(N\) |

### Exactly-once first visit under a root

For a fixed active root \(R\):

1. Every node in \(R\)’s explored subtree receives **exactly one** *first-visit*
   event under \(R\) (the playout that stops on that node while
   \(R\) has not yet visited it).
2. That first visit:
   - uses the **stored NN** if present, otherwise evaluates the net once and
     stores it;
   - expands the node if still unexpanded;
   - records \(d_{\min}^{\mathrm{old}}(N)\) then updates
     \(d_{\min}(N) \leftarrow \min(d_{\min}(N), d(R))\);
   - runs **split backpropagation** (below).
3. Later playouts under the same root may **traverse** already-visited expanded
   nodes (normal MCTS selection) but must **not** treat them again as brand-new
   leaves for \(R\).
4. The search must **not** skip a first visit for \(R\) merely because another
   root already expanded \(N\). The min-depth test is the authority, not
   `state == expanded` alone.

### Split backpropagation (required; naive full-path backup is wrong)

During selection, keep a fixed map of length **2048**:

\[
\mathrm{byDepth}[d] = \text{node on the current path with absolute ply } d.
\]

Let \(L\) be the first-visit leaf under current root \(R\), and let
\(d_{\min}^{\mathrm{old}}(L)\) be its label **before** this visit updates it.

| Case | Backup |
| --- | --- |
| \(d_{\min}^{\mathrm{old}}(L)=+\infty\) (never searched) | Update **entire** path \(L \to R\) (nodes and edges). |
| \(d_{\min}^{\mathrm{old}}(L)\) finite (searched under a deeper root) | \(L\) is correctly treated as **new** for \(R\). But parents of \(L\) up through the node \(S=\mathrm{byDepth}[d_{\min}^{\mathrm{old}}(L)]\) were already updated under that deeper root — full-path backup would **double-update** them. Instead: update **\(L\) itself**, then update from **\(\mathrm{parent}(S)\)** back to **\(R\)** only (not \(S\) and not the \(S\rightsquigarrow L\) segment). |

This is the efficient criterion-correct form of inheritance for statistics when a
shallower root first-visits a node that a descendant root already expanded.

### Why this is not optional

If the engine only checks “already expanded?”, then:

- a descendant-expanded node is silently skipped when an ancestor becomes root
  (ancestor never gets its required first visit / NN-backed backup), or
- conversely, work is double-counted without a clear inheritance rule.

The min-depth rule is the precise inheritance/isolation switch for *visit
labeling*, complementary to parent-local action isolation for *statistics*.

## Layer C — Equivalence to official Search (open)

Still open and **not** claimed:

\[
S_R^{\text{custom}} \stackrel{?}{=} S_R^{\text{official ordinary MCTS}}
\]

under the same model, rules, komi, noise, seed policy, and
\(own(R)+inherited(R)\) sample counts.

Official here means **upstream lightvector/KataGo Search**, not a forked
persistent layer.

## Implementation map (`core/`)

| Concept | Code |
| --- | --- |
| \(d_{\min}(N)\) | `Node::minVisitedRootDepth` (`kNeverVisitedRootDepth` = ∞) |
| Stored NN leaf | `Node::hasStoredNN`, `nn*`, `nnOwnershipOffset` + policy arena |
| \(R\) visited \(N\)? | `MCTSStore::rootHasVisitedNode` |
| Mark visit | `MCTSStore::markVisitedByCurrentRoot` |
| First-visit barrier | `selectPathToLeaf` stops if `!expanded \|\| !rootHasVisited` |
| Path depth map (2048) | `Path::byDepth` / `kSearchChainDepthMapLen` |
| Split backup | `backup(..., priorMinVisitedRootDepth)` |
| Prefer stored NN | `evaluateLeaf` → `loadStoredNNOutput` before evaluator |
| Persist format | version **4** |

## Verification expectations

1. Unit tests: ancestor vs descendant visit labeling; stored NN reuse; no
   false “already done” for shallower roots.
2. Oracle vs official: same model, 1 thread, stock `setPosition` Search; compare
   only after Layer B holds.
3. Do not treat visit-budget matching alone as Layer B or Layer C success.
