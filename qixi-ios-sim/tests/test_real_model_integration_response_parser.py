#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_module(name: str, path: pathlib.Path):
  spec = importlib.util.spec_from_file_location(name, path)
  assert spec is not None and spec.loader is not None
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  return module


class RealModelIntegrationResponseParserTests(unittest.TestCase):
  @classmethod
  def setUpClass(cls) -> None:
    cls.modules = [
      load_module("integration_real_b6", ROOT / "tests" / "integration_real_b6.py"),
      load_module("integration_all_models", ROOT / "tests" / "integration_all_models.py"),
    ]

  def test_accepts_strict_json_objects(self) -> None:
    for module in self.modules:
      with self.subTest(module=module.__name__):
        payload = module.load_json_object_without_duplicate_keys(b'{"engine":"none"}', "backend response")
        self.assertEqual(payload["engine"], "none")

  def test_rejects_ambiguous_or_non_standard_responses(self) -> None:
    cases = [
      (b'{"engine":"none","engine":"b6"}', "duplicate JSON key 'engine'"),
      (b'{"winrate":NaN}', "non-standard JSON constant NaN"),
      (b'["not", "an", "object"]', "must be a JSON object"),
    ]
    for module in self.modules:
      for body, expected_error in cases:
        with self.subTest(module=module.__name__, body=body):
          with self.assertRaisesRegex(RuntimeError, expected_error):
            module.load_json_object_without_duplicate_keys(body, "backend response")

  def test_rejects_oversized_responses_before_json_decode(self) -> None:
    for module in self.modules:
      with self.subTest(module=module.__name__):
        body = b"{" + (b" " * module.MAX_HTTP_RESPONSE_BYTES) + b"}"
        with self.assertRaisesRegex(RuntimeError, "response body exceeds"):
          module.load_json_object_without_duplicate_keys(body, "backend response")

  def test_real_model_artifact_writer_is_atomic_and_rejects_symlink_targets(self) -> None:
    module = self.modules[1]
    previous_artifact = module.ARTIFACT
    try:
      with tempfile.TemporaryDirectory() as tmpdir:
        directory = pathlib.Path(tmpdir)
        module.ARTIFACT = directory / "latest-real-model-integration.json"
        module.write_real_model_artifact({"kind": "qixi-real-model-metal-mux-integration", "schemaVersion": 1})
        payload = json.loads(module.ARTIFACT.read_text(encoding="utf-8"))
        self.assertEqual(payload["kind"], "qixi-real-model-metal-mux-integration")
        self.assertFalse(list(directory.glob("*.tmp")))

      with tempfile.TemporaryDirectory() as tmpdir:
        directory = pathlib.Path(tmpdir)
        target = directory / "target.json"
        target.write_text("do-not-touch\n", encoding="utf-8")
        linked_artifact = directory / "latest-real-model-integration.json"
        try:
          linked_artifact.symlink_to(target)
        except (OSError, NotImplementedError) as exc:
          self.skipTest(f"symlink creation is unavailable: {exc}")
        module.ARTIFACT = linked_artifact
        with self.assertRaisesRegex(RuntimeError, "symbolic links"):
          module.write_real_model_artifact({"schemaVersion": 1})
        self.assertEqual(target.read_text(encoding="utf-8"), "do-not-touch\n")
    finally:
      module.ARTIFACT = previous_artifact

  def test_real_model_artifact_writer_uses_exclusive_temporary_file(self) -> None:
    module = self.modules[1]
    previous_artifact = module.ARTIFACT
    try:
      with tempfile.TemporaryDirectory() as tmpdir:
        directory = pathlib.Path(tmpdir)
        module.ARTIFACT = directory / "latest-real-model-integration.json"
        blocker = directory / f".{module.ARTIFACT.name}.{module.os.getpid()}.tmp"
        blocker.write_text("owned-by-someone-else\n", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "atomic-write temporary file"):
          module.write_real_model_artifact({"schemaVersion": 1})
        self.assertEqual(blocker.read_text(encoding="utf-8"), "owned-by-someone-else\n")
        self.assertFalse(module.ARTIFACT.exists())
    finally:
      module.ARTIFACT = previous_artifact


if __name__ == "__main__":
  unittest.main()
