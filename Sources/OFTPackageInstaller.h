#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSErrorDomain const OFTOfflineErrorDomain;
FOUNDATION_EXPORT NSString * const OFTOfflineErrorStageKey;
FOUNDATION_EXPORT NSString * const OFTOfflineHTTPStatusKey;
/// 失败仍可能留下已发布目录；以下事实不会把失败 completion 变成成功。
FOUNDATION_EXPORT NSString * const OFTOfflineCleanupErrorsKey;
FOUNDATION_EXPORT NSString * const OFTOfflinePublishedRecordKey;
FOUNDATION_EXPORT NSString * const OFTOfflinePublishedDirectoryKey;
FOUNDATION_EXPORT NSString * const OFTOfflinePublishedDirectoryRemainsKey;
FOUNDATION_EXPORT NSString * const OFTOfflinePublishedDirectoryStateUnknownKey;
FOUNDATION_EXPORT NSString * const OFTOfflineRequestStartedKey;
/// Internal retry facts; processing statistics remain independent from retry quota.
FOUNDATION_EXPORT NSString * const OFTOfflineNetworkRetryKey;
FOUNDATION_EXPORT NSString * const OFTOfflineRetryAfterKey;

typedef NS_ENUM(NSInteger, OFTOfflineErrorCode) {
    OFTOfflineInvalidInput = 1, OFTOfflineFileIO, OFTOfflineNetwork,
    OFTOfflineTimeout, OFTOfflineTooLarge, OFTOfflineDigestMismatch,
    OFTOfflineInvalidArchive, OFTOfflineVersionExists, OFTOfflineCancelled,
    OFTOfflineStorageRead, OFTOfflineStorageWrite
};

/// Immutable normalized metadata; the managed SDK owns package selection and lifecycle storage.
@interface OFTPackageRecord : NSObject <NSCopying>
@property (nonatomic, readonly) NSInteger version;
@property (nonatomic, copy, readonly) NSString *sha256;
- (nullable instancetype)initWithVersion:(NSInteger)version sha256:(NSString *)sha256;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Stage is prepare/download/verify/extract/publish. Unknown total bytes is -1.
/// SDK callbacks arrive on the main queue. Publish is NOT host metadata commit.
typedef void (^OFTInstallProgress)(NSString *stage, int64_t completed, int64_t total);
typedef void (^OFTInstallCompletion)(OFTPackageRecord * _Nullable record,
                                     NSURL * _Nullable directory, NSError * _Nullable error);

@interface OFTPackageInstaller : NSObject
/// Reuse one instance per root. Install and cleanup are serialized.
/// The root must be owned by the host; the SDK never follows a root symlink.
- (instancetype)initWithRootDirectory:(NSURL *)root NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (NSProgress *)installRecord:(OFTPackageRecord *)record
                     fromURL:(NSURL *)url
                    progress:(nullable OFTInstallProgress)progress
                  completion:(OFTInstallCompletion)completion;
/// Imports a trusted local ZIP, copies it and verifies the supplied digest.
- (NSProgress *)installRecord:(OFTPackageRecord *)record
                localArchive:(NSURL *)archive
                    progress:(nullable OFTInstallProgress)progress
                  completion:(OFTInstallCompletion)completion;
/// Only before pages are bound. Missing/empty active entry prevents cleanup.
- (void)clearOldVersionsKeeping:(nullable NSNumber *)activeVersion
                    completion:(void (^)(NSError * _Nullable error))completion;
/// The host must guarantee this version has never been bound to a page.
- (void)discardUnboundVersion:(NSInteger)version
                   completion:(void (^)(NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
