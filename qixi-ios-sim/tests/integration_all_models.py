#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import datetime
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import socket
import subprocess
import sys
import time
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent
BACKEND = ROOT / "backend" / "qixi_backend.py"
KATAGO_ROOT = REPO_ROOT / "KataGo"
KATAGO_BIN = KATAGO_ROOT / "cpp" / "build-metal-mux" / "katago"
CONFIG = KATAGO_ROOT / "cpp" / "configs" / "analysis_example.cfg"
OVERRIDE = (ROOT / "configs" / "metal-mux.override").read_text(encoding="utf-8").strip()
ARTIFACT = ROOT / "artifacts" / "real-models" / "latest-real-model-integration.json"
MAX_HTTP_RESPONSE_BYTES = 2 * 1024 * 1024
DEFAULT_REAL_MODEL_MAX_VISITS = 8
EXPECTED_CASE_IDS = ("opening", "same-stones-history-a", "same-stones-history-b")
ALLOWED_PLATFORM_SYMLINK_ALIASES = {
  pathlib.Path("/var"): pathlib.Path("/private/var"),
  pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
  pathlib.Path("/etc"): pathlib.Path("/private/etc"),
}

spec = importlib.util.spec_from_file_location("qixi_backend", BACKEND)
assert spec is not None and spec.loader is not None
qixi_backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qixi_backend)


def free_port() -> int:
  with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as sock:
    sock.bind(("127.0.0.1", 0))
    return int(sock.getsockname()[1])


def load_json_object_without_duplicate_keys(body: bytes, label: str) -> dict:
  if len(body) > MAX_HTTP_RESPONSE_BYTES:
    raise RuntimeError(f"{label} response body exceeds {MAX_HTTP_RESPONSE_BYTES} bytes")

  def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    result: dict[str, object] = {}
    for key, value in pairs:
      if key in result:
        raise RuntimeError(f"{label} must not contain duplicate JSON key {key!r}")
      result[key] = value
    return result

  def reject_non_standard_constant(value: str) -> None:
    raise RuntimeError(f"{label} must not contain non-standard JSON constant {value}")

  payload = json.loads(
    body.decode("utf-8"),
    object_pairs_hook=reject_duplicate_keys,
    parse_constant=reject_non_standard_constant,
  )
  if not isinstance(payload, dict):
    raise RuntimeError(f"{label} must be a JSON object")
  return payload


def request_json(url: str, payload: dict | None = None, timeout: float = 240.0) -> dict:
  data = None
  headers = {}
  if payload is not None:
    data = json.dumps(payload).encode("utf-8")
    headers["Content-Type"] = "application/json"
  req = urllib.request.Request(url, data=data, headers=headers, method="POST" if payload is not None else "GET")
  with urllib.request.urlopen(req, timeout=timeout) as resp:
    media_type = resp.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
    if media_type != "application/json":
      raise RuntimeError(f"backend response must use application/json, got {media_type or '(missing Content-Type)'}")
    body = resp.read(MAX_HTTP_RESPONSE_BYTES + 1)
  return load_json_object_without_duplicate_keys(body, "backend response")


def wait_http_ready(base_url: str, proc: subprocess.Popen[str]) -> None:
  deadline = time.monotonic() + 45
  while time.monotonic() < deadline:
    if proc.poll() is not None:
      raise RuntimeError(f"backend exited early with code {proc.returncode}")
    try:
      request_json(base_url + "/api/status", timeout=3)
      return
    except Exception:
      time.sleep(0.25)
  raise RuntimeError("backend did not start")


def assert_finite_number(value: object, label: str) -> float:
  number = float(value)
  assert math.isfinite(number), f"{label} must be finite: {value!r}"
  return number


def assert_candidate_moves_are_well_formed(result: dict, engine_id: str) -> None:
  moves = result.get("moves")
  assert isinstance(moves, list) and len(moves) > 0, result
  seen: set[tuple[int, int]] = set()
  for item in moves:
    assert isinstance(item, dict), item
    x = item.get("x")
    y = item.get("y")
    assert isinstance(x, int) and 0 <= x < 19, (engine_id, item)
    assert isinstance(y, int) and 0 <= y < 19, (engine_id, item)
    assert (x, y) not in seen, (engine_id, item, moves)
    seen.add((x, y))
    assert isinstance(item.get("move"), str) and item["move"], (engine_id, item)
    assert int(item.get("visits", -1)) >= 0, (engine_id, item)
    winrate = assert_finite_number(item.get("winrate"), f"{engine_id} candidate winrate")
    assert 0.0 <= winrate <= 1.0, (engine_id, item)
    assert_finite_number(item.get("scoreMean"), f"{engine_id} candidate scoreMean")


def utc_timestamp() -> str:
  return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def elapsed_ms(started_at: float) -> float:
  return round((time.perf_counter() - started_at) * 1000, 3)


def engine_model_path(engine_id: str) -> pathlib.Path:
  env_name = qixi_backend.ENGINE_MODEL_ENVS[engine_id]
  configured = os.environ.get(env_name)
  return pathlib.Path(configured or qixi_backend.ENGINE_MODEL_DEFAULTS[engine_id]).expanduser()


def analysis_cases() -> list[dict]:
  return [
    {
      "caseId": "opening",
      "history": [{"color": "B", "x": 3, "y": 3}, {"color": "W", "x": 15, "y": 15}],
      "komi": 7.5,
      "rootNoise": 0.0,
    },
    {
      "caseId": "same-stones-history-a",
      "history": [
        {"color": "B", "x": 3, "y": 3},
        {"color": "W", "x": 15, "y": 15},
        {"color": "B", "x": 16, "y": 3},
        {"color": "W", "x": 2, "y": 15},
      ],
      "komi": 7.5,
      "rootNoise": 0.0,
    },
    {
      "caseId": "same-stones-history-b",
      "history": [
        {"color": "B", "x": 16, "y": 3},
        {"color": "W", "x": 2, "y": 15},
        {"color": "B", "x": 3, "y": 3},
        {"color": "W", "x": 15, "y": 15},
      ],
      "komi": 7.5,
      "rootNoise": 0.0,
    },
  ]


def final_stone_digest(history: list[dict]) -> str:
  stones = qixi_backend.final_stones(history)
  text = json.dumps(stones, sort_keys=True, separators=(",", ":"))
  return hashlib.sha256(text.encode("utf-8")).hexdigest()


def summarize_case_definition(case: dict) -> dict:
  history = case["history"]
  return {
    "caseId": case["caseId"],
    "historyLength": len(history),
    "finalStoneCount": len(qixi_backend.final_stones(history)),
    "finalStoneDigest": final_stone_digest(history),
    "komi": float(case["komi"]),
    "rootNoise": float(case["rootNoise"]),
  }


def summarize_real_model_case_result(
  *,
  engine_id: str,
  case: dict,
  result: dict,
  analysis_elapsed_ms: float,
  max_visits: int,
) -> dict:
  ownership = [float(value) for value in result["ownership"]]
  moves = result["moves"]
  best_move = moves[0]
  return {
    "caseId": case["caseId"],
    "engineId": engine_id,
    "engine": result["engine"],
    "positionKey": result["positionKey"],
    "historyLength": len(case["history"]),
    "komi": float(case["komi"]),
    "rootNoise": float(case["rootNoise"]),
    "maxVisits": max_visits,
    "rootVisits": int(result["visits"]),
    "candidateCount": len(moves),
    "ownershipPointCount": len(ownership),
    "ownershipMin": min(ownership),
    "ownershipMax": max(ownership),
    "winrate": float(result["winrate"]),
    "scoreMean": float(result["scoreMean"]),
    "bestMove": {
      "move": best_move["move"],
      "x": best_move["x"],
      "y": best_move["y"],
      "visits": int(best_move["visits"]),
      "winrate": float(best_move["winrate"]),
      "scoreMean": float(best_move["scoreMean"]),
    },
    "analysisElapsedMs": analysis_elapsed_ms,
  }


def summarize_real_model_result(
  *,
  engine_id: str,
  status: dict,
  primary_case_result: dict,
  status_elapsed_ms: float,
) -> dict:
  model_path = engine_model_path(engine_id)
  return {
    **primary_case_result,
    "modelPath": str(model_path),
    "modelByteCount": model_path.stat().st_size,
    "statusRunning": status["running"],
    "statusPaused": status["paused"],
    "statusElapsedMs": status_elapsed_ms,
  }


def normalized_path(path: pathlib.Path) -> pathlib.Path:
  expanded = path.expanduser()
  if expanded.is_absolute():
    return expanded
  return pathlib.Path.cwd() / expanded


def is_allowed_platform_symlink_alias(path: pathlib.Path) -> bool:
  expected_target = ALLOWED_PLATFORM_SYMLINK_ALIASES.get(path)
  if expected_target is None:
    return False
  try:
    return path.resolve(strict=True) == expected_target
  except OSError:
    return False


def reject_symlink_components(path: pathlib.Path, label: str) -> pathlib.Path:
  checked_path = normalized_path(path)
  current = pathlib.Path(checked_path.anchor) if checked_path.anchor else pathlib.Path()
  for part in checked_path.parts:
    if part == checked_path.anchor or not part:
      continue
    current = current / part
    if current.is_symlink() and not is_allowed_platform_symlink_alias(current):
      raise RuntimeError(f"{label} must not contain symbolic links: {current}")
  return checked_path


def write_atomic_real_model_artifact(target: pathlib.Path, payload: bytes) -> None:
  checked_path = reject_symlink_components(target, "real-model integration artifact target")
  checked_path.parent.mkdir(parents=True, exist_ok=True)
  parent = reject_symlink_components(checked_path.parent, "real-model integration artifact parent")
  if not parent.is_dir():
    raise RuntimeError(f"real-model integration artifact parent is not a directory: {parent}")

  tmp_path = reject_symlink_components(
    checked_path.with_name(f".{checked_path.name}.{os.getpid()}.tmp"),
    "real-model integration artifact atomic-write temporary path",
  )
  flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
  if hasattr(os, "O_CLOEXEC"):
    flags |= os.O_CLOEXEC
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW

  fd = -1
  tmp_created = False
  try:
    try:
      fd = os.open(str(tmp_path), flags, 0o600)
    except OSError as exc:
      raise RuntimeError(
        f"real-model integration artifact atomic-write temporary file could not be created: {tmp_path}: {exc}"
      ) from exc
    tmp_created = True
    with os.fdopen(fd, "wb") as handle:
      fd = -1
      handle.write(payload)
      handle.flush()
      os.fsync(handle.fileno())
    reject_symlink_components(checked_path, "real-model integration artifact target")
    os.replace(tmp_path, checked_path)
    tmp_created = False
    parent_fd = os.open(str(parent), os.O_RDONLY)
    try:
      os.fsync(parent_fd)
    finally:
      os.close(parent_fd)
  except OSError as exc:
    raise RuntimeError(f"real-model integration artifact could not be written: {checked_path}: {exc}") from exc
  finally:
    if fd >= 0:
      os.close(fd)
    if tmp_created:
      try:
        tmp_path.unlink()
      except FileNotFoundError:
        pass


def write_real_model_artifact(artifact: dict) -> None:
  payload = (json.dumps(artifact, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
  write_atomic_real_model_artifact(ARTIFACT, payload)


def assert_real_analysis(result: dict, engine_id: str, case: dict) -> None:
  expected_engine = f"katago-metal-mux:{engine_id}"
  history = case["history"]
  assert result["engine"] == expected_engine, result
  assert result["positionKey"] == qixi_backend.position_key(
    history,
    expected_engine,
    komi=float(case["komi"]),
    root_noise=float(case["rootNoise"]),
  ), result
  assert len(result["positionKey"]) == 64, result
  winrate = assert_finite_number(result.get("winrate"), f"{engine_id} root winrate")
  assert 0.0 <= winrate <= 1.0, result
  assert_finite_number(result.get("scoreMean"), f"{engine_id} root scoreMean")
  assert int(result.get("visits", 0)) >= 1, result
  ownership = result.get("ownership")
  assert isinstance(ownership, list) and len(ownership) == 19 * 19, result
  for index, value in enumerate(ownership):
    number = assert_finite_number(value, f"{engine_id} ownership[{index}]")
    assert -1.01 <= number <= 1.01, (engine_id, index, value)
  assert_candidate_moves_are_well_formed(result, engine_id)


def same_visible_different_history_check(engine_id: str, case_results: dict[str, dict]) -> dict:
  case_a = "same-stones-history-a"
  case_b = "same-stones-history-b"
  cases_by_id = {case["caseId"]: case for case in analysis_cases()}
  final_digest_a = final_stone_digest(cases_by_id[case_a]["history"])
  final_digest_b = final_stone_digest(cases_by_id[case_b]["history"])
  position_key_a = case_results[case_a]["positionKey"]
  position_key_b = case_results[case_b]["positionKey"]
  return {
    "engineId": engine_id,
    "caseA": case_a,
    "caseB": case_b,
    "finalStonesEqual": final_digest_a == final_digest_b,
    "positionKeysDistinct": position_key_a != position_key_b,
    "positionKeyA": position_key_a,
    "positionKeyB": position_key_b,
    "finalStoneDigest": final_digest_a,
  }


def main() -> int:
  if not KATAGO_BIN.exists():
    raise RuntimeError(f"KataGo binary missing: {KATAGO_BIN}")

  port = free_port()
  base_url = f"http://127.0.0.1:{port}"
  env = os.environ.copy()
  env.update({
    "QIXI_KATAGO_BIN": str(KATAGO_BIN),
    "QIXI_KATAGO_CONFIG": str(CONFIG),
    "QIXI_KATAGO_OVERRIDE": OVERRIDE,
  })
  proc = subprocess.Popen(
    [sys.executable, str(BACKEND), "--host", "127.0.0.1", "--port", str(port)],
    cwd=str(REPO_ROOT),
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
  )
  try:
    wait_http_ready(base_url, proc)
    cases = analysis_cases()
    assert tuple(case["caseId"] for case in cases) == EXPECTED_CASE_IDS
    max_visits = int(os.environ.get("QIXI_REAL_MODEL_MAX_VISITS", str(DEFAULT_REAL_MODEL_MAX_VISITS)))
    max_visits = max(DEFAULT_REAL_MODEL_MAX_VISITS, min(max_visits, 4096))
    position_keys: list[str] = []
    artifact: dict = {
      "schemaVersion": 1,
      "kind": "qixi-real-model-metal-mux-integration",
      "generatedAt": utc_timestamp(),
      "katagoBinary": str(KATAGO_BIN),
      "katagoBinaryByteCount": KATAGO_BIN.stat().st_size,
      "configPath": str(CONFIG),
      "overrideSha256": hashlib.sha256(OVERRIDE.encode("utf-8")).hexdigest(),
      "historyLength": len(cases[0]["history"]),
      "maxVisits": max_visits,
      "caseDefinitions": [summarize_case_definition(case) for case in cases],
      "engines": [],
      "offEngineChecks": [],
      "sameVisibleDifferentHistoryChecks": [],
    }
    for engine_id in ("b6", "b18nbt", "b28nbt"):
      status_started_at = time.perf_counter()
      status = request_json(base_url + "/api/engine", {"engine": engine_id}, timeout=240)
      status_elapsed_ms = elapsed_ms(status_started_at)
      assert status["engine"] == f"katago-metal-mux:{engine_id}", status
      assert status["engineId"] == engine_id, status
      assert status["running"] is True, status
      assert status["paused"] is False, status

      case_results: dict[str, dict] = {}
      summarized_cases: list[dict] = []
      for case in cases:
        analysis_started_at = time.perf_counter()
        result = request_json(
          base_url + "/api/analyze",
          {
            "moves": case["history"],
            "maxVisits": max_visits,
            "komi": case["komi"],
            "rootNoise": case["rootNoise"],
          },
          timeout=300,
        )
        analysis_elapsed_ms = elapsed_ms(analysis_started_at)
        assert_real_analysis(result, engine_id, case)
        case_summary = summarize_real_model_case_result(
          engine_id=engine_id,
          case=case,
          result=result,
          analysis_elapsed_ms=analysis_elapsed_ms,
          max_visits=max_visits,
        )
        case_results[case["caseId"]] = case_summary
        summarized_cases.append(case_summary)
        position_keys.append(result["positionKey"])

      artifact["engines"].append(
        {
          **summarize_real_model_result(
            engine_id=engine_id,
            status=status,
            primary_case_result=summarized_cases[0],
            status_elapsed_ms=status_elapsed_ms,
          ),
          "analysisCases": summarized_cases,
        }
      )
      same_visible_check = same_visible_different_history_check(engine_id, case_results)
      assert same_visible_check["finalStonesEqual"] is True, same_visible_check
      assert same_visible_check["positionKeysDistinct"] is True, same_visible_check
      artifact["sameVisibleDifferentHistoryChecks"].append(same_visible_check)

      off_status = request_json(base_url + "/api/engine", {"engine": "none"}, timeout=120)
      assert off_status["engine"] == "none", off_status
      assert off_status["engineId"] == "none", off_status
      assert off_status["running"] is False, off_status
      off_result = request_json(base_url + "/api/analyze", {"moves": cases[0]["history"], "maxVisits": max_visits}, timeout=120)
      assert off_result["engine"] == "none", off_result
      assert off_result["positionKey"] == qixi_backend.position_key(cases[0]["history"], "none"), off_result
      assert off_result["moves"] == [], off_result
      assert off_result["ownership"] == [], off_result
      artifact["offEngineChecks"].append(
        {
          "afterEngineId": engine_id,
          "positionKey": off_result["positionKey"],
          "movesCount": len(off_result["moves"]),
          "ownershipPointCount": len(off_result["ownership"]),
          "running": off_status["running"],
          "paused": off_status["paused"],
        }
      )

    assert len(set(position_keys)) == len(position_keys), position_keys
    artifact["positionKeysUnique"] = True
    write_real_model_artifact(artifact)
    print("All real model integrations passed: b6, b18nbt, b28nbt")
    print(f"Real model integration artifact: {ARTIFACT}")
    return 0
  finally:
    proc.terminate()
    try:
      output, _ = proc.communicate(timeout=8)
    except subprocess.TimeoutExpired:
      proc.kill()
      output, _ = proc.communicate(timeout=8)
    if proc.returncode not in (0, -15, None):
      print(output)


if __name__ == "__main__":
  raise SystemExit(main())
