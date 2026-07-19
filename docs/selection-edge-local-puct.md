# Edge-local PUCT + playout doubling advantage (episode degree)

Last updated: 2026-07-19

## Goal

Make Qixi product search (`core::MCTSStore`) as consistent as practical with **official KataGo tree search**, under:

1. Persistent MCTS (first-visit, min-root-depth, split backup)
2. Tree only (no graph search)
3. Edge-local successor credit (child may become root)
4. User **episode degree** = official **`playoutDoublingAdvantage` (PDA)**

## Product mapping

| Qixi / UI | Official KataGo | Role |
|-----------|-----------------|------|
| Episode degree | `playoutDoublingAdvantage` | NN input: assume one side has \(2^{\mathrm{PDA}}\)× the opponent’s playouts. Typical range **[-3, 3]**. |
| Wide root noise / 宽根噪声 | `wideRootNoise` | Root-only search breadth (analysis default often 0.04). Separate from PDA. |

PDA is **not** a PUCT coefficient. It changes leaf policy/value; PUCT only allocates visits on **edges**.

## Contract A — Edge-local selection

When choosing a successor from parent \(P\) along edge \(a \to C\):

| Quantity | Source | Forbidden |
|----------|--------|-----------|
| Tried? | `Action.visits > 0` under \(P\) | “\(C\) has visits / NN / was root” |
| \(w\) | Edge weight / visits only | `C.visits` |
| \(Q\) if tried | Edge `Action.stats.utilityMean`, side of \(P\) | Child node utility after child-as-root search |
| \(Q\) if untried | FPU at \(P\) | Child historical \(Q\) with \(w=0\) |
| \(W\) | Sum of edge \(w\) over tried edges from \(P\) | Relying only on `P.visits` |

Zero-edge but already-linked child ⇒ **new** branch (FPU, \(w=0\)).

## Contract B — PDA

- Every leaf eval sets `MiscNNInputParams.playoutDoublingAdvantage` with official sign rule vs side-to-move.
- PDA (quantized) is part of `AnalysisKey`. Changing PDA rekeys the store (no mixing stored NN leaves).
- Default PDA = 0.

## Contract C — Tree-subset PUCT (Approach A)

\[
V(a) = c(W)\sqrt{W+0.01}\,\frac{P(a)}{1+w(a)} + \mathrm{side}(U(a))
\]

with log-cPUCT, parent-relative FPU, root-only wide root noise, and two-phase select (tried edges + single best-policy untried move).

Analysis-aligned defaults: \(c=1.0\), \(c_{\log}=0.45\), \(B=500\), root FPU reduction 0.1, non-root 0.2.

## Display score = lead (not selfplay score)

Official analysis reports user-facing score as **scoreLead** (`whiteLead`), and aliases it to `scoreMean` for tools. Selfplay score (`whiteScoreMean`) is exposed separately as `scoreSelfplay` and is often larger / more biased.

Qixi HUD/chart `displayScoreMean` uses **`leadMeanWhite`** (side-to-move polarity), not `scoreMeanWhite`. Utility/PUCT still uses the selfplay score head via ScoreValue.

## Non-goals

Graph search, virtual losses, Dirichlet root noise, human SL, anti-mirror, LCB move choice, dynamic handicap PDA, bit-identical `Search::runWholeSearch` trajectories.
