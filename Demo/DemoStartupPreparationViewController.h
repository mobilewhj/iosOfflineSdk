#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// Shared startup copy, aligned with Android strings_offline.xml and Harmony StartupMessages.
FOUNDATION_EXPORT NSString *const DemoStartupPreparingMessage;
FOUNDATION_EXPORT NSString *const DemoStartupDownloadingMessage;
FOUNDATION_EXPORT NSString *const DemoStartupExtractingMessage;
FOUNDATION_EXPORT NSString *const DemoStartupFinishingMessage;
FOUNDATION_EXPORT NSString *const DemoStartupCompleteMessage;
FOUNDATION_EXPORT NSString *const DemoStartupNoNetworkMessage;
FOUNDATION_EXPORT NSString *const DemoStartupFailedMessage;
FOUNDATION_EXPORT NSString *const DemoStartupRetryTitle;

/// Demo-only startup presentation. Not part of the SDK framework.
/// The startup coordinator owns work; this controller only renders snapshots.
@interface DemoStartupPreparationViewController : UIViewController
- (void)showMessage:(NSString *)message fraction:(nullable NSNumber *)fraction;
- (void)showFailure:(NSString *)message;
- (void)hideProgress;
/// Retry the failed startup work (configuration or resources); the host owns that work.
/// The button is disabled and preparation is rendered before invoking the callback.
@property (nonatomic, copy, nullable) void (^retryStartup)(void);
@end
NS_ASSUME_NONNULL_END
