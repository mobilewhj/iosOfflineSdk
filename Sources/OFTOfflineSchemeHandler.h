#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Optional WKWebView adapter. One handler binds one immutable package directory.
/// Only custom schemes are accepted; HTTP(S) interception is not supported by WebKit.
/// No remote fallback, user information, cookies, CORS overrides or business routing.
@interface OFTOfflineSchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic, copy, readonly) NSString *scheme;
/// baseURL is the original HTTP(S) resource directory, with a trailing slash.
- (nullable instancetype)initWithDirectory:(NSURL *)directory
                                  baseURL:(NSURL *)baseURL
                                   scheme:(NSString *)scheme;
- (instancetype)init NS_UNAVAILABLE;
/// Returns a custom URL only when the original request maps to an existing local resource.
/// Query and fragment are preserved; neither participates in file lookup.
- (nullable NSURL *)offlineURLForURL:(NSURL *)URL;
@end
NS_ASSUME_NONNULL_END
