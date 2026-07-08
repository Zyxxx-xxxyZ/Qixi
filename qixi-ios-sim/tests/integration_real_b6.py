#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import importlib.util
import json
import os
import pathlib
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent
BACKEND = ROOT / "backend" / "qixi_backend.py"
KATAGO_ROOT = REPO_ROOT / "KataGo"
KATAGO_BIN = KATAGO_ROOT / "cpp" / "build-metal-mux" / "katago"
B6_MODEL = KATAGO_ROOT / "cpp" / "tests" / "models" / "g170-b6c96-s175395328-d26788732.bin.gz"
CONFIG = KATAGO_ROOT / "cpp" / "configs" / "analysis_example.cfg"
OVERRIDE = (ROOT / "configs" / "metal-mux.override").read_text(encoding="utf-8").strip()
MAX_HTTP_RESPONSE_BYTES = 2 * 1024 * 1024

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


def request_json(url: str, payload: dict | None = None, timeout: float = 120.0) -> dict:
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


def wait_ready(base_url: str, proc: subprocess.Popen[str]) -> dict:
  deadline = time.monotonic() + 90
  last_error: Exception | None = None
  while time.monotonic() < deadline:
    if proc.poll() is not None:
      raise RuntimeError(f"backend exited early with code {proc.returncode}")
    try:
      status = request_json(base_url + "/api/status", timeout=3)
      if status.get("engine") == "katago-metal-mux:b6":
        return status
    except Exception as exc:
      last_error = exc
    time.sleep(0.5)
  raise RuntimeError(f"backend did not become ready: {last_error}")


def assert_analysis(result: dict) -> None:
  assert result["engine"] == "katago-metal-mux:b6", result
  assert isinstance(result.get("positionKey"), str) and len(result["positionKey"]) == 64, result
  assert isinstance(result.get("moves"), list) and len(result["moves"]) > 0, result
  assert 0.0 <= float(result["winrate"]) <= 1.0, result
  assert isinstance(result.get("ownership"), list) and len(result["ownership"]) in (0, 19 * 19), result


def main() -> int:
  if not KATAGO_BIN.exists():
    raise RuntimeError(f"KataGo binary missing: {KATAGO_BIN}")
  if not B6_MODEL.exists():
    raise RuntimeError(f"b6 model missing: {B6_MODEL}")

  port = free_port()
  base_url = f"http://127.0.0.1:{port}"
  env = os.environ.copy()
  env.update({
    "QIXI_ENGINE_MODE": "b6",
    "QIXI_KATAGO_BIN": str(KATAGO_BIN),
    "QIXI_KATAGO_MODEL": str(B6_MODEL),
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
    status = wait_ready(base_url, proc)
    assert status["running"] is False

    history_a = [
      {"color": "B", "x": 3, "y": 3},
      {"color": "W", "x": 15, "y": 15},
      {"color": "B", "x": 16, "y": 3},
      {"color": "W", "x": 2, "y": 15},
    ]
    history_b = [
      {"color": "B", "x": 16, "y": 3},
      {"color": "W", "x": 2, "y": 15},
      {"color": "B", "x": 3, "y": 3},
      {"color": "W", "x": 15, "y": 15},
    ]
    expected_a = qixi_backend.position_key(history_a, "katago-metal-mux:b6")
    expected_b = qixi_backend.position_key(history_b, "katago-metal-mux:b6")
    assert expected_a != expected_b

    result_a = request_json(base_url + "/api/analyze", {"moves": history_a, "maxVisits": 2}, timeout=180)
    result_b = request_json(base_url + "/api/analyze", {"moves": history_b, "maxVisits": 2}, timeout=180)
    assert_analysis(result_a)
    assert_analysis(result_b)
    assert result_a["positionKey"] == expected_a
    assert result_b["positionKey"] == expected_b
    assert result_a["positionKey"] != result_b["positionKey"]
    print("Real b6 backend integration passed")
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
