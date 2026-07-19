#pragma once

#include "qixi/mcts.hpp"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <future>
#include <map>
#include <mutex>
#include <thread>
#include <variant>

namespace qixi::core {

constexpr size_t kRequestQueueMaxDepth = 512;
constexpr size_t kMaxOptimisticPendingMoves = 128;
constexpr uint32_t kAutosaveIntervalSeconds = 1200;
constexpr uint32_t kSnapshotTargetFPS = 120;

enum class RequestKind : uint8_t {
  boot,
  configureICloud,
  importSGF,
  selectEngine,
  exportAnalysisState,
  enterBackground,
  enterForeground,
  autosaveTick,
  setKomi,
  setWideRootNoise,
  newGame,
  playMove,
  undo,
  redo,
  jumpToNode,
  jumpToLinePoint,
  setTerritoryMode,
  importAnalysisState,
  exportSGF,
  recognizePhoto,
  applyRecognizedBoard,
  iCloudSyncNow,
  /// Product OOM path: checkpoint active store then drop it from RAM (level hard).
  relieveMemoryPressure,
};

struct BootRequest { bool loadLastState = true; bool firstLaunch = false; };
struct ConfigureICloudRequest { bool enabled = false; std::string containerId; };
struct ImportSGFRequest { std::string sgfPath; };
struct SelectEngineRequest { ModelId modelId = ModelId::none; };
struct ExportAnalysisStateRequest { std::string path; };
struct EnterBackgroundRequest { uint32_t deadlineMs = 0; };
struct EnterForegroundRequest {};
struct AutosaveTickRequest { std::string reason; };
struct SetKomiRequest { float komi = 7.5f; };
struct SetWideRootNoiseRequest { float noise = 0.0f; };
struct NewGameRequest { Rules rules; Color nextPla = Color::black; };
struct PlayMoveRequest { Move move = kMovePass; UiIntentId uiIntentId = 0; RootRef parentRootRef = RootRef::nodeRef(0); };
struct StepRequest { uint32_t steps = 1; };
struct JumpToNodeRequest { RootRef targetRootRef = RootRef::nodeRef(kInvalidNode); };
struct SetTerritoryModeRequest { bool enabled = false; };
struct ImportAnalysisStateRequest { std::string path; };
struct ExportSGFRequest { std::string path; bool includeAnalysis = false; };
struct RecognizePhotoRequest { std::string imagePath; std::array<float, 8> cropQuad{}; };
struct ApplyRecognizedBoardRequest { BoardState board; Color sideToMove = Color::black; };
struct ICloudSyncNowRequest {};
/// level: 0 = soft (checkpoint only, keep store in RAM); 1 = hard (checkpoint + drop store).
struct RelieveMemoryPressureRequest { uint8_t level = 1; };

using RequestPayload = std::variant<
  BootRequest,
  ConfigureICloudRequest,
  ImportSGFRequest,
  SelectEngineRequest,
  ExportAnalysisStateRequest,
  EnterBackgroundRequest,
  EnterForegroundRequest,
  AutosaveTickRequest,
  SetKomiRequest,
  SetWideRootNoiseRequest,
  NewGameRequest,
  PlayMoveRequest,
  StepRequest,
  JumpToNodeRequest,
  SetTerritoryModeRequest,
  ImportAnalysisStateRequest,
  ExportSGFRequest,
  RecognizePhotoRequest,
  ApplyRecognizedBoardRequest,
  ICloudSyncNowRequest,
  RelieveMemoryPressureRequest
>;

struct FrontendRequest {
  RequestId id = 0;
  RequestSeq seq = 0;
  BackendEpoch expectedBackendEpoch = 0;
  RequestKind kind = RequestKind::boot;
  RequestPayload payload = BootRequest{};
};

struct BackendResult {
  RequestId requestId = 0;
  BackendEpoch backendEpoch = 0;
  Revision revision = 0;
  bool ok = false;
  std::string message;
  NodeId currentRoot = kInvalidNode;
  EngineState engineState = EngineState::none;
  StoreState storeState = StoreState::empty;
  UiIntentId committedUiIntentId = 0;
  bool hasCommittedUiIntent = false;
  std::optional<RootSnapshot> snapshot;
};

using ResultCallback = std::function<void(const BackendResult&)>;
using EngineSelector = std::function<bool(ModelId, Evaluator*&, std::string&)>;

class BackendWorker {
public:
  explicit BackendWorker(ResultCallback callback = nullptr);
  ~BackendWorker();

  RequestId submit(RequestKind kind, RequestPayload payload, BackendEpoch expectedEpoch);
  BackendResult submitAndWait(RequestKind kind, RequestPayload payload, BackendEpoch expectedEpoch);
  void start();
  void stop();
  void drainForTests();
  BackendResult executeForTests(RequestKind kind, RequestPayload payload, BackendEpoch expectedEpoch);
  BackendResult latestSnapshot() const;
  // High-frequency UI poll: bounded candidates / visible tree (see MCTSStore::snapshotLight).
  BackendResult latestLightSnapshot(
    size_t maxCandidates = 10,
    size_t maxVisibleNodes = 4096,
    bool includeOwnership = true
  ) const;
  std::array<bool, kMoveCount> legalMoveMask() const;
  void runSearchPlayouts(uint32_t count);

  // --- Plane A: lock-free analyze display (no mutex on read path) ---
  uint64_t publishedAnalyzeRevision() const noexcept;
  bool tryLoadAnalyzeDisplay(AnalyzeDisplayPayload& out) const noexcept;

  // --- Plane B: single-slot nav intent (not a FIFO queue; UI never locks) ---
  enum class NavIntentKind : uint8_t { none = 0, play = 1, switchRoot = 2 };
  struct NavIntent {
    NavIntentKind kind = NavIntentKind::none;
    UiIntentId uiIntentId = 0;
    uint32_t moveOrNode = kInvalidNode;
  };
  /// Post latest-wins intent. Returns false only if kind is none. Never blocks.
  bool postNavIntent(NavIntent intent) noexcept;
  /// Engine-side: apply pending nav if any (under state ownership). Returns true if applied.
  bool drainNavIntent();

  // Best-effort progress for long I/O jobs (export/import/checkpoint).
  // unitsDone/unitsTotal prefer semantic progress (nodes/actions); bytes remain available.
  struct IoProgress {
    bool active = false;
    std::string phase;       // e.g. "serializing", "writing", "reading", "parsing", "activating"
    double fraction = 0.0;   // 0..1 when known; otherwise 0 with active=true
    uint64_t unitsDone = 0;
    uint64_t unitsTotal = 0;
    // Aliases for older call sites (same storage as units*).
    uint64_t bytesDone = 0;
    uint64_t bytesTotal = 0;
    std::string message;
  };
  /// Lock-free progress snapshot for UI polling (atomics + best-effort phase string).
  IoProgress currentIoProgress() const;

  void setEvaluator(Evaluator* evaluator);
  void setEngineSelector(EngineSelector selector);
  bool setStoreDirectory(const std::string& path, std::string* error);
  BackendEpoch epoch() const;
  Revision currentRevision() const;

private:
  struct Context {
    BackendEpoch backendEpoch = 1;
    Revision revision = 0;
    GameId nextGameId = 1;
    AnalysisKey currentKey;
    EngineState engineState = EngineState::none;
    StoreState storeState = StoreState::empty;
    SearchState searchState = SearchState::stopped;
    SearchParams params;
    std::unique_ptr<MCTSStore> store;
    Evaluator* evaluator = nullptr;
    std::string storeDirectory;
    std::map<UiIntentId, uint64_t> committedIntentMap;
    bool territoryEnabled = false;
  };

  struct PendingRequest {
    FrontendRequest request;
    std::shared_ptr<std::promise<BackendResult>> completion;
  };

  mutable std::mutex queueMutex;
  mutable std::mutex stateMutex;
  mutable std::mutex ioProgressMutex;
  std::condition_variable queueCondition;
  std::deque<PendingRequest> queue;
  FrontendRequest runningRequest;
  bool hasRunningRequest = false;
  bool stopping = false;
  RequestId nextRequestId = 1;
  RequestSeq nextRequestSeq = 1;
  std::thread worker;
  ResultCallback callback;
  EngineSelector engineSelector;
  Context ctx;
  IoProgress ioProgress;
  /// Per-model stores parked on switch so b28↔b18 never reuses each other's visits,
  /// and a quick switch-back does not wait on async disk persist.
  std::map<std::string, std::unique_ptr<MCTSStore>> parkedStoresByKey;

  // Lock-free analyze display double-buffer (writer publishes under state ownership).
  mutable AnalyzeDisplayPayload analyzeDisplayBuffers[2]{};
  mutable std::atomic<uint32_t> analyzeDisplayIndex{0};
  mutable std::atomic<uint64_t> analyzeDisplayRevision{0};
  mutable std::atomic<uint64_t> analyzeDisplaySeq{0}; // even = stable
  /// Throttles full ownership copies on the HUD publish path (worker thread only).
  uint32_t analyzeOwnershipPublishCounter = 0;

  // Single-slot nav intent (latest wins).
  std::mutex navIntentWriteMutex;
  std::atomic<uint64_t> navIntentSeq{0};
  NavIntent navIntentSlot{};
  std::atomic<uint64_t> navIntentPublished{0};
  /// Non-zero while FIFO has work — free search aborts the slice so selectEngine starts ASAP.
  std::atomic<uint32_t> fifoPendingCount{0};

  // Atomic I/O progress (nearly free publish; UI reads without waiting on I/O work).
  std::atomic<uint64_t> ioUnitsDone{0};
  std::atomic<uint64_t> ioUnitsTotal{0};
  std::atomic<uint32_t> ioFractionMillis{0}; // fraction * 1000
  std::atomic<uint8_t> ioActive{0};
  // Phase string still under mutex for rare updates; UI primarily uses units.

  void setIoProgress(
    bool active,
    const std::string& phase,
    double fraction,
    uint64_t unitsDone = 0,
    uint64_t unitsTotal = 0,
    const std::string& message = {}
  );
  void clearIoProgress();
  void publishAnalyzeDisplayLocked();

  PendingRequest makePendingRequest(
    RequestKind kind,
    RequestPayload payload,
    BackendEpoch expectedEpoch,
    std::shared_ptr<std::promise<BackendResult>> completion
  );
  BackendResult queueFullResult(RequestId requestId) const;
  void workerLoop();
  BackendResult executeRequest(const FrontendRequest& request);
  BackendResult baseResult(const FrontendRequest& request, bool ok, const std::string& message) const;
  void publish(const BackendResult& result) const;
  bool ensureStoreReady(BackendResult& result);
  std::string storePath(const AnalysisKey& key) const;
  std::string activeStorePath() const;
  bool checkpointCurrentStore(std::string& error);
  std::optional<MCTSStore> loadStore(const AnalysisKey& key, std::string& error) const;
  std::optional<MCTSStore> loadActiveStore(std::string& error) const;
  bool prepareTargetStore(
    const AnalysisKey& key,
    const Rules& rules,
    const SearchParams& params,
    std::unique_ptr<MCTSStore>& prepared,
    std::string& error
  ) const;
  bool resolveRootRef(const RootRef& reference, NodeId& node, std::string& error) const;
  void bumpRevision();
  void bumpEpoch();

  BackendResult handleBoot(const FrontendRequest& request, const BootRequest& payload);
  BackendResult handleConfigureICloud(const FrontendRequest& request, const ConfigureICloudRequest& payload);
  BackendResult handleImportSGF(const FrontendRequest& request, const ImportSGFRequest& payload);
  BackendResult handleSelectEngine(const FrontendRequest& request, const SelectEngineRequest& payload);
  BackendResult handleExportAnalysisState(const FrontendRequest& request, const ExportAnalysisStateRequest& payload);
  BackendResult handleEnterBackground(const FrontendRequest& request, const EnterBackgroundRequest& payload);
  BackendResult handleEnterForeground(const FrontendRequest& request, const EnterForegroundRequest& payload);
  BackendResult handleAutosaveTick(const FrontendRequest& request, const AutosaveTickRequest& payload);
  BackendResult handleSetKomi(const FrontendRequest& request, const SetKomiRequest& payload);
  BackendResult handleSetWideRootNoise(const FrontendRequest& request, const SetWideRootNoiseRequest& payload);
  BackendResult handleNewGame(const FrontendRequest& request, const NewGameRequest& payload);
  BackendResult handlePlayMove(const FrontendRequest& request, const PlayMoveRequest& payload);
  BackendResult handleStep(const FrontendRequest& request, const StepRequest& payload, bool forward);
  BackendResult handleJumpToNode(const FrontendRequest& request, const JumpToNodeRequest& payload);
  BackendResult handleSetTerritoryMode(const FrontendRequest& request, const SetTerritoryModeRequest& payload);
  BackendResult handleImportAnalysisState(const FrontendRequest& request, const ImportAnalysisStateRequest& payload);
  BackendResult handleExportSGF(const FrontendRequest& request, const ExportSGFRequest& payload);
  BackendResult handleRecognizePhoto(const FrontendRequest& request, const RecognizePhotoRequest& payload);
  BackendResult handleApplyRecognizedBoard(const FrontendRequest& request, const ApplyRecognizedBoardRequest& payload);
  BackendResult handleICloudSyncNow(const FrontendRequest& request, const ICloudSyncNowRequest& payload);
  BackendResult handleRelieveMemoryPressure(
    const FrontendRequest& request,
    const RelieveMemoryPressureRequest& payload
  );
  /// After OOM drop: load active store from disk if present. Does not create an empty store.
  bool tryRehydrateStoreFromDisk(std::string& error);
};

} // namespace qixi::core
