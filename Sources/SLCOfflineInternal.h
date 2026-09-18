#import "SLCPackageInstaller.h"
NS_ASSUME_NONNULL_BEGIN
NSError *SLCError(SLCOfflineErrorCode code, NSString *stage, NSString *message, NSError * _Nullable cause);
BOOL SLCRegularNonemptyFile(NSURL *url);
@interface SLCDownload : NSObject <NSURLSessionDownloadDelegate>
- (BOOL)downloadURL:(NSURL *)url destination:(NSURL *)destination cancellation:(NSProgress *)cancellation
          progress:(nullable SLCInstallProgress)progress error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
