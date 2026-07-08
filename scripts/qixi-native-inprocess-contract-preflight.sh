#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# Audited source paths:
# - KataGo/cpp/command/analysis.cpp
# - KataGo/cpp/search/asyncbot.h
# - KataGo/cpp/search/search.h
# - KataGo/cpp/program/setup.h
# - qixi-ios-native/Qixi/QixiNativeKataGoCore.hpp
# - qixi-ios-native/Qixi/QixiNativeKataGoCore.cpp
# - qixi-ios-native/Qixi/QixiNativeKataGoEngine.cpp
# - qixi-ios-native/Qixi/QixiNativeKataGoAnalysisService.swift

cd "$ROOT_DIR"

"$PYTHON_BIN" - <<'PY'
from __future__ import annotations

import os
import pathlib
import stat as stat_module
import sys
import tempfile


ROOT = pathlib.Path.cwd()
TESTING_ENV = "QIXI_NATIVE_INPROCESS_PREFLIGHT_TESTING"
SELFTEST_OPENED_DESCRIPTOR_ENV = "QIXI_NATIVE_INPROCESS_PREFLIGHT_SELFTEST_OPENED_DESCRIPTOR"
SOURCE_TEXT_MAX_BYTES = 4 * 1024 * 1024
DOC = ROOT / "docs" / "native-katago-integration.md"
CORE_HEADER = ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeKataGoCore.hpp"
CORE_IMPL = ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeKataGoCore.cpp"
ENGINE = ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeKataGoEngine.cpp"
NATIVE_SERVICE = ROOT / "qixi-ios-native" / "Qixi" / "QixiNativeKataGoAnalysisService.swift"
ANALYSIS = ROOT / "KataGo" / "cpp" / "command" / "analysis.cpp"
ASYNCBOT = ROOT / "KataGo" / "cpp" / "search" / "asyncbot.h"
SEARCH = ROOT / "KataGo" / "cpp" / "search" / "search.h"
SETUP = ROOT / "KataGo" / "cpp" / "program" / "setup.h"
METAL_BACKEND = ROOT / "KataGo" / "cpp" / "neuralnet" / "metalbackend.cpp"


def fail(message: str) -> None:
  print(f"Native in-process contract preflight failed: {message}", file=sys.stderr)
  raise SystemExit(1)


def display_path(path: pathlib.Path) -> str:
  try:
    return str(path.relative_to(ROOT))
  except ValueError:
    return str(path)


def _is_allowed_platform_symlink_alias(path: pathlib.Path) -> bool:
  if sys.platform != "darwin":
    return False
  allowed_aliases = {
    pathlib.Path("/var"): pathlib.Path("/private/var"),
    pathlib.Path("/tmp"): pathlib.Path("/private/tmp"),
    pathlib.Path("/etc"): pathlib.Path("/private/etc"),
  }
  expected_target = allowed_aliases.get(path)
  if expected_target is None:
    return False
  try:
    return path.resolve(strict=True) == expected_target
  except OSError:
    return False


def _reject_symlink_path(path: pathlib.Path, label: str) -> None:
  if path.is_symlink() and not _is_allowed_platform_symlink_alias(path):
    fail(f"{label} must not contain symbolic links: {path}")


def _reject_symlink_components(path: pathlib.Path, label: str) -> None:
  current = pathlib.Path(path.anchor) if path.anchor else pathlib.Path()
  for part in path.parts:
    if part == path.anchor or not part:
      continue
    current = current / part
    _reject_symlink_path(current, label)


def _validate_regular_file(path: pathlib.Path, label: str) -> None:
  _reject_symlink_components(path, label)
  if not path.exists():
    fail(f"missing {display_path(path)}")
  if not path.is_file():
    fail(f"{label} is not a regular file: {path}")


def _opened_regular_file_stat(handle, path: pathlib.Path, label: str) -> os.stat_result:
  try:
    opened_stat = os.fstat(handle.fileno())
  except OSError as exc:
    fail(f"{label} could not be inspected after opening: {path}: {exc}")
  if not stat_module.S_ISREG(opened_stat.st_mode):
    fail(f"{label} must be a regular file after opening: {path}")
  return opened_stat


def read(path: pathlib.Path, label: str | None = None) -> str:
  label = label or f"file {display_path(path)}"
  _validate_regular_file(path, label)
  try:
    size = path.stat().st_size
  except OSError as exc:
    fail(f"{label} could not be statted: {path}: {exc}")
  if size > SOURCE_TEXT_MAX_BYTES:
    fail(f"{label} exceeds bounded size of {SOURCE_TEXT_MAX_BYTES} bytes before loading: {path}")
  try:
    with path.open("rb") as handle:
      opened_stat = _opened_regular_file_stat(handle, path, label)
      if opened_stat.st_size > SOURCE_TEXT_MAX_BYTES:
        fail(f"{label} exceeds bounded size of {SOURCE_TEXT_MAX_BYTES} bytes after opening: {path}")
      data = handle.read(SOURCE_TEXT_MAX_BYTES + 1)
  except OSError as exc:
    fail(f"{label} could not be read: {path}: {exc}")
  if len(data) > SOURCE_TEXT_MAX_BYTES:
    fail(f"{label} exceeds bounded size of {SOURCE_TEXT_MAX_BYTES} bytes before loading: {path}")
  try:
    return data.decode("utf-8")
  except UnicodeDecodeError as exc:
    fail(f"{label} must be UTF-8: {path}: {exc}")


def _selftest_opened_descriptor_recheck() -> None:
  if os.environ.get(SELFTEST_OPENED_DESCRIPTOR_ENV) != "1":
    return
  if os.environ.get(TESTING_ENV) != "1":
    fail(f"{SELFTEST_OPENED_DESCRIPTOR_ENV} may only be used with {TESTING_ENV}=1")
  with tempfile.TemporaryDirectory() as raw_dir:
    directory = pathlib.Path(raw_dir)
    fd = os.open(directory, os.O_RDONLY)
    try:
      class DirectoryHandle:
        def fileno(self) -> int:
          return fd

      _opened_regular_file_stat(DirectoryHandle(), directory / "native-katago-integration.md", "native integration doc")
    finally:
      os.close(fd)
  fail("opened descriptor self-test did not reject a directory descriptor")


_selftest_opened_descriptor_recheck()


doc = read(DOC, "native integration doc")
core_header = read(CORE_HEADER, "native core header")
core_impl = read(CORE_IMPL, "native core implementation")
engine = read(ENGINE, "native engine implementation")
native_service = read(NATIVE_SERVICE, "native Swift analysis service")
analysis = read(ANALYSIS, "KataGo analysis source")
asyncbot = read(ASYNCBOT, "KataGo AsyncBot header")
search = read(SEARCH, "KataGo Search header")
setup = read(SETUP, "KataGo setup header")
metal_backend = read(METAL_BACKEND, "KataGo Metal backend")

required_doc_tokens = [
  "Production Adapter Contract",
  "qixi::NativeKataGoEngine",
  "QixiNativeKataGoEngine.cpp",
  "Board::initHash",
  "ScoreValue::initTables",
  "ConfigParser",
  "Setup::initializeSession",
  "Setup::loadSingleParams",
  "Setup::initializeNNEvaluator",
  "NNEvaluator::spawnServerThreads",
  "AsyncBot",
  "Search::getAnalysisData",
  "Search::getAnalysisJson",
  "Search::getAverageTreeOwnership",
  "Search::getAverageAndStandardDeviationTreeOwnership",
  "EvalCacheTable",
  "must not use `MainCmds::analysis`",
  "must not use `MainCmds::gtp`",
  "spawned",
  "URLSession",
  "Python backend",
  "BoardHistory",
  "same stones but different previous move order",
  "parseNativeKataGoAnalysisRequestJSON",
  "NativeKataGoAnalysisRequest",
  "coreMLPackagePaths",
  "nextPlayer",
  "finalBoard",
  "NativeKataGoRules",
  "Chinese rules",
  "occupied-point moves",
  "suicide",
  "simple-ko recapture",
  "analyzeRequest(const NativeKataGoAnalysisRequest&)",
  "MCTS+NN average",
  "qixi::NativeKataGoEngine::unloadModel",
  "must not call `loadModel` for the next engine",
  "exportTombstoneToFile",
  "restoreTombstoneFromFile",
  "does not leave a b6/b18nbt/b28nbt model resident under",
  "Missing or empty restore sources",
  "call `NativeKataGoEngine::unloadModel`",
  "verify the opened descriptor",
  "Internal persistent-MCTS temporary files must never follow a symlink",
  "create its `.tmp` file exclusively",
  "flush that temporary",
]
for token in required_doc_tokens:
  if token not in doc:
    fail(f"native integration doc missing required contract token: {token}")

source_api_tokens = [
  (analysis, "Board::initHash"),
  (analysis, "ScoreValue::initTables"),
  (analysis, "Setup::initializeSession"),
  (analysis, "Setup::initializeNNEvaluator"),
  (analysis, "AsyncBot* bot = new AsyncBot"),
  (analysis, "EvalCacheTable"),
  (analysis, "search->getAnalysisJson"),
  (asyncbot, "class AsyncBot"),
  (asyncbot, "void setPosition(Player pla, const Board& board, const BoardHistory& history)"),
  (asyncbot, "Search* getSearchStopAndWait()"),
  (search, "void getAnalysisData"),
  (search, "bool getAnalysisJson"),
  (search, "std::vector<double> getAverageTreeOwnership"),
  (search, "getAverageAndStandardDeviationTreeOwnership"),
  (setup, "NNEvaluator* initializeNNEvaluator"),
  (setup, "SearchParams loadSingleParams"),
]
for text, token in source_api_tokens:
  if token not in text:
    fail(f"KataGo source no longer exposes expected native adapter API: {token}")

for token in (
  "struct NativeKataGoMove",
  "struct NativeKataGoAnalysisRequest",
  "struct NativeKataGoRules",
  "enum class NativeKataGoKoRule",
  "enum class NativeKataGoScoringRule",
  "enum class NativeKataGoTaxRule",
  "enum class NativeKataGoWhiteHandicapBonusRule",
  "NativeKataGoKoRule koRule = NativeKataGoKoRule::simple",
  "NativeKataGoScoringRule scoringRule = NativeKataGoScoringRule::area",
  "NativeKataGoTaxRule taxRule = NativeKataGoTaxRule::none",
  "NativeKataGoWhiteHandicapBonusRule whiteHandicapBonusRule = NativeKataGoWhiteHandicapBonusRule::n",
  "bool friendlyPassOk = true",
  "enum class NativeKataGoBoardPoint",
  "std::array<NativeKataGoBoardPoint, 19 * 19> finalBoard{}",
  "NativeKataGoRules rules",
  "NativeKataGoMoveColor nextPlayer = NativeKataGoMoveColor::black",
  "std::vector<std::string> coreMLPackagePaths",
  "virtual NativeKataGoResult unloadModel() = 0",
  "parseNativeKataGoAnalysisRequestJSON",
  "nativeKataGoChineseRules",
  "nativeKataGoOppositeColor",
  "nativeKataGoMoveColorCode",
  "nativeKataGoKoRuleCode",
  "nativeKataGoScoringRuleCode",
  "nativeKataGoTaxRuleCode",
  "nativeKataGoWhiteHandicapBonusRuleCode",
  "nativeKataGoPositionKeyMaterial",
  "virtual NativeKataGoResult analyzeRequest(const NativeKataGoAnalysisRequest& request)",
  "virtual NativeKataGoResult loadModel",
):
  if token not in core_header:
    fail(f"native engine interface missing required model lifecycle token: {token}")
if "virtual NativeKataGoResult analyzeRequestJSON" in core_header:
  fail("native engine adapter interface must receive parsed requests, not raw JSON")

for token in (
  "parseNativeAnalysisRequest",
  "parseRequestMovesArray",
  "parseRequestMoveObject",
  "nativeMoveHistoryLooksLegal",
  "applyNativeBoardMove",
  "nativeBoardPointsFromSnapshot",
  "nativeBoardGroupHasLiberty",
  "request.rules = chineseRules()",
  "valueIsJSONStringEqual(json, rulesStart, rulesEnd, \"Chinese\")",
  "nativeKataGoKoRuleCode(request.rules.koRule)",
  "NativeKataGoMoveColor::black",
  "NativeKataGoMoveColor::white",
  "request.nextPlayer",
  "nativeKataGoOppositeColor(request.moves.back().color)",
  "nativeKataGoMoveColorCode(request.nextPlayer)",
  "nativeKataGoPositionKeyMaterial(const NativeKataGoAnalysisRequest& request)",
  "readableNonEmptyDirectory",
  "config.coreMLPackagePaths",
  "engine->analyzeRequest(request)",
  "engine->unloadModel()",
  "clearLoadedEngineAfterTombstoneRestoreFailure",
  "clearLoadedEngineAfterTombstoneRestoreFailure(engine.get(), loadedEngineID)",
  "if(!unloadResult.ok())",
  "loadedEngineID = \"none\"",
  "engine->loadModel",
):
  if token not in core_impl:
    fail(f"native core missing required unload-before-load token: {token}")

for forbidden in (
  "BackendClient",
  "URLSession",
  "QIXI_BACKEND_URL",
  "http://",
  "127.0.0.1",
  "localhost",
):
  if forbidden in native_service:
    fail(f"native Swift service must not reference Mac-hosted bridge token: {forbidden}")

for token in (
  "coreMLPackagePaths: [String]",
  "coreMLPackagePaths: resolved.coreMLPackageURLs.map(\\.path)",
):
  if token not in native_service:
    fail(f"native Swift service must pass resolved CoreML package paths to the bridge: {token}")

for forbidden in (
  "MainCmds::analysis",
  "MainCmds::gtp",
  "popen(",
  "std::system",
  "system(",
  "NSTask",
  "Process(",
  "URLSession",
  "BackendClient",
  "QIXI_BACKEND_URL",
  "http://",
  "https://",
  "127.0.0.1",
  "localhost",
):
  if forbidden in engine:
    fail(f"native C++ adapter must not use process, GTP, or Mac-hosted bridge token: {forbidden}")

for token in (
  "#if QIXI_ENABLE_NATIVE_KATAGO",
  "qixiToKataGoRules",
  "Rules::KO_SIMPLE",
  "Rules::SCORING_AREA",
  "Rules::TAX_NONE",
  "Rules::WHB_N",
  "qixiBuildKataGoRoot",
  "BoardHistory history(board, initialPlayer, rules, 0)",
  "history.makeBoardMoveTolerant(board, moveLoc, movePlayer, false)",
  "root.history.moveHistory.size() == request.moves.size()",
  "search.setPositionForMCTSPersistence",
  "search.getAnalysisJson",
  "search.getAverageTreeOwnership",
  "qixiBuildAnalysisResponseJSON",
  "qixiMCTSTreeOwnershipJSON",
  "response[\"ownership\"] = qixiMCTSTreeOwnershipJSON(search)",
  "response[\"moves\"] = moves",
  "response[\"winrate\"]",
  "response[\"scoreMean\"]",
  "nativeKataGoPositionKeyMaterial(request)",
  "class LinkedNativeKataGoEngine final",
  "Board::initHash()",
  "ScoreValue::initTables()",
  "Setup::initializeNNEvaluator",
  "Setup::loadSingleParams",
  "qixiNativeKataGoConfigMap",
  "metalCoreMLPackagePathCount",
  "metalCoreMLPackagePath\" + std::to_string(i)",
  "qixiRequestSearchParams",
  "qixiLinkedTombstoneJSON",
  "qixiLinkedTombstoneMatchesLoadedConfig",
  "qixiPrepareInternalTombstoneTempPath",
  "qixiRequireAtomicTombstoneTargetPath",
  "qixiWriteNewRegularFileExclusively",
  "qixiFlushFileDescriptorToStorage",
  "O_RDONLY",
  "O_CREAT | O_EXCL",
  "O_NOFOLLOW",
  "F_FULLFSYNC",
  "fsync(fd)",
  "fstat(fd, &openedMetadata)",
  "openedMetadata.st_size",
  "label + \" is not a regular file",
  "opened-byte-count drift while reading",
  "byte count drift after writing",
  "EINTR",
  "Native KataGo raw persistent-MCTS export temporary path",
  "Native KataGo raw persistent-MCTS restore temporary path",
  "Native KataGo atomic-write target path",
  "Native KataGo atomic-write temporary path",
  "\"coreMLPackagePaths\"",
  "\"rootKeyMaterial\"",
  "\"persistentMCTS\"",
  "\"rootKey\"",
  "\"position\"",
  "std::make_unique<LinkedNativeKataGoEngine>()",
  "search->setPositionForMCTSPersistence",
  "search->runWholeSearch",
  "search->exportPersistentMCTS",
  "search->restorePersistentMCTSTombstone",
  "bot.setPosition(root.nextPlayer, root.board, root.history)",
  "bot.genMoveSynchronousAnalyze",
  "target must not be a symbolic link",
  "target must not be a directory-shaped artifact",
  "Native KataGo atomic-write payload exceeds",
):
  if token not in engine:
    fail(f"native C++ adapter scaffold missing required KataGo API token: {token}")

for token in (
  "loadCoreMLPackagePaths",
  "metalCoreMLPackagePathCount",
  "metalCoreMLPackagePath\" + to_string(i)",
  "findExplicitPreconvertedModelPackage",
  "Explicit Metal CoreML package paths were configured",
  "getPreconvertedModelCandidates",
  "hasCoreMLPackageExtension",
):
  if token not in metal_backend:
    fail(f"Metal backend missing explicit CoreML package path contract token: {token}")

for forbidden in (
  "history.clear(board, movePlayer, rules, history.encorePhase)",
  "Native KataGo tombstone export for linked engines is not implemented yet.",
  "Native KataGo tombstone restore for linked engines is not implemented yet.",
  "std::remove(path.c_str());\n    if(std::rename(tmpPath.c_str(), path.c_str()) != 0)",
):
  if forbidden in engine:
    fail(f"native linked adapter tombstone still contains placeholder diagnostic: {forbidden}")

if "class PlaceholderNativeKataGoEngine final" in engine:
  for token in (
    "#if !QIXI_ENABLE_NATIVE_KATAGO\nNativeKataGoResult libraryNotLinkedResult()",
    "#if !QIXI_ENABLE_NATIVE_KATAGO\nclass PlaceholderNativeKataGoEngine final",
    "Native KataGo is not linked into this build.",
    "NativeKataGoStatusCode::libraryNotLinked",
    "unloadModel()",
    "No native KataGo model is loaded.",
    "#if QIXI_ENABLE_NATIVE_KATAGO\n  return std::make_unique<LinkedNativeKataGoEngine>();\n#else",
    "std::make_unique<PlaceholderNativeKataGoEngine>()",
  ):
    if token not in engine:
      fail(f"development placeholder is present but missing explicit marker: {token}")

print("Native in-process contract preflight passed")
PY
