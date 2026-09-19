#import "OFTPackageInstaller.h"
NS_ASSUME_NONNULL_BEGIN
NSError *OFTError(OFTOfflineErrorCode code, NSString *stage, NSString *message, NSError * _Nullable cause);
BOOL OFTRegularNonemptyFile(NSURL *url);
@interface OFTDownload : NSObject <NSURLSessionDownloadDelegate>
- (BOOL)downloadURL:(NSURL *)url destination:(NSURL *)destination cancellation:(NSProgress *)cancellation
          progress:(nullable OFTInstallProgress)progress error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
