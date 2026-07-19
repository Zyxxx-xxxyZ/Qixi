#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import http.client
import io
import json
import pathlib
import sys
import threading
import urllib.error
import urllib.request
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend" / "qixi_backend.py"
POSITION_IDENTITY_FIXTURE = ROOT.parent / "tests" / "fixtures" / "position_identity_cases.json"
POSITION_IDENTITY_VALIDATOR = ROOT.parent / "tests" / "validate_position_identity_fixture.py"

spec = importlib.util.spec_from_file_location("qixi_backend", BACKEND)
assert spec is not None and spec.loader is not None
qixi_backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qixi_backend)

validator_spec = importlib.util.spec_from_file_location("validate_position_identity_fixture", POSITION_IDENTITY_VALIDATOR)
assert validator_spec is not None and validator_spec.loader is not None
position_identity_validator = importlib.util.module_from_spec(validator_spec)
sys.modules[validator_spec.name] = position_identity_validator
validator_spec.loader.exec_module(position_identity_validator)


def run_backend_server(state: object):
  server = qixi_backend.ThreadingHTTPServer(("127.0.0.1", 0), qixi_backend.QixiHandler, state)
  thread = threading.Thread(target=server.serve_forever, daemon=True)
  thread.start()
  return server, thread


def stop_backend_server(server: object, thread: threading.Thread, state: object) -> None:
  server.shutdown()
  server.server_close()
  state.shutdown()
  thread.join(timeout=2)


def post_raw_json(port: int, path: str, body: bytes, *, content_type: str | None = "application/json") -> dict[str, object]:
  headers = {}
  if content_type is not None:
    headers["Content-Type"] = content_type
  request = urllib.request.Request(
    f"http://127.0.0.1:{port}{path}",
    data=body,
    headers=headers,
    method="POST",
  )
  with urllib.request.urlopen(request, timeout=5) as response:
    return json.loads(response.read().decode("utf-8"))


def get_json(port: int, path: str) -> dict[str, object]:
  with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as response:
    return json.loads(response.read().decode("utf-8"))


def post_expect_error(port: int, path: str, body: bytes, *, content_type: str | None = "application/json") -> tuple[int, str]:
  headers = {}
  if content_type is not None:
    headers["Content-Type"] = content_type
  request = urllib.request.Request(
    f"http://127.0.0.1:{port}{path}",
    data=body,
    headers=headers,
    method="POST",
  )
  try:
    urllib.request.urlopen(request, timeout=5)
  except urllib.error.HTTPError as error:
    payload = json.loads(error.read().decode("utf-8"))
    return error.code, str(payload["error"])
  raise AssertionError("expected HTTPError")


def post_declared_length_expect_error(
  port: int,
  path: str,
  declared_length: int,
  *,
  content_type: str = "application/json",
) -> tuple[int, str]:
  connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
  try:
    connection.putrequest("POST", path)
    connection.putheader("Host", f"127.0.0.1:{port}")
    connection.putheader("Content-Type", content_type)
    connection.putheader("Content-Length", str(declared_length))
    connection.endheaders()
    response = connection.getresponse()
    payload = json.loads(response.read().decode("utf-8"))
    return response.status, str(payload["error"])
  finally:
    connection.close()


class BackendContractTests(unittest.TestCase):
  def test_ordered_history_key_distinguishes_same_stones(self) -> None:
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
    black_a = sorted((m["x"], m["y"]) for m in history_a if m["color"] == "B")
    black_b = sorted((m["x"], m["y"]) for m in history_b if m["color"] == "B")
    white_a = sorted((m["x"], m["y"]) for m in history_a if m["color"] == "W")
    white_b = sorted((m["x"], m["y"]) for m in history_b if m["color"] == "W")
    self.assertEqual(black_a, black_b)
    self.assertEqual(white_a, white_b)
    self.assertNotEqual(
      qixi_backend.position_key(history_a, "katago-metal-mux"),
      qixi_backend.position_key(history_b, "katago-metal-mux"),
    )

  def test_shared_position_identity_fixture_matches_backend_partition(self) -> None:
    fixture = position_identity_validator.validate_fixture(POSITION_IDENTITY_FIXTURE)
    self.assertEqual(fixture["schemaVersion"], 2)
    keys_by_id = {}
    final_stones_by_id = {}
    next_player_by_id = {}
    for case in fixture["cases"]:
      keys_by_id[case["id"]] = qixi_backend.position_key(
        case["moves"],
        case["backendEngine"],
        rules=case["rules"],
        komi=case["komi"],
        root_noise=case["rootNoise"],
      )
      final_stones_by_id[case["id"]] = qixi_backend.final_stones(case["moves"])
      next_player_by_id[case["id"]] = self.next_player_after(case["moves"])

    for relation in fixture["relations"]:
      with self.subTest(relation=relation["id"]):
        self.assertEqual(
          keys_by_id[relation["left"]] == keys_by_id[relation["right"]],
          relation["equal"],
          relation["reason"],
        )
        self.assertEqual(
          final_stones_by_id[relation["left"]] == final_stones_by_id[relation["right"]],
          relation["sameVisibleStones"],
          f"visible-stone relation drifted: {relation['reason']}",
        )
        self.assertEqual(
          next_player_by_id[relation["left"]] == next_player_by_id[relation["right"]],
          relation["sameNextPlayer"],
          f"next-player relation drifted: {relation['reason']}",
        )

  @staticmethod
  def next_player_after(moves: list[dict]) -> str:
    if not moves:
      return "B"
    return "W" if moves[-1]["color"] == "B" else "B"

  def test_pass_move_is_part_of_history(self) -> None:
    with_pass = [{"color": "B", "pass": True}, {"color": "W", "x": 3, "y": 3}]
    without_pass = [{"color": "W", "x": 3, "y": 3}]
    self.assertEqual(qixi_backend.move_to_gtp(with_pass[0]), "pass")
    self.assertNotEqual(
      qixi_backend.position_key(with_pass, "mock"),
      qixi_backend.position_key(without_pass, "mock"),
    )

  def test_repeated_coordinates_are_preserved_as_history(self) -> None:
    recapture_like_history = [
      {"color": "B", "x": 1, "y": 0},
      {"color": "W", "x": 0, "y": 0},
      {"color": "B", "x": 0, "y": 1},
      {"color": "W", "pass": True},
      {"color": "B", "x": 0, "y": 0},
    ]
    single_occupancy_history = [
      {"color": "B", "x": 1, "y": 0},
      {"color": "W", "pass": True},
      {"color": "B", "x": 0, "y": 1},
      {"color": "W", "pass": True},
      {"color": "B", "x": 0, "y": 0},
    ]
    normalized = qixi_backend.normalized_history(recapture_like_history)
    self.assertEqual([move["idx"] for move in normalized], [0, 1, 2, 3, 4])
    self.assertEqual(
      [(move["color"], move.get("x"), move.get("y")) for move in normalized],
      [("B", 1, 0), ("W", 0, 0), ("B", 0, 1), ("W", None, None), ("B", 0, 0)],
    )
    self.assertEqual(
      qixi_backend.final_stones(recapture_like_history),
      qixi_backend.final_stones(single_occupancy_history),
    )
    self.assertNotEqual(
      qixi_backend.position_key(recapture_like_history, "mock"),
      qixi_backend.position_key(single_occupancy_history, "mock"),
    )

  def test_board_replay_validates_capture_suicide_and_simple_ko(self) -> None:
    simple_capture = [
      {"color": "B", "x": 1, "y": 0},
      {"color": "W", "x": 0, "y": 0},
      {"color": "B", "x": 0, "y": 1},
    ]
    self.assertEqual(
      qixi_backend.final_stones(simple_capture),
      [{"color": "B", "x": 1, "y": 0}, {"color": "B", "x": 0, "y": 1}],
    )
    legal_reuse = simple_capture + [{"color": "W", "pass": True}, {"color": "B", "x": 0, "y": 0}]
    qixi_backend.validate_legal_history(legal_reuse)

    illegal_occupied = [
      {"color": "B", "x": 3, "y": 3},
      {"color": "W", "x": 4, "y": 3},
      {"color": "B", "x": 3, "y": 3},
    ]
    with self.assertRaisesRegex(qixi_backend.EngineError, "Move 2 is illegal"):
      qixi_backend.validate_legal_history(illegal_occupied)

    suicide = [
      {"color": "B", "x": 1, "y": 0},
      {"color": "B", "x": 0, "y": 1},
      {"color": "B", "x": 2, "y": 1},
      {"color": "B", "x": 1, "y": 2},
      {"color": "W", "x": 1, "y": 1},
    ]
    with self.assertRaisesRegex(qixi_backend.EngineError, "Move 4 is illegal"):
      qixi_backend.validate_legal_history(suicide)

    ko_after_capture = [
      {"color": "B", "x": 0, "y": 1},
      {"color": "B", "x": 1, "y": 0},
      {"color": "B", "x": 2, "y": 1},
      {"color": "W", "x": 1, "y": 1},
      {"color": "W", "x": 0, "y": 2},
      {"color": "W", "x": 2, "y": 2},
      {"color": "W", "x": 1, "y": 3},
      {"color": "B", "x": 1, "y": 2},
    ]
    with self.assertRaisesRegex(qixi_backend.EngineError, "Move 8 is illegal immediate ko recapture"):
      qixi_backend.validate_legal_history(ko_after_capture + [{"color": "W", "x": 1, "y": 1}])
    qixi_backend.validate_legal_history(ko_after_capture + [
      {"color": "W", "pass": True},
      {"color": "B", "pass": True},
    ])
    qixi_backend.validate_legal_history(ko_after_capture + [
      {"color": "W", "pass": True},
      {"color": "B", "pass": True},
      {"color": "W", "x": 1, "y": 1},
    ])
    qixi_backend.validate_legal_history(
      ko_after_capture + [
        {"color": "W", "pass": True},
        {"color": "B", "x": 3, "y": 3},
        {"color": "W", "x": 1, "y": 1},
      ]
    )

  def test_move_payload_validation_rejects_unambiguous_invalid_input(self) -> None:
    self.assertEqual(
      qixi_backend.normalized_moves([{"color": "w", "x": 3, "y": 3}, {"color": "B", "move": "pass"}]),
      [{"color": "W", "x": 3, "y": 3}, {"color": "B", "pass": True}],
    )
    invalid_payloads = [
      [{"x": 3, "y": 3}],
      [{"color": "C", "x": 3, "y": 3}],
      [{"color": "B", "x": -1, "y": 3}],
      [{"color": "B", "x": 19, "y": 3}],
      [{"color": "B", "x": 3.5, "y": 3}],
      [{"color": "B", "x": True, "y": 3}],
      [{"color": "W", "pass": True, "x": 3, "y": 3}],
      [{"color": "W", "move": "D16"}],
    ]
    for payload in invalid_payloads:
      with self.subTest(payload=payload):
        with self.assertRaises(qixi_backend.EngineError):
          qixi_backend.normalized_moves(payload)
    with self.assertRaises(qixi_backend.EngineError):
      qixi_backend.normalized_moves({"color": "B", "x": 3, "y": 3})

  def test_position_keys_include_komi_and_root_noise(self) -> None:
    history = [{"color": "B", "x": 3, "y": 3}]
    self.assertNotEqual(
      qixi_backend.position_key(history, "mock", komi=7.5),
      qixi_backend.position_key(history, "mock", komi=6.5),
    )
    self.assertNotEqual(
      qixi_backend.position_key(history, "mock", root_noise=0.0),
      qixi_backend.position_key(history, "mock", root_noise=0.04),
    )

  def test_analysis_context_validates_request_settings(self) -> None:
    context = qixi_backend.analysis_context({"rules": "Chinese", "komi": 6.5, "rootNoise": 0.04})
    self.assertEqual(context.rules, "Chinese")
    self.assertEqual(context.komi, 6.5)
    self.assertEqual(context.root_noise, 0.04)
    with self.assertRaises(qixi_backend.EngineError):
      qixi_backend.analysis_context({"komi": 200.0})
    with self.assertRaises(qixi_backend.EngineError):
      qixi_backend.analysis_context({"rootNoise": -0.01})

  def test_mock_engine_contract(self) -> None:
    engine = qixi_backend.DeterministicMockEngine()
    result = engine.analyze(
      [{"color": "B", "x": 3, "y": 15}, {"color": "W", "x": 15, "y": 3}],
      64,
      qixi_backend.AnalysisContext(),
    )
    self.assertEqual(result["engine"], "mock")
    self.assertEqual(len(result["ownership"]), 19 * 19)
    self.assertGreater(len(result["moves"]), 0)
    self.assertIn("positionKey", result)
    self.assertIn("scoreMean", result["moves"][0])

  def test_mock_engine_handles_pass_moves_and_request_settings(self) -> None:
    engine = qixi_backend.DeterministicMockEngine()
    history = [{"color": "B", "pass": True}, {"color": "W", "x": 3, "y": 3}]
    default_result = engine.analyze(history, 64, qixi_backend.AnalysisContext())
    changed_result = engine.analyze(history, 64, qixi_backend.AnalysisContext(komi=6.5, root_noise=0.04))
    self.assertEqual(default_result["engine"], "mock")
    self.assertEqual(len(default_result["ownership"]), 19 * 19)
    self.assertNotEqual(default_result["positionKey"], changed_result["positionKey"])
    self.assertNotEqual(default_result["scoreMean"], changed_result["scoreMean"])

  def test_app_state_analyze_threads_settings_into_position_key(self) -> None:
    state = qixi_backend.AppState()
    state.set_engine("mock")
    history = [{"color": "B", "x": 3, "y": 3}]
    result_a = state.analyze({"moves": history, "maxVisits": 8, "komi": 7.5, "rootNoise": 0.0})
    result_b = state.analyze({"moves": history, "maxVisits": 8, "komi": 6.5, "rootNoise": 0.04})
    self.assertEqual(
      result_a["positionKey"],
      qixi_backend.position_key(history, "mock", komi=7.5, root_noise=0.0),
    )
    self.assertEqual(
      result_b["positionKey"],
      qixi_backend.position_key(history, "mock", komi=6.5, root_noise=0.04),
    )
    self.assertNotEqual(result_a["positionKey"], result_b["positionKey"])

  def test_app_state_rejects_invalid_moves_before_analysis(self) -> None:
    state = qixi_backend.AppState()
    state.set_engine("mock")
    with self.assertRaises(qixi_backend.EngineError):
      state.analyze({"moves": [{"color": "B", "x": 20, "y": 3}], "maxVisits": 8})
    with self.assertRaises(qixi_backend.EngineError):
      state.analyze({"moves": {"color": "B", "x": 3, "y": 3}, "maxVisits": 8})
    with self.assertRaisesRegex(qixi_backend.EngineError, "Move 2 is illegal"):
      state.analyze({
        "moves": [
          {"color": "B", "x": 3, "y": 3},
          {"color": "W", "x": 4, "y": 3},
          {"color": "B", "x": 3, "y": 3},
        ],
        "maxVisits": 8,
      })

  def test_http_invalid_analysis_returns_400(self) -> None:
    state = qixi_backend.AppState()
    state.set_engine("mock")
    server, thread = run_backend_server(state)
    try:
      port = server.server_address[1]
      request = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/analyze",
        data=json.dumps({"moves": [{"color": "B", "x": 20, "y": 3}], "maxVisits": 8}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
      )
      with self.assertRaises(urllib.error.HTTPError) as error:
        urllib.request.urlopen(request, timeout=5)
      self.assertEqual(error.exception.code, 400)
      payload = json.loads(error.exception.read().decode("utf-8"))
      self.assertIn("coordinates out of range", payload["error"])

      illegal_request = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/analyze",
        data=json.dumps({
          "moves": [
            {"color": "B", "x": 3, "y": 3},
            {"color": "W", "x": 4, "y": 3},
            {"color": "B", "x": 3, "y": 3},
          ],
          "maxVisits": 8,
        }).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
      )
      with self.assertRaises(urllib.error.HTTPError) as illegal_error:
        urllib.request.urlopen(illegal_request, timeout=5)
      self.assertEqual(illegal_error.exception.code, 400)
      illegal_payload = json.loads(illegal_error.exception.read().decode("utf-8"))
      self.assertIn("Move 2 is illegal", illegal_payload["error"])
    finally:
      stop_backend_server(server, thread, state)

  def test_http_events_endpoint_records_engine_and_analysis_summaries(self) -> None:
    state = qixi_backend.AppState()
    server, thread = run_backend_server(state)
    try:
      port = server.server_address[1]
      initial = get_json(port, "/api/events")
      self.assertEqual(initial["schemaVersion"], 1)
      self.assertEqual(initial["count"], 0)
      self.assertEqual(initial["events"], [])

      engine_response = post_raw_json(port, "/api/engine", b'{"engine":"mock"}')
      self.assertEqual(engine_response["engineId"], "mock")
      analysis_response = post_raw_json(
        port,
        "/api/analyze",
        b'{"moves":[{"color":"B","x":3,"y":3}],"maxVisits":8}',
      )
      self.assertEqual(analysis_response["engine"], "mock")

      events = get_json(port, "/api/events")
      self.assertEqual(events["count"], 2)
      self.assertEqual(events["latestSequence"], 2)
      self.assertEqual(
        [(event["sequence"], event["kind"], event["path"]) for event in events["events"]],
        [(1, "engine", "/api/engine"), (2, "analyze", "/api/analyze")],
      )
      self.assertEqual(events["events"][0]["engine"], "mock")
      self.assertEqual(events["events"][1]["engine"], "mock")
      self.assertEqual(events["events"][1]["moveCount"], 1)
      self.assertEqual(events["events"][1]["maxVisits"], 8)
      self.assertNotIn("moves", events["events"][1])
    finally:
      stop_backend_server(server, thread, state)

  def test_http_post_json_parser_rejects_ambiguous_or_non_standard_requests(self) -> None:
    state = qixi_backend.AppState()
    state.set_engine("mock")
    server, thread = run_backend_server(state)
    try:
      port = server.server_address[1]
      duplicate_key = b'{"moves":[],"maxVisits":8,"maxVisits":999}'
      code, message = post_expect_error(port, "/api/analyze", duplicate_key)
      self.assertEqual(code, 400)
      self.assertIn("duplicate JSON key 'maxVisits'", message)

      non_standard_number = b'{"moves":[],"maxVisits":NaN}'
      code, message = post_expect_error(port, "/api/analyze", non_standard_number)
      self.assertEqual(code, 400)
      self.assertIn("non-standard JSON constant NaN", message)

      top_level_array = b'[]'
      code, message = post_expect_error(port, "/api/analyze", top_level_array)
      self.assertEqual(code, 400)
      self.assertIn("request JSON must be a JSON object", message)
    finally:
      stop_backend_server(server, thread, state)

  def test_http_post_json_parser_rejects_wrong_content_type_and_oversized_body(self) -> None:
    state = qixi_backend.AppState()
    state.set_engine("mock")
    server, thread = run_backend_server(state)
    try:
      port = server.server_address[1]
      valid_body = b'{"moves":[],"maxVisits":8}'
      code, message = post_expect_error(port, "/api/analyze", valid_body, content_type="text/plain")
      self.assertEqual(code, 400)
      self.assertIn("POST request must use application/json", message)

      self.assertIn("positionKey", post_raw_json(
        port,
        "/api/analyze",
        valid_body,
        content_type="application/json; charset=utf-8",
      ))

      code, message = post_declared_length_expect_error(
        port,
        "/api/analyze",
        qixi_backend.MAX_REQUEST_BYTES + 1,
      )
      self.assertEqual(code, 400)
      self.assertIn("request body exceeds", message)
    finally:
      stop_backend_server(server, thread, state)

  def test_katago_stdout_json_parser_rejects_ambiguous_or_non_standard_responses(self) -> None:
    class FakeProcess:
      def __init__(self, line: str) -> None:
        self.stdin = io.StringIO()
        self.stdout = io.StringIO(line)
        self.stderr = io.StringIO()
        self.returncode = None

      def poll(self) -> None:
        return None

    original_time_ns = qixi_backend.time.time_ns
    qixi_backend.time.time_ns = lambda: 123
    try:
      for line, expected in (
        (
          '{"id":"qixi-123","id":"qixi-123","rootInfo":{},"moveInfos":[]}\n',
          "KataGo analysis response must not contain duplicate JSON key 'id'",
        ),
        (
          '{"id":"qixi-123","rootInfo":{"winrate":NaN},"moveInfos":[]}\n',
          "KataGo analysis response must not contain non-standard JSON constant NaN",
        ),
        (
          '[{"id":"qixi-123"}]\n',
          "KataGo analysis response must be a JSON object",
        ),
      ):
        engine = object.__new__(qixi_backend.KataGoAnalysisEngine)
        engine.engine_id = "b6"
        engine.name = "katago-metal-mux:b6"
        engine.model = pathlib.Path("/tmp/fake-b6.bin")
        engine._lock = threading.Lock()
        engine._process = FakeProcess(line)
        with self.subTest(expected=expected):
          with self.assertRaisesRegex(qixi_backend.EngineError, expected):
            engine.analyze([], 2, qixi_backend.AnalysisContext())
    finally:
      qixi_backend.time.time_ns = original_time_ns

  def test_katago_query_payload_threads_komi_and_wide_root_noise(self) -> None:
    history = [{"color": "B", "pass": True}, {"color": "W", "x": 3, "y": 3}]
    context = qixi_backend.AnalysisContext(rules="Chinese", komi=6.5, root_noise=0.04)
    query = qixi_backend.KataGoAnalysisEngine.query_payload("qixi-test", history, 32, context)
    self.assertEqual(query["id"], "qixi-test")
    self.assertEqual(query["moves"], [["B", "pass"], ["W", "D16"]])
    self.assertEqual(query["rules"], "Chinese")
    self.assertEqual(query["komi"], 6.5)
    self.assertEqual(query["maxVisits"], 32)
    self.assertEqual(query["overrideSettings"]["wideRootNoise"], 0.04)

    default_query = qixi_backend.KataGoAnalysisEngine.query_payload(
      "qixi-default",
      history,
      32,
      qixi_backend.AnalysisContext(),
    )
    self.assertNotIn("overrideSettings", default_query)
    with self.assertRaisesRegex(qixi_backend.EngineError, "Move 2 is illegal"):
      qixi_backend.KataGoAnalysisEngine.query_payload(
        "qixi-illegal",
        [
          {"color": "B", "x": 3, "y": 3},
          {"color": "W", "x": 4, "y": 3},
          {"color": "B", "x": 3, "y": 3},
        ],
        32,
        context,
      )

  def test_default_katago_binary_prefers_metal_mux_build(self) -> None:
    if qixi_backend.DEFAULT_METAL_KATAGO_BIN.exists():
      self.assertEqual(qixi_backend.DEFAULT_KATAGO_BIN, qixi_backend.DEFAULT_METAL_KATAGO_BIN)

  def test_default_project_models_are_discovered(self) -> None:
    # b6 ships as a KataGo upstream test net (present after submodule checkout).
    self.assertTrue(qixi_backend.DEFAULT_B6_MODEL.exists())
    # b18/b28 are large local nets (gitignored); only path wiring is required for CI.
    self.assertEqual(qixi_backend.DEFAULT_B18_MODEL.name, "b18nbt.bin")
    self.assertEqual(qixi_backend.DEFAULT_B28_MODEL.name, "b28nbt.bin")
    self.assertEqual(qixi_backend.ENGINE_MODEL_DEFAULTS["b18nbt"], qixi_backend.DEFAULT_B18_MODEL)
    self.assertEqual(qixi_backend.ENGINE_MODEL_DEFAULTS["b28nbt"], qixi_backend.DEFAULT_B28_MODEL)
    self.assertEqual(qixi_backend.ENGINE_MODEL_DEFAULTS["b6"], qixi_backend.DEFAULT_B6_MODEL)

  def test_position_keys_include_model_identity(self) -> None:
    history = [{"color": "B", "x": 3, "y": 3}]
    self.assertNotEqual(
      qixi_backend.position_key(history, "katago-metal-mux:b6"),
      qixi_backend.position_key(history, "katago-metal-mux:b18nbt"),
    )
    self.assertNotEqual(
      qixi_backend.position_key(history, "katago-metal-mux:b18nbt"),
      qixi_backend.position_key(history, "katago-metal-mux:b28nbt"),
    )


if __name__ == "__main__":
  unittest.main()
