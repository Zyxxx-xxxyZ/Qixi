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
- (nullable NSString *)legalMoveMaskJSONWithError:(NSError **)error;
- (BOOL)exportCoreStateToFile:(NSString *)filePath error:(NSError **)error;
- (BOOL)importCoreStateFromFile:(NSString *)filePath error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
