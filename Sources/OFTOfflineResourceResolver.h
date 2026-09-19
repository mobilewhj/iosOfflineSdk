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
- (nullable OFTOfflineResource *)resourceForRequest:(NSURLRequest *)request;
@end
NS_ASSUME_NONNULL_END
