#import "OFTOfflineResourceResolver.h"
#import "OFTOfflineInternal.h"
#import <sys/stat.h>

@interface OFTOfflineResource ()
@property (nonatomic, copy) NSURL *fileURL;
@property (nonatomic, copy) NSString *MIMEType;
@property (nonatomic, copy) NSString *textEncodingName;
@end
@implementation OFTOfflineResource
@end
@interface OFTOfflineResourceResolver ()
@property NSURL *directory;
@property NSURLComponents *base;
@end
@implementation OFTOfflineResourceResolver
static BOOL OFTSafePath(NSString *path) {
    return path && ![path containsString:@"\\"] && [path rangeOfString:@"\0"].location == NSNotFound &&
        ![path.pathComponents containsObject:@".."] && ![path.pathComponents containsObject:@"."];
}
static NSInteger OFTPort(NSURLComponents *url) { return url.port ? url.port.integerValue : ([url.scheme.lowercaseString isEqualToString:@"https"] ? 443 : 80); }
- (instancetype)initWithDirectory:(NSURL *)directory baseURL:(NSURL *)baseURL {
    NSURLComponents *base = [NSURLComponents componentsWithURL:baseURL resolvingAgainstBaseURL:NO];
    struct stat info;
    if (!directory.isFileURL || lstat(directory.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) ||
        ![@[@"http", @"https"] containsObject:base.scheme.lowercaseString] || !base.host.length ||
        base.user || base.password || base.query || base.fragment || ![base.path hasSuffix:@"/"] || !OFTSafePath(base.path)) return nil;
    if ((self = [super init])) { _directory = directory.URLByResolvingSymlinksInPath; _base = base; }
    return self;
}
- (OFTOfflineResource *)resourceForRequest:(NSURLRequest *)request {
    if (![request.HTTPMethod isEqualToString:@"GET"] || [request valueForHTTPHeaderField:@"Range"]) return nil;
    NSURLComponents *url = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    if (!url.scheme.length || !url.host.length || [url.scheme caseInsensitiveCompare:self.base.scheme] != NSOrderedSame ||
        [url.host caseInsensitiveCompare:self.base.host] != NSOrderedSame || OFTPort(url) != OFTPort(self.base) ||
        url.user || url.password || !OFTSafePath(url.path) || ![url.path hasPrefix:self.base.path]) return nil;
    NSString *relative = [url.path substringFromIndex:self.base.path.length];
    if (!relative.length) relative = @"index.html";
    NSURL *file = [self.directory URLByAppendingPathComponent:relative];
    NSString *rootPrefix = [self.directory.path stringByAppendingString:@"/"];
    if (![file.URLByResolvingSymlinksInPath.path hasPrefix:rootPrefix] || !OFTRegularNonemptyFile(file)) return nil;
    // Reject every symlink component, including links that happen to point inside the root.
    NSURL *component = file;
    while (![component.path isEqualToString:self.directory.path]) {
        struct stat info;
        if (lstat(component.fileSystemRepresentation, &info) != 0 || S_ISLNK(info.st_mode)) return nil;
        component = component.URLByDeletingLastPathComponent;
    }
    NSDictionary *types = @{@"html":@"text/html", @"htm":@"text/html", @"js":@"text/javascript", @"mjs":@"text/javascript",
        @"css":@"text/css", @"json":@"application/json", @"svg":@"image/svg+xml", @"png":@"image/png",
        @"jpg":@"image/jpeg", @"jpeg":@"image/jpeg", @"gif":@"image/gif", @"webp":@"image/webp", @"ico":@"image/x-icon",
        @"woff":@"font/woff", @"woff2":@"font/woff2", @"ttf":@"font/ttf", @"otf":@"font/otf", @"wasm":@"application/wasm",
        @"pdf":@"application/pdf", @"txt":@"text/plain", @"map":@"application/json"};
    NSString *type = types[relative.pathExtension.lowercaseString];
    if (!type) return nil;
    OFTOfflineResource *resource = [OFTOfflineResource new]; resource.fileURL = file; resource.MIMEType = type;
    if ([type hasPrefix:@"text/"] || [@[@"application/json", @"image/svg+xml"] containsObject:type]) resource.textEncodingName = @"utf-8";
    return resource;
}
@end
