# Qixi Core

This directory contains Qixi's C++17 persistent-search state and its sole serialized
backend worker.

Implemented:

- Fixed 19x19 board state, ko/superko-aware move legality, captures, pass handling, and
  frontend legal-move masks backed by the same rules as backend validation.
- One strict-FIFO `BackendWorker`. Mutating frontend requests and background search run
  on that worker; background playouts occur only while its request queue is empty.
- Long-lived MCTS stores keyed by model, komi, and wide-root-noise configuration.
  Selecting no engine retains the active store, while selecting another analysis key
  checkpoints and switches stores without mixing statistics.
- Stable `NodeId` values, history-sensitive lineage identity, parent-local action
  statistics, and root switching without rebuilding the search tree.
- Tree snapshots derive each visible move's color delta only from its parent's action
  statistics, so searching that child as a root cannot recolor the move at its parent.
- Backup that stops at the active root. Searching with a descendant as root therefore
  preserves the descendant subtree but cannot add visits or values to its ancestors.
- One stored neural-network evaluation per expanded node, float scalar statistics, and
  float aggregated ownership on each visited node.
- Versioned binary store and multi-store bundle export/import with bounds checks,
  structural validation, atomic replacement, and active-store restoration.
- Native integration through `LinkedCoreEvaluator`, which reconstructs official KataGo
  `Board`/`BoardHistory` input, runs the configured Metal mux/CoreML evaluator, and maps
  policy, value, score, and ownership output into the persistent core.
- Tests for legality, capture/ko history, root-switch isolation, persistence round trips,
  corrupt-import rejection, FIFO optimistic move chaining, model/settings store
  separation, and engine-switch failure recovery.

Integration boundaries:

- Swift validates moves immediately for responsive UI, then sends ordered mutations to
  the native FIFO. Core snapshots are read-only UI data and do not start searches.
- NativeRelease on iOS Simulator fails model selection closed before entering MPSGraph:
  the simulator framework can raise an uncaught device-construction exception. Real
  Metal-mux inference must be validated on a physical iPhone or iPad.
- SGF parsing/tree presentation, photo recognition, document picking, iCloud file
  coordination, and lifecycle overlays remain Swift platform responsibilities. Their
  resulting core mutations, imports, exports, and checkpoints are serialized by the
  same request queue.
- `ImportSGF`, `ExportSGF`, and `RecognizePhoto` raw-payload handlers deliberately reject
  direct use inside this library; platform adapters parse first and submit concrete
  game, move, recognized-board, or state-file requests.

Correctness scope:

- Persistent visit semantics: see `docs/correctness-persistent-mcts.md`. For each node
  store \(d_{\min}\) (shallowest root depth that visited it). Root \(R\) has visited
  \(N\) iff \(N\) is in \(R\)'s subtree and \(d(R)\ge d_{\min}(N)\). NN output is stored
  once per node; a root must not skip first-visit only because another root expanded \(N\).
- Parent-local action isolation and history-sensitive identity remain required.
- Search policy is **not** claimed equal to upstream lightvector/KataGo. Upstream has
  **no** persistence; fork-only persistence is not "official."
- Persist version 4 writes min-depth + stored NN fields.
- Dual analysis API + host oracle: `include/qixi/analysis_api.hpp`, `core/oracle/`.

Build:

```sh
cmake -S core -B core/build
cmake --build core/build -j4
ctest --test-dir core/build --output-on-failure
```
