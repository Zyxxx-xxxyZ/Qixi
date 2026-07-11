# Dual Analysis API + Correctness Harness

## Unified API (`qixi::analysis::AnalysisEngine`)

Implemented for both backends:

| Operation | Method |
| --- | --- |
| Root change | `setRootPly(ply)` |
| Set additional analyses | `setAdditionalAnalyses(n)` / `runAnalyses()` |
| Match absolute visit total | `runAnalysesUntilTotal(total)` |
| Query analyses on current root | `rootAnalysisCount()` |
| Root points + winrate | `observeRoot()` → `scoreLead`, `winrate`, `bestMove` |

- **Custom (modified):** `createCustomAnalysisEngine(Evaluator*)` in `core/`
- **Official:** `createOfficialAnalysisEngine(HostNNContext*)` in this directory

Search threads are fixed to **1**.

### Official backend

- **Default (no `--policy-only`)**: upstream `Search` + PUCT via `setPosition` /
  `runWholeSearch` (`numSearchThreads=1`). Upstream has **no** persistent MCTS.
- **Test-only (`--policy-only`)**: official engine switches to
  `testNnPolicyOnly` — a **fresh** `MCTSStore` rebuilt each `setRootPly`, same
  NN-policy sampler as custom. This path is **not** used in the app. Full list of
  remaining custom vs official gaps: `docs/oracle-test-discrepancies.md`.

Custom persistence correctness: `docs/correctness-persistent-mcts.md`.

## Correctness protocol

Executable: `qixi_oracle_correctness`

```sh
# Build official KataGo Eigen (submodule on official/lightvector-master)
cmake -S KataGo/cpp -B /private/tmp/qixi_katago_official_eigen \
  -DUSE_BACKEND=EIGEN -DUSE_AVX2=0 -DNO_GIT_REVISION=1 -DCMAKE_BUILD_TYPE=Release
cmake --build /private/tmp/qixi_katago_official_eigen --target katago --parallel
# Archive non-main objects for linking (upstream has no libkatago_core.a)
( cd /private/tmp/qixi_katago_official_eigen && \
  find . -name '*.o' ! -path './CMakeFiles/katago.dir/main.cpp.o' -print0 \
  | xargs -0 ar rcs libkatago_official.a )

# Build harness
cmake -S core/oracle -B /private/tmp/qixi_oracle_build -DCMAKE_BUILD_TYPE=Release \
  -DKATAGO_CORE_LIB=/private/tmp/qixi_katago_official_eigen/libkatago_official.a
cmake --build /private/tmp/qixi_oracle_build --parallel

# Full protocol (defaults: 8 games, window 20, seq 32, +128)
/private/tmp/qixi_oracle_build/qixi_oracle_correctness \
  --model /path/to/b6.bin \
  --sgfs sgfs \
  --report core/oracle/artifacts/correctness_report.json \
  --log core/oracle/artifacts/correctness.log
```

Shared model: both backends call the same Eigen `NNEvaluator` (custom via
`HostCoreEvaluator`, official via `Search`).

## Latest full run (2026-07-11)

- 8/8 games OK, 256/256 steps, **0 visit-count mismatches**
- Custom: +128 analyses per root transfer; official matched `customAnalysesAfter`
- Winrate/score still diverge (custom simplified PUCT ≠ official Search) — expected
- Artifacts: `artifacts/correctness_report.json`, `artifacts/correctness.log`
