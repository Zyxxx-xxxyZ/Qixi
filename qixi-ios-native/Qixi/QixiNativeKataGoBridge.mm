#import "QixiNativeKataGoBridge.h"

#include "QixiNativeKataGoCore.hpp"

#include <memory>
#include <string>

NSString * const QixiNativeKataGoErrorDomain = @"QixiNativeKataGo";

@interface QixiNativeKataGoBridge () {
  std::unique_ptr<qixi::NativeKataGoCore> _core;
}

@end

@implementation QixiNativeKataGoBridge

- (instancetype)init {
  self = [super init];
  if (self) {
    _core = std::make_unique<qixi::NativeKataGoCore>();
    NSURL *applicationSupport = [[NSFileManager defaultManager]
      URLsForDirectory:NSApplicationSupportDirectory
      inDomains:NSUserDomainMask].firstObject;
    NSURL *storeDirectory = [[applicationSupport URLByAppendingPathComponent:@"Qixi" isDirectory:YES]
      URLByAppendingPathComponent:@"CoreStores" isDirectory:YES];
    NSError *directoryError = nil;
    [[NSFileManager defaultManager]
      createDirectoryAtURL:storeDirectory
      withIntermediateDirectories:YES
      attributes:nil
      error:&directoryError];
    if (directoryError == nil) {
      _core->configureCoreStoreDirectory([self stringFromNSString:storeDirectory.path]);
    }
  }
  return self;
}

- (BOOL)isLinked {
  return _core->isLinked();
}

- (BOOL)configureModel:(NSString *)engineID
          resourceName:(NSString *)resourceName
             modelPath:(NSString *)modelPath
    coreMLPackagePaths:(NSArray<NSString *> *)coreMLPackagePaths
       minimumMemoryMB:(int)minimumMemoryMB
   recommendedMemoryMB:(int)recommendedMemoryMB
       maximumMemoryMB:(int)maximumMemoryMB
                 error:(NSError **)error {
  qixi::NativeKataGoModelConfig config;
  config.engineID = [self stringFromNSString:engineID];
  config.resourceName = [self stringFromNSString:resourceName];
  config.modelPath = [self stringFromNSString:modelPath];
  for (NSString *path in coreMLPackagePaths) {
    config.coreMLPackagePaths.push_back([self stringFromNSString:path]);
  }
  config.minimumMemoryMB = minimumMemoryMB;
  config.recommendedMemoryMB = recommendedMemoryMB;
  config.maximumMemoryMB = maximumMemoryMB;
  qixi::NativeKataGoResult result = _core->configureModel(config);
  if (result.ok()) {
    return YES;
  }
  [self populateError:error fromResult:result];
  return NO;
}

- (BOOL)loadEngine:(NSString *)engineID error:(NSError **)error {
  qixi::NativeKataGoResult result = _core->loadEngine([self stringFromNSString:engineID]);
  if (result.ok()) {
    return YES;
  }
  [self populateError:error fromResult:result];
  return NO;
}

- (nullable NSString *)analyzeRequestJSON:(NSString *)requestJSON error:(NSError **)error {
  qixi::NativeKataGoResult result = _core->analyzeRequestJSON([self stringFromNSString:requestJSON]);
  if (result.ok()) {
    return [NSString stringWithUTF8String:result.responseJSON.c_str()];
  }
  [self populateError:error fromResult:result];
  return nil;
}

- (BOOL)exportTombstoneToFile:(NSString *)filePath error:(NSError **)error {
  qixi::NativeKataGoResult result = _core->exportTombstoneToFile([self stringFromNSString:filePath]);
  if (result.ok()) {
    return YES;
  }
  [self populateError:error fromResult:result];
  return NO;
}

- (BOOL)restoreTombstoneFromFile:(NSString *)filePath error:(NSError **)error {
  qixi::NativeKataGoResult result = _core->restoreTombstoneFromFile([self stringFromNSString:filePath]);
  if (result.ok()) {
    return YES;
  }
  [self populateError:error fromResult:result];
  return NO;
}

- (nullable NSString *)submitCoreRequestJSON:(NSString *)requestJSON error:(NSError **)error {
  qixi::NativeKataGoResult result = _core->submitCoreRequestJSON([self stringFromNSString:requestJSON]);
  if (result.ok()) {
    return [NSString stringWithUTF8String:result.responseJSON.c_str()];
  }
  [self populateError:error fromResult:result];
  return nil;
}

- (nullable NSString *)latestCoreSnapshotJSONWithError:(NSError **)error {
  qixi::NativeKataGoResult result = _core->latestCoreSnapshotJSON();
  if (result.ok()) {
    return [NSString stringWithUTF8String:result.responseJSON.c_str()];
  }
  [self populateError:error fromResult:result];
  return nil;
}

- (uint64_t)publishedAnalyzeRevision {
  return _core->publishedAnalyzeRevision();
}

- (nullable NSData *)analyzeDisplayPayloadData {
  qixi::core::AnalyzeDisplayPayload payload{};
  if (!_core->tryLoadAnalyzeDisplay(payload)) {
    return nil;
  }
  return [NSData dataWithBytes:&payload length:sizeof(payload)];
}

- (BOOL)postNavPlayMove:(uint32_t)move uiIntentId:(uint64_t)uiIntentId {
  return _core->postNavPlay(move, uiIntentId) ? YES : NO;
}

- (BOOL)postNavSwitchRoot:(uint32_t)nodeId uiIntentId:(uint64_t)uiIntentId {
  return _core->postNavSwitchRoot(nodeId, uiIntentId) ? YES : NO;
}

- (nullable NSString *)coreIoProgressJSONWithError:(NSError **)error {
  qixi::NativeKataGoResult result = _core->coreIoProgressJSON();
  if (result.ok()) {
    return [NSString stringWithUTF8String:result.responseJSON.c_str()];
  }
  [self populateError:error fromResult:result];
  return nil;
}

- (nullable NSString *)legalMoveMaskJSONWithError:(NSError **)error {
  qixi::NativeKataGoResult result = _core->legalMoveMaskJSON();
  if (result.ok()) {
    return [NSString stringWithUTF8String:result.responseJSON.c_str()];
  }
  [self populateError:error fromResult:result];
  return nil;
}

- (BOOL)exportCoreStateToFile:(NSString *)filePath error:(NSError **)error {
  qixi::NativeKataGoResult result = _core->exportCoreStateToFile([self stringFromNSString:filePath]);
  if (result.ok()) {
    return YES;
  }
  [self populateError:error fromResult:result];
  return NO;
}

- (BOOL)importCoreStateFromFile:(NSString *)filePath error:(NSError **)error {
  qixi::NativeKataGoResult result = _core->importCoreStateFromFile([self stringFromNSString:filePath]);
  if (result.ok()) {
    return YES;
  }
  [self populateError:error fromResult:result];
  return NO;
}

- (std::string)stringFromNSString:(NSString *)value {
  if (value == nil) {
    return "";
  }
  const char *utf8 = [value UTF8String];
  return utf8 == nullptr ? "" : std::string(utf8);
}

- (void)populateError:(NSError **)error fromResult:(const qixi::NativeKataGoResult&)result {
  if (error == nil) {
    return;
  }
  NSInteger code = [self errorCodeForResult:result];
  NSString *message = [NSString stringWithUTF8String:result.message.c_str()];
  *error = [NSError errorWithDomain:QixiNativeKataGoErrorDomain
                               code:code
                           userInfo:@{
                             NSLocalizedDescriptionKey: message
                           }];
}

- (NSInteger)errorCodeForResult:(const qixi::NativeKataGoResult&)result {
  switch (result.code) {
    case qixi::NativeKataGoStatusCode::libraryNotLinked:
      return QixiNativeKataGoErrorLibraryNotLinked;
    case qixi::NativeKataGoStatusCode::invalidRequest:
      return QixiNativeKataGoErrorInvalidRequest;
    case qixi::NativeKataGoStatusCode::ok:
      return 0;
  }
}

@end
