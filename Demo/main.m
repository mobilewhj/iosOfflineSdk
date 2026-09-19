#import <UIKit/UIKit.h>
#import <OfflineTool/OfflineTool.h>
#import "PackageDigest.h"
#import "DemoStartupPreparationViewController.h"

@interface DemoDelegate : UIResponder <UIApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic) UIWindow *window;
@property (nonatomic) UILabel *status;
@property (nonatomic) UIButton *button;
@property (nonatomic) UIButton *previewButton;
@property (nonatomic) DemoStartupPreparationViewController *preparation;
@property (nonatomic) NSUInteger previewGeneration;
@property (nonatomic) BOOL busy;
@property (nonatomic) WKWebView *webView;
@property (nonatomic) OFTPackageInstaller *installer;
@end
@implementation DemoDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.preparation = [DemoStartupPreparationViewController new];
    UIViewController *controller = self.preparation;
    self.window.rootViewController = controller; [self.window makeKeyAndVisible];
    self.status = [UILabel new]; self.status.numberOfLines = 0;
    self.status.text = @"离线包 SDK 示例\n安装内置包可验证本地网页与原生数据注入；包很小，安装很快。点击预览可完整查看启动文本和动画。";
    self.status.textColor = UIColor.blackColor;
    self.status.font = [UIFont systemFontOfSize:15]; self.status.translatesAutoresizingMaskIntoConstraints = NO;
    self.button = [UIButton buttonWithType:UIButtonTypeSystem]; self.button.translatesAutoresizingMaskIntoConstraints = NO;
    [self.button setTitle:@"安装内置测试包" forState:UIControlStateNormal];
    [self.button addTarget:self action:@selector(install) forControlEvents:UIControlEventTouchUpInside];
    self.previewButton = [UIButton buttonWithType:UIButtonTypeSystem]; self.previewButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.previewButton setTitle:@"预览启动效果" forState:UIControlStateNormal];
    [self.previewButton addTarget:self action:@selector(previewAnimation) forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:self.status]; [controller.view addSubview:self.button]; [controller.view addSubview:self.previewButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.status.topAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.topAnchor constant:16],
        [self.status.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor constant:20],
        [self.status.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor constant:-20],
        [self.button.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:12],
        [self.button.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [self.button.heightAnchor constraintEqualToConstant:48],
        [self.previewButton.topAnchor constraintEqualToAnchor:self.button.bottomAnchor],
        [self.previewButton.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [self.previewButton.heightAnchor constraintEqualToConstant:48]]];
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSUInteger preview = [arguments indexOfObject:@"--preview-startup"];
    if (preview != NSNotFound && preview + 1 < arguments.count) [self preview:arguments[preview + 1]];
    else if ([arguments containsObject:@"--smoke-test"]) [self install];
    return YES;
}
- (void)removePage {
    self.webView.navigationDelegate = nil;
    [self.webView stopLoading];
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"demoReady"];
    [self.webView removeFromSuperview]; self.webView = nil;
}
- (void)setInstalling:(BOOL)installing {
    self.busy = installing; self.button.enabled = !installing; self.previewButton.enabled = !installing;
}
- (void)install {
    if (self.busy) return;
    self.previewGeneration += 1; [self removePage]; [self setInstalling:YES];
    self.status.text = @"正在安装内置测试包（本地复制，不请求外网）。进度来自 SDK 实际回调。";
    __weak typeof(self) weakSelf = self;
    self.preparation.retryStartup = ^{ [weakSelf install]; };
    [self.preparation showMessage:DemoStartupPreparingMessage fraction:nil];
    NSURL *root = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"offline/packages"];
    if (!self.installer) self.installer = [[OFTPackageInstaller alloc] initWithRootDirectory:root];
    [self.installer clearOldVersionsKeeping:nil completion:^(NSError *error) {
        if (error) { [self failed:error]; return; }
        OFTPackageRecord *record = [[OFTPackageRecord alloc] initWithVersion:10000 sha256:OFT_DEMO_SHA256];
        [self.installer installRecord:record localArchive:[NSBundle.mainBundle URLForResource:@"demo" withExtension:@"zip"] progress:^(NSString *stage, int64_t done, int64_t total) {
            // Local copying has no byte progress; do not invent a download percentage.
            // A host using fromURL: maps "download" to DemoStartupDownloadingMessage.
            // Android retains the current UI during digest verification.
            if ([stage isEqualToString:@"verify"]) return;
            NSString *message = @{@"prepare":DemoStartupPreparingMessage, @"download":DemoStartupPreparingMessage,
                @"extract":DemoStartupExtractingMessage, @"publish":DemoStartupFinishingMessage}[stage] ?: DemoStartupPreparingMessage;
            NSNumber *fraction = [stage isEqualToString:@"extract"] && total > 0 ? @(MIN(0.99, (double)done / total)) : nil;
            [self.preparation showMessage:message fraction:fraction];
        } completion:^(OFTPackageRecord *installed, NSURL *directory, NSError *failure) {
            if (failure) { [self failed:failure]; return; }
            [self openDirectory:directory];
        }];
    }];
}
- (void)openDirectory:(NSURL *)directory {
    NSURL *base = [NSURL URLWithString:@"https://demo.example/app/"];
    OFTOfflineSchemeHandler *handler = [[OFTOfflineSchemeHandler alloc] initWithDirectory:directory baseURL:base scheme:@"offline-demo"];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    [configuration setURLSchemeHandler:handler forURLScheme:handler.scheme];
    [configuration.userContentController addScriptMessageHandler:self name:@"demoReady"];
    // This is a host concern and contains only synthetic data. Never inject secrets into arbitrary pages.
    NSString *script = @"if(location.protocol==='offline-demo:' && location.host==='demo.example' && location.pathname.startsWith('/app/')){Object.defineProperty(window,'__OFFLINE_DEMO_BOOTSTRAP__',{value:{displayName:'Demo User'},writable:false});}";
    [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration]; self.webView.navigationDelegate = self;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *view = self.window.rootViewController.view; [view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[[self.webView.topAnchor constraintEqualToAnchor:self.previewButton.bottomAnchor constant:12],
        [self.webView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor], [self.webView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor constant:-140]]];
    NSURL *entry = [handler offlineURLForURL:[NSURL URLWithString:@"https://demo.example/app/index.html?demo=1#ready"]];
    [self.webView loadRequest:[NSURLRequest requestWithURL:entry]];
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if (message.webView != self.webView || !message.frameInfo.mainFrame || ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *report = message.body;
    BOOL passed = [report[@"ready"] boolValue] && [report[@"injected"] boolValue];
    [self setInstalling:NO];
    self.status.text = passed ? @"验证通过：离线安装、本地网页加载、原生数据注入、本地 JSON 读取。" : @"网页验证失败，详见 smoke-result.json。";
    if (passed) [self.preparation showMessage:DemoStartupCompleteMessage fraction:@1];
    else [self.preparation showFailure:DemoStartupFailedMessage];
    [self saveReport:report];
}
- (void)failed:(NSError *)error {
    self.status.text = error.localizedDescription; [self setInstalling:NO];
    NSError *cause = error; BOOL offline = NO;
    while (cause) {
        if ([cause.domain isEqualToString:NSURLErrorDomain] && cause.code == NSURLErrorNotConnectedToInternet) { offline = YES; break; }
        cause = cause.userInfo[NSUnderlyingErrorKey];
    }
    [self.preparation showFailure:offline ? DemoStartupNoNetworkMessage : DemoStartupFailedMessage];
    [self saveReport:@{@"ready":@NO, @"error":error.localizedDescription ?: @"Unknown failure"}];
}
- (void)previewAnimation { [self preview:@"animation"]; }
- (void)preview:(NSString *)state {
    if (self.busy) return;
    [self removePage];
    NSUInteger generation = ++self.previewGeneration;
    self.status.text = @"启动效果预览\n演示准备、下载、解压、初始化、完成及失败重试。百分比仅用于预览，不下载或安装资源。";
    __weak typeof(self) weakSelf = self;
    self.preparation.retryStartup = ^{ [weakSelf previewAnimation]; };
    if ([state isEqualToString:@"animation"]) {
        [self.preparation showMessage:DemoStartupPreparingMessage fraction:nil];
        NSArray<NSArray *> *frames = @[
            @[@2.4, DemoStartupDownloadingMessage, @0.15],
            @[@3.2, DemoStartupDownloadingMessage, @0.37],
            @[@4.0, DemoStartupDownloadingMessage, @0.65],
            @[@4.8, DemoStartupDownloadingMessage, @0.90],
            @[@5.6, DemoStartupDownloadingMessage, @1],
            @[@6.4, DemoStartupExtractingMessage, @0],
            @[@7.2, DemoStartupExtractingMessage, @0.45],
            @[@8.0, DemoStartupExtractingMessage, @0.99],
            @[@8.8, DemoStartupFinishingMessage, NSNull.null],
            @[@11.2, DemoStartupCompleteMessage, @1]];
        for (NSArray *frame in frames) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([frame[0] doubleValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!weakSelf || weakSelf.previewGeneration != generation) return;
                [weakSelf.preparation showMessage:frame[1] fraction:frame[2] == NSNull.null ? nil : frame[2]];
            });
        }
        // Keep completion visible, then demonstrate the recoverable failure state.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 14 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!weakSelf || weakSelf.previewGeneration != generation) return;
            [weakSelf.preparation showFailure:DemoStartupFailedMessage];
        });
    } else if ([state isEqualToString:@"failed"] || [state isEqualToString:@"no-network"]) {
        [self.preparation showFailure:[state isEqualToString:@"no-network"] ? DemoStartupNoNetworkMessage : DemoStartupFailedMessage];
    } else {
        NSString *message = @{@"download":DemoStartupDownloadingMessage, @"extract":DemoStartupExtractingMessage,
            @"finishing":DemoStartupFinishingMessage, @"complete":DemoStartupCompleteMessage}[state] ?: DemoStartupPreparingMessage;
        NSNumber *fraction = @{@"download":@0.65, @"extract":@0.37, @"complete":@1}[state];
        [self.preparation showMessage:message fraction:fraction];
    }
}
- (void)saveReport:(NSDictionary *)report {
    NSURL *root = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[root URLByAppendingPathComponent:@"smoke-result.json"] atomically:YES];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error { if (webView == self.webView) [self failed:error]; }
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error { if (webView == self.webView) [self failed:error]; }
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(DemoDelegate.class)); } }
