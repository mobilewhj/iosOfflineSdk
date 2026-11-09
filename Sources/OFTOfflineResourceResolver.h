#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface OFTOfflineResource : NSObject
@property (nonatomic, copy, readonly) NSURL *fileURL;
@property (nonatomic, copy, readonly) NSString *MIMEType;
@property (nonatomic, copy, readonly, nullable) NSString *textEncodingName;
@end

/// Maps original HTTP(S) URLs to files in one immutable version directory.
/// It does not install a WebKit delegate or change the page's origin.
@interface OFTOfflineResourceResolver : NSObject
- (nullable instancetype)initWithDirectory:(NSURL *)directory baseURL:(NSURL *)baseURL;
- (instancetype)init NS_UNAVAILABLE;
/// 纯 URL 范围校验，供托管页面和显式回源复用；不访问文件系统。
+ (BOOL)URL:(NSURL *)URL isWithinStaticRoot:(NSURL *)baseURL;
+ (BOOL)isValidStaticRoot:(NSURL *)baseURL;
/// File-loading only: allows HTTP/HTTPS aliases on the same host/path at their default ports.
/// Returns a matching root with the entry's protocol; never rewrites the entry or any network request.
/// Non-default ports retain strict origin matching. Custom scheme handlers must use the strict API above.
+ (nullable NSURL *)fileStaticRootForURL:(NSURL *)URL configuredStaticRoot:(NSURL *)baseURL;
- (nullable OFTOfflineResource *)resourceForRequest:(NSURLRequest *)request;
@end
NS_ASSUME_NONNULL_END
