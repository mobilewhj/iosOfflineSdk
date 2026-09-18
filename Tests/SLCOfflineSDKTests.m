#import <XCTest/XCTest.h>
#import <SLCOfflineSDK/SLCOfflineSDK.h>

@interface SLCOfflineSDKTests : XCTestCase
@property NSURL *root;
@property SLCPackageInstaller *installer;
@property NSDictionary *digests;
@end
@implementation SLCOfflineSDKTests
- (void)setUp {
    [super setUp];
    self.root = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    self.installer = [[SLCPackageInstaller alloc] initWithRootDirectory:self.root];
    NSURL *url = [[NSBundle bundleForClass:self.class] URLForResource:@"manifest" withExtension:@"json" subdirectory:@"Fixtures"];
    self.digests = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] options:0 error:nil];
    XCTAssertNotNil(self.digests);
}
- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtURL:self.root error:nil];
    [super tearDown];
}
- (NSURL *)fixture:(NSString *)name { return [[NSBundle bundleForClass:self.class] URLForResource:name withExtension:@"zip" subdirectory:@"Fixtures"]; }
- (NSURL *)install:(NSString *)name version:(NSInteger)version error:(NSError **)error {
    XCTestExpectation *finished = [self expectationWithDescription:name];
    __block NSURL *result;
    __block NSError *failure;
    SLCPackageRecord *record = [[SLCPackageRecord alloc] initWithVersion:version sha256:self.digests[name]];
    [self.installer installRecord:record localArchive:[self fixture:name] progress:nil completion:^(SLCPackageRecord *r, NSURL *directory, NSError *e) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqual(r != nil, directory != nil);
        result = directory; failure = e; [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:15];
    if (error) *error = failure;
    return result;
}
- (void)testRecordsRejectInvalidMetadata {
    XCTAssertNil([[SLCPackageRecord alloc] initWithVersion:9999 sha256:self.digests[@"root"]]);
    XCTAssertNil([[SLCPackageRecord alloc] initWithVersion:100000 sha256:@"invalid"]);
    XCTAssertNil([[SLCPackageRecord alloc] initWithVersion:100000 sha256:[self.digests[@"root"] uppercaseString]]);
    XCTAssertNotNil([[SLCPackageRecord alloc] initWithVersion:100000 sha256:self.digests[@"root"]]);
}
- (void)testRootAndDistArchivesPublishNormalizedDirectories {
    NSError *error;
    NSURL *a = [self install:@"root" version:100000 error:&error]; XCTAssertNotNil(a); XCTAssertNil(error);
    NSURL *b = [self install:@"dist" version:100001 error:&error]; XCTAssertNotNil(b); XCTAssertNil(error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[b URLByAppendingPathComponent:@"index.html"].path]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[b URLByAppendingPathComponent:@"dist"].path]);
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.root.path error:nil];
    XCTAssertEqual(names.count, 2);
}
- (void)testExistingVersionIsNeverOverwritten {
    NSError *error;
    NSURL *a = [self install:@"root" version:100000 error:&error];
    XCTAssertNil([self install:@"dist" version:100000 error:&error]);
    XCTAssertEqual(error.code, SLCOfflineVersionExists);
    NSString *contents = [NSString stringWithContentsOfURL:[a URLByAppendingPathComponent:@"index.html"] encoding:NSUTF8StringEncoding error:nil];
    XCTAssertTrue([contents containsString:@"version A"]);
}
- (void)testBadArchivesCannotReplaceActiveOrEscapeRoot {
    NSError *error;
    NSURL *active = [self install:@"root" version:100000 error:&error]; XCTAssertNotNil(active);
    for (NSString *name in @[@"traversal", @"absolute", @"symlink", @"duplicate", @"case_alias", @"conflict", @"empty", @"missing", @"truncated", @"crc", @"wrong_count", @"oversized"]) {
        XCTAssertNil([self install:name version:100001 error:&error], @"%@", name);
        XCTAssertNotNil(error, @"%@", name);
        XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[active URLByAppendingPathComponent:@"index.html"].path]);
        NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.root.path error:nil];
        XCTAssertEqualObjects(names, (@[@"100000"]), @"%@", name);
    }
}
- (void)testDigestMismatchAndCancellationLeaveNoPublishedVersion {
    XCTestExpectation *mismatch = [self expectationWithDescription:@"digest"];
    SLCPackageRecord *wrong = [[SLCPackageRecord alloc] initWithVersion:100000 sha256:self.digests[@"dist"]];
    [self.installer installRecord:wrong localArchive:[self fixture:@"root"] progress:nil completion:^(SLCPackageRecord *record, NSURL *directory, NSError *error) {
        XCTAssertNil(directory); XCTAssertEqual(error.code, SLCOfflineDigestMismatch); [mismatch fulfill];
    }];
    [self waitForExpectations:@[mismatch] timeout:5];
    XCTestExpectation *cancelled = [self expectationWithDescription:@"cancel"];
    NSProgress *task = [self.installer installRecord:wrong localArchive:[self fixture:@"root"] progress:nil completion:^(SLCPackageRecord *record, NSURL *directory, NSError *error) {
        XCTAssertNil(directory); XCTAssertEqual(error.code, SLCOfflineCancelled); [cancelled fulfill];
    }];
    [task cancel];
    [self waitForExpectations:@[cancelled] timeout:5];
}
- (void)testMissingInputFailsWithoutPublishing {
    XCTestExpectation *done = [self expectationWithDescription:@"missing file"];
    SLCPackageRecord *record = [[SLCPackageRecord alloc] initWithVersion:100000 sha256:self.digests[@"root"]];
    [self.installer installRecord:record localArchive:[self.root URLByAppendingPathComponent:@"absent.zip"] progress:nil completion:^(SLCPackageRecord *r, NSURL *directory, NSError *error) {
        XCTAssertNil(directory); XCTAssertNotNil(error); [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:5];
}
- (void)testCleanupRequiresUsableActiveAndKeepsItsFiles {
    NSError *error;
    [self install:@"root" version:100000 error:&error];
    [self install:@"dist" version:100001 error:&error];
    XCTestExpectation *refused = [self expectationWithDescription:@"refuse"];
    [self.installer clearOldVersionsKeeping:@100002 completion:^(NSError *error) { XCTAssertNotNil(error); [refused fulfill]; }];
    [self waitForExpectations:@[refused] timeout:5];
    XCTAssertEqual([[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.root.path error:nil].count, 2);
    XCTestExpectation *done = [self expectationWithDescription:@"cleanup"];
    [self.installer clearOldVersionsKeeping:@100001 completion:^(NSError *error) { XCTAssertNil(error); [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:5];
    XCTAssertEqualObjects([[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.root.path error:nil], (@[@"100001"]));
}
- (void)testRootSymlinkIsRejected {
    NSURL *outside = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtURL:outside withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createSymbolicLinkAtURL:self.root withDestinationURL:outside error:nil];
    NSError *error;
    XCTAssertNil([self install:@"root" version:100000 error:&error]); XCTAssertNotNil(error);
    XCTAssertEqual([[NSFileManager defaultManager] contentsOfDirectoryAtPath:outside.path error:nil].count, 0);
    [[NSFileManager defaultManager] removeItemAtURL:outside error:nil];
}
- (void)testResolverPinsVersionAndChecksOriginMethodRangeAndTraversal {
    NSError *error;
    NSURL *a = [self install:@"root" version:100000 error:&error];
    SLCOfflineResourceResolver *resolver = [[SLCOfflineResourceResolver alloc] initWithDirectory:a baseURL:[NSURL URLWithString:@"https://example.com/app/"]];
    XCTAssertNotNil(resolver);
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.com/app/static/app.js?v=1#route"]];
    SLCOfflineResource *resource = [resolver resourceForRequest:request];
    XCTAssertEqualObjects(resource.MIMEType, @"text/javascript"); XCTAssertEqualObjects(resource.textEncodingName, @"utf-8");
    [self install:@"dist" version:100001 error:&error];
    XCTAssertEqualObjects([resolver resourceForRequest:request].fileURL, resource.fileURL);
    for (NSString *url in @[@"https://evil.example/app/static/app.js", @"https://example.com:444/app/static/app.js", @"https://example.com/application/index.html", @"https://example.com/app/%2e%2e/index.html", @"https://example.com/app/missing.js"]) {
        XCTAssertNil([resolver resourceForRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]], @"%@", url);
    }
    NSMutableURLRequest *post = request.mutableCopy; post.HTTPMethod = @"POST"; XCTAssertNil([resolver resourceForRequest:post]);
    NSMutableURLRequest *range = request.mutableCopy; [range setValue:@"bytes=0-2" forHTTPHeaderField:@"Range"]; XCTAssertNil([resolver resourceForRequest:range]);
    SLCOfflineResource *font = [resolver resourceForRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.com/app/font.woff2"]]];
    XCTAssertEqualObjects(font.MIMEType, @"font/woff2"); XCTAssertNil(font.textEncodingName);
}
@end
