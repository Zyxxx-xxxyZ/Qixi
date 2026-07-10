#include "qixi/board.hpp"

#include <algorithm>
#include <queue>
#include <set>
#include <utility>

namespace qixi::core {
namespace {

bool onBoard(int x, int y) {
  return x >= 0 && x < kBoardLen && y >= 0 && y < kBoardLen;
}

std::array<Move, 4> neighbors(Move move, int& count) {
  const Point p = moveToPoint(move);
  std::array<Move, 4> result{};
  count = 0;
  if(onBoard(p.x - 1, p.y))
    result[count++] = pointToMove(p.x - 1, p.y);
  if(onBoard(p.x + 1, p.y))
    result[count++] = pointToMove(p.x + 1, p.y);
  if(onBoard(p.x, p.y - 1))
    result[count++] = pointToMove(p.x, p.y - 1);
  if(onBoard(p.x, p.y + 1))
    result[count++] = pointToMove(p.x, p.y + 1);
  return result;
}

uint64_t mix64(uint64_t x) {
  x += 0x9e3779b97f4a7c15ULL;
  x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
  x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
  return x ^ (x >> 31);
}

uint64_t boardHashForCells(const std::array<Color, kBoardArea>& cells) {
  uint64_t h = 0x517869426f617264ULL;
  for(size_t i = 0; i < cells.size(); ++i) {
    const Color color = cells[i];
    if(color == Color::empty)
      continue;
    const uint64_t stone = static_cast<uint64_t>(color) + 17ULL * static_cast<uint64_t>(i + 1);
    h ^= mix64(stone);
  }
  return h;
}

uint64_t situationHashFor(uint64_t boardHash, Color nextPla) {
  return boardHash ^ mix64(static_cast<uint64_t>(nextPla) + 0x100000ULL);
}

} // namespace

BoardState BoardLogic::emptyBoard(Color nextPla) {
  BoardState board;
  board.cells.fill(Color::empty);
  board.nextPla = nextPla;
  board.simpleKoPoint = -1;
  board.boardHashHistory.push_back(boardHash(board));
  board.situationHashHistory.push_back(situationHash(board));
  return board;
}

uint64_t BoardLogic::boardHash(const BoardState& board) {
  return boardHashForCells(board.cells);
}

uint64_t BoardLogic::situationHash(const BoardState& board) {
  return situationHashFor(boardHash(board), board.nextPla);
}

void BoardLogic::collectGroup(
  const std::array<Color, kBoardArea>& cells,
  Move start,
  std::vector<Move>& stones,
  std::vector<Move>& liberties
) {
  stones.clear();
  liberties.clear();
  if(!isBoardMove(start) || cells[start] == Color::empty)
    return;

  const Color color = cells[start];
  std::array<uint8_t, kBoardArea> seen{};
  std::array<uint8_t, kBoardArea> seenLib{};
  std::queue<Move> queue;
  queue.push(start);
  seen[start] = 1;

  while(!queue.empty()) {
    const Move current = queue.front();
    queue.pop();
    stones.push_back(current);

    int neighborCount = 0;
    const auto ns = neighbors(current, neighborCount);
    for(int i = 0; i < neighborCount; ++i) {
      const Move n = ns[i];
      if(cells[n] == Color::empty) {
        if(!seenLib[n]) {
          seenLib[n] = 1;
          liberties.push_back(n);
        }
      }
      else if(cells[n] == color && !seen[n]) {
        seen[n] = 1;
        queue.push(n);
      }
    }
  }
}

std::array<bool, kMoveCount> BoardLogic::legalMoveMask(const BoardState& board, const Rules& rules) {
  std::array<bool, kMoveCount> result{};
  for(Move move = 0; move < kMoveCount; ++move)
    result[move] = isLegalMove(board, rules, move);
  return result;
}

bool BoardLogic::isLegalMove(const BoardState& board, const Rules& rules, Move move) {
  MoveSimulation simulation;
  std::string reason;
  return simulateMove(board, rules, move, simulation, reason);
}

bool BoardLogic::simulateMove(
  const BoardState& board,
  const Rules& rules,
  Move move,
  MoveSimulation& simulation,
  std::string& reason
) {
  reason.clear();
  simulation = MoveSimulation{};
  simulation.cells = board.cells;
  simulation.nextPla = opposite(board.nextPla);
  if(move == kMovePass) {
    simulation.simpleKoPoint = -1;
    simulation.boardHash = boardHashForCells(simulation.cells);
    simulation.situationHash = situationHashFor(simulation.boardHash, simulation.nextPla);
    return true;
  }

  if(!isBoardMove(move)) {
    reason = "move out of range";
    return false;
  }
  if(board.cells[move] != Color::empty) {
    reason = "occupied point";
    return false;
  }
  if(rules.koRule == KoRule::simple && board.simpleKoPoint == static_cast<int>(move)) {
    reason = "simple ko recapture";
    return false;
  }

  simulation.cells[move] = board.nextPla;
  simulation.simpleKoPoint = -1;

  const Color opp = opposite(board.nextPla);
  std::vector<Move> group;
  std::vector<Move> liberties;

  int neighborCount = 0;
  const auto ns = neighbors(move, neighborCount);
  std::array<uint8_t, kBoardArea> capturedSeen{};
  for(int i = 0; i < neighborCount; ++i) {
    const Move n = ns[i];
    if(simulation.cells[n] != opp)
      continue;
    collectGroup(simulation.cells, n, group, liberties);
    if(!liberties.empty())
      continue;
    for(Move stone : group) {
      if(!capturedSeen[stone]) {
        capturedSeen[stone] = 1;
        simulation.captured.push_back(stone);
        simulation.cells[stone] = Color::empty;
      }
    }
  }

  collectGroup(simulation.cells, move, group, liberties);
  if(liberties.empty() && !rules.multiStoneSuicideLegal) {
    reason = "suicide";
    return false;
  }

  if(liberties.empty()) {
    simulation.removedOwn = group;
    for(Move stone : simulation.removedOwn)
      simulation.cells[stone] = Color::empty;
  }

  if(simulation.removedOwn.empty() && simulation.captured.size() == 1 &&
     group.size() == 1 && liberties.size() == 1)
    simulation.simpleKoPoint = static_cast<int>(simulation.captured[0]);

  simulation.boardHash = boardHashForCells(simulation.cells);
  simulation.situationHash = situationHashFor(simulation.boardHash, simulation.nextPla);
  if(rules.koRule == KoRule::positional || rules.koRule == KoRule::situational) {
    const uint64_t nextHash = rules.koRule == KoRule::situational
      ? simulation.situationHash
      : simulation.boardHash;
    const std::vector<uint64_t>& history = rules.koRule == KoRule::situational
      ? board.situationHashHistory
      : board.boardHashHistory;
    for(uint64_t oldHash : history) {
      if(oldHash == nextHash) {
        reason = "superko";
        return false;
      }
    }
  }
  return true;
}

void BoardLogic::commitSimulation(BoardState& board, Move move, MoveSimulation&& simulation) {
  const Color pla = board.nextPla;
  const int previousSimpleKoPoint = board.simpleKoPoint;
  board.cells = std::move(simulation.cells);
  board.nextPla = simulation.nextPla;
  board.simpleKoPoint = simulation.simpleKoPoint;
  board.moves.push_back({
    move,
    pla,
    std::move(simulation.captured),
    std::move(simulation.removedOwn),
    previousSimpleKoPoint,
  });
  board.boardHashHistory.push_back(simulation.boardHash);
  board.situationHashHistory.push_back(simulation.situationHash);
}

LegalResult BoardLogic::playMove(const BoardState& board, const Rules& rules, Move move) {
  LegalResult result;
  MoveSimulation simulation;
  if(!simulateMove(board, rules, move, simulation, result.reason))
    return result;
  result.captured = simulation.captured;
  result.next = board;
  commitSimulation(result.next, move, std::move(simulation));
  result.legal = true;
  return result;
}

InPlaceMoveResult BoardLogic::playMoveInPlace(BoardState& board, const Rules& rules, Move move) {
  InPlaceMoveResult result;
  MoveSimulation simulation;
  if(!simulateMove(board, rules, move, simulation, result.reason))
    return result;
  result.captured = simulation.captured;
  commitSimulation(board, move, std::move(simulation));
  result.legal = true;
  return result;
}

BoardPatch BoardLogic::patchBetween(const BoardState& before, const BoardState& after, Move move, Color pla) {
  BoardPatch patch;
  patch.move = move;
  patch.pla = pla;
  patch.nextPla = after.nextPla;
  for(Move i = 0; i < kBoardArea; ++i) {
    if(before.cells[i] != after.cells[i]) {
      patch.setPoints.push_back({i, after.cells[i]});
      if(before.cells[i] != Color::empty && after.cells[i] == Color::empty)
        patch.captured.push_back(i);
    }
  }
  return patch;
}

} // namespace qixi::core
