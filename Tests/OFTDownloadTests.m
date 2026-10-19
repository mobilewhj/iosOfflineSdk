#import <XCTest/XCTest.h>
#import <OfflineTool/OfflineTool.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <sys/param.h>
#import <objc/runtime.h>

@interface OFTDownload : NSObject
- (int)closeManagedZIPOutput:(int)descriptor;
- (NSError *)managedHTTPFailure:(NSInteger)status response:(NSHTTPURLResponse *)response;
- (BOOL)downloadURL:(NSURL *)url destination:(NSURL *)destination configuration:(NSURLSessionConfiguration *)configuration cancellation:(NSProgress *)cancellation onStarted:(dispatch_block_t)onStarted progress:(OFTInstallProgress)progress error:(NSError **)error;
@end
@interface OFTZIPCloseFaultDownload : OFTDownload
@property BOOL failClose;
@property NSUInteger closes;
@end
@implementation OFTZIPCloseFaultDownload
- (int)closeManagedZIPOutput:(int)descriptor {
    self.closes++;
    int result = [super closeManagedZIPOutput:descriptor];
    if (!result && self.failClose) { errno = EIO; return -1; }
    return result;
}
@end
@interface OFTDownloadTests : XCTestCase
@property NSURL *root;
@property OFTPackageInstaller *installer;
@property NSUInteger requestsServed;
@end
@implementation OFTDownloadTests
- (void)setUp {
    self.root = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    self.installer = [[OFTPackageInstaller alloc] initWithRootDirectory:self.root];
}
- (void)tearDown { [[NSFileManager defaultManager] removeItemAtURL:self.root error:nil]; }
- (NSData *)archive {
    return [NSData dataWithContentsOfURL:[[NSBundle bundleForClass:self.class] URLForResource:@"root" withExtension:@"zip" subdirectory:@"Fixtures"]];
}
- (OFTPackageRecord *)record {
    NSData *data = [self archive]; uint8_t bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *digest = [NSMutableString new]; for (NSUInteger i=0; i<sizeof(bytes); i++) [digest appendFormat:@"%02x",bytes[i]];
    return [[OFTPackageRecord alloc] initWithVersion:100000 sha256:digest];
}
/// One-shot local HTTP fixture. Its socket timeout ensures failed tests cannot leave an accept thread blocked.
- (NSURL *)serverWithStatus:(NSInteger)status chunked:(BOOL)chunked truncated:(BOOL)truncated {
    int listener = socket(AF_INET, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(listener, 0);
    struct timeval timeout = {10, 0}; setsockopt(listener, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in address = {0}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    XCTAssertEqual(bind(listener, (struct sockaddr *)&address, sizeof(address)), 0);
    XCTAssertEqual(listen(listener, 1), 0);
    socklen_t length=sizeof(address); getsockname(listener, (struct sockaddr *)&address, &length);
    NSData *body = [self archive];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        int client = accept(listener, NULL, NULL); close(listener); if (client < 0) return;
        int noSigPipe=1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        char request[4096]; recv(client, request, sizeof(request), 0); self.requestsServed++;
        NSString *headers = chunked ? @"Transfer-Encoding: chunked\r\n" : [NSString stringWithFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
        NSString *head = [NSString stringWithFormat:@"HTTP/1.1 %ld Test\r\n%@Connection: close\r\nContent-Type: application/zip\r\n\r\n", (long)status, headers];
        NSMutableData *response = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        if (chunked) [response appendData:[[NSString stringWithFormat:@"%lx\r\n",(unsigned long)body.length] dataUsingEncoding:NSUTF8StringEncoding]];
        [response appendData:truncated ? [body subdataWithRange:NSMakeRange(0, body.length/2)] : body];
        if (chunked) [response appendData:[@"\r\n0\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        NSUInteger sent=0;
        while (sent < response.length) {
            ssize_t count=send(client,(const char *)response.bytes+sent,response.length-sent,0);
            if (count<=0) break; sent+=(NSUInteger)count;
        }
        close(client);
    });
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%hu/package.zip",ntohs(address.sin_port)]];
}
- (void)testHTTP200InstallsAndDeliversOrderedMainThreadCallbacks {
    XCTestExpectation *done = [self expectationWithDescription:@"download"];
    NSMutableArray *stages = [NSMutableArray new];
    [self.installer installRecord:[self record] fromURL:[self serverWithStatus:200 chunked:NO truncated:NO] progress:^(NSString *stage, int64_t bytes, int64_t total) {
        XCTAssertTrue(NSThread.isMainThread); [stages addObject:stage];
    } completion:^(OFTPackageRecord *record, NSURL *directory, NSError *error) {
        XCTAssertNil(error); XCTAssertNotNil(directory); XCTAssertEqualObjects(stages.lastObject,@"publish"); [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:15];
}
- (void)testChunkedDownloadDoesNotInventTotalLength {
    XCTestExpectation *done = [self expectationWithDescription:@"chunked"];
    __block BOOL sawUnknown=NO;
    [self.installer installRecord:[self record] fromURL:[self serverWithStatus:200 chunked:YES truncated:NO] progress:^(NSString *stage, int64_t bytes, int64_t total) {
        if ([stage isEqualToString:@"download"] && bytes>0) { XCTAssertEqual(total,-1); sawUnknown=YES; }
    } completion:^(OFTPackageRecord *record, NSURL *directory, NSError *error) {
        XCTAssertNil(error); XCTAssertNotNil(directory); XCTAssertTrue(sawUnknown); [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:15];
}
- (void)testPartialHTTPResponseIsRejected {
    XCTestExpectation *done = [self expectationWithDescription:@"206"];
    [self.installer installRecord:[self record] fromURL:[self serverWithStatus:206 chunked:NO truncated:NO] progress:nil completion:^(OFTPackageRecord *record, NSURL *directory, NSError *error) {
        XCTAssertNil(directory); XCTAssertEqual(error.code,OFTOfflineNetwork); XCTAssertEqualObjects(error.userInfo[OFTOfflineHTTPStatusKey],@206); [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:15];
}
- (void)testInterruptedResponseDoesNotPublish {
    XCTestExpectation *done = [self expectationWithDescription:@"truncated HTTP"];
    [self.installer installRecord:[self record] fromURL:[self serverWithStatus:200 chunked:NO truncated:YES] progress:nil completion:^(OFTPackageRecord *record, NSURL *directory, NSError *error) {
        XCTAssertNil(directory); XCTAssertNotNil(error); [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:15];
}
/// 持续慢流使每次读取都及时返回，专门验证整个请求 120 秒上限与客户端释放。
- (NSURL *)slowServerStarted:(XCTestExpectation *)started closed:(XCTestExpectation *)closed {
    int listener = socket(AF_INET, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(listener, 0);
    struct timeval acceptTimeout = {10, 0}; setsockopt(listener, SOL_SOCKET, SO_RCVTIMEO, &acceptTimeout, sizeof(acceptTimeout));
    struct sockaddr_in address = {0}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    XCTAssertEqual(bind(listener, (struct sockaddr *)&address, sizeof(address)), 0); XCTAssertEqual(listen(listener, 1), 0);
    socklen_t length = sizeof(address); getsockname(listener, (struct sockaddr *)&address, &length);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        int client = accept(listener, NULL, NULL); close(listener);
        if (client < 0) { [closed fulfill]; return; }
        int noSigPipe = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        struct timeval timeout = {3, 0}; setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        char request[4096]; recv(client, request, sizeof(request), 0);
        NSData *headers = [@"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\nContent-Type: application/zip\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        send(client, headers.bytes, headers.length, 0);
        NSMutableData *chunk = [[@"400\r\n" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [chunk appendData:[NSMutableData dataWithLength:1024]]; [chunk appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        BOOL first = YES;
        while (YES) {
            NSUInteger sent = 0;
            while (sent < chunk.length) {
                ssize_t count = send(client, (const char *)chunk.bytes + sent, chunk.length - sent, 0);
                if (count <= 0) break; sent += (NSUInteger)count;
            }
            if (sent != chunk.length) break;
            if (first) { [started fulfill]; first = NO; }
            usleep(200000);
        }
        close(client); [closed fulfill];
    });
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%hu/slow-package.zip", ntohs(address.sin_port)]];
}
- (void)testInFlightCancellationStopsSocketAndCompletesExactlyOnce {
    XCTestExpectation *started = [self expectationWithDescription:@"服务器已发真实响应字节"];
    XCTestExpectation *closed = [self expectationWithDescription:@"取消后服务器连接释放"];
    XCTestExpectation *done = [self expectationWithDescription:@"取消安装终态"];
    __block NSUInteger completions = 0;
    NSProgress *task = [self.installer installRecord:[self record] fromURL:[self slowServerStarted:started closed:closed] progress:nil completion:^(OFTPackageRecord *record, NSURL *directory, NSError *error) {
        completions++; XCTAssertNil(record); XCTAssertNil(directory); XCTAssertEqual(error.code, OFTOfflineCancelled);
        XCTAssertEqualObjects(error.userInfo[OFTOfflineRequestStartedKey], @YES); [done fulfill];
    }];
    [self waitForExpectations:@[started] timeout:10];
    NSTimeInterval cancelTime = NSProcessInfo.processInfo.systemUptime; [task cancel];
    [self waitForExpectations:@[done, closed] timeout:8];
    XCTAssertLessThan(NSProcessInfo.processInfo.systemUptime - cancelTime, 8);
    XCTAssertNil(task.cancellationHandler); XCTAssertEqual(completions, 1);
    XCTAssertEqual([[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.root.path error:nil].count, 0);
}
- (void)testContinuousSlowStreamTimesOutAtWholeRequest120Seconds {
    XCTestExpectation *started = [self expectationWithDescription:@"持续慢流开始"];
    XCTestExpectation *closed = [self expectationWithDescription:@"总超时后连接释放"];
    XCTestExpectation *done = [self expectationWithDescription:@"真实 120 秒下载总超时"];
    NSTimeInterval begin = NSProcessInfo.processInfo.systemUptime;
    __block NSUInteger completions = 0;
    NSProgress *task = [self.installer installRecord:[self record] fromURL:[self slowServerStarted:started closed:closed] progress:nil completion:^(OFTPackageRecord *record, NSURL *directory, NSError *error) {
        completions++; XCTAssertNil(record); XCTAssertNil(directory); XCTAssertEqual(error.code, OFTOfflineTimeout);
        XCTAssertEqualObjects(error.userInfo[OFTOfflineErrorStageKey], @"download");
        XCTAssertEqualObjects(error.userInfo[OFTOfflineRequestStartedKey], @YES); [done fulfill];
    }];
    [self waitForExpectations:@[started] timeout:10];
    [self waitForExpectations:@[done, closed] timeout:130];
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - begin;
    XCTAssertGreaterThanOrEqual(elapsed, 115); XCTAssertLessThan(elapsed, 130);
    NSLog(@"OFT验证 continuousSlowStream elapsed=%.3f completions=%lu", elapsed, (unsigned long)completions);
    XCTAssertNil(task.cancellationHandler); XCTAssertEqual(completions, 1);
    XCTAssertEqual([[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.root.path error:nil].count, 0);
}
- (void)testManagedUnknownLengthSmallBodyProducesActualFinalTailBeforeConflation {
    NSURL *URL=[self serverWithStatus:200 chunked:YES truncated:NO];
    [NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *destination=[self.root URLByAppendingPathComponent:@"tail.zip"];XCTestExpectation *done=[self expectationWithDescription:@"managed producer tail"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
        NSMutableArray *events=[NSMutableArray array];__block NSUInteger attempts=0;NSError *error=nil;
        BOOL ok=[[OFTDownload new] downloadURL:URL destination:destination configuration:NSURLSessionConfiguration.ephemeralSessionConfiguration cancellation:[NSProgress progressWithTotalUnitCount:1] onStarted:^{attempts++;} progress:^(NSString *stage,int64_t bytes,int64_t total){[events addObject:@{@"bytes":@(bytes),@"total":@(total)}];} error:&error];
        XCTAssertTrue(ok);XCTAssertNil(error);XCTAssertEqual(attempts,1u);XCTAssertEqual([events.lastObject[@"bytes"] unsignedIntegerValue],[self archive].length);XCTAssertEqualObjects(events.lastObject[@"total"],@-1);XCTAssertLessThanOrEqual(events.count,2u);
        OFTPreparationProgress *p=[[OFTPreparationProgress alloc] initWithStage:@"download" completed:[self archive].length total:-1];XCTAssertEqual(p.fraction,-1);[done fulfill];
    });[self waitForExpectations:@[done] timeout:8];
}
- (void)testManagedRetryAfterSecondsUseCheckedInt64MillisecondsBoundary {
    OFTDownload *download=[OFTDownload new];
    NSDictionary *cases=@{@"3000000000":@YES,@"9223372036854775":@YES,@"9223372036854776":@NO,@"9223372036854775807":@NO,@"-1":@NO,@"Wed, 21 Oct 2015 07:28:00 GMT":@NO,@"1.5":@NO};
    for (NSString *value in cases) {
        NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://example.com/package.zip"] statusCode:503 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Retry-After":value}];
        NSError *error=[download managedHTTPFailure:503 response:response];XCTAssertEqual(error.userInfo[OFTOfflineRetryAfterKey]!=nil,[cases[value] boolValue],@"%@",value);
    }
}
// Only the final POSIX output-close result is injected; HTTP, preparation, SQLite and events are real.
- (void)runManagedRemoteZIPCloseFailure:(BOOL)closeFailure truncated:(BOOL)truncated cancelAtClose:(BOOL)cancelAtClose {
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSURL *packages = [self.root URLByAppendingPathComponent:@"managed" isDirectory:YES];
    OFTManagedStorage *storage = [OFTManagedStorage defaultStorageForInstallationRootDirectory:packages error:nil];
    NSURL *URL = [self serverWithStatus:200 chunked:NO truncated:truncated];
    OFTPackageRecord *record = [self record]; __block NSUInteger configurations = 0;
    NSError *error = nil;
    OFTManagedOfflineSDK *sdk = [[OFTManagedOfflineSDK alloc] initWithRootDirectory:packages originalStaticRoot:[NSURL URLWithString:@"https://example.com/app/"] minimumVersion:10000 checkInterval:300 storage:storage versionedConfigurationProvider:^NSProgress *(NSInteger currentVersion, OFTConfigurationCompletion completion) {
        configurations++; XCTAssertEqual(currentVersion, 0);
        completion([[OFTManagedConfiguration alloc] initWithEnabled:YES version:record.version packageURL:URL sha256:record.sha256], nil);
        return nil;
    } error:&error];
    XCTAssertNotNil(sdk); XCTAssertNil(error);
    NSURLSessionConfiguration *network = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    network.timeoutIntervalForRequest = 3; network.timeoutIntervalForResource = 6; sdk.downloadConfiguration = network;
    sdk.resourceCacheCleaner = ^{};
    NSMutableArray<OFTManagedOutcome *> *outcomes = [NSMutableArray array];
    sdk.outcomeHandler = ^(OFTManagedOutcome *outcome) { XCTAssertTrue(NSThread.isMainThread); [outcomes addObject:outcome]; };
    NSString *outputPath = [[packages URLByAppendingPathComponent:@"100000.zip"] URLByResolvingSymlinksInPath].path;
    SEL selector = @selector(closeManagedZIPOutput:);
    Method method = class_getInstanceMethod(OFTDownload.class, selector); XCTAssertNotEqual(method, NULL);
    if (!method) { [sdk close]; return; }
    IMP original = method_getImplementation(method); __block NSUInteger closes = 0;
    IMP injected = imp_implementationWithBlock(^int(OFTDownload *download, int descriptor) {
        char path[MAXPATHLEN] = {0}; BOOL matches = fcntl(descriptor, F_GETPATH, path) == 0 && [outputPath isEqualToString:[[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]] URLByResolvingSymlinksInPath].path];
        int result = ((int (*)(id, SEL, int))original)(download, selector, descriptor);
        if (!matches) return result;
        closes++; XCTAssertEqual(result, 0); // The fixture must really release the descriptor, exactly once.
        if (cancelAtClose) dispatch_sync(dispatch_get_main_queue(), ^{ [sdk updatePrivacyGranted:NO foreground:YES]; });
        if (closeFailure) { errno = EIO; return -1; }
        return result;
    });
    method_setImplementation(method, injected);
    @try {
        [sdk updatePrivacyGranted:YES foreground:YES];
        XCTestExpectation *done = [self expectationWithDescription:@"real managed Remote preparation"];
        __block OFTPreparationResult *result = nil; __block NSUInteger completions = 0;
        [sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *value) { completions++; result = value; [done fulfill]; }];
        [self waitForExpectations:@[done] timeout:12];
        XCTAssertEqual(completions, 1u); XCTAssertEqual(configurations, 1u); XCTAssertEqual(self.requestsServed, 1u); XCTAssertEqual(closes, 1u);
        NSDictionary *row = [storage rowForVersion:100000 error:&error]; XCTAssertNotNil(row); XCTAssertNil(error);
        BOOL succeeded = !closeFailure && !truncated && !cancelAtClose;
        if (cancelAtClose) {
            XCTAssertEqual(result.disposition, OFTPreparationCancelled); XCTAssertNil(result.outcome); XCTAssertEqual(outcomes.count, 0u);
        } else {
            XCTAssertEqual(result.disposition, OFTPreparationContinue); XCTAssertEqual(outcomes.count, 1u);
            XCTAssertEqualObjects(result.outcome, outcomes.firstObject); XCTAssertEqual(result.outcome.success, succeeded);
            XCTAssertEqual(result.outcome.record.version, 100000); XCTAssertTrue(result.outcome.requestStarted);
            if (!succeeded) {
                XCTAssertEqual(result.outcome.reason, truncated ? OFTOfflineNetwork : OFTOfflineFileIO);
                XCTAssertEqualObjects(result.outcome.stage, @"download"); XCTAssertNil(result.outcome.publishedRecord);
            }
        }
        XCTAssertEqualObjects(row[@"stage"], succeeded ? OFTPackageStageActive : OFTPackageStageDownloading);
        XCTAssertEqual([NSFileManager.defaultManager fileExistsAtPath:[packages URLByAppendingPathComponent:@"100000/index.html"].path], succeeded);
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:outputPath]);
        XCTAssertEqual([storage readRowsWithError:nil].count, 1u);
    } @finally {
        [sdk close]; sdk.outcomeHandler = nil;
        method_setImplementation(method, original); imp_removeBlock(injected);
    }
}
- (void)testManagedRemoteZIPCloseFailureCannotBecomeReadyOrPrepared {
    [self runManagedRemoteZIPCloseFailure:YES truncated:NO cancelAtClose:NO];
}
- (void)testManagedRemoteTransferFailureKeepsPriorityOverZIPCloseFailure {
    [self runManagedRemoteZIPCloseFailure:YES truncated:YES cancelAtClose:NO];
}
- (void)testManagedRemoteCancellationKeepsPriorityOverZIPCloseFailure {
    [self runManagedRemoteZIPCloseFailure:YES truncated:NO cancelAtClose:YES];
}
- (void)testManagedRemoteSuccessfulZIPCloseStillPreparesExactlyOnce {
    [self runManagedRemoteZIPCloseFailure:NO truncated:NO cancelAtClose:NO];
}
- (void)testManagedRemoteTransferErrorFactsSurviveZIPCloseFailure {
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES attributes:nil error:nil]);
    XCTestExpectation *done = [self expectationWithDescription:@"real Remote primary error facts"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSError *primary = nil;
        for (NSNumber *failClose in @[@NO, @YES]) {
            OFTZIPCloseFaultDownload *download = [OFTZIPCloseFaultDownload new]; download.failClose = failClose.boolValue;
            NSURL *destination = [self.root URLByAppendingPathComponent:[NSString stringWithFormat:@"facts-%@.zip", failClose]];
            NSURLSessionConfiguration *network = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            network.timeoutIntervalForRequest = 3; network.timeoutIntervalForResource = 6;
            NSError *error = nil; __block NSUInteger attempts = 0;
            BOOL ok = [download downloadURL:[self serverWithStatus:200 chunked:NO truncated:YES] destination:destination configuration:network cancellation:[NSProgress progressWithTotalUnitCount:1] onStarted:^{ attempts++; } progress:nil error:&error];
            XCTAssertFalse(ok); XCTAssertEqual(attempts, 1u); XCTAssertEqual(download.closes, 1u);
            XCTAssertEqualObjects(error.domain, OFTOfflineErrorDomain); XCTAssertEqual(error.code, OFTOfflineNetwork);
            XCTAssertEqualObjects(error.userInfo[OFTOfflineErrorStageKey], @"download");
            XCTAssertEqualObjects(error.userInfo[OFTOfflineNetworkRetryKey], @YES);
            NSError *underlying = error.userInfo[NSUnderlyingErrorKey]; XCTAssertEqualObjects(underlying.domain, NSURLErrorDomain);
            if (!primary) primary = error;
            else {
                XCTAssertEqualObjects(error.localizedDescription, primary.localizedDescription);
                NSError *original = primary.userInfo[NSUnderlyingErrorKey]; XCTAssertEqual(underlying.code, original.code);
            }
        }
        [done fulfill];
    });
    [self waitForExpectations:@[done] timeout:12];
}
@end
