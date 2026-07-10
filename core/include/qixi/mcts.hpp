#pragma once

#include "qixi/board.hpp"

#include <atomic>
#include <memory>
#include <mutex>
#include <optional>
#include <random>
#include <unordered_map>

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
  uint32_t ownershipOffset = kInvalidNode;
  uint64_t lineageHash = 0;
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
  void setEvaluator(Evaluator* evaluator);

  std::array<bool, kMoveCount> legalMoveMask() const;
  PlayMoveCommit playMoveFromRoot(Move move);
  bool switchRoot(NodeId node, std::string* error);
  bool markVisible(NodeId node, bool value);
  bool isAncestorOrSelf(NodeId ancestor, NodeId node) const;
  std::optional<NodeId> findVisibleNodeByLineage(uint64_t lineageHash) const;
  bool runPlayout();
  void runPlayouts(uint32_t count);
  RootSnapshot snapshot() const;
  StoreMemoryStats memoryStats() const;
  MCTSStore cloneVisibleRecord(
    const Rules& rules,
    const AnalysisKey& analysisKey,
    const SearchParams& searchParams,
    std::string* error
  ) const;
  bool mergeVisibleRecordFrom(const MCTSStore& source, std::string* error);

  std::vector<uint8_t> serialize() const;
  static std::optional<MCTSStore> deserialize(const std::vector<uint8_t>& bytes, std::string* error);

  const std::vector<Node>& nodeArray() const { return nodes; }
  const std::vector<Action>& actionArray() const { return actions; }

private:
  struct Path {
    std::vector<NodeId> nodes;
    std::vector<ActionId> actions;
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
  BoardState rootBoardState;
  uint64_t playoutSeq = 0;
  uint64_t rootSessionSeq = 0;
  Evaluator* evaluator = nullptr;

  static uint64_t childKey(NodeId parent, Move move);
  static uint64_t initialLineageHash(const BoardState& board);
  static uint64_t childLineageHash(uint64_t parentHash, Move move, Color pla);
  NodeId createInitialNode();
  NodeId createChildLink(NodeId parent, Move move, const BoardState& childBoard);
  std::optional<BoardState> materializePosition(NodeId node) const;
  ActionId findAction(NodeId parent, Move move) const;
  ActionId getOrCreateAction(NodeId parent, Move move);
  bool expandNode(NodeId node, const LeafPayload& leaf, const std::array<bool, kMoveCount>& legalMask);
  bool selectPathToLeaf(ThreadState& state, Path& path, NodeId& leaf);
  ActionId selectAction(NodeId parent, bool isRoot);
  float scoreAction(const Node& parent, Move move, float prior, const Action* action, bool isRoot) const;
  float policyPrior(const Node& parent, Move move) const;
  float valueForSelection(const ScalarStats& stats, Color pla) const;
  bool evaluateLeaf(const ThreadState& state, bool isRoot, LeafPayload& leaf);
  void backup(const Path& path, const LeafPayload& leaf);
  void updateNodeStats(Node& node, const LeafPayload& leaf, float weight);
  void updateActionStats(Action& action, const LeafPayload& leaf, float weight);
  void updateOwnershipMean(Node& node, const std::array<float, kOwnershipDim>& ownership, float weight);
  static void updateScalarStats(ScalarStats& stats, const LeafPayload& leaf, float utility, float weight);
  float displayWinrate(const ScalarStats& stats, Color pla) const;
  float displayScoreMean(const ScalarStats& stats, Color pla) const;
};

} // namespace qixi::core
