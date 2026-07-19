#pragma once

#include "qixi/board.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

namespace qixi::core {

struct ScalarStats {
  float weightSum = 0.0f;
  float weightSqSum = 0.0f;
  float winLossMeanWhite = 0.0f;
  float noResultMean = 0.0f;
  float scoreMeanWhite = 0.0f;
  float scoreMeanSqWhite = 0.0f;
  float leadMeanWhite = 0.0f;
  float utilityMean = 0.0f;
  float utilitySqMean = 0.0f;
};

struct LeafPayload {
  float winLossWhite = 0.0f;
  float noResult = 0.0f;
  float scoreMeanWhite = 0.0f;
  float scoreMeanSqWhite = 0.0f;
  float leadWhite = 0.0f;
  float utilityWhite = 0.0f;
  std::array<float, kOwnershipDim> ownership{};
  std::array<float, kMoveCount> policy{};
  float weight = 1.0f;
};

enum class NodeState : uint8_t {
  unexpanded = 0,
  expanding = 1,
  expanded = 2,
  terminal = 3,
};

struct Node {
  NodeId id = kInvalidNode;
  NodeId parent = kInvalidNode;
  Move moveFromParent = kMovePass;
  Color movePla = Color::empty;
  uint32_t ply = 0;
  Color nextPla = Color::black;
  NodeState state = NodeState::unexpanded;
  uint32_t policyOffset = kInvalidNode;
  ActionId firstAction = kInvalidAction;
  uint16_t actionCount = 0;
  uint16_t ancestorCount = 0;
  uint32_t ancestorOffset = 0;
  VisitCount visits = 0;
  ScalarStats stats;
  // Aggregated MCTS ownership mean (backup-weighted), not necessarily raw NN.
  uint32_t ownershipOffset = kInvalidNode;
  uint64_t lineageHash = 0;

  // Persistent visit labeling (see docs/correctness-persistent-mcts.md):
  // shallowest depth of any root that has visited this node while acting as root.
  // Root R (depth d_R) has visited N iff N is in R's subtree and d_R >= minVisitedRootDepth.
  uint32_t minVisitedRootDepth = kNeverVisitedRootDepth;

  // Raw neural-network leaf stored once on first expansion (required for reuse
  // when a shallower root later visits a node first-expanded under a deeper root).
  bool hasStoredNN = false;
  float nnWinLossWhite = 0.0f;
  float nnNoResult = 0.0f;
  float nnScoreMeanWhite = 0.0f;
  float nnScoreMeanSqWhite = 0.0f;
  float nnLeadWhite = 0.0f;
  float nnUtilityWhite = 0.0f;
  float nnWeight = 1.0f;
  uint32_t nnOwnershipOffset = kInvalidNode;
};

struct Action {
  NodeId parent = kInvalidNode;
  NodeId child = kInvalidNode;
  ActionId nextAction = kInvalidAction;
  Move move = kMovePass;
  VisitCount visits = 0;
  ScalarStats stats;
};

struct SearchParams {
  float cpuct = 1.1f;
  float fpuValue = 0.0f;
  float rootNoise = 0.0f;
  float rootNoiseWeight = 0.25f;
  float winLossUtilityFactor = 1.0f;
  float staticScoreUtilityFactor = 0.0f;
  float dynamicScoreUtilityFactor = 0.0f;
  uint64_t seed = 0x517869ULL;
};

// Tree action selection. Production always uses `puct`.
// `testNnPolicyOnly` ignores visit counts / Q and samples successors from the
// stored NN policy alone. It is intentionally incorrect for real play and is
// available only when the translation unit is compiled with
// QIXI_ALLOW_TEST_SELECTION_MODES=1 (test binaries only).
enum class TreeSelectionMode : uint8_t {
  puct = 0,
  testNnPolicyOnly = 1,
};

struct CandidateSnapshot {
  Move move = kMovePass;
  uint64_t visits = 0;
  float prior = 0.0f;
  float winrate = 0.0f;
  float scoreMean = 0.0f;
  float utility = 0.0f;
};

struct TreeNodeSnapshot {
  NodeId id = kInvalidNode;
  uint64_t lineageHash = 0;
  NodeId parent = kInvalidNode;
  Move moveFromParent = kMovePass;
  Color movePla = Color::empty;
  uint32_t ply = 0;
  uint64_t visits = 0;
  float winrate = 0.0f;
  float scoreMean = 0.0f;
  float qualityDeltaPercent = 0.0f;
  bool analyzed = false;
  bool hasQualityDelta = false;
};

struct RootSnapshot {
  NodeId root = kInvalidNode;
  uint64_t rootLineageHash = 0;
  uint64_t rootVisits = 0;
  float rootWinrate = 0.0f;
  float rootScoreMean = 0.0f;
  std::vector<CandidateSnapshot> candidates;
  std::vector<TreeNodeSnapshot> visibleTree;
  std::array<float, kOwnershipDim> ownership{};
  bool hasOwnership = false;
};

/// Fixed-size lock-free UI analyze plane (O(1): K candidates + 361 ownership).
/// Product displays at most 10 move candidates on the board.
constexpr size_t kAnalyzeDisplayMaxCandidates = 10;

#pragma pack(push, 1)
struct AnalyzeDisplayCandidate {
  uint16_t move = static_cast<uint16_t>(kMovePass);
  uint32_t visits = 0;
  float winrate = 0.0f;
  float scoreMean = 0.0f;
};

struct AnalyzeDisplayPayload {
  uint64_t backendEpoch = 0;
  uint64_t revision = 0;
  uint32_t root = kInvalidNode;
  uint32_t candidateCount = 0;
  uint64_t rootVisits = 0;
  float rootWinrate = 0.5f;
  float rootScoreMean = 0.0f;
  AnalyzeDisplayCandidate candidates[kAnalyzeDisplayMaxCandidates]{};
  float ownership[kOwnershipDim]{};
  uint8_t hasOwnership = 0;
};
#pragma pack(pop)

static_assert(sizeof(AnalyzeDisplayCandidate) == 14, "packed candidate layout");
static_assert(
  sizeof(AnalyzeDisplayPayload) ==
    8 + 8 + 4 + 4 + 8 + 4 + 4 + 14 * kAnalyzeDisplayMaxCandidates + 4 * kOwnershipDim + 1,
  "packed analyze display layout"
);

struct StoreMemoryStats {
  uint64_t nodeCount = 0;
  uint64_t actionCount = 0;
  uint64_t policyFloatCount = 0;
  uint64_t ownershipFloatCount = 0;
  uint64_t ancestorIdCount = 0;
  uint64_t visibleByteCount = 0;
  uint64_t estimatedArenaBytes = 0;
};

class Evaluator {
public:
  virtual ~Evaluator() = default;
  virtual bool evaluate(
    const BoardState& board,
    const Rules& rules,
    bool isRoot,
    LeafPayload& output
  ) = 0;
};

class UniformEvaluator final : public Evaluator {
public:
  bool evaluate(
    const BoardState& board,
    const Rules& rules,
    bool isRoot,
    LeafPayload& output
  ) override;
};

struct PlayMoveCommit {
  bool ok = false;
  std::string error;
  NodeId node = kInvalidNode;
  BoardPatch patch;
};

class MCTSStore {
public:
  static MCTSStore create(
    const BoardState& initialBoard,
    const Rules& rules,
    const AnalysisKey& key,
    const SearchParams& params
  );

  bool validate(std::string* error) const;
  NodeId currentRoot() const;
  const BoardState& rootBoard() const;
  const Rules& rules() const;
  const AnalysisKey& analysisKey() const;
  const SearchParams& searchParams() const;
  void assignImportedGameId(GameId gameId);
  /// O(1) model rekey for fast engine switch — does not clone or free the tree.
  void rekeyModelId(ModelId modelId);
  void setEvaluator(Evaluator* evaluator);

  // Production default is always TreeSelectionMode::puct.
  TreeSelectionMode treeSelectionMode() const { return treeSelectionMode_; }
  // Enables test-only policy selection. Fails closed unless this core library
  // was built with -DQIXI_ALLOW_TEST_SELECTION_MODES=1. Even then, callers must
  // pass the explicit allow token (see kTestSelectionModeAllowToken).
  bool setTreeSelectionMode(
    TreeSelectionMode mode,
    uint64_t allowToken,
    std::string* error
  );
  // Token required as a second line of defense against accidental activation.
  static constexpr uint64_t kTestSelectionModeAllowToken = 0x51584d4354535445ULL; // "QXMCTSTE"

  std::array<bool, kMoveCount> legalMoveMask() const;
  PlayMoveCommit playMoveFromRoot(Move move);
  bool switchRoot(NodeId node, std::string* error);
  bool markVisible(NodeId node, bool value);
  bool isAncestorOrSelf(NodeId ancestor, NodeId node) const;
  // True iff `node` lies in the current root's subtree (including the root).
  bool isInCurrentRootSubtree(NodeId node) const;
  // Min-depth visit predicate for the active root (requires subtree membership).
  bool rootHasVisitedNode(NodeId node) const;
  std::optional<NodeId> findVisibleNodeByLineage(uint64_t lineageHash) const;
  bool runPlayout();
  void runPlayouts(uint32_t count);
  // Full UI-facing snapshot (all visible nodes). Prefer snapshotLight for poll paths.
  RootSnapshot snapshot() const;
  // Bounded snapshot for high-frequency UI polls. Caps candidates and visibleTree size;
  // always includes the current root lineage chain when possible.
  RootSnapshot snapshotLight(
    size_t maxCandidates = 10,
    size_t maxVisibleNodes = 4096,
    bool includeOwnership = true
  ) const;
  /// O(1) display fill: root metrics + top-K candidates + optional ownership[361].
  /// Does not walk visibleTree. maxCandidates is capped at kAnalyzeDisplayMaxCandidates.
  void fillAnalyzeDisplay(
    AnalyzeDisplayPayload& out,
    size_t maxCandidates = kAnalyzeDisplayMaxCandidates,
    bool includeOwnership = true
  ) const;
  StoreMemoryStats memoryStats() const;
  MCTSStore cloneVisibleRecord(
    const Rules& rules,
    const AnalysisKey& analysisKey,
    const SearchParams& searchParams,
    std::string* error
  ) const;
  /// Fast model-switch helper: only the path from game root to current root (O(ply)),
  /// not the full visible variation tree.
  MCTSStore cloneCurrentRootPath(
    const Rules& rules,
    const AnalysisKey& analysisKey,
    const SearchParams& searchParams,
    std::string* error
  ) const;
  bool mergeVisibleRecordFrom(const MCTSStore& source, std::string* error);

  std::vector<uint8_t> serialize() const;

  /// One-shot durable write for OOM unload / checkpoint: serialize once, atomic replace once.
  /// Does not stream progress and does not write nodes as separate records.
  bool persistToFile(const std::string& path, std::string* error) const;

  /// Progress callback kept for optional diagnostics only; product unload/reload never uses it.
  struct DeserializeProgress {
    std::string phase;
    double fraction = 0.0;
    uint64_t unitsDone = 0;
    uint64_t unitsTotal = 0;
    std::string message;
  };
  using DeserializeProgressFn = std::function<void(const DeserializeProgress&)>;

  static std::optional<MCTSStore> deserialize(
    const std::vector<uint8_t>& bytes,
    std::string* error,
    const DeserializeProgressFn& progress = {}
  );
  static std::optional<MCTSStore> deserialize(
    const uint8_t* data,
    size_t size,
    std::string* error,
    const DeserializeProgressFn& progress = {}
  );
  /// One-shot file load for OOM rehydrate: mmap/read the whole blob once, parse once.
  /// No streaming progress. Prefer this over any multi-pass or chunk-progress path.
  static std::optional<MCTSStore> loadFromFile(
    const std::string& path,
    uint64_t maxBytes,
    std::string* error
  );
  /// Alias of loadFromFile (progress argument is ignored; kept for call-site compatibility).
  static std::optional<MCTSStore> deserializeFromFile(
    const std::string& path,
    uint64_t maxBytes,
    std::string* error,
    const DeserializeProgressFn& progress = {}
  );

  const std::vector<Node>& nodeArray() const { return nodes; }
  const std::vector<Action>& actionArray() const { return actions; }

private:
  struct Path {
    std::vector<NodeId> nodes;
    std::vector<ActionId> actions;
    // Absolute depth (node.ply) → node on this selection path. Filled during select.
    std::array<NodeId, kSearchChainDepthMapLen> byDepth{};

    void clear() {
      nodes.clear();
      actions.clear();
      byDepth.fill(kInvalidNode);
    }

    void recordDepth(NodeId id, uint32_t ply) {
      if(ply < kSearchChainDepthMapLen)
        byDepth[ply] = id;
    }
  };

  struct ThreadState {
    BoardState board;
  };

  BoardState initialBoardState;
  Rules storeRules;
  AnalysisKey key;
  SearchParams params;
  std::vector<Node> nodes;
  std::vector<Action> actions;
  std::unordered_map<uint64_t, NodeId> childIndex;
  std::vector<float> policyArena;
  std::vector<float> ownershipArena;
  std::vector<NodeId> ancestorArena;
  std::vector<uint8_t> visible;
  std::unordered_map<uint64_t, NodeId> visibleLineageIndex;
  NodeId root = kInvalidNode;
  /// Current root board (shared_ptr for O(1) switchRoot install).
  std::shared_ptr<const BoardState> rootBoardPtr;
  /// Per-node board cache for O(1) switchRoot. Runtime-only.
  std::vector<std::shared_ptr<const BoardState>> boardCacheByNode;
  uint64_t playoutSeq = 0;
  uint64_t rootSessionSeq = 0;
  Evaluator* evaluator = nullptr;
  TreeSelectionMode treeSelectionMode_ = TreeSelectionMode::puct;

  static uint64_t childKey(NodeId parent, Move move);
  static uint64_t initialLineageHash(const BoardState& board);
  static uint64_t childLineageHash(uint64_t parentHash, Move move, Color pla);
  NodeId createInitialNode();
  NodeId createChildLink(NodeId parent, Move move, const BoardState& childBoard);
  void storeBoardCache(NodeId node, BoardState board);
  std::shared_ptr<const BoardState> boardCacheFor(NodeId node) const;
  std::shared_ptr<const BoardState> ensureBoardCache(NodeId node);
  std::optional<BoardState> materializePosition(NodeId node) const;
  ActionId findAction(NodeId parent, Move move) const;
  ActionId getOrCreateAction(NodeId parent, Move move);
  bool expandNode(NodeId node, const LeafPayload& leaf, const std::array<bool, kMoveCount>& legalMask);
  bool storeNNOutput(NodeId node, const LeafPayload& leaf);
  bool loadStoredNNOutput(NodeId node, LeafPayload& leaf) const;
  void markVisitedByCurrentRoot(NodeId node);
  bool selectPathToLeaf(ThreadState& state, Path& path, NodeId& leaf);
  ActionId selectAction(NodeId parent, bool isRoot);
  ActionId selectActionByNnPolicyOnly(NodeId parent);
  float scoreAction(const Node& parent, Move move, float prior, const Action* action, bool isRoot) const;
  float policyPrior(const Node& parent, Move move) const;
  float valueForSelection(const ScalarStats& stats, Color pla) const;
  bool evaluateLeaf(const ThreadState& state, NodeId leafNode, bool isRoot, LeafPayload& leaf);
  // priorMinVisitedRootDepth is the leaf's d_min *before* markVisitedByCurrentRoot.
  //   - never visited (∞): backup entire path leaf → current root
  //   - previously visited under a deeper root: update leaf + father(node@d_min) → root
  void backup(const Path& path, const LeafPayload& leaf, uint32_t priorMinVisitedRootDepth);
  void updateNodeStats(Node& node, const LeafPayload& leaf, float weight);
  void updateActionStats(Action& action, const LeafPayload& leaf, float weight);
  void updateOwnershipMean(Node& node, const std::array<float, kOwnershipDim>& ownership, float weight);
  static void updateScalarStats(ScalarStats& stats, const LeafPayload& leaf, float utility, float weight);
  float displayWinrate(const ScalarStats& stats, Color pla) const;
  float displayScoreMean(const ScalarStats& stats, Color pla) const;
  /// Quality of `playedMove` vs peers at `parent` (side-to-move polarity).
  /// Extreme-low (STM ≤ 5%): score-loss scale; else winrate-loss percentage points.
  /// Returns false when the played move has no visited peer baseline.
  bool qualityDeltaPercentForParentAction(
    const Node& parent,
    Move playedMove,
    float& outQualityDeltaPercent
  ) const;
};

} // namespace qixi::core
