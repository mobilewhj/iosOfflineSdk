#import <Foundation/Foundation.h>
#import "OFTPackageInstaller.h"

NS_ASSUME_NONNULL_BEGIN
/// Provider 可以原样映射关闭响应；关闭时其余字段可为空或无效。
@interface OFTManagedConfiguration : NSObject
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) NSInteger version;
@property (nonatomic, copy, readonly, nullable) NSURL *packageURL;
@property (nonatomic, copy, readonly, nullable) NSString *sha256;
- (instancetype)initWithEnabled:(BOOL)enabled version:(NSInteger)version
                     packageURL:(nullable NSURL *)packageURL sha256:(nullable NSString *)sha256;
@end

typedef void (^OFTConfigurationCompletion)(OFTManagedConfiguration * _Nullable configuration, NSError * _Nullable error);
/// SDK 在 Main 调用 provider；completion 可以来自任意队列，且只能消费一次。
typedef NSProgress * _Nullable (^OFTConfigurationProvider)(OFTConfigurationCompletion completion);
/// SDK 在 Main 给出本次可用 active 版本；入口不可读或不满足 minimumVersion 时为 0。
/// 可用版本独立于页面资格，关闭开关、线上版本差异或 SHA 冲突不会抹去仍可读的 active。
typedef NSProgress * _Nullable (^OFTVersionedConfigurationProvider)(NSInteger currentPackageVersion, OFTConfigurationCompletion completion);

@interface OFTPreparationProgress : NSObject
/// checking / prepare / download / verify / extract / saving / confirming / complete
@property (nonatomic, copy, readonly) NSString *stage;
@property (nonatomic, readonly) int64_t completed;
@property (nonatomic, readonly) int64_t total;
/// -1 表示未知；阶段比例不等于整次安装比例，ready 确认写入后才有 1。
@property (nonatomic, readonly) double fraction;
- (instancetype)initWithStage:(NSString *)stage completed:(int64_t)completed total:(int64_t)total;
@end

@interface OFTManagedOutcome : NSObject
@property (nonatomic, readonly) BOOL success;
@property (nonatomic, strong, readonly) OFTPackageRecord *record;
@property (nonatomic, copy, readonly) NSString *stage;
@property (nonatomic, readonly) OFTOfflineErrorCode reason;
/// 有限安全原因，不含原异常、URL 或认证信息。
@property (nonatomic, copy, readonly) NSString *detail;
@property (nonatomic, strong, readonly, nullable) NSNumber *HTTPStatus;
/// Package-processing boundary: Remote attempt, Local input or verified ZIP reuse.
@property (nonatomic, readonly) BOOL requestStarted;
@property (nonatomic, readonly) NSInteger activeVersion;
@property (nonatomic, strong, readonly, nullable) OFTPackageRecord *publishedRecord;
@property (nonatomic, readonly) BOOL publishedDirectoryRemains;
/// 观察目录状态发生 IO 故障；此时 remains=NO 不代表已经确认删除。
@property (nonatomic, readonly) BOOL publishedDirectoryStateUnknown;
@property (nonatomic, readonly) NSUInteger cleanupFailureCount;
- (instancetype)initWithRecord:(OFTPackageRecord *)record success:(BOOL)success error:(nullable NSError *)error;
- (instancetype)initWithRecord:(OFTPackageRecord *)record success:(BOOL)success error:(nullable NSError *)error activeVersion:(NSInteger)activeVersion;
@end

typedef NS_ENUM(NSInteger, OFTPreparationDisposition) {
    OFTPreparationContinue, OFTPreparationDeferred, OFTPreparationCancelled
};
@interface OFTPreparationResult : NSObject
@property (nonatomic, readonly) OFTPreparationDisposition disposition;
@property (nonatomic, readonly) BOOL performedFirstPreparation;
@property (nonatomic, strong, readonly, nullable) OFTManagedOutcome *outcome;
- (instancetype)initWithDisposition:(OFTPreparationDisposition)disposition first:(BOOL)first outcome:(nullable OFTManagedOutcome *)outcome;
@end

@interface OFTPageLoadResult : NSObject
@property (nonatomic, readonly) BOOL offline;
@property (nonatomic, strong, readonly, nullable) OFTPackageRecord *record;
@property (nonatomic, copy, readonly) NSURL *loadedURL;
- (instancetype)initWithURL:(NSURL *)URL record:(nullable OFTPackageRecord *)record;
@end
NS_ASSUME_NONNULL_END
