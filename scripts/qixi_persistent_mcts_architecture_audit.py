#!/usr/bin/env python3
from __future__ import annotations

import dataclasses
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
ENGINE = ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeKataGoEngine.cpp"
VIEW_MODEL = ROOT / "qixi-ios-native" / "Qixi" / "QixiViewModel.swift"


@dataclasses.dataclass(frozen=True)
class Finding:
  path: pathlib.Path
  line: int
  message: str


def line_of(text: str, offset: int) -> int:
  return text.count("\n", 0, offset) + 1


def read(path: pathlib.Path) -> str:
  return path.read_text(encoding="utf-8")


def find_matching_brace(text: str, open_brace: int) -> int:
  depth = 0
  index = open_brace
  while index < len(text):
    char = text[index]
    if char == "{":
      depth += 1
    elif char == "}":
      depth -= 1
      if depth == 0:
        return index
    index += 1
  raise ValueError("unmatched brace")


def extract_cpp_method(text: str, signature_pattern: str) -> tuple[int, str]:
  match = re.search(signature_pattern, text)
  if not match:
    raise ValueError(f"method not found: {signature_pattern}")
  open_brace = text.find("{", match.end())
  if open_brace < 0:
    raise ValueError(f"method body not found: {signature_pattern}")
  close_brace = find_matching_brace(text, open_brace)
  return open_brace, text[open_brace + 1:close_brace]


def extract_swift_method(text: str, signature_pattern: str) -> tuple[int, str]:
  match = re.search(signature_pattern, text)
  if not match:
    raise ValueError(f"method not found: {signature_pattern}")
  open_brace = text.find("{", match.end())
  if open_brace < 0:
    raise ValueError(f"method body not found: {signature_pattern}")
  close_brace = find_matching_brace(text, open_brace)
  return open_brace, text[open_brace + 1:close_brace]


def audit_native_analyze_request() -> list[Finding]:
  text = read(ENGINE)
  start, body = extract_cpp_method(
    text,
    r"NativeKataGoResult\s+analyzeRequest\s*\(\s*const\s+NativeKataGoAnalysisRequest&\s+request\s*\)\s+override",
  )
  findings: list[Finding] = []
  forbidden = {
    "setPositionForMCTSPersistence": (
      "native analyzeRequest must not reset/materialize the persistent root on every UI batch; "
      "root switching must be a separate operation"
    ),
    "runWholeSearch": (
      "native analyzeRequest must not own a full search lifecycle per UI batch; "
      "analysis must run as a long-lived search with lightweight snapshots"
    ),
    "getSearchStopAndWait": (
      "native analyzeRequest must not stop/wait the search for every UI batch; "
      "batch refreshes should not tear through the AsyncBot lifecycle"
    ),
  }
  for needle, message in forbidden.items():
    offset = body.find(needle)
    if offset >= 0:
      findings.append(Finding(ENGINE, line_of(text, start + 1 + offset), message))
  return findings


def audit_swift_realtime_loop() -> list[Finding]:
  text = read(VIEW_MODEL)
  start, body = extract_swift_method(
    text,
    r"private\s+func\s+startAnalysis\s*\([^)]*engine:\s*AnalysisEngine,[^)]*assumesEngineAlreadyLoaded:\s*Bool[^)]*\)",
  )
  findings: list[Finding] = []
  loop_match = re.search(r"while\s+true\s*\{", body)
  analyze_match = re.search(r"analysisService\.analyze\s*\(", body)
  if loop_match and analyze_match:
    findings.append(Finding(
      VIEW_MODEL,
      line_of(text, start + 1 + loop_match.start()),
      "Swift realtime analysis must not be implemented as while-true repeated analyze requests; "
      "UI refresh should read snapshots from a long-lived native search",
    ))
  return findings


def main() -> int:
  findings = audit_native_analyze_request() + audit_swift_realtime_loop()
  if not findings:
    print("Persistent MCTS architecture audit passed.")
    return 0

  print("Persistent MCTS architecture audit failed:")
  for finding in findings:
    rel = finding.path.relative_to(ROOT)
    print(f"- {rel}:{finding.line}: {finding.message}")
  return 1


if __name__ == "__main__":
  sys.exit(main())
