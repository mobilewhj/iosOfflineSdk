#import <Foundation/Foundation.h>
#import "OFTPackageInstaller.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSErrorDomain const OFTManagedStorageErrorDomain;
FOUNDATION_EXPORT NSString * const OFTPackageStageDownloading;
FOUNDATION_EXPORT NSString * const OFTPackageStageDownloaded;
FOUNDATION_EXPORT NSString * const OFTPackageStageReady;
FOUNDATION_EXPORT NSString * const OFTPackageStageActive;

typedef NS_ENUM(NSInteger, OFTManagedStorageErrorCode) {
    OFTManagedStorageIOFailure = 1,
    OFTManagedStorageIdentityConflict,
    OFTManagedStorageMissingStageRow,
    OFTManagedStorageInvalidDirectory,
    OFTManagedStorageUnsupportedSchema,
};

/// SDK-owned SQLite lifecycle facts. One table: version, sha256, stage.
/// Methods perform synchronous transactions on the SDK IO queue; callers must not use Main.
/// nil rows means read failure, while an empty array is a successful empty database read.
@interface OFTManagedStorage : NSObject
@property (nonatomic, copy, readonly) NSURL *databaseURL;
- (instancetype)initWithDatabaseURL:(NSURL *)databaseURL NS_DESIGNATED_INITIALIZER;
/// Convenience for isolated tests/consumers; stores packages.db in this state directory.
- (instancetype)initWithDirectory:(NSURL *)directory;
/// Stable container-relative relationship: database is beside the package root, outside cleanup.
+ (nullable instancetype)defaultStorageForInstallationRootDirectory:(NSURL *)root error:(NSError **)error;
- (BOOL)validateInstallationRootDirectory:(NSURL *)root error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)readRowsWithError:(NSError **)error;
- (nullable NSDictionary *)rowForVersion:(NSInteger)version error:(NSError **)error;
/// Identity is checked before any eviction. nil means rollback/failure; [] is valid success.
- (nullable NSArray<NSNumber *> *)registerTarget:(OFTPackageRecord *)target error:(NSError **)error;
/// Exactly one non-active row must be changed. SHA never changes; active is transaction-only.
- (BOOL)setStage:(NSString *)stage forVersion:(NSInteger)version error:(NSError **)error;
/// Delete previous active and promote the ready row in one transaction; failure rolls back.
- (BOOL)activateVersion:(NSInteger)version error:(NSError **)error;
/// Only evict when the retained version is actually active in the database.
- (nullable NSArray<NSNumber *> *)evictInactiveKeepingVersion:(NSInteger)version error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
