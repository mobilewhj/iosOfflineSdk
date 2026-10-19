#import "OFTOfflineSchemeHandler.h"
#import "OFTOfflineResourceResolver.h"
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSError *OFTResourceError(NSInteger code) {
    return [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil];
}
static BOOL OFTCustomScheme(NSString *scheme) {
    NSCharacterSet *letters = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789+.-"];
    return scheme.length && [letters characterIsMember:[scheme characterAtIndex:0]] &&
        [scheme rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound && ![WKWebView handlesURLScheme:scheme];
}

/// 只由后台读取队列使用；释放时关闭文件，取消最多留下当前一个 64KiB 读取。
@interface OFTResourceReader : NSObject
@property int descriptor;
@property int64_t length;
@property int64_t delivered;
@end
@implementation OFTResourceReader
- (instancetype)init { if ((self = [super init])) _descriptor = -1; return self; }
- (void)dealloc { if (_descriptor >= 0) close(_descriptor); }
@end

@interface OFTResourceTask : NSObject
@property (atomic) BOOL cancelled;
@property id<WKURLSchemeTask> schemeTask;
@property NSURLRequest *request;
@property NSURLSessionDataTask *networkTask;
@property NSURLSession *networkSession;
@property OFTResourceReader *reader;
@property BOOL responseSent;
@end
@implementation OFTResourceTask
@end

@class OFTResourceNetworkDelegate;
@interface OFTOfflineSchemeHandler ()
@property OFTOfflineResourceResolver *resolver;
@property NSURL *directory;
@property NSURL *originalStaticRoot;
@property (nonatomic, copy) NSString *originalScheme;
@property (nonatomic, copy) BOOL (^enabledProvider)(void);
@property NSURLSessionConfiguration *networkConfiguration;
@property NSMapTable<id<WKURLSchemeTask>, OFTResourceTask *> *tasks;
@property dispatch_queue_t readQueue;
@property BOOL managed;
@property BOOL bound;
@property BOOL disposed;
- (BOOL)isCurrent:(OFTResourceTask *)state;
- (void)finishState:(OFTResourceTask *)state error:(nullable NSError *)error;
- (void)fallbackState:(OFTResourceTask *)state originalRequest:(NSURLRequest *)request;
- (void)readNextState:(OFTResourceTask *)state firstResource:(nullable OFTOfflineResource *)resource;
@end

/// 每个静态回源有独立会话和任务，delegate 不持有页面 handler。
@interface OFTResourceNetworkDelegate : NSObject <NSURLSessionDataDelegate>
@property (weak) OFTOfflineSchemeHandler *handler;
@property (weak) OFTResourceTask *state;
@end
@implementation OFTResourceNetworkDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
 didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    OFTResourceTask *state = self.state;
    OFTOfflineSchemeHandler *handler = self.handler;
    if (![handler isCurrent:state]) { completionHandler(NSURLSessionResponseCancel); return; }
    if (![response isKindOfClass:NSHTTPURLResponse.class]) {
        completionHandler(NSURLSessionResponseCancel);
        [handler finishState:state error:OFTResourceError(NSURLErrorBadServerResponse)]; return;
    }
    NSHTTPURLResponse *HTTP = (NSHTTPURLResponse *)response;
    // 状态、MIME、Range/条件响应头保持网络事实；不伪造 CORS 放宽或 HTTP 200。
    NSMutableDictionary *headers = HTTP.allHeaderFields.mutableCopy;
    // URLSession 会解码常见压缩表示；交给 WebKit 的头须描述实际解码后字节，避免二次解码。
    NSString *encoding;
    for (NSString *key in headers.allKeys) if ([key caseInsensitiveCompare:@"Content-Encoding"] == NSOrderedSame) encoding = [headers[key] lowercaseString];
    if ([@[@"gzip", @"deflate", @"br"] containsObject:encoding]) {
        for (NSString *key in headers.allKeys) if ([key caseInsensitiveCompare:@"Content-Encoding"] == NSOrderedSame ||
            [key caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) [headers removeObjectForKey:key];
    }
    // CSS 相对资源以最终响应地址为基准；同根重定向后继续映射真实终点，不能沿用起点目录。
    NSURL *finalURL = [handler offlineURLForOriginalURL:HTTP.URL];
    if (!finalURL) {
        completionHandler(NSURLSessionResponseCancel);
        [handler finishState:state error:OFTResourceError(NSURLErrorBadServerResponse)]; return;
    }
    NSHTTPURLResponse *mapped = [[NSHTTPURLResponse alloc] initWithURL:finalURL statusCode:HTTP.statusCode
        HTTPVersion:@"HTTP/1.1" headerFields:headers];
    state.responseSent = YES;
    [state.schemeTask didReceiveResponse:mapped];
    completionHandler([handler isCurrent:state] ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    OFTResourceTask *state = self.state;
    OFTOfflineSchemeHandler *handler = self.handler;
    if (![handler isCurrent:state]) return;
    [state.schemeTask didReceiveData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    OFTResourceTask *state = self.state;
    OFTOfflineSchemeHandler *handler = self.handler;
    if ([handler isCurrent:state]) [handler finishState:state error:error];
    [session finishTasksAndInvalidate];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    OFTResourceTask *state = self.state;
    OFTOfflineSchemeHandler *handler = self.handler;
    // 不允许静态回源跳出原根，包括跨源重定向，因而不会跨源发送 Cookie/认证头。
    if (![handler isCurrent:state] || ![OFTOfflineResourceResolver URL:request.URL isWithinStaticRoot:handler.originalStaticRoot] ||
        ![request.HTTPMethod isEqualToString:@"GET"]) {
        completionHandler(nil);
        if ([handler isCurrent:state]) [handler finishState:state error:OFTResourceError(NSURLErrorRedirectToNonExistentLocation)];
        return;
    }
    completionHandler(request);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    // 使用系统 ATS/TLS 评估；SDK 不接管信任、不输出认证内容。
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

@implementation OFTOfflineSchemeHandler
- (instancetype)initWithDirectory:(NSURL *)directory baseURL:(NSURL *)baseURL scheme:(NSString *)scheme {
    NSString *lower = scheme.lowercaseString;
    if (!OFTCustomScheme(lower)) return nil;
    OFTOfflineResourceResolver *resolver = [[OFTOfflineResourceResolver alloc] initWithDirectory:directory baseURL:baseURL];
    if (!resolver) return nil;
    if ((self = [super init])) {
        [self setUpScheme:lower root:baseURL];
        _resolver = resolver; _directory = directory; _bound = YES;
    }
    return self;
}
- (void)setUpScheme:(NSString *)scheme root:(NSURL *)root {
    _scheme = scheme.copy; _originalScheme = root.scheme.lowercaseString; _originalStaticRoot = root.copy;
    _tasks = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                 valueOptions:NSPointerFunctionsStrongMemory];
    _readQueue = dispatch_queue_create("com.offline.tool.resources", DISPATCH_QUEUE_SERIAL);
}
+ (instancetype)managedHandlerWithScheme:(NSString *)scheme originalStaticRoot:(NSURL *)root
 enabledProvider:(BOOL (^)(void))enabledProvider networkConfiguration:(NSURLSessionConfiguration *)configuration error:(NSError **)error {
    NSString *lower = scheme.lowercaseString;
    if (!OFTCustomScheme(lower) || ![OFTOfflineResourceResolver isValidStaticRoot:root] || !enabledProvider) {
        if (error) *error = OFTResourceError(NSURLErrorUnsupportedURL); return nil;
    }
    OFTOfflineSchemeHandler *handler = [[self alloc] initPrivate];
    [handler setUpScheme:lower root:root]; handler.managed = YES; handler.enabledProvider = enabledProvider;
    NSURLSessionConfiguration *network = configuration ? configuration.copy : NSURLSessionConfiguration.ephemeralSessionConfiguration;
    network.URLCache = nil; network.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    if (!configuration) { network.HTTPCookieStorage = nil; network.HTTPShouldSetCookies = NO; network.URLCredentialStorage = nil; }
    handler.networkConfiguration = network;
    return handler;
}
- (instancetype)initPrivate { return [super init]; }
- (BOOL)bindDirectory:(NSURL *)directory entryFile:(NSString *)entryFile error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Page binding must run on main");
    if (!self.managed || self.bound || self.disposed || !directory.isFileURL || ![entryFile isEqualToString:@"index.html"]) {
        if (error) *error = OFTResourceError(NSURLErrorUnsupportedURL); return NO;
    }
    // 管理器已在后台观察规范目录；这里不做 lstat/读取，避免 Main 的磁盘工作。
    self.directory = directory.copy; self.bound = YES; return YES;
}
- (NSURL *)offlineURLForOriginalURL:(NSURL *)URL {
    if (self.disposed || ![OFTOfflineResourceResolver URL:URL isWithinStaticRoot:self.originalStaticRoot]) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    parts.scheme = self.scheme; return parts.URL;
}
- (NSURL *)offlineURLForURL:(NSURL *)URL {
    if (self.managed) return [self offlineURLForOriginalURL:URL];
    if (!URL || self.disposed || ![self.resolver resourceForRequest:[NSURLRequest requestWithURL:URL]]) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    parts.scheme = self.scheme; return parts.URL;
}
- (BOOL)isCurrent:(OFTResourceTask *)state {
    return state && !state.cancelled && !self.disposed && [self.tasks objectForKey:state.schemeTask] == state;
}
- (void)finishState:(OFTResourceTask *)state error:(NSError *)error {
    if (![self isCurrent:state]) return;
    [self.tasks removeObjectForKey:state.schemeTask]; state.cancelled = YES;
    [state.networkTask cancel]; [state.networkSession finishTasksAndInvalidate];
    if (error) [state.schemeTask didFailWithError:error]; else [state.schemeTask didFinish];
}
- (NSURLRequest *)originalRequest:(NSURLRequest *)request {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    if (![parts.scheme.lowercaseString isEqualToString:self.scheme]) return nil;
    parts.scheme = self.originalScheme;
    if (!parts.URL || ![OFTOfflineResourceResolver URL:parts.URL isWithinStaticRoot:self.originalStaticRoot]) return nil;
    NSMutableURLRequest *original = request.mutableCopy; original.URL = parts.URL;
    return original;
}
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSAssert(NSThread.isMainThread, @"WebKit scheme callbacks must run on the main thread");
    if (self.disposed) { [task didFailWithError:OFTResourceError(NSURLErrorCancelled)]; return; }
    OFTResourceTask *previous = [self.tasks objectForKey:task];
    if (previous) { previous.cancelled = YES; [previous.networkTask cancel]; [previous.networkSession invalidateAndCancel]; }
    OFTResourceTask *state = [OFTResourceTask new]; state.schemeTask = task; state.request = task.request.copy;
    [self.tasks setObject:state forKey:task];
    NSURLRequest *original = [self originalRequest:state.request];
    if (!self.bound || !original || ![original.HTTPMethod isEqualToString:@"GET"]) {
        [self finishState:state error:OFTResourceError(NSURLErrorUnsupportedURL)]; return;
    }
    // 开关在作出本次资源决定时读取；已成立响应不因稍后关闭被撤销。
    BOOL localAllowed = !self.managed || self.enabledProvider();
    if (self.managed && (!localAllowed || [original valueForHTTPHeaderField:@"Range"])) {
        [self fallbackState:state originalRequest:original]; return;
    }
    NSURL *directory = self.directory; NSURL *root = self.originalStaticRoot;
    OFTOfflineResourceResolver *legacy = self.resolver;
    __weak OFTOfflineSchemeHandler *weakSelf = self;
    dispatch_async(self.readQueue, ^{
        if (state.cancelled) return;
        OFTOfflineResourceResolver *resolver = legacy ?: [[OFTOfflineResourceResolver alloc] initWithDirectory:directory baseURL:root];
        OFTOfflineResource *resource = [resolver resourceForRequest:original];
        OFTResourceReader *reader;
        if (resource && !state.cancelled) {
            reader = [OFTResourceReader new]; reader.descriptor = open(resource.fileURL.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
            struct stat info;
            if (reader.descriptor < 0 || fstat(reader.descriptor, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0) reader = nil;
            else reader.length = info.st_size;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            OFTOfflineSchemeHandler *handler = weakSelf;
            if (![handler isCurrent:state]) return;
            if (!reader) { [handler fallbackState:state originalRequest:original]; return; }
            state.reader = reader; [handler readNextState:state firstResource:resource];
        });
    });
}
- (void)readNextState:(OFTResourceTask *)state firstResource:(OFTOfflineResource *)resource {
    __weak OFTOfflineSchemeHandler *weakSelf = self;
    dispatch_async(self.readQueue, ^{
        if (state.cancelled) { state.reader = nil; return; }
        uint8_t buffer[64 * 1024]; ssize_t count;
        do { count = read(state.reader.descriptor, buffer, sizeof(buffer)); } while (count < 0 && errno == EINTR && !state.cancelled);
        NSData *chunk = count > 0 ? [NSData dataWithBytes:buffer length:(NSUInteger)count] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            OFTOfflineSchemeHandler *handler = weakSelf;
            if (![handler isCurrent:state]) { state.reader = nil; return; }
            if (count <= 0) {
                BOOL complete = count == 0 && state.reader.delivered == state.reader.length;
                state.reader = nil;
                if (!state.responseSent) [handler fallbackState:state originalRequest:[handler originalRequest:state.request]];
                // 响应已成立后不能拼接另一来源；晚到读错或截断只结束本次任务。
                else [handler finishState:state error:complete ? nil : OFTResourceError(NSURLErrorCannotOpenFile)];
                return;
            }
            if (!state.responseSent) {
                NSString *type = resource.textEncodingName ? [NSString stringWithFormat:@"%@; charset=%@", resource.MIMEType, resource.textEncodingName] : resource.MIMEType;
                NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:state.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
                    headerFields:@{@"Content-Type":type, @"Content-Length":@(state.reader.length).stringValue, @"Cache-Control":@"no-store"}];
                state.responseSent = YES; [state.schemeTask didReceiveResponse:response];
            }
            if (![handler isCurrent:state]) { state.reader = nil; return; }
            state.reader.delivered += count;
            [state.schemeTask didReceiveData:chunk];
            if (![handler isCurrent:state]) { state.reader = nil; return; }
            // 下一块只有在 Main 消费上一块后读取，避免大文件/并发页积压内存。
            [handler readNextState:state firstResource:nil];
        });
    });
}
- (void)fallbackState:(OFTResourceTask *)state originalRequest:(NSURLRequest *)request {
    if (![self isCurrent:state]) return;
    if (!self.managed || !request || state.responseSent) {
        [self finishState:state error:OFTResourceError(NSURLErrorFileDoesNotExist)]; return;
    }
    OFTResourceNetworkDelegate *delegate = [OFTResourceNetworkDelegate new]; delegate.handler = self; delegate.state = state;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:self.networkConfiguration delegate:delegate delegateQueue:NSOperationQueue.mainQueue];
    NSMutableURLRequest *network = request.mutableCopy; network.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    if (![network valueForHTTPHeaderField:@"Accept-Encoding"]) [network setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    state.networkSession = session; state.networkTask = [session dataTaskWithRequest:network]; [state.networkTask resume];
}
- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSAssert(NSThread.isMainThread, @"WebKit scheme callbacks must run on the main thread");
    OFTResourceTask *state = [self.tasks objectForKey:task];
    state.cancelled = YES; [state.networkTask cancel]; [state.networkSession invalidateAndCancel];
    [self.tasks removeObjectForKey:task];
}
- (void)dispose {
    NSAssert(NSThread.isMainThread, @"Page disposal must run on main");
    if (self.disposed) return;
    self.disposed = YES;
    for (OFTResourceTask *state in self.tasks.objectEnumerator) {
        state.cancelled = YES; [state.networkTask cancel]; [state.networkSession invalidateAndCancel];
    }
    [self.tasks removeAllObjects]; self.enabledProvider = nil;
}
- (void)dealloc {
    for (OFTResourceTask *state in _tasks.objectEnumerator) {
        state.cancelled = YES; [state.networkTask cancel]; [state.networkSession invalidateAndCancel];
    }
}
@end
