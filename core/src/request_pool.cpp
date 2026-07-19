#include "qixi/request_pool.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <set>
#include <sstream>
#include <thread>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// Model-switch timing: always on so device logs answer "what is slow?"
// Format: [qixi-switch] phase=... ms=... extra=...
// Also appends to $TMPDIR/qixi-switch-timing.log when TMPDIR is set (iOS sandbox).
static void qixiSwitchLog(const char* line) {
  std::fprintf(stderr, "%s\n", line);
  if(const char* tmp = std::getenv("TMPDIR")) {
    std::string path = std::string(tmp) + "qixi-switch-timing.log";
    if(FILE* f = std::fopen(path.c_str(), "a")) {
      std::fputs(line, f);
      std::fputc('\n', f);
      std::fclose(f);
    }
  }
}

#define QIXI_SWITCH_LOG(fmt, ...) \
  do { \
    char _qixi_switch_buf[768]; \
    std::snprintf(_qixi_switch_buf, sizeof(_qixi_switch_buf), "[qixi-switch] " fmt, ##__VA_ARGS__); \
    qixiSwitchLog(_qixi_switch_buf); \
  } while(0)

namespace qixi::core {
namespace {

// Product-facing cap for core-state files (export/import/checkpoint). Large enough
// for long analysis sessions; small enough to reduce double-buffer OOM risk on iPad.
constexpr uint64_t kMaxCoreStateBytes = 384ULL * 1024ULL * 1024ULL;
constexpr uint64_t kStoreBundleMagic = 0x51495849424E444CULL; // "QIXIBNDL"
constexpr uint32_t kStoreBundleVersion = 1;
constexpr uint32_t kMaxStoreBundleEntries = 256;
constexpr size_t kMaxStoreFilenameBytes = 128;
constexpr float kMinimumSupportedKomi = -150.0f;
constexpr float kMaximumSupportedKomi = 150.0f;
constexpr float kMaximumRepresentableWideRootNoise =
  static_cast<float>(std::numeric_limits<int32_t>::max()) / 10000.0f;

struct StoreBundleEntry {
  std::string filename;
  std::vector<uint8_t> bytes;
};

/// Persist a (path-only) store off the worker critical path.
/// Ownership is exclusive to this thread; never touch BackendWorker state from here.
void persistStoreInBackground(std::unique_ptr<MCTSStore> store, std::string path) {
  if(!store || path.empty())
    return;
  std::thread([store = std::move(store), path = std::move(path)]() mutable {
    std::string error;
    // Best-effort only: model switch must not wait on multi-hundred-MB serializes.
    (void)store->persistToFile(path, &error);
    store.reset();
  }).detach();
}

/// Destroy a huge MCTS tree off the worker critical path.
/// Freeing millions of nodes on the selectEngine thread was multi-second freezes.
void destroyStoreInBackground(std::unique_ptr<MCTSStore> store) {
  if(!store)
    return;
  std::thread([store = std::move(store)]() mutable {
    store.reset();
  }).detach();
}

std::string keyString(const AnalysisKey& key) {
  std::ostringstream out;
  out << key.gameId << ":"
      << modelIdToString(key.modelId) << ":"
      << key.rulesHash << ":"
      << key.komiKey << ":"
      << key.wideRootNoiseKey;
  return out.str();
}

bool readFile(
  const std::string& path,
  std::vector<uint8_t>& bytes,
  std::string& error,
  uint64_t maxBytes = kMaxCoreStateBytes
) {
  int flags = O_RDONLY;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
  flags |= O_NOFOLLOW;
#endif
  const int fd = open(path.c_str(), flags);
  if(fd < 0) {
    error = "could not open file for reading: " + path;
    return false;
  }
  struct stat metadata;
  if(fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0 ||
     static_cast<uint64_t>(metadata.st_size) > maxBytes) {
    close(fd);
    error = "file is not a bounded regular file: " + path;
    return false;
  }
  bytes.resize(static_cast<size_t>(metadata.st_size));
  size_t offset = 0;
  while(offset < bytes.size()) {
    const ssize_t count = read(fd, bytes.data() + offset, bytes.size() - offset);
    if(count < 0 && errno == EINTR)
      continue;
    if(count <= 0) {
      close(fd);
      error = "could not read complete file: " + path;
      return false;
    }
    offset += static_cast<size_t>(count);
  }
  if(close(fd) != 0) {
    error = "could not close file after reading: " + path;
    return false;
  }
  return true;
}

bool peekFilePrefix(
  const std::string& path,
  size_t maxPrefix,
  std::vector<uint8_t>& bytes,
  std::string& error,
  uint64_t maxFileBytes = kMaxCoreStateBytes
) {
  int flags = O_RDONLY;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
  flags |= O_NOFOLLOW;
#endif
  const int fd = open(path.c_str(), flags);
  if(fd < 0) {
    error = "could not open file for reading: " + path;
    return false;
  }
  struct stat metadata;
  if(fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0 ||
     static_cast<uint64_t>(metadata.st_size) > maxFileBytes) {
    close(fd);
    error = "file is not a bounded regular file: " + path;
    return false;
  }
  const size_t toRead = std::min(maxPrefix, static_cast<size_t>(metadata.st_size));
  bytes.resize(toRead);
  size_t offset = 0;
  while(offset < bytes.size()) {
    const ssize_t count = read(fd, bytes.data() + offset, bytes.size() - offset);
    if(count < 0 && errno == EINTR)
      continue;
    if(count <= 0) {
      close(fd);
      error = "could not peek file: " + path;
      return false;
    }
    offset += static_cast<size_t>(count);
  }
  if(close(fd) != 0) {
    error = "could not close file after peek: " + path;
    return false;
  }
  return true;
}

bool syncParentDirectory(const std::string& path, std::string& error) {
  std::filesystem::path parent = std::filesystem::path(path).parent_path();
  if(parent.empty())
    parent = ".";
  int flags = O_RDONLY;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
#ifdef O_DIRECTORY
  flags |= O_DIRECTORY;
#endif
#ifdef O_NOFOLLOW
  flags |= O_NOFOLLOW;
#endif
  const int fd = open(parent.string().c_str(), flags);
  if(fd < 0) {
    error = "could not open output parent directory for sync: " + parent.string();
    return false;
  }
  while(fsync(fd) != 0) {
    if(errno != EINTR) {
      close(fd);
      error = "could not sync output parent directory: " + parent.string();
      return false;
    }
  }
  if(close(fd) != 0) {
    error = "could not close output parent directory after sync: " + parent.string();
    return false;
  }
  return true;
}

bool writeFileAtomically(const std::string& path, const std::vector<uint8_t>& bytes, std::string& error) {
  if(bytes.size() > kMaxCoreStateBytes) {
    error = "output exceeds the core-state byte limit: " + path;
    return false;
  }
  const std::string temp = path + ".tmp";
  auto requireRegularOrMissing = [&](const std::string& candidate, bool removeRegular) {
    struct stat metadata;
    if(lstat(candidate.c_str(), &metadata) != 0)
      return errno == ENOENT;
    if(!S_ISREG(metadata.st_mode))
      return false;
    return !removeRegular || std::remove(candidate.c_str()) == 0;
  };
  if(!requireRegularOrMissing(path, false)) {
    error = "output target is not a regular file or is inaccessible: " + path;
    return false;
  }
  if(!requireRegularOrMissing(temp, true)) {
    error = "temporary output target is not a removable regular file: " + temp;
    return false;
  }

  int flags = O_WRONLY | O_CREAT | O_EXCL;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
  flags |= O_NOFOLLOW;
#endif
  int fd = open(temp.c_str(), flags, 0600);
  if(fd < 0) {
    error = "could not exclusively create temp file: " + temp;
    return false;
  }
  size_t offset = 0;
  while(offset < bytes.size()) {
    const ssize_t count = write(fd, bytes.data() + offset, bytes.size() - offset);
    if(count < 0 && errno == EINTR)
      continue;
    if(count <= 0) {
      close(fd);
      std::remove(temp.c_str());
      error = "could not write temp file: " + temp;
      return false;
    }
    offset += static_cast<size_t>(count);
  }
  while(fsync(fd) != 0) {
    if(errno != EINTR) {
      close(fd);
      std::remove(temp.c_str());
      error = "could not flush temp file: " + temp;
      return false;
    }
  }
  if(close(fd) != 0) {
    std::remove(temp.c_str());
    error = "could not close temp file: " + temp;
    return false;
  }
  if(!requireRegularOrMissing(path, false)) {
    std::remove(temp.c_str());
    error = "output target changed type before replacement: " + path;
    return false;
  }
  if(std::rename(temp.c_str(), path.c_str()) != 0) {
    error = "could not replace output file: " + path;
    std::remove(temp.c_str());
    return false;
  }
  return syncParentDirectory(path, error);
}

uint64_t bundleChecksum(const uint8_t* bytes, size_t size) {
  uint64_t hash = 1469598103934665603ULL;
  for(size_t i = 0; i < size; ++i) {
    hash ^= bytes[i];
    hash *= 1099511628211ULL;
  }
  return hash;
}

void appendU16(std::vector<uint8_t>& bytes, uint16_t value) {
  bytes.push_back(static_cast<uint8_t>(value & 0xffU));
  bytes.push_back(static_cast<uint8_t>((value >> 8) & 0xffU));
}

void appendU32(std::vector<uint8_t>& bytes, uint32_t value) {
  for(int shift = 0; shift < 32; shift += 8)
    bytes.push_back(static_cast<uint8_t>((value >> shift) & 0xffU));
}

void appendU64(std::vector<uint8_t>& bytes, uint64_t value) {
  for(int shift = 0; shift < 64; shift += 8)
    bytes.push_back(static_cast<uint8_t>((value >> shift) & 0xffULL));
}

bool readUnsigned(
  const std::vector<uint8_t>& bytes,
  size_t limit,
  size_t& offset,
  size_t count,
  uint64_t& value
) {
  if(count > 8 || offset > limit || count > limit - offset)
    return false;
  value = 0;
  for(size_t i = 0; i < count; ++i)
    value |= static_cast<uint64_t>(bytes[offset++]) << (8 * i);
  return true;
}

bool validStoreFilename(const std::string& filename) {
  return !filename.empty() && filename.size() <= kMaxStoreFilenameBytes &&
    filename.find('/') == std::string::npos && filename.find('\\') == std::string::npos &&
    std::filesystem::path(filename).filename().string() == filename &&
    std::filesystem::path(filename).extension() == ".qixi-core-store";
}

bool buildStoreBundle(
  const std::string& activeFilename,
  std::vector<StoreBundleEntry>& entries,
  std::vector<uint8_t>& bytes,
  std::string& error
) {
  if(!validStoreFilename(activeFilename) || entries.empty() ||
     entries.size() > kMaxStoreBundleEntries) {
    error = "store bundle has invalid active filename or entry count";
    return false;
  }
  bytes.clear();
  appendU64(bytes, kStoreBundleMagic);
  appendU32(bytes, kStoreBundleVersion);
  appendU16(bytes, static_cast<uint16_t>(activeFilename.size()));
  bytes.insert(bytes.end(), activeFilename.begin(), activeFilename.end());
  appendU32(bytes, static_cast<uint32_t>(entries.size()));
  bool foundActive = false;
  std::set<std::string> names;
  for(StoreBundleEntry& entry : entries) {
    if(!validStoreFilename(entry.filename) || entry.bytes.empty() ||
       !names.insert(entry.filename).second) {
      error = "store bundle contains an invalid or duplicate entry";
      return false;
    }
    foundActive = foundActive || entry.filename == activeFilename;
    const uint64_t projected = static_cast<uint64_t>(bytes.size()) + 2ULL +
      entry.filename.size() + 16ULL + entry.bytes.size() + 8ULL;
    if(projected > kMaxCoreStateBytes) {
      error = "store bundle exceeds the core-state byte limit";
      return false;
    }
    appendU16(bytes, static_cast<uint16_t>(entry.filename.size()));
    bytes.insert(bytes.end(), entry.filename.begin(), entry.filename.end());
    appendU64(bytes, entry.bytes.size());
    appendU64(bytes, bundleChecksum(entry.bytes.data(), entry.bytes.size()));
    bytes.insert(bytes.end(), entry.bytes.begin(), entry.bytes.end());
    std::vector<uint8_t>().swap(entry.bytes);
  }
  if(!foundActive) {
    error = "store bundle does not contain its active store";
    return false;
  }
  appendU64(bytes, bundleChecksum(bytes.data(), bytes.size()));
  return true;
}

bool parseStoreBundle(
  const std::vector<uint8_t>& bytes,
  std::string& activeFilename,
  std::vector<StoreBundleEntry>& entries,
  std::string& error
) {
  if(bytes.size() < 26 || bytes.size() > kMaxCoreStateBytes) {
    error = "store bundle has invalid byte count";
    return false;
  }
  const size_t payloadLimit = bytes.size() - 8;
  size_t checksumOffset = payloadLimit;
  uint64_t storedChecksum = 0;
  if(!readUnsigned(bytes, bytes.size(), checksumOffset, 8, storedChecksum) ||
     storedChecksum != bundleChecksum(bytes.data(), payloadLimit)) {
    error = "store bundle checksum mismatch";
    return false;
  }
  size_t offset = 0;
  uint64_t magic = 0;
  uint64_t version = 0;
  uint64_t activeLength = 0;
  uint64_t entryCount = 0;
  if(!readUnsigned(bytes, payloadLimit, offset, 8, magic) || magic != kStoreBundleMagic ||
     !readUnsigned(bytes, payloadLimit, offset, 4, version) || version != kStoreBundleVersion ||
     !readUnsigned(bytes, payloadLimit, offset, 2, activeLength) ||
     activeLength == 0 || activeLength > kMaxStoreFilenameBytes ||
     activeLength > payloadLimit - offset) {
    error = "store bundle header is invalid";
    return false;
  }
  activeFilename.assign(
    reinterpret_cast<const char*>(bytes.data() + offset), static_cast<size_t>(activeLength)
  );
  offset += static_cast<size_t>(activeLength);
  if(!validStoreFilename(activeFilename) ||
     !readUnsigned(bytes, payloadLimit, offset, 4, entryCount) ||
     entryCount == 0 || entryCount > kMaxStoreBundleEntries) {
    error = "store bundle active filename or entry count is invalid";
    return false;
  }
  entries.clear();
  entries.reserve(static_cast<size_t>(entryCount));
  std::set<std::string> names;
  bool foundActive = false;
  for(uint64_t i = 0; i < entryCount; ++i) {
    uint64_t nameLength = 0;
    uint64_t byteCount = 0;
    uint64_t entryChecksum = 0;
    if(!readUnsigned(bytes, payloadLimit, offset, 2, nameLength) ||
       nameLength == 0 || nameLength > kMaxStoreFilenameBytes ||
       nameLength > payloadLimit - offset) {
      error = "store bundle entry filename is truncated";
      return false;
    }
    StoreBundleEntry entry;
    entry.filename.assign(
      reinterpret_cast<const char*>(bytes.data() + offset), static_cast<size_t>(nameLength)
    );
    offset += static_cast<size_t>(nameLength);
    if(!validStoreFilename(entry.filename) || !names.insert(entry.filename).second ||
       !readUnsigned(bytes, payloadLimit, offset, 8, byteCount) || byteCount == 0 ||
       byteCount > kMaxCoreStateBytes ||
       !readUnsigned(bytes, payloadLimit, offset, 8, entryChecksum) ||
       byteCount > payloadLimit - offset) {
      error = "store bundle entry metadata is invalid";
      return false;
    }
    entry.bytes.assign(
      bytes.begin() + static_cast<std::ptrdiff_t>(offset),
      bytes.begin() + static_cast<std::ptrdiff_t>(offset + static_cast<size_t>(byteCount))
    );
    offset += static_cast<size_t>(byteCount);
    if(entryChecksum != bundleChecksum(entry.bytes.data(), entry.bytes.size())) {
      error = "store bundle entry checksum mismatch";
      return false;
    }
    foundActive = foundActive || entry.filename == activeFilename;
    entries.push_back(std::move(entry));
  }
  if(offset != payloadLimit || !foundActive) {
    error = "store bundle has trailing bytes or no active entry";
    return false;
  }
  return true;
}

bool hasStoreBundleMagic(const std::vector<uint8_t>& bytes) {
  size_t offset = 0;
  uint64_t magic = 0;
  return readUnsigned(bytes, bytes.size(), offset, 8, magic) && magic == kStoreBundleMagic;
}

AnalysisKey makeKey(GameId gameId, ModelId modelId, const Rules& rules, int32_t noiseKey) {
  AnalysisKey key;
  key.gameId = gameId;
  key.modelId = modelId;
  key.rulesHash = hashRules(rules);
  key.komiKey = komiToKey(rules.komi);
  key.wideRootNoiseKey = noiseKey;
  return key;
}

uint64_t stableStringHash(const std::string& value) {
  uint64_t hash = 1469598103934665603ULL;
  for(unsigned char byte : value) {
    hash ^= byte;
    hash *= 1099511628211ULL;
  }
  return hash;
}

} // namespace

BackendWorker::BackendWorker(ResultCallback cb) : callback(std::move(cb)) {
  ctx.params.seed = 0x517869ULL;
  Rules rules;
  ctx.currentKey = makeKey(ctx.nextGameId++, ModelId::none, rules, wideRootNoiseToKey(ctx.params.rootNoise));
}

BackendWorker::~BackendWorker() {
  stop();
}

void BackendWorker::start() {
  std::lock_guard<std::mutex> lock(queueMutex);
  if(worker.joinable())
    return;
  stopping = false;
  worker = std::thread([this]() { workerLoop(); });
}

void BackendWorker::stop() {
  {
    std::lock_guard<std::mutex> lock(queueMutex);
    stopping = true;
  }
  queueCondition.notify_all();
  if(worker.joinable())
    worker.join();
}

BackendWorker::PendingRequest BackendWorker::makePendingRequest(
  RequestKind kind,
  RequestPayload payload,
  BackendEpoch expectedEpoch,
  std::shared_ptr<std::promise<BackendResult>> completion
) {
  PendingRequest pending;
  pending.request.id = nextRequestId++;
  pending.request.seq = nextRequestSeq++;
  pending.request.kind = kind;
  pending.request.payload = std::move(payload);
  pending.request.expectedBackendEpoch = expectedEpoch;
  pending.completion = std::move(completion);
  return pending;
}

BackendResult BackendWorker::queueFullResult(RequestId requestId) const {
  std::lock_guard<std::mutex> stateLock(stateMutex);
  BackendResult result;
  result.requestId = requestId;
  result.backendEpoch = ctx.backendEpoch;
  result.revision = ctx.revision;
  result.ok = false;
  result.message = "request queue is full";
  result.currentRoot = ctx.store ? ctx.store->currentRoot() : kInvalidNode;
  result.engineState = ctx.engineState;
  result.storeState = ctx.storeState;
  return result;
}

RequestId BackendWorker::submit(RequestKind kind, RequestPayload payload, BackendEpoch expectedEpoch) {
  RequestId requestId = 0;
  bool full = false;
  {
    std::lock_guard<std::mutex> lock(queueMutex);
    PendingRequest pending = makePendingRequest(kind, std::move(payload), expectedEpoch, nullptr);
    requestId = pending.request.id;
    if(queue.size() >= kRequestQueueMaxDepth) {
      full = true;
    }
    else {
      queue.push_back(std::move(pending));
      fifoPendingCount.store(static_cast<uint32_t>(queue.size()), std::memory_order_release);
    }
  }
  if(full) {
    publish(queueFullResult(requestId));
    return requestId;
  }
  queueCondition.notify_one();
  return requestId;
}

BackendResult BackendWorker::submitAndWait(
  RequestKind kind,
  RequestPayload payload,
  BackendEpoch expectedEpoch
) {
  start();
  const auto tSubmit = std::chrono::steady_clock::now();
  auto completion = std::make_shared<std::promise<BackendResult>>();
  std::future<BackendResult> future = completion->get_future();
  RequestId requestId = 0;
  bool full = false;
  size_t queueDepth = 0;
  {
    std::lock_guard<std::mutex> lock(queueMutex);
    PendingRequest pending = makePendingRequest(kind, std::move(payload), expectedEpoch, completion);
    requestId = pending.request.id;
    if(queue.size() >= kRequestQueueMaxDepth)
      full = true;
    else {
      queue.push_back(std::move(pending));
      queueDepth = queue.size();
      fifoPendingCount.store(static_cast<uint32_t>(queue.size()), std::memory_order_release);
    }
  }
  if(full)
    return queueFullResult(requestId);
  queueCondition.notify_one();
  BackendResult result = future.get();
  if(kind == RequestKind::selectEngine) {
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - tSubmit
    ).count();
    QIXI_SWITCH_LOG(
      "submitAndWait_selectEngine total_ms=%lld queue_depth_at_submit=%zu",
      static_cast<long long>(ms),
      queueDepth
    );
    // Append timing to message so Swift diagnostics can surface it.
    result.message += " | wall_ms=" + std::to_string(ms) +
      " queue_depth=" + std::to_string(queueDepth);
  }
  return result;
}

BackendResult BackendWorker::executeForTests(RequestKind kind, RequestPayload payload, BackendEpoch expectedEpoch) {
  FrontendRequest request;
  {
    std::lock_guard<std::mutex> queueLock(queueMutex);
    request.id = nextRequestId++;
    request.seq = nextRequestSeq++;
  }
  request.kind = kind;
  request.payload = std::move(payload);
  request.expectedBackendEpoch = expectedEpoch;
  std::lock_guard<std::mutex> stateLock(stateMutex);
  return executeRequest(request);
}

void BackendWorker::setIoProgress(
  bool active,
  const std::string& phase,
  double fraction,
  uint64_t unitsDone,
  uint64_t unitsTotal,
  const std::string& message
) {
  // Atomically publish units first (UI lock-free path), then rare string under mutex.
  ioActive.store(active ? 1 : 0, std::memory_order_release);
  ioUnitsDone.store(unitsDone, std::memory_order_relaxed);
  ioUnitsTotal.store(unitsTotal, std::memory_order_relaxed);
  const uint32_t millis = static_cast<uint32_t>(
    std::max(0.0, std::min(1.0, fraction)) * 1000.0 + 0.5
  );
  ioFractionMillis.store(millis, std::memory_order_relaxed);
  std::lock_guard<std::mutex> lock(ioProgressMutex);
  ioProgress.active = active;
  ioProgress.phase = phase;
  ioProgress.fraction = std::max(0.0, std::min(1.0, fraction));
  ioProgress.unitsDone = unitsDone;
  ioProgress.unitsTotal = unitsTotal;
  ioProgress.bytesDone = unitsDone;
  ioProgress.bytesTotal = unitsTotal;
  ioProgress.message = message;
}

void BackendWorker::clearIoProgress() {
  setIoProgress(false, "", 0.0, 0, 0, "");
}

BackendWorker::IoProgress BackendWorker::currentIoProgress() const {
  // Prefer atomics so UI never waits on I/O critical section.
  IoProgress snap;
  snap.active = ioActive.load(std::memory_order_acquire) != 0;
  snap.unitsDone = ioUnitsDone.load(std::memory_order_relaxed);
  snap.unitsTotal = ioUnitsTotal.load(std::memory_order_relaxed);
  snap.bytesDone = snap.unitsDone;
  snap.bytesTotal = snap.unitsTotal;
  snap.fraction = static_cast<double>(ioFractionMillis.load(std::memory_order_relaxed)) / 1000.0;
  {
    std::lock_guard<std::mutex> lock(ioProgressMutex);
    snap.phase = ioProgress.phase;
    snap.message = ioProgress.message;
    if(snap.unitsTotal == 0 && ioProgress.unitsTotal > 0) {
      snap.unitsDone = ioProgress.unitsDone;
      snap.unitsTotal = ioProgress.unitsTotal;
      snap.bytesDone = ioProgress.bytesDone;
      snap.bytesTotal = ioProgress.bytesTotal;
    }
  }
  return snap;
}

void BackendWorker::publishAnalyzeDisplayLocked() {
  // Caller owns store mutation (stateMutex or sole worker). Reader never takes locks.
  AnalyzeDisplayPayload payload{};
  payload.backendEpoch = ctx.backendEpoch;
  payload.revision = ctx.revision;
  // Always publish the live root when the store is resident so Plane B settlement /
  // UI root gating can observe nav without requiring a ready NN. Analysis numbers
  // (candidates / ownership / visits) only fill while the engine is ready.
  if(ctx.store && ctx.storeState == StoreState::ready) {
    const NodeId liveRoot = ctx.store->currentRoot();
    payload.root = liveRoot;
    if(ctx.engineState == EngineState::ready && ctx.evaluator != nullptr) {
      // Ownership is 361 floats (~1.4KB). Candidates need every publish; ownership can
      // refresh ~10 Hz. Carry forward previous buffer ownership so the UI heatmap does not flicker.
      // Always refresh ownership when the root changes so territory is not blank after nav.
      const uint32_t readIndex = analyzeDisplayIndex.load(std::memory_order_relaxed) & 1u;
      const AnalyzeDisplayPayload& prev = analyzeDisplayBuffers[readIndex];
      analyzeOwnershipPublishCounter += 1;
      const bool rootChanged = !prev.hasOwnership || prev.root != liveRoot;
      const bool refreshOwnership = rootChanged || (analyzeOwnershipPublishCounter % 12u) == 1u;
      ctx.store->fillAnalyzeDisplay(payload, kAnalyzeDisplayMaxCandidates, refreshOwnership);
      payload.root = liveRoot;
      if(!refreshOwnership && prev.hasOwnership && prev.root == payload.root) {
        std::memcpy(payload.ownership, prev.ownership, sizeof(payload.ownership));
        payload.hasOwnership = 1;
      }
    }
  }
  payload.backendEpoch = ctx.backendEpoch;
  payload.revision = ctx.revision;

  const uint32_t writeIndex = 1u - analyzeDisplayIndex.load(std::memory_order_relaxed);
  analyzeDisplaySeq.fetch_add(1, std::memory_order_release); // odd = writing
  analyzeDisplayBuffers[writeIndex] = payload;
  analyzeDisplayIndex.store(writeIndex, std::memory_order_release);
  analyzeDisplayRevision.store(payload.revision, std::memory_order_release);
  analyzeDisplaySeq.fetch_add(1, std::memory_order_release); // even = stable
}

uint64_t BackendWorker::publishedAnalyzeRevision() const noexcept {
  return analyzeDisplayRevision.load(std::memory_order_acquire);
}

bool BackendWorker::tryLoadAnalyzeDisplay(AnalyzeDisplayPayload& out) const noexcept {
  for(int attempt = 0; attempt < 4; ++attempt) {
    const uint64_t seq1 = analyzeDisplaySeq.load(std::memory_order_acquire);
    if(seq1 & 1ull)
      continue; // writer in progress
    const uint32_t index = analyzeDisplayIndex.load(std::memory_order_acquire);
    out = analyzeDisplayBuffers[index & 1u];
    const uint64_t seq2 = analyzeDisplaySeq.load(std::memory_order_acquire);
    if(seq1 == seq2 && (seq2 & 1ull) == 0)
      return out.revision != 0 || out.root != kInvalidNode || out.candidateCount > 0 ||
             analyzeDisplayRevision.load(std::memory_order_relaxed) != 0;
  }
  return false;
}

bool BackendWorker::postNavIntent(NavIntent intent) noexcept {
  if(intent.kind == NavIntentKind::none)
    return false;
  // Serialize writers: seqlock is single-writer. Concurrent posts from multiple
  // Swift Tasks must not tear navIntentSlot.
  std::lock_guard<std::mutex> writeLock(navIntentWriteMutex);
  // Seqlock latest-wins: UI never blocks; engine reads a stable copy.
  navIntentSeq.fetch_add(1, std::memory_order_acq_rel); // odd = writing
  navIntentSlot = intent;
  const uint64_t published = navIntentSeq.fetch_add(1, std::memory_order_acq_rel) + 1; // even
  navIntentPublished.store(published, std::memory_order_release);
  queueCondition.notify_one();
  return true;
}

bool BackendWorker::drainNavIntent() {
  // Must be called with stateMutex held (or as sole store writer).
  const uint64_t published = navIntentPublished.load(std::memory_order_acquire);
  if(published == 0)
    return false;

  NavIntent intent{};
  bool got = false;
  for(int attempt = 0; attempt < 8; ++attempt) {
    const uint64_t seq1 = navIntentSeq.load(std::memory_order_acquire);
    if(seq1 & 1ull)
      continue;
    intent = navIntentSlot;
    const uint64_t seq2 = navIntentSeq.load(std::memory_order_acquire);
    if(seq1 == seq2 && (seq2 & 1ull) == 0) {
      got = true;
      break;
    }
  }
  if(!got || intent.kind == NavIntentKind::none)
    return false;

  // Hard OOM unload leaves store null — rehydrate before dropping the intent.
  // Previously CAS-cleared first, then returned false and the play was lost forever.
  if(!ctx.store || ctx.storeState != StoreState::ready) {
    std::string rehydrateError;
    (void)tryRehydrateStoreFromDisk(rehydrateError);
  }
  if(!ctx.store || ctx.storeState != StoreState::ready) {
    // Cannot apply: drop the intent so the worker does not busy-spin on a
    // permanently missing store. UI settlement times out and rolls back.
    uint64_t expectedPublished = published;
    (void)navIntentPublished.compare_exchange_strong(
      expectedPublished, 0ull, std::memory_order_acq_rel, std::memory_order_acquire
    );
    return false;
  }

  // Only clear if this is still the published intent. A newer postNavIntent bumps
  // published and must not be wiped by a stale drain of the previous slot.
  uint64_t expectedPublished = published;
  if(!navIntentPublished.compare_exchange_strong(
       expectedPublished, 0ull, std::memory_order_acq_rel, std::memory_order_acquire)) {
    return false;
  }

  bool applied = false;
  if(intent.kind == NavIntentKind::play) {
    PlayMoveCommit commit = ctx.store->playMoveFromRoot(static_cast<Move>(intent.moveOrNode));
    applied = commit.ok;
    // Intent map stores lineage hashes (same as FIFO handlePlayMove), never revision.
    if(applied && intent.uiIntentId != 0 && commit.node < ctx.store->nodeArray().size())
      ctx.committedIntentMap[intent.uiIntentId] = ctx.store->nodeArray()[commit.node].lineageHash;
  } else if(intent.kind == NavIntentKind::switchRoot) {
    std::string error;
    applied = ctx.store->switchRoot(intent.moveOrNode, &error);
    // Record switch intents so FIFO play/jump can resolve parentRoot=.intent(...)
    if(applied && intent.uiIntentId != 0 && ctx.store->currentRoot() < ctx.store->nodeArray().size())
      ctx.committedIntentMap[intent.uiIntentId] =
        ctx.store->nodeArray()[ctx.store->currentRoot()].lineageHash;
  }
  if(applied) {
    bumpRevision();
    publishAnalyzeDisplayLocked();
  }
  return applied;
}

BackendResult BackendWorker::latestSnapshot() const {
  // NEVER block on stateMutex for polls. Free search holds this mutex for entire
  // playout slices; a blocking lock here starves Swift's analysis actor, which then
  // cannot run setEngine → selectEngine is never enqueued → free search continues
  // forever (observed: wall≈36s, core begin only at +35s, engineSelector≈0.3s).
  std::unique_lock<std::mutex> lock(stateMutex, std::try_to_lock);
  if(!lock.owns_lock()) {
    BackendResult busy;
    busy.ok = true;
    busy.message = "snapshot busy";
    // epoch/revision 0 → UI apply path drops this frame without poisoning state.
    busy.currentRoot = kInvalidNode;
    return busy;
  }
  BackendResult result;
  result.requestId = 0;
  result.backendEpoch = ctx.backendEpoch;
  result.revision = ctx.revision;
  // Do not rehydrate on poll — OOM unload must stay free until a mutation.
  result.ok = true;
  result.engineState = ctx.engineState;
  result.storeState = ctx.storeState;
  if(ctx.store && ctx.storeState == StoreState::ready) {
    result.message = "snapshot copied";
    result.currentRoot = ctx.store->currentRoot();
    result.snapshot = ctx.store->snapshot();
  }
  else {
    result.message = "store not resident";
    result.currentRoot = kInvalidNode;
  }
  return result;
}

BackendResult BackendWorker::latestLightSnapshot(
  size_t maxCandidates,
  size_t maxVisibleNodes,
  bool includeOwnership
) const {
  // try_lock: structure polls must never wait behind free-search playouts.
  std::unique_lock<std::mutex> lock(stateMutex, std::try_to_lock);
  if(!lock.owns_lock()) {
    BackendResult busy;
    busy.ok = true;
    busy.message = "snapshot busy";
    busy.currentRoot = kInvalidNode;
    return busy;
  }
  BackendResult result;
  result.requestId = 0;
  result.backendEpoch = ctx.backendEpoch;
  result.revision = ctx.revision;
  // Do not rehydrate on poll — OOM unload must stay free until a mutation.
  result.ok = true;
  result.engineState = ctx.engineState;
  result.storeState = ctx.storeState;
  if(ctx.store && ctx.storeState == StoreState::ready) {
    result.message = "light snapshot copied";
    result.currentRoot = ctx.store->currentRoot();
    result.snapshot = ctx.store->snapshotLight(maxCandidates, maxVisibleNodes, includeOwnership);
  }
  else {
    result.message = "store not resident";
    result.currentRoot = kInvalidNode;
  }
  return result;
}

std::array<bool, kMoveCount> BackendWorker::legalMoveMask() const {
  std::lock_guard<std::mutex> lock(stateMutex);
  if(ctx.store && ctx.storeState == StoreState::ready)
    return ctx.store->legalMoveMask();
  std::array<bool, kMoveCount> empty{};
  return empty;
}

void BackendWorker::runSearchPlayouts(uint32_t count) {
  std::lock_guard<std::mutex> lock(stateMutex);
  if(count > 0 && ctx.store && ctx.storeState == StoreState::ready &&
     ctx.engineState == EngineState::ready && ctx.evaluator != nullptr) {
    bool changed = false;
    for(uint32_t i = 0; i < count; ++i)
      changed = ctx.store->runPlayout() || changed;
    if(changed) {
      bumpRevision();
      publishAnalyzeDisplayLocked();
    }
  }
}

void BackendWorker::drainForTests() {
  while(true) {
    PendingRequest pending;
    {
      std::lock_guard<std::mutex> lock(queueMutex);
      if(queue.empty())
        return;
      pending = std::move(queue.front());
      queue.pop_front();
    }
    BackendResult result;
    {
      std::lock_guard<std::mutex> stateLock(stateMutex);
      result = executeRequest(pending.request);
    }
    publish(result);
    if(pending.completion)
      pending.completion->set_value(result);
  }
}

void BackendWorker::setEvaluator(Evaluator* evaluator) {
  std::lock_guard<std::mutex> lock(stateMutex);
  ctx.evaluator = evaluator;
  if(ctx.store)
    ctx.store->setEvaluator(evaluator);
}

void BackendWorker::setEngineSelector(EngineSelector selector) {
  std::lock_guard<std::mutex> lock(stateMutex);
  engineSelector = std::move(selector);
}

bool BackendWorker::setStoreDirectory(const std::string& path, std::string* error) {
  std::lock_guard<std::mutex> lock(stateMutex);
  if(path.empty()) {
    if(error) *error = "store directory must not be empty";
    return false;
  }
  std::error_code filesystemError;
  std::filesystem::create_directories(path, filesystemError);
  if(filesystemError || !std::filesystem::is_directory(path)) {
    if(error) *error = "could not create store directory: " + path;
    return false;
  }
  ctx.storeDirectory = path;
  return true;
}

BackendEpoch BackendWorker::epoch() const {
  std::lock_guard<std::mutex> lock(stateMutex);
  return ctx.backendEpoch;
}

Revision BackendWorker::currentRevision() const {
  std::lock_guard<std::mutex> lock(stateMutex);
  return ctx.revision;
}

void BackendWorker::workerLoop() {
  using clock = std::chrono::steady_clock;
  // Publish HUD at most ~120 Hz. Running one playout + full display fill every
  // playout was the main reason analyze refresh felt far slower than 120 FPS.
  constexpr auto kDisplayPublishInterval = std::chrono::microseconds(8333);
  constexpr uint32_t kMaxPlayoutsPerSlice = 64;
  // After a move/jump, burst-search the new root so the first HUD frame has real
  // candidates within ~Lizzie-class latency (target <100 ms including first NN).
  auto burstSearchAfterNav = [&]() {
    if(!ctx.store || ctx.storeState != StoreState::ready ||
       ctx.engineState != EngineState::ready || ctx.evaluator == nullptr)
      return;
    publishAnalyzeDisplayLocked(); // new root id immediately (even with 0 visits)
    const auto burstStart = clock::now();
    constexpr auto kPostNavBurstBudget = std::chrono::milliseconds(70);
    uint32_t n = 0;
    while(n < 8u) {
      if(navIntentPublished.load(std::memory_order_relaxed) != 0)
        break;
      if(clock::now() - burstStart >= kPostNavBurstBudget)
        break;
      if(!ctx.store->runPlayout())
        break;
      ctx.revision += 1;
      n += 1;
      // Publish every playout so the UI can paint the first expanded root ASAP.
      publishAnalyzeDisplayLocked();
    }
  };

  while(true) {
    // Plane B: drain single-slot nav intents before FIFO bulk work / search.
    {
      std::lock_guard<std::mutex> stateLock(stateMutex);
      if(drainNavIntent()) {
        burstSearchAfterNav();
        continue;
      }
    }

    PendingRequest pending;
    bool hasRequest = false;
    {
      std::lock_guard<std::mutex> lock(queueMutex);
      if(stopping && queue.empty())
        return;
      if(!queue.empty()) {
        pending = std::move(queue.front());
        queue.pop_front();
        fifoPendingCount.store(static_cast<uint32_t>(queue.size()), std::memory_order_release);
        runningRequest = pending.request;
        hasRunningRequest = true;
        hasRequest = true;
      }
    }
    if(!hasRequest) {
      bool searched = false;
      {
        std::lock_guard<std::mutex> stateLock(stateMutex);
        // Prefer nav over search if something landed while we waited.
        if(drainNavIntent()) {
          burstSearchAfterNav();
          continue;
        }
        // Do not start free search when FIFO work is waiting (model switch, etc.).
        if(fifoPendingCount.load(std::memory_order_acquire) != 0) {
          // fall through to process queue next iteration
        } else if(ctx.store && ctx.storeState == StoreState::ready &&
           ctx.engineState == EngineState::ready && ctx.evaluator != nullptr) {
          // Run a short search slice, publish display.
          // Early phase (few root visits): publish every playout so the UI can show
          // 1, 2, 4… visits immediately — not a 1000+ jump after a blocked first paint.
          // Steady phase: batch playouts for ~8.3 ms, then publish once (~120 Hz).
          // Do not take queueMutex here (would risk lock order inversions).
          const auto sliceStart = clock::now();
          uint32_t playouts = 0;
          const NodeId liveRoot = ctx.store->currentRoot();
          const uint64_t visitsAtSliceStart =
            (liveRoot < ctx.store->nodeArray().size())
              ? static_cast<uint64_t>(ctx.store->nodeArray()[liveRoot].visits)
              : 0ull;
          // Treat a freshly navigated root as early for longer so post-move paints stay snappy.
          const bool earlyPhase = visitsAtSliceStart < 128ull;
          const uint32_t playoutCap = earlyPhase ? 8u : kMaxPlayoutsPerSlice;
          while(playouts < playoutCap) {
            if(navIntentPublished.load(std::memory_order_relaxed) != 0)
              break;
            // Abort mid-slice so selectEngine is not stuck behind expensive huge-tree playouts.
            if(fifoPendingCount.load(std::memory_order_relaxed) != 0)
              break;
            if(!ctx.store->runPlayout())
              break;
            ctx.revision += 1;
            searched = true;
            playouts += 1;
            if(earlyPhase) {
              // First visits: publish every playout for instant on-screen feedback.
              publishAnalyzeDisplayLocked();
            }
            if(clock::now() - sliceStart >= kDisplayPublishInterval)
              break;
          }
          if(searched && !earlyPhase)
            publishAnalyzeDisplayLocked();
        }
      }
      // Always drop stateMutex before looping. After a free-search slice, yield so
      // try_lock snapshot readers (and thus the Swift analysis actor) are not starved
      // by a tight re-acquire loop — that starvation blocked setEngine for ~30s+.
      if(searched)
        std::this_thread::yield();
      if(!searched) {
        std::unique_lock<std::mutex> lock(queueMutex);
        queueCondition.wait_for(
          lock,
          std::chrono::milliseconds(1),
          [&]() {
            return stopping || !queue.empty() ||
                   navIntentPublished.load(std::memory_order_acquire) != 0;
          }
        );
      }
      continue;
    }
    BackendResult result;
    {
      std::lock_guard<std::mutex> stateLock(stateMutex);
      result = executeRequest(pending.request);
    }
    publish(result);
    if(pending.completion)
      pending.completion->set_value(result);
    {
      std::lock_guard<std::mutex> lock(queueMutex);
      hasRunningRequest = false;
    }
  }
}

BackendResult BackendWorker::baseResult(const FrontendRequest& request, bool ok, const std::string& message) const {
  BackendResult result;
  result.requestId = request.id;
  result.backendEpoch = ctx.backendEpoch;
  result.revision = ctx.revision;
  result.ok = ok;
  result.message = message;
  result.currentRoot = ctx.store ? ctx.store->currentRoot() : kInvalidNode;
  result.engineState = ctx.engineState;
  result.storeState = ctx.storeState;
  return result;
}

void BackendWorker::publish(const BackendResult& result) const {
  if(callback)
    callback(result);
}

bool BackendWorker::tryRehydrateStoreFromDisk(std::string& error) {
  error.clear();
  if(ctx.store && ctx.storeState == StoreState::ready)
    return true;
  if(ctx.storeDirectory.empty()) {
    error = "store directory is not configured";
    return false;
  }
  auto loaded = loadActiveStore(error);
  if(!error.empty())
    return false;
  if(!loaded) {
    // Fall back to current analysis key file when the active index is missing.
    loaded = loadStore(ctx.currentKey, error);
    if(!error.empty())
      return false;
  }
  if(!loaded) {
    error = "no checkpointed store is available to rehydrate";
    return false;
  }
  ctx.store = std::make_unique<MCTSStore>(std::move(*loaded));
  ctx.currentKey = ctx.store->analysisKey();
  ctx.params = ctx.store->searchParams();
  ctx.store->setEvaluator(ctx.evaluator);
  ctx.storeState = StoreState::ready;
  return true;
}

bool BackendWorker::ensureStoreReady(BackendResult& result) {
  if(ctx.store && ctx.storeState == StoreState::ready)
    return true;
  // Product OOM path drops the live store after checkpoint. Mutations rehydrate
  // from disk; snapshot polls must not call this (see latestLightSnapshot).
  std::string error;
  if(tryRehydrateStoreFromDisk(error)) {
    bumpRevision();
    return true;
  }
  result.ok = false;
  result.message = error.empty() ? "store is not ready" : error;
  return false;
}

std::string BackendWorker::storePath(const AnalysisKey& analysisKey) const {
  if(ctx.storeDirectory.empty())
    return std::string();
  std::ostringstream filename;
  filename << std::hex << std::setw(16) << std::setfill('0')
           << stableStringHash(keyString(analysisKey)) << ".qixi-core-store";
  return (std::filesystem::path(ctx.storeDirectory) / filename.str()).string();
}

std::string BackendWorker::activeStorePath() const {
  if(ctx.storeDirectory.empty())
    return std::string();
  return (std::filesystem::path(ctx.storeDirectory) / "active-store.index").string();
}

bool BackendWorker::checkpointCurrentStore(std::string& error) {
  if(!ctx.store)
    return true;
  if(!ctx.store->validate(&error))
    return false;
  const std::string path = storePath(ctx.currentKey);
  if(path.empty())
    return true;
  // One-shot: single blob serialize+atomic write (no streaming, no per-node I/O).
  if(!ctx.store->persistToFile(path, &error))
    return false;
  const std::string filename = std::filesystem::path(path).filename().string();
  const std::vector<uint8_t> index(filename.begin(), filename.end());
  return writeFileAtomically(activeStorePath(), index, error);
}

std::optional<MCTSStore> BackendWorker::loadStore(const AnalysisKey& analysisKey, std::string& error) const {
  const std::string path = storePath(analysisKey);
  if(path.empty() || !std::filesystem::exists(path))
    return std::nullopt;
  // One-shot rehydrate: whole-file load, no streaming progress.
  auto loaded = MCTSStore::loadFromFile(path, kMaxCoreStateBytes, &error);
  if(loaded && !(loaded->analysisKey() == analysisKey)) {
    error = "store file analysis key does not match its requested key";
    return std::nullopt;
  }
  return loaded;
}

std::optional<MCTSStore> BackendWorker::loadActiveStore(std::string& error) const {
  const std::string indexPath = activeStorePath();
  if(indexPath.empty() || !std::filesystem::exists(indexPath))
    return std::nullopt;
  std::vector<uint8_t> indexBytes;
  if(!readFile(indexPath, indexBytes, error))
    return std::nullopt;
  if(indexBytes.empty() || indexBytes.size() > 128) {
    error = "active store index has invalid byte count";
    return std::nullopt;
  }
  const std::string filename(indexBytes.begin(), indexBytes.end());
  if(filename.find('/') != std::string::npos || filename.find('\\') != std::string::npos ||
     std::filesystem::path(filename).extension() != ".qixi-core-store") {
    error = "active store index contains an invalid filename";
    return std::nullopt;
  }
  const std::string path = (std::filesystem::path(ctx.storeDirectory) / filename).string();
  return MCTSStore::loadFromFile(path, kMaxCoreStateBytes, &error);
}

bool BackendWorker::prepareTargetStore(
  const AnalysisKey& analysisKey,
  const Rules& rules,
  const SearchParams& searchParams,
  std::unique_ptr<MCTSStore>& prepared,
  std::string& error
) const {
  error.clear();
  // Fast model switch:
  // 1) Reuse on-disk store for this model key as-is (no full visible-tree merge).
  // 2) Else clone only the current root path (O(ply)), not the entire visible tree.
  auto loaded = loadStore(analysisKey, error);
  // Missing on-disk store is normal for a fresh model/komi/noise key — not fatal.
  if(!loaded) {
    error.clear();
  }
  if(loaded) {
    prepared = std::make_unique<MCTSStore>(std::move(*loaded));
    // Align to the live game root when that lineage exists in the loaded tree.
    // If it does not (moves played under another model), KEEP the full loaded
    // store — do not replace it with a path clone from the other model, which
    // would wipe this model's visits/search state.
    if(ctx.store) {
      const uint64_t wantLineage = ctx.store->nodeArray().empty()
        ? 0
        : (ctx.store->currentRoot() < ctx.store->nodeArray().size()
             ? ctx.store->nodeArray()[ctx.store->currentRoot()].lineageHash
             : 0);
      if(wantLineage != 0) {
        if(const auto found = prepared->findVisibleNodeByLineage(wantLineage)) {
          std::string switchError;
          if(!prepared->switchRoot(*found, &switchError)) {
            // Keep store; root remains wherever the checkpoint had it.
          }
        }
      }
    }
    return true;
  }
  if(ctx.store) {
    MCTSStore clone = ctx.store->cloneCurrentRootPath(rules, analysisKey, searchParams, &error);
    if(!error.empty())
      return false;
    prepared = std::make_unique<MCTSStore>(std::move(clone));
    return true;
  }
  prepared = std::make_unique<MCTSStore>(MCTSStore::create(
    BoardLogic::emptyBoard(Color::black), rules, analysisKey, searchParams
  ));
  return true;
}

bool BackendWorker::resolveRootRef(const RootRef& reference, NodeId& node, std::string& error) const {
  if(reference.kind == RootRef::Kind::node) {
    if(reference.value > std::numeric_limits<NodeId>::max()) {
      error = "node root reference is out of range";
      return false;
    }
    node = static_cast<NodeId>(reference.value);
    return true;
  }
  uint64_t lineageHash = reference.value;
  if(reference.kind == RootRef::Kind::uiIntent) {
    const auto found = ctx.committedIntentMap.find(reference.value);
    if(found == ctx.committedIntentMap.end()) {
      error = "optimistic root reference is not committed";
      return false;
    }
    lineageHash = found->second;
  }
  if(!ctx.store) {
    error = "cannot resolve a lineage without an active store";
    return false;
  }
  const auto foundNode = ctx.store->findVisibleNodeByLineage(lineageHash);
  if(!foundNode) {
    error = "root lineage is absent from the active visible record";
    return false;
  }
  node = *foundNode;
  return true;
}

void BackendWorker::bumpRevision() {
  ctx.revision += 1;
  // Mutations / tests: publish immediately. Continuous search uses revision++ + one
  // publish per ~8.3ms slice in workerLoop (do not call this per playout there).
  publishAnalyzeDisplayLocked();
}

void BackendWorker::bumpEpoch() {
  ctx.backendEpoch += 1;
  ctx.revision += 1;
  publishAnalyzeDisplayLocked();
}

BackendResult BackendWorker::executeRequest(const FrontendRequest& request) {
  if(request.expectedBackendEpoch != 0 && request.expectedBackendEpoch != ctx.backendEpoch)
    return baseResult(request, false, "backend epoch mismatch");

  try {
    switch(request.kind) {
    case RequestKind::boot: return handleBoot(request, std::get<BootRequest>(request.payload));
    case RequestKind::configureICloud: return handleConfigureICloud(request, std::get<ConfigureICloudRequest>(request.payload));
    case RequestKind::importSGF: return handleImportSGF(request, std::get<ImportSGFRequest>(request.payload));
    case RequestKind::selectEngine: return handleSelectEngine(request, std::get<SelectEngineRequest>(request.payload));
    case RequestKind::exportAnalysisState: return handleExportAnalysisState(request, std::get<ExportAnalysisStateRequest>(request.payload));
    case RequestKind::enterBackground: return handleEnterBackground(request, std::get<EnterBackgroundRequest>(request.payload));
    case RequestKind::enterForeground: return handleEnterForeground(request, std::get<EnterForegroundRequest>(request.payload));
    case RequestKind::autosaveTick: return handleAutosaveTick(request, std::get<AutosaveTickRequest>(request.payload));
    case RequestKind::setKomi: return handleSetKomi(request, std::get<SetKomiRequest>(request.payload));
    case RequestKind::setWideRootNoise: return handleSetWideRootNoise(request, std::get<SetWideRootNoiseRequest>(request.payload));
    case RequestKind::newGame: return handleNewGame(request, std::get<NewGameRequest>(request.payload));
    case RequestKind::playMove: return handlePlayMove(request, std::get<PlayMoveRequest>(request.payload));
    case RequestKind::undo: return handleStep(request, std::get<StepRequest>(request.payload), false);
    case RequestKind::redo: return handleStep(request, std::get<StepRequest>(request.payload), true);
    case RequestKind::jumpToNode: return handleJumpToNode(request, std::get<JumpToNodeRequest>(request.payload));
    case RequestKind::jumpToLinePoint: return handleJumpToNode(request, std::get<JumpToNodeRequest>(request.payload));
    case RequestKind::setTerritoryMode: return handleSetTerritoryMode(request, std::get<SetTerritoryModeRequest>(request.payload));
    case RequestKind::importAnalysisState: return handleImportAnalysisState(request, std::get<ImportAnalysisStateRequest>(request.payload));
    case RequestKind::exportSGF: return handleExportSGF(request, std::get<ExportSGFRequest>(request.payload));
    case RequestKind::recognizePhoto: return handleRecognizePhoto(request, std::get<RecognizePhotoRequest>(request.payload));
    case RequestKind::applyRecognizedBoard: return handleApplyRecognizedBoard(request, std::get<ApplyRecognizedBoardRequest>(request.payload));
    case RequestKind::iCloudSyncNow: return handleICloudSyncNow(request, std::get<ICloudSyncNowRequest>(request.payload));
    case RequestKind::relieveMemoryPressure:
      return handleRelieveMemoryPressure(request, std::get<RelieveMemoryPressureRequest>(request.payload));
    }
  }
  catch(const std::exception& ex) {
    return baseResult(request, false, ex.what());
  }
  return baseResult(request, false, "unknown request kind");
}

BackendResult BackendWorker::handleBoot(const FrontendRequest& request, const BootRequest& payload) {
  if(!ctx.store) {
    std::string loadError;
    auto loaded = payload.loadLastState ? loadActiveStore(loadError) : std::nullopt;
    if(!loadError.empty())
      return baseResult(request, false, "could not load active store: " + loadError);
    if(loaded) {
      ctx.store = std::make_unique<MCTSStore>(std::move(*loaded));
      ctx.currentKey = ctx.store->analysisKey();
      ctx.params = ctx.store->searchParams();
      ctx.nextGameId = std::max(ctx.nextGameId, ctx.currentKey.gameId + 1);
    }
    else {
      Rules rules;
      BoardState board = BoardLogic::emptyBoard(Color::black);
      ctx.currentKey = makeKey(ctx.currentKey.gameId, ModelId::none, rules, wideRootNoiseToKey(ctx.params.rootNoise));
      ctx.store = std::make_unique<MCTSStore>(MCTSStore::create(board, rules, ctx.currentKey, ctx.params));
    }
    ctx.store->setEvaluator(ctx.evaluator);
    ctx.committedIntentMap.clear();
    ctx.storeState = StoreState::ready;
    ctx.engineState = EngineState::none;
    bumpRevision();
  }
  auto result = baseResult(request, true, "boot completed");
  result.snapshot = ctx.store->snapshot();
  return result;
}

BackendResult BackendWorker::handleConfigureICloud(const FrontendRequest& request, const ConfigureICloudRequest& payload) {
  (void)payload;
  return baseResult(request, true, "icloud configuration recorded by platform layer");
}

BackendResult BackendWorker::handleImportSGF(const FrontendRequest& request, const ImportSGFRequest& payload) {
  (void)payload;
  return baseResult(request, false, "SGF import requires the platform SGF adapter");
}

BackendResult BackendWorker::handleSelectEngine(const FrontendRequest& request, const SelectEngineRequest& payload) {
  // Model switch correctness:
  //   NEVER rekey another model's visit/Q/policy tree under a new modelId.
  //   That mixed b6/b18/b28 analysis on the HUD (critical accuracy bug).
  // Each model owns an isolated store: load its on-disk tree if present, else a
  // fresh path-clone of the board (O(ply), zero visits). Old store is persisted
  // and destroyed off the critical path so switch-back keeps per-model analysis.
  using clock = std::chrono::steady_clock;
  const auto t0 = clock::now();
  auto msSince = [&](clock::time_point t) -> long long {
    return std::chrono::duration_cast<std::chrono::milliseconds>(clock::now() - t).count();
  };

  // After hard OOM unload the store may be null — rehydrate the active game path first.
  long long rehydrateMs = 0;
  if(ctx.store == nullptr) {
    const auto t = clock::now();
    std::string rehydrateError;
    if(!tryRehydrateStoreFromDisk(rehydrateError) && !rehydrateError.empty()) {
      // Continue with empty board only when there is truly no checkpoint.
    }
    rehydrateMs = msSince(t);
  }

  uint64_t nodesBefore = 0;
  uint64_t actionsBefore = 0;
  uint64_t memBytesBefore = 0;
  if(ctx.store) {
    nodesBefore = ctx.store->nodeArray().size();
    actionsBefore = ctx.store->actionArray().size();
    const StoreMemoryStats mem = ctx.store->memoryStats();
    memBytesBefore = mem.estimatedArenaBytes;
  }
  QIXI_SWITCH_LOG(
    "begin model=%d nodes=%llu actions=%llu store_bytes=%llu rehydrate_ms=%lld",
    static_cast<int>(payload.modelId),
    static_cast<unsigned long long>(nodesBefore),
    static_cast<unsigned long long>(actionsBefore),
    static_cast<unsigned long long>(memBytesBefore),
    rehydrateMs
  );

  if(payload.modelId == ModelId::none) {
    const auto tUnload = clock::now();
    Evaluator* retainedEvaluator = nullptr;
    std::string selectionError;
    ctx.engineState = EngineState::unloading;
    if(engineSelector && !engineSelector(ModelId::none, retainedEvaluator, selectionError)) {
      ctx.evaluator = retainedEvaluator;
      if(ctx.store)
        ctx.store->setEvaluator(retainedEvaluator);
      ctx.engineState = retainedEvaluator != nullptr ? EngineState::ready : EngineState::offline;
      bumpEpoch();
      return baseResult(
        request,
        false,
        selectionError.empty() ? "engine unload failed" : selectionError
      );
    }
    ctx.evaluator = nullptr;
    if(ctx.store)
      ctx.store->setEvaluator(nullptr);
    ctx.engineState = EngineState::none;
    // Publish a blank analysis plane so the UI cannot keep painting the unloaded model.
    ctx.revision += 1;
    publishAnalyzeDisplayLocked();
    bumpEpoch();
    auto result = baseResult(request, true, "engine unloaded; active analysis retained");
    if(ctx.store)
      result.snapshot = ctx.store->snapshotLight(10, 1, false);
    QIXI_SWITCH_LOG("to_none engineSelector_ms=%lld total_ms=%lld", msSince(tUnload), msSince(t0));
    return result;
  }

  AnalysisKey targetKey = ctx.currentKey;
  targetKey.modelId = payload.modelId;
  // Same model id already on the live key → keep that model's tree (true reload / no-op path).
  const bool sameModelStore = ctx.store != nullptr &&
    ctx.storeState == StoreState::ready &&
    targetKey == ctx.currentKey;

  // Stop free search from using any NN while we swap stores / load weights.
  ctx.engineState = EngineState::loading;
  ctx.revision += 1;
  if(ctx.store)
    ctx.store->setEvaluator(nullptr);
  ctx.evaluator = nullptr;
  publishAnalyzeDisplayLocked();

  long long prepareMs = 0;
  // Model isolation: always prepare a target-model store when the live key differs.
  // This replaces the broken O(1) rekey that painted b28 visits as b18.
  if(!sameModelStore) {
    const auto t = clock::now();
    std::unique_ptr<MCTSStore> preparedStore;
    std::string preparationError;
    const Rules targetRules = ctx.store ? ctx.store->rules() : Rules{};
    const std::string targetKeyStr = keyString(targetKey);

    // 1) Prefer an in-memory parked store for this model (fast switch-back).
    // IMPORTANT: never discard a parked tree merely because the live lineage is
    // absent from that model (common after moves under a different engine). The
    // parked tree still holds that model's search state for jump-back / re-root.
    if(auto parked = parkedStoresByKey.find(targetKeyStr); parked != parkedStoresByKey.end()) {
      preparedStore = std::move(parked->second);
      parkedStoresByKey.erase(parked);
      // Best-effort align to live game root lineage when that node exists.
      if(ctx.store && preparedStore) {
        const uint64_t wantLineage = ctx.store->nodeArray().empty()
          ? 0
          : (ctx.store->currentRoot() < ctx.store->nodeArray().size()
               ? ctx.store->nodeArray()[ctx.store->currentRoot()].lineageHash
               : 0);
        if(wantLineage != 0) {
          if(const auto found = preparedStore->findVisibleNodeByLineage(wantLineage)) {
            std::string switchError;
            if(!preparedStore->switchRoot(*found, &switchError)) {
              // Keep the parked tree at its previous root; do not drop the park.
              QIXI_SWITCH_LOG(
                "store_park_root_align_failed model=%d err=%s",
                static_cast<int>(payload.modelId),
                switchError.c_str()
              );
            }
          } else {
            QIXI_SWITCH_LOG(
              "store_park_lineage_absent model=%d (keeping full parked tree)",
              static_cast<int>(payload.modelId)
            );
          }
        }
      }
      if(preparedStore) {
        QIXI_SWITCH_LOG("store_park_hit model=%d", static_cast<int>(payload.modelId));
      }
    }

    // 2) Disk / path-clone prepare when no usable park.
    if(!preparedStore) {
      if(!prepareTargetStore(targetKey, targetRules, ctx.params, preparedStore, preparationError))
        return baseResult(request, false, "could not prepare model-specific store: " + preparationError);
    }
    if(!preparedStore)
      return baseResult(request, false, "engine selection committed without a store");

    // Hand off the outgoing model's tree into the park (and async disk).
    auto outgoing = std::move(ctx.store);
    const AnalysisKey outgoingKey = ctx.currentKey;
    ctx.store = std::move(preparedStore);
    ctx.currentKey = targetKey;
    ctx.params = ctx.store->searchParams();
    ctx.storeState = StoreState::ready;
    ctx.store->setEvaluator(nullptr);
    // New store has renumbered NodeIds — clear intent map (ui intents are session-local).
    ctx.committedIntentMap.clear();

    if(outgoing && outgoingKey.modelId != ModelId::none) {
      outgoing->setEvaluator(nullptr);
      const std::string outKeyStr = keyString(outgoingKey);
      // Evict any older park for the same key (keep only the freshest).
      if(auto oldPark = parkedStoresByKey.find(outKeyStr); oldPark != parkedStoresByKey.end()) {
        destroyStoreInBackground(std::move(oldPark->second));
        parkedStoresByKey.erase(oldPark);
      }
      // Cap park size: product has ≤3 engines; never retain a fourth tree.
      while(parkedStoresByKey.size() >= 3) {
        auto it = parkedStoresByKey.begin();
        destroyStoreInBackground(std::move(it->second));
        parkedStoresByKey.erase(it);
      }
      // Keep the outgoing model's tree in RAM for correct switch-back, and always
      // attempt a durable disk image so cold rehydrate / park-miss can recover visits.
      // Without this write, only a stale pre-search checkpoint (or nothing) remains
      // on disk and switch-back after park eviction loses the entire tree.
      if(!ctx.storeDirectory.empty()) {
        const std::string path = storePath(outgoingKey);
        if(!path.empty()) {
          std::string persistError;
          if(!outgoing->persistToFile(path, &persistError)) {
            QIXI_SWITCH_LOG(
              "store_park_persist_failed model=%d err=%s",
              static_cast<int>(outgoingKey.modelId),
              persistError.c_str()
            );
          } else {
            // Keep active-store.index pointing at the live model after switch; the
            // parked file is still loadable via storePath(outgoingKey).
            QIXI_SWITCH_LOG(
              "store_park_persisted model=%d path=%s",
              static_cast<int>(outgoingKey.modelId),
              path.c_str()
            );
          }
        }
      }
      parkedStoresByKey[outKeyStr] = std::move(outgoing);
    } else if(outgoing) {
      destroyStoreInBackground(std::move(outgoing));
    }
    prepareMs = msSince(t);
    QIXI_SWITCH_LOG(
      "store_isolated model=%d prepare_ms=%lld parked=%zu",
      static_cast<int>(payload.modelId),
      prepareMs,
      parkedStoresByKey.size()
    );
  }

  Evaluator* selectedEvaluator = nullptr;
  std::string selectionError;
  long long engineSelectorMs = 0;
  if(engineSelector) {
    const auto t = clock::now();
    if(!engineSelector(payload.modelId, selectedEvaluator, selectionError)) {
      engineSelectorMs = msSince(t);
      QIXI_SWITCH_LOG("engineSelector FAILED ms=%lld err=%s", engineSelectorMs, selectionError.c_str());
      ctx.evaluator = selectedEvaluator;
      if(ctx.store)
        ctx.store->setEvaluator(selectedEvaluator);
      ctx.engineState = selectedEvaluator != nullptr ? EngineState::ready : EngineState::offline;
      bumpEpoch();
      return baseResult(
        request,
        false,
        selectionError.empty() ? "engine selection failed" : selectionError
      );
    }
    engineSelectorMs = msSince(t);
  }
  else {
    selectedEvaluator = ctx.evaluator;
  }
  if(selectedEvaluator == nullptr) {
    ctx.engineState = EngineState::offline;
    bumpEpoch();
    return baseResult(request, false, "selected engine did not provide an evaluator");
  }

  if(!ctx.store) {
    ctx.engineState = EngineState::offline;
    bumpEpoch();
    return baseResult(request, false, "engine selection committed without a store");
  }

  const auto tAttach = clock::now();
  // Store already carries targetKey.modelId from prepareTargetStore / sameModel path.
  // Do not rekey a foreign tree.
  ctx.currentKey = targetKey;
  if(ctx.store->analysisKey().modelId != payload.modelId)
    ctx.store->rekeyModelId(payload.modelId);
  ctx.params = ctx.store->searchParams();
  ctx.evaluator = selectedEvaluator;
  ctx.engineState = EngineState::ready;
  ctx.store->setEvaluator(selectedEvaluator);
  ctx.storeState = StoreState::ready;
  bumpEpoch();
  const long long rekeyMs = msSince(tAttach);

  // Fresh plane for this model only (path clone starts at 0 visits).
  publishAnalyzeDisplayLocked();
  const long long playoutMs = 0;

  const auto tSnap = clock::now();
  auto result = baseResult(request, true, "engine selection committed");
  result.snapshot = ctx.store->snapshotLight(10, 1, false);
  const long long snapMs = msSince(tSnap);
  const long long totalMs = msSince(t0);

  QIXI_SWITCH_LOG(
    "done model=%d nodes=%llu store_bytes=%llu prepare_ms=%lld engineSelector_ms=%lld "
    "rekey_ms=%lld playout_ms=%lld snapshot_ms=%lld total_ms=%lld isolated=%d",
    static_cast<int>(payload.modelId),
    static_cast<unsigned long long>(nodesBefore),
    static_cast<unsigned long long>(memBytesBefore),
    prepareMs,
    engineSelectorMs,
    rekeyMs,
    playoutMs,
    snapMs,
    totalMs,
    sameModelStore ? 0 : 1
  );
  result.message +=
    " | nodes=" + std::to_string(nodesBefore) +
    " store_MB=" + std::to_string(memBytesBefore / (1024ull * 1024ull)) +
    " prepare_ms=" + std::to_string(prepareMs) +
    " engineSelector_ms=" + std::to_string(engineSelectorMs) +
    " rekey_ms=" + std::to_string(rekeyMs) +
    " playout_ms=" + std::to_string(playoutMs) +
    " snapshot_ms=" + std::to_string(snapMs) +
    " isolated=" + std::to_string(sameModelStore ? 0 : 1) +
    " handle_ms=" + std::to_string(totalMs);
  return result;
}

BackendResult BackendWorker::handleExportAnalysisState(const FrontendRequest& request, const ExportAnalysisStateRequest& payload) {
  auto result = baseResult(request, true, "analysis state exported");
  if(!ensureStoreReady(result))
    return result;
  // Export ONLY the live store. Older multi-engine on-disk stores for the same game
  // can each be 100–250+ MB; bundling all of them made user-facing packages huge
  // after only a few analyzes on the current engine.
  // I/O: persistToFile streams with fopen("wb") + fwrite of the in-memory arenas
  // (no full intermediate vector, no re-read/re-serialize of every store file).
  std::string error;
  if(!checkpointCurrentStore(error))
    return baseResult(request, false, error);
  if(!ctx.store->persistToFile(payload.path, &error))
    return baseResult(request, false, error);
  return result;
}

BackendResult BackendWorker::handleEnterBackground(const FrontendRequest& request, const EnterBackgroundRequest& payload) {
  // Product policy: no background action. Regular MCTS backup is periodic autosave / OOM only.
  (void)payload;
  return baseResult(request, true, "enterBackground ignored (no lifecycle checkpoint)");
}

BackendResult BackendWorker::handleEnterForeground(const FrontendRequest& request, const EnterForegroundRequest& payload) {
  // Product policy: no foreground restore of previous session state.
  (void)payload;
  return baseResult(request, true, "enterForeground ignored (no lifecycle restore)");
}

BackendResult BackendWorker::handleAutosaveTick(const FrontendRequest& request, const AutosaveTickRequest& payload) {
  (void)payload;
  std::string error;
  if(!checkpointCurrentStore(error))
    return baseResult(request, false, error);
  return baseResult(request, true, "autosave completed");
}

BackendResult BackendWorker::handleSetKomi(const FrontendRequest& request, const SetKomiRequest& payload) {
  if(!std::isfinite(payload.komi) || payload.komi < kMinimumSupportedKomi ||
     payload.komi > kMaximumSupportedKomi)
    return baseResult(request, false, "komi is outside the supported finite range");
  auto result = baseResult(request, true, "komi changed");
  if(!ensureStoreReady(result))
    return result;
  Rules rules = ctx.store->rules();
  const int32_t oldKey = komiToKey(rules.komi);
  const int32_t newKey = komiToKey(payload.komi);
  if(oldKey == newKey)
    return baseResult(request, true, "komi unchanged");
  std::string checkpointError;
  // Best-effort: do not refuse a komi change because a disk checkpoint failed.
  (void)checkpointCurrentStore(checkpointError);
  rules.komi = payload.komi;
  AnalysisKey targetKey = ctx.currentKey;
  targetKey.rulesHash = hashRules(rules);
  targetKey.komiKey = newKey;
  std::unique_ptr<MCTSStore> preparedStore;
  std::string preparationError;
  if(!prepareTargetStore(targetKey, rules, ctx.params, preparedStore, preparationError))
    return baseResult(request, false, "could not prepare komi-specific store: " + preparationError);
  ctx.store = std::move(preparedStore);
  ctx.currentKey = targetKey;
  ctx.params = ctx.store->searchParams();
  ctx.store->setEvaluator(ctx.evaluator);
  bumpEpoch();
  result = baseResult(request, true, "komi changed");
  result.snapshot = ctx.store->snapshot();
  return result;
}

BackendResult BackendWorker::handleSetWideRootNoise(const FrontendRequest& request, const SetWideRootNoiseRequest& payload) {
  if(!std::isfinite(payload.noise) || payload.noise < 0.0f ||
     payload.noise > kMaximumRepresentableWideRootNoise)
    return baseResult(request, false, "wide root noise is outside the supported finite range");
  auto result = baseResult(request, true, "wide root noise changed");
  if(!ensureStoreReady(result))
    return result;
  const int32_t newKey = wideRootNoiseToKey(payload.noise);
  if(ctx.currentKey.wideRootNoiseKey == newKey)
    return baseResult(request, true, "wide root noise unchanged");
  std::string checkpointError;
  // Best-effort: do not refuse a root-noise change because a disk checkpoint failed.
  (void)checkpointCurrentStore(checkpointError);
  SearchParams targetParams = ctx.params;
  targetParams.rootNoise = payload.noise;
  AnalysisKey targetKey = ctx.currentKey;
  targetKey.wideRootNoiseKey = newKey;
  std::unique_ptr<MCTSStore> preparedStore;
  std::string preparationError;
  if(!prepareTargetStore(
       targetKey, ctx.store->rules(), targetParams, preparedStore, preparationError
     ))
    return baseResult(request, false, "could not prepare noise-specific store: " + preparationError);
  ctx.store = std::move(preparedStore);
  ctx.currentKey = targetKey;
  ctx.params = ctx.store->searchParams();
  ctx.store->setEvaluator(ctx.evaluator);
  bumpEpoch();
  result = baseResult(request, true, "wide root noise changed");
  result.snapshot = ctx.store->snapshot();
  return result;
}

BackendResult BackendWorker::handleNewGame(const FrontendRequest& request, const NewGameRequest& payload) {
  if(!std::isfinite(payload.rules.komi) || payload.rules.komi < kMinimumSupportedKomi ||
     payload.rules.komi > kMaximumSupportedKomi ||
     (payload.nextPla != Color::black && payload.nextPla != Color::white))
    return baseResult(request, false, "new game rules or next player are invalid");
  // Best-effort only: refusing New on a failed checkpoint left the UI wiped while core
  // still held the old tree, so structure polls resurrected previous variations.
  std::string checkpointError;
  (void)checkpointCurrentStore(checkpointError);
  const GameId gameId = ctx.nextGameId++;
  ctx.currentKey = makeKey(gameId, ctx.currentKey.modelId, payload.rules, ctx.currentKey.wideRootNoiseKey);
  BoardState board = BoardLogic::emptyBoard(payload.nextPla);
  ctx.store = std::make_unique<MCTSStore>(MCTSStore::create(board, payload.rules, ctx.currentKey, ctx.params));
  ctx.store->setEvaluator(ctx.evaluator);
  ctx.committedIntentMap.clear();
  ctx.storeState = StoreState::ready;
  bumpEpoch();
  auto result = baseResult(request, true, "new game committed");
  result.snapshot = ctx.store->snapshot();
  return result;
}

BackendResult BackendWorker::handlePlayMove(const FrontendRequest& request, const PlayMoveRequest& payload) {
  auto result = baseResult(request, true, "move committed");
  if(!ensureStoreReady(result))
    return result;
  NodeId parent = kInvalidNode;
  std::string referenceError;
  if(!resolveRootRef(payload.parentRootRef, parent, referenceError))
    return baseResult(request, false, referenceError);
  if(parent != ctx.store->currentRoot()) {
    std::string error;
    if(!ctx.store->switchRoot(parent, &error))
      return baseResult(request, false, "could not switch to requested parent: " + error);
  }
  PlayMoveCommit commit = ctx.store->playMoveFromRoot(payload.move);
  if(!commit.ok)
    return baseResult(request, false, "defensive legality rejection: " + commit.error);
  // Never pollute the intent map with key 0 (sentinel / "no intent").
  if(payload.uiIntentId != 0)
    ctx.committedIntentMap[payload.uiIntentId] = ctx.store->nodeArray()[commit.node].lineageHash;
  bumpRevision();
  publishAnalyzeDisplayLocked();
  result = baseResult(request, true, "move committed");
  result.committedUiIntentId = payload.uiIntentId;
  result.hasCommittedUiIntent = payload.uiIntentId != 0;
  // Light snapshot only — full visible-tree snapshot freezes the worker for seconds.
  result.snapshot = ctx.store->snapshotLight(10, 512, true);
  return result;
}

BackendResult BackendWorker::handleStep(const FrontendRequest& request, const StepRequest& payload, bool forward) {
  auto result = baseResult(request, true, "root changed");
  if(!ensureStoreReady(result))
    return result;
  NodeId target = ctx.store->currentRoot();
  const auto& nodes = ctx.store->nodeArray();
  for(uint32_t i = 0; i < payload.steps; ++i) {
    if(!forward) {
      if(target >= nodes.size() || nodes[target].parent == kInvalidNode)
        break;
      target = nodes[target].parent;
    }
    else {
      // Prefer highest-visit action child (PV). Fall back to any child node of
      // target (played moves create children even when actions were missing).
      NodeId child = kInvalidNode;
      VisitCount bestVisits = 0;
      if(target < nodes.size()) {
        ActionId actionId = nodes[target].firstAction;
        uint32_t traversed = 0;
        const auto& actions = ctx.store->actionArray();
        while(actionId != kInvalidAction && traversed < nodes[target].actionCount) {
          if(actionId >= actions.size())
            break;
          const Action& action = actions[actionId];
          if(action.child != kInvalidNode &&
             (child == kInvalidNode || action.visits > bestVisits ||
              (action.visits == bestVisits && action.child < child))) {
            child = action.child;
            bestVisits = action.visits;
          }
          actionId = action.nextAction;
          traversed += 1;
        }
        if(child == kInvalidNode) {
          for(NodeId id = 0; id < nodes.size(); ++id) {
            if(nodes[id].parent != target)
              continue;
            const VisitCount visits = nodes[id].visits;
            if(child == kInvalidNode || visits > bestVisits ||
               (visits == bestVisits && id < child)) {
              child = id;
              bestVisits = visits;
            }
          }
        }
      }
      if(child == kInvalidNode)
        break;
      target = child;
    }
  }
  std::string error;
  if(!ctx.store->switchRoot(target, &error))
    return baseResult(request, false, error);
  bumpRevision();
  // Publish HUD immediately so UI can settle without waiting for JSON snapshot.
  publishAnalyzeDisplayLocked();
  result = baseResult(request, true, "root changed");
  // Cap tree nodes — full snapshot() walks every visible node + parent actions.
  result.snapshot = ctx.store->snapshotLight(10, 512, true);
  return result;
}

BackendResult BackendWorker::handleJumpToNode(const FrontendRequest& request, const JumpToNodeRequest& payload) {
  auto result = baseResult(request, true, "root changed");
  if(!ensureStoreReady(result))
    return result;
  NodeId target = kInvalidNode;
  std::string error;
  if(!resolveRootRef(payload.targetRootRef, target, error))
    return baseResult(request, false, error);
  if(!ctx.store->switchRoot(target, &error))
    return baseResult(request, false, error);
  bumpRevision();
  publishAnalyzeDisplayLocked();
  result = baseResult(request, true, "root changed");
  result.snapshot = ctx.store->snapshotLight(10, 512, true);
  return result;
}

BackendResult BackendWorker::handleSetTerritoryMode(const FrontendRequest& request, const SetTerritoryModeRequest& payload) {
  ctx.territoryEnabled = payload.enabled;
  auto result = baseResult(request, true, "territory mode changed");
  if(ctx.store)
    result.snapshot = ctx.store->snapshot();
  return result;
}

BackendResult BackendWorker::handleImportAnalysisState(const FrontendRequest& request, const ImportAnalysisStateRequest& payload) {
  // One-shot import: whole-file read(s) + at most one rekey serialize per store blob.
  // No streaming progress and no double-pass per-entry transcription.
  std::string error;

  std::vector<uint8_t> magicBytes;
  if(!peekFilePrefix(payload.path, 16, magicBytes, error))
    return baseResult(request, false, error);

  std::optional<MCTSStore> loaded;
  std::vector<StoreBundleEntry> bundleEntries;
  std::string activeFilename;
  GameId importedGameId = ctx.nextGameId;
  std::vector<uint8_t> bytes;
  if(hasStoreBundleMagic(magicBytes)) {
    if(!readFile(payload.path, bytes, error))
      return baseResult(request, false, error);
    if(!parseStoreBundle(bytes, activeFilename, bundleEntries, error))
      return baseResult(request, false, error);
    if(ctx.storeDirectory.empty())
      return baseResult(request, false, "cannot import a multi-store bundle without a store directory");
    std::vector<uint8_t>().swap(bytes);

    std::set<std::string> analysisKeys;
    GameId bundleGameId = 0;
    std::string importedActiveFilename;
    for(StoreBundleEntry& entry : bundleEntries) {
      const bool isActive = entry.filename == activeFilename;
      std::string decodeError;
      // Single deserialize of the whole entry blob (not node-by-node file I/O).
      auto decoded = MCTSStore::deserialize(entry.bytes, &decodeError);
      if(!decoded)
        return baseResult(request, false, "bundle store is invalid: " + decodeError);
      const std::string canonical = std::filesystem::path(storePath(decoded->analysisKey())).filename().string();
      if(canonical != entry.filename)
        return baseResult(request, false, "bundle store filename does not match its analysis key");
      if(bundleGameId == 0)
        bundleGameId = decoded->analysisKey().gameId;
      else if(decoded->analysisKey().gameId != bundleGameId)
        return baseResult(request, false, "bundle contains stores from multiple games");
      if(!analysisKeys.insert(keyString(decoded->analysisKey())).second)
        return baseResult(request, false, "bundle contains duplicate analysis keys");

      std::vector<uint8_t>().swap(entry.bytes);
      decoded->assignImportedGameId(importedGameId);
      entry.filename =
        std::filesystem::path(storePath(decoded->analysisKey())).filename().string();
      // One rekey serialize of the whole blob, then install with one write.
      entry.bytes = decoded->serialize();
      if(entry.bytes.empty())
        return baseResult(request, false, "imported bundle store exceeds the core-state byte limit");
      if(isActive) {
        importedActiveFilename = entry.filename;
        loaded = std::move(decoded);
      }
    }
    activeFilename = importedActiveFilename;
    if(!loaded)
      return baseResult(request, false, "bundle active store could not be decoded");
  }
  else {
    // Single-store: one-shot whole-file load (core-state.bin from a .qixi-mcts package).
    loaded = MCTSStore::loadFromFile(payload.path, kMaxCoreStateBytes, &error);
    if(!loaded)
      return baseResult(request, false, error.empty() ? "could not load core-state.bin" : error);
    // Pick a free game id so reopened archives never collide with on-disk CoreStores.
    if(!ctx.storeDirectory.empty()) {
      for(int attempt = 0; attempt < 10000; ++attempt) {
        loaded->assignImportedGameId(importedGameId);
        const std::string candidate = storePath(loaded->analysisKey());
        if(candidate.empty() || !std::filesystem::exists(candidate))
          break;
        importedGameId += 1;
      }
    } else {
      loaded->assignImportedGameId(importedGameId);
    }
    // One rekey serialize of the whole store blob (required because game id changes).
    bytes = loaded->serialize();
    if(bytes.empty())
      return baseResult(request, false, "imported store exceeds the core-state byte limit");
  }

  // Import *replaces* the live analysis store. The package may come from a different
  // model than the currently selected engine (open .qixi-mcts after analyzing on another
  // model is the common case). Swift re-selects the package engine after import.
  // Detach any live evaluator so free search cannot race the store swap.
  if(ctx.store)
    ctx.store->setEvaluator(nullptr);
  if(ctx.engineState == EngineState::ready || ctx.engineState == EngineState::loading)
    ctx.engineState = EngineState::offline;

  std::vector<std::string> bundleDestinations;
  std::string singleDestination;
  if(!bundleEntries.empty()) {
    bundleDestinations.reserve(bundleEntries.size());
    for(StoreBundleEntry& entry : bundleEntries) {
      const std::string destination =
        (std::filesystem::path(ctx.storeDirectory) / entry.filename).string();
      if(std::filesystem::exists(destination))
        return baseResult(request, false, "imported bundle game id collides with an existing store");
      bundleDestinations.push_back(destination);
    }
  }
  else if(!ctx.storeDirectory.empty()) {
    singleDestination = storePath(loaded->analysisKey());
    if(std::filesystem::exists(singleDestination))
      return baseResult(request, false, "imported game id collides with an existing store");
  }

  if(!checkpointCurrentStore(error))
    return baseResult(request, false, error.empty() ? "checkpoint before import failed" : error);

  if(!bundleEntries.empty()) {
    std::vector<std::string> installedPaths;
    installedPaths.reserve(bundleEntries.size());
    for(size_t i = 0; i < bundleEntries.size(); ++i) {
      StoreBundleEntry& entry = bundleEntries[i];
      const std::string& destination = bundleDestinations[i];
      if(!writeFileAtomically(destination, entry.bytes, error)) {
        for(const std::string& installed : installedPaths) {
          std::error_code removeError;
          std::filesystem::remove(installed, removeError);
        }
        return baseResult(request, false, "could not install bundled store: " + error);
      }
      installedPaths.push_back(destination);
      std::vector<uint8_t>().swap(entry.bytes);
    }
    const std::vector<uint8_t> index(activeFilename.begin(), activeFilename.end());
    if(!writeFileAtomically(activeStorePath(), index, error)) {
      for(const std::string& installed : installedPaths) {
        std::error_code removeError;
        std::filesystem::remove(installed, removeError);
      }
      return baseResult(request, false, "could not commit bundled active store: " + error);
    }
  }
  else if(!ctx.storeDirectory.empty()) {
    if(!writeFileAtomically(singleDestination, bytes, error))
      return baseResult(request, false, "could not install imported store: " + error);
    const std::string filename = std::filesystem::path(singleDestination).filename().string();
    const std::vector<uint8_t> index(filename.begin(), filename.end());
    if(!writeFileAtomically(activeStorePath(), index, error)) {
      std::error_code removeError;
      std::filesystem::remove(singleDestination, removeError);
      return baseResult(request, false, "could not commit imported active store: " + error);
    }
    std::vector<uint8_t>().swap(bytes);
  }
  ctx.store = std::make_unique<MCTSStore>(std::move(*loaded));
  ctx.currentKey = ctx.store->analysisKey();
  ctx.params = ctx.store->searchParams();
  ctx.nextGameId = importedGameId + 1;
  ctx.store->setEvaluator(ctx.evaluator);
  ctx.committedIntentMap.clear();
  ctx.storeState = StoreState::ready;
  bumpEpoch();
  auto result = baseResult(request, true, "analysis state imported");
  result.snapshot = ctx.store->snapshotLight(10, 4096, true);
  return result;
}

BackendResult BackendWorker::handleExportSGF(const FrontendRequest& request, const ExportSGFRequest& payload) {
  (void)payload;
  return baseResult(request, false, "SGF export requires the platform SGF adapter");
}

BackendResult BackendWorker::handleRecognizePhoto(const FrontendRequest& request, const RecognizePhotoRequest& payload) {
  (void)payload;
  return baseResult(request, false, "photo recognition requires the platform recognition adapter");
}

BackendResult BackendWorker::handleApplyRecognizedBoard(const FrontendRequest& request, const ApplyRecognizedBoardRequest& payload) {
  std::string checkpointError;
  if(!checkpointCurrentStore(checkpointError))
    return baseResult(request, false, checkpointError);
  BoardState board = payload.board;
  board.nextPla = payload.sideToMove;
  board.moves.clear();
  board.simpleKoPoint = -1;
  board.boardHashHistory.clear();
  board.boardHashHistory.push_back(BoardLogic::boardHash(board));
  board.situationHashHistory.clear();
  board.situationHashHistory.push_back(BoardLogic::situationHash(board));
  Rules rules = ctx.store ? ctx.store->rules() : Rules{};
  const GameId gameId = ctx.nextGameId++;
  ctx.currentKey = makeKey(gameId, ctx.currentKey.modelId, rules, ctx.currentKey.wideRootNoiseKey);
  ctx.store = std::make_unique<MCTSStore>(MCTSStore::create(board, rules, ctx.currentKey, ctx.params));
  ctx.store->setEvaluator(ctx.evaluator);
  ctx.committedIntentMap.clear();
  ctx.storeState = StoreState::ready;
  bumpEpoch();
  auto result = baseResult(request, true, "recognized board committed without synthetic history");
  result.snapshot = ctx.store->snapshot();
  return result;
}

BackendResult BackendWorker::handleICloudSyncNow(const FrontendRequest& request, const ICloudSyncNowRequest& payload) {
  (void)payload;
  std::string error;
  if(!checkpointCurrentStore(error))
    return baseResult(request, false, error);
  return baseResult(request, true, "icloud sync checkpoint prepared for platform layer");
}

BackendResult BackendWorker::handleRelieveMemoryPressure(
  const FrontendRequest& request,
  const RelieveMemoryPressureRequest& payload
) {
  // Soft (0): one-shot durable checkpoint; keep the live store.
  // Hard (1): one-shot checkpoint write, then drop the live store from RAM.
  // No streaming progress. Product Swift owns NN unload ordering.
  if(payload.level == 0) {
    std::string error;
    if(!checkpointCurrentStore(error))
      return baseResult(request, false, error.empty() ? "soft memory checkpoint failed" : error);
    auto result = baseResult(request, true, "memory pressure soft: store checkpointed");
    if(ctx.store)
      result.snapshot = ctx.store->snapshotLight(10, 4096, true);
    return result;
  }

  if(payload.level != 1)
    return baseResult(request, false, "unsupported relieveMemoryPressure level");

  if(!ctx.store) {
    auto result = baseResult(request, true, "memory pressure hard: store already not resident");
    return result;
  }
  if(ctx.storeDirectory.empty()) {
    return baseResult(
      request,
      false,
      "cannot unload store from RAM without a store directory (would lose analysis)"
    );
  }

  const StoreMemoryStats before = ctx.store->memoryStats();
  std::string error;
  // Direct one-time disk write of the whole store blob, then free RAM.
  if(!checkpointCurrentStore(error)) {
    return baseResult(
      request,
      false,
      error.empty() ? "hard memory unload aborted: checkpoint failed" : error
    );
  }

  ctx.store.reset();
  ctx.storeState = StoreState::empty;
  // Keep currentKey / intent map / engine identity; mutations rehydrate via one-shot loadFromFile.
  bumpRevision();

  std::ostringstream message;
  message << "memory pressure hard: store unloaded nodes=" << before.nodeCount
          << " actions=" << before.actionCount
          << " arenaBytes~=" << before.estimatedArenaBytes;
  return baseResult(request, true, message.str());
}

} // namespace qixi::core
