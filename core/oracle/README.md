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

### Official-backend note (no Search.cpp patches)

An attempt to drive official Search with `setPersistentMCTSEnabled(true)` +
`setPositionForMCTSPersistence` hit a fatal `testAssert(isRoot)` inside stock
`search.cpp` during multi-root transfers (zero-weight non-root node). Per policy
we **did not modify** official Search sources. The official backend uses stock
`setPosition` for root changes (fresh tree per root) and matches the custom
backend’s reported total analysis count via `maxVisits` / `maxPlayouts`.

## Correctness protocol

Executable: `qixi_oracle_correctness`

```sh
# Build KataGo Eigen once
cmake -S KataGo/cpp -B /private/tmp/qixi_katago_eigen \
  -DUSE_BACKEND=EIGEN -DUSE_AVX2=0 -DNO_GIT_REVISION=1 -DCMAKE_BUILD_TYPE=Release
cmake --build /private/tmp/qixi_katago_eigen --target katago_core --parallel

# Build harness
cmake -S core/oracle -B /private/tmp/qixi_oracle_build -DCMAKE_BUILD_TYPE=Release
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
