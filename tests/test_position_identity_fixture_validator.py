#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "position_identity_cases.json"
VALIDATOR = ROOT / "tests" / "validate_position_identity_fixture.py"

spec = importlib.util.spec_from_file_location("validate_position_identity_fixture", VALIDATOR)
assert spec is not None and spec.loader is not None
validator = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = validator
spec.loader.exec_module(validator)


def real_fixture_payload() -> dict:
  return validator.load_strict_json(FIXTURE)


def write_fixture(directory: pathlib.Path, payload: dict) -> pathlib.Path:
  path = directory / "position_identity_cases.json"
  path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
  return path


def write_sparse_file(path: pathlib.Path, byte_count: int) -> None:
  with path.open("wb") as handle:
    handle.seek(byte_count - 1)
    handle.write(b"\0")


class PositionIdentityFixtureValidatorTests(unittest.TestCase):
  def test_real_fixture_validates_and_pins_critical_relations(self) -> None:
    fixture = validator.validate_fixture(FIXTURE)
    summary = fixture["_summary"]
    self.assertEqual(summary.case_count, 14)
    self.assertEqual(summary.relation_count, 9)
    self.assertGreaterEqual(summary.same_visible_different_identity_count, 5)
    relation_ids = {relation["id"] for relation in fixture["relations"]}
    self.assertTrue(validator.REQUIRED_RELATION_IDS.issubset(relation_ids))
    validator_source = VALIDATOR.read_text(encoding="utf-8")
    for token in (
      "final_visible_stones",
      "must not play on an occupied point",
      "must not be suicide",
      "must not immediately recapture a simple ko",
      "sameVisibleStones does not match replayed final stones",
      "sameNextPlayer does not match replayed next player",
      "FIXTURE_MAX_BYTES",
      "reject_symlink_components",
      "opened_regular_file_stat",
      "os.fstat(handle.fileno())",
      "stat_module.S_ISREG",
      "handle.read(FIXTURE_MAX_BYTES + 1)",
      "opened-byte-count drift while reading fixture",
    ):
      self.assertIn(token, validator_source)
    self.assertNotIn('path.read_text(encoding="utf-8")', validator_source)

  def test_fixture_path_must_not_be_symbolic_link(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      directory = pathlib.Path(temp_dir)
      target = write_fixture(directory, real_fixture_payload())
      link = directory / "linked-position-identity.json"
      try:
        link.symlink_to(target)
      except OSError as exc:
        self.skipTest(f"symlink creation is unavailable: {exc}")

      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "symbolic links"):
        validator.validate_fixture(link)

  def test_fixture_path_must_be_regular_file_before_opening(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "regular file"):
        validator.validate_fixture(pathlib.Path(temp_dir))

  def test_oversized_fixture_is_rejected_before_json_parse(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      path = pathlib.Path(temp_dir) / "oversized.json"
      write_sparse_file(path, validator.FIXTURE_MAX_BYTES + 1)

      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "too large"):
        validator.validate_fixture(path)

  def test_fixture_reader_rechecks_opened_descriptor_is_regular(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      fd = os.open(temp_dir, os.O_RDONLY)
      try:
        class DirectoryHandle:
          def fileno(self) -> int:
            return fd

        with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "regular file after opening"):
          validator.opened_regular_file_stat(DirectoryHandle(), pathlib.Path(temp_dir))
      finally:
        os.close(fd)

  def test_fixture_reader_rejects_invalid_utf8_before_json_parse(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      path = pathlib.Path(temp_dir) / "bad.json"
      path.write_bytes(b"\xff\xfe\xfd")

      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "valid UTF-8"):
        validator.validate_fixture(path)

  def test_duplicate_json_keys_are_rejected_before_schema_validation(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      path = pathlib.Path(temp_dir) / "bad.json"
      path.write_text(
        '{"schemaVersion":1,"schemaVersion":1,"cases":[],"relations":[]}',
        encoding="utf-8",
      )

      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "duplicate JSON object key"):
        validator.validate_fixture(path)

  def test_non_standard_json_constants_are_rejected(self) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
      path = pathlib.Path(temp_dir) / "bad.json"
      path.write_text(
        '{"schemaVersion":NaN,"cases":[],"relations":[]}',
        encoding="utf-8",
      )

      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "non-standard JSON numeric constant"):
        validator.validate_fixture(path)

  def test_unknown_relation_reference_is_rejected(self) -> None:
    payload = copy.deepcopy(real_fixture_payload())
    payload["relations"][0]["right"] = "missing-case"

    with tempfile.TemporaryDirectory() as temp_dir:
      path = write_fixture(pathlib.Path(temp_dir), payload)
      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "references unknown case"):
        validator.validate_fixture(path)

  def test_pass_move_with_coordinates_is_rejected(self) -> None:
    payload = copy.deepcopy(real_fixture_payload())
    payload["cases"][0]["moves"][0] = {"color": "B", "pass": True, "x": 3, "y": 3}

    with tempfile.TemporaryDirectory() as temp_dir:
      path = write_fixture(pathlib.Path(temp_dir), payload)
      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "keys must be"):
        validator.validate_fixture(path)

  def test_missing_same_stones_history_relation_is_rejected(self) -> None:
    payload = copy.deepcopy(real_fixture_payload())
    payload["relations"] = [
      relation for relation in payload["relations"]
      if relation["id"] != "same-stones-different-order"
    ]

    with tempfile.TemporaryDirectory() as temp_dir:
      path = write_fixture(pathlib.Path(temp_dir), payload)
      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "missing required relation ids"):
        validator.validate_fixture(path)

  def test_same_visible_stones_claim_must_match_replayed_board(self) -> None:
    payload = copy.deepcopy(real_fixture_payload())
    for relation in payload["relations"]:
      if relation["id"] == "same-stones-different-order":
        relation["sameVisibleStones"] = False
        break

    with tempfile.TemporaryDirectory() as temp_dir:
      path = write_fixture(pathlib.Path(temp_dir), payload)
      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "sameVisibleStones does not match"):
        validator.validate_fixture(path)

  def test_same_next_player_claim_must_match_replayed_history(self) -> None:
    payload = copy.deepcopy(real_fixture_payload())
    for relation in payload["relations"]:
      if relation["id"] == "ko-history-after-passes":
        relation["sameNextPlayer"] = False
        break

    with tempfile.TemporaryDirectory() as temp_dir:
      path = write_fixture(pathlib.Path(temp_dir), payload)
      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "sameNextPlayer does not match"):
        validator.validate_fixture(path)

  def test_illegal_occupied_point_history_is_rejected(self) -> None:
    payload = copy.deepcopy(real_fixture_payload())
    payload["cases"][0]["moves"] = [
      {"color": "B", "x": 3, "y": 3},
      {"color": "W", "x": 3, "y": 3},
    ]

    with tempfile.TemporaryDirectory() as temp_dir:
      path = write_fixture(pathlib.Path(temp_dir), payload)
      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "occupied point"):
        validator.validate_fixture(path)

  def test_illegal_suicide_history_is_rejected(self) -> None:
    payload = copy.deepcopy(real_fixture_payload())
    payload["cases"][0]["moves"] = [
      {"color": "B", "x": 0, "y": 1},
      {"color": "W", "pass": True},
      {"color": "B", "x": 1, "y": 0},
      {"color": "W", "pass": True},
      {"color": "B", "x": 2, "y": 1},
      {"color": "W", "pass": True},
      {"color": "B", "x": 1, "y": 2},
      {"color": "W", "x": 1, "y": 1},
    ]

    with tempfile.TemporaryDirectory() as temp_dir:
      path = write_fixture(pathlib.Path(temp_dir), payload)
      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "suicide"):
        validator.validate_fixture(path)

  def test_consecutive_passes_are_legal_history(self) -> None:
    payload = copy.deepcopy(real_fixture_payload())
    payload["cases"].append({
      "id": "two-pass-history",
      "engine": "none",
      "backendEngine": "none",
      "rules": "Chinese",
      "komi": 7.5,
      "rootNoise": 0.0,
      "moves": [
        {"color": "B", "pass": True},
        {"color": "W", "pass": True},
      ],
    })

    with tempfile.TemporaryDirectory() as temp_dir:
      path = write_fixture(pathlib.Path(temp_dir), payload)
      fixture = validator.validate_fixture(path)
      self.assertEqual(fixture["_summary"].case_count, 15)

  def test_illegal_immediate_ko_recapture_history_is_rejected(self) -> None:
    payload = copy.deepcopy(real_fixture_payload())
    payload["cases"][0]["moves"] = [
      {"color": "B", "x": 0, "y": 1},
      {"color": "B", "x": 1, "y": 0},
      {"color": "B", "x": 2, "y": 1},
      {"color": "W", "x": 1, "y": 1},
      {"color": "W", "x": 0, "y": 2},
      {"color": "W", "x": 2, "y": 2},
      {"color": "W", "x": 1, "y": 3},
      {"color": "B", "x": 1, "y": 2},
      {"color": "W", "x": 1, "y": 1},
    ]

    with tempfile.TemporaryDirectory() as temp_dir:
      path = write_fixture(pathlib.Path(temp_dir), payload)
      with self.assertRaisesRegex(validator.PositionIdentityFixtureError, "simple ko"):
        validator.validate_fixture(path)


if __name__ == "__main__":
  unittest.main()
