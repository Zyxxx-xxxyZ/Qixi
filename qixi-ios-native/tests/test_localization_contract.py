#!/usr/bin/env python3
from __future__ import annotations

import ast
import pathlib
import re
import unittest

from screenshot_manifest_json import load_manifest_json


ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "Qixi"
MANIFEST = ROOT / "tests" / "screenshot_coverage_manifest.json"


def read(path: pathlib.Path) -> str:
  return path.read_text(encoding="utf-8")


def swift_string_value(raw: str) -> str:
  return ast.literal_eval(raw)


def l10n_source() -> str:
  return read(SRC / "L10n.swift")


def app_language_cases(source: str) -> dict[str, str]:
  block = re.search(r"enum AppLanguage: String, CaseIterable \{(?P<body>.*?)\n\}", source, re.S)
  if not block:
    return {}
  return {
    name: swift_string_value(raw)
    for name, raw in re.findall(r"\bcase\s+([A-Za-z0-9_]+)\s*=\s*(\"(?:\\.|[^\"\\])*\")", block.group("body"))
  }


def l10n_keys(source: str) -> set[str]:
  block = re.search(r"enum Key: String, CaseIterable \{(?P<body>.*?)\n  \}", source, re.S)
  if not block:
    return set()
  return set(re.findall(r"\bcase\s+([A-Za-z0-9_]+)", block.group("body")))


def translation_table(source: str, language: str) -> dict[str, str]:
  block = re.search(rf"\.{language}:\s*\[(?P<body>.*?)\n    \]", source, re.S)
  if not block:
    return {}
  entries = re.findall(r"\.([A-Za-z0-9_]+):\s*(\"(?:\\.|[^\"\\])*\")", block.group("body"))
  return {key: swift_string_value(value) for key, value in entries}


FORMAT_SPECIFIER = re.compile(
  r"%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|L|z|j|t)?[@diuoxXfFeEgGaAcCsSp]"
)


def format_specifiers(value: str) -> list[str]:
  specifiers: list[str] = []
  index = 0
  while index < len(value):
    if value[index] != "%":
      index += 1
      continue
    if index + 1 < len(value) and value[index + 1] == "%":
      index += 2
      continue
    match = FORMAT_SPECIFIER.match(value, index)
    if not match:
      specifiers.append(f"INVALID_PERCENT_AT_{index}")
      index += 1
      continue
    specifiers.append(match.group(0))
    index = match.end()
  return specifiers


class LocalizationContractTests(unittest.TestCase):
  def setUp(self) -> None:
    self.source = l10n_source()
    self.keys = l10n_keys(self.source)
    self.languages = app_language_cases(self.source)

  def test_supported_languages_match_screenshot_manifest(self) -> None:
    self.assertEqual(
      self.languages,
      {
        "zhHans": "zh-Hans",
        "zhHant": "zh-Hant",
        "en": "en",
      },
    )
    manifest = load_manifest_json(MANIFEST)
    self.assertEqual(manifest["languages"], list(self.languages.values()))

  def test_every_key_has_explicit_translation_in_every_language(self) -> None:
    self.assertGreaterEqual(len(self.keys), 40)
    for language in self.languages:
      table = translation_table(self.source, language)
      self.assertEqual(self.keys, set(table), language)
      for key, value in table.items():
        self.assertNotEqual("", value.strip(), f"{language}.{key}")
        self.assertNotEqual(key, value, f"{language}.{key} must not fall back to raw key")

  def test_format_placeholders_are_identical_across_languages(self) -> None:
    tables = {
      language: translation_table(self.source, language)
      for language in self.languages
    }
    expected_format_keys = {
      "treeMoveNumber",
      "cameraRecognizedStones",
      "importLoadedMoves",
      "syncLastSynced",
      "engineErrorModelMissing",
      "engineErrorInsufficientMemory",
      "engineErrorUnloadFailed",
      "engineErrorAnalysisFailed",
      "engineErrorModelInstallFailed",
    }
    actual_format_keys: set[str] = set()

    for key in sorted(self.keys):
      reference = format_specifiers(tables["zhHans"][key])
      if reference:
        actual_format_keys.add(key)
      self.assertNotIn("INVALID_PERCENT", " ".join(reference), key)
      for language, table in tables.items():
        specifiers = format_specifiers(table[key])
        self.assertEqual(reference, specifiers, f"{language}.{key}")
        self.assertNotIn("INVALID_PERCENT", " ".join(specifiers), f"{language}.{key}")

    self.assertEqual(expected_format_keys, actual_format_keys)

  def test_all_l10n_text_references_target_declared_keys(self) -> None:
    referenced: set[str] = set()
    for path in SRC.glob("*.swift"):
      referenced.update(re.findall(r"L10n\.text\(\.([A-Za-z0-9_]+)\)", read(path)))
    self.assertTrue(referenced, "expected UI to reference localized copy")
    self.assertLessEqual(referenced, self.keys)

  def test_formatted_localized_strings_use_known_format_keys(self) -> None:
    source = "\n".join(read(path) for path in SRC.glob("*.swift"))
    expected_uses = {
      "treeMoveNumber": "String(format: text(.treeMoveNumber), ply)",
      "cameraRecognizedStones": "format: L10n.text(.cameraRecognizedStones)",
      "importLoadedMoves": "String(format: L10n.text(.importLoadedMoves), model.mainLine.count)",
      "syncLastSynced": "format: L10n.text(.syncLastSynced)",
      "engineErrorModelMissing": "String(format: L10n.text(.engineErrorModelMissing), resourceName)",
      "engineErrorInsufficientMemory": "format: L10n.text(.engineErrorInsufficientMemory)",
      "engineErrorUnloadFailed": "fallbackKey: .engineErrorUnloadFailed",
      "engineErrorAnalysisFailed": "fallbackKey: .engineErrorAnalysisFailed",
      "engineErrorModelInstallFailed": "fallbackKey: .engineErrorModelInstallFailed",
    }
    for key, token in expected_uses.items():
      self.assertIn(token, source, key)


if __name__ == "__main__":
  unittest.main()
