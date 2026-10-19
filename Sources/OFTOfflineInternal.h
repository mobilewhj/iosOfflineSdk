#import "OFTPackageInstaller.h"
NS_ASSUME_NONNULL_BEGIN
NSError *OFTError(OFTOfflineErrorCode code, NSString *stage, NSString *message, NSError * _Nullable cause);
BOOL OFTRegularNonemptyFile(NSURL *url);
/// 托管认领持续至进程结束，防止重新创建 manager 绕过目录保护与失败门槛。
@interface OFTPackageInstaller (ManagedOwnership)
- (BOOL)claimManagedRootWithOwner:(id)owner error:(NSError **)error;
- (BOOL)markManagedRootPageBound;
@property (nonatomic, readonly) BOOL canModifyExistingVersions;
@end
@interface OFTDownload : NSObject <NSURLSessionDownloadDelegate, NSURLSessionDataDelegate>
- (BOOL)downloadURL:(NSURL *)url destination:(NSURL *)destination cancellation:(NSProgress *)cancellation
          progress:(nullable OFTInstallProgress)progress error:(NSError **)error;
- (BOOL)downloadURL:(NSURL *)url destination:(NSURL *)destination configuration:(nullable NSURLSessionConfiguration *)configuration
       cancellation:(NSProgress *)cancellation onStarted:(dispatch_block_t)onStarted
           progress:(nullable OFTInstallProgress)progress error:(NSError **)error;
@end

@interface OFTPackageInstaller (ManagedFiles)
- (nullable NSURL *)prepareManagedRecord:(OFTPackageRecord *)record source:(NSURL *)source
                         configuration:(nullable NSURLSessionConfiguration *)configuration cancellation:(NSProgress *)cancellation
                       protectedVersion:(NSInteger)protectedVersion onStarted:(dispatch_block_t)onStarted
                              stageWrite:(BOOL (^)(NSString *stage, NSError **error))stageWrite
                               progress:(OFTInstallProgress)progress error:(NSError **)error;
- (void)deleteManagedVersion:(NSInteger)version protectedVersion:(NSInteger)protectedVersion;
- (void)deleteManagedZIP:(NSInteger)version;
- (void)cleanupManagedKeeping:(NSSet<NSString *> *)kept cancellation:(nullable NSProgress *)cancellation;
@end
NS_ASSUME_NONNULL_END
