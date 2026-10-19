#import <XCTest/XCTest.h>
#import <OfflineTool/OfflineTool.h>
#import <CommonCrypto/CommonDigest.h>
#import <sqlite3.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>

@interface OFTManagedOfflineSDK (LifecycleTestClock)
- (NSTimeInterval)monotonicTime;
@end
@interface OFTLifecycleSDK : OFTManagedOfflineSDK
@property NSTimeInterval now;
@end
@implementation OFTLifecycleSDK
- (NSTimeInterval)monotonicTime { return self.now; }
@end
@interface OFTLifecycleWebView : WKWebView
@property NSURL *recordedURL;
@end
@implementation OFTLifecycleWebView
- (WKNavigation *)loadRequest:(NSURLRequest *)request { self.recordedURL = request.URL; return nil; }
@end
@interface OFTDelayedSQLiteStorage : OFTManagedStorage
@property dispatch_semaphore_t gate;
@property XCTestExpectation *entered;
@property BOOL delayed;
@end
@implementation OFTDelayedSQLiteStorage
- (NSArray *)readRowsWithError:(NSError **)error {
    if (!self.delayed) { self.delayed=YES; [self.entered fulfill]; dispatch_semaphore_wait(self.gate,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC)); }
    return [super readRowsWithError:error];
}
@end
@interface OFTManagedTests : XCTestCase
@property NSURL *sandbox;
@property NSURL *root;
@property NSURL *archiveURL;
@property NSData *archive;
@property NSString *sha;
@property OFTManagedStorage *storage;
@property OFTLifecycleSDK *sdk;
@property NSMutableArray<OFTManagedOutcome *> *outcomes;
@property NSMutableArray<NSDictionary *> *diagnostics;
@end
@implementation OFTManagedTests
- (NSString *)hash:(NSData *)data {
    uint8_t bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString *result = [NSMutableString string]; for (NSUInteger i=0;i<sizeof(bytes);i++) [result appendFormat:@"%02x",bytes[i]]; return result;
}
- (void)setUp {
    self.sandbox = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    self.root = [self.sandbox URLByAppendingPathComponent:@"webview" isDirectory:YES];
    self.storage = [OFTManagedStorage defaultStorageForInstallationRootDirectory:self.root error:nil];
    self.archiveURL = [[NSBundle bundleForClass:self.class] URLForResource:@"root" withExtension:@"zip" subdirectory:@"Fixtures"];
    self.archive = [NSData dataWithContentsOfURL:self.archiveURL]; self.sha = [self hash:self.archive];
    self.outcomes = [NSMutableArray array]; self.diagnostics = [NSMutableArray array];
}
- (void)tearDown { [self.sdk close]; self.sdk.outcomeHandler = nil; self.sdk.diagnosticHandler = nil; [NSFileManager.defaultManager removeItemAtURL:self.sandbox error:nil]; }
- (OFTManagedConfiguration *)config:(NSInteger)version URL:(NSURL *)URL sha:(NSString *)sha { return [[OFTManagedConfiguration alloc] initWithEnabled:YES version:version packageURL:URL sha256:sha]; }
- (OFTLifecycleSDK *)manager:(OFTVersionedConfigurationProvider)provider {
    NSError *error = nil;
    self.sdk = [[OFTLifecycleSDK alloc] initWithRootDirectory:self.root originalStaticRoot:[NSURL URLWithString:@"https://example.com/app/"] minimumVersion:10000 checkInterval:300 storage:self.storage versionedConfigurationProvider:provider error:&error];
    XCTAssertNotNil(self.sdk); XCTAssertNil(error); self.sdk.now=1000;
    NSURLSessionConfiguration *network = NSURLSessionConfiguration.ephemeralSessionConfiguration; network.timeoutIntervalForRequest=3; network.timeoutIntervalForResource=6; self.sdk.downloadConfiguration=network;
    self.sdk.resourceCacheCleaner=^{};
    NSMutableArray *outcomes=self.outcomes,*diagnostics=self.diagnostics;
    self.sdk.outcomeHandler=^(OFTManagedOutcome *outcome){ [outcomes addObject:outcome]; };
    self.sdk.diagnosticHandler=^(NSString *stage,OFTOfflineErrorCode reason,NSString *detail){ [diagnostics addObject:@{@"stage":stage,@"reason":@(reason),@"detail":detail}]; };
    return self.sdk;
}
- (void)entry:(NSInteger)version text:(NSString *)text {
    NSURL *directory=[self.root URLByAppendingPathComponent:@(version).stringValue isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    XCTAssertTrue([text writeToURL:[directory URLByAppendingPathComponent:@"index.html"] atomically:NO encoding:NSUTF8StringEncoding error:nil]);
}
- (OFTPackageRecord *)record:(NSInteger)version sha:(NSString *)sha { return [[OFTPackageRecord alloc] initWithVersion:version sha256:sha ?: self.sha]; }
- (void)seed:(NSInteger)version stage:(NSString *)stage {
    XCTAssertNotNil([self.storage registerTarget:[self record:version sha:nil] error:nil]);
    if ([stage isEqual:OFTPackageStageActive]) { XCTAssertTrue([self.storage setStage:OFTPackageStageReady forVersion:version error:nil]); XCTAssertTrue([self.storage activateVersion:version error:nil]); }
    else XCTAssertTrue([self.storage setStage:stage forVersion:version error:nil]);
}
- (void)SQL:(NSString *)sql {
    XCTAssertNotNil([self.storage readRowsWithError:nil]); sqlite3 *db=NULL;
    XCTAssertEqual(sqlite3_open(self.storage.databaseURL.fileSystemRepresentation,&db),SQLITE_OK);
    XCTAssertEqual(sqlite3_exec(db,sql.UTF8String,NULL,NULL,NULL),SQLITE_OK); sqlite3_close(db);
}
- (OFTPreparationResult *)prepare {
    XCTestExpectation *done=[self expectationWithDescription:@"invocation result"]; __block OFTPreparationResult *result;
    [self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *value){ result=value; [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:12]; return result;
}
- (void)until:(BOOL (^)(void))condition {
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(id obj,NSDictionary *bindings){ return condition(); }];
    [self waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:self]] timeout:12];
}
- (void)idle { [self until:^BOOL{ return [self.sdk valueForKey:@"update"] == nil; }]; }
- (void)tick { self.sdk.now+=300; [self.sdk checkForUpdates]; [self idle]; }
- (OFTPageLoadResult *)page {
    WKWebViewConfiguration *configuration=[WKWebViewConfiguration new]; configuration.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;
    OFTPageBinding *binding=[self.sdk pageBindingForConfiguration:configuration scheme:@"lifecycle-test" error:nil];
    OFTLifecycleWebView *webView=[[OFTLifecycleWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    XCTestExpectation *done=[self expectationWithDescription:@"page decision"]; __block OFTPageLoadResult *result;
    [self.sdk loadPage:[NSURL URLWithString:@"https://example.com/app/index.html"] inWebView:webView binding:binding completion:^(OFTPageLoadResult *value,NSError *error){ result=value; XCTAssertNil(error); [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:5]; [binding dispose]; return result;
}
- (NSURL *)serverStatus:(NSInteger)status body:(NSData *)body declaredExtra:(NSUInteger)extra retryAfter:(NSString *)retry gate:(dispatch_semaphore_t)gate accepted:(XCTestExpectation *)accepted {
    int listener=socket(AF_INET,SOCK_STREAM,0); XCTAssertGreaterThanOrEqual(listener,0);
    struct timeval timeout={8,0}; setsockopt(listener,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    struct sockaddr_in address={0};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    XCTAssertEqual(bind(listener,(struct sockaddr *)&address,sizeof(address)),0); XCTAssertEqual(listen(listener,1),0);
    socklen_t length=sizeof(address);getsockname(listener,(struct sockaddr *)&address,&length);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
        int client=accept(listener,NULL,NULL);close(listener);if(client<0)return;
        int noPipe=1;setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&noPipe,sizeof(noPipe));setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        char request[2048];recv(client,request,sizeof(request),0);if(accepted)[accepted fulfill];if(gate)dispatch_semaphore_wait(gate,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC));
        NSString *header=[NSString stringWithFormat:@"HTTP/1.1 %ld Test\r\nContent-Length: %lu\r\n%@Connection: close\r\n\r\n",(long)status,(unsigned long)(body.length+extra),retry?[NSString stringWithFormat:@"Retry-After: %@\r\n",retry]:@""];
        NSMutableData *response=[[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];[response appendData:body];NSUInteger sent=0;
        while(sent<response.length){ssize_t n=send(client,(const char *)response.bytes+sent,response.length-sent,0);if(n<=0)break;sent+=n;}close(client);
    });
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%hu/package.zip",ntohs(address.sin_port)]];
}
- (NSURL *)closedPort {
    int listener=socket(AF_INET,SOCK_STREAM,0);struct sockaddr_in address={0};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    bind(listener,(struct sockaddr *)&address,sizeof(address));socklen_t length=sizeof(address);getsockname(listener,(struct sockaddr *)&address,&length);close(listener);
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%hu/zip",ntohs(address.sin_port)]];
}
- (void)testFirstEmptyTableInstallsLocalReadyThenActivatesExactlyOnce {
    __block NSUInteger calls=0;
    [self manager:^NSProgress *(NSInteger version,OFTConfigurationCompletion done){calls++;XCTAssertEqual(version,0);done([self config:10000 URL:self.archiveURL sha:self.sha.uppercaseString],nil);return nil;}];
    [self.sdk updatePrivacyGranted:YES foreground:YES];OFTPreparationResult *result=[self prepare];
    XCTAssertEqual(result.disposition,OFTPreparationContinue);XCTAssertTrue(result.performedFirstPreparation);XCTAssertTrue(result.outcome.success);
    XCTAssertEqualObjects(result.outcome.detail,@"prepared");XCTAssertEqualObjects([self.storage rowForVersion:10000 error:nil][@"stage"],OFTPackageStageActive);
    XCTAssertEqual(self.outcomes.count,1u);XCTAssertTrue([self page].offline);XCTAssertFalse([self prepare].performedFirstPreparation);XCTAssertEqual(calls,1u);
}
- (void)testNonemptyIncompleteRecordSkipsFirstAndReusesValidZIPWithoutHTTP {
    [self seed:10000 stage:OFTPackageStageDownloading];[NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES attributes:nil error:nil];
    XCTAssertTrue([self.archive writeToURL:[self.root URLByAppendingPathComponent:@"10000.zip"] atomically:NO]);
    [self entry:10000 text:@"incomplete"];NSURL *remote=[self closedPort];
    [self manager:^NSProgress *(NSInteger version,OFTConfigurationCompletion done){done([self config:10000 URL:remote sha:self.sha],nil);return nil;}];
    [self.sdk updatePrivacyGranted:YES foreground:YES];XCTAssertFalse([self prepare].performedFirstPreparation);[self idle];
    XCTAssertEqual(self.outcomes.count,1u);XCTAssertTrue(self.outcomes.firstObject.success);XCTAssertTrue(self.outcomes.firstObject.requestStarted);XCTAssertNil(self.outcomes.firstObject.HTTPStatus);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.root URLByAppendingPathComponent:@"10000.zip"].path]);
}
- (void)testFirstDefersWithoutFactsAndCancellationKeepsGateForExplicitRetry {
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([[OFTManagedConfiguration alloc] initWithEnabled:NO version:0 packageURL:nil sha256:nil],nil);return nil;}];
    XCTAssertEqual([self prepare].disposition,OFTPreparationDeferred);XCTAssertEqual([self.storage readRowsWithError:nil].count,0u);
    [self.sdk updatePrivacyGranted:YES foreground:YES];XCTAssertTrue([self prepare].performedFirstPreparation);XCTAssertEqual(self.outcomes.count,0u);
    XCTAssertFalse([self prepare].performedFirstPreparation); // No durable first marker: another empty-database process will be first again.
}
- (void)testFirstOwnerCancelPropagatesAndWaiterCancelDoesNotCancelOwner {
    __block OFTConfigurationCompletion pending;[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){pending=done;return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];
    XCTestExpectation *ownerDone=[self expectationWithDescription:@"owner"],*waiterDone=[self expectationWithDescription:@"waiter"];
    NSProgress *owner=[self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationCancelled);[ownerDone fulfill];}];
    [self until:^BOOL{return pending!=nil;}];
    [self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationCancelled);[waiterDone fulfill];}];
    [owner cancel];[self waitForExpectations:@[ownerDone,waiterDone] timeout:5];pending([self config:10000 URL:self.archiveURL sha:self.sha],nil);[self idle];XCTAssertEqual(self.outcomes.count,0u);
    pending=nil;XCTestExpectation *healthy=[self expectationWithDescription:@"healthy owner"],*cancelled=[self expectationWithDescription:@"cancelled waiter"];
    [self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationContinue);[healthy fulfill];}];[self until:^BOOL{return pending!=nil;}];
    NSProgress *waiter=[self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationCancelled);[cancelled fulfill];}];[waiter cancel];
    pending([self config:10000 URL:self.archiveURL sha:self.sha],nil);[self waitForExpectations:@[healthy,cancelled] timeout:8];XCTAssertEqual(self.outcomes.count,1u);
}
- (void)testReadFailureNeverClearsPackageAndReleasesOnlyOfflineWait {
    [self entry:10000 text:@"preserved"];[NSFileManager.defaultManager createDirectoryAtURL:self.storage.databaseURL withIntermediateDirectories:YES attributes:nil error:nil];
    __block NSUInteger calls=0;[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){calls++;return nil;}];
    OFTPreparationResult *r=[self prepare];XCTAssertEqual(r.disposition,OFTPreparationContinue);XCTAssertFalse(r.performedFirstPreparation);XCTAssertEqual(calls,0u);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[self.root URLByAppendingPathComponent:@"10000/index.html"].path]);XCTAssertFalse([self page].offline);
}
- (void)testActiveMissingDirectoryIsNotRepairedOrDowngraded {
    [self seed:10001 stage:OFTPackageStageActive];__block NSInteger supplied=-1;
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){supplied=v;done([self config:10001 URL:self.archiveURL sha:self.sha],nil);return nil;}];
    [self.sdk updatePrivacyGranted:YES foreground:YES];XCTAssertFalse([self prepare].performedFirstPreparation);[self idle];
    XCTAssertEqual(supplied,0);XCTAssertEqual(self.outcomes.count,0u);XCTAssertFalse([self page].offline);XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.root URLByAppendingPathComponent:@"10001"].path]);
}
- (void)testHigherTargetWritesReadyWithoutReplacingProcessActiveAndCacheRequestedOnce {
    [self seed:10000 stage:OFTPackageStageActive];[self entry:10000 text:@"active A"];
    __block NSUInteger clears=0;__block NSInteger supplied=0;
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){supplied=v;done([self config:10001 URL:self.archiveURL sha:self.sha],nil);return nil;}];self.sdk.resourceCacheCleaner=^{clears++;XCTAssertEqual([[self.sdk valueForKey:@"onlineVersion"] integerValue],10001);};
    [self.sdk updatePrivacyGranted:YES foreground:YES];XCTAssertFalse([self prepare].performedFirstPreparation);[self idle];
    XCTAssertEqual(supplied,10000);XCTAssertEqual(((OFTPackageRecord *)[self.sdk valueForKey:@"active"]).version,10000);XCTAssertEqualObjects([self.storage rowForVersion:10001 error:nil][@"stage"],OFTPackageStageReady);
    XCTAssertEqual(self.outcomes.count,1u);XCTAssertEqual(self.outcomes.firstObject.activeVersion,10000);XCTAssertFalse([self page].offline);[self tick];XCTAssertEqual(clears,1u);XCTAssertEqual(self.outcomes.count,1u);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[self.root URLByAppendingPathComponent:@"10000/index.html"].path]);
}
- (void)testColdLoadingPromotesReadyAndRetainsUnusableReadyWithoutInventingSuccess {
    [self seed:10000 stage:OFTPackageStageActive];[self entry:10000 text:@"A"];[self seed:10001 stage:OFTPackageStageReady];[self entry:10001 text:@"B"];
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){return nil;}];
    XCTAssertFalse([self prepare].performedFirstPreparation);XCTAssertTrue([self page].offline);XCTAssertEqual([self page].record.version,10001);XCTAssertNil([self.storage rowForVersion:10000 error:nil]);XCTAssertEqual(self.outcomes.count,0u);
}
- (void)testInvalidReadyStaysRecordedAndDirectoryPreservedAtColdLoad {
    [self seed:10001 stage:OFTPackageStageReady];NSURL *directory=[self.root URLByAppendingPathComponent:@"10001" isDirectory:YES];[NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){return nil;}];XCTAssertFalse([self prepare].performedFirstPreparation);
    XCTAssertEqualObjects([self.storage rowForVersion:10001 error:nil][@"stage"],OFTPackageStageReady);XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:directory.path]);XCTAssertFalse([self page].offline);
}
- (void)testSameNumberConflictPreservesPriorUnknownPolicyAndAllRows {
    [self seed:10000 stage:OFTPackageStageActive];[self entry:10000 text:@"A"];NSArray *before=[self.storage readRowsWithError:nil];NSString *different=[@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0];
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:self.archiveURL sha:different],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];[self idle];
    XCTAssertTrue([self page].offline);XCTAssertEqualObjects(before,[self.storage readRowsWithError:nil]);XCTAssertEqual(self.outcomes.count,0u);XCTAssertFalse([[self.sdk valueForKey:@"sawConfiguration"] boolValue]);
}
- (void)testConfigurationAndRegistrationPreflightHaveNoInstallationReportButRegistrationUsesQuota {
    [self SQL:@"CREATE TRIGGER reject_registration BEFORE INSERT ON offline_package BEGIN SELECT RAISE(ABORT,'test'); END"];
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:self.archiveURL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];
    XCTAssertEqual(self.outcomes.count,0u);XCTAssertEqual([[self.sdk valueForKey:@"packageFailures"] unsignedIntegerValue],1u);XCTAssertEqual([self.storage readRowsWithError:nil].count,0u);
    [self tick];XCTAssertEqual([[self.sdk valueForKey:@"packageFailures"] unsignedIntegerValue],2u);[self tick];XCTAssertEqual(self.outcomes.count,0u);
}
- (void)testZIPPreflightAndDownloadingStageWriteAreDiagnosticOnly {
    [self seed:10000 stage:OFTPackageStageDownloading];[NSFileManager.defaultManager createDirectoryAtURL:[self.root URLByAppendingPathComponent:@"10000.zip"] withIntermediateDirectories:YES attributes:nil error:nil];
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:self.archiveURL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];[self idle];
    XCTAssertEqual(self.outcomes.count,0u);XCTAssertEqual([[self.sdk valueForKey:@"packageFailures"] unsignedIntegerValue],1u);
    [NSFileManager.defaultManager removeItemAtURL:[self.root URLByAppendingPathComponent:@"10000.zip"] error:nil];
    [self SQL:@"CREATE TRIGGER reject_downloading BEFORE UPDATE OF stage ON offline_package WHEN NEW.stage='downloading' BEGIN SELECT RAISE(IGNORE); END"];
    [self tick];XCTAssertEqual(self.outcomes.count,0u);XCTAssertEqual([[self.sdk valueForKey:@"packageFailures"] unsignedIntegerValue],2u);
}
- (void)testZeroByteConnectionFailureCountsOnceAndDoesNotUsePackageQuota {
    NSURL *URL=[self closedPort];[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:URL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];
    XCTAssertEqual(self.outcomes.count,1u);XCTAssertEqual(self.outcomes.firstObject.reason,OFTOfflineNetwork);XCTAssertEqualObjects(self.outcomes.firstObject.stage,@"download");XCTAssertNil(self.outcomes.firstObject.HTTPStatus);XCTAssertEqual([[self.sdk valueForKey:@"packageFailures"] unsignedIntegerValue],0u);
}
- (void)testHTTP404ConsumesTwoAttemptsButNewHigherTargetGetsFreshQuota {
    __block NSInteger target=10000;[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){NSURL *URL=[self serverStatus:404 body:NSData.data declaredExtra:0 retryAfter:nil gate:nil accepted:nil];done([self config:target URL:URL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];[self tick];
    XCTAssertEqual(self.outcomes.count,2u);XCTAssertEqualObjects(self.outcomes.firstObject.HTTPStatus,@404);[self tick];XCTAssertEqual(self.outcomes.count,2u);
    target=10001;[self tick];XCTAssertEqual(self.outcomes.count,3u);XCTAssertEqual(self.outcomes.lastObject.record.version,10001);
}
- (void)testHTTP503RetryAfterLimitsDownloadIndependentlyOfFailureStatistics {
    __block NSUInteger connections=0;[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){XCTestExpectation *accepted=nil;connections++;NSURL *URL=[self serverStatus:503 body:NSData.data declaredExtra:0 retryAfter:@"600" gate:nil accepted:accepted];done([self config:10000 URL:URL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];
    XCTAssertEqual(self.outcomes.count,1u);XCTAssertEqualObjects(self.outcomes.firstObject.HTTPStatus,@503);XCTAssertEqual([[self.sdk valueForKey:@"packageFailures"] unsignedIntegerValue],0u);
    [self tick];XCTAssertEqual(self.outcomes.count,1u);[self tick];XCTAssertEqual(self.outcomes.count,2u);XCTAssertEqual(connections,3u);
}
- (void)testInterruptedBodyIsNetworkWithoutHTTP200AndSHAIsVerifyFailure {
    NSURL *URL=[self serverStatus:200 body:self.archive declaredExtra:100 retryAfter:nil gate:nil accepted:nil];
    __block BOOL shaCase=NO;[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:shaCase?10001:10000 URL:shaCase?self.archiveURL:URL sha:shaCase?[@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0]:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];
    XCTAssertEqual(self.outcomes.firstObject.reason,OFTOfflineNetwork);XCTAssertNil(self.outcomes.firstObject.HTTPStatus);shaCase=YES;[self tick];
    XCTAssertEqual(self.outcomes.lastObject.reason,OFTOfflineDigestMismatch);XCTAssertEqualObjects(self.outcomes.lastObject.stage,@"verify");
}
- (void)testLocalInputReadFailureAndVerifiedBadZIPKeepActualStages {
    NSURL *missing=[self.sandbox URLByAppendingPathComponent:@"missing-input.zip"];[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:missing sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];
    XCTAssertEqual(self.outcomes.count,1u);XCTAssertEqual(self.outcomes.firstObject.reason,OFTOfflineFileIO);XCTAssertEqualObjects(self.outcomes.firstObject.stage,@"download");XCTAssertNil(self.outcomes.firstObject.HTTPStatus);
}
- (void)testReadyWriteZeroRowsIsPublishStorageFailureAfterActualProcessing {
    [self SQL:@"CREATE TRIGGER reject_ready BEFORE UPDATE OF stage ON offline_package WHEN NEW.stage='ready' BEGIN SELECT RAISE(IGNORE); END"];
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:self.archiveURL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];
    XCTAssertEqual(self.outcomes.count,1u);XCTAssertFalse(self.outcomes.firstObject.success);XCTAssertEqual(self.outcomes.firstObject.reason,OFTOfflineStorageWrite);XCTAssertEqualObjects(self.outcomes.firstObject.stage,@"publish");XCTAssertEqualObjects([self.storage rowForVersion:10000 error:nil][@"stage"],OFTPackageStageDownloaded);
}
- (void)testFirstForegroundCheckpointCancelsBeforePreparingButDownloadContinuesBackground {
    __block OFTConfigurationCompletion pending;[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){pending=done;return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];
    XCTestExpectation *done=[self expectationWithDescription:@"first checkpoint cancelled"];
    [self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationCancelled);[done fulfill];}];[self until:^BOOL{return pending!=nil;}];
    [self.sdk updatePrivacyGranted:YES foreground:NO];pending([self config:10000 URL:self.archiveURL sha:self.sha],nil);[self waitForExpectations:@[done] timeout:5];XCTAssertEqual([self.storage readRowsWithError:nil].count,0u);
}
- (void)testOrdinaryBackgroundContinuesStartedFirstDownload {
    dispatch_semaphore_t gate=dispatch_semaphore_create(0);XCTestExpectation *accepted=[self expectationWithDescription:@"HTTP attempt"];
    NSURL *URL=[self serverStatus:200 body:self.archive declaredExtra:0 retryAfter:nil gate:gate accepted:accepted];
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:URL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];
    XCTestExpectation *done=[self expectationWithDescription:@"download background finish"];
    [self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationContinue);XCTAssertTrue(r.outcome.success);[done fulfill];}];[self waitForExpectations:@[accepted] timeout:5];
    [self.sdk updatePrivacyGranted:YES foreground:NO];dispatch_semaphore_signal(gate);[self waitForExpectations:@[done] timeout:8];XCTAssertEqual(self.outcomes.count,1u);
}
- (void)testSilentConfigMayStartPreparationAfterOrdinaryBackground {
    [self seed:10000 stage:OFTPackageStageActive];[self entry:10000 text:@"A"];__block OFTConfigurationCompletion pending;
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){pending=done;return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];[self until:^BOOL{return pending!=nil;}];
    [self.sdk updatePrivacyGranted:YES foreground:NO];pending([self config:10001 URL:self.archiveURL sha:self.sha],nil);[self idle];XCTAssertEqual(self.outcomes.count,1u);XCTAssertEqualObjects([self.storage rowForVersion:10001 error:nil][@"stage"],OFTPackageStageReady);
}
- (void)testPrivacyCancellationRejectsLateConfigAndDoesNotCountFailure {
    __block OFTConfigurationCompletion pending;[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){pending=done;return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];
    XCTestExpectation *done=[self expectationWithDescription:@"privacy cancelled"];
    [self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationCancelled);[done fulfill];}];[self until:^BOOL{return pending!=nil;}];[self.sdk updatePrivacyGranted:NO foreground:YES];
    pending([self config:10000 URL:self.archiveURL sha:self.sha],nil);[self waitForExpectations:@[done] timeout:5];XCTAssertEqual(self.outcomes.count,0u);XCTAssertEqual([self.storage readRowsWithError:nil].count,0u);
}
- (void)testCancelledReadyFinishingStillEmitsPreparedButKeepsFirstGate {
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:self.archiveURL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];
    XCTestExpectation *done=[self expectationWithDescription:@"cancel during ready commit"];__block NSProgress *owner;
    owner=[self.sdk prepareStartupWithProgress:^(OFTPreparationProgress *p){if([p.stage isEqual:@"saving"])[owner cancel];} completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationCancelled);[done fulfill];}];
    [self waitForExpectations:@[done] timeout:8];XCTAssertEqual(self.outcomes.count,1u);XCTAssertTrue(self.outcomes.firstObject.success);XCTAssertEqual([[self.sdk valueForKey:@"startupGate"] integerValue],1);
}
- (void)testRuntimeDatabaseRebuildProtectsInMemoryActiveWithoutRepeatingColdCleanup {
    [self seed:10000 stage:OFTPackageStageActive];[self entry:10000 text:@"A"];__block NSInteger target=10000;
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:target URL:self.archiveURL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];[self idle];
    NSURL *sentinel=[self.root URLByAppendingPathComponent:@"runtime-sentinel"];XCTAssertTrue([[@"keep" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:sentinel atomically:NO]);
    XCTAssertTrue([[@"not sqlite" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:self.storage.databaseURL atomically:NO]);target=10001;[self tick];
    XCTAssertEqual(((OFTPackageRecord *)[self.sdk valueForKey:@"active"]).version,10000);XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[self.root URLByAppendingPathComponent:@"10000/index.html"].path]);XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:sentinel.path]);XCTAssertEqualObjects([self.storage rowForVersion:10001 error:nil][@"stage"],OFTPackageStageReady);
}
- (NSData *)damagePackageDataPage {
    sqlite3 *db=NULL; sqlite3_stmt *statement=NULL;
    XCTAssertEqual(sqlite3_open(self.storage.databaseURL.fileSystemRepresentation,&db),SQLITE_OK);
    XCTAssertEqual(sqlite3_prepare_v2(db,"PRAGMA page_size",-1,&statement,NULL),SQLITE_OK);
    XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW); NSInteger pageSize=sqlite3_column_int(statement,0);sqlite3_finalize(statement);
    XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT rootpage FROM sqlite_master WHERE name='offline_package'",-1,&statement,NULL),SQLITE_OK);
    XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW);NSInteger rootPage=sqlite3_column_int(statement,0);sqlite3_finalize(statement);sqlite3_close(db);
    NSMutableData *bytes=[[NSData dataWithContentsOfURL:self.storage.databaseURL] mutableCopy];uint8_t invalidPageType=0;
    XCTAssertGreaterThan(rootPage,1);XCTAssertGreaterThanOrEqual(bytes.length,(NSUInteger)(rootPage*pageSize));
    [bytes replaceBytesInRange:NSMakeRange((rootPage-1)*pageSize,1) withBytes:&invalidPageType];XCTAssertTrue([bytes writeToURL:self.storage.databaseURL atomically:NO]);
    XCTAssertEqual(sqlite3_open_v2(self.storage.databaseURL.fileSystemRepresentation,&db,SQLITE_OPEN_READONLY,NULL),SQLITE_OK);
    XCTAssertEqual(sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&statement,NULL),SQLITE_OK);XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(statement,0),1);sqlite3_finalize(statement);
    XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT version,sha256,stage FROM offline_package WHERE version=10000",-1,&statement,NULL),SQLITE_OK);
    int result=sqlite3_step(statement);NSLog(@"OFT managed query-page fault: header/schema readable, step=%d errcode=%d",result,sqlite3_errcode(db));XCTAssertEqual(result,SQLITE_CORRUPT);sqlite3_finalize(statement);sqlite3_close(db);return bytes;
}
- (void)assertQueryQuarantineContains:(NSData *)bytes {
    NSArray<NSURL *> *children=[NSFileManager.defaultManager contentsOfDirectoryAtURL:self.sandbox includingPropertiesForKeys:nil options:0 error:nil];NSUInteger matches=0;
    for(NSURL *URL in children)if([URL.lastPathComponent hasPrefix:@"webview.db.corrupt-"]){matches++;XCTAssertEqualObjects([NSData dataWithContentsOfURL:URL],bytes);}
    XCTAssertEqual(matches,1u);XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:self.storage.databaseURL.path]);
}
- (void)testQueryCorruptionAtColdPageLoadContinuesOnlineWithoutClearingUnknownPackage {
    [self seed:10000 stage:OFTPackageStageActive];[self entry:10000 text:@"unknown preserved package"];
    NSData *corrupt=[self damagePackageDataPage];__block NSUInteger requests=0;
    [self manager:^NSProgress *(NSInteger version,OFTConfigurationCompletion done){requests++;return nil;}];
    XCTAssertFalse([self page].offline);XCTAssertEqual(requests,0u);XCTAssertEqual(self.outcomes.count,0u);
    XCTAssertNil([self.sdk valueForKey:@"active"]);XCTAssertFalse([[self.sdk valueForKey:@"loaded"] boolValue]);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[self.root URLByAppendingPathComponent:@"10000/index.html"].path]);
    [self assertQueryQuarantineContains:corrupt];
}
- (void)testRuntimeQueryCorruptionRecoveryRetainsActivePageAndSkipsColdCleanupAndSuccess {
    [self seed:10000 stage:OFTPackageStageActive];[self entry:10000 text:@"in-use A"];
    __block NSUInteger requests=0;
    [self manager:^NSProgress *(NSInteger version,OFTConfigurationCompletion done){requests++;XCTAssertEqual(version,10000);done([self config:10000 URL:self.archiveURL sha:self.sha],nil);return nil;}];
    XCTAssertFalse([self prepare].performedFirstPreparation);OFTPackageRecord *active=[self.sdk valueForKey:@"active"];
    XCTAssertEqual(active.version,10000);XCTAssertEqual([self page].record.version,10000);
    NSURL *sentinel=[self.root URLByAppendingPathComponent:@"runtime-sentinel"];NSData *sentinelBytes=[@"keep after cold initialization" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([sentinelBytes writeToURL:sentinel atomically:NO]);NSURL *entry=[self.root URLByAppendingPathComponent:@"10000/index.html"];NSData *entryBytes=[NSData dataWithContentsOfURL:entry];
    NSData *corrupt=[self damagePackageDataPage];[self.sdk updatePrivacyGranted:YES foreground:YES];[self idle];
    XCTAssertEqual(requests,1u);XCTAssertEqualObjects(self.diagnostics.lastObject[@"detail"],@"candidate_read_failed");
    XCTAssertEqual([self.sdk valueForKey:@"active"],active);XCTAssertTrue([[self.sdk valueForKey:@"initialized"] boolValue]);
    XCTAssertFalse([[self.sdk valueForKey:@"sawConfiguration"] boolValue]);XCTAssertEqual(self.outcomes.count,0u);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:entry],entryBytes);XCTAssertEqualObjects([NSData dataWithContentsOfURL:sentinel],sentinelBytes);
    [self assertQueryQuarantineContains:corrupt];
    [self tick];XCTAssertEqual(requests,2u);XCTAssertEqual([self.sdk valueForKey:@"active"],active);XCTAssertEqual([self page].record.version,10000);
    NSError *error=nil;NSArray *rows=[self.storage readRowsWithError:&error];XCTAssertNotNil(rows);XCTAssertEqual(rows.count,0u);XCTAssertNil(error);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:entry],entryBytes);XCTAssertEqualObjects([NSData dataWithContentsOfURL:sentinel],sentinelBytes);
    XCTAssertEqual(self.outcomes.count,0u);XCTAssertEqual([[self.sdk valueForKey:@"packageFailures"] unsignedIntegerValue],0u);XCTAssertFalse([self prepare].performedFirstPreparation);
}
- (void)testMissingCandidateIsUpToDateOnlyWithUsableCurrentAndPolicyStaysMemoryOnly {
    [self seed:10000 stage:OFTPackageStageActive];[self entry:10000 text:@"A"];
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:nil sha:nil],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];[self idle];
    XCTAssertTrue([self page].offline);XCTAssertEqual(self.outcomes.count,0u);XCTAssertEqual([self.storage readRowsWithError:nil].count,1u);
}
- (void)testCheckingReentrantClosePreventsProviderAndNoRequestClockAdvance {
    __block NSUInteger requests=0;[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){requests++;return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];
    XCTestExpectation *done=[self expectationWithDescription:@"closed checking"];
    [self.sdk prepareStartupWithProgress:^(OFTPreparationProgress *p){if([p.stage isEqual:@"checking"])[self.sdk close];} completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationCancelled);[done fulfill];}];
    [self waitForExpectations:@[done] timeout:5];XCTAssertEqual(requests,0u);XCTAssertFalse([[self.sdk valueForKey:@"requestEverStarted"] boolValue]);XCTAssertEqual(self.outcomes.count,0u);
}
- (void)testCanceledColdOwnerImmediateNewOwnerPerformsFreshRealSQLiteLoad {
    OFTDelayedSQLiteStorage *storage=[[OFTDelayedSQLiteStorage alloc] initWithDatabaseURL:self.storage.databaseURL];self.storage=storage;
    storage.gate=dispatch_semaphore_create(0);storage.entered=[self expectationWithDescription:@"real database read held"];
    __block NSUInteger requests=0;[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){requests++;done([self config:10000 URL:self.archiveURL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];
    XCTestExpectation *oldDone=[self expectationWithDescription:@"old owner canceled"],*newDone=[self expectationWithDescription:@"new owner prepared"];
    NSProgress *old=[self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationCancelled);[oldDone fulfill];}];
    [self waitForExpectations:@[storage.entered] timeout:5];[old cancel];
    [self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationContinue);XCTAssertTrue(r.performedFirstPreparation);XCTAssertTrue(r.outcome.success);[newDone fulfill];}];
    dispatch_semaphore_signal(storage.gate);[self waitForExpectations:@[oldDone,newDone] timeout:10];XCTAssertEqual(requests,1u);XCTAssertEqual(self.outcomes.count,1u);
}
- (void)testSilentColdLoadAdmissionDefersInBackgroundBeforeChecking {
    // First read fails and releases Welcome; the next explicit foreground silent round owns a delayed cold load.
    [NSFileManager.defaultManager createDirectoryAtURL:self.storage.databaseURL withIntermediateDirectories:YES attributes:nil error:nil];
    OFTDelayedSQLiteStorage *storage=[[OFTDelayedSQLiteStorage alloc] initWithDatabaseURL:self.storage.databaseURL];storage.delayed=YES;self.storage=storage;
    __block NSUInteger requests=0;[self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){requests++;done([self config:10000 URL:self.archiveURL sha:self.sha],nil);return nil;}];
    XCTAssertFalse([self prepare].performedFirstPreparation);[NSFileManager.defaultManager removeItemAtURL:storage.databaseURL error:nil];
    storage.delayed=NO;storage.gate=dispatch_semaphore_create(0);storage.entered=[self expectationWithDescription:@"silent cold load held"];
    [self.sdk updatePrivacyGranted:YES foreground:YES];[self waitForExpectations:@[storage.entered] timeout:5];[self.sdk updatePrivacyGranted:YES foreground:NO];dispatch_semaphore_signal(storage.gate);[self idle];
    XCTAssertEqual(requests,0u);XCTAssertEqual(self.outcomes.count,0u);
    [self.sdk updatePrivacyGranted:YES foreground:YES];[self tick];XCTAssertEqual(requests,1u);XCTAssertTrue(self.outcomes.firstObject.success);
}
- (void)testActivationFailureRetainsReadyAndOnlyPreparationEmitsSuccess {
    [self SQL:@"CREATE TRIGGER reject_active BEFORE UPDATE OF stage ON offline_package WHEN NEW.stage='active' BEGIN SELECT RAISE(IGNORE); END"];
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:self.archiveURL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];
    XCTAssertEqual(self.outcomes.count,1u);XCTAssertTrue(self.outcomes.firstObject.success);XCTAssertEqualObjects([self.storage rowForVersion:10000 error:nil][@"stage"],OFTPackageStageReady);XCTAssertFalse([self page].offline);
    [self tick];XCTAssertEqual(self.outcomes.count,1u);[self SQL:@"DROP TRIGGER reject_active"];[self tick];XCTAssertEqual(self.outcomes.count,1u);XCTAssertTrue([self page].offline);
}
- (void)testCacheCleanerExceptionIsDiagnosticAndNoSecondRequestForSameTarget {
    [self seed:10000 stage:OFTPackageStageActive];[self entry:10000 text:@"A"];
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10001 URL:self.archiveURL sha:self.sha],nil);return nil;}];__block NSUInteger calls=0;
    self.sdk.resourceCacheCleaner=^{calls++;@throw [NSException exceptionWithName:@"SyntheticCache" reason:nil userInfo:nil];};
    [self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];[self idle];[self tick];XCTAssertEqual(calls,1u);XCTAssertEqual(self.outcomes.count,1u);XCTAssertTrue(self.outcomes.firstObject.success);
    XCTAssertEqual([self.diagnostics filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"stage == 'cache'"]].count,1u);
}
- (void)testVerifiedInvalidZIPIsRetainedAndReusedAfterInputDisappears {
    NSData *invalid=[@"not a ZIP archive" dataUsingEncoding:NSUTF8StringEncoding];NSString *sha=[self hash:invalid];
    [NSFileManager.defaultManager createDirectoryAtURL:self.sandbox withIntermediateDirectories:YES attributes:nil error:nil];NSURL *input=[self.sandbox URLByAppendingPathComponent:@"invalid-input.zip"];XCTAssertTrue([invalid writeToURL:input atomically:NO]);
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:input sha:sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];[self prepare];
    XCTAssertEqual(self.outcomes.firstObject.reason,OFTOfflineInvalidArchive);XCTAssertEqualObjects(self.outcomes.firstObject.stage,@"extract");XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[self.root URLByAppendingPathComponent:@"10000.zip"].path]);
    [NSFileManager.defaultManager removeItemAtURL:input error:nil];[self tick];XCTAssertEqual(self.outcomes.count,2u);XCTAssertEqual(self.outcomes.lastObject.reason,OFTOfflineInvalidArchive);XCTAssertEqualObjects(self.outcomes.lastObject.stage,@"extract");
}
- (NSDictionary *)prepareCapacityFixture:(NSString *)name {
    self.archiveURL=[[NSBundle bundleForClass:self.class] URLForResource:name withExtension:@"zip" subdirectory:@"Fixtures"];
    NSData *data=[NSData dataWithContentsOfURL:self.archiveURL];XCTAssertNotNil(data);self.sha=[self hash:data];
    [self manager:^NSProgress *(NSInteger v,OFTConfigurationCompletion done){done([self config:10000 URL:self.archiveURL sha:self.sha],nil);return nil;}];[self.sdk updatePrivacyGranted:YES foreground:YES];
    XCTestExpectation *done=[self expectationWithDescription:@"real managed capacity preparation"];
    [self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *r){XCTAssertEqual(r.disposition,OFTPreparationContinue);XCTAssertTrue(r.outcome.success);[done fulfill];}];
    [self waitForExpectations:@[done] timeout:180];XCTAssertEqual(self.outcomes.count,1u);XCTAssertTrue(self.outcomes.firstObject.success);XCTAssertEqualObjects(self.outcomes.firstObject.stage,@"publish");
    NSURL *directory=[self.root URLByAppendingPathComponent:@"10000" isDirectory:YES];NSDirectoryEnumerator *children=[NSFileManager.defaultManager enumeratorAtURL:directory includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLFileSizeKey] options:0 errorHandler:nil];
    uint64_t total=0;NSUInteger files=0;
    for(NSURL *file in children){NSNumber *regular=nil,*size=nil;[file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];if(regular.boolValue){files++;[file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];total+=size.unsignedLongLongValue;}}
    NSLog(@"Managed capacity %@: compressed=%lu expanded=%llu regularFiles=%lu prepared=%@",name,(unsigned long)data.length,total,(unsigned long)files,self.outcomes.firstObject.success?@"YES":@"NO");
    return @{@"bytes":@(total),@"files":@(files)};
}
- (void)testManagedSingleFileAbove64MiBPreparesSuccessfully {
    NSDictionary *actual=[self prepareCapacityFixture:@"oversized"];XCTAssertEqual([actual[@"bytes"] unsignedLongLongValue],64ULL*1024*1024+1);XCTAssertEqualObjects(actual[@"files"],@1);
}
- (void)testManagedMoreThan10000EntriesPrepareSuccessfully {
    NSDictionary *actual=[self prepareCapacityFixture:@"managed_entry_count_limit"];XCTAssertEqualObjects(actual[@"files"],@10001);XCTAssertEqualObjects(actual[@"bytes"],@2);
}
- (void)testManagedExpandedTotalAbove256MiBPreparesSuccessfully {
    NSDictionary *actual=[self prepareCapacityFixture:@"managed_large_total_valid"];XCTAssertEqual([actual[@"bytes"] unsignedLongLongValue],5ULL*52*1024*1024+2);XCTAssertEqualObjects(actual[@"files"],@6);
}
@end
