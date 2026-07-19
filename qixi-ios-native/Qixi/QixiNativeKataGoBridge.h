#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const QixiNativeKataGoErrorDomain;

typedef NS_ERROR_ENUM(QixiNativeKataGoErrorDomain, QixiNativeKataGoError) {
  QixiNativeKataGoErrorLibraryNotLinked = 1,
  QixiNativeKataGoErrorInvalidRequest = 2,
};

@interface QixiNativeKataGoBridge : NSObject

@property(nonatomic, readonly, getter=isLinked) BOOL linked;

- (BOOL)configureModel:(NSString *)engineID
          resourceName:(NSString *)resourceName
             modelPath:(NSString *)modelPath
    coreMLPackagePaths:(NSArray<NSString *> *)coreMLPackagePaths
       minimumMemoryMB:(int)minimumMemoryMB
    recommendedMemoryMB:(int)recommendedMemoryMB
       maximumMemoryMB:(int)maximumMemoryMB
                 error:(NSError **)error;
- (BOOL)loadEngine:(NSString *)engineID error:(NSError **)error;
- (nullable NSString *)analyzeRequestJSON:(NSString *)requestJSON error:(NSError **)error;
- (BOOL)exportTombstoneToFile:(NSString *)filePath error:(NSError **)error;
- (BOOL)restoreTombstoneFromFile:(NSString *)filePath error:(NSError **)error;
- (nullable NSString *)submitCoreRequestJSON:(NSString *)requestJSON error:(NSError **)error;
- (nullable NSString *)latestCoreSnapshotJSONWithError:(NSError **)error;
/// Plane A: lock-free published revision (no core mutex).
- (uint64_t)publishedAnalyzeRevision;
/// Plane A: lock-free O(1) analyze POD copy, or nil when no stable payload.
- (nullable NSData *)analyzeDisplayPayloadData;
/// Plane B: post play intent (move = x+y*19 or 361 pass). Never blocks.
- (BOOL)postNavPlayMove:(uint32_t)move uiIntentId:(uint64_t)uiIntentId;
/// Plane B: post switchRoot intent. Never blocks.
- (BOOL)postNavSwitchRoot:(uint32_t)nodeId uiIntentId:(uint64_t)uiIntentId;
- (nullable NSString *)coreIoProgressJSONWithError:(NSError **)error;
- (nullable NSString *)legalMoveMaskJSONWithError:(NSError **)error;
- (BOOL)exportCoreStateToFile:(NSString *)filePath error:(NSError **)error;
- (BOOL)importCoreStateFromFile:(NSString *)filePath error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
