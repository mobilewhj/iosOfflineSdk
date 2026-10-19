#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN
/// 每页固定一个版本目录；须在创建 WKWebView 前注册自定义 scheme。
/// 旧初始化入口保持仅本地行为，托管入口仅回源指定 HTTP(S) 静态根中的 GET。
@interface OFTOfflineSchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic, copy, readonly) NSString *scheme;
/// 兼容旧入口：baseURL 是带尾斜杠的原 HTTP(S) 静态根；未命中直接失败。
- (nullable instancetype)initWithDirectory:(NSURL *)directory
                                  baseURL:(NSURL *)baseURL
                                   scheme:(NSString *)scheme;
- (instancetype)init NS_UNAVAILABLE;
/// 先创建未绑定 handler，再由管理器在后台观察、最终复核后绑定一次。
/// enabledProvider 每次资源决策读取最新开关；不得阻塞或读磁盘。
/// 默认临时网络会话不使用 URLCache、Cookie 或凭据仓库。可传受控配置协调认证静态资源，
/// SDK 不读取 WKHTTPCookieStore；重定向限原静态根，拒绝跨源携带敏感信息。
+ (nullable instancetype)managedHandlerWithScheme:(NSString *)scheme
                              originalStaticRoot:(NSURL *)originalStaticRoot
                                 enabledProvider:(BOOL (^)(void))enabledProvider
                            networkConfiguration:(nullable NSURLSessionConfiguration *)networkConfiguration
                                           error:(NSError * _Nullable * _Nullable)error;
/// directory 必须已由管理器在后台确认可用；本方法只记录不可变绑定，不读磁盘。
- (BOOL)bindDirectory:(NSURL *)directory entryFile:(NSString *)entryFile error:(NSError * _Nullable * _Nullable)error;
/// 托管入口的纯 URL 映射；不根据全局 latest 选文件，也不检查磁盘。
- (nullable NSURL *)offlineURLForOriginalURL:(NSURL *)URL;
/// 旧入口：仅存在可用本地资源时转换，保留 query/fragment。
- (nullable NSURL *)offlineURLForURL:(NSURL *)URL;
/// 离开本页文档或关闭本页时显式释放任务；不会影响应用级管理器。
- (void)dispose;
@end
NS_ASSUME_NONNULL_END
