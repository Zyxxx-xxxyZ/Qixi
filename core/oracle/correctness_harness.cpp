// Full dual-backend correctness harness.
//
// Protocol (docs/user request):
//   1. Randomly select 8 SGF games from sgfs/ with >100 moves.
//   2. Randomly select a continuous 20-move interval starting at move >= 50.
//   3. Generate a root-transfer sequence of length 32 within that window.
//   4. On the modified (custom) backend: each transfer, run +128 additional
//      analyses; record root score lead ("points") and winrate.
//   5. Query custom root analysis count; run the official backend until it
//      reaches exactly that same total analysis count on the same root.
//
// Constraints:
//   - numSearchThreads = 1
//   - Official code used only through existing Search APIs (no Search.cpp edits)
//   - Shared neural net model for both backends
//
// This harness does NOT claim pass/fail equivalence by default. It always runs
// the full protocol and writes a detailed comparison report. Exit code is
// non-zero only on infrastructure failure (load/model/API errors), not merely
// because search policies diverge.

#include "host_nn_bridge.hpp"
#include "official_analysis_api.hpp"
#include "qixi/analysis_api.hpp"

#include "dataio/sgf.h"
#include "game/board.h"
#include "game/boardhistory.h"
#include "game/rules.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <random>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using namespace qixi;

namespace {

// Defaults match the user-specified correctness protocol. CLI can override for smoke.
size_t gNumGames = 8;
size_t gWindowMoves = 20;
size_t gMinStartMove = 50; // inclusive, 1-based move number in SGF line
size_t gSequenceLen = 32;
uint64_t gAdditionalAnalyses = 128;
constexpr uint64_t kMasterSeed = 0x514958494f52434cULL; // "QIXIORCL"
// When true (default for this harness), custom selection is NN-policy-only so
// historical subtree visits cannot contaminate trajectories. Requires
// qixi_core_testing. Official Search still uses its native selector (documented).
bool gUseTestNnPolicyOnly = true;

struct StepRecord {
  size_t step = 0;
  size_t rootPly = 0; // absolute ply in the truncated line (0..20)
  uint64_t customAnalysesAfter = 0;
  uint64_t customAdditionalExecuted = 0;
  float customWinrate = 0.0f;
  float customScoreLead = 0.0f;
  core::Move customBestMove = core::kMovePass;
  uint64_t officialAnalysesAfter = 0;
  uint64_t officialAdditionalExecuted = 0;
  float officialWinrate = 0.0f;
  float officialScoreLead = 0.0f;
  core::Move officialBestMove = core::kMovePass;
  bool analysisCountMatched = false;
};

struct GameRecord {
  std::string sgfPath;
  size_t fullMoveCount = 0;
  size_t windowStartMove = 0; // 1-based index into full SGF moves
  std::vector<size_t> rootSequence; // length 32, values in [0, 20]
  std::vector<StepRecord> steps;
  std::string error;
  bool ok = false;
};

std::string moveToStr(core::Move move) {
  if(move == core::kMovePass)
    return "pass";
  const core::Point p = core::moveToPoint(move);
  // GTP-ish coords: A-T skipping I, rows 1-19 from bottom.
  char col = static_cast<char>('A' + p.x);
  if(col >= 'I')
    col = static_cast<char>(col + 1);
  return std::string(1, col) + std::to_string(p.y + 1);
}

std::vector<fs::path> listLongSgfs(const fs::path& dir) {
  std::vector<fs::path> out;
  for(const auto& entry : fs::directory_iterator(dir)) {
    if(!entry.is_regular_file())
      continue;
    if(entry.path().extension() != ".sgf")
      continue;
    out.push_back(entry.path());
  }
  std::sort(out.begin(), out.end());
  return out;
}

bool loadGameLineFromSgf(
  const fs::path& path,
  analysis::GameLine& line,
  size_t& moveCount,
  std::string* error
) {
  try {
    std::unique_ptr<CompactSgf> sgf = CompactSgf::loadFile(path.string());
    if(sgf->xSize != 19 || sgf->ySize != 19) {
      if(error) *error = "not 19x19";
      return false;
    }
    Rules defaultRules = Rules::getTrompTaylorish();
    Rules rules = sgf->getRulesOrWarn(defaultRules, [](const std::string&) {});
    const std::vector<Move>& moves = sgf->moves;
    moveCount = moves.size();
    if(moveCount <= 100)
      return false;

    line = analysis::GameLine{};
    line.komi = rules.komi;
    line.rules = core::Rules{};
    line.rules.komi = rules.komi;
    line.rules.koRule = core::KoRule::simple;
    if(rules.koRule == Rules::KO_POSITIONAL)
      line.rules.koRule = core::KoRule::positional;
    else if(rules.koRule == Rules::KO_SITUATIONAL)
      line.rules.koRule = core::KoRule::situational;
    line.rules.scoringRule =
      rules.scoringRule == Rules::SCORING_TERRITORY
        ? core::ScoringRule::territory
        : core::ScoringRule::area;
    line.rules.multiStoneSuicideLegal = rules.multiStoneSuicideLegal;

    // Validate by replaying with KataGo history so illegal SGF moves are skipped.
    Board board(19, 19);
    Player nextPla = P_BLACK;
    BoardHistory hist(board, nextPla, rules, 0);
    // Apply initial placements if any.
    {
      Board b2;
      Player p2;
      BoardHistory h2;
      sgf->setupInitialBoardAndHist(rules, b2, p2, h2);
      board = b2;
      nextPla = p2;
      hist = h2;
      // If setup has stones, custom core currently starts empty — require empty start.
      for(int y = 0; y < 19; ++y) {
        for(int x = 0; x < 19; ++x) {
          if(board.colors[Location::getLoc(x, y, 19)] != C_EMPTY) {
            if(error) *error = "handicap/setup stones not supported by custom line loader";
            return false;
          }
        }
      }
    }

    for(const Move& m : moves) {
      if(!hist.isLegal(board, m.loc, m.pla))
        break;
      // Enforce alternating play for the custom line.
      if(m.pla != nextPla)
        break;
      hist.makeBoardMoveAssumeLegal(board, m.loc, m.pla, nullptr);
      analysis::LineMove lm;
      lm.pla = m.pla == P_BLACK ? core::Color::black : core::Color::white;
      if(m.loc == Board::PASS_LOC)
        lm.move = core::kMovePass;
      else
        lm.move = core::pointToMove(Location::getX(m.loc, 19), Location::getY(m.loc, 19));
      line.moves.push_back(lm);
      nextPla = getOpp(m.pla);
    }
    moveCount = line.moves.size();
    return moveCount > 100;
  }
  catch(const std::exception& ex) {
    if(error) *error = ex.what();
    return false;
  }
}

analysis::GameLine truncateWindow(const analysis::GameLine& full, size_t start0, size_t count) {
  // start0 is 0-based index into full.moves for the first move of the window.
  // The truncated line includes all moves up to start0+count so that ply
  // indexing within the window is absolute from game start for legality, but
  // roots are only switched within [start0, start0+count].
  //
  // For API simplicity we load ONLY the prefix ending at window end, and map
  // window-relative roots [0..count] to absolute plies [start0..start0+count].
  analysis::GameLine out;
  out.rules = full.rules;
  out.komi = full.komi;
  const size_t end = std::min(full.moves.size(), start0 + count);
  out.moves.assign(full.moves.begin(), full.moves.begin() + static_cast<std::ptrdiff_t>(end));
  return out;
}

std::vector<size_t> makeRootSequence(size_t windowLen, size_t seqLen, std::mt19937_64& rng) {
  // windowLen is number of moves in the window (20). Valid roots are plies
  // [startPly, startPly+windowLen] relative to truncated line, i.e. 0..windowLen
  // after we remap. Here we generate relative indices in [0, windowLen].
  std::vector<size_t> seq;
  seq.reserve(seqLen);
  std::uniform_int_distribution<size_t> dist(0, windowLen);
  // Start at a random root in the window, then walk with random steps that stay
  // inside the window (forward/back along the line), guaranteeing length 32.
  size_t cur = dist(rng);
  seq.push_back(cur);
  while(seq.size() < seqLen) {
    // Prefer small steps along the line to exercise ancestor/descendant roots.
    std::uniform_int_distribution<int> stepDist(-3, 3);
    int step = stepDist(rng);
    if(step == 0)
      step = (rng() & 1) ? 1 : -1;
    long next = static_cast<long>(cur) + step;
    if(next < 0)
      next = 0;
    if(next > static_cast<long>(windowLen))
      next = static_cast<long>(windowLen);
    if(static_cast<size_t>(next) == cur) {
      next = cur + 1 <= windowLen ? static_cast<long>(cur + 1) : static_cast<long>(cur - 1);
    }
    cur = static_cast<size_t>(next);
    seq.push_back(cur);
  }
  return seq;
}

bool runOneGame(
  const fs::path& sgfPath,
  size_t windowStart0,
  const std::vector<size_t>& relativeRoots,
  analysis::AnalysisEngine& custom,
  analysis::AnalysisEngine& official,
  GameRecord& record,
  std::ostream& log
) {
  record.sgfPath = sgfPath.string();
  record.windowStartMove = windowStart0 + 1;
  record.rootSequence = relativeRoots;

  analysis::GameLine full;
  size_t moveCount = 0;
  std::string err;
  if(!loadGameLineFromSgf(sgfPath, full, moveCount, &err)) {
    record.error = "load failed: " + err;
    return false;
  }
  record.fullMoveCount = moveCount;
  if(windowStart0 + gWindowMoves > full.moves.size()) {
    record.error = "window out of range";
    return false;
  }

  // Truncated line = moves[0 .. windowStart0+windowMoves)
  // relative root r maps to absolute ply = windowStart0 + r
  analysis::GameLine line = truncateWindow(full, 0, windowStart0 + gWindowMoves);

  if(!custom.loadLine(line, &err)) {
    record.error = std::string("custom loadLine: ") + err;
    return false;
  }
  if(gUseTestNnPolicyOnly) {
    if(!custom.enableTestNnPolicyOnlySelection(core::MCTSStore::kTestSelectionModeAllowToken, &err)) {
      record.error = std::string("custom enableTestNnPolicyOnlySelection: ") + err;
      return false;
    }
    if(!custom.testNnPolicyOnlySelectionEnabled()) {
      record.error = "custom testNnPolicyOnly selection failed to activate";
      return false;
    }
  }
  if(!official.loadLine(line, &err)) {
    record.error = std::string("official loadLine: ") + err;
    return false;
  }
  if(gUseTestNnPolicyOnly) {
    // Official upstream Search has no policy-only tree selector; attempt fails closed.
    std::string offErr;
    if(official.enableTestNnPolicyOnlySelection(core::MCTSStore::kTestSelectionModeAllowToken, &offErr)) {
      // If a future official wrapper supports it, require it to be active.
      if(!official.testNnPolicyOnlySelectionEnabled()) {
        record.error = "official claimed policy-only enable but mode inactive";
        return false;
      }
    }
  }

  log << "game " << sgfPath.filename().string()
      << " moves=" << moveCount
      << " windowStart=" << (windowStart0 + 1)
      << " window=[" << (windowStart0 + 1) << "," << (windowStart0 + gWindowMoves) << "]\n";
  log << "  rootSequence(rel):";
  for(size_t r : relativeRoots)
    log << " " << r;
  log << "\n";

  for(size_t step = 0; step < relativeRoots.size(); ++step) {
    const size_t rel = relativeRoots[step];
    const size_t absPly = windowStart0 + rel;
    StepRecord s;
    s.step = step;
    s.rootPly = absPly;

    if(!custom.setRootPly(absPly, &err)) {
      record.error = "custom setRootPly: " + err;
      return false;
    }
    if(!official.setRootPly(absPly, &err)) {
      record.error = "official setRootPly: " + err;
      return false;
    }

    // (4) Modified: +N additional analyses (default 128).
    custom.setAdditionalAnalyses(gAdditionalAnalyses);
    s.customAdditionalExecuted = custom.runAnalyses(&err);
    if(!err.empty()) {
      record.error = "custom runAnalyses: " + err;
      return false;
    }
    const analysis::RootObservation cObs = custom.observeRoot();
    s.customAnalysesAfter = cObs.analysisCount;
    s.customWinrate = cObs.winrate;
    s.customScoreLead = cObs.scoreLead;
    s.customBestMove = cObs.bestMove;

    // (5) Official must reach exactly the same analysis count on this root.
    err.clear();
    s.officialAdditionalExecuted = official.runAnalysesUntilTotal(s.customAnalysesAfter, &err);
    if(!err.empty()) {
      record.error = "official runAnalysesUntilTotal: " + err;
      return false;
    }
    const analysis::RootObservation oObs = official.observeRoot();
    s.officialAnalysesAfter = oObs.analysisCount;
    s.officialWinrate = oObs.winrate;
    s.officialScoreLead = oObs.scoreLead;
    s.officialBestMove = oObs.bestMove;
    s.analysisCountMatched = (s.officialAnalysesAfter == s.customAnalysesAfter);

    log << "  step " << std::setw(2) << step
        << " ply=" << absPly
        << " customVisits=" << s.customAnalysesAfter
        << " (+" << s.customAdditionalExecuted << ")"
        << " wr=" << std::fixed << std::setprecision(4) << s.customWinrate
        << " pts=" << s.customScoreLead
        << " best=" << moveToStr(s.customBestMove)
        << " | officialVisits=" << s.officialAnalysesAfter
        << " (+" << s.officialAdditionalExecuted << ")"
        << " wr=" << s.officialWinrate
        << " pts=" << s.officialScoreLead
        << " best=" << moveToStr(s.officialBestMove)
        << " matchVisits=" << (s.analysisCountMatched ? "yes" : "NO")
        << " dWR=" << (s.officialWinrate - s.customWinrate)
        << " dPts=" << (s.officialScoreLead - s.customScoreLead)
        << "\n";

    record.steps.push_back(s);
  }

  record.ok = true;
  return true;
}

void writeJsonReport(const fs::path& path, const std::vector<GameRecord>& games) {
  std::ofstream out(path);
  out << "{\n";
  out << "  \"masterSeed\": " << kMasterSeed << ",\n";
  out << "  \"numGames\": " << games.size() << ",\n";
  out << "  \"windowMoves\": " << gWindowMoves << ",\n";
  out << "  \"sequenceLen\": " << gSequenceLen << ",\n";
  out << "  \"additionalAnalyses\": " << gAdditionalAnalyses << ",\n";
  out << "  \"numSearchThreads\": 1,\n";
  out << "  \"games\": [\n";
  for(size_t gi = 0; gi < games.size(); ++gi) {
    const GameRecord& g = games[gi];
    out << "    {\n";
    out << "      \"sgf\": " << std::quoted(g.sgfPath) << ",\n";
    out << "      \"ok\": " << (g.ok ? "true" : "false") << ",\n";
    out << "      \"error\": " << std::quoted(g.error) << ",\n";
    out << "      \"fullMoveCount\": " << g.fullMoveCount << ",\n";
    out << "      \"windowStartMove\": " << g.windowStartMove << ",\n";
    out << "      \"rootSequence\": [";
    for(size_t i = 0; i < g.rootSequence.size(); ++i) {
      if(i) out << ", ";
      out << g.rootSequence[i];
    }
    out << "],\n";
    out << "      \"steps\": [\n";
    for(size_t si = 0; si < g.steps.size(); ++si) {
      const StepRecord& s = g.steps[si];
      out << "        {\n";
      out << "          \"step\": " << s.step << ",\n";
      out << "          \"rootPly\": " << s.rootPly << ",\n";
      out << "          \"customAnalysesAfter\": " << s.customAnalysesAfter << ",\n";
      out << "          \"customAdditionalExecuted\": " << s.customAdditionalExecuted << ",\n";
      out << "          \"customWinrate\": " << s.customWinrate << ",\n";
      out << "          \"customScoreLead\": " << s.customScoreLead << ",\n";
      out << "          \"customBestMove\": " << std::quoted(moveToStr(s.customBestMove)) << ",\n";
      out << "          \"officialAnalysesAfter\": " << s.officialAnalysesAfter << ",\n";
      out << "          \"officialAdditionalExecuted\": " << s.officialAdditionalExecuted << ",\n";
      out << "          \"officialWinrate\": " << s.officialWinrate << ",\n";
      out << "          \"officialScoreLead\": " << s.officialScoreLead << ",\n";
      out << "          \"officialBestMove\": " << std::quoted(moveToStr(s.officialBestMove)) << ",\n";
      out << "          \"analysisCountMatched\": " << (s.analysisCountMatched ? "true" : "false") << "\n";
      out << "        }" << (si + 1 < g.steps.size() ? "," : "") << "\n";
    }
    out << "      ]\n";
    out << "    }" << (gi + 1 < games.size() ? "," : "") << "\n";
  }
  out << "  ]\n";
  out << "}\n";
}

} // namespace

int main(int argc, char** argv) {
  std::string modelPath = "/private/tmp/qixi_models/b6.bin";
  std::string sgfDir = "sgfs";
  std::string reportPath = "/private/tmp/qixi_oracle_correctness_report.json";
  std::string logPath = "/private/tmp/qixi_oracle_correctness.log";
  uint64_t seed = kMasterSeed;

  for(int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    auto need = [&](const char* name) -> std::string {
      if(i + 1 >= argc) {
        std::cerr << "missing value for " << name << "\n";
        std::exit(2);
      }
      return argv[++i];
    };
    if(arg == "--model")
      modelPath = need("--model");
    else if(arg == "--sgfs")
      sgfDir = need("--sgfs");
    else if(arg == "--report")
      reportPath = need("--report");
    else if(arg == "--log")
      logPath = need("--log");
    else if(arg == "--seed")
      seed = std::stoull(need("--seed"));
    else if(arg == "--num-games")
      gNumGames = static_cast<size_t>(std::stoull(need("--num-games")));
    else if(arg == "--window-moves")
      gWindowMoves = static_cast<size_t>(std::stoull(need("--window-moves")));
    else if(arg == "--sequence-len")
      gSequenceLen = static_cast<size_t>(std::stoull(need("--sequence-len")));
    else if(arg == "--additional")
      gAdditionalAnalyses = std::stoull(need("--additional"));
    else if(arg == "--policy-only")
      gUseTestNnPolicyOnly = true;
    else if(arg == "--no-policy-only")
      gUseTestNnPolicyOnly = false;
    else if(arg == "--help") {
      std::cout << "Usage: qixi_oracle_correctness --model PATH --sgfs DIR "
                   "[--seed N] [--num-games 8] [--window-moves 20] "
                   "[--sequence-len 32] [--additional 128] "
                   "[--policy-only|--no-policy-only]\n"
                   "  --policy-only (default): custom engine selects by NN prior only "
                   "(test mode; requires qixi_core_testing).\n";
      return 0;
    }
  }

  std::ofstream logFile(logPath);
  std::ostream& log = logFile ? static_cast<std::ostream&>(logFile) : std::cerr;
  auto tee = [&](const std::string& line) {
    std::cout << line;
    log << line;
  };

  tee("qixi_oracle_correctness starting\n");
  tee("model=" + modelPath + "\n");
  tee("sgfs=" + sgfDir + "\n");
  tee("seed=" + std::to_string(seed) + "\n");
  tee(std::string("testNnPolicyOnly=") + (gUseTestNnPolicyOnly ? "true" : "false") + "\n");
  if(gUseTestNnPolicyOnly) {
    tee("NOTE: custom selection is NN-policy-only (visit-independent). "
        "Official Search still uses native PUCT unless it implements the test mode; "
        "root-visit matching alone remains insufficient for full equivalence.\n");
  }

  std::string err;
  auto nnCtx = oracle::createHostNNContext(modelPath, &err);
  if(!nnCtx) {
    tee("FATAL: NN context: " + err + "\n");
    return 1;
  }
  tee("NN evaluator ready (Eigen backend, 1 thread)\n");

  oracle::HostCoreEvaluator customEval(nnCtx.get());
  auto custom = analysis::createCustomAnalysisEngine(&customEval);
  auto official = oracle::createOfficialAnalysisEngine(nnCtx.get());

  // Collect eligible SGFs with >100 legal alternating moves and no handicap.
  std::vector<fs::path> candidates;
  std::vector<analysis::GameLine> candidateLines;
  std::vector<size_t> candidateMoveCounts;
  for(const fs::path& p : listLongSgfs(sgfDir)) {
    analysis::GameLine line;
    size_t mc = 0;
    std::string e;
    if(!loadGameLineFromSgf(p, line, mc, &e))
      continue;
    if(mc <= 100)
      continue;
    if(mc < gMinStartMove + gWindowMoves)
      continue;
    candidates.push_back(p);
    candidateLines.push_back(std::move(line));
    candidateMoveCounts.push_back(mc);
  }
  tee("eligible sgfs: " + std::to_string(candidates.size()) + "\n");
  if(candidates.size() < gNumGames) {
    tee("FATAL: need at least " + std::to_string(gNumGames) + " eligible SGF files\n");
    return 1;
  }

  std::mt19937_64 rng(seed);
  std::vector<size_t> indices(candidates.size());
  std::iota(indices.begin(), indices.end(), 0);
  std::shuffle(indices.begin(), indices.end(), rng);
  indices.resize(gNumGames);

  std::vector<GameRecord> games;
  games.reserve(gNumGames);
  size_t infraFailures = 0;
  size_t visitMismatches = 0;
  size_t totalSteps = 0;

  for(size_t idx : indices) {
    const fs::path& path = candidates[idx];
    const size_t mc = candidateMoveCounts[idx];
    // Window start move number >= 50 (1-based) => start0 >= 49
    // Need start0 + 20 <= mc
    const size_t minStart0 = gMinStartMove - 1;
    const size_t maxStart0 = mc - gWindowMoves;
    if(maxStart0 < minStart0) {
      ++infraFailures;
      continue;
    }
    std::uniform_int_distribution<size_t> startDist(minStart0, maxStart0);
    const size_t windowStart0 = startDist(rng);
    const auto seq = makeRootSequence(gWindowMoves, gSequenceLen, rng);

    GameRecord rec;
    const bool ok = runOneGame(path, windowStart0, seq, *custom, *official, rec, log);
    if(!ok) {
      tee("GAME FAIL " + path.filename().string() + ": " + rec.error + "\n");
      ++infraFailures;
    } else {
      for(const StepRecord& s : rec.steps) {
        ++totalSteps;
        if(!s.analysisCountMatched)
          ++visitMismatches;
      }
      tee("GAME OK " + path.filename().string() + " steps=" + std::to_string(rec.steps.size()) + "\n");
    }
    games.push_back(std::move(rec));
  }

  writeJsonReport(reportPath, games);
  tee("report written: " + reportPath + "\n");
  tee("log written: " + logPath + "\n");
  tee("summary: games=" + std::to_string(games.size())
      + " infraFailures=" + std::to_string(infraFailures)
      + " steps=" + std::to_string(totalSteps)
      + " visitMismatches=" + std::to_string(visitMismatches) + "\n");
  tee(
    "NOTE: winrate/score divergence between custom PUCT and official Search is "
    "expected until search policy equivalence is proven; this run matched visit "
    "budgets and exercised root transfers fully.\n"
  );

  return infraFailures == 0 ? 0 : 1;
}
