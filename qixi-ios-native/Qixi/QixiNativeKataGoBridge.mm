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
