#import "DemoStartupPreparationViewController.h"
#import <math.h>

NSString *const DemoStartupPreparingMessage = @"正在准备启动配置…";
NSString *const DemoStartupDownloadingMessage = @"正在下载资源包…";
NSString *const DemoStartupExtractingMessage = @"正在解压资源包…";
NSString *const DemoStartupFinishingMessage = @"正在完成初始化…";
NSString *const DemoStartupCompleteMessage = @"启动配置准备完成";
NSString *const DemoStartupNoNetworkMessage = @"网络未连接，请连接网络后重试。";
NSString *const DemoStartupFailedMessage = @"启动配置准备失败，请稍后重试。";
NSString *const DemoStartupRetryTitle = @"重试";

@interface DemoStartupProgressView : UIView
@property (nonatomic) CAGradientLayer *fill;
@property (nonatomic) CAGradientLayer *scan;
@property (nonatomic) CGFloat fraction;
@property (nonatomic) BOOL indeterminate;
@property (nonatomic) BOOL running;
- (void)start;
- (void)stop;
@end
@implementation DemoStartupProgressView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:237/255.0 green:240/255.0 blue:243/255.0 alpha:1];
        self.layer.cornerRadius = 1.5; self.clipsToBounds = YES;
        _fill = [CAGradientLayer layer];
        _fill.colors = @[(id)[UIColor colorWithRed:1 green:106/255.0 blue:66/255.0 alpha:1].CGColor,
                         (id)[UIColor colorWithRed:1 green:69/255.0 blue:40/255.0 alpha:1].CGColor];
        _fill.startPoint = CGPointMake(0, 0.5); _fill.endPoint = CGPointMake(1, 0.5);
        _fill.anchorPoint = CGPointZero; _fill.cornerRadius = 1.5; _fill.masksToBounds = YES;
        [self.layer addSublayer:_fill];
        _scan = [CAGradientLayer layer];
        _scan.colors = @[(id)[UIColor colorWithWhite:1 alpha:0].CGColor,
                         (id)[UIColor colorWithWhite:1 alpha:136/255.0].CGColor,
                         (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
        _scan.locations = @[@0, @0.5, @1];
        _scan.startPoint = CGPointMake(0, 0.5); _scan.endPoint = CGPointMake(1, 0.5);
        [self.layer addSublayer:_scan];
        for (NSString *name in @[UIApplicationDidBecomeActiveNotification, UIApplicationDidEnterBackgroundNotification,
                                 UIAccessibilityReduceMotionStatusDidChangeNotification]) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(animationEnvironmentChanged:) name:name object:nil];
        }
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateLayersAnimated:NO];
}
- (BOOL)canAnimate {
    return self.running && self.window && !self.hidden && !UIAccessibilityIsReduceMotionEnabled() &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}
- (void)updateLayersAnimated:(BOOL)animated {
    CGFloat width = self.bounds.size.width;
    CGFloat target = width * (self.indeterminate ? 1 : self.fraction);
    CGFloat current = self.fill.presentationLayer ? self.fill.presentationLayer.bounds.size.width : self.fill.bounds.size.width;
    BOOL resize = self.scan.bounds.size.width != width * 0.24;
    if (resize || ![self canAnimate]) {
        [self.scan removeAllAnimations]; [self.fill removeAllAnimations];
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.fill.position = CGPointZero;
    self.fill.bounds = CGRectMake(0, 0, target, self.bounds.size.height);
    // Match Android: full orange track, with a 24%-wide white highlight sweeping across it.
    self.scan.frame = CGRectMake(-width * 0.24, 0, width * 0.24, self.bounds.size.height);
    self.scan.hidden = !self.indeterminate || ![self canAnimate];
    [CATransaction commit];
    if (animated && !resize && !self.indeterminate && [self canAnimate] && current != target) {
        CABasicAnimation *growth = [CABasicAnimation animationWithKeyPath:@"bounds.size.width"];
        growth.fromValue = @(current); growth.toValue = @(target);
        growth.duration = 0.08;
        growth.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [self.fill addAnimation:growth forKey:@"progress"];
    }
    if (self.indeterminate && [self canAnimate] && width > 0 && ![self.scan animationForKey:@"scan"]) {
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        animation.fromValue = @0; animation.toValue = @(width * 1.24);
        animation.duration = 1.2; animation.repeatCount = HUGE_VALF;
        animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [self.scan addAnimation:animation forKey:@"scan"];
    }
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateLayersAnimated:NO];
}
- (void)setIndeterminate:(BOOL)value {
    if (_indeterminate == value) return;
    _indeterminate = value;
    [self.fill removeAllAnimations]; [self.scan removeAllAnimations];
    [self updateLayersAnimated:NO];
}
- (void)setFraction:(CGFloat)value {
    CGFloat next = MAX(0, MIN(1, value));
    if (_fraction == next) return;
    BOOL forward = next > _fraction;
    _fraction = next;
    // A new stage can reset the fraction; reset directly rather than animating backwards.
    [self updateLayersAnimated:forward];
    if (!forward) [self.fill removeAnimationForKey:@"progress"];
}
- (void)start { self.running = YES; [self updateLayersAnimated:NO]; }
- (void)stop { self.running = NO; [self updateLayersAnimated:NO]; }
- (void)animationEnvironmentChanged:(NSNotification *)notification { [self updateLayersAnimated:NO]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

@interface DemoStartupPreparationViewController ()
@property UILabel *messageLabel;
@property UILabel *percentLabel;
@property DemoStartupProgressView *progressView;
@property UIStackView *progressStack;
@property UIStackView *failureStack;
@property UILabel *failureLabel;
@property UIButton *retryButton;
@end
@implementation DemoStartupPreparationViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.messageLabel = [UILabel new]; self.messageLabel.numberOfLines = 0;
    self.messageLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12]];
    self.messageLabel.adjustsFontForContentSizeCategory = YES;
    self.messageLabel.textColor = [UIColor colorWithRed:115/255.0 green:119/255.0 blue:128/255.0 alpha:1];
    self.percentLabel = [UILabel new];
    self.percentLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium]];
    self.percentLabel.adjustsFontForContentSizeCategory = YES;
    self.percentLabel.textAlignment = NSTextAlignmentRight;
    self.percentLabel.textColor = [UIColor colorWithWhite:0.2 alpha:1];
    [self.percentLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.percentLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[self.messageLabel, self.percentLabel]];
    labels.axis = UILayoutConstraintAxisHorizontal; labels.spacing = 12; labels.alignment = UIStackViewAlignmentBottom;
    self.progressView = [DemoStartupProgressView new];
    [self.progressView.heightAnchor constraintEqualToConstant:3].active = YES;
    self.failureLabel = [UILabel new]; self.failureLabel.numberOfLines = 0;
    self.failureLabel.font = self.messageLabel.font;
    self.failureLabel.adjustsFontForContentSizeCategory = YES;
    self.failureLabel.textColor = self.messageLabel.textColor;
    self.failureLabel.textAlignment = NSTextAlignmentCenter;
    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:DemoStartupRetryTitle forState:UIControlStateNormal];
    [self.retryButton setTitleColor:[UIColor colorWithRed:1 green:69/255.0 blue:40/255.0 alpha:1] forState:UIControlStateNormal];
    self.retryButton.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14]];
    self.retryButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.retryButton.accessibilityIdentifier = @"startup.retry";
    [self.retryButton addTarget:self action:@selector(retryConfiguration) forControlEvents:UIControlEventTouchUpInside];
    [self.retryButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [self.retryButton.widthAnchor constraintGreaterThanOrEqualToConstant:96].active = YES;
    self.progressStack = [[UIStackView alloc] initWithArrangedSubviews:@[labels, self.progressView]];
    self.progressStack.axis = UILayoutConstraintAxisVertical; self.progressStack.spacing = 7;
    self.progressStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.progressStack];
    [NSLayoutConstraint activateConstraints:@[[self.progressStack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:28],
        [self.progressStack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-28],
        [self.progressStack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-52]]];
    self.failureStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.failureLabel, self.retryButton]];
    self.failureStack.axis = UILayoutConstraintAxisVertical; self.failureStack.alignment = UIStackViewAlignmentCenter;
    self.failureStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.failureStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.failureStack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:28],
        [self.failureStack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-28],
        [self.failureLabel.widthAnchor constraintEqualToAnchor:self.failureStack.widthAnchor],
        [self.failureStack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16]]];
    self.progressStack.hidden = YES;
    self.failureStack.hidden = YES;
}
- (void)showMessage:(NSString *)message fraction:(NSNumber *)fraction {
    NSAssert(NSThread.isMainThread, @"启动 UI 必须在主线程更新");
    [self loadViewIfNeeded]; self.progressStack.hidden = NO; self.failureStack.hidden = YES; self.retryButton.enabled = NO;
    BOOL changed = ![self.messageLabel.text isEqualToString:message];
    self.messageLabel.text = message;
    // Truncate actual progress, as on Android; do not round 99.9% up to completion.
    self.percentLabel.text = fraction ? [NSString stringWithFormat:@"%ld%%", (long)floor(MAX(0, MIN(1, fraction.doubleValue)) * 100)] : @"";
    self.progressView.indeterminate = fraction == nil; self.progressView.fraction = fraction.doubleValue;
    [self.progressView start];
    if (changed && UIAccessibilityIsVoiceOverRunning()) UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
}
- (void)showFailure:(NSString *)message {
    NSAssert(NSThread.isMainThread, @"启动 UI 必须在主线程更新");
    [self loadViewIfNeeded]; [self.progressView stop]; self.progressStack.hidden = YES;
    self.failureLabel.text = message; self.failureStack.hidden = NO;
    self.retryButton.enabled = self.retryStartup != nil;
    if (UIAccessibilityIsVoiceOverRunning()) UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
}
- (void)hideProgress {
    [self loadViewIfNeeded]; [self.progressView stop]; self.progressStack.hidden = YES;
    self.failureStack.hidden = YES; self.retryButton.enabled = NO;
}
- (void)retryConfiguration {
    if (!self.retryButton.enabled || !self.retryStartup) return;
    [self showMessage:DemoStartupPreparingMessage fraction:nil];
    self.retryStartup();
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self.progressView stop]; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.progressStack.hidden) [self.progressView start];
}
@end
