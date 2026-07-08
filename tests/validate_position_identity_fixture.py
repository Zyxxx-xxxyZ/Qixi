#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import stat as stat_module
from dataclasses import dataclass
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = ROOT / "tests" / "fixtures" / "position_identity_cases.json"
FIXTURE_MAX_BYTES = 1 * 1024 * 1024

ALLOWED_ENGINES = frozenset(("none", "b6", "b18nbt", "b28nbt"))
EXPECTED_BACKEND_ENGINES = {
  "none": "none",
  "b6": "katago-metal-mux:b6",
  "b18nbt": "katago-metal-mux:b18nbt",
  "b28nbt": "katago-metal-mux:b28nbt",
}
BOARD_SIZE = 19
REQUIRED_RELATION_IDS = frozenset((
  "identical-request",
  "same-stones-different-order",
  "engine-switch",
  "komi-change",
  "root-noise-change",
  "pass-history",
  "captured-coordinate-reuse",
  "ko-history-after-passes",
))


class PositionIdentityFixtureError(ValueError):
  pass


@dataclass(frozen=True)
class PositionIdentityFixtureSummary:
  case_count: int
  relation_count: int
  same_visible_different_identity_count: int


def reject_json_constant(value: str) -> None:
  raise PositionIdentityFixtureError(f"non-standard JSON numeric constant is not allowed: {value}")


def object_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
  result: dict[str, Any] = {}
  for key, value in pairs:
    if key in result:
      raise PositionIdentityFixtureError(f"duplicate JSON object key is not allowed: {key}")
    result[key] = value
  return result


def is_allowed_platform_symlink_alias(path: pathlib.Path) -> bool:
  allowed_aliases = {
    pathlib.Path("/var"): pathlib.Path("/private/var"),
    pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
    pathlib.Path("/etc"): pathlib.Path("/private/etc"),
  }
  target = allowed_aliases.get(path)
  if target is None:
    return False
  try:
    return path.resolve(strict=True) == target
  except OSError:
    return False


def reject_symlink_components(path: pathlib.Path) -> None:
  expanded = path.expanduser()
  current = pathlib.Path(expanded.anchor) if expanded.is_absolute() else pathlib.Path(".")
  for part in expanded.parts:
    if part == expanded.anchor or part in ("", "."):
      continue
    if part == "..":
      raise PositionIdentityFixtureError(f"{path}: fixture path must not contain parent-directory traversal")
    current = current / part
    if current.is_symlink() and not is_allowed_platform_symlink_alias(current):
      raise PositionIdentityFixtureError(f"{path}: fixture path must not contain symbolic links: {current}")


def opened_regular_file_stat(handle: Any, path: pathlib.Path) -> os.stat_result:
  try:
    opened_stat = os.fstat(handle.fileno())
  except OSError as exc:
    raise PositionIdentityFixtureError(f"{path}: could not stat opened fixture file descriptor: {exc}") from exc
  if not stat_module.S_ISREG(opened_stat.st_mode):
    raise PositionIdentityFixtureError(f"{path}: fixture must be a regular file after opening")
  if opened_stat.st_size <= 0:
    raise PositionIdentityFixtureError(f"{path}: fixture must be non-empty after opening")
  if opened_stat.st_size > FIXTURE_MAX_BYTES:
    raise PositionIdentityFixtureError(
      f"{path}: fixture is too large after opening: {opened_stat.st_size} bytes > {FIXTURE_MAX_BYTES}"
    )
  return opened_stat


def read_fixture_text(path: pathlib.Path) -> str:
  expanded = path.expanduser()
  reject_symlink_components(expanded)
  try:
    initial_stat = expanded.stat()
  except OSError as exc:
    raise PositionIdentityFixtureError(f"{expanded}: could not stat fixture: {exc}") from exc
  if not stat_module.S_ISREG(initial_stat.st_mode):
    raise PositionIdentityFixtureError(f"{expanded}: fixture must be a regular file")
  if initial_stat.st_size <= 0:
    raise PositionIdentityFixtureError(f"{expanded}: fixture must be non-empty")
  if initial_stat.st_size > FIXTURE_MAX_BYTES:
    raise PositionIdentityFixtureError(
      f"{expanded}: fixture is too large: {initial_stat.st_size} bytes > {FIXTURE_MAX_BYTES}"
    )

  try:
    with expanded.open("rb") as handle:
      opened_stat = opened_regular_file_stat(handle, expanded)
      data = handle.read(FIXTURE_MAX_BYTES + 1)
  except OSError as exc:
    raise PositionIdentityFixtureError(f"{expanded}: could not read fixture: {exc}") from exc
  if len(data) > FIXTURE_MAX_BYTES:
    raise PositionIdentityFixtureError(f"{expanded}: fixture exceeded bounded read limit of {FIXTURE_MAX_BYTES} bytes")
  if len(data) != opened_stat.st_size:
    raise PositionIdentityFixtureError(
      f"{expanded}: opened-byte-count drift while reading fixture: read {len(data)} bytes, expected {opened_stat.st_size}"
    )
  try:
    return data.decode("utf-8")
  except UnicodeDecodeError as exc:
    raise PositionIdentityFixtureError(f"{expanded}: fixture must be valid UTF-8: {exc}") from exc


def load_strict_json(path: pathlib.Path) -> Any:
  try:
    return json.loads(
      read_fixture_text(path),
      object_pairs_hook=object_without_duplicate_keys,
      parse_constant=reject_json_constant,
    )
  except json.JSONDecodeError as exc:
    raise PositionIdentityFixtureError(f"{path}: invalid JSON: {exc}") from exc


def require(condition: bool, message: str) -> None:
  if not condition:
    raise PositionIdentityFixtureError(message)


def require_object(value: Any, label: str) -> dict[str, Any]:
  require(isinstance(value, dict), f"{label} must be an object")
  return value


def require_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
  actual = set(value)
  require(actual == expected, f"{label} keys must be {sorted(expected)}, got {sorted(actual)}")


def require_string(value: Any, label: str) -> str:
  require(isinstance(value, str) and value.strip() == value and value != "", f"{label} must be a non-empty trimmed string")
  return value


def require_bool(value: Any, label: str) -> bool:
  require(isinstance(value, bool), f"{label} must be a boolean")
  return value


def require_finite_number(value: Any, label: str) -> float:
  require(not isinstance(value, bool) and isinstance(value, (int, float)), f"{label} must be a finite number")
  require(math.isfinite(float(value)), f"{label} must be finite")
  return float(value)


def require_coordinate(value: Any, label: str) -> int:
  require(type(value) is int, f"{label} must be an integer coordinate")
  require(0 <= value < BOARD_SIZE, f"{label} must be in the 19x19 board range")
  return value


def board_index(x: int, y: int) -> int:
  return y * BOARD_SIZE + x


def neighbors(index: int) -> list[int]:
  x = index % BOARD_SIZE
  y = index // BOARD_SIZE
  values: list[int] = []
  if x > 0:
    values.append(index - 1)
  if x + 1 < BOARD_SIZE:
    values.append(index + 1)
  if y > 0:
    values.append(index - BOARD_SIZE)
  if y + 1 < BOARD_SIZE:
    values.append(index + BOARD_SIZE)
  return values


def group_from(board: list[str | None], start: int) -> set[int]:
  color = board[start]
  if color is None:
    return set()
  seen: set[int] = set()
  stack = [start]
  while stack:
    point = stack.pop()
    if point in seen:
      continue
    seen.add(point)
    for neighbor in neighbors(point):
      if board[neighbor] == color and neighbor not in seen:
        stack.append(neighbor)
  return seen


def has_liberty(board: list[str | None], group: set[int]) -> bool:
  return any(board[neighbor] is None for point in group for neighbor in neighbors(point))


def next_board_after_playing(board: list[str | None], move: dict[str, Any], label: str) -> list[str | None]:
  if move.get("pass") is True:
    return board.copy()

  point = board_index(int(move["x"]), int(move["y"]))
  require(board[point] is None, f"{label} must not play on an occupied point")
  color = str(move["color"])
  opponent = "W" if color == "B" else "B"
  next_board = board.copy()
  next_board[point] = color

  for neighbor in neighbors(point):
    if next_board[neighbor] != opponent:
      continue
    group = group_from(next_board, neighbor)
    if not has_liberty(next_board, group):
      for captured in group:
        next_board[captured] = None

  own_group = group_from(next_board, point)
  require(has_liberty(next_board, own_group), f"{label} must not be suicide")
  return next_board


def is_pass_move(move: dict[str, Any]) -> bool:
  return move.get("pass") is True


def final_visible_stones(moves: list[dict[str, Any]], label: str) -> tuple[tuple[str, int, int], ...]:
  board: list[str | None] = [None] * (BOARD_SIZE * BOARD_SIZE)
  snapshots = [board.copy()]
  for index, move in enumerate(moves):
    board = next_board_after_playing(board, move, f"{label}.moves[{index}]")
    previous_move_was_play = index > 0 and not is_pass_move(moves[index - 1])
    current_move_is_play = not is_pass_move(move)
    require(
      not (previous_move_was_play and current_move_is_play and len(snapshots) >= 2 and board == snapshots[-2]),
      f"{label}.moves[{index}] must not immediately recapture a simple ko",
    )
    snapshots.append(board.copy())
  return tuple(
    (color, index % BOARD_SIZE, index // BOARD_SIZE)
    for index, color in enumerate(board)
    if color is not None
  )


def next_player_after(moves: list[dict[str, Any]]) -> str:
  if not moves:
    return "B"
  last_color = str(moves[-1]["color"])
  return "W" if last_color == "B" else "B"


def validate_move(move: Any, label: str) -> None:
  move_object = require_object(move, label)
  require("color" in move_object, f"{label}.color is required")
  color = require_string(move_object["color"], f"{label}.color")
  require(color in ("B", "W"), f"{label}.color must be B or W")

  is_pass = move_object.get("pass") is True
  if is_pass:
    require_exact_keys(move_object, {"color", "pass"}, label)
    require_bool(move_object["pass"], f"{label}.pass")
    return

  require_exact_keys(move_object, {"color", "x", "y"}, label)
  require_coordinate(move_object["x"], f"{label}.x")
  require_coordinate(move_object["y"], f"{label}.y")


def validate_case(case: Any, index: int) -> tuple[str, dict[str, Any]]:
  label = f"cases[{index}]"
  case_object = require_object(case, label)
  require_exact_keys(case_object, {"id", "engine", "backendEngine", "rules", "komi", "rootNoise", "moves"}, label)

  case_id = require_string(case_object["id"], f"{label}.id")
  engine = require_string(case_object["engine"], f"{label}.engine")
  require(engine in ALLOWED_ENGINES, f"{label}.engine must be one of {sorted(ALLOWED_ENGINES)}")
  backend_engine = require_string(case_object["backendEngine"], f"{label}.backendEngine")
  require(
    backend_engine == EXPECTED_BACKEND_ENGINES[engine],
    f"{label}.backendEngine must be {EXPECTED_BACKEND_ENGINES[engine]!r} for engine {engine!r}",
  )
  require(require_string(case_object["rules"], f"{label}.rules") == "Chinese", f"{label}.rules must be Chinese")
  require(-100.0 <= require_finite_number(case_object["komi"], f"{label}.komi") <= 100.0, f"{label}.komi is out of range")
  require(0.0 <= require_finite_number(case_object["rootNoise"], f"{label}.rootNoise") <= 1.0, f"{label}.rootNoise is out of range")
  require(isinstance(case_object["moves"], list), f"{label}.moves must be a list")
  for move_index, move in enumerate(case_object["moves"]):
    validate_move(move, f"{label}.moves[{move_index}]")
  final_visible_stones(case_object["moves"], label)
  return case_id, case_object


def validate_relation(relation: Any, index: int, case_ids: set[str]) -> tuple[str, dict[str, Any]]:
  label = f"relations[{index}]"
  relation_object = require_object(relation, label)
  require_exact_keys(
    relation_object,
    {"id", "left", "right", "equal", "sameVisibleStones", "sameNextPlayer", "reason"},
    label,
  )

  relation_id = require_string(relation_object["id"], f"{label}.id")
  left = require_string(relation_object["left"], f"{label}.left")
  right = require_string(relation_object["right"], f"{label}.right")
  require(left in case_ids, f"{label}.left references unknown case {left!r}")
  require(right in case_ids, f"{label}.right references unknown case {right!r}")
  require(left != right, f"{label} must compare two distinct cases")
  require_bool(relation_object["equal"], f"{label}.equal")
  require_bool(relation_object["sameVisibleStones"], f"{label}.sameVisibleStones")
  require_bool(relation_object["sameNextPlayer"], f"{label}.sameNextPlayer")
  require_string(relation_object["reason"], f"{label}.reason")
  return relation_id, relation_object


def validate_fixture(path: pathlib.Path = DEFAULT_FIXTURE) -> dict[str, Any]:
  fixture = require_object(load_strict_json(path), "fixture")
  require_exact_keys(fixture, {"schemaVersion", "cases", "relations"}, "fixture")
  require(fixture["schemaVersion"] == 2, "fixture.schemaVersion must be 2")
  require(isinstance(fixture["cases"], list) and len(fixture["cases"]) > 0, "fixture.cases must be a non-empty list")
  require(isinstance(fixture["relations"], list) and len(fixture["relations"]) > 0, "fixture.relations must be a non-empty list")

  cases_by_id: dict[str, dict[str, Any]] = {}
  for index, case in enumerate(fixture["cases"]):
    case_id, case_object = validate_case(case, index)
    require(case_id not in cases_by_id, f"duplicate case id is not allowed: {case_id}")
    cases_by_id[case_id] = case_object

  relations_by_id: dict[str, dict[str, Any]] = {}
  visible_stones_by_id = {
    case_id: final_visible_stones(case_object["moves"], f"cases[{case_id}]")
    for case_id, case_object in cases_by_id.items()
  }
  next_player_by_id = {
    case_id: next_player_after(case_object["moves"])
    for case_id, case_object in cases_by_id.items()
  }
  same_visible_different_identity_count = 0
  for index, relation in enumerate(fixture["relations"]):
    relation_id, relation_object = validate_relation(relation, index, set(cases_by_id))
    require(relation_id not in relations_by_id, f"duplicate relation id is not allowed: {relation_id}")
    relations_by_id[relation_id] = relation_object
    actual_same_visible_stones = (
      visible_stones_by_id[relation_object["left"]] == visible_stones_by_id[relation_object["right"]]
    )
    require(
      actual_same_visible_stones is relation_object["sameVisibleStones"],
      f"relations[{index}].sameVisibleStones does not match replayed final stones",
    )
    actual_same_next_player = (
      next_player_by_id[relation_object["left"]] == next_player_by_id[relation_object["right"]]
    )
    require(
      actual_same_next_player is relation_object["sameNextPlayer"],
      f"relations[{index}].sameNextPlayer does not match replayed next player",
    )
    if relation_object["sameVisibleStones"] is True and relation_object["equal"] is False:
      same_visible_different_identity_count += 1

  missing_relations = REQUIRED_RELATION_IDS - set(relations_by_id)
  require(not missing_relations, f"fixture is missing required relation ids: {sorted(missing_relations)}")
  require(
    same_visible_different_identity_count >= 5,
    "fixture must contain multiple sameVisibleStones=true but equal=false cases",
  )
  fixture["_summary"] = PositionIdentityFixtureSummary(
    case_count=len(cases_by_id),
    relation_count=len(relations_by_id),
    same_visible_different_identity_count=same_visible_different_identity_count,
  )
  return fixture


def main() -> int:
  parser = argparse.ArgumentParser(description="Validate the shared Qixi position-identity fixture.")
  parser.add_argument("fixture", nargs="?", default=str(DEFAULT_FIXTURE))
  args = parser.parse_args()

  try:
    fixture = validate_fixture(pathlib.Path(args.fixture))
  except PositionIdentityFixtureError as exc:
    print(f"Position identity fixture validation failed: {exc}")
    return 1

  summary = fixture["_summary"]
  print(
    "Position identity fixture valid: "
    f"{summary.case_count} cases, {summary.relation_count} relations, "
    f"{summary.same_visible_different_identity_count} same-visible/different-identity relations"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
