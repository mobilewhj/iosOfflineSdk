#import <XCTest/XCTest.h>
#import <OfflineTool/OfflineTool.h>
#import <OfflineTool/OfflineTool-Swift.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <errno.h>
#import <sys/param.h>
#import <objc/runtime.h>

// 私有托管契约仅用于定向故障验证，消费者仍使用公开 manager。
@interface OFTPackageInstaller (OwnershipTests)
- (int)closeManagedZIPOutput:(int)descriptor;
- (BOOL)copyManagedArchive:(NSURL *)source to:(NSURL *)destination cancellation:(NSProgress *)cancel onStarted:(dispatch_block_t)onStarted progress:(OFTInstallProgress)progress error:(NSError **)error;
- (BOOL)claimManagedRootWithOwner:(id)owner error:(NSError **)error;
- (BOOL)markManagedRootPageBound;
- (BOOL)canModifyExistingVersions;
- (BOOL)removeItemAtURL:(NSURL *)url error:(NSError **)error;
@end
@interface OFTFaultInstaller : OFTPackageInstaller
@property BOOL failStagingCleanup;
@property BOOL failPublishedCleanup;
@property NSProgress *cancelDuringCleanup;
@end
@implementation OFTFaultInstaller
- (BOOL)removeItemAtURL:(NSURL *)url error:(NSError **)error {
    if ([url.lastPathComponent hasPrefix:@".staging-"]) [self.cancelDuringCleanup cancel];
    if ((self.failStagingCleanup && [url.lastPathComponent hasPrefix:@".staging-"]) ||
        (self.failPublishedCleanup && [url.lastPathComponent isEqualToString:@"100001"])) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        return NO;
    }
    return [super removeItemAtURL:url error:error];
}
@end

@interface OFTZIPCloseFaultInstaller : OFTPackageInstaller
@property BOOL failClose;
@property NSUInteger closes;
@end
@implementation OFTZIPCloseFaultInstaller
- (int)closeManagedZIPOutput:(int)descriptor {
    self.closes++;
    int result = [super closeManagedZIPOutput:descriptor];
    if (!result && self.failClose) { errno = EIO; return -1; }
    return result;
}
@end

@interface OfflineToolTests : XCTestCase
@property NSURL *root;
@property OFTPackageInstaller *installer;
@property NSDictionary *digests;
@end
@implementation OfflineToolTests
- (void)setUp {
    [super setUp];
    self.root = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    self.installer = [[OFTPackageInstaller alloc] initWithRootDirectory:self.root];
    NSURL *url = [[NSBundle bundleForClass:self.class] URLForResource:@"manifest" withExtension:@"json" subdirectory:@"Fixtures"];
    NSMutableDictionary *digests = [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] options:0 error:nil] mutableCopy];
    NSURL *additions = [[NSBundle bundleForClass:self.class] URLForResource:@"managed-manifest" withExtension:@"json" subdirectory:@"Fixtures"];
    [digests addEntriesFromDictionary:[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:additions] options:0 error:nil]];
    NSURL *stored = [[NSBundle bundleForClass:self.class] URLForResource:@"managed-directory-stored-manifest" withExtension:@"json" subdirectory:@"Fixtures"];
    [digests addEntriesFromDictionary:[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:stored] options:0 error:nil]];
    self.digests = digests;
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
    OFTPackageRecord *record = [[OFTPackageRecord alloc] initWithVersion:version sha256:self.digests[name]];
    [self.installer installRecord:record localArchive:[self fixture:name] progress:nil completion:^(OFTPackageRecord *r, NSURL *directory, NSError *e) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqual(r != nil, directory != nil);
        result = directory; failure = e; [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:15];
    if (error) *error = failure;
    return result;
}
- (void)testRecordsRejectInvalidMetadata {
    XCTAssertNil([[OFTPackageRecord alloc] initWithVersion:9999 sha256:self.digests[@"root"]]);
    XCTAssertNil([[OFTPackageRecord alloc] initWithVersion:100000 sha256:@"invalid"]);
    XCTAssertEqualObjects([[OFTPackageRecord alloc] initWithVersion:100000 sha256:[self.digests[@"root"] uppercaseString]].sha256,self.digests[@"root"]);
    XCTAssertNil([[OFTPackageRecord alloc] initWithVersion:100000 sha256:[self.digests[@"root"] stringByAppendingString:@" "]]);
    XCTAssertNotNil([[OFTPackageRecord alloc] initWithVersion:100000 sha256:self.digests[@"root"]]);
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
    XCTAssertEqual(error.code, OFTOfflineVersionExists);
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
    OFTPackageRecord *wrong = [[OFTPackageRecord alloc] initWithVersion:100000 sha256:self.digests[@"dist"]];
    [self.installer installRecord:wrong localArchive:[self fixture:@"root"] progress:nil completion:^(OFTPackageRecord *record, NSURL *directory, NSError *error) {
        XCTAssertNil(directory); XCTAssertEqual(error.code, OFTOfflineDigestMismatch); [mismatch fulfill];
    }];
    [self waitForExpectations:@[mismatch] timeout:5];
    XCTestExpectation *cancelled = [self expectationWithDescription:@"cancel"];
    NSProgress *task = [self.installer installRecord:wrong localArchive:[self fixture:@"root"] progress:nil completion:^(OFTPackageRecord *record, NSURL *directory, NSError *error) {
        XCTAssertNil(directory); XCTAssertEqual(error.code, OFTOfflineCancelled); [cancelled fulfill];
    }];
    [task cancel];
    [self waitForExpectations:@[cancelled] timeout:5];
}
- (void)testMissingInputFailsWithoutPublishing {
    XCTestExpectation *done = [self expectationWithDescription:@"missing file"];
    OFTPackageRecord *record = [[OFTPackageRecord alloc] initWithVersion:100000 sha256:self.digests[@"root"]];
    [self.installer installRecord:record localArchive:[self.root URLByAppendingPathComponent:@"absent.zip"] progress:nil completion:^(OFTPackageRecord *r, NSURL *directory, NSError *error) {
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
    OFTOfflineResourceResolver *resolver = [[OFTOfflineResourceResolver alloc] initWithDirectory:a baseURL:[NSURL URLWithString:@"https://example.com/app/"]];
    XCTAssertNotNil(resolver);
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.com/app/static/app.js?v=1#route"]];
    OFTOfflineResource *resource = [resolver resourceForRequest:request];
    XCTAssertEqualObjects(resource.MIMEType, @"text/javascript"); XCTAssertEqualObjects(resource.textEncodingName, @"utf-8");
    [self install:@"dist" version:100001 error:&error];
    XCTAssertEqualObjects([resolver resourceForRequest:request].fileURL, resource.fileURL);
    for (NSString *url in @[@"https://evil.example/app/static/app.js", @"https://example.com:444/app/static/app.js", @"https://example.com/application/index.html", @"https://example.com/app/%2e%2e/index.html", @"https://example.com/app/missing.js"]) {
        XCTAssertNil([resolver resourceForRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]], @"%@", url);
    }
    NSMutableURLRequest *post = request.mutableCopy; post.HTTPMethod = @"POST"; XCTAssertNil([resolver resourceForRequest:post]);
    NSMutableURLRequest *range = request.mutableCopy; [range setValue:@"bytes=0-2" forHTTPHeaderField:@"Range"]; XCTAssertNil([resolver resourceForRequest:range]);
    OFTOfflineResource *font = [resolver resourceForRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.com/app/font.woff2"]]];
    XCTAssertEqualObjects(font.MIMEType, @"font/woff2"); XCTAssertNil(font.textEncodingName);
}
- (void)testArchiveLimitsUseTooLargeAndPreserveExistingVersion {
    NSError *error;
    NSURL *active = [self install:@"root" version:100000 error:&error]; XCTAssertNotNil(active);
    for (NSString *name in @[@"oversized", @"managed_entry_count_limit", @"managed_total_size_limit"]) {
        XCTAssertNil([self install:name version:100001 error:&error]);
        XCTAssertEqual(error.code, OFTOfflineTooLarge, @"%@", name);
        XCTAssertEqualObjects(error.userInfo[OFTOfflineErrorStageKey], @"extract");
        XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[active URLByAppendingPathComponent:@"index.html"].path]);
    }
}
- (void)testDirectoryPayloadAndCentralConsistencyRejectWhileEmptyDeflateDirectoryWorks {
    NSError *error;
    XCTAssertNotNil([self install:@"managed_directory_valid" version:100000 error:&error]); XCTAssertNil(error);
    XCTAssertNotNil([self install:@"managed_directory_stored" version:100002 error:&error]); XCTAssertNil(error);
    for (NSString *name in @[@"managed_directory_payload", @"managed_directory_inconsistent", @"managed_directory_hidden_payload", @"managed_central_undercount"]) {
        XCTAssertNil([self install:name version:100001 error:&error]);
        XCTAssertEqual(error.code, OFTOfflineInvalidArchive, @"%@", name);
        XCTAssertEqualObjects(error.userInfo[OFTOfflineErrorStageKey], @"extract");
    }
}
- (void)testUnreadableEntryPreventsCleanupAndPreservesOtherVersions {
    NSError *error;
    NSURL *active = [self install:@"root" version:100000 error:&error];
    [self install:@"dist" version:100001 error:&error];
    NSURL *entry = [active URLByAppendingPathComponent:@"index.html"];
    XCTAssertEqual(chmod(entry.fileSystemRepresentation, 0000), 0);
    int descriptor = open(entry.fileSystemRepresentation, O_RDONLY);
    if (descriptor >= 0) {
        close(descriptor); chmod(entry.fileSystemRepresentation, 0644);
        XCTSkip(@"当前运行身份仍可读 chmod 000 文件，不能证明权限读取故障");
        return;
    }
    XCTestExpectation *refused = [self expectationWithDescription:@"不可读入口拒绝清理"];
    [self.installer clearOldVersionsKeeping:@100000 completion:^(NSError *failure) { XCTAssertNotNil(failure); [refused fulfill]; }];
    [self waitForExpectations:@[refused] timeout:5];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[self.root URLByAppendingPathComponent:@"100001/index.html"].path]);
    chmod(entry.fileSystemRepresentation, 0644);
}
- (void)testManagedRootClaimBlocksOldInstallerAndSurvivesRecreation {
    OFTPackageInstaller *old = self.installer;
    OFTPackageInstaller *managed = [[OFTPackageInstaller alloc] initWithRootDirectory:self.root];
    NSError *error; XCTAssertTrue([managed claimManagedRootWithOwner:self error:&error]);
    XCTAssertFalse([[[OFTPackageInstaller alloc] initWithRootDirectory:self.root] claimManagedRootWithOwner:self error:&error]);
    XCTestExpectation *refused = [self expectationWithDescription:@"旧低层拒绝写入"];
    [old installRecord:[[OFTPackageRecord alloc] initWithVersion:100000 sha256:self.digests[@"root"]] localArchive:[self fixture:@"root"] progress:nil completion:^(OFTPackageRecord *record, NSURL *directory, NSError *failure) {
        XCTAssertNil(record); XCTAssertNil(directory); XCTAssertEqual(failure.code, OFTOfflineInvalidInput); [refused fulfill];
    }];
    [self waitForExpectations:@[refused] timeout:5];
    self.installer = managed;
    XCTAssertNotNil([self install:@"root" version:100000 error:&error]);
    XCTAssertTrue([managed markManagedRootPageBound]); XCTAssertFalse(managed.canModifyExistingVersions);
    XCTestExpectation *clear = [self expectationWithDescription:@"绑定后永久拒绝清理"];
    [managed clearOldVersionsKeeping:nil completion:^(NSError *failure) { XCTAssertNotNil(failure); [clear fulfill]; }];
    XCTestExpectation *discard = [self expectationWithDescription:@"绑定后永久拒绝删除"];
    [managed discardUnboundVersion:100000 completion:^(NSError *failure) { XCTAssertNotNil(failure); [discard fulfill]; }];
    [self waitForExpectations:@[clear, discard] timeout:5];
    XCTAssertNotNil([self install:@"dist" version:100001 error:&error]); XCTAssertNil(error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[self.root URLByAppendingPathComponent:@"100000/index.html"].path]);
    self.installer = nil; managed = nil;
    XCTAssertFalse([[[OFTPackageInstaller alloc] initWithRootDirectory:self.root] claimManagedRootWithOwner:self error:&error]);
}
- (void)testManagedRegistryIdentityStaysFixedWhenParentAliasChanges {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *a = [self.root URLByAppendingPathComponent:@"A" isDirectory:YES];
    NSURL *b = [self.root URLByAppendingPathComponent:@"B" isDirectory:YES];
    NSURL *alias = [self.root URLByAppendingPathComponent:@"alias" isDirectory:YES];
    XCTAssertTrue([fm createDirectoryAtURL:a withIntermediateDirectories:YES attributes:nil error:nil]);
    XCTAssertTrue([fm createDirectoryAtURL:b withIntermediateDirectories:YES attributes:nil error:nil]);
    XCTAssertTrue([fm createSymbolicLinkAtURL:alias withDestinationURL:a error:nil]);
    OFTPackageInstaller *managed = [[OFTPackageInstaller alloc] initWithRootDirectory:[alias URLByAppendingPathComponent:@"packages" isDirectory:YES]];
    NSError *error; XCTAssertTrue([managed claimManagedRootWithOwner:self error:&error]);
    XCTAssertTrue([fm removeItemAtURL:alias error:nil]);
    XCTAssertTrue([fm createSymbolicLinkAtURL:alias withDestinationURL:b error:nil]);
    // 页面提交只查已缓存的认领身份，不重新解析已变化的磁盘别名。
    XCTAssertTrue([managed markManagedRootPageBound]); XCTAssertFalse(managed.canModifyExistingVersions);
    self.installer = managed;
    XCTAssertNil([self install:@"root" version:100000 error:&error]);
    XCTAssertEqual(error.code, OFTOfflineFileIO);
    XCTAssertFalse([fm fileExistsAtPath:[b URLByAppendingPathComponent:@"packages"].path]);
}
- (void)testPrimaryFailureRetainsStagingCleanupFailure {
    OFTFaultInstaller *fault = [[OFTFaultInstaller alloc] initWithRootDirectory:self.root]; fault.failStagingCleanup = YES;
    self.installer = fault;
    NSError *error; XCTAssertNil([self install:@"crc" version:100001 error:&error]);
    XCTAssertEqual(error.code, OFTOfflineInvalidArchive);
    XCTAssertEqual([error.userInfo[OFTOfflineCleanupErrorsKey] count], 1);
    XCTAssertNil(error.userInfo[OFTOfflinePublishedRecordKey]);
}
- (void)testPublishedCleanupFailureReportsResidualWithoutSuccess {
    OFTFaultInstaller *fault = [[OFTFaultInstaller alloc] initWithRootDirectory:self.root];
    fault.failStagingCleanup = YES; self.installer = fault;
    NSError *removedError; XCTAssertNil([self install:@"root" version:100001 error:&removedError]);
    XCTAssertEqualObjects(removedError.userInfo[OFTOfflinePublishedDirectoryRemainsKey], @NO);
    OFTPackageRecord *removedRecord = removedError.userInfo[OFTOfflinePublishedRecordKey];
    XCTAssertEqual(removedRecord.version, 100001);
    fault.failPublishedCleanup = YES;
    NSError *error; XCTAssertNil([self install:@"root" version:100001 error:&error]);
    XCTAssertEqual(error.code, OFTOfflineFileIO);
    XCTAssertEqualObjects(error.userInfo[OFTOfflineErrorStageKey], @"cleanup");
    XCTAssertEqual([error.userInfo[OFTOfflineCleanupErrorsKey] count], 2);
    OFTPackageRecord *publishedRecord = error.userInfo[OFTOfflinePublishedRecordKey];
    XCTAssertEqual(publishedRecord.version, 100001);
    XCTAssertEqualObjects(error.userInfo[OFTOfflinePublishedDirectoryRemainsKey], @YES);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[error.userInfo[OFTOfflinePublishedDirectoryKey] URLByAppendingPathComponent:@"index.html"].path]);
}
- (void)testFailedNewPublicationPreservesEveryVersionAfterPageEverBound {
    OFTFaultInstaller *fault = [[OFTFaultInstaller alloc] initWithRootDirectory:self.root]; self.installer = fault;
    NSError *error; XCTAssertTrue([fault claimManagedRootWithOwner:self error:&error]);
    XCTAssertNotNil([self install:@"root" version:100000 error:&error]);
    XCTAssertTrue([fault markManagedRootPageBound]);
    fault.failStagingCleanup = YES;
    XCTAssertNil([self install:@"dist" version:100001 error:&error]);
    XCTAssertEqual(error.code, OFTOfflineFileIO);
    XCTAssertEqualObjects(error.userInfo[OFTOfflinePublishedDirectoryRemainsKey], @YES);
    XCTAssertEqual([error.userInfo[OFTOfflineCleanupErrorsKey] count], 2);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[self.root URLByAppendingPathComponent:@"100000/index.html"].path]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[self.root URLByAppendingPathComponent:@"100001/index.html"].path]);
}
- (void)testCancellationDuringCleanupRetainsCleanupFactsAndDoesNotPublishSuccess {
    OFTFaultInstaller *fault = [[OFTFaultInstaller alloc] initWithRootDirectory:self.root]; fault.failStagingCleanup = YES;
    self.installer = fault;
    XCTestExpectation *done = [self expectationWithDescription:@"清理时取消"];
    fault.cancelDuringCleanup = [fault installRecord:[[OFTPackageRecord alloc] initWithVersion:100001 sha256:self.digests[@"managed_entry_count_limit"]] localArchive:[self fixture:@"managed_entry_count_limit"] progress:nil completion:^(OFTPackageRecord *record, NSURL *directory, NSError *error) {
        XCTAssertNil(record); XCTAssertNil(directory); XCTAssertEqual(error.code, OFTOfflineCancelled);
        XCTAssertEqual([error.userInfo[OFTOfflineCleanupErrorsKey] count], 1); [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:10];
}
- (void)testManagedExtractionOutputCreationFailureIsFileIO {
    NSURL *destination=[self.root URLByAppendingPathComponent:@"output-create-fault" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:[destination URLByAppendingPathComponent:@"index.html"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *archive=[[NSBundle bundleForClass:self.class] URLForResource:@"root" withExtension:@"zip" subdirectory:@"Fixtures"];NSError *error=nil;
    BOOL ok=[OFTArchiveReader extractManagedArchive:archive toDirectory:destination cancellation:[NSProgress progressWithTotalUnitCount:1] progress:^(int64_t done,int64_t total){} error:&error];
    XCTAssertFalse(ok);XCTAssertEqualObjects(error.domain,OFTOfflineErrorDomain);XCTAssertEqual(error.code,OFTOfflineFileIO);XCTAssertEqualObjects(error.userInfo[OFTOfflineErrorStageKey],@"extract");
}
// Only the final POSIX output-close result is injected; Local copying, preparation, SQLite and events are real.
- (void)runManagedLocalZIPCloseFailure:(BOOL)closeFailure missingInput:(BOOL)missingInput cancelAtClose:(BOOL)cancelAtClose {
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSURL *packages = [self.root URLByAppendingPathComponent:@"managed" isDirectory:YES];
    OFTManagedStorage *storage = [OFTManagedStorage defaultStorageForInstallationRootDirectory:packages error:nil];
    NSURL *source = missingInput ? [self.root URLByAppendingPathComponent:@"absent.zip"] : [self fixture:@"root"];
    NSString *sha = self.digests[@"root"]; __block NSUInteger configurations = 0;
    NSError *error = nil;
    OFTManagedOfflineSDK *sdk = [[OFTManagedOfflineSDK alloc] initWithRootDirectory:packages originalStaticRoot:[NSURL URLWithString:@"https://example.com/app/"] minimumVersion:10000 checkInterval:300 storage:storage versionedConfigurationProvider:^NSProgress *(NSInteger currentVersion, OFTConfigurationCompletion completion) {
        configurations++; XCTAssertEqual(currentVersion, 0);
        completion([[OFTManagedConfiguration alloc] initWithEnabled:YES version:100000 packageURL:source sha256:sha], nil);
        return nil;
    } error:&error];
    XCTAssertNotNil(sdk); XCTAssertNil(error); sdk.resourceCacheCleaner = ^{};
    NSMutableArray<OFTManagedOutcome *> *outcomes = [NSMutableArray array];
    sdk.outcomeHandler = ^(OFTManagedOutcome *outcome) { XCTAssertTrue(NSThread.isMainThread); [outcomes addObject:outcome]; };
    NSString *outputPath = [[packages URLByAppendingPathComponent:@"100000.zip"] URLByResolvingSymlinksInPath].path;
    SEL selector = @selector(closeManagedZIPOutput:);
    Method method = class_getInstanceMethod(OFTPackageInstaller.class, selector); XCTAssertNotEqual(method, NULL);
    if (!method) { [sdk close]; return; }
    IMP original = method_getImplementation(method); __block NSUInteger closes = 0;
    IMP injected = imp_implementationWithBlock(^int(OFTPackageInstaller *installer, int descriptor) {
        char path[MAXPATHLEN] = {0}; BOOL matches = fcntl(descriptor, F_GETPATH, path) == 0 && [outputPath isEqualToString:[[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]] URLByResolvingSymlinksInPath].path];
        int result = ((int (*)(id, SEL, int))original)(installer, selector, descriptor);
        if (!matches) return result;
        closes++; XCTAssertEqual(result, 0);
        if (cancelAtClose) dispatch_sync(dispatch_get_main_queue(), ^{ [sdk updatePrivacyGranted:NO foreground:YES]; });
        if (closeFailure) { errno = EIO; return -1; }
        return result;
    });
    method_setImplementation(method, injected);
    @try {
        [sdk updatePrivacyGranted:YES foreground:YES];
        XCTestExpectation *done = [self expectationWithDescription:@"real managed Local preparation"];
        __block OFTPreparationResult *result = nil; __block NSUInteger completions = 0;
        [sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *value) { completions++; result = value; [done fulfill]; }];
        [self waitForExpectations:@[done] timeout:12];
        XCTAssertEqual(completions, 1u); XCTAssertEqual(configurations, 1u); XCTAssertEqual(closes, 1u);
        NSDictionary *row = [storage rowForVersion:100000 error:&error]; XCTAssertNotNil(row); XCTAssertNil(error);
        BOOL succeeded = !closeFailure && !missingInput && !cancelAtClose;
        if (cancelAtClose) {
            XCTAssertEqual(result.disposition, OFTPreparationCancelled); XCTAssertNil(result.outcome); XCTAssertEqual(outcomes.count, 0u);
        } else {
            XCTAssertEqual(result.disposition, OFTPreparationContinue); XCTAssertEqual(outcomes.count, 1u);
            XCTAssertEqualObjects(result.outcome, outcomes.firstObject); XCTAssertEqual(result.outcome.success, succeeded);
            XCTAssertEqual(result.outcome.record.version, 100000); XCTAssertTrue(result.outcome.requestStarted);
            if (!succeeded) {
                XCTAssertEqual(result.outcome.reason, OFTOfflineFileIO); XCTAssertEqualObjects(result.outcome.stage, @"download");
                XCTAssertNil(result.outcome.publishedRecord);
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
- (void)testManagedLocalZIPCloseFailureCannotBecomeReadyOrPrepared {
    [self runManagedLocalZIPCloseFailure:YES missingInput:NO cancelAtClose:NO];
}
- (void)testManagedLocalReadFailureKeepsPriorityOverZIPCloseFailure {
    [self runManagedLocalZIPCloseFailure:YES missingInput:YES cancelAtClose:NO];
}
- (void)testManagedLocalCancellationKeepsPriorityOverZIPCloseFailure {
    [self runManagedLocalZIPCloseFailure:YES missingInput:NO cancelAtClose:YES];
}
- (void)testManagedLocalSuccessfulZIPCloseStillPreparesExactlyOnce {
    [self runManagedLocalZIPCloseFailure:NO missingInput:NO cancelAtClose:NO];
}
- (void)testManagedLocalReadErrorFactsSurviveZIPCloseFailure {
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSError *primary = nil;
    for (NSNumber *failClose in @[@NO, @YES]) {
        OFTZIPCloseFaultInstaller *installer = [[OFTZIPCloseFaultInstaller alloc] initWithRootDirectory:self.root]; installer.failClose = failClose.boolValue;
        NSURL *destination = [self.root URLByAppendingPathComponent:[NSString stringWithFormat:@"facts-%@.zip", failClose]];
        NSError *error = nil; __block NSUInteger attempts = 0;
        BOOL ok = [installer copyManagedArchive:[self.root URLByAppendingPathComponent:@"absent.zip"] to:destination cancellation:[NSProgress progressWithTotalUnitCount:1] onStarted:^{ attempts++; } progress:^(NSString *stage, int64_t done, int64_t total) {} error:&error];
        XCTAssertFalse(ok); XCTAssertEqual(attempts, 1u); XCTAssertEqual(installer.closes, 1u);
        XCTAssertEqualObjects(error.domain, OFTOfflineErrorDomain); XCTAssertEqual(error.code, OFTOfflineFileIO);
        XCTAssertEqualObjects(error.userInfo[OFTOfflineErrorStageKey], @"download");
        if (!primary) primary = error;
        else XCTAssertEqualObjects(error.userInfo, primary.userInfo); // Includes the original read/write message, not a close replacement.
    }
}
@end
