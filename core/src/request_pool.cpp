#include "qixi/request_pool.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <set>
#include <sstream>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

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
  auto completion = std::make_shared<std::promise<BackendResult>>();
  std::future<BackendResult> future = completion->get_future();
  RequestId requestId = 0;
  bool full = false;
  {
    std::lock_guard<std::mutex> lock(queueMutex);
    PendingRequest pending = makePendingRequest(kind, std::move(payload), expectedEpoch, completion);
    requestId = pending.request.id;
    if(queue.size() >= kRequestQueueMaxDepth)
      full = true;
    else
      queue.push_back(std::move(pending));
  }
  if(full)
    return queueFullResult(requestId);
  queueCondition.notify_one();
  return future.get();
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
  uint64_t bytesDone,
  uint64_t bytesTotal,
  const std::string& message
) {
  std::lock_guard<std::mutex> lock(ioProgressMutex);
  ioProgress.active = active;
  ioProgress.phase = phase;
  ioProgress.fraction = std::max(0.0, std::min(1.0, fraction));
  ioProgress.bytesDone = bytesDone;
  ioProgress.bytesTotal = bytesTotal;
  ioProgress.message = message;
}

void BackendWorker::clearIoProgress() {
  setIoProgress(false, "", 0.0, 0, 0, "");
}

BackendWorker::IoProgress BackendWorker::currentIoProgress() const {
  std::lock_guard<std::mutex> lock(ioProgressMutex);
  return ioProgress;
}

BackendResult BackendWorker::latestSnapshot() const {
  std::lock_guard<std::mutex> lock(stateMutex);
  BackendResult result;
  result.requestId = 0;
  result.backendEpoch = ctx.backendEpoch;
  result.revision = ctx.revision;
  result.ok = ctx.store != nullptr && ctx.storeState == StoreState::ready;
  result.message = result.ok ? "snapshot copied" : "store is not ready";
  result.currentRoot = ctx.store ? ctx.store->currentRoot() : kInvalidNode;
  result.engineState = ctx.engineState;
  result.storeState = ctx.storeState;
  if(ctx.store)
    result.snapshot = ctx.store->snapshot();
  return result;
}

BackendResult BackendWorker::latestLightSnapshot(
  size_t maxCandidates,
  size_t maxVisibleNodes,
  bool includeOwnership
) const {
  std::lock_guard<std::mutex> lock(stateMutex);
  BackendResult result;
  result.requestId = 0;
  result.backendEpoch = ctx.backendEpoch;
  result.revision = ctx.revision;
  result.ok = ctx.store != nullptr && ctx.storeState == StoreState::ready;
  result.message = result.ok ? "light snapshot copied" : "store is not ready";
  result.currentRoot = ctx.store ? ctx.store->currentRoot() : kInvalidNode;
  result.engineState = ctx.engineState;
  result.storeState = ctx.storeState;
  if(ctx.store)
    result.snapshot = ctx.store->snapshotLight(maxCandidates, maxVisibleNodes, includeOwnership);
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
    if(changed)
      bumpRevision();
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
  while(true) {
    PendingRequest pending;
    bool hasRequest = false;
    {
      std::lock_guard<std::mutex> lock(queueMutex);
      if(stopping && queue.empty())
        return;
      if(!queue.empty()) {
        pending = std::move(queue.front());
        queue.pop_front();
        runningRequest = pending.request;
        hasRunningRequest = true;
        hasRequest = true;
      }
    }
    if(!hasRequest) {
      bool searched = false;
      {
        std::lock_guard<std::mutex> stateLock(stateMutex);
        if(ctx.store && ctx.storeState == StoreState::ready &&
           ctx.engineState == EngineState::ready && ctx.evaluator != nullptr &&
           ctx.store->runPlayout()) {
          bumpRevision();
          searched = true;
        }
      }
      if(!searched) {
        std::unique_lock<std::mutex> lock(queueMutex);
        queueCondition.wait_for(
          lock,
          std::chrono::milliseconds(1),
          [&]() { return stopping || !queue.empty(); }
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

bool BackendWorker::ensureStoreReady(BackendResult& result) {
  if(ctx.store && ctx.storeState == StoreState::ready)
    return true;
  result.ok = false;
  result.message = "store is not ready";
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
  const std::vector<uint8_t> bytes = ctx.store->serialize();
  if(bytes.empty()) {
    error = "serialized store exceeds the core-state byte limit";
    return false;
  }
  if(!writeFileAtomically(path, bytes, error))
    return false;
  const std::string filename = std::filesystem::path(path).filename().string();
  const std::vector<uint8_t> index(filename.begin(), filename.end());
  return writeFileAtomically(activeStorePath(), index, error);
}

std::optional<MCTSStore> BackendWorker::loadStore(const AnalysisKey& analysisKey, std::string& error) const {
  const std::string path = storePath(analysisKey);
  if(path.empty() || !std::filesystem::exists(path))
    return std::nullopt;
  // const method: progress updates go through mutable mutex (setIoProgress is non-const).
  // Use silent deserializeFromFile for const loads; boot path can call import with progress.
  auto loaded = MCTSStore::deserializeFromFile(path, kMaxCoreStateBytes, &error);
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
  return MCTSStore::deserializeFromFile(path, kMaxCoreStateBytes, &error);
}

bool BackendWorker::prepareTargetStore(
  const AnalysisKey& analysisKey,
  const Rules& rules,
  const SearchParams& searchParams,
  std::unique_ptr<MCTSStore>& prepared,
  std::string& error
) const {
  error.clear();
  auto loaded = loadStore(analysisKey, error);
  if(!error.empty())
    return false;
  if(loaded) {
    prepared = std::make_unique<MCTSStore>(std::move(*loaded));
    if(ctx.store && !prepared->mergeVisibleRecordFrom(*ctx.store, &error))
      return false;
    return true;
  }
  if(ctx.store) {
    MCTSStore clone = ctx.store->cloneVisibleRecord(rules, analysisKey, searchParams, &error);
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
}

void BackendWorker::bumpEpoch() {
  ctx.backendEpoch += 1;
  ctx.revision += 1;
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
  std::string checkpointError;
  if(!checkpointCurrentStore(checkpointError))
    return baseResult(request, false, checkpointError);

  if(payload.modelId == ModelId::none) {
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
    bumpEpoch();
    auto result = baseResult(request, true, "engine unloaded; active analysis retained");
    if(ctx.store)
      result.snapshot = ctx.store->snapshot();
    return result;
  }

  AnalysisKey targetKey = ctx.currentKey;
  targetKey.modelId = payload.modelId;
  const Rules targetRules = ctx.store ? ctx.store->rules() : Rules{};
  const bool reuseActiveStore = ctx.store != nullptr && targetKey == ctx.currentKey;
  std::unique_ptr<MCTSStore> preparedStore;
  std::string preparationError;
  if(!reuseActiveStore &&
     !prepareTargetStore(targetKey, targetRules, ctx.params, preparedStore, preparationError))
    return baseResult(request, false, "could not prepare model-specific store: " + preparationError);

  Evaluator* selectedEvaluator = nullptr;
  std::string selectionError;
  if(engineSelector) {
    ctx.engineState = EngineState::loading;
    if(!engineSelector(payload.modelId, selectedEvaluator, selectionError)) {
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
  }
  else {
    selectedEvaluator = ctx.evaluator;
  }
  if(selectedEvaluator == nullptr) {
    ctx.engineState = EngineState::offline;
    bumpEpoch();
    return baseResult(request, false, "selected engine did not provide an evaluator");
  }

  if(!reuseActiveStore)
    ctx.store = std::move(preparedStore);
  ctx.currentKey = targetKey;
  ctx.params = ctx.store->searchParams();
  ctx.evaluator = selectedEvaluator;
  ctx.engineState = EngineState::ready;
  ctx.store->setEvaluator(selectedEvaluator);
  ctx.storeState = StoreState::ready;
  bumpEpoch();
  auto result = baseResult(request, true, "engine selection committed");
  result.snapshot = ctx.store->snapshot();
  return result;
}

BackendResult BackendWorker::handleExportAnalysisState(const FrontendRequest& request, const ExportAnalysisStateRequest& payload) {
  auto result = baseResult(request, true, "analysis state exported");
  if(!ensureStoreReady(result))
    return result;
  setIoProgress(true, "checkpointing", 0.05, 0, 0, "Saving active store");
  std::string error;
  if(!checkpointCurrentStore(error)) {
    clearIoProgress();
    return baseResult(request, false, error);
  }

  std::vector<uint8_t> bytes;
  if(ctx.storeDirectory.empty()) {
    setIoProgress(true, "serializing", 0.25, 0, 0, "Serializing MCTS store");
    bytes = ctx.store->serialize();
    if(bytes.empty()) {
      clearIoProgress();
      return baseResult(request, false, "serialized store exceeds the core-state byte limit");
    }
    setIoProgress(true, "serializing", 0.55, bytes.size(), bytes.size(), "Serialized MCTS store");
  }
  else {
    setIoProgress(true, "bundling", 0.20, 0, 0, "Collecting store bundle");
    const std::string activeFilename = std::filesystem::path(storePath(ctx.currentKey)).filename().string();
    std::vector<StoreBundleEntry> entries;
    std::error_code iteratorError;
    for(std::filesystem::directory_iterator iterator(ctx.storeDirectory, iteratorError), end;
        !iteratorError && iterator != end;
        iterator.increment(iteratorError)) {
      const std::filesystem::directory_entry& item = *iterator;
      const std::string filename = item.path().filename().string();
      if(item.path().extension() != ".qixi-core-store")
        continue;
      const auto status = item.symlink_status(iteratorError);
      if(iteratorError || !std::filesystem::is_regular_file(status)) {
        error = "core store directory contains a non-regular store entry";
        break;
      }
      StoreBundleEntry entry;
      entry.filename = filename;
      if(!readFile(item.path().string(), entry.bytes, error))
        break;
      std::string decodeError;
      auto decoded = MCTSStore::deserialize(entry.bytes, &decodeError);
      if(!decoded) {
        error = "could not validate store while exporting bundle: " + decodeError;
        break;
      }
      if(decoded->analysisKey().gameId != ctx.currentKey.gameId)
        continue;
      if(std::filesystem::path(storePath(decoded->analysisKey())).filename().string() != filename) {
        error = "core store filename does not match its embedded analysis key";
        break;
      }
      entries.push_back(std::move(entry));
    }
    if(iteratorError && error.empty())
      error = "could not enumerate core store directory";
    if(!error.empty()) {
      clearIoProgress();
      return baseResult(request, false, error);
    }
    std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) {
      return a.filename < b.filename;
    });
    if(!buildStoreBundle(activeFilename, entries, bytes, error)) {
      clearIoProgress();
      return baseResult(request, false, error);
    }
    setIoProgress(true, "bundling", 0.55, bytes.size(), bytes.size(), "Bundle ready");
  }
  setIoProgress(true, "writing", 0.75, 0, bytes.size(), "Writing package");
  if(!writeFileAtomically(payload.path, bytes, error)) {
    clearIoProgress();
    return baseResult(request, false, error);
  }
  setIoProgress(true, "complete", 1.0, bytes.size(), bytes.size(), "Export complete");
  clearIoProgress();
  return result;
}

BackendResult BackendWorker::handleEnterBackground(const FrontendRequest& request, const EnterBackgroundRequest& payload) {
  (void)payload;
  std::string error;
  if(!checkpointCurrentStore(error))
    return baseResult(request, false, error);
  return baseResult(request, true, "background checkpoint saved committed state");
}

BackendResult BackendWorker::handleEnterForeground(const FrontendRequest& request, const EnterForegroundRequest& payload) {
  (void)payload;
  auto result = baseResult(request, true, "foreground restored");
  if(ctx.store)
    result.snapshot = ctx.store->snapshot();
  return result;
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
  if(!checkpointCurrentStore(checkpointError))
    return baseResult(request, false, checkpointError);
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
  if(!checkpointCurrentStore(checkpointError))
    return baseResult(request, false, checkpointError);
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
  std::string checkpointError;
  if(!checkpointCurrentStore(checkpointError))
    return baseResult(request, false, checkpointError);
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
  ctx.committedIntentMap[payload.uiIntentId] = ctx.store->nodeArray()[commit.node].lineageHash;
  bumpRevision();
  result = baseResult(request, true, "move committed");
  result.committedUiIntentId = payload.uiIntentId;
  result.hasCommittedUiIntent = payload.uiIntentId != 0;
  result.snapshot = ctx.store->snapshot();
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
      NodeId child = kInvalidNode;
      const RootSnapshot snapshot = ctx.store->snapshot();
      for(const TreeNodeSnapshot& candidate : snapshot.visibleTree) {
        if(candidate.parent == target) {
          child = candidate.id;
          break;
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
  result = baseResult(request, true, "root changed");
  result.snapshot = ctx.store->snapshot();
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
  result = baseResult(request, true, "root changed");
  result.snapshot = ctx.store->snapshot();
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
  setIoProgress(true, "reading", 0.02, 0, 0, "Reading MCTS state");
  std::string error;
  auto progressCb = [this](const MCTSStore::DeserializeProgress& p) {
    setIoProgress(true, p.phase, p.fraction, p.unitsDone, p.unitsTotal, p.message);
  };

  // Peek magic with a small prefix read to choose bundle vs single-store path.
  std::vector<uint8_t> magicBytes;
  if(!peekFilePrefix(payload.path, 16, magicBytes, error)) {
    clearIoProgress();
    return baseResult(request, false, error);
  }

  std::optional<MCTSStore> loaded;
  std::vector<StoreBundleEntry> bundleEntries;
  std::string activeFilename;
  const GameId importedGameId = ctx.nextGameId;
  std::vector<uint8_t> bytes;
  if(hasStoreBundleMagic(magicBytes)) {
    if(!readFile(payload.path, bytes, error)) {
      clearIoProgress();
      return baseResult(request, false, error);
    }
    setIoProgress(true, "parsing", 0.25, bytes.size(), bytes.size(), "Parsing store bundle");
    if(!parseStoreBundle(bytes, activeFilename, bundleEntries, error)) {
      clearIoProgress();
      return baseResult(request, false, error);
    }
    if(ctx.storeDirectory.empty()) {
      clearIoProgress();
      return baseResult(request, false, "cannot import a multi-store bundle without a store directory");
    }
    std::vector<uint8_t>().swap(bytes);

    std::set<std::string> analysisKeys;
    GameId bundleGameId = 0;
    for(StoreBundleEntry& entry : bundleEntries) {
      std::string decodeError;
      auto decoded = MCTSStore::deserialize(entry.bytes, &decodeError);
      if(!decoded) {
        clearIoProgress();
        return baseResult(request, false, "bundle store is invalid: " + decodeError);
      }
      const std::string canonical = std::filesystem::path(storePath(decoded->analysisKey())).filename().string();
      if(canonical != entry.filename) {
        clearIoProgress();
        return baseResult(request, false, "bundle store filename does not match its analysis key");
      }
      if(bundleGameId == 0)
        bundleGameId = decoded->analysisKey().gameId;
      else if(decoded->analysisKey().gameId != bundleGameId) {
        clearIoProgress();
        return baseResult(request, false, "bundle contains stores from multiple games");
      }
      if(!analysisKeys.insert(keyString(decoded->analysisKey())).second) {
        clearIoProgress();
        return baseResult(request, false, "bundle contains duplicate analysis keys");
      }
    }

    std::string importedActiveFilename;
    for(StoreBundleEntry& entry : bundleEntries) {
      const bool isActive = entry.filename == activeFilename;
      std::string decodeError;
      auto decoded = MCTSStore::deserialize(entry.bytes, &decodeError);
      if(!decoded) {
        clearIoProgress();
        return baseResult(request, false, "bundle store changed during validation: " + decodeError);
      }
      std::vector<uint8_t>().swap(entry.bytes);
      decoded->assignImportedGameId(importedGameId);
      entry.filename =
        std::filesystem::path(storePath(decoded->analysisKey())).filename().string();
      entry.bytes = decoded->serialize();
      if(entry.bytes.empty()) {
        clearIoProgress();
        return baseResult(request, false, "imported bundle store exceeds the core-state byte limit");
      }
      if(isActive) {
        importedActiveFilename = entry.filename;
        loaded = std::move(decoded);
      }
    }
    activeFilename = importedActiveFilename;
    if(!loaded) {
      clearIoProgress();
      return baseResult(request, false, "bundle active store could not be decoded");
    }
  }
  else {
    // Single-store product path: mmap/chunked load with true parse progress.
    loaded = MCTSStore::deserializeFromFile(payload.path, kMaxCoreStateBytes, &error, progressCb);
    if(!loaded) {
      clearIoProgress();
      return baseResult(request, false, error);
    }
    loaded->assignImportedGameId(importedGameId);
    setIoProgress(true, "serializing", 0.92, 0, 0, "Re-serializing imported store");
    bytes = loaded->serialize();
    if(bytes.empty()) {
      clearIoProgress();
      return baseResult(request, false, "imported store exceeds the core-state byte limit");
    }
  }

  if(ctx.engineState == EngineState::ready &&
     loaded->analysisKey().modelId != ctx.currentKey.modelId) {
    clearIoProgress();
    return baseResult(request, false, "imported active state belongs to a different loaded model");
  }

  std::vector<std::string> bundleDestinations;
  std::string singleDestination;
  if(!bundleEntries.empty()) {
    bundleDestinations.reserve(bundleEntries.size());
    for(const StoreBundleEntry& entry : bundleEntries) {
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
    return baseResult(request, false, error);

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
  setIoProgress(true, "activating", 0.85, 0, 0, "Activating imported store");
  ctx.store = std::make_unique<MCTSStore>(std::move(*loaded));
  ctx.currentKey = ctx.store->analysisKey();
  ctx.params = ctx.store->searchParams();
  ctx.nextGameId = importedGameId + 1;
  ctx.store->setEvaluator(ctx.evaluator);
  ctx.committedIntentMap.clear();
  ctx.storeState = StoreState::ready;
  bumpEpoch();
  auto result = baseResult(request, true, "analysis state imported");
  result.snapshot = ctx.store->snapshotLight(32, 4096, true);
  setIoProgress(true, "complete", 1.0, 0, 0, "Import complete");
  clearIoProgress();
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

} // namespace qixi::core
