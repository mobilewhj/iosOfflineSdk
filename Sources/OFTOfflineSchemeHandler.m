#import "OFTOfflineSchemeHandler.h"
#import "OFTOfflineResourceResolver.h"

@interface OFTOfflineSchemeHandler ()
@property (nonatomic) OFTOfflineResourceResolver *resolver;
@property (nonatomic, copy) NSString *originalScheme;
@property (nonatomic) NSMapTable<id<WKURLSchemeTask>, NSObject *> *tasks;
@property (nonatomic) dispatch_queue_t readQueue;
@end

@implementation OFTOfflineSchemeHandler
- (instancetype)initWithDirectory:(NSURL *)directory baseURL:(NSURL *)baseURL scheme:(NSString *)scheme {
    NSString *lower = scheme.lowercaseString;
    NSCharacterSet *letters = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789+.-"];
    if (!lower.length || ![letters characterIsMember:[lower characterAtIndex:0]] ||
        [lower rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound || [WKWebView handlesURLScheme:lower]) return nil;
    OFTOfflineResourceResolver *resolver = [[OFTOfflineResourceResolver alloc] initWithDirectory:directory baseURL:baseURL];
    if (!resolver) return nil;
    if ((self = [super init])) {
        _scheme = lower.copy; _originalScheme = baseURL.scheme.lowercaseString;
        _resolver = resolver;
        _tasks = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                     valueOptions:NSPointerFunctionsStrongMemory];
        _readQueue = dispatch_queue_create("com.offline.tool.resources", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (NSURL *)offlineURLForURL:(NSURL *)URL {
    if (!URL || ![self.resolver resourceForRequest:[NSURLRequest requestWithURL:URL]]) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    parts.scheme = self.scheme;
    return parts.URL;
}
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSAssert(NSThread.isMainThread, @"WebKit scheme callbacks must run on the main thread");
    NSObject *token = [NSObject new];
    [self.tasks setObject:token forKey:task];
    NSURLRequest *request = task.request.copy;
    dispatch_async(self.readQueue, ^{
        NSURLComponents *parts = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
        OFTOfflineResource *resource;
        if ([parts.scheme.lowercaseString isEqualToString:self.scheme]) {
            parts.scheme = self.originalScheme;
            NSMutableURLRequest *original = request.mutableCopy;
            original.URL = parts.URL;
            resource = [self.resolver resourceForRequest:original];
        }
        NSError *failure;
        NSData *data = resource ? [NSData dataWithContentsOfURL:resource.fileURL options:NSDataReadingMappedIfSafe error:&failure] : nil;
        if (!data && !failure) failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist
                                                        userInfo:@{NSLocalizedDescriptionKey:@"No matching local resource"}];
        dispatch_async(dispatch_get_main_queue(), ^{
            // stopURLSchemeTask can race the file read, or be re-entered from a response callback.
            if ([self.tasks objectForKey:task] != token) return;
            if (failure) {
                [self.tasks removeObjectForKey:task]; [task didFailWithError:failure]; return;
            }
            NSString *type = resource.textEncodingName ? [NSString stringWithFormat:@"%@; charset=%@", resource.MIMEType, resource.textEncodingName] : resource.MIMEType;
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
                headerFields:@{@"Content-Type":type, @"Content-Length":@(data.length).stringValue, @"Cache-Control":@"no-store"}];
            [task didReceiveResponse:response];
            if ([self.tasks objectForKey:task] != token) return;
            [task didReceiveData:data];
            if ([self.tasks objectForKey:task] != token) return;
            [self.tasks removeObjectForKey:task]; [task didFinish];
        });
    });
}
- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSAssert(NSThread.isMainThread, @"WebKit scheme callbacks must run on the main thread");
    [self.tasks removeObjectForKey:task];
}
@end
