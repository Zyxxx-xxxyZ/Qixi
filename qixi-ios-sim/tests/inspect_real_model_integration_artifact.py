#!/usr/bin/env python3
from __future__ import annotations

import datetime
import json
import math
import os
import pathlib
import re
import sys
import stat as stat_module
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent
DEFAULT_ARTIFACT = ROOT / "artifacts" / "real-models" / "latest-real-model-integration.json"
EXPECTED_ENGINES = ("b6", "b18nbt", "b28nbt")
EXPECTED_CASE_IDS = ("opening", "same-stones-history-a", "same-stones-history-b")
EXPECTED_KIND = "qixi-real-model-metal-mux-integration"
MIN_REAL_MODEL_MAX_VISITS = 8
POSITION_KEY_RE = re.compile(r"^[0-9a-f]{64}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
DEFAULT_MAX_AGE_SECONDS = 2 * 60 * 60
MAX_ARTIFACT_BYTES = 256 * 1024
ALLOWED_PLATFORM_SYMLINK_ALIASES = {
  pathlib.Path("/var"): pathlib.Path("/private/var"),
  pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
  pathlib.Path("/etc"): pathlib.Path("/private/etc"),
}


class RealModelArtifactError(RuntimeError):
  pass


def fail(message: str) -> None:
  raise RealModelArtifactError(message)


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
  candidate_path = normalized_path(path)
  candidates = list(reversed(candidate_path.parents)) + [candidate_path]
  for candidate in candidates:
    if candidate == candidate.parent:
      continue
    if candidate.is_symlink() and not is_allowed_platform_symlink_alias(candidate):
      fail(f"{label} must not contain symbolic links: {candidate}")
  return candidate_path


def repository_path(path: pathlib.Path, label: str) -> pathlib.Path:
  candidate_path = reject_symlink_components(path, label)
  repository_root = reject_symlink_components(REPO_ROOT, "repository root")
  try:
    candidate_path.relative_to(repository_root)
  except ValueError:
    fail(f"{label} must stay inside repository root: {candidate_path}")
  return candidate_path


def regular_file_stat(path: pathlib.Path, label: str) -> os.stat_result:
  checked_path = repository_path(path, label)
  if not checked_path.exists():
    fail(f"{label} does not exist: {checked_path}")
  try:
    file_stat = checked_path.stat()
  except OSError as exc:
    fail(f"{label} is unreadable: {exc}")
  if not stat_module.S_ISREG(file_stat.st_mode):
    fail(f"{label} must be a regular file: {checked_path}")
  return file_stat


def bounded_text(path: pathlib.Path, label: str, max_bytes: int = MAX_ARTIFACT_BYTES) -> str:
  checked_path = repository_path(path, label)
  file_stat = regular_file_stat(checked_path, label)
  if file_stat.st_size > max_bytes:
    fail(f"{label} exceeds bounded size: {file_stat.st_size} > {max_bytes}")
  try:
    with checked_path.open("rb") as handle:
      opened_stat = os.fstat(handle.fileno())
      if not stat_module.S_ISREG(opened_stat.st_mode):
        fail(f"{label} must be a regular file: {checked_path}")
      if opened_stat.st_size > max_bytes:
        fail(f"{label} exceeds bounded size: {opened_stat.st_size} > {max_bytes}")
      data = handle.read(max_bytes + 1)
  except OSError as exc:
    fail(f"{label} is unreadable: {exc}")
  if len(data) > max_bytes:
    fail(f"{label} exceeds bounded size: read more than {max_bytes} bytes")
  try:
    return data.decode("utf-8")
  except UnicodeDecodeError as exc:
    fail(f"{label} must be UTF-8: {exc}")


def load_strict_json(path: pathlib.Path) -> Any:
  def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
      if key in result:
        fail(f"real-model integration artifact must not contain duplicate JSON key {key!r}")
      result[key] = value
    return result

  def reject_non_standard_constant(value: str) -> None:
    fail(f"real-model integration artifact must not contain non-standard JSON constant {value}")

  try:
    return json.loads(
      bounded_text(path, "real-model integration artifact"),
      object_pairs_hook=reject_duplicate_keys,
      parse_constant=reject_non_standard_constant,
    )
  except RealModelArtifactError:
    raise
  except Exception as exc:
    fail(f"real-model integration artifact must be JSON: {exc}")


def as_dict(value: Any, label: str) -> dict[str, Any]:
  if not isinstance(value, dict):
    fail(f"{label} must be an object")
  return value


def as_list(value: Any, label: str) -> list[Any]:
  if not isinstance(value, list):
    fail(f"{label} must be a list")
  return value


def as_string(value: Any, label: str, *, allow_empty: bool = False) -> str:
  if not isinstance(value, str):
    fail(f"{label} must be a string")
  if not allow_empty and not value:
    fail(f"{label} must not be empty")
  return value


def as_bool(value: Any, label: str) -> bool:
  if not isinstance(value, bool):
    fail(f"{label} must be boolean")
  return value


def as_int(value: Any, label: str, *, minimum: int | None = None) -> int:
  if isinstance(value, bool) or not isinstance(value, int):
    fail(f"{label} must be an integer")
  if minimum is not None and value < minimum:
    fail(f"{label} must be at least {minimum}")
  return value


def as_finite_float(value: Any, label: str) -> float:
  if isinstance(value, bool):
    fail(f"{label} must be numeric")
  try:
    number = float(value)
  except Exception as exc:
    fail(f"{label} must be numeric: {exc}")
  if not math.isfinite(number):
    fail(f"{label} must be finite")
  return number


def as_path(value: Any, label: str) -> pathlib.Path:
  raw = as_string(value, label)
  path = repository_path(pathlib.Path(raw), label)
  regular_file_stat(path, label)
  return path


def parse_timestamp(value: Any, label: str) -> datetime.datetime:
  raw = as_string(value, label)
  if not raw.endswith("Z"):
    fail(f"{label} must be a UTC timestamp ending in Z")
  try:
    parsed = datetime.datetime.fromisoformat(raw.removesuffix("Z") + "+00:00")
  except ValueError as exc:
    fail(f"{label} must be ISO-8601: {exc}")
  if parsed.tzinfo is None:
    fail(f"{label} must include timezone information")
  return parsed.astimezone(datetime.timezone.utc)


def artifact_min_mtime_epoch() -> float | None:
  raw = os.environ.get("QIXI_REAL_MODEL_ARTIFACT_MIN_MTIME_EPOCH")
  if raw is None or raw == "":
    return None
  try:
    return float(raw)
  except ValueError as exc:
    fail("QIXI_REAL_MODEL_ARTIFACT_MIN_MTIME_EPOCH must be a numeric Unix timestamp")
    raise AssertionError("unreachable") from exc


def validate_position_key(value: Any, label: str) -> str:
  key = as_string(value, label)
  if not POSITION_KEY_RE.fullmatch(key):
    fail(f"{label} must be a 64-character lowercase hex digest")
  return key


def validate_best_move(value: Any, label: str) -> None:
  best = as_dict(value, label)
  as_string(best.get("move"), f"{label}.move")
  x = as_int(best.get("x"), f"{label}.x")
  y = as_int(best.get("y"), f"{label}.y")
  if not 0 <= x < 19 or not 0 <= y < 19:
    fail(f"{label} coordinates must be on a 19x19 board")
  as_int(best.get("visits"), f"{label}.visits", minimum=0)
  winrate = as_finite_float(best.get("winrate"), f"{label}.winrate")
  if not 0.0 <= winrate <= 1.0:
    fail(f"{label}.winrate must be within [0, 1]")
  as_finite_float(best.get("scoreMean"), f"{label}.scoreMean")


def validate_case_definition(entry: Any, expected_case_id: str) -> None:
  case = as_dict(entry, f"caseDefinitions[{expected_case_id}]")
  case_id = as_string(case.get("caseId"), f"caseDefinitions[{expected_case_id}].caseId")
  if case_id != expected_case_id:
    fail(f"case definition order mismatch: expected {expected_case_id}, got {case_id}")
  as_int(case.get("historyLength"), f"{case_id}.historyLength", minimum=1)
  as_int(case.get("finalStoneCount"), f"{case_id}.finalStoneCount", minimum=0)
  final_stone_digest = as_string(case.get("finalStoneDigest"), f"{case_id}.finalStoneDigest")
  if not SHA256_RE.fullmatch(final_stone_digest):
    fail(f"{case_id}.finalStoneDigest must be a 64-character lowercase hex digest")
  as_finite_float(case.get("komi"), f"{case_id}.komi")
  root_noise = as_finite_float(case.get("rootNoise"), f"{case_id}.rootNoise")
  if root_noise < 0.0:
    fail(f"{case_id}.rootNoise must be non-negative")


def validate_analysis_case(
  entry: Any,
  *,
  expected_engine_id: str,
  expected_case_id: str,
  max_visits: int,
) -> str:
  case = as_dict(entry, f"{expected_engine_id}.analysisCases[{expected_case_id}]")
  case_id = as_string(case.get("caseId"), f"{expected_engine_id}.{expected_case_id}.caseId")
  if case_id != expected_case_id:
    fail(f"{expected_engine_id}.analysisCases order mismatch: expected {expected_case_id}, got {case_id}")
  engine_id = as_string(case.get("engineId"), f"{expected_engine_id}.{case_id}.engineId")
  if engine_id != expected_engine_id:
    fail(f"engine entry order mismatch: expected {expected_engine_id}, got {engine_id}")
  expected_engine = f"katago-metal-mux:{engine_id}"
  if as_string(case.get("engine"), f"{engine_id}.{case_id}.engine") != expected_engine:
    fail(f"{engine_id}.{case_id}.engine must be {expected_engine}")
  position_key = validate_position_key(case.get("positionKey"), f"{engine_id}.{case_id}.positionKey")
  as_int(case.get("historyLength"), f"{engine_id}.{case_id}.historyLength", minimum=1)
  as_finite_float(case.get("komi"), f"{engine_id}.{case_id}.komi")
  root_noise = as_finite_float(case.get("rootNoise"), f"{engine_id}.{case_id}.rootNoise")
  if root_noise < 0.0:
    fail(f"{engine_id}.{case_id}.rootNoise must be non-negative")
  if as_int(case.get("maxVisits"), f"{engine_id}.{case_id}.maxVisits", minimum=1) != max_visits:
    fail(f"{engine_id}.{case_id}.maxVisits must match artifact.maxVisits")
  as_int(case.get("rootVisits"), f"{engine_id}.{case_id}.rootVisits", minimum=1)
  as_int(case.get("candidateCount"), f"{engine_id}.{case_id}.candidateCount", minimum=1)
  if as_int(case.get("ownershipPointCount"), f"{engine_id}.{case_id}.ownershipPointCount", minimum=1) != 19 * 19:
    fail(f"{engine_id}.{case_id}.ownershipPointCount must be 361")

  ownership_min = as_finite_float(case.get("ownershipMin"), f"{engine_id}.{case_id}.ownershipMin")
  ownership_max = as_finite_float(case.get("ownershipMax"), f"{engine_id}.{case_id}.ownershipMax")
  if ownership_min > ownership_max:
    fail(f"{engine_id}.{case_id}.ownershipMin must be <= ownershipMax")
  if not -1.01 <= ownership_min <= 1.01 or not -1.01 <= ownership_max <= 1.01:
    fail(f"{engine_id}.{case_id}.ownership range must be within [-1.01, 1.01]")
  winrate = as_finite_float(case.get("winrate"), f"{engine_id}.{case_id}.winrate")
  if not 0.0 <= winrate <= 1.0:
    fail(f"{engine_id}.{case_id}.winrate must be within [0, 1]")
  as_finite_float(case.get("scoreMean"), f"{engine_id}.{case_id}.scoreMean")
  analysis_elapsed_ms = as_finite_float(case.get("analysisElapsedMs"), f"{engine_id}.{case_id}.analysisElapsedMs")
  if analysis_elapsed_ms <= 0:
    fail(f"{engine_id}.{case_id}.analysisElapsedMs must be positive")
  validate_best_move(case.get("bestMove"), f"{engine_id}.{case_id}.bestMove")
  return position_key


def validate_engine(entry: Any, expected_engine_id: str, max_visits: int) -> dict[str, str]:
  engine = as_dict(entry, f"engines[{expected_engine_id}]")
  engine_id = as_string(engine.get("engineId"), f"{expected_engine_id}.engineId")
  if engine_id != expected_engine_id:
    fail(f"engine entry order mismatch: expected {expected_engine_id}, got {engine_id}")

  model_path = as_path(engine.get("modelPath"), f"{engine_id}.modelPath")
  model_byte_count = as_int(engine.get("modelByteCount"), f"{engine_id}.modelByteCount", minimum=1)
  if model_path.stat().st_size != model_byte_count:
    fail(f"{engine_id}.modelByteCount does not match modelPath size")

  primary_position_key = validate_analysis_case(
    engine,
    expected_engine_id=expected_engine_id,
    expected_case_id=EXPECTED_CASE_IDS[0],
    max_visits=max_visits,
  )
  if validate_position_key(engine.get("positionKey"), f"{engine_id}.positionKey") != primary_position_key:
    fail(f"{engine_id}.positionKey must match the first analysis case")
  as_finite_float(engine.get("statusElapsedMs"), f"{engine_id}.statusElapsedMs")
  if as_bool(engine.get("statusRunning"), f"{engine_id}.statusRunning") is not True:
    fail(f"{engine_id}.statusRunning must be true")
  if as_bool(engine.get("statusPaused"), f"{engine_id}.statusPaused") is not False:
    fail(f"{engine_id}.statusPaused must be false")

  analysis_cases = as_list(engine.get("analysisCases"), f"{engine_id}.analysisCases")
  if len(analysis_cases) != len(EXPECTED_CASE_IDS):
    fail(f"{engine_id}.analysisCases must contain exactly {len(EXPECTED_CASE_IDS)} entries")
  case_keys = {
    case_id: validate_analysis_case(
      case,
      expected_engine_id=expected_engine_id,
      expected_case_id=case_id,
      max_visits=max_visits,
    )
    for case, case_id in zip(analysis_cases, EXPECTED_CASE_IDS)
  }
  if case_keys[EXPECTED_CASE_IDS[0]] != primary_position_key:
    fail(f"{engine_id}.analysisCases[0] must match the primary engine summary")
  if len(set(case_keys.values())) != len(case_keys):
    fail(f"{engine_id}.analysis case position keys must be unique")
  return case_keys


def validate_off_engine_check(entry: Any, expected_after_engine_id: str) -> str:
  check = as_dict(entry, f"offEngineChecks[{expected_after_engine_id}]")
  after = as_string(check.get("afterEngineId"), f"offEngineChecks[{expected_after_engine_id}].afterEngineId")
  if after != expected_after_engine_id:
    fail(f"off-engine check order mismatch: expected {expected_after_engine_id}, got {after}")
  position_key = validate_position_key(check.get("positionKey"), f"offEngineChecks[{after}].positionKey")
  if as_int(check.get("movesCount"), f"offEngineChecks[{after}].movesCount", minimum=0) != 0:
    fail(f"offEngineChecks[{after}].movesCount must be 0")
  if as_int(check.get("ownershipPointCount"), f"offEngineChecks[{after}].ownershipPointCount", minimum=0) != 0:
    fail(f"offEngineChecks[{after}].ownershipPointCount must be 0")
  if as_bool(check.get("running"), f"offEngineChecks[{after}].running") is not False:
    fail(f"offEngineChecks[{after}].running must be false")
  if as_bool(check.get("paused"), f"offEngineChecks[{after}].paused") is not False:
    fail(f"offEngineChecks[{after}].paused must be false")
  return position_key


def validate_same_visible_different_history_check(
  entry: Any,
  expected_engine_id: str,
  case_keys: dict[str, str],
) -> None:
  check = as_dict(entry, f"sameVisibleDifferentHistoryChecks[{expected_engine_id}]")
  engine_id = as_string(check.get("engineId"), f"sameVisibleDifferentHistoryChecks[{expected_engine_id}].engineId")
  if engine_id != expected_engine_id:
    fail(f"same-visible check order mismatch: expected {expected_engine_id}, got {engine_id}")
  case_a = as_string(check.get("caseA"), f"{engine_id}.sameVisible.caseA")
  case_b = as_string(check.get("caseB"), f"{engine_id}.sameVisible.caseB")
  if (case_a, case_b) != ("same-stones-history-a", "same-stones-history-b"):
    fail(f"{engine_id}.sameVisible cases must compare the same-stones history pair")
  if as_bool(check.get("finalStonesEqual"), f"{engine_id}.sameVisible.finalStonesEqual") is not True:
    fail(f"{engine_id}.sameVisible.finalStonesEqual must be true")
  if as_bool(check.get("positionKeysDistinct"), f"{engine_id}.sameVisible.positionKeysDistinct") is not True:
    fail(f"{engine_id}.sameVisible.positionKeysDistinct must be true")
  position_key_a = validate_position_key(check.get("positionKeyA"), f"{engine_id}.sameVisible.positionKeyA")
  position_key_b = validate_position_key(check.get("positionKeyB"), f"{engine_id}.sameVisible.positionKeyB")
  if position_key_a == position_key_b:
    fail(f"{engine_id}.sameVisible position keys must be distinct")
  if case_keys.get(case_a) != position_key_a or case_keys.get(case_b) != position_key_b:
    fail(f"{engine_id}.sameVisible position keys must match analysisCases")
  final_stone_digest = as_string(check.get("finalStoneDigest"), f"{engine_id}.sameVisible.finalStoneDigest")
  if not SHA256_RE.fullmatch(final_stone_digest):
    fail(f"{engine_id}.sameVisible.finalStoneDigest must be a 64-character lowercase hex digest")


def validate_artifact(path: pathlib.Path) -> dict[str, Any]:
  path = repository_path(path, "real-model integration artifact")
  artifact_stat = regular_file_stat(path, "real-model integration artifact")
  if artifact_stat.st_size <= 0:
    fail(f"real-model integration artifact must be a non-empty file: {path}")
  min_mtime_epoch = artifact_min_mtime_epoch()
  if min_mtime_epoch is not None and artifact_stat.st_mtime < min_mtime_epoch:
    fail(
      "real-model integration artifact is stale for this run: "
      f"mtime={artifact_stat.st_mtime:.3f} before required minimum {min_mtime_epoch:.3f}"
    )
  payload = load_strict_json(path)
  artifact = as_dict(payload, "artifact")

  if as_int(artifact.get("schemaVersion"), "schemaVersion") != 1:
    fail("schemaVersion must be 1")
  if as_string(artifact.get("kind"), "kind") != EXPECTED_KIND:
    fail(f"kind must be {EXPECTED_KIND}")
  generated_at = parse_timestamp(artifact.get("generatedAt"), "generatedAt")
  max_age_seconds = int(os.environ.get("QIXI_REAL_MODEL_ARTIFACT_MAX_AGE_SECONDS", str(DEFAULT_MAX_AGE_SECONDS)))
  if max_age_seconds > 0:
    age_seconds = (datetime.datetime.now(datetime.timezone.utc) - generated_at).total_seconds()
    if age_seconds < -300:
      fail("generatedAt is more than five minutes in the future")
    if age_seconds > max_age_seconds:
      fail(f"real-model integration artifact is stale: ageSeconds={age_seconds:.1f}")

  katago_binary = as_path(artifact.get("katagoBinary"), "katagoBinary")
  katago_binary_byte_count = as_int(artifact.get("katagoBinaryByteCount"), "katagoBinaryByteCount", minimum=1)
  if katago_binary.stat().st_size != katago_binary_byte_count:
    fail("katagoBinaryByteCount does not match katagoBinary size")
  as_path(artifact.get("configPath"), "configPath")
  override_sha256 = as_string(artifact.get("overrideSha256"), "overrideSha256")
  if not SHA256_RE.fullmatch(override_sha256):
    fail("overrideSha256 must be a 64-character lowercase hex digest")
  as_int(artifact.get("historyLength"), "historyLength", minimum=1)
  max_visits = as_int(artifact.get("maxVisits"), "maxVisits", minimum=1)
  if max_visits < MIN_REAL_MODEL_MAX_VISITS:
    fail(f"maxVisits must be at least {MIN_REAL_MODEL_MAX_VISITS} for real-model integration evidence")

  case_definitions = as_list(artifact.get("caseDefinitions"), "caseDefinitions")
  if len(case_definitions) != len(EXPECTED_CASE_IDS):
    fail(f"caseDefinitions must contain exactly {len(EXPECTED_CASE_IDS)} entries")
  for case_definition, case_id in zip(case_definitions, EXPECTED_CASE_IDS):
    validate_case_definition(case_definition, case_id)

  engines = as_list(artifact.get("engines"), "engines")
  if len(engines) != len(EXPECTED_ENGINES):
    fail(f"engines must contain exactly {len(EXPECTED_ENGINES)} entries")
  case_key_maps = [
    validate_engine(entry, engine_id, max_visits)
    for entry, engine_id in zip(engines, EXPECTED_ENGINES)
  ]
  position_keys = [case_keys[EXPECTED_CASE_IDS[0]] for case_keys in case_key_maps]
  all_real_position_keys = [position_key for case_keys in case_key_maps for position_key in case_keys.values()]
  if len(set(position_keys)) != len(position_keys):
    fail("engine position keys must be unique")
  if len(set(all_real_position_keys)) != len(all_real_position_keys):
    fail("all real-model analysis case position keys must be unique")
  if as_bool(artifact.get("positionKeysUnique"), "positionKeysUnique") is not True:
    fail("positionKeysUnique must be true")

  same_visible_checks = as_list(
    artifact.get("sameVisibleDifferentHistoryChecks"),
    "sameVisibleDifferentHistoryChecks",
  )
  if len(same_visible_checks) != len(EXPECTED_ENGINES):
    fail(f"sameVisibleDifferentHistoryChecks must contain exactly {len(EXPECTED_ENGINES)} entries")
  for check, engine_id, case_keys in zip(same_visible_checks, EXPECTED_ENGINES, case_key_maps):
    validate_same_visible_different_history_check(check, engine_id, case_keys)

  off_checks = as_list(artifact.get("offEngineChecks"), "offEngineChecks")
  if len(off_checks) != len(EXPECTED_ENGINES):
    fail(f"offEngineChecks must contain exactly {len(EXPECTED_ENGINES)} entries")
  off_position_keys = [
    validate_off_engine_check(entry, engine_id)
    for entry, engine_id in zip(off_checks, EXPECTED_ENGINES)
  ]
  if len(set(off_position_keys)) != 1:
    fail("off-engine position keys should be identical after each model unload")
  if set(off_position_keys) & set(all_real_position_keys):
    fail("off-engine position key must not equal a real-model position key")
  return artifact


def main(argv: list[str]) -> int:
  path = pathlib.Path(argv[1]).expanduser() if len(argv) > 1 else DEFAULT_ARTIFACT
  try:
    artifact = validate_artifact(path)
  except RealModelArtifactError as exc:
    print(f"Real model integration artifact inspection failed: {exc}", file=sys.stderr)
    return 1
  print(
    "Real model integration artifact inspection passed: "
    f"{len(artifact['engines'])} engines, {path}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main(sys.argv))
