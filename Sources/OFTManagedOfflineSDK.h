#import <WebKit/WebKit.h>
#import "OFTManagedTypes.h"
#import "OFTManagedStorage.h"

NS_ASSUME_NONNULL_BEGIN
@class OFTOfflineSchemeHandler;

/// 绑定跟随同一 WKWebView；reload、外站历史返回保持固定版本，整个页面关闭才 dispose。
/// 重新打开业务入口创建新绑定，外站文档不会取得离线身份。
@interface OFTPageBinding : NSObject
@property (nonatomic, strong, readonly) OFTOfflineSchemeHandler *handler;
- (void)dispose;
- (instancetype)init NS_UNAVAILABLE;
@end

/// 应用入口持有唯一实例，页面释放不会结束应用级更新。
@interface OFTManagedOfflineSDK : NSObject
/// minimumVersion defaults to 10000 and checkInterval to 300 seconds.
/// storage=nil uses the SDK SQLite database beside the package root.
- (nullable instancetype)initWithRootDirectory:(NSURL *)root
                           originalStaticRoot:(NSURL *)staticRoot
                               minimumVersion:(NSInteger)minimumVersion
                                checkInterval:(NSTimeInterval)checkInterval
                                      storage:(nullable OFTManagedStorage *)storage
                        configurationProvider:(OFTConfigurationProvider)provider
                                        error:(NSError **)error;
- (nullable instancetype)initWithRootDirectory:(NSURL *)root
                           originalStaticRoot:(NSURL *)staticRoot
                        configurationProvider:(OFTConfigurationProvider)provider
                                        error:(NSError **)error;
/// 后端需要本次可用版本时使用此入口；旧 provider 与两个旧构造入口继续兼容。
- (nullable instancetype)initWithRootDirectory:(NSURL *)root
                           originalStaticRoot:(NSURL *)staticRoot
                               minimumVersion:(NSInteger)minimumVersion
                                checkInterval:(NSTimeInterval)checkInterval
                                      storage:(nullable OFTManagedStorage *)storage
               versionedConfigurationProvider:(OFTVersionedConfigurationProvider)provider
                                        error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// Main delivery. Skip/cancellation adds no installation event; confirmed ready success survives
/// cancellation of the short finishing section. Callback exceptions do not change committed facts.
@property (nonatomic, copy, nullable) void (^outcomeHandler)(OFTManagedOutcome *outcome);
@property (nonatomic, copy, nullable) void (^diagnosticHandler)(NSString *stage, OFTOfflineErrorCode reason, NSString *detail);
/// Main synchronous cache-removal request, once for a higher silent target with an active package.
/// nil requests only WK memory/disk resource removal. Completion/disk deletion is not promised.
@property (nonatomic, copy, nullable) void (^resourceCacheCleaner)(void);
/// Set before starting work. Managed downloads inherit these timeouts (nil: platform defaults).
@property (nonatomic, copy, nullable) NSURLSessionConfiguration *downloadConfiguration;
- (void)updatePrivacyGranted:(BOOL)privacyGranted foreground:(BOOL)foreground;
- (NSProgress *)prepareStartupWithProgress:(nullable void (^)(OFTPreparationProgress *progress))progress
                               completion:(void (^)(OFTPreparationResult *result))completion;
/// 条件/间隔仍由 SDK 检查，此入口不会绕过 300 秒或失败门槛。
- (void)checkForUpdates;
/// 必须在 WKWebView 创建前调用；保留宿主配置、脚本与代理。
- (nullable OFTPageBinding *)pageBindingForConfiguration:(WKWebViewConfiguration *)configuration
                                                scheme:(NSString *)scheme error:(NSError **)error;
/// 受认证静态资源可提供与宿主协调的受控网络会话配置。
- (nullable OFTPageBinding *)pageBindingForConfiguration:(WKWebViewConfiguration *)configuration
                                                scheme:(NSString *)scheme
                                  networkConfiguration:(nullable NSURLSessionConfiguration *)networkConfiguration
                                                 error:(NSError **)error;
- (NSProgress *)loadPage:(NSURL *)originalURL inWebView:(WKWebView *)webView
                binding:(OFTPageBinding *)binding
             completion:(nullable void (^)(OFTPageLoadResult * _Nullable result, NSError * _Nullable error))completion;
- (void)close;
@end
NS_ASSUME_NONNULL_END
