#import <XCTest/XCTest.h>
#import <SLCOfflineSDK/SLCOfflineSDK.h>
@interface SLCTestSchemeTask : NSObject <WKURLSchemeTask>
@property (nonatomic) NSURLRequest *request;
@property (nonatomic) NSMutableArray<NSString *> *events;
@property (nonatomic) NSURLResponse *response;
@property (nonatomic) NSData *data;
@property (nonatomic) NSError *error;
@property (nonatomic, copy) void (^responseBlock)(void);
@property (nonatomic, copy) void (^terminalBlock)(void);
@end
@implementation SLCTestSchemeTask
- (instancetype)init { if ((self=[super init])) _events=[NSMutableArray new]; return self; }
- (void)didReceiveResponse:(NSURLResponse *)response { self.response=response; [self.events addObject:@"response"]; if(self.responseBlock) self.responseBlock(); }
- (void)didReceiveData:(NSData *)data { self.data=data; [self.events addObject:@"data"]; }
- (void)didFinish { [self.events addObject:@"finish"]; if(self.terminalBlock) self.terminalBlock(); }
- (void)didFailWithError:(NSError *)error { self.error=error; [self.events addObject:@"error"]; if(self.terminalBlock) self.terminalBlock(); }
@end
@interface SLCSchemeHandlerTests : XCTestCase
@property NSURL *directory;
@property SLCOfflineSchemeHandler *handler;
@end
@implementation SLCSchemeHandlerTests
- (void)setUp {
    self.directory=[[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
    [@"<p>local</p>" writeToURL:[self.directory URLByAppendingPathComponent:@"index.html"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    self.handler=[[SLCOfflineSchemeHandler alloc] initWithDirectory:self.directory baseURL:[NSURL URLWithString:@"https://demo.example/app/"] scheme:@"offline-test"];
    XCTAssertNotNil(self.handler);
}
- (void)tearDown { [[NSFileManager defaultManager] removeItemAtURL:self.directory error:nil]; }
- (SLCTestSchemeTask *)task:(NSString *)address {
    SLCTestSchemeTask *task=[SLCTestSchemeTask new]; task.request=[NSURLRequest requestWithURL:[NSURL URLWithString:address]]; return task;
}
- (void)testReservedAndInvalidSchemesAreRejected {
    for (NSString *scheme in @[@"http",@"https",@"file",@"1bad",@"bad scheme",@""]) {
        XCTAssertNil([[SLCOfflineSchemeHandler alloc] initWithDirectory:self.directory baseURL:[NSURL URLWithString:@"https://demo.example/app/"] scheme:scheme]);
    }
}
- (void)testEntryConversionPreservesQueryAndFragmentAndRestrictsScope {
    NSURL *url=[self.handler offlineURLForURL:[NSURL URLWithString:@"https://demo.example/app/index.html?user=demo#route"]];
    XCTAssertEqualObjects(url.absoluteString,@"offline-test://demo.example/app/index.html?user=demo#route");
    for(NSString *invalid in @[@"https://other.example/app/index.html", @"https://demo.example/api/index.html", @"https://demo.example/app/missing.js", @"http://demo.example/app/index.html"]) {
        XCTAssertNil([self.handler offlineURLForURL:[NSURL URLWithString:invalid]]);
    }
}
- (void)testResponseUsesLocalBytesAndDoesNotGrantCORS {
    SLCTestSchemeTask *task=[self task:@"offline-test://demo.example/app/index.html"];
    XCTestExpectation *done=[self expectationWithDescription:@"response"];
    task.terminalBlock=^{ [done fulfill]; };
    [self.handler webView:nil startURLSchemeTask:task];
    [self waitForExpectations:@[done] timeout:5];
    XCTAssertEqualObjects(task.events,(@[@"response",@"data",@"finish"]));
    XCTAssertEqualObjects([[NSString alloc] initWithData:task.data encoding:NSUTF8StringEncoding],@"<p>local</p>");
    XCTAssertEqualObjects(task.response.MIMEType,@"text/html");
    NSDictionary *headers=((NSHTTPURLResponse *)task.response).allHeaderFields;
    XCTAssertNil(headers[@"Access-Control-Allow-Origin"]); XCTAssertEqualObjects(headers[@"Cache-Control"],@"no-store");
}
- (void)testMissingForeignPostAndRangeRequestsFailWithoutNetworkFallback {
    for (NSString *kind in @[@"missing",@"foreign",@"post",@"range"]) {
        NSString *address=[kind isEqualToString:@"missing"] ? @"offline-test://demo.example/app/missing.js" :
            [kind isEqualToString:@"foreign"] ? @"offline-test://foreign.example/app/index.html" : @"offline-test://demo.example/app/index.html";
        SLCTestSchemeTask *task=[self task:address]; NSMutableURLRequest *request=task.request.mutableCopy;
        if([kind isEqualToString:@"post"]) request.HTTPMethod=@"POST";
        if([kind isEqualToString:@"range"]) [request setValue:@"bytes=0-4" forHTTPHeaderField:@"Range"];
        task.request=request;
        XCTestExpectation *done=[self expectationWithDescription:kind]; task.terminalBlock=^{ [done fulfill]; };
        [self.handler webView:nil startURLSchemeTask:task]; [self waitForExpectations:@[done] timeout:5];
        XCTAssertEqualObjects(task.events,(@[@"error"])); XCTAssertNotNil(task.error);
    }
}
- (void)testStopDuringReadPreventsFurtherCallbacks {
    SLCTestSchemeTask *task=[self task:@"offline-test://demo.example/app/index.html"];
    XCTestExpectation *unexpected=[self expectationWithDescription:@"stopped callback"]; unexpected.inverted=YES;
    task.terminalBlock=^{ [unexpected fulfill]; }; task.responseBlock=^{ [unexpected fulfill]; };
    [self.handler webView:nil startURLSchemeTask:task]; [self.handler webView:nil stopURLSchemeTask:task];
    [self waitForExpectations:@[unexpected] timeout:0.25]; XCTAssertEqual(task.events.count,0);
}
- (void)testStopFromResponseCallbackPreventsDataAndFinish {
    SLCTestSchemeTask *task=[self task:@"offline-test://demo.example/app/index.html"];
    XCTestExpectation *response=[self expectationWithDescription:@"response"];
    __weak SLCTestSchemeTask *weakTask=task;
    task.responseBlock=^{ [self.handler webView:nil stopURLSchemeTask:weakTask]; [response fulfill]; };
    [self.handler webView:nil startURLSchemeTask:task]; [self waitForExpectations:@[response] timeout:5];
    XCTAssertEqualObjects(task.events,(@[@"response"]));
}
@end
