#import <XCTest/XCTest.h>
#import <OfflineTool/OfflineTool.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>

/// 此处是 handler 的确定性回归；真实 WKWebView 证据由独立管理入口消费者另行提供。
@interface OFTManagedSchemeTask : NSObject <WKURLSchemeTask>
@property (nonatomic, copy) NSURLRequest *request;
@property NSMutableArray<NSString *> *events;
@property NSMutableData *data;
@property NSURLResponse *response;
@property NSError *error;
@property (copy) void (^responseBlock)(void);
@property (copy) void (^dataBlock)(void);
@property (copy) void (^terminalBlock)(void);
@end
@implementation OFTManagedSchemeTask
- (instancetype)init { if ((self = [super init])) { _events = [NSMutableArray new]; _data = [NSMutableData new]; } return self; }
- (void)didReceiveResponse:(NSURLResponse *)response { self.response = response; [self.events addObject:@"response"]; if (self.responseBlock) self.responseBlock(); }
- (void)didReceiveData:(NSData *)data { [self.data appendData:data]; [self.events addObject:@"data"]; if (self.dataBlock) self.dataBlock(); }
- (void)didFinish { [self.events addObject:@"finish"]; if (self.terminalBlock) self.terminalBlock(); }
- (void)didFailWithError:(NSError *)error { self.error = error; [self.events addObject:@"error"]; if (self.terminalBlock) self.terminalBlock(); }
@end

@interface OFTManagedHandlerTests : XCTestCase
@property NSURL *directory;
@property OFTOfflineSchemeHandler *handler;
@property BOOL enabled;
@end
@implementation OFTManagedHandlerTests
- (void)setUp {
    self.directory = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
    [@"local A" writeToURL:[self.directory URLByAppendingPathComponent:@"index.html"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    self.enabled = YES;
}
- (void)tearDown { [self.handler dispose]; [[NSFileManager defaultManager] removeItemAtURL:self.directory error:nil]; }
- (void)configureRoot:(NSURL *)root {
    __weak OFTManagedHandlerTests *weakSelf = self;
    self.handler = [OFTOfflineSchemeHandler managedHandlerWithScheme:@"managed-test" originalStaticRoot:root
        enabledProvider:^{ return weakSelf.enabled; } networkConfiguration:nil error:nil];
    XCTAssertNotNil(self.handler);
    XCTAssertTrue([self.handler bindDirectory:self.directory entryFile:@"index.html" error:nil]);
}
- (OFTManagedSchemeTask *)taskForOriginal:(NSURL *)URL {
    OFTManagedSchemeTask *task = [OFTManagedSchemeTask new];
    task.request = [NSURLRequest requestWithURL:[self.handler offlineURLForOriginalURL:URL]]; return task;
}
- (void)runTask:(OFTManagedSchemeTask *)task {
    XCTestExpectation *done = [self expectationWithDescription:@"unique terminal"];
    task.terminalBlock = ^{ [done fulfill]; };
    [self.handler webView:nil startURLSchemeTask:task]; [self waitForExpectations:@[done] timeout:5];
    NSUInteger terminalCount = 0;
    for (NSString *event in task.events) if ([event isEqualToString:@"finish"] || [event isEqualToString:@"error"]) terminalCount++;
    XCTAssertEqual(terminalCount, 1);
}
/// 有界一次/两次 HTTP 测试源，记录实际请求；没有业务账号或生产地址。
- (NSURL *)serverBody:(NSData *)body status:(NSInteger)status headers:(NSDictionary *)headers
    redirects:(nullable NSString *)redirect requestObserver:(void (^)(NSString *))observer delayBody:(BOOL)delay {
    int listener = socket(AF_INET, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(listener, 0);
    struct timeval timeout = {5, 0}; setsockopt(listener, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in address = {0}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    XCTAssertEqual(bind(listener, (struct sockaddr *)&address, sizeof(address)), 0); XCTAssertEqual(listen(listener, 2), 0);
    socklen_t size = sizeof(address); getsockname(listener, (struct sockaddr *)&address, &size);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSUInteger count = redirect && [redirect hasPrefix:@"/app/"] ? 2 : 1;
        for (NSUInteger index = 0; index < count; index++) {
            int client = accept(listener, NULL, NULL); if (client < 0) break;
            int noSigPipe = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            char requestBuffer[8192] = {0}; ssize_t received = recv(client, requestBuffer, sizeof(requestBuffer) - 1, 0);
            NSString *request = received > 0 ? [[NSString alloc] initWithBytes:requestBuffer length:(NSUInteger)received encoding:NSUTF8StringEncoding] : @"";
            if (observer) dispatch_async(dispatch_get_main_queue(), ^{ observer(request); });
            BOOL isRedirect = redirect && index == 0;
            NSMutableString *head = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld Test\r\nConnection: close\r\nContent-Length: %lu\r\n", (long)(isRedirect ? 302 : status), (unsigned long)(isRedirect ? 0 : body.length)];
            if (isRedirect) [head appendFormat:@"Location: %@\r\n", redirect];
            for (NSString *key in headers) [head appendFormat:@"%@: %@\r\n", key, headers[key]];
            [head appendString:@"\r\n"];
            NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding]; send(client, headData.bytes, headData.length, 0);
            if (delay) usleep(200000);
            if (!isRedirect) {
                NSUInteger offset = 0;
                while (offset < body.length) {
                    ssize_t sent = send(client, (const uint8_t *)body.bytes + offset, body.length - offset, 0);
                    if (sent <= 0) break; offset += (NSUInteger)sent;
                }
            }
            close(client);
        }
        close(listener);
    });
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%hu/app/", ntohs(address.sin_port)]];
}
- (void)testUnboundMappingSupportsManagerDecisionThenSingleBinding {
    NSURL *root = [NSURL URLWithString:@"https://static.example/app/"];
    self.handler = [OFTOfflineSchemeHandler managedHandlerWithScheme:@"managed-test" originalStaticRoot:root
        enabledProvider:^{ return YES; } networkConfiguration:nil error:nil];
    NSURL *entry = [root URLByAppendingPathComponent:@"index.html"];
    // 管理器在最终选择目录前先验证映射；纯 URL 检查不得要求已有目录绑定。
    XCTAssertEqualObjects([self.handler offlineURLForOriginalURL:entry].absoluteString, @"managed-test://static.example/app/index.html");
    OFTManagedSchemeTask *premature = [self taskForOriginal:entry]; [self runTask:premature];
    XCTAssertEqualObjects(premature.events, (@[@"error"]));
    XCTAssertTrue([self.handler bindDirectory:self.directory entryFile:@"index.html" error:nil]);
    OFTManagedSchemeTask *bound = [self taskForOriginal:entry]; [self runTask:bound];
    XCTAssertNil(bound.error); XCTAssertEqualObjects([[NSString alloc] initWithData:bound.data encoding:NSUTF8StringEncoding], @"local A");
}
- (void)testBindingIsOnceAndPureURLMappingRejectsForeignAndTraversal {
    NSURL *root = [NSURL URLWithString:@"https://static.example/app/"]; [self configureRoot:root];
    XCTAssertFalse([self.handler bindDirectory:self.directory entryFile:@"index.html" error:nil]);
    XCTAssertEqualObjects([self.handler offlineURLForOriginalURL:[NSURL URLWithString:@"https://static.example/app/missing.js?v=1#route"]].absoluteString,
        @"managed-test://static.example/app/missing.js?v=1#route");
    for (NSString *bad in @[@"https://other.example/app/a.js", @"http://static.example/app/a.js", @"https://static.example/api/a.js", @"https://static.example/app/%2e%2e/a.js", @"https://user:pw@static.example/app/a.js"]) {
        XCTAssertNil([self.handler offlineURLForOriginalURL:[NSURL URLWithString:bad]]);
    }
    [[NSFileManager defaultManager] removeItemAtURL:self.directory error:nil];
    XCTAssertNotNil([self.handler offlineURLForOriginalURL:[root URLByAppendingPathComponent:@"index.html"]]);
}
- (void)testLargeLocalResponseStreamsBoundedChunksAndPreservesBytes {
    [self configureRoot:[NSURL URLWithString:@"https://static.example/app/"]];
    NSMutableData *body = [NSMutableData dataWithLength:2 * 1024 * 1024];
    uint8_t *bytes = body.mutableBytes; for (NSUInteger i = 0; i < body.length; i++) bytes[i] = (uint8_t)(i % 251);
    [body writeToURL:[self.directory URLByAppendingPathComponent:@"image.png"] atomically:YES];
    OFTManagedSchemeTask *task = [self taskForOriginal:[NSURL URLWithString:@"https://static.example/app/image.png"]];
    [self runTask:task]; XCTAssertNil(task.error); XCTAssertEqualObjects(task.data, body);
    XCTAssertGreaterThan(task.events.count, 10); XCTAssertEqualObjects(task.response.MIMEType, @"image/png");
}
- (void)testMissingStaticUsesOriginalQueryRangeHeaders206AndBinary {
    const uint8_t raw[] = {0, 255, 4, 0, 17}; NSData *body = [NSData dataWithBytes:raw length:sizeof(raw)];
    __block NSString *observed;
    NSURL *root = [self serverBody:body status:206 headers:@{@"Content-Type":@"image/png", @"Content-Range":@"bytes 0-4/20"}
        redirects:nil requestObserver:^(NSString *request) { observed = request; } delayBody:NO];
    [self configureRoot:root];
    OFTManagedSchemeTask *task = [self taskForOriginal:[NSURL URLWithString:@"missing.png?signature=synthetic" relativeToURL:root].absoluteURL];
    NSMutableURLRequest *request = task.request.mutableCopy;
    [request setValue:@"bytes=0-4" forHTTPHeaderField:@"Range"]; [request setValue:@"synthetic-etag" forHTTPHeaderField:@"If-Range"]; task.request = request;
    [self runTask:task];
    XCTAssertNil(task.error); XCTAssertEqualObjects(task.data, body); XCTAssertEqual(((NSHTTPURLResponse *)task.response).statusCode, 206);
    XCTAssertEqualObjects(((NSHTTPURLResponse *)task.response).allHeaderFields[@"Content-Range"], @"bytes 0-4/20");
    XCTAssertTrue([observed containsString:@"GET /app/missing.png?signature=synthetic HTTP/1.1"]);
    XCTAssertTrue([observed.lowercaseString containsString:@"range: bytes=0-4"]); XCTAssertTrue([observed.lowercaseString containsString:@"if-range: synthetic-etag"]);
}
- (void)testDisabledOldPageGoesOnlineAndReenabledStaysAtSameDirectory {
    NSData *remote = [@"online" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *root = [self serverBody:remote status:200 headers:@{@"Content-Type":@"text/html"} redirects:nil requestObserver:nil delayBody:NO];
    [self configureRoot:root];
    NSURL *entry = [root URLByAppendingPathComponent:@"index.html"];
    OFTManagedSchemeTask *first = [self taskForOriginal:entry]; [self runTask:first];
    XCTAssertEqualObjects([[NSString alloc] initWithData:first.data encoding:NSUTF8StringEncoding], @"local A");
    self.enabled = NO; OFTManagedSchemeTask *disabled = [self taskForOriginal:entry]; [self runTask:disabled]; XCTAssertEqualObjects(disabled.data, remote);
    self.enabled = YES; OFTManagedSchemeTask *again = [self taskForOriginal:entry]; [self runTask:again]; XCTAssertEqualObjects(again.data, first.data);
}
- (void)testUnreadableOrReplacedLocalResourceFallsBackBeforeResponse {
    NSData *remote = [@"remote replaced resource" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *root = [self serverBody:remote status:200 headers:@{@"Content-Type":@"text/html"} redirects:nil requestObserver:nil delayBody:NO];
    [self configureRoot:root];
    NSURL *entry = [self.directory URLByAppendingPathComponent:@"index.html"];
    [[NSFileManager defaultManager] removeItemAtURL:entry error:nil];
    [[NSFileManager defaultManager] createDirectoryAtURL:entry withIntermediateDirectories:NO attributes:nil error:nil];
    OFTManagedSchemeTask *task = [self taskForOriginal:[root URLByAppendingPathComponent:@"index.html"]]; [self runTask:task];
    XCTAssertNil(task.error); XCTAssertEqualObjects(task.data, remote); XCTAssertEqualObjects(task.events.firstObject, @"response");
}
- (void)testNonGETAndOutOfRootCannotBecomeBusinessProxy {
    [self configureRoot:[NSURL URLWithString:@"https://static.example/app/"]];
    for (NSString *address in @[@"managed-test://static.example/app/index.html", @"managed-test://static.example/api/session"]) {
        OFTManagedSchemeTask *task = [OFTManagedSchemeTask new]; NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
        request.HTTPMethod = @"POST"; request.HTTPBody = [@"synthetic" dataUsingEncoding:NSUTF8StringEncoding]; task.request = request;
        [self runTask:task]; XCTAssertEqualObjects(task.events, (@[@"error"]));
    }
}
- (void)testSameRootRedirectFinishesAndOutsideRedirectFailsOnce {
    for (NSString *redirect in @[@"/app/final.js", @"/app/theme/style.css", @"http://other.example/private.js"]) {
        NSData *body = [@"redirected" dataUsingEncoding:NSUTF8StringEncoding];
        NSURL *root = [self serverBody:body status:200 headers:@{@"Content-Type":@"text/javascript"} redirects:redirect requestObserver:nil delayBody:NO];
        [self configureRoot:root]; OFTManagedSchemeTask *task = [self taskForOriginal:[root URLByAppendingPathComponent:@"redirect.js"]]; [self runTask:task];
        if ([redirect hasPrefix:@"/app/"]) {
            XCTAssertNil(task.error); XCTAssertEqualObjects(task.data, body);
            // 响应地址须保留重定向后的目录；否则 CSS 的相对图片仍按旧目录寻址。
            NSURL *finalURL = [NSURL URLWithString:redirect relativeToURL:root].absoluteURL;
            XCTAssertEqualObjects(task.response.URL, [self.handler offlineURLForOriginalURL:finalURL]);
        }
        else { XCTAssertNotNil(task.error); XCTAssertEqual(task.data.length, 0); }
        [self.handler dispose];
    }
}
- (void)testHTTPErrorStatusRemainsResponseAndNetworkFailureIsUniqueError {
    NSData *body = [@"not found" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *root = [self serverBody:body status:404 headers:@{@"Content-Type":@"text/plain"} redirects:nil requestObserver:nil delayBody:NO];
    [self configureRoot:root]; OFTManagedSchemeTask *task = [self taskForOriginal:[root URLByAppendingPathComponent:@"missing.js"]]; [self runTask:task];
    XCTAssertNil(task.error); XCTAssertEqual(((NSHTTPURLResponse *)task.response).statusCode, 404); XCTAssertEqualObjects(task.data, body);
    [self.handler dispose]; [self configureRoot:[NSURL URLWithString:@"http://127.0.0.1:1/app/"]];
    OFTManagedSchemeTask *failed = [self taskForOriginal:[NSURL URLWithString:@"http://127.0.0.1:1/app/missing.js"]]; [self runTask:failed]; XCTAssertNotNil(failed.error);
}
- (void)testDisposeFromNetworkResponseStopsLateDataAndTerminal {
    NSURL *root = [self serverBody:[@"late bytes" dataUsingEncoding:NSUTF8StringEncoding] status:200 headers:@{@"Content-Type":@"text/plain"}
        redirects:nil requestObserver:nil delayBody:YES];
    [self configureRoot:root]; OFTManagedSchemeTask *task = [self taskForOriginal:[root URLByAppendingPathComponent:@"missing.js"]];
    XCTestExpectation *response = [self expectationWithDescription:@"response"];
    XCTestExpectation *late = [self expectationWithDescription:@"no late callback"]; late.inverted = YES;
    task.responseBlock = ^{ [self.handler dispose]; [response fulfill]; }; task.dataBlock = ^{ [late fulfill]; }; task.terminalBlock = ^{ [late fulfill]; };
    [self.handler webView:nil startURLSchemeTask:task]; [self waitForExpectations:@[response, late] timeout:0.5];
    XCTAssertEqualObjects(task.events, (@[@"response"]));
}
- (void)testStopAfterFirstLocalChunkCancelsRemainingBoundedRead {
    [self configureRoot:[NSURL URLWithString:@"https://static.example/app/"]];
    [[NSMutableData dataWithLength:8 * 1024 * 1024] writeToURL:[self.directory URLByAppendingPathComponent:@"large.png"] atomically:YES];
    OFTManagedSchemeTask *task = [self taskForOriginal:[NSURL URLWithString:@"https://static.example/app/large.png"]];
    XCTestExpectation *chunk = [self expectationWithDescription:@"first chunk"];
    XCTestExpectation *late = [self expectationWithDescription:@"no finish after stop"]; late.inverted = YES;
    __weak OFTManagedSchemeTask *weakTask = task;
    task.dataBlock = ^{ [self.handler webView:nil stopURLSchemeTask:weakTask]; [chunk fulfill]; }; task.terminalBlock = ^{ [late fulfill]; };
    [self.handler webView:nil startURLSchemeTask:task]; [self waitForExpectations:@[chunk, late] timeout:0.3];
    XCTAssertEqual(task.data.length, 64 * 1024); XCTAssertEqualObjects(task.events, (@[@"response", @"data"]));
}
- (void)testCompressedNetworkBodyIsDeliveredOnceWithMatchingEncodingHeaders {
    const uint8_t compressed[] = {31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 75, 206, 207, 45, 40, 74, 45, 46, 78, 77, 209, 45, 46, 73, 44, 201, 76, 102, 248, 15, 0, 178, 22, 155, 17, 19, 0, 0, 0};
    const uint8_t raw[] = {99, 111, 109, 112, 114, 101, 115, 115, 101, 100, 45, 115, 116, 97, 116, 105, 99, 0, 255};
    NSData *expected = [NSData dataWithBytes:raw length:sizeof(raw)];
    NSURL *root = [self serverBody:[NSData dataWithBytes:compressed length:sizeof(compressed)] status:200
        headers:@{@"Content-Type":@"image/png", @"Content-Encoding":@"gzip"} redirects:nil requestObserver:nil delayBody:NO];
    [self configureRoot:root]; OFTManagedSchemeTask *task = [self taskForOriginal:[root URLByAppendingPathComponent:@"compressed.png"]];
    [self runTask:task]; XCTAssertNil(task.error); XCTAssertEqualObjects(task.data, expected);
    for (NSString *key in ((NSHTTPURLResponse *)task.response).allHeaderFields) {
        XCTAssertNotEqual([key caseInsensitiveCompare:@"Content-Encoding"], NSOrderedSame);
    }
}
@end
