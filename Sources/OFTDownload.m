#import "OFTOfflineInternal.h"

static const int64_t OFTMaxZIPBytes = 64LL * 1024 * 1024;
@interface OFTDownload ()
@property NSURL *destination;
@property NSURL *originalURL;
@property NSProgress *cancellation;
@property (copy) OFTInstallProgress progress;
@property NSError *failure;
@property dispatch_semaphore_t finished;
@end

@implementation OFTDownload
- (BOOL)downloadURL:(NSURL *)url destination:(NSURL *)destination cancellation:(NSProgress *)cancellation
          progress:(OFTInstallProgress)progress error:(NSError **)error {
    self.destination = destination; self.originalURL = url;
    self.cancellation = cancellation; self.progress = progress;
    self.finished = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 120;
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    NSOperationQueue *delegateQueue = [NSOperationQueue new];
    delegateQueue.maxConcurrentOperationCount = 1;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url];
    cancellation.cancellationHandler = ^{ [task cancel]; };
    if (cancellation.cancelled) [task cancel];
    [task resume];
    // An explicit wall-clock limit also covers servers which continuously trickle data.
    BOOL timedOut = dispatch_semaphore_wait(self.finished, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC)) != 0;
    if (timedOut) {
        [task cancel];
        dispatch_semaphore_wait(self.finished, DISPATCH_TIME_FOREVER);
    }
    cancellation.cancellationHandler = nil;
    [session finishTasksAndInvalidate];
    if (cancellation.cancelled) self.failure = OFTError(OFTOfflineCancelled, @"download", @"资源下载已取消", nil);
    else if (timedOut) self.failure = OFTError(OFTOfflineTimeout, @"download", @"资源下载超时", nil);
    if (self.failure && error) *error = self.failure;
    return self.failure == nil;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    NSURL *url = request.URL;
    if (![url.scheme.lowercaseString isEqualToString:self.originalURL.scheme.lowercaseString] ||
        !url.host.length || url.user || url.password) {
        self.failure = OFTError(OFTOfflineNetwork, @"download", @"资源下载重定向无效", nil);
        completionHandler(nil); [task cancel]; return;
    }
    completionHandler(request);
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
 didWriteData:(int64_t)bytes totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    if (written > OFTMaxZIPBytes || expected > OFTMaxZIPBytes) {
        self.failure = OFTError(OFTOfflineTooLarge, @"download", @"资源包超过 64 MiB", nil);
        [task cancel]; return;
    }
    if (self.progress) self.progress(@"download", written, expected > 0 ? expected : -1);
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
 didFinishDownloadingToURL:(NSURL *)location {
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
    if (![response isKindOfClass:NSHTTPURLResponse.class] || response.statusCode != 200) {
        NSMutableDictionary *details = [@{NSLocalizedDescriptionKey:@"资源下载未返回完整文件", OFTOfflineErrorStageKey:@"download"} mutableCopy];
        if ([response isKindOfClass:NSHTTPURLResponse.class]) details[OFTOfflineHTTPStatusKey] = @(response.statusCode);
        self.failure = [NSError errorWithDomain:OFTOfflineErrorDomain code:OFTOfflineNetwork userInfo:details]; return;
    }
    NSNumber *size;
    NSError *ioError;
    if (![location getResourceValue:&size forKey:NSURLFileSizeKey error:&ioError] || size.longLongValue > OFTMaxZIPBytes) {
        self.failure = OFTError(ioError ? OFTOfflineFileIO : OFTOfflineTooLarge, @"download", @"下载文件大小无效", ioError); return;
    }
    if (self.cancellation.cancelled || self.failure) return;
    if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:self.destination error:&ioError])
        self.failure = OFTError(OFTOfflineFileIO, @"download", @"下载文件保存失败", ioError);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error && !self.failure) self.failure = OFTError(error.code == NSURLErrorTimedOut ? OFTOfflineTimeout : OFTOfflineNetwork,
                                                       @"download", @"资源下载失败", error);
    dispatch_semaphore_signal(self.finished);
}
@end
