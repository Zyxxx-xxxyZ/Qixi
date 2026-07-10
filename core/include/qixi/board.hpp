#pragma once

#include "qixi/core_types.hpp"

#include <array>
#include <cstdint>
#include <string>
#include <unordered_set>
#include <vector>

namespace qixi::core {

struct MoveRecord {
  Move move = kMovePass;
  Color pla = Color::black;
  std::vector<Move> captured;
  std::vector<Move> removedOwn;
  int previousSimpleKoPoint = -1;
};

struct BoardState {
  std::array<Color, kBoardArea> cells{};
  Color nextPla = Color::black;
  int simpleKoPoint = -1;
  std::vector<uint64_t> boardHashHistory;
  std::vector<uint64_t> situationHashHistory;
  std::vector<MoveRecord> moves;
};

struct LegalResult {
  bool legal = false;
  std::string reason;
  BoardState next;
  std::vector<Move> captured;
};

struct InPlaceMoveResult {
  bool legal = false;
  std::string reason;
  std::vector<Move> captured;
};

struct BoardPatch {
  Move move = kMovePass;
  Color pla = Color::black;
  std::vector<std::pair<Move, Color>> setPoints;
  std::vector<Move> captured;
  Color nextPla = Color::white;
};

class BoardLogic {
public:
  static BoardState emptyBoard(Color nextPla = Color::black);
  static uint64_t boardHash(const BoardState& board);
  static uint64_t situationHash(const BoardState& board);
  static std::array<bool, kMoveCount> legalMoveMask(const BoardState& board, const Rules& rules);
  static bool isLegalMove(const BoardState& board, const Rules& rules, Move move);
  static LegalResult playMove(const BoardState& board, const Rules& rules, Move move);
  static InPlaceMoveResult playMoveInPlace(BoardState& board, const Rules& rules, Move move);
  static BoardPatch patchBetween(const BoardState& before, const BoardState& after, Move move, Color pla);

private:
  struct MoveSimulation {
    std::array<Color, kBoardArea> cells{};
    Color nextPla = Color::black;
    int simpleKoPoint = -1;
    std::vector<Move> captured;
    std::vector<Move> removedOwn;
    uint64_t boardHash = 0;
    uint64_t situationHash = 0;
  };

  static bool simulateMove(
    const BoardState& board,
    const Rules& rules,
    Move move,
    MoveSimulation& simulation,
    std::string& reason
  );
  static void commitSimulation(BoardState& board, Move move, MoveSimulation&& simulation);
  static void collectGroup(
    const std::array<Color, kBoardArea>& cells,
    Move start,
    std::vector<Move>& stones,
    std::vector<Move>& liberties
  );
};

} // namespace qixi::core
