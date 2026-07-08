#!/usr/bin/env python3
from __future__ import annotations

import copy
import datetime
import importlib.util
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSPECTOR = ROOT / "tests" / "inspect_real_model_integration_artifact.py"

spec = importlib.util.spec_from_file_location("inspect_real_model_integration_artifact", INSPECTOR)
assert spec is not None and spec.loader is not None
inspector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspector)


def utc_now() -> str:
  return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def stale_timestamp() -> str:
  return "2000-01-01T00:00:00Z"


def key(seed: int) -> str:
  return f"{seed:064x}"


class RealModelArtifactInspectorTests(unittest.TestCase):
  def use_repo_root(self, directory: pathlib.Path) -> None:
    previous_repo_root = inspector.REPO_ROOT
    inspector.REPO_ROOT = directory
    self.addCleanup(lambda: setattr(inspector, "REPO_ROOT", previous_repo_root))

  def build_artifact(self, directory: pathlib.Path) -> tuple[pathlib.Path, dict]:
    katago = directory / "katago"
    config = directory / "analysis.cfg"
    katago.write_bytes(b"fake-katago-binary")
    config.write_text("rules = Chinese\n", encoding="utf-8")
    models = {
      "b6": directory / "b6.bin.gz",
      "b18nbt": directory / "b18nbt.bin",
      "b28nbt": directory / "b28nbt.bin",
    }
    for engine_id, model in models.items():
      model.write_bytes((engine_id * 13).encode("utf-8"))

    artifact = {
      "schemaVersion": 1,
      "kind": "qixi-real-model-metal-mux-integration",
      "generatedAt": utc_now(),
      "katagoBinary": str(katago),
      "katagoBinaryByteCount": katago.stat().st_size,
      "configPath": str(config),
      "overrideSha256": "a" * 64,
      "historyLength": 2,
      "maxVisits": 8,
      "positionKeysUnique": True,
      "caseDefinitions": [
        {
          "caseId": "opening",
          "historyLength": 2,
          "finalStoneCount": 2,
          "finalStoneDigest": "b" * 64,
          "komi": 7.5,
          "rootNoise": 0.0,
        },
        {
          "caseId": "same-stones-history-a",
          "historyLength": 4,
          "finalStoneCount": 4,
          "finalStoneDigest": "c" * 64,
          "komi": 7.5,
          "rootNoise": 0.0,
        },
        {
          "caseId": "same-stones-history-b",
          "historyLength": 4,
          "finalStoneCount": 4,
          "finalStoneDigest": "c" * 64,
          "komi": 7.5,
          "rootNoise": 0.0,
        },
      ],
      "engines": [],
      "offEngineChecks": [],
      "sameVisibleDifferentHistoryChecks": [],
    }
    for index, engine_id in enumerate(("b6", "b18nbt", "b28nbt"), start=1):
      analysis_cases = []
      for case_index, case_id in enumerate(("opening", "same-stones-history-a", "same-stones-history-b"), start=1):
        analysis_cases.append(
          {
            "caseId": case_id,
            "engineId": engine_id,
            "engine": f"katago-metal-mux:{engine_id}",
            "positionKey": key(index * 10 + case_index),
            "historyLength": 2 if case_id == "opening" else 4,
            "komi": 7.5,
            "rootNoise": 0.0,
            "maxVisits": 8,
            "rootVisits": 8,
            "candidateCount": 2,
            "ownershipPointCount": 361,
            "ownershipMin": -0.5,
            "ownershipMax": 0.5,
            "winrate": 0.5,
            "scoreMean": 0.0,
            "bestMove": {
              "move": "D16",
              "x": 3,
              "y": 3,
              "visits": 1,
              "winrate": 0.5,
              "scoreMean": 0.0,
            },
            "analysisElapsedMs": 10.0,
          }
        )
      artifact["engines"].append(
        {
          **analysis_cases[0],
          "engineId": engine_id,
          "engine": f"katago-metal-mux:{engine_id}",
          "modelPath": str(models[engine_id]),
          "modelByteCount": models[engine_id].stat().st_size,
          "positionKey": analysis_cases[0]["positionKey"],
          "statusRunning": True,
          "statusPaused": False,
          "statusElapsedMs": 1.0,
          "analysisCases": analysis_cases,
        }
      )
      artifact["sameVisibleDifferentHistoryChecks"].append(
        {
          "engineId": engine_id,
          "caseA": "same-stones-history-a",
          "caseB": "same-stones-history-b",
          "finalStonesEqual": True,
          "positionKeysDistinct": True,
          "positionKeyA": analysis_cases[1]["positionKey"],
          "positionKeyB": analysis_cases[2]["positionKey"],
          "finalStoneDigest": "c" * 64,
        }
      )
      artifact["offEngineChecks"].append(
        {
          "afterEngineId": engine_id,
          "positionKey": key(100),
          "movesCount": 0,
          "ownershipPointCount": 0,
          "running": False,
          "paused": False,
        }
      )

    path = directory / "artifact.json"
    path.write_text(json.dumps(artifact, allow_nan=True, sort_keys=True), encoding="utf-8")
    return path, artifact

  def write_variant(self, directory: pathlib.Path, artifact: dict) -> pathlib.Path:
    path = directory / "variant.json"
    path.write_text(json.dumps(artifact, allow_nan=True, sort_keys=True), encoding="utf-8")
    return path

  def symlink_or_skip(self, source: pathlib.Path, link: pathlib.Path) -> None:
    try:
      link.symlink_to(source)
    except (OSError, NotImplementedError) as exc:
      self.skipTest(f"symlink creation is unavailable: {exc}")

  def test_valid_artifact_passes(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      directory = pathlib.Path(tmpdir)
      self.use_repo_root(directory)
      path, _ = self.build_artifact(directory)
      payload = inspector.validate_artifact(path)
      self.assertEqual(payload["kind"], "qixi-real-model-metal-mux-integration")
      self.assertEqual([entry["engineId"] for entry in payload["engines"]], ["b6", "b18nbt", "b28nbt"])

  def test_rejects_negative_artifact_cases(self) -> None:
    cases = [
      (
        "stale",
        lambda payload: payload.__setitem__("generatedAt", stale_timestamp()),
        "stale",
      ),
      (
        "too-few-visits",
        lambda payload: payload.__setitem__("maxVisits", 2),
        "maxVisits must be at least 8",
      ),
      (
        "missing-engine",
        lambda payload: payload["engines"].pop(),
        "engines must contain exactly 3 entries",
      ),
      (
        "missing-case-definition",
        lambda payload: payload["caseDefinitions"].pop(),
        "caseDefinitions must contain exactly 3 entries",
      ),
      (
        "missing-analysis-case",
        lambda payload: payload["engines"][0]["analysisCases"].pop(),
        "analysisCases must contain exactly 3 entries",
      ),
      (
        "model-byte-count",
        lambda payload: payload["engines"][0].__setitem__("modelByteCount", 999999),
        "modelByteCount does not match modelPath size",
      ),
      (
        "ownership-count",
        lambda payload: payload["engines"][1].__setitem__("ownershipPointCount", 360),
        "ownershipPointCount must be 361",
      ),
      (
        "duplicate-real-position-key",
        lambda payload: [
          payload["engines"][2].__setitem__("positionKey", payload["engines"][0]["positionKey"]),
          payload["engines"][2]["analysisCases"][0].__setitem__(
            "positionKey",
            payload["engines"][0]["positionKey"],
          ),
        ],
        "engine position keys must be unique",
      ),
      (
        "same-visible-history-collapsed",
        lambda payload: payload["sameVisibleDifferentHistoryChecks"][0].__setitem__("positionKeysDistinct", False),
        "positionKeysDistinct must be true",
      ),
      (
        "off-engine-leaks-real-key",
        lambda payload: [
          check.__setitem__("positionKey", payload["engines"][0]["positionKey"])
          for check in payload["offEngineChecks"]
        ],
        "off-engine position key must not equal a real-model position key",
      ),
      (
        "non-finite-winrate",
        lambda payload: payload["engines"][0].__setitem__("winrate", float("nan")),
        "non-standard JSON constant NaN",
      ),
      (
        "bad-best-move-coordinate",
        lambda payload: payload["engines"][0]["bestMove"].__setitem__("x", 19),
        "coordinates must be on a 19x19 board",
      ),
    ]
    for case_name, mutate, expected_error in cases:
      with self.subTest(case=case_name):
        with tempfile.TemporaryDirectory() as tmpdir:
          directory = pathlib.Path(tmpdir)
          self.use_repo_root(directory)
          _, artifact = self.build_artifact(directory)
          variant = copy.deepcopy(artifact)
          mutate(variant)
          path = self.write_variant(directory, variant)
          with self.assertRaisesRegex(inspector.RealModelArtifactError, expected_error):
            inspector.validate_artifact(path)

  def test_rejects_ambiguous_or_non_standard_json(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      directory = pathlib.Path(tmpdir)
      self.use_repo_root(directory)
      path = directory / "duplicate-key.json"
      path.write_text(
        '{"schemaVersion":1,"schemaVersion":1,"kind":"qixi-real-model-metal-mux-integration"}\n',
        encoding="utf-8",
      )
      with self.assertRaisesRegex(inspector.RealModelArtifactError, "duplicate JSON key 'schemaVersion'"):
        inspector.validate_artifact(path)

    with tempfile.TemporaryDirectory() as tmpdir:
      directory = pathlib.Path(tmpdir)
      self.use_repo_root(directory)
      path = directory / "non-standard-number.json"
      path.write_text(
        '{"schemaVersion":1,"kind":"qixi-real-model-metal-mux-integration","generatedAt":NaN}\n',
        encoding="utf-8",
      )
      with self.assertRaisesRegex(inspector.RealModelArtifactError, "non-standard JSON constant NaN"):
        inspector.validate_artifact(path)

  def test_rejects_symbolic_link_artifact_and_model_paths(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      directory = pathlib.Path(tmpdir)
      self.use_repo_root(directory)
      path, artifact = self.build_artifact(directory)
      linked_artifact = directory / "linked-artifact.json"
      self.symlink_or_skip(path, linked_artifact)
      with self.assertRaisesRegex(inspector.RealModelArtifactError, "symbolic links"):
        inspector.validate_artifact(linked_artifact)

      model_target = pathlib.Path(artifact["engines"][0]["modelPath"])
      linked_model = directory / "linked-b6.bin.gz"
      self.symlink_or_skip(model_target, linked_model)
      artifact["engines"][0]["modelPath"] = str(linked_model)
      artifact["engines"][0]["modelByteCount"] = model_target.stat().st_size
      variant = self.write_variant(directory, artifact)
      with self.assertRaisesRegex(inspector.RealModelArtifactError, "symbolic links"):
        inspector.validate_artifact(variant)

  def test_rejects_oversized_artifact_before_json_decode(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      directory = pathlib.Path(tmpdir)
      self.use_repo_root(directory)
      path = directory / "oversized-artifact.json"
      path.write_bytes(b"{" + (b" " * inspector.MAX_ARTIFACT_BYTES) + b"}")
      with self.assertRaisesRegex(inspector.RealModelArtifactError, "exceeds bounded size"):
        inspector.validate_artifact(path)

  def test_rejects_artifacts_older_than_current_gate_marker(self) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
      directory = pathlib.Path(tmpdir)
      self.use_repo_root(directory)
      path, _ = self.build_artifact(directory)
      minimum_mtime = path.stat().st_mtime + 10.0

      with mock.patch.dict(
        os.environ,
        {"QIXI_REAL_MODEL_ARTIFACT_MIN_MTIME_EPOCH": str(minimum_mtime)},
      ):
        with self.assertRaisesRegex(inspector.RealModelArtifactError, "stale for this run"):
          inspector.validate_artifact(path)

  def test_rejects_artifacts_that_reference_files_outside_repository_root(self) -> None:
    with tempfile.TemporaryDirectory() as repo_tmpdir, tempfile.TemporaryDirectory() as outside_tmpdir:
      repository = pathlib.Path(repo_tmpdir)
      outside = pathlib.Path(outside_tmpdir)
      self.use_repo_root(repository)
      path, artifact = self.build_artifact(repository)
      outside_model = outside / "outside-b6.bin.gz"
      outside_model.write_bytes(b"outside-model")
      artifact["engines"][0]["modelPath"] = str(outside_model)
      artifact["engines"][0]["modelByteCount"] = outside_model.stat().st_size
      variant = self.write_variant(repository, artifact)

      with self.assertRaisesRegex(inspector.RealModelArtifactError, "repository root"):
        inspector.validate_artifact(variant)


if __name__ == "__main__":
  unittest.main()
