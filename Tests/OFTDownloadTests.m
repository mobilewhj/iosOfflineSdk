#import <XCTest/XCTest.h>
#import <OfflineTool/OfflineTool.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>

@interface OFTDownloadTests : XCTestCase
@property NSURL *root;
@property OFTPackageInstaller *installer;
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
        char request[4096]; recv(client, request, sizeof(request), 0);
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
@end
