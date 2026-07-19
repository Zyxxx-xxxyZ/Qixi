#include "qixi/mcts.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_set>

namespace qixi::core {
namespace {

float clamp01(float value) {
  if(value < 0.0f)
    return 0.0f;
  if(value > 1.0f)
    return 1.0f;
  return value;
}

uint64_t mixDeterministic(uint64_t value) {              //value -> hashed_value
  value += 0x9e3779b97f4a7c15ULL;
  value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9ULL;
  value = (value ^ (value >> 27)) * 0x94d049bb133111ebULL;
  return value ^ (value >> 31);
}

double deterministicUnit(uint64_t value) {
  return (static_cast<double>(mixDeterministic(value) >> 11) + 0.5) /
    static_cast<double>(1ULL << 53);
}

//bool terminalByPasses(const BoardState& board) {    //double pass -> terminate the game
//  const size_t count = board.moves.size();
//  return count >= 2 &&
//    board.moves[count - 1].move == kMovePass &&
//    board.moves[count - 2].move == kMovePass;
//}

bool validLeafPayload(const LeafPayload& leaf) {    // to check whether a node is valid
  if(!std::isfinite(leaf.weight) || leaf.weight <= 0.0f ||
     !std::isfinite(leaf.winLossWhite) || leaf.winLossWhite < -1.0f || leaf.winLossWhite > 1.0f ||
     !std::isfinite(leaf.noResult) || leaf.noResult < 0.0f || leaf.noResult > 1.0f ||
     !std::isfinite(leaf.scoreMeanWhite) ||
     !std::isfinite(leaf.scoreMeanSqWhite) || leaf.scoreMeanSqWhite < 0.0f ||
     !std::isfinite(leaf.leadWhite) || !std::isfinite(leaf.utilityWhite))
    return false;
  for(float value : leaf.ownership) {
    if(!std::isfinite(value) || value < -1.0f || value > 1.0f)
      return false;
  }
  for(float value : leaf.policy) {
    if(!std::isfinite(value) || value < -1.0f || value > 1.0f)
      return false;
  }
  return true;
}

float whiteScoreLead(const BoardState& board, const Rules& rules) {
  int blackStones = 0;
  int whiteStones = 0;
  int blackTerritory = 0;
  int whiteTerritory = 0;
  std::array<uint8_t, kBoardArea> visited{};
  std::vector<Move> stack;
  stack.reserve(kBoardArea);

  for(Move move = 0; move < kBoardArea; ++move) {
    const Color color = board.cells[move];
    if(color == Color::black) {
      blackStones += 1;
      continue;
    }
    if(color == Color::white) {
      whiteStones += 1;
      continue;
    }
    if(visited[move])
      continue;

    int regionSize = 0;
    bool bordersBlack = false;
    bool bordersWhite = false;
    stack.clear();
    stack.push_back(move);
    visited[move] = 1;
    while(!stack.empty()) {
      const Move current = stack.back();
      stack.pop_back();
      regionSize += 1;
      const Point point = moveToPoint(current);
      const std::array<Point, 4> neighbors = {{
        {point.x - 1, point.y}, {point.x + 1, point.y},
        {point.x, point.y - 1}, {point.x, point.y + 1},
      }};
      for(const Point neighbor : neighbors) {
        if(neighbor.x < 0 || neighbor.x >= kBoardLen ||
           neighbor.y < 0 || neighbor.y >= kBoardLen)
          continue;
        const Move neighborMove = pointToMove(neighbor.x, neighbor.y);
        const Color neighborColor = board.cells[neighborMove];
        if(neighborColor == Color::black)
          bordersBlack = true;
        else if(neighborColor == Color::white)
          bordersWhite = true;
        else if(!visited[neighborMove]) {
          visited[neighborMove] = 1;
          stack.push_back(neighborMove);
        }
      }
    }
    if(bordersBlack && !bordersWhite)
      blackTerritory += regionSize;
    else if(bordersWhite && !bordersBlack)
      whiteTerritory += regionSize;
  }

  int blackPrisoners = 0;
  int whitePrisoners = 0;
  for(const MoveRecord& record : board.moves) {
    if(record.pla == Color::black) {
      blackPrisoners += static_cast<int>(record.captured.size());
      whitePrisoners += static_cast<int>(record.removedOwn.size());
    }
    else if(record.pla == Color::white) {
      whitePrisoners += static_cast<int>(record.captured.size());
      blackPrisoners += static_cast<int>(record.removedOwn.size());
    }
  }

  const int blackScore = rules.scoringRule == ScoringRule::area
    ? blackStones + blackTerritory
    : blackTerritory + blackPrisoners;
  const int whiteScore = rules.scoringRule == ScoringRule::area
    ? whiteStones + whiteTerritory
    : whiteTerritory + whitePrisoners;
  return static_cast<float>(whiteScore - blackScore) + rules.komi;
}

class ByteWriter {
public:
  void writeU8(uint8_t value) {
    bytes.push_back(value);
  }

  void writeU16(uint16_t value) {
    for(int shift = 0; shift < 16; shift += 8)
      bytes.push_back(static_cast<uint8_t>((value >> shift) & 0xffU));
  }

  void writeU32(uint32_t value) {
    for(int shift = 0; shift < 32; shift += 8)
      bytes.push_back(static_cast<uint8_t>((value >> shift) & 0xffU));
  }

  void writeU64(uint64_t value) {
    for(int shift = 0; shift < 64; shift += 8)
      bytes.push_back(static_cast<uint8_t>((value >> shift) & 0xffULL));
  }

  void writeI32(int32_t value) {
    writeU32(static_cast<uint32_t>(value));
  }

  void writeFloat(float value) {
    uint32_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value), "float must be IEEE-754 binary32");
    std::memcpy(&bits, &value, sizeof(bits));
    writeU32(bits);
  }

  void writeBytes(const void* data, size_t size) {
    const auto* ptr = reinterpret_cast<const uint8_t*>(data);
    bytes.insert(bytes.end(), ptr, ptr + size);
  }

  std::vector<uint8_t> bytes;
};

class ByteReader {
public:
  explicit ByteReader(const std::vector<uint8_t>& data, size_t byteLimit)
    : ptr(data.data()), limit(std::min(byteLimit, data.size())) {}

  explicit ByteReader(const uint8_t* data, size_t byteLimit)
    : ptr(data), limit(byteLimit) {}

  bool readU8(uint8_t& value) {
    if(offset + 1 > limit)
      return false;
    value = ptr[offset++];
    return true;
  }

  bool readU16(uint16_t& value) {
    uint64_t decoded = 0;
    if(!readUnsigned(2, decoded))
      return false;
    value = static_cast<uint16_t>(decoded);
    return true;
  }

  bool readU32(uint32_t& value) {
    uint64_t decoded = 0;
    if(!readUnsigned(4, decoded))
      return false;
    value = static_cast<uint32_t>(decoded);
    return true;
  }

  bool readU64(uint64_t& value) {
    return readUnsigned(8, value);
  }

  bool readI32(int32_t& value) {
    uint32_t decoded = 0;
    if(!readU32(decoded))
      return false;
    value = static_cast<int32_t>(decoded);
    return true;
  }

  bool readFloat(float& value) {
    uint32_t bits = 0;
    if(!readU32(bits))
      return false;
    std::memcpy(&value, &bits, sizeof(value));
    return std::isfinite(value);
  }

  bool readBytes(void* dst, size_t size) {
    if(offset + size > limit)
      return false;
    std::memcpy(dst, ptr + offset, size);
    offset += size;
    return true;
  }

  bool atEnd() const {
    return offset == limit;
  }

  size_t remaining() const {
    return limit - offset;
  }

  size_t position() const {
    return offset;
  }

  size_t sizeLimit() const {
    return limit;
  }

private:
  bool readUnsigned(size_t count, uint64_t& value) {
    if(count > 8 || offset + count > limit)
      return false;
    value = 0;
    for(size_t i = 0; i < count; ++i)
      value |= static_cast<uint64_t>(ptr[offset++]) << (8 * i);
    return true;
  }

  const uint8_t* ptr = nullptr;
  size_t limit = 0;
  size_t offset = 0;
};

void reportDeserializeProgress(
  const MCTSStore::DeserializeProgressFn& progress,
  const char* phase,
  double fraction,
  uint64_t unitsDone = 0,
  uint64_t unitsTotal = 0,
  const char* message = ""
) {
  if(!progress)
    return;
  MCTSStore::DeserializeProgress p;
  p.phase = phase;
  p.fraction = std::max(0.0, std::min(1.0, fraction));
  p.unitsDone = unitsDone;
  p.unitsTotal = unitsTotal;
  p.message = message ? message : "";
  progress(p);
}

uint64_t checksum64Progress(
  const uint8_t* bytes,
  size_t size,
  const MCTSStore::DeserializeProgressFn& progress,
  double fractionStart,
  double fractionEnd
) {
  uint64_t hash = 1469598103934665603ULL;
  constexpr size_t kReportEvery = 4ULL * 1024ULL * 1024ULL;
  size_t nextReport = kReportEvery;
  for(size_t i = 0; i < size; ++i) {
    hash ^= bytes[i];
    hash *= 1099511628211ULL;
    if(progress && (i + 1 == size || i + 1 >= nextReport)) {
      const double t = size == 0 ? 1.0 : static_cast<double>(i + 1) / static_cast<double>(size);
      reportDeserializeProgress(
        progress,
        "verifying",
        fractionStart + (fractionEnd - fractionStart) * t,
        static_cast<uint64_t>(i + 1),
        static_cast<uint64_t>(size),
        "Verifying checksum"
      );
      nextReport = i + 1 + kReportEvery;
    }
  }
  return hash;
}

// Raised from 512 MiB: policy-only oracle stress can grow multi-hundred-MiB trees.
// Must match product rehydrate cap in request_pool.cpp (kMaxCoreStateBytes).
// Writing a larger blob would make OOM unload unrestorable.
constexpr uint64_t kMaxSerializedBytes = 384ULL * 1024ULL * 1024ULL;
constexpr uint64_t kMaxSerializedNodes = 5000000ULL;
constexpr uint64_t kMaxSerializedActions = 20000000ULL;
constexpr uint64_t kMaxArenaElements = 120000000ULL;

uint64_t checksum64(const uint8_t* bytes, size_t size) {
  uint64_t hash = 1469598103934665603ULL;
  for(size_t i = 0; i < size; ++i) {
    hash ^= bytes[i];
    hash *= 1099511628211ULL;
  }
  return hash;
}

uint64_t decodeTrailingU64(const uint8_t* bytes, size_t size) {
  uint64_t value = 0;
  const size_t start = size - sizeof(uint64_t);
  for(size_t i = 0; i < sizeof(uint64_t); ++i)
    value |= static_cast<uint64_t>(bytes[start + i]) << (8 * i);
  return value;
}

uint64_t decodeTrailingU64(const std::vector<uint8_t>& bytes) {
  return decodeTrailingU64(bytes.data(), bytes.size());
}

} // namespace

bool UniformEvaluator::evaluate(
  const BoardState& board,
  const Rules& rules,
  bool /*isRoot*/,
  LeafPayload& output
) {
  output = LeafPayload{};
  const float score = whiteScoreLead(board, rules);
  output.scoreMeanWhite = score;
  output.scoreMeanSqWhite = score * score;
  output.leadWhite = score;
  output.winLossWhite = clamp01(0.5f + score / 80.0f) * 2.0f - 1.0f;
  output.utilityWhite = output.winLossWhite;
  output.noResult = 0.0f;
  for(int i = 0; i < kOwnershipDim; ++i) {
    if(board.cells[static_cast<size_t>(i)] == Color::white)
      output.ownership[static_cast<size_t>(i)] = 1.0f;
    else if(board.cells[static_cast<size_t>(i)] == Color::black)
      output.ownership[static_cast<size_t>(i)] = -1.0f;
    else
      output.ownership[static_cast<size_t>(i)] = 0.0f;
  }
  const auto legal = BoardLogic::legalMoveMask(board, rules);
  int count = 0;
  for(bool value : legal) {
    if(value)
      count += 1;
  }
  const float p = count > 0 ? 1.0f / static_cast<float>(count) : 0.0f;
  for(int i = 0; i < kMoveCount; ++i)
    output.policy[static_cast<size_t>(i)] = legal[static_cast<size_t>(i)] ? p : -1.0f;
  output.weight = 1.0f;
  return true;
}

MCTSStore MCTSStore::create(
  const BoardState& initialBoard,
  const Rules& rules,
  const AnalysisKey& key,
  const SearchParams& params
) {
  MCTSStore store;
  store.initialBoardState = initialBoard;
  store.storeRules = rules;
  store.key = key;
  store.params = params;
  // Force AnalysisKey fields that validate() cross-checks against rules/params.
  // Inconsistent keys used to serialize fine and then fail closed on every load.
  store.key.rulesHash = hashRules(store.storeRules);
  store.key.komiKey = komiToKey(store.storeRules.komi);
  store.key.wideRootNoiseKey = wideRootNoiseToKey(store.params.rootNoise);
  store.key.playoutDoublingAdvantageKey =
    playoutDoublingAdvantageToKey(store.params.playoutDoublingAdvantage);
  store.params.searchForPla = initialBoard.nextPla;
  store.root = store.createInitialNode();
  store.rootBoardPtr = store.boardCacheFor(store.root);
  if(!store.rootBoardPtr)
    store.rootBoardPtr = std::make_shared<const BoardState>(initialBoard);
  store.visible.resize(store.nodes.size(), 0);
  store.visible[store.root] = 1;
  return store;
}

NodeId MCTSStore::currentRoot() const {
  return root;
}

const BoardState& MCTSStore::rootBoard() const {
  static const BoardState kEmpty = BoardLogic::emptyBoard();
  return rootBoardPtr ? *rootBoardPtr : kEmpty;
}

const Rules& MCTSStore::rules() const {
  return storeRules;
}

const AnalysisKey& MCTSStore::analysisKey() const {
  return key;
}

const SearchParams& MCTSStore::searchParams() const {
  return params;
}

void MCTSStore::assignImportedGameId(GameId gameId) {
  key.gameId = gameId;
}

void MCTSStore::rekeyModelId(ModelId modelId) {
  key.modelId = modelId;
}

void MCTSStore::setEvaluator(Evaluator* value) {
  evaluator = value;
  if(evaluator) {
    evaluator->setPlayoutDoublingAdvantage(
      params.playoutDoublingAdvantage,
      params.playoutDoublingAdvantagePla,
      params.searchForPla
    );
  }
}

bool MCTSStore::setTreeSelectionMode(
  TreeSelectionMode mode,
  uint64_t allowToken,
  std::string* error
) {
  if(mode == TreeSelectionMode::puct) {
    treeSelectionMode_ = TreeSelectionMode::puct;
    return true;
  }
  if(mode != TreeSelectionMode::testNnPolicyOnly) {
    if(error) *error = "unknown tree selection mode";
    return false;
  }
#if !defined(QIXI_ALLOW_TEST_SELECTION_MODES) || !QIXI_ALLOW_TEST_SELECTION_MODES
  if(error) {
    *error =
      "testNnPolicyOnly selection is disabled in this build "
      "(requires -DQIXI_ALLOW_TEST_SELECTION_MODES=1)";
  }
  treeSelectionMode_ = TreeSelectionMode::puct;
  return false;
#else
  if(allowToken != kTestSelectionModeAllowToken) {
    if(error) *error = "refusing test selection mode without allow token";
    treeSelectionMode_ = TreeSelectionMode::puct;
    return false;
  }
  treeSelectionMode_ = TreeSelectionMode::testNnPolicyOnly;
  return true;
#endif
}

uint64_t MCTSStore::childKey(NodeId parent, Move move) {
  return (static_cast<uint64_t>(parent) << 32) | static_cast<uint64_t>(move);
}

uint64_t MCTSStore::initialLineageHash(const BoardState& board) {
  uint64_t hash = 0x514958494C494E45ULL;
  auto append = [&](uint64_t value) {
    hash = mixDeterministic(hash ^ mixDeterministic(value + 0x9e3779b97f4a7c15ULL));
  };
  for(Color color : board.cells)
    append(static_cast<uint64_t>(color));
  append(static_cast<uint64_t>(board.nextPla));
  append(static_cast<uint32_t>(board.simpleKoPoint));
  append(board.boardHashHistory.size());
  for(uint64_t value : board.boardHashHistory)
    append(value);
  append(board.situationHashHistory.size());
  for(uint64_t value : board.situationHashHistory)
    append(value);
  append(board.moves.size());
  for(const MoveRecord& record : board.moves) {
    append(record.move);
    append(static_cast<uint64_t>(record.pla));
    append(static_cast<uint32_t>(record.previousSimpleKoPoint));
    append(record.captured.size());
    for(Move move : record.captured)
      append(move);
    append(record.removedOwn.size());
    for(Move move : record.removedOwn)
      append(move);
  }
  return hash;
}

uint64_t MCTSStore::childLineageHash(uint64_t parentHash, Move move, Color pla) {
  uint64_t hash = mixDeterministic(parentHash ^ 0x4348494C444C494EULL);
  hash = mixDeterministic(hash ^ static_cast<uint64_t>(move));
  return mixDeterministic(hash ^ (static_cast<uint64_t>(pla) << 48));
}

NodeId MCTSStore::createInitialNode() {
  Node node;
  node.id = 0;
  node.parent = kInvalidNode;
  node.moveFromParent = kMovePass;
  node.ply = 0;
  node.nextPla = initialBoardState.nextPla;
  node.lineageHash = initialLineageHash(initialBoardState);
  nodes.push_back(node);
  nodes.back().ancestorOffset = static_cast<uint32_t>(ancestorArena.size());
  nodes.back().ancestorCount = 1;
  ancestorArena.push_back(node.id);
  visibleLineageIndex.emplace(node.lineageHash, node.id);
  storeBoardCache(0, initialBoardState);
  return node.id;
}

NodeId MCTSStore::createChildLink(NodeId parent, Move move, const BoardState& childBoard) {
  const uint64_t keyValue = childKey(parent, move);
  const auto found = childIndex.find(keyValue);
  if(found != childIndex.end())
    return found->second;

  Node node;
  node.id = static_cast<NodeId>(nodes.size());
  node.parent = parent;
  node.moveFromParent = move;
  node.movePla = nodes[parent].nextPla;
  node.ply = nodes[parent].ply + 1;
  node.nextPla = childBoard.nextPla;
  node.lineageHash = childLineageHash(nodes[parent].lineageHash, move, nodes[parent].nextPla);
  const Node& parentNode = nodes[parent];
  node.ancestorOffset = static_cast<uint32_t>(ancestorArena.size());
  node.ancestorCount = static_cast<uint16_t>(parentNode.ancestorCount + 1);
  for(uint32_t depth = 0; depth < parentNode.ancestorCount; ++depth)
    ancestorArena.push_back(ancestorArena[parentNode.ancestorOffset + depth]);
  ancestorArena.push_back(node.id);
  nodes.push_back(node);
  visible.push_back(0);
  childIndex.emplace(keyValue, node.id);
  storeBoardCache(node.id, childBoard);
  return node.id;
}

void MCTSStore::storeBoardCache(NodeId node, BoardState board) {
  if(node >= nodes.size())
    return;
  if(boardCacheByNode.size() < nodes.size())
    boardCacheByNode.resize(nodes.size());
  boardCacheByNode[node] = std::make_shared<const BoardState>(std::move(board));
}

std::shared_ptr<const BoardState> MCTSStore::boardCacheFor(NodeId node) const {
  if(node >= boardCacheByNode.size())
    return nullptr;
  return boardCacheByNode[node];
}

std::shared_ptr<const BoardState> MCTSStore::ensureBoardCache(NodeId node) {
  if(node >= nodes.size())
    return nullptr;
  if(auto existing = boardCacheFor(node))
    return existing;
  auto materialized = materializePosition(node);
  if(!materialized)
    return nullptr;
  storeBoardCache(node, std::move(*materialized));
  return boardCacheFor(node);
}

std::optional<BoardState> MCTSStore::materializePosition(NodeId node) const {
  if(node >= nodes.size())
    return std::nullopt;
  if(auto cached = boardCacheFor(node))
    return *cached;
  std::vector<Move> moves;
  NodeId current = node;
  while(current != kInvalidNode) {
    const Node& n = nodes[current];
    if(n.parent != kInvalidNode)
      moves.push_back(n.moveFromParent);
    current = n.parent;
  }
  std::reverse(moves.begin(), moves.end());

  BoardState board = initialBoardState;
  for(Move move : moves) {
    InPlaceMoveResult result = BoardLogic::playMoveInPlace(board, storeRules, move);
    if(!result.legal)
      return std::nullopt;
  }
  return board;
}

bool MCTSStore::switchRoot(NodeId node, std::string* error) {
  if(node >= nodes.size()) {
    if(error)
      *error = "target node is out of range";
    return false;
  }
  // O(1) path: shared_ptr assign (cache miss fills once, amortized).
  auto cached = ensureBoardCache(node);
  if(!cached) {
    if(error)
      *error = "could not materialize target node";
    return false;
  }
  root = node;
  rootBoardPtr = std::move(cached);
  rootSessionSeq += 1;
  params.searchForPla = rootBoardPtr->nextPla;
  if(evaluator) {
    evaluator->setPlayoutDoublingAdvantage(
      params.playoutDoublingAdvantage,
      params.playoutDoublingAdvantagePla,
      params.searchForPla
    );
  }
  // Checkpoint/validate require the current root to be visible. Search leaves many
  // nodes invisible; without this, autosave/OOM unload fail after a root switch.
  markVisible(node, true);
  return true;
}

bool MCTSStore::markVisible(NodeId node, bool value) {
  if(node >= nodes.size())
    return false;
  visible[node] = value ? 1 : 0;
  if(value)
    visibleLineageIndex[nodes[node].lineageHash] = node;
  else
    visibleLineageIndex.erase(nodes[node].lineageHash);
  if(value) {
    NodeId current = nodes[node].parent;
    while(current != kInvalidNode) {
      visible[current] = 1;
      visibleLineageIndex[nodes[current].lineageHash] = current;
      current = nodes[current].parent;
    }
  }
  return true;
}

bool MCTSStore::isAncestorOrSelf(NodeId ancestor, NodeId node) const {
  if(ancestor >= nodes.size() || node >= nodes.size())
    return false;
  const Node& ancestorNode = nodes[ancestor];
  const Node& nodeValue = nodes[node];
  if(ancestorNode.ply > nodeValue.ply || ancestorNode.ply >= nodeValue.ancestorCount)
    return false;
  const uint64_t index = static_cast<uint64_t>(nodeValue.ancestorOffset) + ancestorNode.ply;
  return index < ancestorArena.size() && ancestorArena[static_cast<size_t>(index)] == ancestor;
}

std::optional<NodeId> MCTSStore::findVisibleNodeByLineage(uint64_t lineageHash) const {
  const auto found = visibleLineageIndex.find(lineageHash);
  if(found == visibleLineageIndex.end())
    return std::nullopt;
  if(found->second >= nodes.size() || found->second >= visible.size() || !visible[found->second])
    return std::nullopt;
  return found->second;
}

std::array<bool, kMoveCount> MCTSStore::legalMoveMask() const {
  return BoardLogic::legalMoveMask(rootBoard(), storeRules);
}

PlayMoveCommit MCTSStore::playMoveFromRoot(Move move) {
  PlayMoveCommit commit;
  const BoardState& beforeRef = rootBoard();
  LegalResult result = BoardLogic::playMove(beforeRef, storeRules, move);
  if(!result.legal) {
    commit.error = result.reason.empty() ? "illegal move" : result.reason;
    return commit;
  }
  const Color pla = beforeRef.nextPla;
  const NodeId child = createChildLink(root, move, result.next);
  // Link parent action → child so FIFO redo / PV walk can follow played moves
  // even when the parent has not been searched yet.
  (void)getOrCreateAction(root, move);
  // createChildLink already stores board cache for child.
  markVisible(child, true);
  root = child;
  rootBoardPtr = boardCacheFor(child);
  if(!rootBoardPtr) {
    storeBoardCache(child, result.next);
    rootBoardPtr = boardCacheFor(child);
  }
  rootSessionSeq += 1;
  commit.ok = true;
  commit.node = child;
  commit.patch = BoardLogic::patchBetween(beforeRef, *rootBoardPtr, move, pla);
  return commit;
}

ActionId MCTSStore::findAction(NodeId parent, Move move) const {
  if(parent >= nodes.size())
    return kInvalidAction;
  ActionId actionId = nodes[parent].firstAction;
  uint32_t traversed = 0;
  while(actionId != kInvalidAction && traversed < nodes[parent].actionCount) {
    if(actionId >= actions.size())
      return kInvalidAction;
    if(actions[actionId].move == move)
      return actionId;
    actionId = actions[actionId].nextAction;
    traversed += 1;
  }
  return kInvalidAction;
}

ActionId MCTSStore::getOrCreateAction(NodeId parent, Move move) {
  const ActionId existing = findAction(parent, move);
  if(existing != kInvalidAction)
    return existing;
  if(parent >= nodes.size() || move >= kMoveCount)
    return kInvalidAction;
  Action action;
  action.parent = parent;
  action.move = move;
  action.nextAction = nodes[parent].firstAction;
  const auto child = childIndex.find(childKey(parent, move));
  if(child != childIndex.end())
    action.child = child->second;
  const ActionId id = static_cast<ActionId>(actions.size());
  actions.push_back(action);
  nodes[parent].firstAction = id;
  nodes[parent].actionCount += 1;
  return id;
}

bool MCTSStore::storeNNOutput(NodeId nodeId, const LeafPayload& leaf) {
  if(nodeId >= nodes.size() || !validLeafPayload(leaf))
    return false;
  Node& node = nodes[nodeId];
  if(node.hasStoredNN)
    return true;
  node.hasStoredNN = true;
  node.nnWinLossWhite = leaf.winLossWhite;
  node.nnNoResult = leaf.noResult;
  node.nnScoreMeanWhite = leaf.scoreMeanWhite;
  node.nnScoreMeanSqWhite = leaf.scoreMeanSqWhite;
  node.nnLeadWhite = leaf.leadWhite;
  node.nnUtilityWhite = leaf.utilityWhite;
  node.nnWeight = leaf.weight;
  node.nnOwnershipOffset = static_cast<uint32_t>(ownershipArena.size());
  ownershipArena.resize(ownershipArena.size() + kOwnershipDim, 0.0f);
  std::copy(leaf.ownership.begin(), leaf.ownership.end(), ownershipArena.begin() + node.nnOwnershipOffset);
  return true;
}

bool MCTSStore::loadStoredNNOutput(NodeId nodeId, LeafPayload& leaf) const {
  if(nodeId >= nodes.size())
    return false;
  const Node& node = nodes[nodeId];
  if(!node.hasStoredNN ||
     node.policyOffset == kInvalidNode ||
     static_cast<uint64_t>(node.policyOffset) + kMoveCount > policyArena.size() ||
     node.nnOwnershipOffset == kInvalidNode ||
     static_cast<uint64_t>(node.nnOwnershipOffset) + kOwnershipDim > ownershipArena.size())
    return false;
  leaf = LeafPayload{};
  leaf.winLossWhite = node.nnWinLossWhite;
  leaf.noResult = node.nnNoResult;
  leaf.scoreMeanWhite = node.nnScoreMeanWhite;
  leaf.scoreMeanSqWhite = node.nnScoreMeanSqWhite;
  leaf.leadWhite = node.nnLeadWhite;
  leaf.utilityWhite = node.nnUtilityWhite;
  leaf.weight = node.nnWeight;
  std::copy(
    policyArena.begin() + node.policyOffset,
    policyArena.begin() + node.policyOffset + kMoveCount,
    leaf.policy.begin()
  );
  std::copy(
    ownershipArena.begin() + node.nnOwnershipOffset,
    ownershipArena.begin() + node.nnOwnershipOffset + kOwnershipDim,
    leaf.ownership.begin()
  );
  return true;
}

void MCTSStore::markVisitedByCurrentRoot(NodeId nodeId) {
  if(nodeId >= nodes.size() || root >= nodes.size())
    return;
  if(!isAncestorOrSelf(root, nodeId))
    return;
  const uint32_t rootDepth = nodes[root].ply;
  Node& node = nodes[nodeId];
  if(node.minVisitedRootDepth > rootDepth)
    node.minVisitedRootDepth = rootDepth;
}

bool MCTSStore::isInCurrentRootSubtree(NodeId node) const {
  if(root >= nodes.size() || node >= nodes.size())
    return false;
  return isAncestorOrSelf(root, node);
}

bool MCTSStore::rootHasVisitedNode(NodeId node) const {
  if(!isInCurrentRootSubtree(node))
    return false;
  if(root >= nodes.size() || node >= nodes.size())
    return false;
  // Root R has visited N iff depth(R) >= shallowest root-depth that visited N.
  return nodes[root].ply >= nodes[node].minVisitedRootDepth;
}

bool MCTSStore::expandNode(NodeId nodeId, const LeafPayload& leaf, const std::array<bool, kMoveCount>& legalMask) {
  if(nodeId >= nodes.size())
    return false;
  Node& node = nodes[nodeId];
  if(node.state == NodeState::expanded || node.state == NodeState::terminal)
    return true;

  float sum = 0.0f;
  for(int i = 0; i < kMoveCount; ++i) {
    if(legalMask[i])
      sum += std::max(0.0f, leaf.policy[i]);
  }
  int legalCount = 0;
  for(bool legal : legalMask) {
    if(legal)
      legalCount += 1;
  }
  if(legalCount <= 0) {
    node.state = NodeState::terminal;
    if(!storeNNOutput(nodeId, leaf))
      return false;
    return true;
  }

  node.policyOffset = static_cast<uint32_t>(policyArena.size());
  policyArena.resize(policyArena.size() + kMoveCount, -1.0f);
  for(int i = 0; i < kMoveCount; ++i) {
    if(!legalMask[i])
      continue;
    policyArena[node.policyOffset + i] = sum > 0.0f
      ? std::max(0.0f, leaf.policy[i]) / sum
      : 1.0f / static_cast<float>(legalCount);
  }
  // Store raw NN leaf once. Subsequent roots reuse this payload instead of
  // treating the node as a brand-new unevaluated leaf solely because another
  // root expanded it earlier.
  if(!storeNNOutput(nodeId, leaf))
    return false;
  node.state = NodeState::expanded;
  return true;
}

bool MCTSStore::selectPathToLeaf(ThreadState& state, Path& path, NodeId& leaf) {
  path.clear();
  NodeId current = root;
  path.nodes.push_back(current);
  path.recordDepth(current, nodes[current].ply);

  while(true) {
    Node& node = nodes[current];
//    if(terminalByPasses(state.board)) {
//      node.state = NodeState::terminal;
//      leaf = current;
//      return true;
//    }
    // First-visit barrier for the *current root*:
    // even if the node is already expanded (NN stored under another root), a
    // root that has not yet visited it must stop here and perform exactly one
    // first visit under this root (using stored NN when available).
    if(node.state != NodeState::expanded || !rootHasVisitedNode(current)) {
      leaf = current;
      return true;
    }
    const ActionId actionId = selectAction(current, current == root);
    if(actionId == kInvalidAction) {
      leaf = current;
      return true;
    }
    const Move move = actions[actionId].move;
    InPlaceMoveResult result = BoardLogic::playMoveInPlace(state.board, storeRules, move);
    if(!result.legal) {
      leaf = current;
      return false;
    }
    NodeId child = createChildLink(current, move, state.board);
    actions[actionId].child = child;
    path.actions.push_back(actionId);
    path.nodes.push_back(child);
    path.recordDepth(child, nodes[child].ply);
    current = child;
  }
}

ActionId MCTSStore::selectActionByNnPolicyOnly(NodeId parentId) {
  // TEST-ONLY path: sample a legal child proportional to the stored NN prior.
  // Visit counts, Q-values, FPU, and root noise are intentionally ignored so
  // prior MCTS traffic through a node cannot bias successor choice.
  const Node& parent = nodes[parentId];
  if(parent.policyOffset == kInvalidNode ||
     static_cast<uint64_t>(parent.policyOffset) + kMoveCount > policyArena.size())
    return kInvalidAction;

  float priorSum = 0.0f;
  for(Move move = 0; move < kMoveCount; ++move) {
    const float prior = policyArena[parent.policyOffset + move];
    if(prior > 0.0f)
      priorSum += prior;
  }
  if(priorSum <= 0.0f)
    return kInvalidAction;

  // Deterministic unit draw from store seed, playout index, and parent id so
  // two engines with the same NN priors and seed follow the same trajectory
  // regardless of visit statistics.
  const uint64_t keyValue = params.seed ^
    (playoutSeq * 0x9e3779b97f4a7c15ULL) ^
    (static_cast<uint64_t>(parentId) * 0xbf58476d1ce4e5b9ULL) ^
    0x504f4c594f4e4c59ULL; // "POLYONLY"
  const double u = deterministicUnit(keyValue) * static_cast<double>(priorSum);
  double cumulative = 0.0;
  Move chosen = kMovePass;
  bool found = false;
  for(Move move = 0; move < kMoveCount; ++move) {
    const float prior = policyArena[parent.policyOffset + move];
    if(prior <= 0.0f)
      continue;
    cumulative += static_cast<double>(prior);
    if(!found || u <= cumulative) {
      chosen = move;
      found = true;
      if(u <= cumulative)
        break;
    }
  }
  if(!found)
    return kInvalidAction;
  return getOrCreateAction(parentId, chosen);
}

namespace {

// Official TOTALCHILDWEIGHT_PUCT_OFFSET
constexpr float kPuctChildWeightOffset = 0.01f;

float edgeWeight(const Action& action) {
  // Edge-local only — never scale by child node visits (child may have been root).
  if(action.stats.weightSum > 0.0f && std::isfinite(action.stats.weightSum))
    return action.stats.weightSum;
  return static_cast<float>(action.visits);
}

float cpuctExplorationTerm(float totalChildWeight, const SearchParams& params) {
  const float base = std::max(1.0f, params.cpuctExplorationBase);
  const float w = std::max(0.0f, totalChildWeight);
  return params.cpuct +
    params.cpuctExplorationLog * std::log((w + base) / base);
}

float exploreScaling(float totalChildWeight, const SearchParams& params) {
  const float w = std::max(0.0f, totalChildWeight);
  return cpuctExplorationTerm(w, params) * std::sqrt(w + kPuctChildWeightOffset);
}

} // namespace

ActionId MCTSStore::selectAction(NodeId parentId, bool isRoot) {
  if(treeSelectionMode_ == TreeSelectionMode::testNnPolicyOnly) {
#if !defined(QIXI_ALLOW_TEST_SELECTION_MODES) || !QIXI_ALLOW_TEST_SELECTION_MODES
    // Defense in depth: even if the enum were corrupted, never run the test
    // selector in production builds.
    treeSelectionMode_ = TreeSelectionMode::puct;
#else
    return selectActionByNnPolicyOnly(parentId);
#endif
  }

  const Node& parent = nodes[parentId];
  if(parent.policyOffset == kInvalidNode ||
     static_cast<uint64_t>(parent.policyOffset) + kMoveCount > policyArena.size())
    return kInvalidAction;
  std::array<ActionId, kMoveCount> actionByMove;
  actionByMove.fill(kInvalidAction);
  ActionId current = parent.firstAction;
  uint32_t traversed = 0;
  while(current != kInvalidAction && traversed < parent.actionCount) {
    if(current >= actions.size())
      return kInvalidAction;
    if(actions[current].move < kMoveCount)
      actionByMove[actions[current].move] = current;
    current = actions[current].nextAction;
    traversed += 1;
  }

  // Precompute edge-local W and policy mass of tried edges (Contract A).
  float totalChildWeight = 0.0f;
  float policyProbMassVisited = 0.0f;
  for(Move move = 0; move < kMoveCount; ++move) {
    const float prior = policyArena[parent.policyOffset + move];
    if(prior < 0.0f)
      continue;
    const ActionId actionId = actionByMove[move];
    if(actionId == kInvalidAction || actionId >= actions.size())
      continue;
    const Action& action = actions[actionId];
    if(action.visits == 0)
      continue;
    totalChildWeight += edgeWeight(action);
    policyProbMassVisited += prior;
  }
  if(policyProbMassVisited > 1.0001f)
    policyProbMassVisited = 1.0f;

  const float scaling = exploreScaling(totalChildWeight, params);
  const float fpu = fpuValueForChildren(parent, isRoot, policyProbMassVisited);

  float bestScore = -1.0e30f;
  Move bestMove = kMovePass;
  ActionId bestActionId = kInvalidAction;
  bool found = false;

  // Phase 1: score all edge-tried actions.
  for(Move move = 0; move < kMoveCount; ++move) {
    float prior = policyArena[parent.policyOffset + move];
    if(prior < 0.0f)
      continue;
    const ActionId actionId = actionByMove[move];
    if(actionId == kInvalidAction || actionId >= actions.size())
      continue;
    const Action& action = actions[actionId];
    if(action.visits == 0)
      continue;
    const float score = scoreActionEdge(
      parent, move, prior, &action, /*edgeTried=*/true, scaling, fpu, isRoot
    );
    if(!found || score > bestScore) {
      bestScore = score;
      bestMove = move;
      bestActionId = actionId;
      found = true;
    }
  }

  // Phase 2: single best-policy untried legal move (official structure).
  Move bestNewMove = kMovePass;
  float bestNewPrior = -1.0f;
  bool hasNew = false;
  for(Move move = 0; move < kMoveCount; ++move) {
    const float prior = policyArena[parent.policyOffset + move];
    if(prior < 0.0f)
      continue;
    const ActionId actionId = actionByMove[move];
    if(actionId != kInvalidAction && actionId < actions.size() && actions[actionId].visits > 0)
      continue;
    if(!hasNew || prior > bestNewPrior) {
      bestNewPrior = prior;
      bestNewMove = move;
      hasNew = true;
    }
  }
  if(hasNew) {
    const ActionId actionId = actionByMove[bestNewMove];
    const Action* action =
      (actionId != kInvalidAction && actionId < actions.size()) ? &actions[actionId] : nullptr;
    const float score = scoreActionEdge(
      parent, bestNewMove, bestNewPrior, action, /*edgeTried=*/false, scaling, fpu, isRoot
    );
    if(!found || score > bestScore) {
      bestScore = score;
      bestMove = bestNewMove;
      bestActionId = actionId;
      found = true;
    }
  }

  if(!found)
    return kInvalidAction;
  return bestActionId != kInvalidAction
    ? bestActionId
    : getOrCreateAction(parentId, bestMove);
}

float MCTSStore::fpuValueForChildren(
  const Node& parent,
  bool isRoot,
  float policyProbMassVisited
) const {
  // Parent-relative FPU on the same utility scale as edge backups (white-centered utilityMean).
  const float parentUtility = parent.visits > 0
    ? parent.stats.utilityMean
    : params.fpuValue;
  const float fpuReductionMax = isRoot ? params.rootFpuReductionMax : params.fpuReductionMax;
  const float reduction = fpuReductionMax * std::sqrt(std::max(0.0f, policyProbMassVisited));
  // Official: white FPU = parent - reduction; black FPU = parent + reduction (worse for the player).
  if(parent.nextPla == Color::white)
    return parentUtility - reduction;
  if(parent.nextPla == Color::black)
    return parentUtility + reduction;
  return parentUtility - reduction;
}

float MCTSStore::scoreActionEdge(
  const Node& parent,
  Move move,
  float prior,
  const Action* action,
  bool edgeTried,
  float exploreScalingValue,
  float fpuValue,
  bool isRoot
) const {
  (void)move;
  if(prior < 0.0f)
    return -1.0e30f;

  float childUtility = fpuValue;
  float childWeight = 0.0f;
  if(edgeTried && action != nullptr && action->visits > 0) {
    // Edge-local Q only (Contract A) — never child node utility.
    childUtility = action->stats.utilityMean;
    childWeight = edgeWeight(*action);
  }

  float nnPolicyProb = prior;
  if(isRoot && params.rootNoise > 0.0f && nnPolicyProb >= 0.0f) {
    nnPolicyProb = std::pow(nnPolicyProb, 1.0f / (4.0f * params.rootNoise + 1.0f));
    const uint64_t keyValue = params.seed ^
      (rootSessionSeq * 0x9e3779b97f4a7c15ULL) ^
      (playoutSeq * 0xbf58476d1ce4e5b9ULL) ^
      static_cast<uint64_t>(move);
    const double u1 = std::max(1.0e-12, deterministicUnit(keyValue));
    const double u2 = deterministicUnit(keyValue ^ 0x94d049bb133111ebULL);
    const float gaussianMagnitude = static_cast<float>(
      std::fabs(std::sqrt(-2.0 * std::log(u1)) * std::cos(6.28318530717958647692 * u2))
    );
    if((mixDeterministic(keyValue ^ 0x517869ULL) & 1ULL) != 0) {
      if(parent.nextPla == Color::white)
        childUtility += params.rootNoise * gaussianMagnitude;
      else
        childUtility -= params.rootNoise * gaussianMagnitude;
    }
  }

  const float exploreComponent =
    exploreScalingValue * nnPolicyProb / (1.0f + childWeight);
  const float valueComponent = valueForSelectionUtility(childUtility, parent.nextPla);
  return exploreComponent + valueComponent;
}

float MCTSStore::scoreAction(
  const Node& parent,
  Move move,
  float prior,
  const Action* action,
  bool isRoot
) const {
  // Compatibility entry: recompute scaling/FPU for a single edge (tests / call sites).
  float totalChildWeight = 0.0f;
  float policyMass = 0.0f;
  ActionId current = parent.firstAction;
  uint32_t traversed = 0;
  while(current != kInvalidAction && traversed < parent.actionCount) {
    if(current >= actions.size())
      break;
    const Action& a = actions[current];
    if(a.visits > 0) {
      totalChildWeight += edgeWeight(a);
      const float p = policyPrior(parent, a.move);
      if(p >= 0.0f)
        policyMass += p;
    }
    current = a.nextAction;
    traversed += 1;
  }
  if(policyMass > 1.0001f)
    policyMass = 1.0f;
  const float scaling = exploreScaling(totalChildWeight, params);
  const float fpu = fpuValueForChildren(parent, isRoot, policyMass);
  const bool edgeTried = action != nullptr && action->visits > 0;
  return scoreActionEdge(parent, move, prior, action, edgeTried, scaling, fpu, isRoot);
}

float MCTSStore::policyPrior(const Node& parent, Move move) const {
  if(move >= kMoveCount || parent.policyOffset == kInvalidNode ||
     static_cast<uint64_t>(parent.policyOffset) + kMoveCount > policyArena.size())
    return -1.0f;
  return policyArena[parent.policyOffset + move];
}

float MCTSStore::valueForSelection(const ScalarStats& stats, Color pla) const {
  return valueForSelectionUtility(stats.utilityMean, pla);
}

float MCTSStore::valueForSelectionUtility(float utilityWhite, Color pla) const {
  if(pla == Color::white)
    return utilityWhite;
  if(pla == Color::black)
    return -utilityWhite;
  return utilityWhite;
}

bool MCTSStore::evaluateLeaf(
  const ThreadState& state,
  NodeId leafNode,
  bool isRoot,
  LeafPayload& leaf
) {
//  if(terminalByPasses(state.board)) {
//    leaf = LeafPayload{};
//    const float score = whiteScoreLead(state.board, storeRules);
//    leaf.scoreMeanWhite = score;
//    leaf.scoreMeanSqWhite = score * score;
//    leaf.leadWhite = score;
//    leaf.winLossWhite = score > 0.0f ? 1.0f : (score < 0.0f ? -1.0f : 0.0f);
//    leaf.utilityWhite = leaf.winLossWhite;
//    leaf.weight = 1.0f;
//    for(int i = 0; i < kOwnershipDim; ++i) {
//      if(state.board.cells[i] == Color::white)
//        leaf.ownership[i] = 1.0f;
//      else if(state.board.cells[i] == Color::black)
//        leaf.ownership[i] = -1.0f;
//      else
//        leaf.ownership[i] = 0.0f;
//    }
//    return true;
//  }
  // Prefer the once-stored NN output so a later root does not re-query the net
  // for a node that was already expanded under a different root.
  if(loadStoredNNOutput(leafNode, leaf))
    return true;
  if(!evaluator)
    return false;
  return evaluator->evaluate(state.board, storeRules, isRoot, leaf);
}

bool MCTSStore::runPlayout() {
  if(root >= nodes.size())
    return false;
  if(nodes[root].state == NodeState::terminal && rootHasVisitedNode(root) && nodes[root].visits > 0)
    return false;
  ThreadState state{rootBoard()};
  Path path;
  NodeId leafNode = kInvalidNode;
  if(!selectPathToLeaf(state, path, leafNode))
    return false;

  // Exactly-once visit under the current root: never re-enter a node this root
  // has already visited as a first-visit leaf.
  if(rootHasVisitedNode(leafNode) && nodes[leafNode].state == NodeState::expanded) {
    // Path selection should not stop on an already-visited expanded node; if it
    // did, selection is stuck (no legal continuation).
    return false;
  }

  LeafPayload leaf;
  if(!evaluateLeaf(state, leafNode, path.nodes.size() == 1, leaf))
    return false;
  if(!validLeafPayload(leaf))
    return false;

  if(nodes[leafNode].state == NodeState::unexpanded) {
    const auto legal = BoardLogic::legalMoveMask(state.board, storeRules);
    if(!expandNode(leafNode, leaf, legal))
      return false;
  } else if(!nodes[leafNode].hasStoredNN) {
    // Expanded without stored NN should not happen under v4 semantics; repair.
    if(!storeNNOutput(leafNode, leaf))
      return false;
  }

  // Capture d_min *before* labeling so backup can avoid double-updating the
  // segment that was already trained under a deeper historical root.
  const uint32_t priorMinVisitedRootDepth = nodes[leafNode].minVisitedRootDepth;
  markVisitedByCurrentRoot(leafNode);
  backup(path, leaf, priorMinVisitedRootDepth);
  playoutSeq += 1;
  return true;
}

void MCTSStore::runPlayouts(uint32_t count) {
  for(uint32_t i = 0; i < count; ++i) {
    if(!runPlayout())
      break;
  }
}

void MCTSStore::backup(
  const Path& path,
  const LeafPayload& leaf,
  uint32_t priorMinVisitedRootDepth
) {
  if(path.nodes.empty())
    return;

  // Case 1: leaf has never been searched under any root → full path to root.
  if(priorMinVisitedRootDepth == kNeverVisitedRootDepth) {
    for(size_t i = 0; i < path.nodes.size(); ++i) {
      updateNodeStats(nodes[path.nodes[i]], leaf, leaf.weight);
      if(i > 0)
        updateActionStats(actions[path.actions[i - 1]], leaf, leaf.weight);
    }
    return;
  }

  // Case 2: leaf was previously visited under a deeper root (d_min > d(R)).
  // Treating the leaf as new for the current (shallower) root is correct, but
  // re-backing the whole path double-updates parent(leaf) … node@d_min.
  // Correct/efficient backup:
  //   - always update the leaf itself
  //   - then update father(node at absolute depth d_min on this path) … current root
  //   - do NOT update node@d_min through parent(leaf)

  const NodeId leafId = path.nodes.back();
  updateNodeStats(nodes[leafId], leaf, leaf.weight);

  // Locate the historical-root node on this path at absolute depth d_min.
  size_t histIdx = path.nodes.size();
  if(priorMinVisitedRootDepth < kSearchChainDepthMapLen) {
    const NodeId mapped = path.byDepth[priorMinVisitedRootDepth];
    if(mapped != kInvalidNode) {
      for(size_t i = 0; i < path.nodes.size(); ++i) {
        if(path.nodes[i] == mapped) {
          histIdx = i;
          break;
        }
      }
    }
  }
  if(histIdx >= path.nodes.size()) {
    for(size_t i = 0; i < path.nodes.size(); ++i) {
      if(nodes[path.nodes[i]].ply == priorMinVisitedRootDepth) {
        histIdx = i;
        break;
      }
    }
  }
  if(histIdx >= path.nodes.size() || histIdx == 0) {
    // Historical root missing or is the current root (should not happen when
    // priorMin > d(R)); leaf-only update is the safe partial credit.
    return;
  }

  // path.nodes[0] = current root … path.nodes[histIdx] = node@d_min (= S).
  // Update nodes [0 .. histIdx-1] (father of S back to root).
  // Update actions only on edges fully above S (not the edge into S).
  for(size_t i = 0; i < histIdx; ++i) {
    // Leaf may equal path.nodes[histIdx] when d_min node's ply equals leaf;
    // avoid double-updating the leaf if it also appears in this range (it won't
    // for histIdx < last, and when histIdx == last the loop is parents only).
    if(path.nodes[i] == leafId)
      continue;
    updateNodeStats(nodes[path.nodes[i]], leaf, leaf.weight);
    // Action i connects nodes[i] → nodes[i+1]. Include only when i+1 < histIdx
    // so we never touch the action into S or anything below S.
    if(i + 1 < histIdx)
      updateActionStats(actions[path.actions[i]], leaf, leaf.weight);
  }
}

void MCTSStore::updateNodeStats(Node& node, const LeafPayload& leaf, float weight) {
  node.visits += 1;
  updateOwnershipMean(node, leaf.ownership, weight);
  updateScalarStats(node.stats, leaf, leaf.utilityWhite, weight);
}

void MCTSStore::updateActionStats(Action& action, const LeafPayload& leaf, float weight) {
  action.visits += 1;
  updateScalarStats(action.stats, leaf, leaf.utilityWhite, weight);
}

void MCTSStore::updateScalarStats(ScalarStats& stats, const LeafPayload& leaf, float utility, float weight) {
  const float oldWeight = stats.weightSum;
  const float newWeight = oldWeight + weight;
  if(newWeight <= 0.0f)
    return;
  const float alpha = weight / newWeight;
  auto upd = [&](float& mean, float sample) {
    mean += alpha * (sample - mean);
  };
  upd(stats.winLossMeanWhite, leaf.winLossWhite);
  upd(stats.noResultMean, leaf.noResult);
  upd(stats.scoreMeanWhite, leaf.scoreMeanWhite);
  upd(stats.scoreMeanSqWhite, leaf.scoreMeanSqWhite);
  upd(stats.leadMeanWhite, leaf.leadWhite);
  upd(stats.utilityMean, utility);
  upd(stats.utilitySqMean, utility * utility);
  stats.weightSum = newWeight;
  stats.weightSqSum += weight * weight;
}

void MCTSStore::updateOwnershipMean(Node& node, const std::array<float, kOwnershipDim>& ownership, float weight) {
  if(node.ownershipOffset == kInvalidNode) {
    node.ownershipOffset = static_cast<uint32_t>(ownershipArena.size());
    ownershipArena.resize(ownershipArena.size() + kOwnershipDim, 0.0f);
  }
  const float oldWeight = node.stats.weightSum;
  const float newWeight = oldWeight + weight;
  if(newWeight <= 0.0f)
    return;
  const float alpha = weight / newWeight;
  float* dst = ownershipArena.data() + node.ownershipOffset;
  for(int i = 0; i < kOwnershipDim; ++i)
    dst[i] += alpha * (ownership[i] - dst[i]);
}

float MCTSStore::displayWinrate(const ScalarStats& stats, Color pla) const {
  const float whiteWinrate = 0.5f * (stats.winLossMeanWhite + 1.0f);
  if(pla == Color::white)
    return whiteWinrate;
  if(pla == Color::black)
    return 1.0f - whiteWinrate;
  return whiteWinrate;
}

float MCTSStore::displayScoreMean(const ScalarStats& stats, Color pla) const {
  // Match official KataGo analysis JSON: user-facing "scoreMean" / "scoreLead" is the
  // lead head (whiteLead), not scoreSelfplay (whiteScoreMean). Selfplay score is often
  // roughly 2× lead on empty boards and is biased for display (see searchresults.cpp:
  // moveInfo["scoreMean"] = lead; moveInfo["scoreSelfplay"] = scoreMean).
  // Utility/PUCT still train on scoreMeanWhite via ScoreValue; only HUD/chart use lead.
  const float whiteLead = stats.leadMeanWhite;
  if(pla == Color::black)
    return -whiteLead;
  return whiteLead;
}

bool MCTSStore::qualityDeltaPercentForParentAction(
  const Node& parent,
  Move playedMove,
  float& outQualityDeltaPercent
) const {
  // Keep in sync with CandidatePalette.extremeLowWinrateAbsolute / scoreLossPaletteScale.
  constexpr float kExtremeLowWinrate = 0.05f;
  constexpr float kScoreLossPaletteScale = 2.5f;

  bool foundPlayed = false;
  bool foundAny = false;
  float playedWR = 0.0f;
  float playedScore = 0.0f;
  float bestWR = 0.0f;
  float bestScore = 0.0f;

  ActionId parentAction = parent.firstAction;
  uint32_t traversed = 0;
  while(parentAction != kInvalidAction && traversed < parent.actionCount) {
    if(parentAction >= actions.size())
      break;
    const Action& action = actions[parentAction];
    if(action.visits > 0) {
      // Metrics from the **parent side-to-move** (the player choosing among actions).
      const float wr = displayWinrate(action.stats, parent.nextPla);
      const float sc = displayScoreMean(action.stats, parent.nextPla);
      if(!foundAny) {
        bestWR = wr;
        bestScore = sc;
        foundAny = true;
      } else {
        if(wr > bestWR)
          bestWR = wr;
        if(sc > bestScore)
          bestScore = sc;
      }
      if(action.move == playedMove) {
        playedWR = wr;
        playedScore = sc;
        foundPlayed = true;
      }
    }
    parentAction = action.nextAction;
    traversed += 1;
  }
  if(!foundPlayed || !foundAny)
    return false;

  // Side-to-move winrate of the parent position (not Black's chart winrate).
  // Use min(parentSTM, bestPeer) so one optimistic peer just above 5% cannot
  // keep winrate-loss dyeing while the side to move is still crushed.
  const float parentSTM =
    parent.visits > 0 ? displayWinrate(parent.stats, parent.nextPla) : bestWR;
  const float effectiveSTM = std::min(bestWR, parentSTM);
  const bool extremeLow = effectiveSTM <= kExtremeLowWinrate;
  if(extremeLow) {
    // Score-loss mode: points behind best STM score, scaled into palette k-space.
    const float scoreLoss = std::max(0.0f, bestScore - playedScore);
    outQualityDeltaPercent = -scoreLoss * kScoreLossPaletteScale;
  } else {
    outQualityDeltaPercent = (playedWR - bestWR) * 100.0f;
  }
  return true;
}

RootSnapshot MCTSStore::snapshot() const {
  RootSnapshot snap;
  if(root >= nodes.size())
    return snap;
  const Node& rootNode = nodes[root];
  snap.root = root;
  snap.rootLineageHash = rootNode.lineageHash;
  snap.rootVisits = rootNode.visits;
  snap.rootWinrate = rootNode.visits > 0 ? displayWinrate(rootNode.stats, rootNode.nextPla) : 0.0f;
  snap.rootScoreMean = rootNode.visits > 0 ? displayScoreMean(rootNode.stats, rootNode.nextPla) : 0.0f;
  if(rootNode.ownershipOffset != kInvalidNode &&
     rootNode.ownershipOffset + kOwnershipDim <= ownershipArena.size()) {
    std::copy(
      ownershipArena.begin() + rootNode.ownershipOffset,
      ownershipArena.begin() + rootNode.ownershipOffset + kOwnershipDim,
      snap.ownership.begin()
    );
    snap.hasOwnership = true;
  }

  ActionId actionId = rootNode.firstAction;
  uint32_t traversed = 0;
  while(actionId != kInvalidAction && traversed < rootNode.actionCount) {
    if(actionId >= actions.size())
      break;
    const Action& action = actions[actionId];
    CandidateSnapshot candidate;
    candidate.move = action.move;
    candidate.visits = action.visits;
    candidate.prior = policyPrior(rootNode, action.move);
    candidate.winrate = action.visits > 0 ? displayWinrate(action.stats, rootNode.nextPla) : 0.0f;
    candidate.scoreMean = action.visits > 0 ? displayScoreMean(action.stats, rootNode.nextPla) : 0.0f;
    candidate.utility = action.stats.utilityMean;
    snap.candidates.push_back(candidate);
    actionId = action.nextAction;
    traversed += 1;
  }
  std::sort(snap.candidates.begin(), snap.candidates.end(), [](const auto& a, const auto& b) {
    if(a.visits != b.visits)
      return a.visits > b.visits;
    return a.prior > b.prior;
  });

  for(NodeId id = 0; id < nodes.size(); ++id) {
    if(id >= visible.size() || !visible[id])
      continue;
    const Node& node = nodes[id];
    NodeId parent = node.parent;
    while(parent != kInvalidNode && (parent >= visible.size() || !visible[parent]))
      parent = nodes[parent].parent;
    TreeNodeSnapshot item;
    item.id = id;
    item.lineageHash = node.lineageHash;
    item.parent = parent;
    item.moveFromParent = node.moveFromParent;
    item.movePla = node.movePla;
    item.ply = node.ply;
    item.visits = node.visits;
    item.analyzed = node.visits > 0;
    item.winrate = item.analyzed ? displayWinrate(node.stats, node.nextPla) : 0.0f;
    item.scoreMean = item.analyzed ? displayScoreMean(node.stats, node.nextPla) : 0.0f;
    if(node.parent != kInvalidNode && node.parent < nodes.size()) {
      float quality = 0.0f;
      if(qualityDeltaPercentForParentAction(nodes[node.parent], node.moveFromParent, quality)) {
        item.qualityDeltaPercent = quality;
        item.hasQualityDelta = true;
      }
    }
    snap.visibleTree.push_back(item);
  }
  std::sort(snap.visibleTree.begin(), snap.visibleTree.end(), [](const auto& a, const auto& b) {
    if(a.ply != b.ply)
      return a.ply < b.ply;
    return a.id < b.id;
  });
  return snap;
}

RootSnapshot MCTSStore::snapshotLight(
  size_t maxCandidates,
  size_t maxVisibleNodes,
  bool includeOwnership
) const {
  // True light path: do not allocate/walk a full visible-tree snapshot.
  RootSnapshot snap;
  if(root >= nodes.size())
    return snap;
  const Node& rootNode = nodes[root];
  snap.root = root;
  snap.rootLineageHash = rootNode.lineageHash;
  snap.rootVisits = rootNode.visits;
  snap.rootWinrate = rootNode.visits > 0 ? displayWinrate(rootNode.stats, rootNode.nextPla) : 0.0f;
  snap.rootScoreMean = rootNode.visits > 0 ? displayScoreMean(rootNode.stats, rootNode.nextPla) : 0.0f;

  if(includeOwnership &&
     rootNode.ownershipOffset != kInvalidNode &&
     rootNode.ownershipOffset + kOwnershipDim <= ownershipArena.size()) {
    std::copy(
      ownershipArena.begin() + rootNode.ownershipOffset,
      ownershipArena.begin() + rootNode.ownershipOffset + kOwnershipDim,
      snap.ownership.begin()
    );
    snap.hasOwnership = true;
  }

  // Top-K candidates from root actions only (same ordering as full snapshot).
  {
    AnalyzeDisplayPayload display{};
    fillAnalyzeDisplay(display, maxCandidates == 0 ? kAnalyzeDisplayMaxCandidates : maxCandidates, false);
    snap.candidates.reserve(display.candidateCount);
    for(uint32_t i = 0; i < display.candidateCount; ++i) {
      CandidateSnapshot candidate;
      candidate.move = display.candidates[i].move;
      candidate.visits = display.candidates[i].visits;
      candidate.winrate = display.candidates[i].winrate;
      candidate.scoreMean = display.candidates[i].scoreMean;
      // prior/utility not on display payload — leave default 0.
      snap.candidates.push_back(candidate);
    }
  }

  // Visible tree: always keep current-root path; then BFS-ish fill by ply from visible set.
  const size_t cap = maxVisibleNodes == 0 ? nodes.size() : maxVisibleNodes;
  std::unordered_set<NodeId> keep;
  keep.reserve(64);
  {
    NodeId cursor = root;
    while(cursor != kInvalidNode && cursor < nodes.size()) {
      keep.insert(cursor);
      if(nodes[cursor].parent == kInvalidNode)
        break;
      cursor = nodes[cursor].parent;
    }
  }

  auto fillTreeNode = [&](NodeId id) -> TreeNodeSnapshot {
    const Node& node = nodes[id];
    NodeId parent = node.parent;
    while(parent != kInvalidNode && (parent >= visible.size() || !visible[parent]))
      parent = nodes[parent].parent;
    TreeNodeSnapshot item;
    item.id = id;
    item.lineageHash = node.lineageHash;
    item.parent = parent;
    item.moveFromParent = node.moveFromParent;
    item.movePla = node.movePla;
    item.ply = node.ply;
    item.visits = node.visits;
    item.analyzed = node.visits > 0;
    item.winrate = item.analyzed ? displayWinrate(node.stats, node.nextPla) : 0.0f;
    item.scoreMean = item.analyzed ? displayScoreMean(node.stats, node.nextPla) : 0.0f;
    if(node.parent != kInvalidNode && node.parent < nodes.size()) {
      float quality = 0.0f;
      if(qualityDeltaPercentForParentAction(nodes[node.parent], node.moveFromParent, quality)) {
        item.qualityDeltaPercent = quality;
        item.hasQualityDelta = true;
      }
    }
    return item;
  };

  snap.visibleTree.reserve(std::min(cap, nodes.size()));
  for(NodeId id : keep) {
    if(id < nodes.size() && id < visible.size() && visible[id])
      snap.visibleTree.push_back(fillTreeNode(id));
  }
  if(snap.visibleTree.size() < cap) {
    // Add remaining visible nodes in id order until cap (cheap, deterministic).
    for(NodeId id = 0; id < nodes.size() && snap.visibleTree.size() < cap; ++id) {
      if(id >= visible.size() || !visible[id])
        continue;
      if(keep.count(id) != 0)
        continue;
      snap.visibleTree.push_back(fillTreeNode(id));
    }
  }
  std::sort(snap.visibleTree.begin(), snap.visibleTree.end(), [](const auto& a, const auto& b) {
    if(a.ply != b.ply)
      return a.ply < b.ply;
    return a.id < b.id;
  });
  return snap;
}

void MCTSStore::fillAnalyzeDisplay(
  AnalyzeDisplayPayload& out,
  size_t maxCandidates,
  bool includeOwnership
) const {
  out.root = root;
  out.candidateCount = 0;
  out.rootVisits = 0;
  out.rootWinrate = 0.5f;
  out.rootScoreMean = 0.0f;
  out.hasOwnership = 0;
  if(root >= nodes.size())
    return;

  const Node& rootNode = nodes[root];
  out.rootVisits = rootNode.visits;
  out.rootWinrate = rootNode.visits > 0 ? displayWinrate(rootNode.stats, rootNode.nextPla) : 0.5f;
  out.rootScoreMean = rootNode.visits > 0 ? displayScoreMean(rootNode.stats, rootNode.nextPla) : 0.0f;

  const size_t cap = std::min(maxCandidates, kAnalyzeDisplayMaxCandidates);
  // Online top-K by visits (then prior). O(B · K) with K≤10 — avoids 362-entry partial_sort.
  struct Entry {
    Move move = kMovePass;
    VisitCount visits = 0;
    float prior = 0.0f;
    float winrate = 0.0f;
    float scoreMean = 0.0f;
  };
  Entry top[kAnalyzeDisplayMaxCandidates];
  size_t topCount = 0;
  auto better = [](const Entry& a, const Entry& b) {
    if(a.visits != b.visits)
      return a.visits > b.visits;
    return a.prior > b.prior;
  };
  ActionId actionId = rootNode.firstAction;
  uint32_t traversed = 0;
  while(actionId != kInvalidAction && traversed < rootNode.actionCount) {
    if(actionId >= actions.size())
      break;
    const Action& action = actions[actionId];
    Entry e;
    e.move = action.move;
    e.visits = action.visits;
    e.prior = policyPrior(rootNode, action.move);
    e.winrate = action.visits > 0 ? displayWinrate(action.stats, rootNode.nextPla) : 0.0f;
    e.scoreMean = action.visits > 0 ? displayScoreMean(action.stats, rootNode.nextPla) : 0.0f;
    if(topCount < cap) {
      top[topCount++] = e;
      // Insertion keep small array sorted best→worst.
      for(size_t i = topCount - 1; i > 0; --i) {
        if(better(top[i], top[i - 1]))
          std::swap(top[i], top[i - 1]);
        else
          break;
      }
    } else if(better(e, top[cap - 1])) {
      top[cap - 1] = e;
      for(size_t i = cap - 1; i > 0; --i) {
        if(better(top[i], top[i - 1]))
          std::swap(top[i], top[i - 1]);
        else
          break;
      }
    }
    actionId = action.nextAction;
    traversed += 1;
  }
  out.candidateCount = static_cast<uint32_t>(topCount);
  for(size_t i = 0; i < topCount; ++i) {
    out.candidates[i].move = top[i].move;
    out.candidates[i].visits = static_cast<uint32_t>(std::min<VisitCount>(top[i].visits, 0xffffffffu));
    out.candidates[i].winrate = top[i].winrate;
    out.candidates[i].scoreMean = top[i].scoreMean;
  }

  if(includeOwnership &&
     rootNode.ownershipOffset != kInvalidNode &&
     rootNode.ownershipOffset + kOwnershipDim <= ownershipArena.size()) {
    std::copy(
      ownershipArena.begin() + rootNode.ownershipOffset,
      ownershipArena.begin() + rootNode.ownershipOffset + kOwnershipDim,
      out.ownership
    );
    out.hasOwnership = 1;
  }
}

StoreMemoryStats MCTSStore::memoryStats() const {
  StoreMemoryStats result;
  result.nodeCount = nodes.size();
  result.actionCount = actions.size();
  result.policyFloatCount = policyArena.size();
  result.ownershipFloatCount = ownershipArena.size();
  result.ancestorIdCount = ancestorArena.size();
  result.visibleByteCount = visible.size();
  result.estimatedArenaBytes =
    static_cast<uint64_t>(nodes.capacity()) * sizeof(Node) +
    static_cast<uint64_t>(actions.capacity()) * sizeof(Action) +
    static_cast<uint64_t>(policyArena.capacity()) * sizeof(float) +
    static_cast<uint64_t>(ownershipArena.capacity()) * sizeof(float) +
    static_cast<uint64_t>(ancestorArena.capacity()) * sizeof(NodeId) +
    static_cast<uint64_t>(visible.capacity()) * sizeof(uint8_t);
  return result;
}

MCTSStore MCTSStore::cloneVisibleRecord(
  const Rules& rules,
  const AnalysisKey& analysisKey,
  const SearchParams& searchParams,
  std::string* error
) const {
  if(error)
    error->clear();
  MCTSStore clone = MCTSStore::create(initialBoardState, rules, analysisKey, searchParams);
  std::unordered_map<NodeId, NodeId> mapped;
  mapped.emplace(0, 0);
  RootSnapshot record = snapshot();
  for(const TreeNodeSnapshot& item : record.visibleTree) {
    if(item.parent == kInvalidNode)
      continue;
    const auto parent = mapped.find(item.parent);
    if(parent == mapped.end()) {
      if(error) *error = "visible record is not parent-before-child ordered";
      return clone;
    }
    std::string switchError;
    if(!clone.switchRoot(parent->second, &switchError)) {
      if(error) *error = switchError;
      return clone;
    }
    PlayMoveCommit commit = clone.playMoveFromRoot(item.moveFromParent);
    if(!commit.ok) {
      if(error) *error = "visible record is illegal under target rules: " + commit.error;
      return clone;
    }
    mapped.emplace(item.id, commit.node);
  }
  const auto target = mapped.find(root);
  if(target == mapped.end()) {
    if(error) *error = "current root is absent from visible record";
    return clone;
  }
  std::string switchError;
  if(!clone.switchRoot(target->second, &switchError) && error)
    *error = switchError;
  return clone;
}

MCTSStore MCTSStore::cloneCurrentRootPath(
  const Rules& rules,
  const AnalysisKey& analysisKey,
  const SearchParams& searchParams,
  std::string* error
) const {
  if(error)
    error->clear();
  MCTSStore clone = MCTSStore::create(initialBoardState, rules, analysisKey, searchParams);
  if(root == kInvalidNode || root >= nodes.size()) {
    if(error) *error = "current root is invalid";
    return clone;
  }
  // Collect moves from game root → current root (O(ply)).
  std::vector<Move> pathMoves;
  NodeId cursor = root;
  while(cursor != kInvalidNode && cursor < nodes.size()) {
    const Node& node = nodes[cursor];
    if(node.parent == kInvalidNode)
      break;
    pathMoves.push_back(node.moveFromParent);
    cursor = node.parent;
  }
  std::reverse(pathMoves.begin(), pathMoves.end());
  for(Move move : pathMoves) {
    PlayMoveCommit commit = clone.playMoveFromRoot(move);
    if(!commit.ok) {
      if(error) *error = "current root path is illegal under target rules: " + commit.error;
      return clone;
    }
  }
  return clone;
}

bool MCTSStore::mergeVisibleRecordFrom(const MCTSStore& source, std::string* error) {
  if(error)
    error->clear();
  if(nodes.empty() || source.nodes.empty() ||
     nodes.front().lineageHash != source.nodes.front().lineageHash) {
    if(error) *error = "visible records have different initial lineages";
    return false;
  }

  const RootSnapshot record = source.snapshot();
  std::unordered_map<uint64_t, NodeId> mapped;
  mapped.reserve(record.visibleTree.size());
  for(const TreeNodeSnapshot& item : record.visibleTree) {
    if(item.parent == kInvalidNode) {
      mapped.emplace(item.lineageHash, 0);
      markVisible(0, true);
      continue;
    }
    if(item.parent >= source.nodes.size()) {
      if(error) *error = "source visible record parent is out of range";
      return false;
    }
    const uint64_t parentLineage = source.nodes[item.parent].lineageHash;
    const auto parent = mapped.find(parentLineage);
    if(parent == mapped.end()) {
      if(error) *error = "source visible record is not parent-before-child ordered";
      return false;
    }

    NodeId child = kInvalidNode;
    const auto existing = childIndex.find(childKey(parent->second, item.moveFromParent));
    if(existing != childIndex.end()) {
      child = existing->second;
      if(child >= nodes.size() || nodes[child].lineageHash != item.lineageHash) {
        if(error) *error = "target child lineage conflicts with source visible record";
        return false;
      }
    }
    else {
      auto parentBoard = materializePosition(parent->second);
      if(!parentBoard) {
        if(error) *error = "could not materialize target record parent";
        return false;
      }
      InPlaceMoveResult played = BoardLogic::playMoveInPlace(
        *parentBoard, storeRules, item.moveFromParent
      );
      if(!played.legal) {
        if(error) *error = "source visible record is illegal in target store: " + played.reason;
        return false;
      }
      child = createChildLink(parent->second, item.moveFromParent, *parentBoard);
      if(nodes[child].lineageHash != item.lineageHash) {
        if(error) *error = "new target child lineage does not match source visible record";
        return false;
      }
    }
    markVisible(child, true);
    mapped[item.lineageHash] = child;
  }

  const auto target = mapped.find(record.rootLineageHash);
  if(target == mapped.end()) {
    if(error) *error = "source current root is absent from its visible record";
    return false;
  }
  return switchRoot(target->second, error);
}

bool MCTSStore::validate(std::string* error) const {
  auto fail = [&](const char* message) {
    if(error)
      *error = message;
    return false;
  };
  auto validStats = [](const ScalarStats& stats) {
    return std::isfinite(stats.weightSum) && stats.weightSum >= 0.0f &&
      std::isfinite(stats.weightSqSum) && stats.weightSqSum >= 0.0f &&
      std::isfinite(stats.winLossMeanWhite) && stats.winLossMeanWhite >= -1.0f &&
      stats.winLossMeanWhite <= 1.0f &&
      std::isfinite(stats.noResultMean) && stats.noResultMean >= 0.0f &&
      stats.noResultMean <= 1.0f &&
      std::isfinite(stats.scoreMeanWhite) &&
      std::isfinite(stats.scoreMeanSqWhite) && stats.scoreMeanSqWhite >= 0.0f &&
      std::isfinite(stats.leadMeanWhite) &&
      std::isfinite(stats.utilityMean) &&
      std::isfinite(stats.utilitySqMean) && stats.utilitySqMean >= 0.0f;
  };
  if(!std::isfinite(storeRules.komi) ||
     !std::isfinite(params.cpuct) || params.cpuct < 0.0f ||
     !std::isfinite(params.cpuctExplorationLog) || params.cpuctExplorationLog < 0.0f ||
     !std::isfinite(params.cpuctExplorationBase) || params.cpuctExplorationBase <= 0.0f ||
     !std::isfinite(params.fpuReductionMax) || params.fpuReductionMax < 0.0f ||
     !std::isfinite(params.rootFpuReductionMax) || params.rootFpuReductionMax < 0.0f ||
     !std::isfinite(params.fpuValue) ||
     !std::isfinite(params.rootNoise) || params.rootNoise < 0.0f ||
     !std::isfinite(params.rootNoiseWeight) ||
     !std::isfinite(params.winLossUtilityFactor) ||
     !std::isfinite(params.staticScoreUtilityFactor) ||
     !std::isfinite(params.dynamicScoreUtilityFactor) ||
     !std::isfinite(params.playoutDoublingAdvantage) ||
     params.playoutDoublingAdvantage < -3.0f || params.playoutDoublingAdvantage > 3.0f)
    return fail("persisted rules or search parameters are not finite and valid");
  if(key.rulesHash != hashRules(storeRules) || key.komiKey != komiToKey(storeRules.komi) ||
     key.wideRootNoiseKey != wideRootNoiseToKey(params.rootNoise) ||
     key.playoutDoublingAdvantageKey !=
       playoutDoublingAdvantageToKey(params.playoutDoublingAdvantage)) {
    if(error) *error = "analysis key does not match persisted rules or search parameters";
    return false;
  }
  if(nodes.empty()) {
    if(error) *error = "nodes array is empty";
    return false;
  }
  if(root >= nodes.size()) {
    if(error) *error = "current root is out of range";
    return false;
  }
  if(root >= visible.size() || !visible[root]) {
    if(error) *error = "current root is not visible";
    return false;
  }
  if(visible.size() != nodes.size()) {
    if(error) *error = "visible array size mismatch";
    return false;
  }
  if(initialBoardState.boardHashHistory.size() != initialBoardState.moves.size() + 1 ||
     initialBoardState.situationHashHistory.size() != initialBoardState.moves.size() + 1 ||
     initialBoardState.boardHashHistory.empty() ||
     initialBoardState.boardHashHistory.back() != BoardLogic::boardHash(initialBoardState) ||
     initialBoardState.situationHashHistory.back() != BoardLogic::situationHash(initialBoardState))
    return fail("initial board history hashes are incomplete or inconsistent");
  if(initialBoardState.simpleKoPoint < -1 || initialBoardState.simpleKoPoint >= kBoardArea ||
     (initialBoardState.simpleKoPoint >= 0 &&
      initialBoardState.cells[static_cast<size_t>(initialBoardState.simpleKoPoint)] != Color::empty))
    return fail("initial board simple-ko point is invalid");
  for(Color color : initialBoardState.cells) {
    if(color != Color::empty && color != Color::black && color != Color::white)
      return fail("initial board contains an invalid color");
  }
  for(const MoveRecord& move : initialBoardState.moves) {
    if(move.move >= kMoveCount || (move.pla != Color::black && move.pla != Color::white) ||
       move.previousSimpleKoPoint < -1 || move.previousSimpleKoPoint >= kBoardArea)
      return fail("initial board move history contains invalid metadata");
    std::array<uint8_t, kBoardArea> seenRemoved{};
    for(Move captured : move.captured) {
      if(captured >= kBoardArea || seenRemoved[captured])
        return fail("initial board move history contains duplicate captured points");
      seenRemoved[captured] = 1;
    }
    for(Move removed : move.removedOwn) {
      if(removed >= kBoardArea || seenRemoved[removed])
        return fail("initial board move history contains duplicate removed points");
      seenRemoved[removed] = 1;
    }
  }
  if(!initialBoardState.moves.empty() &&
     initialBoardState.nextPla != opposite(initialBoardState.moves.back().pla))
    return fail("initial board next player does not follow its move history");
  for(float value : policyArena) {
    if(!std::isfinite(value) || value < -1.0f || value > 1.0f)
      return fail("policy arena contains an invalid probability");
  }
  for(float value : ownershipArena) {
    if(!std::isfinite(value) || value < -1.0f || value > 1.0f)
      return fail("ownership arena contains an invalid value");
  }
  if(policyArena.size() % kMoveCount != 0 || ownershipArena.size() % kOwnershipDim != 0)
    return fail("policy or ownership arena has a partial block");
  std::vector<uint8_t> usedPolicyBlocks(policyArena.size() / kMoveCount, 0);
  std::vector<uint8_t> usedOwnershipBlocks(ownershipArena.size() / kOwnershipDim, 0);
  uint64_t nextAncestorOffset = 0;
  std::unordered_map<uint64_t, NodeId> seenChildren;
  std::unordered_map<uint64_t, NodeId> seenVisibleLineages;
  std::vector<uint8_t> seenActions(actions.size(), 0);
  for(NodeId i = 0; i < nodes.size(); ++i) {
    const Node& node = nodes[i];
    if(node.id != i) {
      if(error) *error = "node id does not equal array index";
      return false;
    }
    if((i == 0 && (node.parent != kInvalidNode || node.ply != 0)) ||
       (i > 0 && (node.parent == kInvalidNode || node.parent >= i ||
                  node.ply != nodes[node.parent].ply + 1))) {
      if(error) *error = "node parent/depth ordering is invalid";
      return false;
    }
    if(node.parent != kInvalidNode && node.parent >= nodes.size()) {
      if(error) *error = "node parent out of range";
      return false;
    }
    if(node.parent != kInvalidNode) {
      if(node.movePla == Color::empty || node.movePla != nodes[node.parent].nextPla ||
         node.nextPla != opposite(node.movePla)) {
        if(error) *error = "node move color does not match parent turn";
        return false;
      }
      const uint64_t keyValue = childKey(node.parent, node.moveFromParent);
      auto inserted = seenChildren.emplace(keyValue, i);
      if(!inserted.second) {
        if(error) *error = "duplicate child link";
        return false;
      }
    }
    else if(node.movePla != Color::empty) {
      if(error) *error = "initial node unexpectedly has a move color";
      return false;
    }
    const uint64_t expectedLineage = node.parent == kInvalidNode
      ? initialLineageHash(initialBoardState)
      : childLineageHash(nodes[node.parent].lineageHash, node.moveFromParent, node.movePla);
    if(node.lineageHash != expectedLineage) {
      if(error) *error = "node lineage hash does not match its complete move lineage";
      return false;
    }
    if(node.ancestorCount != node.ply + 1 ||
       node.ancestorOffset != nextAncestorOffset ||
       static_cast<uint64_t>(node.ancestorOffset) + node.ancestorCount > ancestorArena.size()) {
      if(error) *error = "node ancestor range is invalid";
      return false;
    }
    nextAncestorOffset += node.ancestorCount;
    if(ancestorArena[node.ancestorOffset + node.ply] != i) {
      if(error) *error = "node ancestor range does not end in self";
      return false;
    }
    if(node.parent != kInvalidNode) {
      const Node& parent = nodes[node.parent];
      for(uint32_t depth = 0; depth < parent.ancestorCount; ++depth) {
        if(ancestorArena[node.ancestorOffset + depth] != ancestorArena[parent.ancestorOffset + depth]) {
          if(error) *error = "node ancestor range does not extend parent lineage";
          return false;
        }
      }
    }
    if(node.state == NodeState::expanded) {
      if(node.policyOffset == kInvalidNode ||
         node.policyOffset % kMoveCount != 0 ||
         static_cast<uint64_t>(node.policyOffset) + kMoveCount > policyArena.size() ||
         usedPolicyBlocks[node.policyOffset / kMoveCount]) {
        if(error) *error = "expanded node policy range is invalid";
        return false;
      }
      usedPolicyBlocks[node.policyOffset / kMoveCount] = 1;
    }
    else if(node.policyOffset != kInvalidNode) {
      if(error) *error = "unexpanded node unexpectedly owns policy data";
      return false;
    }
    if(!validStats(node.stats) ||
       ((node.visits == 0) != (node.stats.weightSum == 0.0f)))
      return fail("node visits and scalar statistics are inconsistent");
    ActionId currentAction = node.firstAction;
    uint32_t actionCount = 0;
    uint64_t actionVisitSum = 0;
    std::array<uint8_t, kMoveCount> seenMoves{};
    while(currentAction != kInvalidAction) {
      if(currentAction >= actions.size() || seenActions[currentAction]) {
        if(error) *error = "node action list is cyclic or out of range";
        return false;
      }
      seenActions[currentAction] = 1;
      const Action& action = actions[currentAction];
      if(action.parent != i) {
        if(error) *error = "node action list contains action with different parent";
        return false;
      }
      if(action.move >= kMoveCount || seenMoves[action.move]) {
        if(error) *error = "node action list contains duplicate or invalid move";
        return false;
      }
      seenMoves[action.move] = 1;
      // Search actions require an expanded parent with non-negative prior.
      // commitMove also creates action→child links for played moves *before*
      // the parent is expanded (redo / PV). Those navigation play-links are
      // valid when the child pointer is consistent, even without policy yet.
      const bool expandedWithPrior =
        node.state == NodeState::expanded && policyPrior(node, action.move) >= 0.0f;
      const bool navigationPlayLink =
        action.child != kInvalidNode &&
        action.child < nodes.size() &&
        nodes[action.child].parent == i &&
        nodes[action.child].moveFromParent == action.move;
      if(!expandedWithPrior && !navigationPlayLink) {
        if(error) *error = "action move is absent from parent policy";
        return false;
      }
      if(action.child != kInvalidNode) {
        if(action.child >= nodes.size() ||
           nodes[action.child].parent != i ||
           nodes[action.child].moveFromParent != action.move) {
          if(error) *error = "action child does not match canonical child link";
          return false;
        }
      }
      if(!validStats(action.stats) || action.visits > node.visits ||
         ((action.visits == 0) != (action.stats.weightSum == 0.0f)) ||
         actionVisitSum > node.visits - action.visits)
        return fail("action visits and scalar statistics are inconsistent");
      actionVisitSum += action.visits;
      currentAction = action.nextAction;
      actionCount += 1;
      if(actionCount > node.actionCount) {
        if(error) *error = "node action list exceeds recorded count";
        return false;
      }
    }
    if(actionCount != node.actionCount) {
      if(error) *error = "node action count mismatch";
      return false;
    }
    if(node.ownershipOffset == kInvalidNode) {
      if(node.visits != 0)
        return fail("visited node is missing aggregated ownership");
    }
    else {
      if(node.visits == 0 || node.ownershipOffset % kOwnershipDim != 0 ||
         static_cast<uint64_t>(node.ownershipOffset) + kOwnershipDim > ownershipArena.size() ||
         usedOwnershipBlocks[node.ownershipOffset / kOwnershipDim]) {
        if(error) *error = "node ownership range is invalid or aliased";
        return false;
      }
      usedOwnershipBlocks[node.ownershipOffset / kOwnershipDim] = 1;
    }
    // Raw NN ownership is a separate owned block (v4).
    if(node.hasStoredNN) {
      if(node.nnOwnershipOffset == kInvalidNode ||
         node.nnOwnershipOffset % kOwnershipDim != 0 ||
         static_cast<uint64_t>(node.nnOwnershipOffset) + kOwnershipDim > ownershipArena.size() ||
         usedOwnershipBlocks[node.nnOwnershipOffset / kOwnershipDim]) {
        if(error) *error = "stored NN ownership range is invalid or aliased";
        return false;
      }
      usedOwnershipBlocks[node.nnOwnershipOffset / kOwnershipDim] = 1;
    } else if(node.nnOwnershipOffset != kInvalidNode) {
      if(error) *error = "node without stored NN unexpectedly owns nnOwnership";
      return false;
    }
    if(visible[i]) {
      if(!seenVisibleLineages.emplace(node.lineageHash, i).second) {
        if(error) *error = "visible record contains duplicate lineage hashes";
        return false;
      }
      NodeId parent = node.parent;
      while(parent != kInvalidNode) {
        if(!visible[parent]) {
          if(error) *error = "visible node has invisible ancestor";
          return false;
        }
        parent = nodes[parent].parent;
      }
    }
  }
  for(ActionId i = 0; i < actions.size(); ++i) {
    if(!seenActions[i]) {
      if(error) *error = "orphaned action is not reachable from its parent";
      return false;
    }
  }
  if(nextAncestorOffset != ancestorArena.size() ||
     std::find(usedPolicyBlocks.begin(), usedPolicyBlocks.end(), 0) != usedPolicyBlocks.end() ||
     std::find(usedOwnershipBlocks.begin(), usedOwnershipBlocks.end(), 0) != usedOwnershipBlocks.end())
    return fail("serialized arenas contain gaps or unowned blocks");
  if(childIndex.size() != seenChildren.size()) {
    if(error) *error = "child index size mismatch";
    return false;
  }
  for(const auto& item : seenChildren) {
    const auto found = childIndex.find(item.first);
    if(found == childIndex.end() || found->second != item.second) {
      if(error) *error = "child index does not match node parent links";
      return false;
    }
  }
  if(visibleLineageIndex.size() != seenVisibleLineages.size()) {
    if(error) *error = "visible lineage index size mismatch";
    return false;
  }
  for(const auto& item : seenVisibleLineages) {
    const auto found = visibleLineageIndex.find(item.first);
    if(found == visibleLineageIndex.end() || found->second != item.second) {
      if(error) *error = "visible lineage index does not match visible nodes";
      return false;
    }
  }
  const auto materializedRoot = materializePosition(root);
  const BoardState& rootBoardRef = rootBoard();
  if(!materializedRoot || materializedRoot->cells != rootBoardRef.cells ||
     materializedRoot->nextPla != rootBoardRef.nextPla ||
     materializedRoot->simpleKoPoint != rootBoardRef.simpleKoPoint ||
     materializedRoot->boardHashHistory != rootBoardRef.boardHashHistory ||
     materializedRoot->situationHashHistory != rootBoardRef.situationHashHistory ||
     materializedRoot->moves.size() != rootBoardRef.moves.size())
    return fail("cached root board does not match its persistent lineage");
  return true;
}

std::vector<uint8_t> MCTSStore::serialize() const {
  ByteWriter w;
  uint64_t estimatedBytes = 512ULL +
    static_cast<uint64_t>(initialBoardState.boardHashHistory.size()) * 8ULL +
    static_cast<uint64_t>(initialBoardState.situationHashHistory.size()) * 8ULL +
    static_cast<uint64_t>(initialBoardState.moves.size()) * 15ULL +
    static_cast<uint64_t>(nodes.size()) * 126ULL +
    static_cast<uint64_t>(actions.size()) * 58ULL +
    static_cast<uint64_t>(policyArena.size()) * sizeof(float) +
    static_cast<uint64_t>(ownershipArena.size()) * sizeof(float) +
    static_cast<uint64_t>(ancestorArena.size()) * sizeof(NodeId) +
    static_cast<uint64_t>(visible.size());
  for(const MoveRecord& move : initialBoardState.moves) {
    estimatedBytes += static_cast<uint64_t>(move.captured.size() + move.removedOwn.size()) * 2ULL;
  }
  if(estimatedBytes > kMaxSerializedBytes)
    return {};
  w.bytes.reserve(static_cast<size_t>(estimatedBytes));
  auto writeStats = [&](const ScalarStats& stats) {
    w.writeFloat(stats.weightSum);
    w.writeFloat(stats.weightSqSum);
    w.writeFloat(stats.winLossMeanWhite);
    w.writeFloat(stats.noResultMean);
    w.writeFloat(stats.scoreMeanWhite);
    w.writeFloat(stats.scoreMeanSqWhite);
    w.writeFloat(stats.leadMeanWhite);
    w.writeFloat(stats.utilityMean);
    w.writeFloat(stats.utilitySqMean);
  };
  auto writeMoveVector = [&](const std::vector<Move>& moves) {
    w.writeU32(static_cast<uint32_t>(moves.size()));
    for(Move move : moves)
      w.writeU16(move);
  };

  w.writeU64(kPersistMagic);
  w.writeU32(kPersistVersion);
  w.writeU64(key.gameId);
  w.writeU8(static_cast<uint8_t>(key.modelId));
  w.writeU64(key.rulesHash);
  w.writeI32(key.komiKey);
  w.writeI32(key.wideRootNoiseKey);
  w.writeI32(key.playoutDoublingAdvantageKey);

  w.writeU8(static_cast<uint8_t>(storeRules.koRule));
  w.writeU8(static_cast<uint8_t>(storeRules.scoringRule));
  w.writeU8(static_cast<uint8_t>(storeRules.taxRule));
  w.writeU8(storeRules.multiStoneSuicideLegal ? 1 : 0);
  w.writeU8(storeRules.hasButton ? 1 : 0);
  w.writeU8(static_cast<uint8_t>(storeRules.whiteHandicapBonusRule));
  w.writeU8(storeRules.friendlyPassOk ? 1 : 0);
  w.writeFloat(storeRules.komi);

  w.writeFloat(params.cpuct);
  w.writeFloat(params.fpuValue);
  w.writeFloat(params.rootNoise);
  w.writeFloat(params.rootNoiseWeight);
  w.writeFloat(params.winLossUtilityFactor);
  w.writeFloat(params.staticScoreUtilityFactor);
  w.writeFloat(params.dynamicScoreUtilityFactor);
  // v5 fields
  w.writeFloat(params.cpuctExplorationLog);
  w.writeFloat(params.cpuctExplorationBase);
  w.writeFloat(params.fpuReductionMax);
  w.writeFloat(params.rootFpuReductionMax);
  w.writeFloat(params.playoutDoublingAdvantage);
  w.writeU8(static_cast<uint8_t>(params.playoutDoublingAdvantagePla));
  w.writeU64(params.seed);
  w.writeU32(root);
  w.writeU64(playoutSeq);
  w.writeU64(rootSessionSeq);

  for(Color color : initialBoardState.cells)
    w.writeU8(static_cast<uint8_t>(color));
  w.writeU8(static_cast<uint8_t>(initialBoardState.nextPla));
  w.writeI32(initialBoardState.simpleKoPoint);
  w.writeU64(initialBoardState.boardHashHistory.size());
  for(uint64_t hash : initialBoardState.boardHashHistory)
    w.writeU64(hash);
  w.writeU64(initialBoardState.situationHashHistory.size());
  for(uint64_t hash : initialBoardState.situationHashHistory)
    w.writeU64(hash);
  w.writeU64(initialBoardState.moves.size());
  for(const MoveRecord& move : initialBoardState.moves) {
    w.writeU16(move.move);
    w.writeU8(static_cast<uint8_t>(move.pla));
    w.writeI32(move.previousSimpleKoPoint);
    writeMoveVector(move.captured);
    writeMoveVector(move.removedOwn);
  }

  w.writeU64(nodes.size());
  w.writeU64(actions.size());
  w.writeU64(policyArena.size());
  w.writeU64(ownershipArena.size());
  w.writeU64(ancestorArena.size());
  w.writeU64(visible.size());
  for(const Node& node : nodes) {
    w.writeU32(node.id);
    w.writeU32(node.parent);
    w.writeU16(node.moveFromParent);
    w.writeU8(static_cast<uint8_t>(node.movePla));
    w.writeU32(node.ply);
    w.writeU8(static_cast<uint8_t>(node.nextPla));
    w.writeU8(static_cast<uint8_t>(node.state));
    w.writeU32(node.policyOffset);
    w.writeU32(node.firstAction);
    w.writeU16(node.actionCount);
    w.writeU16(node.ancestorCount);
    w.writeU32(node.ancestorOffset);
    w.writeU64(node.visits);
    writeStats(node.stats);
    w.writeU32(node.ownershipOffset);
    w.writeU64(node.lineageHash);
    // v4 persistent-visit + stored NN fields
    w.writeU32(node.minVisitedRootDepth);
    w.writeU8(node.hasStoredNN ? 1 : 0);
    w.writeFloat(node.nnWinLossWhite);
    w.writeFloat(node.nnNoResult);
    w.writeFloat(node.nnScoreMeanWhite);
    w.writeFloat(node.nnScoreMeanSqWhite);
    w.writeFloat(node.nnLeadWhite);
    w.writeFloat(node.nnUtilityWhite);
    w.writeFloat(node.nnWeight);
    w.writeU32(node.nnOwnershipOffset);
  }
  for(const Action& action : actions) {
    w.writeU32(action.parent);
    w.writeU32(action.child);
    w.writeU32(action.nextAction);
    w.writeU16(action.move);
    w.writeU64(action.visits);
    writeStats(action.stats);
  }
  // Bulk memory image of the large arenas (dominant on-disk size). On little-endian
  // IEEE-754 targets this is byte-identical to per-element writeFloat/writeU32.
  static_assert(sizeof(float) == 4, "policy/ownership bulk write assumes binary32 float");
  static_assert(sizeof(NodeId) == 4, "ancestor bulk write assumes 32-bit NodeId");
  if(!policyArena.empty())
    w.writeBytes(policyArena.data(), policyArena.size() * sizeof(float));
  if(!ownershipArena.empty())
    w.writeBytes(ownershipArena.data(), ownershipArena.size() * sizeof(float));
  if(!ancestorArena.empty())
    w.writeBytes(ancestorArena.data(), ancestorArena.size() * sizeof(NodeId));
  if(!visible.empty())
    w.writeBytes(visible.data(), visible.size());

  if(w.bytes.size() > kMaxSerializedBytes - sizeof(uint64_t))
    return {};
  const uint64_t checksum = checksum64(w.bytes.data(), w.bytes.size());
  w.writeU64(checksum);
  return std::move(w.bytes);
}

bool MCTSStore::persistToFile(const std::string& path, std::string* error) const {
  // Encode once into a contiguous memory image of the store, then fopen("wb") +
  // fwrite the whole blob and fread/mmap it back on load. No per-node file I/O.
  // (Arenas already dominate the blob size; this is a direct memory image write.)
  const std::vector<uint8_t> bytes = serialize();
  if(bytes.empty()) {
    if(error) *error = "serialized store exceeds the core-state byte limit";
    return false;
  }
  const std::string temp = path + ".tmp";
  auto requireRegularOrMissing = [&](const std::string& candidate, bool removeRegular) {
    struct stat metadata;
    if(lstat(candidate.c_str(), &metadata) != 0)
      return errno == ENOENT;
    if(!S_ISREG(metadata.st_mode))
      return false;
    return !removeRegular || std::remove(candidate.c_str()) == 0;
  };
  if(!requireRegularOrMissing(path, false)) {
    if(error) *error = "output target is not a regular file or is inaccessible: " + path;
    return false;
  }
  if(!requireRegularOrMissing(temp, true)) {
    if(error) *error = "temporary output target is not a removable regular file: " + temp;
    return false;
  }

  FILE* file = std::fopen(temp.c_str(), "wb");
  if(file == nullptr) {
    if(error) *error = "could not open store file for writing (wb): " + temp;
    return false;
  }
  size_t offset = 0;
  while(offset < bytes.size()) {
    const size_t count = std::fwrite(bytes.data() + offset, 1, bytes.size() - offset, file);
    if(count == 0) {
      std::fclose(file);
      std::remove(temp.c_str());
      if(error) *error = "fwrite failed while writing store blob: " + temp;
      return false;
    }
    offset += count;
  }
  if(std::fflush(file) != 0) {
    std::fclose(file);
    std::remove(temp.c_str());
    if(error) *error = "fflush failed for store blob: " + temp;
    return false;
  }
  const int fd = fileno(file);
  if(fd >= 0 && fsync(fd) != 0) {
    std::fclose(file);
    std::remove(temp.c_str());
    if(error) *error = "fsync failed for store blob: " + temp;
    return false;
  }
  if(std::fclose(file) != 0) {
    std::remove(temp.c_str());
    if(error) *error = "fclose failed for store blob: " + temp;
    return false;
  }
  if(std::rename(temp.c_str(), path.c_str()) != 0) {
    std::remove(temp.c_str());
    if(error) *error = "could not atomically replace store file: " + path;
    return false;
  }
  return true;
}

std::optional<MCTSStore> MCTSStore::deserialize(
  const std::vector<uint8_t>& bytes,
  std::string* error,
  const DeserializeProgressFn& progress
) {
  return deserialize(bytes.data(), bytes.size(), error, progress);
}

std::optional<MCTSStore> MCTSStore::loadFromFile(
  const std::string& path,
  uint64_t maxBytes,
  std::string* error
) {
  // One-shot read: map or read the entire blob once, then parse once. No streaming.
  int flags = O_RDONLY;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
  flags |= O_NOFOLLOW;
#endif
  const int fd = open(path.c_str(), flags);
  if(fd < 0) {
    if(error) *error = "could not open store file: " + path;
    return std::nullopt;
  }
  struct stat metadata;
  if(fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0 ||
     static_cast<uint64_t>(metadata.st_size) < 32 ||
     static_cast<uint64_t>(metadata.st_size) > maxBytes ||
     static_cast<uint64_t>(metadata.st_size) > kMaxSerializedBytes) {
    close(fd);
    if(error) *error = "store file is not a bounded regular file: " + path;
    return std::nullopt;
  }
  const size_t fileSize = static_cast<size_t>(metadata.st_size);

  void* mapped = mmap(nullptr, fileSize, PROT_READ, MAP_PRIVATE, fd, 0);
  if(mapped != MAP_FAILED) {
    close(fd);
    // Silent parse: product rehydrate never streams progress.
    auto store = deserialize(
      static_cast<const uint8_t*>(mapped),
      fileSize,
      error,
      {}
    );
    munmap(mapped, fileSize);
    return store;
  }

  // Fallback: one full-buffer read (not progressive unit streaming).
  std::vector<uint8_t> bytes(fileSize);
  size_t offset = 0;
  while(offset < bytes.size()) {
    const ssize_t count = read(fd, bytes.data() + offset, bytes.size() - offset);
    if(count < 0 && errno == EINTR)
      continue;
    if(count <= 0) {
      close(fd);
      if(error) *error = "could not read complete store file: " + path;
      return std::nullopt;
    }
    offset += static_cast<size_t>(count);
  }
  if(close(fd) != 0) {
    if(error) *error = "could not close store file: " + path;
    return std::nullopt;
  }
  return deserialize(bytes.data(), bytes.size(), error, {});
}

std::optional<MCTSStore> MCTSStore::deserializeFromFile(
  const std::string& path,
  uint64_t maxBytes,
  std::string* error,
  const DeserializeProgressFn& progress
) {
  (void)progress; // Streaming progress removed from product file I/O.
  return loadFromFile(path, maxBytes, error);
}

std::optional<MCTSStore> MCTSStore::deserialize(
  const uint8_t* data,
  size_t size,
  std::string* error,
  const DeserializeProgressFn& progress
) {
  if(data == nullptr || size < 32 || size > kMaxSerializedBytes) {
    if(error) *error = "serialized state has invalid byte count";
    return std::nullopt;
  }
  const size_t payloadSize = size - sizeof(uint64_t);
  reportDeserializeProgress(progress, "verifying", 0.36, 0, payloadSize, "Verifying checksum");
  if(checksum64Progress(data, payloadSize, progress, 0.36, 0.48) != decodeTrailingU64(data, size)) {
    if(error) *error = "serialized state checksum mismatch";
    return std::nullopt;
  }
  reportDeserializeProgress(progress, "parsing_header", 0.50, 0, 1, "Parsing header");
  ByteReader r(data, payloadSize);
  uint64_t magic = 0;
  uint32_t version = 0;
  if(!r.readU64(magic) || magic != kPersistMagic) {
    if(error) *error = "bad magic";
    return std::nullopt;
  }
  if(!r.readU32(version) || version < kMinimumReadablePersistVersion || version > kPersistVersion) {
    if(error) *error = "unsupported version";
    return std::nullopt;
  }

  MCTSStore store;
  uint8_t modelId = 0;
  uint8_t koRule = 0;
  uint8_t scoringRule = 0;
  uint8_t taxRule = 0;
  uint8_t suicide = 0;
  uint8_t hasButton = 0;
  uint8_t handicapBonus = 0;
  uint8_t friendlyPass = 0;
  if(!r.readU64(store.key.gameId) ||
     !r.readU8(modelId) ||
     !r.readU64(store.key.rulesHash) ||
     !r.readI32(store.key.komiKey) ||
     !r.readI32(store.key.wideRootNoiseKey)) {
    if(error) *error = "truncated header";
    return std::nullopt;
  }
  // v5+: PDA key after wideRootNoiseKey.
  if(version >= 5) {
    if(!r.readI32(store.key.playoutDoublingAdvantageKey)) {
      if(error) *error = "truncated header (pda key)";
      return std::nullopt;
    }
  } else {
    store.key.playoutDoublingAdvantageKey = 0;
  }
  if(!r.readU8(koRule) ||
     !r.readU8(scoringRule) ||
     !r.readU8(taxRule) ||
     !r.readU8(suicide) ||
     !r.readU8(hasButton) ||
     !r.readU8(handicapBonus) ||
     !r.readU8(friendlyPass) ||
     !r.readFloat(store.storeRules.komi) ||
     !r.readFloat(store.params.cpuct) ||
     !r.readFloat(store.params.fpuValue) ||
     !r.readFloat(store.params.rootNoise) ||
     !r.readFloat(store.params.rootNoiseWeight) ||
     !r.readFloat(store.params.winLossUtilityFactor) ||
     !r.readFloat(store.params.staticScoreUtilityFactor) ||
     !r.readFloat(store.params.dynamicScoreUtilityFactor)) {
    if(error) *error = "truncated header";
    return std::nullopt;
  }
  if(version >= 5) {
    uint8_t pdaPla = 0;
    if(!r.readFloat(store.params.cpuctExplorationLog) ||
       !r.readFloat(store.params.cpuctExplorationBase) ||
       !r.readFloat(store.params.fpuReductionMax) ||
       !r.readFloat(store.params.rootFpuReductionMax) ||
       !r.readFloat(store.params.playoutDoublingAdvantage) ||
       !r.readU8(pdaPla) ||
       !r.readU64(store.params.seed) ||
       !r.readU32(store.root) ||
       !r.readU64(store.playoutSeq) ||
       !r.readU64(store.rootSessionSeq)) {
      if(error) *error = "truncated header (v5 params)";
      return std::nullopt;
    }
    if(pdaPla > static_cast<uint8_t>(Color::white)) {
      if(error) *error = "invalid playoutDoublingAdvantagePla";
      return std::nullopt;
    }
    store.params.playoutDoublingAdvantagePla = static_cast<Color>(pdaPla);
  } else {
    // Pre-v5: analysis-aligned PUCT defaults; PDA = 0; keep legacy cpuct as c_expl.
    store.params.cpuctExplorationLog = 0.45f;
    store.params.cpuctExplorationBase = 500.0f;
    store.params.fpuReductionMax = 0.2f;
    store.params.rootFpuReductionMax = 0.1f;
    store.params.playoutDoublingAdvantage = 0.0f;
    store.params.playoutDoublingAdvantagePla = Color::empty;
    store.key.playoutDoublingAdvantageKey = 0;
    if(!r.readU64(store.params.seed) ||
       !r.readU32(store.root) ||
       !r.readU64(store.playoutSeq) ||
       !r.readU64(store.rootSessionSeq)) {
      if(error) *error = "truncated header";
      return std::nullopt;
    }
  }
  if(modelId > static_cast<uint8_t>(ModelId::b28nbt) ||
     koRule > static_cast<uint8_t>(KoRule::situational) ||
     scoringRule > static_cast<uint8_t>(ScoringRule::territory) ||
     taxRule > static_cast<uint8_t>(TaxRule::all) ||
     handicapBonus > static_cast<uint8_t>(WhiteHandicapBonusRule::nMinusOne) ||
     suicide > 1 || hasButton > 1 || friendlyPass > 1) {
    if(error) *error = "serialized state contains invalid enum or boolean";
    return std::nullopt;
  }
  store.key.modelId = static_cast<ModelId>(modelId);
  store.storeRules.koRule = static_cast<KoRule>(koRule);
  store.storeRules.scoringRule = static_cast<ScoringRule>(scoringRule);
  store.storeRules.taxRule = static_cast<TaxRule>(taxRule);
  store.storeRules.multiStoneSuicideLegal = suicide != 0;
  store.storeRules.hasButton = hasButton != 0;
  store.storeRules.whiteHandicapBonusRule = static_cast<WhiteHandicapBonusRule>(handicapBonus);
  store.storeRules.friendlyPassOk = friendlyPass != 0;

  for(Color& c : store.initialBoardState.cells) {
    uint8_t v = 0;
    if(!r.readU8(v) || v > static_cast<uint8_t>(Color::white)) {
      if(error) *error = "truncated initial board";
      return std::nullopt;
    }
    c = static_cast<Color>(v);
  }
  uint8_t nextPla = 0;
  if(!r.readU8(nextPla) || nextPla < static_cast<uint8_t>(Color::black) ||
     nextPla > static_cast<uint8_t>(Color::white) ||
     !r.readI32(store.initialBoardState.simpleKoPoint)) {
    if(error) *error = "truncated initial board metadata";
    return std::nullopt;
  }
  store.initialBoardState.nextPla = static_cast<Color>(nextPla);
  uint64_t hashCount = 0;
  if(!r.readU64(hashCount) || hashCount > 1000000ULL || hashCount > r.remaining() / sizeof(uint64_t)) {
    if(error) *error = "bad initial hash count";
    return std::nullopt;
  }
  store.initialBoardState.boardHashHistory.resize(static_cast<size_t>(hashCount));
  for(uint64_t& h : store.initialBoardState.boardHashHistory) {
    if(!r.readU64(h)) {
      if(error) *error = "truncated initial hash history";
      return std::nullopt;
    }
  }
  if(!r.readU64(hashCount) || hashCount > 1000000ULL || hashCount > r.remaining() / sizeof(uint64_t)) {
    if(error) *error = "bad initial situation hash count";
    return std::nullopt;
  }
  store.initialBoardState.situationHashHistory.resize(static_cast<size_t>(hashCount));
  for(uint64_t& h : store.initialBoardState.situationHashHistory) {
    if(!r.readU64(h)) {
      if(error) *error = "truncated initial situation hash history";
      return std::nullopt;
    }
  }
  uint64_t moveCount = 0;
  if(!r.readU64(moveCount) || moveCount > 1000000ULL) {
    if(error) *error = "bad initial move count";
    return std::nullopt;
  }
  store.initialBoardState.moves.resize(static_cast<size_t>(moveCount));
  for(MoveRecord& move : store.initialBoardState.moves) {
    uint8_t pla = 0;
    if(!r.readU16(move.move) || move.move >= kMoveCount ||
       !r.readU8(pla) || pla < static_cast<uint8_t>(Color::black) ||
       pla > static_cast<uint8_t>(Color::white) ||
       !r.readI32(move.previousSimpleKoPoint)) {
      if(error) *error = "truncated or invalid initial move";
      return std::nullopt;
    }
    move.pla = static_cast<Color>(pla);
    auto readMoveVector = [&](std::vector<Move>& values) {
      uint32_t count = 0;
      if(!r.readU32(count) || count > kBoardArea)
        return false;
      values.resize(count);
      for(Move& value : values) {
        if(!r.readU16(value) || value >= kBoardArea)
          return false;
      }
      return true;
    };
    if(!readMoveVector(move.captured) || !readMoveVector(move.removedOwn)) {
      if(error) *error = "invalid captured-stone vector";
      return std::nullopt;
    }
  }

  uint64_t nodeCount = 0;
  uint64_t actionCount = 0;
  uint64_t policyCount = 0;
  uint64_t ownershipCount = 0;
  uint64_t ancestorCount = 0;
  uint64_t visibleCount = 0;
  if(!r.readU64(nodeCount) ||
     !r.readU64(actionCount) ||
     !r.readU64(policyCount) ||
     !r.readU64(ownershipCount) ||
     !r.readU64(ancestorCount) ||
     !r.readU64(visibleCount)) {
    if(error) *error = "truncated array counts";
    return std::nullopt;
  }
  const uint32_t nodeRecordBytes = version >= 4 ? 126U : 89U;
  const __uint128_t minimumBytes =
    static_cast<__uint128_t>(nodeCount) * nodeRecordBytes +
    static_cast<__uint128_t>(actionCount) * 58U +
    static_cast<__uint128_t>(policyCount) * 4U +
    static_cast<__uint128_t>(ownershipCount) * 4U +
    static_cast<__uint128_t>(ancestorCount) * 4U +
    static_cast<__uint128_t>(visibleCount);
  if(nodeCount == 0 || nodeCount > kMaxSerializedNodes ||
     actionCount > kMaxSerializedActions ||
     policyCount > kMaxArenaElements || ownershipCount > kMaxArenaElements ||
     ancestorCount > kMaxArenaElements || visibleCount != nodeCount ||
     policyCount % kMoveCount != 0 || ownershipCount % kOwnershipDim != 0 ||
     minimumBytes > r.remaining()) {
    if(error) *error = "array count too large";
    return std::nullopt;
  }
  store.nodes.resize(static_cast<size_t>(nodeCount));
  store.actions.resize(static_cast<size_t>(actionCount));
  store.policyArena.resize(static_cast<size_t>(policyCount));
  store.ownershipArena.resize(static_cast<size_t>(ownershipCount));
  store.ancestorArena.resize(static_cast<size_t>(ancestorCount));
  store.visible.resize(static_cast<size_t>(visibleCount));
  auto readStats = [&](ScalarStats& stats) {
    return r.readFloat(stats.weightSum) &&
      r.readFloat(stats.weightSqSum) &&
      r.readFloat(stats.winLossMeanWhite) &&
      r.readFloat(stats.noResultMean) &&
      r.readFloat(stats.scoreMeanWhite) &&
      r.readFloat(stats.scoreMeanSqWhite) &&
      r.readFloat(stats.leadMeanWhite) &&
      r.readFloat(stats.utilityMean) &&
      r.readFloat(stats.utilitySqMean);
  };
  reportDeserializeProgress(
    progress,
    "parsing_nodes",
    0.52,
    0,
    nodeCount,
    "Parsing nodes"
  );
  size_t nodeIndex = 0;
  for(Node& node : store.nodes) {
    uint8_t movePla = 0;
    uint8_t pla = 0;
    uint8_t state = 0;
    if(!r.readU32(node.id) ||
       !r.readU32(node.parent) ||
       !r.readU16(node.moveFromParent) ||
       !r.readU8(movePla) ||
       !r.readU32(node.ply) ||
       !r.readU8(pla) ||
       !r.readU8(state) ||
       !r.readU32(node.policyOffset) ||
       !r.readU32(node.firstAction) ||
       !r.readU16(node.actionCount) ||
       !r.readU16(node.ancestorCount) ||
       !r.readU32(node.ancestorOffset) ||
       !r.readU64(node.visits) ||
       !readStats(node.stats) ||
       !r.readU32(node.ownershipOffset) ||
       !r.readU64(node.lineageHash) ||
       movePla > static_cast<uint8_t>(Color::white) ||
       pla < static_cast<uint8_t>(Color::black) || pla > static_cast<uint8_t>(Color::white) ||
       state > static_cast<uint8_t>(NodeState::terminal)) {
      if(error) *error = "truncated or invalid node";
      return std::nullopt;
    }
    node.movePla = static_cast<Color>(movePla);
    node.nextPla = static_cast<Color>(pla);
    node.state = static_cast<NodeState>(state);
    if(version >= 4) {
      uint8_t hasNN = 0;
      if(!r.readU32(node.minVisitedRootDepth) ||
         !r.readU8(hasNN) || hasNN > 1 ||
         !r.readFloat(node.nnWinLossWhite) ||
         !r.readFloat(node.nnNoResult) ||
         !r.readFloat(node.nnScoreMeanWhite) ||
         !r.readFloat(node.nnScoreMeanSqWhite) ||
         !r.readFloat(node.nnLeadWhite) ||
         !r.readFloat(node.nnUtilityWhite) ||
         !r.readFloat(node.nnWeight) ||
         !r.readU32(node.nnOwnershipOffset)) {
        if(error) *error = "truncated v4 node visit/NN fields";
        return std::nullopt;
      }
      node.hasStoredNN = hasNN != 0;
    } else {
      // Legacy import approximation: expanded nodes are treated as visited by
      // the initial root depth 0 and without a recoverable raw NN leaf.
      node.minVisitedRootDepth =
        (node.state == NodeState::expanded || node.visits > 0) ? 0u : kNeverVisitedRootDepth;
      node.hasStoredNN = false;
      node.nnOwnershipOffset = kInvalidNode;
    }
    ++nodeIndex;
    if(progress && (nodeIndex == nodeCount || (nodeIndex % 4096ULL) == 0)) {
      const double t = nodeCount == 0 ? 1.0 : static_cast<double>(nodeIndex) / static_cast<double>(nodeCount);
      reportDeserializeProgress(
        progress,
        "parsing_nodes",
        0.52 + 0.22 * t,
        static_cast<uint64_t>(nodeIndex),
        nodeCount,
        "Parsing nodes"
      );
    }
  }
  reportDeserializeProgress(progress, "parsing_actions", 0.74, 0, actionCount, "Parsing actions");
  size_t actionIndex = 0;
  for(Action& action : store.actions) {
    if(!r.readU32(action.parent) ||
       !r.readU32(action.child) ||
       !r.readU32(action.nextAction) ||
       !r.readU16(action.move) ||
       !r.readU64(action.visits) ||
       !readStats(action.stats)) {
      if(error) *error = "truncated action";
      return std::nullopt;
    }
    ++actionIndex;
    if(progress && (actionIndex == actionCount || (actionIndex % 16384ULL) == 0)) {
      const double t = actionCount == 0 ? 1.0 : static_cast<double>(actionIndex) / static_cast<double>(actionCount);
      reportDeserializeProgress(
        progress,
        "parsing_actions",
        0.74 + 0.10 * t,
        static_cast<uint64_t>(actionIndex),
        actionCount,
        "Parsing actions"
      );
    }
  }
  reportDeserializeProgress(progress, "parsing_arenas", 0.85, 0, policyCount + ownershipCount + ancestorCount + visibleCount, "Parsing arenas");
  size_t arenaDone = 0;
  const uint64_t arenaTotal = policyCount + ownershipCount + ancestorCount + visibleCount;
  auto bumpArena = [&](size_t step) {
    arenaDone += step;
    if(progress && (arenaDone >= arenaTotal || (arenaDone % (256ULL * 1024ULL)) == 0)) {
      const double t = arenaTotal == 0 ? 1.0 : static_cast<double>(arenaDone) / static_cast<double>(arenaTotal);
      reportDeserializeProgress(
        progress,
        "parsing_arenas",
        0.85 + 0.08 * t,
        static_cast<uint64_t>(arenaDone),
        arenaTotal,
        "Parsing arenas"
      );
    }
  };
  for(float& value : store.policyArena) {
    if(!r.readFloat(value)) {
      if(error) *error = "truncated policy arena";
      return std::nullopt;
    }
    bumpArena(1);
  }
  for(float& value : store.ownershipArena) {
    if(!r.readFloat(value)) {
      if(error) *error = "truncated ownership arena";
      return std::nullopt;
    }
    bumpArena(1);
  }
  for(NodeId& id : store.ancestorArena) {
    if(!r.readU32(id)) {
      if(error) *error = "truncated ancestor arena";
      return std::nullopt;
    }
    bumpArena(1);
  }
  for(uint8_t& value : store.visible) {
    if(!r.readU8(value) || value > 1) {
      if(error) *error = "truncated or invalid visible array";
      return std::nullopt;
    }
    bumpArena(1);
  }
  if(!r.atEnd()) {
    if(error) *error = "trailing bytes";
    return std::nullopt;
  }
  reportDeserializeProgress(progress, "validating", 0.94, 0, 1, "Validating store");
  if(version < 3) {
    for(NodeId id = 0; id < store.nodes.size(); ++id) {
      Node& node = store.nodes[id];
      if(node.parent == kInvalidNode) {
        if(id != 0) {
          if(error) *error = "legacy state contains more than one initial node";
          return std::nullopt;
        }
        node.lineageHash = initialLineageHash(store.initialBoardState);
      }
      else {
        if(node.parent >= id) {
          if(error) *error = "legacy state parent is not earlier than child";
          return std::nullopt;
        }
        node.lineageHash = childLineageHash(
          store.nodes[node.parent].lineageHash,
          node.moveFromParent,
          node.movePla
        );
      }
    }
  }
  for(const Node& node : store.nodes) {
    if(node.parent != kInvalidNode)
      store.childIndex.emplace(childKey(node.parent, node.moveFromParent), node.id);
  }
  for(NodeId id = 0; id < store.nodes.size(); ++id) {
    if(store.visible[id]) {
      const auto inserted = store.visibleLineageIndex.emplace(store.nodes[id].lineageHash, id);
      if(!inserted.second) {
        if(error) *error = "serialized state contains duplicate visible lineage hashes";
        return std::nullopt;
      }
    }
  }
  auto materialized = store.materializePosition(store.root);
  if(!materialized) {
    if(error) *error = "could not materialize root";
    return std::nullopt;
  }
  store.storeBoardCache(store.root, std::move(*materialized));
  store.rootBoardPtr = store.boardCacheFor(store.root);
  if(!store.validate(error))
    return std::nullopt;
  reportDeserializeProgress(progress, "complete", 1.0, 1, 1, "Deserialize complete");
  return store;
}

} // namespace qixi::core
