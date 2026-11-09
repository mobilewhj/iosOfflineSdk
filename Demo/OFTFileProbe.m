#import <UIKit/UIKit.h>
#import <OfflineTool/OfflineTool.h>
#import <CommonCrypto/CommonDigest.h>

// Consumer of managed installation + the SDK's required file network configuration.
// Requests remain real WebKit XHR/fetch; no API proxy or Origin rewriting.
@interface OFTFileProbeDelegate : UIResponder <UIApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic) WKWebView *webView;
@property(nonatomic) OFTManagedOfflineSDK *sdk;
@property(nonatomic) OFTPageBinding *binding;
@property(nonatomic) NSProgress *preparation;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) NSMutableDictionary *report;
@property(nonatomic) NSMutableArray *events;
@property(nonatomic, copy) NSString *runID;
@property(nonatomic, copy) NSString *serverBase;
@property(nonatomic, copy) NSString *secureServerBase;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic) NSInteger modeIndex;
@property(nonatomic) BOOL includeTargets;
@property(nonatomic) BOOL modeFinished;
@end

@implementation OFTFileProbeDelegate
- (NSString *)argument:(NSString *)name fallback:(NSString *)fallback {
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSUInteger index = [args indexOfObject:name];
    return index != NSNotFound && index + 1 < args.count ? args[index + 1] : fallback;
}
- (NSURL *)reportURL {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [documents URLByAppendingPathComponent:@"origin-probe-report.json"];
}
- (void)save {
    self.report[@"events"] = self.events;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:self.reportURL options:NSDataWritingAtomic error:nil];
}
- (void)record:(NSDictionary *)event {
    NSMutableDictionary *row = [event mutableCopy];
    row[@"elapsed"] = @([NSDate.date timeIntervalSince1970] - [self.report[@"started"] doubleValue]);
    [self.events addObject:row];
    NSLog(@"ORIGIN_PROBE %@", [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:row options:0 error:nil] encoding:NSUTF8StringEncoding]);
    [self save];
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.runID = [self argument:@"--run-id" fallback:NSUUID.UUID.UUIDString];
    self.serverBase = [self argument:@"--server-base" fallback:@"http://127.0.0.1:18769"];
    self.secureServerBase = [self argument:@"--https-server-base" fallback:@""];
    self.includeTargets = [NSProcessInfo.processInfo.arguments containsObject:@"--include-targets"];
    self.events = [NSMutableArray array];
    self.report = [@{@"runID":self.runID, @"started":@([NSDate.date timeIntervalSince1970]),
                     @"systemVersion":UIDevice.currentDevice.systemVersion,
                     @"sdkVersion":[[NSBundle bundleForClass:OFTManagedOfflineSDK.class] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
                     @"implementation":@"SDK managed loadPage using file binding",
                     @"includeTargets":@(self.includeTargets), @"finished":@NO,
                     @"configuration":@"SDK requires universal file network access; ephemeral store; local HTTP ATS exception; synthetic credentials only"} mutableCopy];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.systemBackgroundColor;
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, self.window.bounds.size.width - 32, 60)];
    self.statusLabel.numberOfLines = 3;
    self.statusLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [root.view addSubview:self.statusLabel];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    [self save];
    [self preparePackage];
    return YES;
}
- (void)preparePackage {
    NSURL *archive = [NSBundle.mainBundle URLForResource:@"file-probe" withExtension:@"zip"];
    NSData *bytes = archive ? [NSData dataWithContentsOfURL:archive] : nil;
    if (!bytes) { [self record:@{@"kind":@"fatal", @"error":@"Missing file-probe.zip"}]; [self finish]; return; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *sha = [NSMutableString string]; for (NSUInteger i=0; i<sizeof(digest); i++) [sha appendFormat:@"%02x", digest[i]];
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *root = [[support URLByAppendingPathComponent:NSUUID.UUID.UUIDString] URLByAppendingPathComponent:@"packages"];
    NSError *error;
    self.sdk = [[OFTManagedOfflineSDK alloc] initWithRootDirectory:root originalStaticRoot:[NSURL URLWithString:@"http://offline.example/app/"]
        minimumVersion:100000 checkInterval:300 storage:nil configurationProvider:^NSProgress *(OFTConfigurationCompletion done) {
            done([[OFTManagedConfiguration alloc] initWithEnabled:YES version:100000 packageURL:archive sha256:sha], nil); return nil;
        } error:&error];
    if (!self.sdk) { [self record:@{@"kind":@"fatal", @"error":error.localizedDescription ?: @"SDK initialization failed"}]; [self finish]; return; }
    [self.sdk updatePrivacyGranted:YES foreground:YES];
    self.preparation = [self.sdk prepareStartupWithProgress:nil completion:^(OFTPreparationResult *result) {
        [self record:@{@"kind":@"package-ready", @"success":@(result.outcome.success), @"version":@(result.outcome.record.version)}];
        if (!result.outcome.success) { [self record:@{@"kind":@"fatal", @"error":@"Managed install failed"}]; [self finish]; return; }
        [self nextMode];
    }];
}
- (NSDictionary *)headers {
    return @{@"Content-Type":@"application/json", @"X-Probe-Token":@"synthetic-probe-not-a-user-token",
             @"X-Probe-Session":@"synthetic-probe", @"X-Probe-Version":@"0.0.0-probe",
             @"X-Probe-Platform":@"ios", @"X-Probe-Run":@"offline-origin-probe", @"X-Probe-Container":@"H5"};
}
- (NSArray *)targets {
    NSMutableArray *targets = [NSMutableArray array];
    for (NSString *name in @[@"business", @"monitor"]) {
        NSString *url = [self argument:[NSString stringWithFormat:@"--%@-url", name] fallback:@""];
        if (url.length) [targets addObject:@{@"id":name, @"url":url}];
    }
    return targets;
}
- (void)nextMode {
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"originProbe"];
    [self.webView stopLoading];
    [self.webView removeFromSuperview];
    [self.binding dispose];
    self.binding = nil;
    NSInteger count = 1;
    if (self.modeIndex >= count) {
        [self finish];
        return;
    }
    self.modeIndex++; self.mode = @"file";
    self.modeFinished = NO;
    self.statusLabel.text = [NSString stringWithFormat:@"OfflineTool file · %@\nSDK 文件网络配置 · %@", self.mode, self.runID];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    [configuration.userContentController addScriptMessageHandler:self name:@"originProbe"];
    NSDictionary *settings = @{@"mode":self.mode, @"runID":self.runID, @"serverBase":self.serverBase, @"secureServerBase":self.secureServerBase,
                              @"headers":self.headers, @"targets":self.includeTargets ? self.targets : @[]};
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:settings options:0 error:nil] encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"window.__PROBE=%@;try{document.cookie='probe_cookie=synthetic';document.cookie='probe_context=example';}catch(e){window.__COOKIE_INJECTION_ERROR=String(e);}", json];
    [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    NSError *error;
    self.binding = [self.sdk pageBindingForConfiguration:configuration error:&error];
    if (!self.binding) { [self record:@{@"kind":@"fatal", @"mode":self.mode, @"error":error.localizedDescription ?: @"binding failed"}]; [self nextMode]; return; }
    [self record:@{@"kind":@"file-network-configuration", @"enabled":[configuration valueForKey:@"allowUniversalAccessFromFileURLs"] ?: @NO}];
    CGRect area = self.window.rootViewController.view.bounds;
    area.origin.y = 130; area.size.height -= 130;
    self.webView = [[WKWebView alloc] initWithFrame:area configuration:configuration];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    if (@available(iOS 16.4, *)) self.webView.inspectable = YES;
    [self.window.rootViewController.view addSubview:self.webView];
    [self record:@{@"kind":@"mode-start", @"mode":self.mode}];
    [self.sdk loadPage:[NSURL URLWithString:@"http://offline.example/app/index.html?probe=a%26b#/file-validation"] inWebView:self.webView binding:self.binding completion:^(OFTPageLoadResult *result, NSError *error) {
        [self record:@{@"kind":@"sdk-page-selection", @"mode":self.mode, @"offline":@(result.offline), @"version":@(result.record.version),
            @"url":result.loadedURL.absoluteString ?: @"", @"error":error.localizedDescription ?: @""}];
    }];
    NSString *current = self.mode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self.modeFinished && [self.mode isEqualToString:current]) {
            [self record:@{@"kind":@"watchdog", @"mode":current}];
            self.modeFinished = YES;
            [self nextMode];
        }
    });
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *body = message.body;
    [self record:body];
    if ([body[@"kind"] isEqual:@"complete"] && !self.modeFinished) {
        self.modeFinished = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self nextMode]; });
    }
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self record:@{@"kind":@"navigation-error", @"mode":self.mode, @"error":error.localizedDescription}];
    if (!self.modeFinished) { self.modeFinished = YES; [self nextMode]; }
}
- (void)finish {
    [self.binding dispose]; [self.sdk close];
    self.report[@"finished"] = @YES;
    self.report[@"ended"] = @([NSDate.date timeIntervalSince1970]);
    [self save];
    self.statusLabel.text = @"对照测试完成\n结果已保存：origin-probe-report.json";
    UITextView *summary = [[UITextView alloc] initWithFrame:CGRectMake(12, 130, self.window.bounds.size.width - 24, self.window.bounds.size.height - 150)];
    summary.editable = NO;
    summary.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    NSMutableString *text = [NSMutableString stringWithFormat:@"iOS %@\n\n", UIDevice.currentDevice.systemVersion];
    for (NSDictionary *event in self.events) if ([event[@"kind"] isEqual:@"case-result"]) [text appendFormat:@"%@  %@\nstatus=%@  %@\n\n", event[@"mode"], event[@"name"], event[@"status"], event[@"event"]];
    summary.text = text;
    [self.window.rootViewController.view addSubview:summary];
    NSLog(@"ORIGIN_PROBE_FINISHED %@", self.reportURL.path);
}
@end
