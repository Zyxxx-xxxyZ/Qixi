#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import math
import os
import pathlib
import subprocess
import sys
import threading
import time
import urllib.parse
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
WEB_ROOT = ROOT / "web"
ASSET_ROOT = ROOT / "assets"
REPO_ROOT = ROOT.parent
KATAGO_ROOT = REPO_ROOT / "KataGo"
DEFAULT_METAL_KATAGO_BIN = KATAGO_ROOT / "cpp" / "build-metal-mux" / "katago"
DEFAULT_PERSISTENT_KATAGO_BIN = KATAGO_ROOT / "cpp" / "build-persistent-mcts" / "katago"
DEFAULT_KATAGO_BIN = DEFAULT_METAL_KATAGO_BIN if DEFAULT_METAL_KATAGO_BIN.exists() else DEFAULT_PERSISTENT_KATAGO_BIN
DEFAULT_KATAGO_CONFIG = KATAGO_ROOT / "cpp" / "configs" / "analysis_example.cfg"
DEFAULT_B6_MODEL = KATAGO_ROOT / "cpp" / "tests" / "models" / "g170-b6c96-s175395328-d26788732.bin.gz"
DEFAULT_B18_MODEL = REPO_ROOT / "b18nbt.bin"
DEFAULT_B28_MODEL = REPO_ROOT / "b28nbt.bin"
DEFAULT_OVERRIDE = (ROOT / "configs" / "metal-mux.override").read_text(encoding="utf-8").strip()
LETTERS = "ABCDEFGHJKLMNOPQRST"
BOARD_SIZE = 19
ENGINE_MODEL_DEFAULTS = {
  "b6": DEFAULT_B6_MODEL,
  "b18nbt": DEFAULT_B18_MODEL,
  "b28nbt": DEFAULT_B28_MODEL,
}
ENGINE_MODEL_ENVS = {
  "b6": "QIXI_KATAGO_B6_MODEL",
  "b18nbt": "QIXI_KATAGO_B18_MODEL",
  "b28nbt": "QIXI_KATAGO_B28_MODEL",
}
MAX_REQUEST_BYTES = 256 * 1024
MAX_EVENT_LOG_ENTRIES = 256


class EngineError(RuntimeError):
  pass


def load_json_object_without_duplicate_keys(body: bytes, label: str) -> dict[str, Any]:
  def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
      if key in result:
        raise EngineError(f"{label} must not contain duplicate JSON key {key!r}")
      result[key] = value
    return result

  def reject_non_standard_constant(value: str) -> None:
    raise EngineError(f"{label} must not contain non-standard JSON constant {value}")

  try:
    payload = json.loads(
      body.decode("utf-8"),
      object_pairs_hook=reject_duplicate_keys,
      parse_constant=reject_non_standard_constant,
    )
  except EngineError:
    raise
  except Exception as exc:
    raise EngineError(f"{label} must be valid JSON: {exc}") from exc
  if not isinstance(payload, dict):
    raise EngineError(f"{label} must be a JSON object")
  return payload


class AnalysisContext:
  def __init__(self, rules: str = "Chinese", komi: float = 7.5, root_noise: float = 0.0) -> None:
    self.rules = rules
    self.komi = komi
    self.root_noise = root_noise


def gtp_coord(x: int, y: int) -> str:
  return f"{LETTERS[x]}{BOARD_SIZE - y}"


def normalize_move(move: dict[str, Any], index: int) -> dict[str, Any]:
  if not isinstance(move, dict):
    raise EngineError(f"Move {index} must be an object")

  color_value = move.get("color")
  if color_value is None:
    raise EngineError(f"Move {index} missing color")
  color = str(color_value).upper()
  if color not in ("B", "W"):
    raise EngineError(f"Move {index} has invalid color: {color_value}")

  pass_value = move.get("pass", False)
  if pass_value is None:
    pass_value = False
  if not isinstance(pass_value, bool):
    raise EngineError(f"Move {index} pass flag must be boolean")
  move_text = move.get("move")
  if move_text is not None and str(move_text).lower() != "pass":
    raise EngineError(f"Move {index} unsupported move field: {move_text}")

  is_pass = pass_value or (move_text is not None and str(move_text).lower() == "pass")
  if is_pass:
    if move.get("x") is not None or move.get("y") is not None:
      raise EngineError(f"Move {index} pass must not include coordinates")
    return {"color": color, "pass": True}

  if "x" not in move or "y" not in move:
    raise EngineError(f"Move {index} missing coordinates")
  x = move.get("x")
  y = move.get("y")
  if isinstance(x, bool) or isinstance(y, bool) or not isinstance(x, int) or not isinstance(y, int):
    raise EngineError(f"Move {index} coordinates must be integers")
  if x < 0 or x >= BOARD_SIZE or y < 0 or y >= BOARD_SIZE:
    raise EngineError(f"Move {index} coordinates out of range: ({x},{y})")
  return {"color": color, "x": x, "y": y}


def normalized_moves(moves: Any) -> list[dict[str, Any]]:
  if not isinstance(moves, list):
    raise EngineError("moves must be a list")
  return [normalize_move(move, index) for index, move in enumerate(moves)]


def board_index(x: int, y: int) -> int:
  return y * BOARD_SIZE + x


def neighbors(index: int) -> list[int]:
  x = index % BOARD_SIZE
  y = index // BOARD_SIZE
  values = []
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


def next_board_after_playing(board: list[str | None], move: dict[str, Any]) -> list[str | None] | None:
  if move.get("pass"):
    return board.copy()
  x = int(move["x"])
  y = int(move["y"])
  point = board_index(x, y)
  if board[point] is not None:
    return None

  color = move["color"]
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
  if not has_liberty(next_board, own_group):
    return None
  return next_board


def replay_snapshots(moves: list[dict[str, Any]]) -> list[list[str | None]]:
  board: list[str | None] = [None] * (BOARD_SIZE * BOARD_SIZE)
  snapshots = [board.copy()]
  for index, move in enumerate(normalized_moves(moves)):
    candidate = next_board_after_playing(board, move)
    if candidate is None:
      raise EngineError(f"Move {index} is illegal under board replay")
    if not move.get("pass") and len(snapshots) >= 2 and candidate == snapshots[-2]:
      raise EngineError(f"Move {index} is illegal immediate ko recapture")
    board = candidate
    snapshots.append(board.copy())
  return snapshots


def validate_legal_history(moves: list[dict[str, Any]]) -> None:
  replay_snapshots(moves)


def final_board(moves: list[dict[str, Any]]) -> list[str | None]:
  return replay_snapshots(moves)[-1]


def final_stones(moves: list[dict[str, Any]]) -> list[dict[str, Any]]:
  board = final_board(moves)
  stones = []
  for index, color in enumerate(board):
    if color is None:
      continue
    stones.append({"color": color, "x": index % BOARD_SIZE, "y": index // BOARD_SIZE})
  return stones


def move_to_gtp(move: dict[str, Any]) -> str:
  move = normalize_move(move, -1)
  if move.get("pass"):
    return "pass"
  return gtp_coord(int(move["x"]), int(move["y"]))


def xy_from_gtp(move: str) -> tuple[int, int] | None:
  if not move or move.lower() == "pass":
    return None
  col = move[0].upper()
  if col not in LETTERS:
    return None
  try:
    row = int(move[1:])
  except ValueError:
    return None
  x = LETTERS.index(col)
  y = BOARD_SIZE - row
  if x < 0 or x >= BOARD_SIZE or y < 0 or y >= BOARD_SIZE:
    return None
  return x, y


def stable_unit(*parts: Any) -> float:
  text = json.dumps(parts, sort_keys=True, separators=(",", ":"))
  digest = hashlib.sha256(text.encode("utf-8")).digest()
  value = int.from_bytes(digest[:8], "big")
  return value / float(2**64 - 1)


def normalized_history(moves: list[dict[str, Any]]) -> list[dict[str, Any]]:
  history = []
  for idx, move in enumerate(normalized_moves(moves)):
    color = move["color"]
    if move.get("pass"):
      history.append({"idx": idx, "color": color, "move": "pass"})
    else:
      history.append({
        "idx": idx,
        "color": color,
        "x": int(move["x"]),
        "y": int(move["y"]),
        "move": move_to_gtp(move),
      })
  return history


def analysis_context(payload: dict[str, Any] | None = None) -> AnalysisContext:
  payload = payload or {}
  rules = str(payload.get("rules", "Chinese"))
  komi = float(payload.get("komi", 7.5))
  root_noise = float(payload.get("rootNoise", payload.get("wideRootNoise", 0.0)))
  if not math.isfinite(komi) or komi < -150.0 or komi > 150.0:
    raise EngineError(f"Invalid komi: {komi}")
  if not math.isfinite(root_noise) or root_noise < 0.0:
    raise EngineError(f"Invalid root noise: {root_noise}")
  return AnalysisContext(rules=rules, komi=komi, root_noise=root_noise)


def position_key(
  moves: list[dict[str, Any]],
  engine_name: str,
  rules: str = "Chinese",
  komi: float = 7.5,
  root_noise: float = 0.0,
) -> str:
  payload = {
    "boardSize": BOARD_SIZE,
    "engine": engine_name,
    "komi": komi,
    "rules": rules,
    "search": {
      "wideRootNoise": root_noise,
    },
    "history": normalized_history(moves),
  }
  text = json.dumps(payload, sort_keys=True, separators=(",", ":"))
  return hashlib.sha256(text.encode("utf-8")).hexdigest()


class NullEngine:
  name = "none"

  def analyze(self, moves: list[dict[str, Any]], max_visits: int, context: AnalysisContext) -> dict[str, Any]:
    validate_legal_history(moves)
    return {
      "engine": self.name,
      "state": "no engine loaded",
      "positionKey": position_key(moves, self.name, context.rules, context.komi, context.root_noise),
      "winrate": None,
      "scoreMean": None,
      "visits": 0,
      "moves": [],
      "ownership": [],
    }

  def shutdown(self) -> None:
    return


class DeterministicMockEngine:
  name = "mock"

  def analyze(self, moves: list[dict[str, Any]], max_visits: int, context: AnalysisContext) -> dict[str, Any]:
    moves = normalized_moves(moves)
    board = final_board(moves)
    stones = final_stones(moves)

    candidates: list[dict[str, Any]] = []
    for y in range(BOARD_SIZE):
      for x in range(BOARD_SIZE):
        if board[y * BOARD_SIZE + x] is not None:
          continue
        center = 1.0 - (abs(x - 9) + abs(y - 9)) / 24.0
        noise = stable_unit("move", moves, context.komi, context.root_noise, x, y)
        score = center * 0.55 + noise * 0.45
        candidates.append({
          "x": x,
          "y": y,
          "move": gtp_coord(x, y),
          "rankScore": score,
        })
    candidates.sort(key=lambda item: item["rankScore"], reverse=True)

    top = []
    remaining = max(1, max_visits)
    for index, item in enumerate(candidates[:10]):
      share = max(1, int(max_visits * (0.34 / (index + 1))))
      remaining = max(0, remaining - share)
      winrate = 0.5 + (item["rankScore"] - 0.5) * 0.22
      top.append({
        "x": item["x"],
        "y": item["y"],
        "move": item["move"],
        "visits": share,
        "winrate": max(0.01, min(0.99, winrate)),
        "scoreMean": (item["rankScore"] - 0.5) * 18.0,
      })
    if top:
      top[0]["visits"] += remaining

    black_influence = 0.0
    white_influence = 0.0
    for move in stones:
      color = move["color"]
      x = int(move["x"])
      y = int(move["y"])
      weight = 1.0 + stable_unit("stone", x, y) * 0.2
      if color == "B":
        black_influence += weight
      else:
        white_influence += weight

    ownership = []
    for y in range(BOARD_SIZE):
      for x in range(BOARD_SIZE):
        local = 0.0
        for move in stones:
          sx = int(move["x"])
          sy = int(move["y"])
          dist = abs(sx - x) + abs(sy - y)
          influence = math.exp(-dist / 4.6)
          local += influence if move.get("color") == "W" else -influence
        ownership.append(max(-1.0, min(1.0, local * 0.48)))

    balance = black_influence - white_influence
    komi_adjustment = (7.5 - context.komi) * 0.018
    root_jitter = (stable_unit("root", moves, context.komi, context.root_noise) - 0.5) * (0.05 + context.root_noise * 0.1)
    winrate = max(0.01, min(0.99, 0.5 + balance * 0.018 + komi_adjustment + root_jitter))
    score_mean = balance * 1.8 + (7.5 - context.komi) + (stable_unit("score", moves, context.komi, context.root_noise) - 0.5) * 5.0
    return {
      "engine": self.name,
      "state": "running deterministic analysis",
      "positionKey": position_key(moves, self.name, context.rules, context.komi, context.root_noise),
      "winrate": winrate,
      "scoreMean": score_mean,
      "visits": max_visits,
      "moves": top,
      "ownership": ownership,
    }

  def shutdown(self) -> None:
    return


class KataGoAnalysisEngine:
  def __init__(self, engine_id: str, binary: pathlib.Path, model: pathlib.Path, config: pathlib.Path, override: str) -> None:
    if not binary.exists():
      raise EngineError(f"KataGo binary not found: {binary}")
    if not model.exists():
      raise EngineError(f"KataGo model not found: {model}")
    if not config.exists():
      raise EngineError(f"KataGo config not found: {config}")

    self.engine_id = engine_id
    self.name = f"katago-metal-mux:{engine_id}"
    self.model = model
    self._lock = threading.Lock()
    command = [
      str(binary),
      "analysis",
      "-model",
      str(model),
      "-config",
      str(config),
    ]
    if override:
      command.extend(["-override-config", override])

    self._process = subprocess.Popen(
      command,
      stdin=subprocess.PIPE,
      stdout=subprocess.PIPE,
      stderr=subprocess.PIPE,
      text=True,
      bufsize=1,
    )
    self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
    self._stderr_thread.start()

  def _drain_stderr(self) -> None:
    assert self._process.stderr is not None
    for line in self._process.stderr:
      sys.stderr.write(f"[katago] {line}")

  def analyze(self, moves: list[dict[str, Any]], max_visits: int, context: AnalysisContext) -> dict[str, Any]:
    query_id = f"qixi-{time.time_ns()}"
    query = self.query_payload(query_id, moves, max_visits, context)
    with self._lock:
      if self._process.poll() is not None:
        raise EngineError(f"KataGo exited with code {self._process.returncode}")
      assert self._process.stdin is not None
      assert self._process.stdout is not None
      self._process.stdin.write(json.dumps(query, separators=(",", ":")) + "\n")
      self._process.stdin.flush()

      deadline = time.monotonic() + 120.0
      while time.monotonic() < deadline:
        line = self._process.stdout.readline()
        if not line:
          break
        payload = load_json_object_without_duplicate_keys(
          line.encode("utf-8"),
          "KataGo analysis response",
        )
        if payload.get("id") == query_id:
          return self._convert_response(payload, max_visits, moves, context)
    raise EngineError("Timed out waiting for KataGo analysis response")

  @staticmethod
  def query_payload(query_id: str, moves: list[dict[str, Any]], max_visits: int, context: AnalysisContext) -> dict[str, Any]:
    validate_legal_history(moves)
    kg_moves = []
    for move in normalized_moves(moves):
      kg_moves.append([move["color"], move_to_gtp(move)])
    query = {
      "id": query_id,
      "moves": kg_moves,
      "initialStones": [],
      "rules": context.rules,
      "komi": context.komi,
      "boardXSize": BOARD_SIZE,
      "boardYSize": BOARD_SIZE,
      "includeOwnership": True,
      "maxVisits": int(max_visits),
    }
    if context.root_noise > 0.0:
      query["overrideSettings"] = {"wideRootNoise": context.root_noise}
    return query

  def _convert_response(
    self,
    payload: dict[str, Any],
    max_visits: int,
    moves_in_query: list[dict[str, Any]],
    context: AnalysisContext,
  ) -> dict[str, Any]:
    root = payload.get("rootInfo", {})
    move_infos = payload.get("moveInfos", [])
    moves = []
    for item in move_infos[:10]:
      xy = xy_from_gtp(item.get("move", ""))
      if xy is None:
        continue
      x, y = xy
      moves.append({
        "x": x,
        "y": y,
        "move": item.get("move"),
        "visits": item.get("visits", 0),
        "winrate": item.get("winrate", 0.0),
        "scoreMean": item.get("scoreMean", item.get("scoreLead", root.get("scoreMean", 0.0))),
      })
    return {
      "engine": self.name,
      "state": "running Metal mux analysis",
      "positionKey": position_key(moves_in_query, self.name, context.rules, context.komi, context.root_noise),
      "winrate": root.get("winrate", payload.get("rootWinrate", 0.0)),
      "scoreMean": root.get("scoreMean", payload.get("scoreMean", 0.0)),
      "visits": root.get("visits", max_visits),
      "moves": moves,
      "ownership": payload.get("ownership", []),
    }

  def shutdown(self) -> None:
    if self._process.poll() is None:
      self._process.terminate()
      try:
        self._process.wait(timeout=5)
      except subprocess.TimeoutExpired:
        self._process.kill()


class AppState:
  def __init__(self) -> None:
    self.running = False
    self.paused = False
    self.engine = self._create_engine(os.environ.get("QIXI_ENGINE_MODE", "none"))
    self._event_lock = threading.Lock()
    self._events: list[dict[str, Any]] = []
    self._event_sequence = 0

  def record_request_event(self, path: str, payload: dict[str, Any], client: str) -> None:
    if path == "/api/engine":
      summary = {
        "kind": "engine",
        "engine": str(payload.get("engine", "")),
      }
    elif path == "/api/analyze":
      moves = payload.get("moves", [])
      summary = {
        "kind": "analyze",
        "engine": self.status_payload()["engineId"],
        "maxVisits": int(payload.get("maxVisits", 0) or 0),
        "moveCount": len(moves) if isinstance(moves, list) else -1,
      }
    else:
      return

    with self._event_lock:
      self._event_sequence += 1
      event = {
        "sequence": self._event_sequence,
        "path": path,
        "client": client,
        "receivedAtUnixMs": round(time.time() * 1000),
        **summary,
      }
      self._events.append(event)
      if len(self._events) > MAX_EVENT_LOG_ENTRIES:
        del self._events[: len(self._events) - MAX_EVENT_LOG_ENTRIES]

  def events_payload(self) -> dict[str, Any]:
    with self._event_lock:
      events = [dict(event) for event in self._events]
      sequence = self._event_sequence
    return {
      "schemaVersion": 1,
      "count": len(events),
      "latestSequence": sequence,
      "events": events,
    }

  def _create_engine(self, mode: str) -> NullEngine | DeterministicMockEngine | KataGoAnalysisEngine:
    mode = mode.lower()
    if mode == "mock":
      return DeterministicMockEngine()
    if mode in ("none", "off", "disabled"):
      return NullEngine()
    model = self._model_for_engine(mode)
    if not model:
      return NullEngine()
    binary = pathlib.Path(os.environ.get("QIXI_KATAGO_BIN", str(DEFAULT_KATAGO_BIN))).expanduser()
    config = pathlib.Path(os.environ.get("QIXI_KATAGO_CONFIG", str(DEFAULT_KATAGO_CONFIG))).expanduser()
    override = os.environ.get("QIXI_KATAGO_OVERRIDE", DEFAULT_OVERRIDE)
    return KataGoAnalysisEngine(engine_id=mode, binary=binary, model=pathlib.Path(model).expanduser(), config=config, override=override)

  def _model_for_engine(self, engine_id: str) -> str | None:
    if engine_id in ENGINE_MODEL_DEFAULTS:
      specific = os.environ.get(ENGINE_MODEL_ENVS[engine_id])
      return specific or str(ENGINE_MODEL_DEFAULTS[engine_id])
    if engine_id == "katago":
      return os.environ.get("QIXI_KATAGO_MODEL")
    return os.environ.get("QIXI_KATAGO_MODEL")

  def status_payload(self) -> dict[str, Any]:
    state = "paused" if self.paused else "running" if self.running else "ready"
    return {
      "engine": self.engine.name,
      "engineId": getattr(self.engine, "engine_id", self.engine.name),
      "state": state,
      "running": self.running,
      "paused": self.paused,
    }

  def control(self, action: str) -> dict[str, Any]:
    if action == "start":
      self.running = True
      self.paused = False
    elif action == "pause":
      self.paused = True
    elif action == "resume":
      self.running = True
      self.paused = False
    elif action == "stop":
      self.running = False
      self.paused = False
    else:
      raise EngineError(f"Unknown control action: {action}")
    return self.status_payload()

  def set_engine(self, engine_id: str) -> dict[str, Any]:
    old_engine = self.engine
    engine_id = engine_id.lower()
    if engine_id not in ("none", "mock", "b6", "b18nbt", "b28nbt", "katago"):
      raise EngineError(f"Unknown engine id: {engine_id}")
    old_engine.shutdown()
    try:
      self.engine = self._create_engine(engine_id)
    except Exception:
      self.engine = NullEngine()
      self.running = False
      self.paused = False
      raise
    self.running = engine_id != "none"
    self.paused = False
    return self.status_payload()

  def analyze(self, payload: dict[str, Any]) -> dict[str, Any]:
    if self.paused:
      raise EngineError("Analysis is paused")
    moves = normalized_moves(payload.get("moves", []))
    validate_legal_history(moves)
    max_visits = int(payload.get("maxVisits", 64))
    max_visits = max(1, min(max_visits, 4096))
    context = analysis_context(payload)
    self.running = self.engine.name != "none"
    return self.engine.analyze(moves, max_visits, context)

  def shutdown(self) -> None:
    self.engine.shutdown()


class QixiHandler(http.server.SimpleHTTPRequestHandler):
  server_version = "QixiLocalAnalysis/0.1"

  def translate_path(self, path: str) -> str:
    parsed = urllib.parse.urlparse(path)
    request_path = parsed.path
    if request_path.startswith("/assets/"):
      relative = request_path[len("/assets/"):]
      return str((ASSET_ROOT / relative).resolve())
    if request_path == "/":
      return str(WEB_ROOT / "index.html")
    relative = request_path.lstrip("/")
    return str((WEB_ROOT / relative).resolve())

  def end_headers(self) -> None:
    self.send_header("Cache-Control", "no-store")
    super().end_headers()

  def log_message(self, format: str, *args: Any) -> None:
    if os.environ.get("QIXI_BACKEND_HTTP_LOGS") == "1":
      super().log_message(format, *args)

  @property
  def app_state(self) -> AppState:
    return self.server.app_state  # type: ignore[attr-defined]

  def do_GET(self) -> None:
    if self.path == "/api/status":
      self._send_json(200, self.app_state.status_payload())
      return
    if urllib.parse.urlparse(self.path).path == "/api/events":
      self._send_json(200, self.app_state.events_payload())
      return
    super().do_GET()

  def do_POST(self) -> None:
    try:
      payload = self._read_json()
      if self.path == "/api/control":
        self._send_json(200, self.app_state.control(str(payload.get("action", ""))))
      elif self.path == "/api/engine":
        self.app_state.record_request_event(self.path, payload, self.client_address[0])
        self._send_json(200, self.app_state.set_engine(str(payload.get("engine", "none"))))
      elif self.path == "/api/analyze":
        self.app_state.record_request_event(self.path, payload, self.client_address[0])
        self._send_json(200, self.app_state.analyze(payload))
      else:
        self._send_json(404, {"error": "not found"})
    except EngineError as exc:
      self._send_json(400, {"error": str(exc)})
    except Exception as exc:
      self._send_json(500, {"error": str(exc)})

  def _read_json(self) -> dict[str, Any]:
    raw_length = self.headers.get("Content-Length", "0")
    try:
      length = int(raw_length)
    except ValueError as exc:
      raise EngineError("request Content-Length must be an integer") from exc
    if length < 0:
      raise EngineError("request Content-Length must not be negative")
    if length > MAX_REQUEST_BYTES:
      raise EngineError(f"request body exceeds {MAX_REQUEST_BYTES} bytes")
    content_type = self.headers.get("Content-Type", "")
    media_type = content_type.split(";", 1)[0].strip().lower()
    if length > 0 and media_type != "application/json":
      raise EngineError(f"POST request must use application/json, got {content_type or '(missing Content-Type)'}")
    body = self.rfile.read(length)
    if not body:
      return {}
    return load_json_object_without_duplicate_keys(body, "request JSON")

  def _send_json(self, status: int, payload: dict[str, Any]) -> None:
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    self.send_response(status)
    self.send_header("Content-Type", "application/json; charset=utf-8")
    self.send_header("Content-Length", str(len(data)))
    self.end_headers()
    self.wfile.write(data)


class ThreadingHTTPServer(http.server.ThreadingHTTPServer):
  daemon_threads = True

  def __init__(self, server_address: tuple[str, int], handler_class: type[QixiHandler], app_state: AppState) -> None:
    super().__init__(server_address, handler_class)
    self.app_state = app_state


def main() -> int:
  parser = argparse.ArgumentParser(description="Run the Qixi local analysis simulator backend.")
  parser.add_argument("--host", default="127.0.0.1")
  parser.add_argument("--port", type=int, default=8765)
  args = parser.parse_args()

  app_state = AppState()
  server = ThreadingHTTPServer((args.host, args.port), QixiHandler, app_state)
  print(f"Qixi simulator serving http://{args.host}:{args.port}", flush=True)
  print(f"Engine: {app_state.engine.name}", flush=True)
  try:
    server.serve_forever()
  except KeyboardInterrupt:
    pass
  finally:
    app_state.shutdown()
    server.server_close()
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
