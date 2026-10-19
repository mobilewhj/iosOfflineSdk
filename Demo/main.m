#import <UIKit/UIKit.h>
#import <OfflineTool/OfflineTool.h>
#import "DemoStartupPreparationViewController.h"
#import "Bridge/WKWebViewJavascriptBridge.h"
#import <sys/stat.h>

// 示例只负责 UI、配置映射和生命周期；版本、首次资格与检查周期由同一个 SDK 管理。
@interface DemoManagedPage : NSObject
@property (nonatomic) WKWebView *webView;
@property (nonatomic) OFTPageBinding *binding;
@property (nonatomic) WKWebViewJavascriptBridge *bridge;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) OFTPageLoadResult *loadResult;
@end
@implementation DemoManagedPage
@end

@interface DemoDelegate : UIResponder <UIApplicationDelegate, WKNavigationDelegate>
@property (nonatomic) UIWindow *window;
@property (nonatomic) OFTManagedOfflineSDK *sdk;
@property (nonatomic) DemoStartupPreparationViewController *preparation;
@property (nonatomic) UILabel *status;
@property (nonatomic) UIStackView *pageStack;
@property (nonatomic) NSMutableArray<DemoManagedPage *> *pages;
@property (nonatomic) NSURLSession *testSession;
@property (nonatomic) WKWebsiteDataStore *isolatedStore;
@property (nonatomic) NSProgress *startup;
@property (nonatomic) NSMutableDictionary *report;
@property (nonatomic) NSMutableArray *events;
@property (nonatomic) dispatch_queue_t reportQueue;
@property (nonatomic, copy) NSString *serverBase;
@property (nonatomic, copy) NSString *runID;
@property (nonatomic) BOOL privacyGranted;
@property (nonatomic) BOOL startupAttempted;
@property (nonatomic) BOOL navigated;
@property (nonatomic) BOOL automaticSmoke;
@property (nonatomic) BOOL startupOnly;
@property (nonatomic) BOOL longCadence;
@property (nonatomic) BOOL openedDuringB;
@property (nonatomic) BOOL requestedB;
@property (nonatomic) BOOL installedB;
@property (nonatomic) BOOL disabledObserved;
@property (nonatomic) BOOL switchedUser;
@property (nonatomic) BOOL didCancelAfterProgress;
@property (nonatomic, copy) NSString *syntheticUserID;
@property (nonatomic) NSUInteger navigationCount;
@property (nonatomic) NSURL *installationRoot;
@property (nonatomic) BOOL webFaultProbes;
@property (nonatomic) BOOL faultProbesStarted;
@property (nonatomic) BOOL faultProbesFinished;
@property (nonatomic) NSURL *faultReadFile;
@property (nonatomic) NSUInteger faultReadMode;
@property (nonatomic) BOOL redirectCSSProbe;
@property (nonatomic) BOOL redirectCSSFinished;
@property (nonatomic, copy) NSString *checkingAction;
@property (nonatomic) BOOL checkingActionFired;
@property (nonatomic) NSUInteger providerCount;
@property (nonatomic, copy) NSString *backgroundConfiguration;
@property (nonatomic) BOOL backgroundConfigurationBackgrounded;
@property (nonatomic) BOOL backgroundConfigurationReceived;
@property (nonatomic) BOOL backgroundConfigurationOpened;
@property (nonatomic) BOOL backgroundPageReported;
@property (nonatomic) BOOL backgroundOldPageReported;
@end

@implementation DemoDelegate
- (NSString *)argument:(NSString *)name fallback:(NSString *)fallback {
    NSArray *arguments = NSProcessInfo.processInfo.arguments;
    NSUInteger index = [arguments indexOfObject:name];
    return index != NSNotFound && index + 1 < arguments.count ? arguments[index + 1] : fallback;
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSArray *arguments = NSProcessInfo.processInfo.arguments;
    self.automaticSmoke = [arguments containsObject:@"--managed-smoke"];
    self.startupOnly = [arguments containsObject:@"--startup-only"];
    self.longCadence = [arguments containsObject:@"--long-cadence"];
    self.webFaultProbes = [arguments containsObject:@"--web-fault-probes"];
    self.redirectCSSProbe = [arguments containsObject:@"--redirect-css-probe"];
    self.checkingAction = [self argument:@"--checking-action" fallback:@""];
    self.backgroundConfiguration = [self argument:@"--background-configuration" fallback:@""];
    self.privacyGranted = ![arguments containsObject:@"--privacy-deferred"];
    self.syntheticUserID = @"synthetic-user-one";
    NSString *port = [self argument:@"--server-port" fallback:@"18765"];
    self.serverBase = [@"http://127.0.0.1:" stringByAppendingString:port];
    self.runID = [self argument:@"--run-id" fallback:NSUUID.UUID.UUIDString];
    self.runID = [[self.runID componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@"-"];
    self.reportQueue = dispatch_queue_create("com.offline.tool.demo.report", DISPATCH_QUEUE_SERIAL);
    self.events = [NSMutableArray array]; self.pages = [NSMutableArray array];
    self.report = [@{@"runID":self.runID, @"systemVersion":UIDevice.currentDevice.systemVersion,
        @"bundleID":NSBundle.mainBundle.bundleIdentifier ?: @"", @"defaultCadence":@(self.longCadence || !self.automaticSmoke),
        @"events":self.events, @"pages":[NSMutableArray array], @"navigationCount":@0, @"finished":@NO} mutableCopy];
    NSURLSessionConfiguration *network = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    network.URLCache = nil; network.HTTPCookieStorage = nil; network.HTTPShouldSetCookies = NO;
    self.testSession = [NSURLSession sessionWithConfiguration:network];
    self.isolatedStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.preparation = [DemoStartupPreparationViewController new];
    self.window.rootViewController = self.preparation; [self.window makeKeyAndVisible];
    [self installControlsInController:self.preparation];
    self.status.text = @"iOS 托管离线 SDK 隔离示例\n启动页消费本次准备结果；应用入口继续持有 SDK。仅使用合成数据和回环测试源。";
    __weak typeof(self) weakSelf = self;
    OFTConfigurationProvider provider = ^NSProgress *(OFTConfigurationCompletion completion) {
        return [weakSelf requestConfiguration:completion];
    };
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *storageID = [self argument:@"--storage-id" fallback:@"managed-isolated-v1"];
    storageID = [[storageID componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@"-"];
    NSURL *root = [[support URLByAppendingPathComponent:storageID] URLByAppendingPathComponent:@"packages"];
    self.installationRoot = root;
    NSURL *staticRoot = [NSURL URLWithString:[self.serverBase stringByAppendingString:@"/app/"]];
    NSError *creationError;
    if (self.automaticSmoke && !self.longCadence) {
        self.sdk = [[OFTManagedOfflineSDK alloc] initWithRootDirectory:root originalStaticRoot:staticRoot minimumVersion:10000 checkInterval:8 storage:nil configurationProvider:provider error:&creationError];
    } else {
        self.sdk = [[OFTManagedOfflineSDK alloc] initWithRootDirectory:root originalStaticRoot:staticRoot configurationProvider:provider error:&creationError];
    }
    if (!self.sdk) {
        [self record:@"manager-creation-failed" fields:@{@"reason":@(creationError.code)}];
        self.status.text = @"SDK 初始化失败，详见本次 JSON。"; return YES;
    }
    self.sdk.resourceCacheCleaner = ^{
        [weakSelf.isolatedStore removeDataOfTypes:[NSSet setWithObjects:WKWebsiteDataTypeMemoryCache,WKWebsiteDataTypeDiskCache,nil] modifiedSince:NSDate.distantPast completionHandler:^{}];
        [weakSelf record:@"cache-removal-request" fields:@{}];
    };
    self.sdk.outcomeHandler = ^(OFTManagedOutcome *outcome) {
        [weakSelf record:@"outcome" fields:@{@"version":@(outcome.record.version), @"success":@(outcome.success), @"stage":outcome.stage, @"reason":@(outcome.reason), @"requestStarted":@(outcome.requestStarted), @"activeVersion":@(outcome.activeVersion),
            @"publishedRemains":@(outcome.publishedDirectoryRemains), @"publishedUnknown":@(outcome.publishedDirectoryStateUnknown), @"publishedVersion":outcome.publishedRecord ? @(outcome.publishedRecord.version) : NSNull.null, @"cleanupFailureCount":@(outcome.cleanupFailureCount)}];
        if (outcome.success && outcome.record.version == 10001 && weakSelf.requestedB) {
            weakSelf.installedB = YES;
            [weakSelf record:@"ready-awaits-cold-start" fields:@{@"version":@(outcome.record.version),@"activeVersion":@(outcome.activeVersion)}];
            [weakSelf openPageNamed:@"online-after-B-ready"];
            [weakSelf laterProbeInFirstPage:@"fixed-after-B"];
        }
    };
    self.sdk.diagnosticHandler = ^(NSString *stage, OFTOfflineErrorCode reason, NSString *detail) {
        [weakSelf record:@"diagnostic" fields:@{@"stage":stage, @"reason":@(reason), @"detail":detail}];
    };
    [self record:@"launch" fields:@{@"privacy":@(self.privacyGranted), @"cadenceSeconds":@(self.automaticSmoke && !self.longCadence ? 8 : 300)}];
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self.sdk updatePrivacyGranted:self.privacyGranted foreground:YES];
    [self record:@"foreground" fields:@{}];
    if (!self.startupAttempted && self.sdk) [self prepareStartup];
    [self openAfterBackgroundConfiguration];
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    [self.sdk updatePrivacyGranted:self.privacyGranted foreground:NO];
    [self record:@"background" fields:@{}];
    if (self.backgroundConfiguration.length) self.backgroundConfigurationBackgrounded = YES;
}
- (void)installControlsInController:(UIViewController *)controller {
    self.status = [UILabel new]; self.status.numberOfLines = 0; self.status.font = [UIFont systemFontOfSize:13];
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    NSArray *titles = @[@"继续 / 重入", @"取消首次", @"隐私开关", @"新页面", @"测试源 B", @"测试源关闭"];
    NSArray *actions = @[@"prepareStartup", @"cancelStartup", @"togglePrivacy", @"openManualPage", @"selectB", @"selectDisabled"];
    UIStackView *controls = [UIStackView new]; controls.axis = UILayoutConstraintAxisVertical; controls.spacing = 2;
    for (NSUInteger row = 0; row < 2; row++) {
        UIStackView *line = [UIStackView new]; line.axis = UILayoutConstraintAxisHorizontal; line.distribution = UIStackViewDistributionFillEqually;
        for (NSUInteger column = 0; column < 3; column++) {
            NSUInteger index = row * 3 + column;
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:titles[index] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:12]; button.accessibilityIdentifier = actions[index];
            [button addTarget:self action:NSSelectorFromString(actions[index]) forControlEvents:UIControlEventTouchUpInside];
            [line addArrangedSubview:button];
        }
        [controls addArrangedSubview:line];
    }
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:self.status]; [controller.view addSubview:controls];
    [NSLayoutConstraint activateConstraints:@[
        [self.status.topAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.topAnchor constant:10],
        [self.status.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor constant:14],
        [self.status.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor constant:-14],
        [controls.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:5],
        [controls.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor constant:8],
        [controls.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor constant:-8], [controls.heightAnchor constraintEqualToConstant:64]]];
    if (controller != self.preparation) {
        UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO; [controller.view addSubview:scroll];
        self.pageStack = [UIStackView new]; self.pageStack.axis = UILayoutConstraintAxisVertical; self.pageStack.spacing = 10;
        self.pageStack.translatesAutoresizingMaskIntoConstraints = NO; [scroll addSubview:self.pageStack];
        [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:8],
            [scroll.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.bottomAnchor],
            [self.pageStack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor], [self.pageStack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
            [self.pageStack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor], [self.pageStack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
            [self.pageStack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];
    }
}
- (void)prepareStartup {
    if (self.navigated) return;
    self.startupAttempted = YES; [self.startup cancel];
    [self.preparation hideProgress];
    __weak typeof(self) weakSelf = self;
    self.startup = [self.sdk prepareStartupWithProgress:^(OFTPreparationProgress *progress) {
        if (weakSelf.navigated) return;
        NSString *message = @{@"checking":@"正在检查启动条件…", @"prepare":DemoStartupPreparingMessage,
            @"download":DemoStartupDownloadingMessage, @"verify":@"正在校验资源包…", @"extract":DemoStartupExtractingMessage,
            @"saving":@"正在保存资源版本…", @"confirming":@"正在确认资源可用…", @"complete":DemoStartupCompleteMessage}[progress.stage] ?: DemoStartupFinishingMessage;
        NSNumber *fraction = progress.fraction >= 0 ? @(progress.fraction) : nil;
        [weakSelf.preparation showMessage:message fraction:fraction];
        [weakSelf record:@"first-progress" fields:@{@"stage":progress.stage, @"completed":@(progress.completed), @"total":@(progress.total), @"fraction":fraction ?: NSNull.null}];
        if ([progress.stage isEqualToString:@"checking"] && weakSelf.checkingAction.length && !weakSelf.checkingActionFired) {
            // 同步回调可重入 SDK；这里直接撤回条件/close，检查结束后不会额外启动 provider。
            weakSelf.checkingActionFired = YES;
            [weakSelf record:@"checking-callback-action" fields:@{@"action":weakSelf.checkingAction}];
            if ([weakSelf.checkingAction isEqualToString:@"privacy"]) {
                weakSelf.privacyGranted = NO; [weakSelf.sdk updatePrivacyGranted:NO foreground:YES];
            } else if ([weakSelf.checkingAction isEqualToString:@"close"]) [weakSelf.sdk close];
        }
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--cancel-after-progress"] && !weakSelf.didCancelAfterProgress && [progress.stage isEqualToString:@"download"] && progress.completed > 0) {
            weakSelf.didCancelAfterProgress = YES;
            [weakSelf record:@"owner-cancel-download" fields:@{@"completed":@(progress.completed), @"total":@(progress.total)}];
            [weakSelf.startup cancel];
        }
    } completion:^(OFTPreparationResult *result) {
        [weakSelf record:@"startup-result" fields:@{@"disposition":@(result.disposition), @"performedFirst":@(result.performedFirstPreparation),
            @"success":result.outcome ? @(result.outcome.success) : NSNull.null}];
        if (result.disposition == OFTPreparationContinue) {
            weakSelf.status.text = result.outcome && !result.outcome.success ? @"首次离线准备失败，已结束等待；继续使用线上入口。" : @"本次启动准备已结束。应用入口仍持有同一个 SDK。";
            if (!result.performedFirstPreparation) [weakSelf.preparation hideProgress];
            // 导航只消费本次结果，不消费任何全局重播进度。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, result.performedFirstPreparation ? 500 * NSEC_PER_MSEC : 0), dispatch_get_main_queue(), ^{ [weakSelf continueFromStartup]; });
        } else {
            [weakSelf.preparation hideProgress];
            weakSelf.status.text = result.disposition == OFTPreparationCancelled ? @"已取消首次准备，未记作首次完成。可重新进入。" : @"首次准备暂缓：需同意隐私且处于前台。可重新进入。";
            if (weakSelf.checkingAction.length || [NSProcessInfo.processInfo.arguments containsObject:@"--finish-deferred"]) {
                [weakSelf finishScenario:weakSelf.checkingAction.length ? @"checking-callback-cancel" : @"first-conditions-deferred"];
            }
            if (result.disposition == OFTPreparationCancelled && weakSelf.didCancelAfterProgress && [NSProcessInfo.processInfo.arguments containsObject:@"--auto-reenter-after-cancel"]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [weakSelf prepareStartup]; });
            }
        }
    }];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--cancel-startup"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [weakSelf cancelStartup]; });
    }
}
- (void)continueFromStartup {
    if (self.navigated) return;
    self.navigated = YES; self.navigationCount += 1; self.report[@"navigationCount"] = @(self.navigationCount);
    UIViewController *pages = [UIViewController new]; pages.view.backgroundColor = UIColor.whiteColor;
    self.window.rootViewController = pages; [self installControlsInController:pages];
    // 本次导航已消费，释放启动页和完成句柄；应用入口继续独立持有 SDK。
    self.preparation = nil; self.startup = nil;
    self.status.text = @"已离开启动页。应用级 SDK 按条件静默更新；每个 WebView 固定本次页面版本。";
    [self record:@"left-startup" fields:@{}]; [self openPageNamed:@"initial-A"];
}
- (void)cancelStartup { [self.startup cancel]; [self record:@"owner-cancel" fields:@{}]; }
- (void)togglePrivacy {
    self.privacyGranted = !self.privacyGranted;
    [self.sdk updatePrivacyGranted:self.privacyGranted foreground:UIApplication.sharedApplication.applicationState == UIApplicationStateActive];
    [self record:@"privacy" fields:@{@"granted":@(self.privacyGranted)}];
    self.status.text = self.privacyGranted ? @"已同意隐私。SDK 按实际请求间隔判断静默资格。" : @"已撤回隐私。SDK 取消相应工作。";
}
- (NSProgress *)requestConfiguration:(OFTConfigurationCompletion)completion {
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
    self.providerCount += 1;
    NSUInteger ordinal = self.providerCount;
    [self record:@"provider-start" fields:@{@"ordinal":@(ordinal)}];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.testSession dataTaskWithURL:[NSURL URLWithString:[self.serverBase stringByAppendingString:@"/configuration"]] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL valid = [value isKindOfClass:NSDictionary.class] && [value[@"enabled"] isKindOfClass:NSNumber.class] && ((NSHTTPURLResponse *)response).statusCode == 200;
        OFTManagedConfiguration *configuration;
        if (valid && ![value[@"enabled"] boolValue]) configuration = [[OFTManagedConfiguration alloc] initWithEnabled:NO version:0 packageURL:nil sha256:nil];
        else if (valid) configuration = [[OFTManagedConfiguration alloc] initWithEnabled:YES version:[value[@"version"] integerValue]
            packageURL:[NSURL URLWithString:value[@"packageURL"] ?: @""] sha256:value[@"sha256"]];
        NSError *failure = error ?: (valid ? nil : [NSError errorWithDomain:@"DemoConfiguration" code:1 userInfo:nil]);
        completion(configuration, failure);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf record:@"provider-result" fields:@{@"enabled":configuration ? @(configuration.enabled) : NSNull.null,
                @"version":configuration ? @(configuration.version) : NSNull.null, @"failed":@(failure != nil), @"ordinal":@(ordinal)}];
            if (weakSelf.backgroundConfiguration.length && ordinal == 2) {
                weakSelf.backgroundConfigurationReceived = YES;
                [weakSelf record:@"background-configuration-received" fields:@{@"backgroundObserved":@(weakSelf.backgroundConfigurationBackgrounded)}];
                [weakSelf openAfterBackgroundConfiguration]; return;
            }
            if (configuration.enabled && configuration.version == 10001 && weakSelf.requestedB && !weakSelf.openedDuringB) {
                weakSelf.openedDuringB = YES;
                // 一次场景动作等配置事实生效后开页；没有 App 轮询器。
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [weakSelf openPageNamed:@"online-during-B"]; });
            } else if (configuration && !configuration.enabled && weakSelf.installedB && !weakSelf.disabledObserved) {
                weakSelf.disabledObserved = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [weakSelf laterProbeInFirstPage:@"after-disable"]; [weakSelf openPageNamed:@"online-disabled"]; });
            }
        });
    }];
    progress.cancellationHandler = ^{ [task cancel]; }; [task resume]; return progress;
}
- (void)openManualPage { if (self.navigated) [self openPageNamed:[NSString stringWithFormat:@"manual-%lu", (unsigned long)self.pages.count]]; }
- (void)openPageNamed:(NSString *)name {
    if (!self.navigated || !self.pageStack) return;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = self.isolatedStore;
    NSString *approvedPort = [NSURLComponents componentsWithString:self.serverBase].port.stringValue;
    BOOL cookieFallback = [name isEqualToString:@"online-disabled"];
    NSString *userID = self.syntheticUserID;
    NSString *identity = cookieFallback ? @"" : [NSString stringWithFormat:@",user:{userID:'%@',displayName:'Synthetic Demo'},device:{plat:'iOS',ver:'0.0.synthetic',deviceID:'synthetic-device'}", userID];
    // 合成明文 JSON 仅证明既有 getMessage 形状与注入顺序，不复制业务 AES 或真实身份。
    NSString *bootstrap = [NSString stringWithFormat:@"if(location.hostname==='127.0.0.1' && location.port==='%@' && (location.protocol==='http:' || location.protocol==='offline-managed:') && location.pathname.indexOf('/app/')===0){Object.defineProperty(window,'__OFFLINE_DEMO_BOOTSTRAP__',{value:{displayName:'Synthetic Demo',apiBase:'%@'%@},writable:false});if(location.protocol==='http:'){document.cookie='_demoUser='+encodeURIComponent(JSON.stringify({userID:'synthetic-cookie-user',displayName:'Synthetic Demo'}))+'; path=/';document.cookie='_demoDevice='+encodeURIComponent(JSON.stringify({plat:'iOS',ver:'0.0.synthetic',deviceID:'synthetic-cookie-device'}))+'; path=/';}}", approvedPort, self.serverBase, identity];
    [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:bootstrap injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    NSError *error;
    OFTPageBinding *binding = [self.sdk pageBindingForConfiguration:configuration scheme:@"offline-managed" error:&error];
    if (!binding) { [self record:@"page-configuration-failed" fields:@{@"page":name, @"reason":@(error.code)}]; return; }
    DemoManagedPage *page = [DemoManagedPage new]; page.name = name; page.binding = binding;
    page.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    page.bridge = [WKWebViewJavascriptBridge bridgeForWebView:page.webView];
    [page.bridge setWebViewDelegate:self];
    __weak typeof(self) weakSelf = self; __weak DemoManagedPage *weakPage = page;
    [page.bridge registerHandler:@"demoEcho" handler:^(id data, WVJBResponseCallback reply) {
        [weakSelf record:@"bridge-js-to-native" fields:@{@"page":weakPage.name ?: @""}]; reply(@{@"kind":@"synthetic-native"});
    }];
    [page.bridge registerHandler:@"demoReport" handler:^(id data, WVJBResponseCallback reply) {
        if (![data isKindOfClass:NSDictionary.class]) return;
        [weakSelf page:weakPage reported:data]; reply(@{@"received":@YES});
    }];
    UILabel *title = [UILabel new]; title.font = [UIFont boldSystemFontOfSize:13]; title.text = name;
    [self.pageStack addArrangedSubview:title]; [self.pageStack addArrangedSubview:page.webView];
    [page.webView.heightAnchor constraintEqualToConstant:300].active = YES;
    [self.pages addObject:page];
    NSURL *entry = [NSURL URLWithString:[self.serverBase stringByAppendingString:@"/app/index.html?demo=managed#ready"]];
    [self.sdk loadPage:entry inWebView:page.webView binding:binding completion:^(OFTPageLoadResult *result, NSError *failure) {
        weakPage.loadResult = result;
        [weakSelf record:@"page-decision" fields:@{@"page":name, @"offline":result ? @(result.offline) : NSNull.null,
            @"version":result.record ? @(result.record.version) : NSNull.null, @"failed":@(failure != nil)}];
    }];
    // 合成网络 Cookie 与离线启动信息分开；缓存测试只观察保留，不迁移真实凭据。
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName:@"managed-synthetic", NSHTTPCookieValue:@"preserved", NSHTTPCookieDomain:@"127.0.0.1", NSHTTPCookiePath:@"/"}];
    [configuration.websiteDataStore.httpCookieStore setCookie:cookie completionHandler:^{ [weakSelf record:@"synthetic-cookie-set" fields:@{@"page":name}]; }];
}
- (void)page:(DemoManagedPage *)page reported:(NSDictionary *)value {
    if (!page) return;
    NSMutableDictionary *safe = [value mutableCopy]; safe[@"page"] = page.name;
    [(NSMutableArray *)self.report[@"pages"] addObject:safe]; [self record:@"web-report" fields:safe];
    if ([value[@"kind"] isEqual:@"redirect-css"]) {
        self.redirectCSSFinished = YES; [self continueInitialScenario]; return;
    }
    if ([value[@"kind"] isEqual:@"background-disabled"] || [value[@"kind"] isEqual:@"background-B"]) {
        self.backgroundOldPageReported = YES; [self finishBackgroundConfigurationIfReady]; return;
    }
    if ([value[@"kind"] isEqual:@"read-failure"] && self.faultReadFile) {
        [self restoreFaultReadFile]; [self openPageNamed:@"fault-cancel"];
    }
    if ([value[@"kind"] isEqual:@"initial"]) {
        __weak typeof(self) weakSelf = self;
        [page.bridge callHandler:@"demoToJs" data:@{@"kind":@"synthetic-native"} responseCallback:^(id response) {
            [weakSelf record:@"bridge-native-to-js" fields:@{@"page":page.name, @"received":[response isKindOfClass:NSDictionary.class] ? response[@"received"] ?: @NO : @NO}];
        }];
        [page.webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
            BOOL retained = NO; for (NSHTTPCookie *cookie in cookies) if ([cookie.name isEqualToString:@"managed-synthetic"]) retained = YES;
            [weakSelf record:@"cookie-observed" fields:@{@"page":page.name, @"retained":@(retained)}];
        }];
        if ([page.name isEqualToString:@"initial-A"]) {
            if (self.redirectCSSProbe && !self.redirectCSSFinished) [self runRedirectCSSProbe:page];
            else if (self.webFaultProbes && !self.faultProbesStarted) [self startWebFaultProbes];
            else [self continueInitialScenario];
        } else if ([page.name isEqualToString:@"after-background-configuration"]) {
            self.backgroundPageReported = YES; [self finishBackgroundConfigurationIfReady];
        } else if ([page.name isEqualToString:@"fault-cancel"]) {
            [self cancelSlowScriptInPage:page];
        } else if ([page.name isEqualToString:@"online-after-B-ready"] && self.installedB) {
            if (!self.switchedUser) {
                self.switchedUser = YES; self.syntheticUserID = @"synthetic-user-two";
                [self record:@"synthetic-user-switch" fields:@{}]; [self openPageNamed:@"user-switched"];
            }
            if (self.longCadence) [self finishScenario:@"natural-300s-B-ready-awaits-cold"];
            else if (self.automaticSmoke) [self selectDisabled];
        } else if ([page.name isEqualToString:@"online-disabled"]) [self finishScenario:@"A-to-B-ready-to-disabled"];
    }
}
- (void)continueInitialScenario {
    if (self.redirectCSSProbe && !self.redirectCSSFinished) return;
    if (self.webFaultProbes && !self.faultProbesFinished) return;
    if (self.backgroundConfiguration.length) {
        // 测试源只延迟下一次配置；真实前后台切换由外部隔离运行器操作系统 App。
        [self control:@{@"version":@"B",
            @"disabled":@([self.backgroundConfiguration isEqualToString:@"disabled"]), @"configDelay":@4} completion:nil];
        return;
    }
    if (self.startupOnly) [self finishScenario:@"startup-only"];
    else if (self.automaticSmoke && !self.requestedB) [self selectB];
}
- (void)runRedirectCSSProbe:(DemoManagedPage *)page {
    // CSS 及其相对图片均不在 ZIP，必须走真实 handler；路径与实际样式由 WebKit 回报。
    NSString *script = @"void(function(){var box=document.createElement('div');box.id='redirect-probe';box.textContent='CSS redirect';document.body.appendChild(box);var link=document.createElement('link');link.rel='stylesheet';link.href='css/start.css?case=redirect-css';link.onerror=function(){window.WebViewJavascriptBridge.callHandler('demoReport',{kind:'redirect-css',cssLoaded:false});};link.onload=function(){setTimeout(function(){var style=getComputedStyle(box);var background=style.backgroundImage;var imageURL=background.indexOf('url(')===0?background.slice(4,-1).split(String.fromCharCode(34)).join('').split(String.fromCharCode(39)).join(''):'';var image=new Image();var result={kind:'redirect-css',cssLoaded:true,color:style.color,background:background,cssHref:link.href};image.onload=function(){result.imageLoaded=true;result.width=image.naturalWidth;result.height=image.naturalHeight;window.WebViewJavascriptBridge.callHandler('demoReport',result);};image.onerror=function(){result.imageLoaded=false;window.WebViewJavascriptBridge.callHandler('demoReport',result);};if(imageURL)image.src=imageURL;else{result.imageLoaded=false;window.WebViewJavascriptBridge.callHandler('demoReport',result);}},100);};document.head.appendChild(link);})();";
    [page.webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        [self record:@"redirect-css-injected" fields:@{@"failed":@(error != nil)}];
    }];
}
- (void)openAfterBackgroundConfiguration {
    if (!self.backgroundConfigurationReceived || !self.backgroundConfigurationBackgrounded || self.backgroundConfigurationOpened ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.backgroundConfigurationOpened = YES;
    [self record:@"background-configuration-foreground-page" fields:@{}];
    [self openPageNamed:@"after-background-configuration"];
    [self laterProbeInFirstPage:[self.backgroundConfiguration isEqualToString:@"disabled"] ? @"background-disabled" : @"background-B"];
}
- (void)finishBackgroundConfigurationIfReady {
    if (self.backgroundPageReported && self.backgroundOldPageReported) [self finishScenario:@"background-returned-configuration"];
}
- (void)startWebFaultProbes {
    self.faultProbesStarted = YES;
    DemoManagedPage *page = self.pages.firstObject;
    OFTPackageRecord *record = page.loadResult.record;
    NSURL *file = record ? [[self.installationRoot URLByAppendingPathComponent:@(record.version).stringValue] URLByAppendingPathComponent:@"payload.json"] : nil;
    struct stat info;
    BOOL isolated = file && [file.path hasPrefix:[self.installationRoot.path stringByAppendingString:@"/"]] &&
        lstat(file.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode);
    if (!isolated || chmod(file.fileSystemRepresentation, 0) != 0) {
        [self record:@"read-failure-probe-unavailable" fields:@{}]; [self openPageNamed:@"fault-cancel"]; return;
    }
    self.faultReadMode = info.st_mode & 0777; self.faultReadFile = file;
    // 只更改本次 SDK 隔离根中的合成 payload；真实 JS 回报或超时都会恢复权限。
    [self record:@"read-failure-permission-set" fields:@{@"version":@(record.version)}];
    [self laterProbeInFirstPage:@"read-failure"];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!weakSelf.faultReadFile) return;
        [weakSelf record:@"read-failure-probe-timeout" fields:@{}];
        [weakSelf restoreFaultReadFile]; [weakSelf openPageNamed:@"fault-cancel"];
    });
}
- (void)restoreFaultReadFile {
    NSURL *file = self.faultReadFile;
    if (!file) return;
    BOOL restored = chmod(file.fileSystemRepresentation, (mode_t)self.faultReadMode) == 0;
    [self record:@"read-failure-permission-restored" fields:@{@"restored":@(restored)}];
    self.faultReadFile = nil;
}
- (void)cancelSlowScriptInPage:(DemoManagedPage *)page {
    // 真实 WK 页面发起请求；dispose 仅取消该页面的 handler，不结束应用级更新。
    NSString *script = @"void(function(){var script=document.createElement('script');script.src='slow.js?case=cancel-probe';document.head.appendChild(script);})();";
    [page.webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        [self record:@"slow-script-inserted" fields:@{@"failed":@(error != nil)}];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [page.binding dispose]; [page.webView stopLoading];
        [self record:@"fault-page-disposed" fields:@{@"page":page.name}];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [page.webView evaluateJavaScript:@"typeof window.__SLOW_EXECUTED__ === 'undefined'" completionHandler:^(id value, NSError *error) {
            [self record:@"slow-script-after-dispose" fields:@{@"notExecuted":value ?: NSNull.null, @"failed":@(error != nil)}];
            self.faultProbesFinished = YES; [self continueInitialScenario];
        }];
    });
}
- (void)laterProbeInFirstPage:(NSString *)kind {
    DemoManagedPage *page = self.pages.firstObject;
    // WebKit evaluateJavaScript 不能桥接 Promise；异步真实结果仍由原 Bridge 回传。
    NSString *script = [NSString stringWithFormat:@"void window.runLaterProbe('%@')", kind];
    [page.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (error) [self record:@"later-probe-failed" fields:@{@"kind":kind, @"reason":@(error.code)}];
    }];
}
- (void)control:(NSDictionary *)value completion:(void (^)(void))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.serverBase stringByAppendingString:@"/control"]]];
    request.HTTPMethod = @"POST"; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    NSURLSessionDataTask *task = [self.testSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self record:@"test-source-control" fields:@{@"value":value, @"failed":@(error != nil)}]; if (!error && completion) completion(); });
    }]; [task resume];
}
- (void)selectB {
    self.requestedB = YES;
    [self control:@{@"version":@"B", @"disabled":@NO} completion:nil];
    self.status.text = self.longCadence ? @"测试源已改为 B。等待 SDK 自然 300 秒请求；启动页已释放。" : @"测试源已改为 B。等待 SDK 自身静默周期。";
}
- (void)selectDisabled { [self control:@{@"disabled":@YES} completion:nil]; self.status.text = @"测试源已关闭。等待 SDK 观察关闭，再验证旧页资源显式线上回源。"; }
- (void)finishScenario:(NSString *)name {
    self.report[@"finished"] = @YES; self.report[@"scenario"] = name;
    self.status.text = @"场景已执行。结果保存在 Documents/managed-result-本次标识.json；实际字段决定通过或失败。";
    [self record:@"scenario-finished" fields:@{@"scenario":name}];
}
- (void)record:(NSString *)name fields:(NSDictionary *)fields {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self record:name fields:fields]; }); return; }
    NSMutableDictionary *event = [fields mutableCopy]; event[@"event"] = name; event[@"uptime"] = @(NSProcessInfo.processInfo.systemUptime);
    [self.events addObject:event];
    NSDictionary *snapshot = @{ @"runID":self.report[@"runID"], @"systemVersion":self.report[@"systemVersion"], @"bundleID":self.report[@"bundleID"],
        @"defaultCadence":self.report[@"defaultCadence"], @"navigationCount":@(self.navigationCount), @"finished":self.report[@"finished"],
        @"scenario":self.report[@"scenario"] ?: @"running", @"events":[self.events copy], @"pages":[self.report[@"pages"] copy] };
    NSString *runID = self.runID;
    dispatch_async(self.reportQueue, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:nil];
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        [data writeToURL:[documents URLByAppendingPathComponent:[NSString stringWithFormat:@"managed-result-%@.json", runID]] atomically:YES];
    });
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error { [self record:@"web-navigation-failed" fields:@{@"reason":@(error.code), @"domain":error.domain}]; }
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error { [self record:@"web-provisional-failed" fields:@{@"reason":@(error.code), @"domain":error.domain}]; }
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(DemoDelegate.class)); } }
