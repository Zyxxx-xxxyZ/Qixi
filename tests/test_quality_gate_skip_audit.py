#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
QUALITY_GATE = ROOT / "scripts" / "qixi-quality-gate.sh"
RELEASE_GATE = ROOT / "scripts" / "qixi-release-evidence-gate.sh"
DEVICE_PREFLIGHT = ROOT / "scripts" / "qixi_device_run_preflight.py"


def read(path: pathlib.Path) -> str:
  return path.read_text(encoding="utf-8")


def skip_messages(script: str, *, source: str) -> list[str]:
  patterns = {
    "shell": (r'\s*echo "([^"]*Skipping[^"]*)"\s*',),
    "python": (r'\s*print\("([^"]*Skipping[^"]*)"\)\s*',),
  }
  if source not in patterns:
    raise AssertionError(f"unsupported skip source type: {source}")
  messages: list[str] = []
  for line_number, line in enumerate(script.splitlines(), start=1):
    skip_probe = line.replace('""', "").replace("''", "")
    if "Skipping" not in line and "Skipping" not in skip_probe:
      continue
    match = next((candidate for pattern in patterns[source] if (candidate := re.fullmatch(pattern, line))), None)
    if match is None:
      raise AssertionError(f"unparseable {source} skip output on line {line_number}: {line}")
    messages.append(match.group(1))
  return messages


class QualityGateSkipAuditTests(unittest.TestCase):
  def test_skip_parser_rejects_unparseable_skip_output(self) -> None:
    for script in (
      'printf "Skipping hidden optional gate\\n"\n',
      "echo 'Skipping hidden optional gate'\n",
      'echo "Skip""ping hidden optional gate"\n',
    ):
      with self.subTest(script=script):
        with self.assertRaisesRegex(AssertionError, "unparseable shell skip output"):
          skip_messages(script, source="shell")

  def test_python_skip_parser_rejects_unparseable_skip_output(self) -> None:
    for script in (
      "print('Skipping hidden optional gate')\n",
      'print("Skip""ping hidden optional gate")\n',
      'print(f"Skipping hidden optional gate")\n',
    ):
      with self.subTest(script=script):
        with self.assertRaisesRegex(AssertionError, "unparseable python skip output"):
          skip_messages(script, source="python")

  def test_default_quality_gate_skip_messages_are_explicit_and_ordered(self) -> None:
    messages = skip_messages(read(QUALITY_GATE), source="shell")
    self.assertEqual(
      messages,
      [
        "Skipping web simulator UI contract: node not found",
        "Skipping native Xcode build because QIXI_SKIP_XCODEBUILD=1",
        "Skipping native Xcode build: xcodebuild not found",
        "Skipping iOS KataGo CMake preflight. Set QIXI_RUN_IOS_KATAGO_CMAKE=1 to enable.",
        "Skipping native release simulator smoke. Set QIXI_RUN_NATIVE_RELEASE_SIM=1 to enable.",
        "Skipping physical-device bridge plan. Set QIXI_RUN_DEVICE_BRIDGE_PLAN=1 to enable.",
        "Skipping physical-device bridge smoke. Set QIXI_RUN_DEVICE_BRIDGE_SMOKE=1 to enable.",
        "Skipping physical-device bridge failure inspection. Set QIXI_RUN_DEVICE_BRIDGE_FAILURE_INSPECT=1 to enable.",
        "Skipping simulator screenshot smoke. Set QIXI_RUN_SCREENSHOT_SMOKE=1 to enable.",
        "Skipping simulator screenshot/persistence smoke. Set QIXI_RUN_SCREENSHOTS=1 to enable.",
        "Skipping real-model integrations. Set QIXI_RUN_REAL_MODELS=1 to enable.",
      ],
    )

  def test_optional_quality_gate_skips_name_the_exact_enabling_variable(self) -> None:
    optional_messages = [
      message
      for message in skip_messages(read(QUALITY_GATE), source="shell")
      if "Set QIXI_RUN_" in message
    ]
    self.assertTrue(optional_messages)
    for message in optional_messages:
      match = re.fullmatch(r"Skipping .+\. Set (QIXI_RUN_[A-Z0-9_]+)=1 to enable\.", message)
      self.assertIsNotNone(match, message)
      variable = match.group(1)
      self.assertIn(f'if [[ "${{{variable}:-0}}" == "1"', read(QUALITY_GATE))

  def test_default_quality_gate_environment_missing_skips_are_diagnostic_only(self) -> None:
    messages = skip_messages(read(QUALITY_GATE), source="shell")
    diagnostic_messages = [message for message in messages if "Set QIXI_RUN_" not in message]
    self.assertEqual(
      diagnostic_messages,
      [
        "Skipping web simulator UI contract: node not found",
        "Skipping native Xcode build because QIXI_SKIP_XCODEBUILD=1",
        "Skipping native Xcode build: xcodebuild not found",
      ],
    )
    for message in diagnostic_messages:
      self.assertRegex(message, r"(node not found|xcodebuild not found|QIXI_SKIP_XCODEBUILD=1)")

  def test_release_evidence_gate_has_only_native_inprocess_backend_skip(self) -> None:
    release_script = read(RELEASE_GATE)
    self.assertEqual(
      skip_messages(release_script, source="shell"),
      [
        "Skipping strict physical-device backend preflight because release evidence must be nativeInProcess",
      ],
    )
    self.assertIn("QIXI_RUN_SCREENSHOTS=1", release_script)
    self.assertIn("QIXI_RUN_IOS_KATAGO_CMAKE=1", release_script)
    self.assertIn("QIXI_RUN_NATIVE_RELEASE_SIM=1", release_script)
    self.assertIn("QIXI_RUN_REAL_MODELS=1", release_script)

  def test_device_run_preflight_skip_is_explicit_and_audited(self) -> None:
    device_script = read(DEVICE_PREFLIGHT)
    self.assertEqual(
      skip_messages(device_script, source="python"),
      [
        "Skipping live device backend check. Set QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765 to enable it.",
      ],
    )
    self.assertIn("if backend_url:", device_script)
    self.assertIn(
      "strict physical-device preflight requires QIXI_DEVICE_BACKEND_URL=http://<mac-lan-ip>:8765",
      device_script,
    )


if __name__ == "__main__":
  unittest.main()
