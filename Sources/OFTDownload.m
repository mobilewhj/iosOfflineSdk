#import "OFTOfflineInternal.h"
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static const int64_t OFTMaxZIPBytes = 64LL * 1024 * 1024;
@interface OFTDownload ()
@property NSURL *destination;
@property NSURL *originalURL;
@property NSProgress *cancellation;
@property (copy) OFTInstallProgress progress;
@property NSError *failure;
@property dispatch_semaphore_t finished;
@property BOOL abandoned;
@property BOOL managed;
@property int outputDescriptor;
@property int64_t downloadedBytes;
@property int64_t expectedBytes;
@property int64_t reportedBytes;
@property NSInteger reportedPercent;
@end

@implementation OFTDownload
- (int)closeManagedZIPOutput:(int)descriptor { return close(descriptor); }
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
    // 总时限覆盖整个请求和持续慢流，不会被每次新数据重新计时。
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 120;
    NSTimeInterval cancelDeadline = 0;
    BOOL timedOut = NO;
    while (dispatch_semaphore_wait(self.finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10)) != 0) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (cancellation.cancelled) {
            if (!cancelDeadline) cancelDeadline = now + 5;
            if (now >= cancelDeadline) { @synchronized (self) { self.abandoned = YES; } break; }
        } else if (now >= deadline) { timedOut = YES; break; }
    }
    if (timedOut) {
        [task cancel];
        // 取消收尾有界；异常网络栈不能让安装队列永远等最终回调。
        if (dispatch_semaphore_wait(self.finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
            @synchronized (self) { self.abandoned = YES; }
        }
    }
    cancellation.cancellationHandler = nil;
    [session invalidateAndCancel];
    @synchronized (self) {
        if (cancellation.cancelled) self.failure = OFTError(OFTOfflineCancelled, @"download", @"资源下载已取消", nil);
        else if (timedOut) self.failure = OFTError(OFTOfflineTimeout, @"download", @"资源下载超时", nil);
        if (self.failure) {
            NSMutableDictionary *facts = [self.failure.userInfo mutableCopy]; facts[OFTOfflineRequestStartedKey] = @YES;
            self.failure = [NSError errorWithDomain:self.failure.domain code:self.failure.code userInfo:facts];
        }
        self.progress = nil; self.cancellation = nil;
    }
    if (self.failure && error) *error = self.failure;
    return self.failure == nil;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    NSURL *url = request.URL;
    if (self.abandoned) { completionHandler(nil); return; }
    if (![url.scheme.lowercaseString isEqualToString:self.originalURL.scheme.lowercaseString] ||
        !url.host.length || url.user || url.password) {
        self.failure = OFTError(self.managed ? OFTOfflineInvalidInput : OFTOfflineNetwork, @"download", @"资源下载重定向无效", nil);
        completionHandler(nil); [task cancel]; return;
    }
    completionHandler(request);
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
 didWriteData:(int64_t)bytes totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    if (self.abandoned) return;
    if (written > OFTMaxZIPBytes || expected > OFTMaxZIPBytes) {
        self.failure = OFTError(OFTOfflineTooLarge, @"download", @"资源包超过 64 MiB", nil);
        [task cancel]; return;
    }
    if (self.progress) self.progress(@"download", written, expected > 0 ? expected : -1);
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
 didFinishDownloadingToURL:(NSURL *)location {
    @synchronized (self) {
    if (self.abandoned) return;
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
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    @synchronized (self) {
    if (self.abandoned) { dispatch_semaphore_signal(self.finished); return; }
    if (error && !self.failure) {
        NSError *failure = OFTError(error.code == NSURLErrorTimedOut ? OFTOfflineTimeout : OFTOfflineNetwork, @"download", @"资源下载失败", error);
        if (self.managed) { NSMutableDictionary *facts = failure.userInfo.mutableCopy; facts[OFTOfflineNetworkRetryKey] = @YES; failure = [NSError errorWithDomain:failure.domain code:failure.code userInfo:facts]; }
        self.failure = failure;
    }
    if (self.managed && !self.failure && self.downloadedBytes == 0) self.failure = [self managedHTTPFailure:200 response:nil];
    if (self.managed && !self.failure) [self reportManagedProgressTail:YES];
    if (self.managed && self.outputDescriptor >= 0) {
        if (!self.failure && fsync(self.outputDescriptor)) self.failure = OFTError(OFTOfflineFileIO,@"download",@"ZIP sync failed",nil);
        int descriptor = self.outputDescriptor; self.outputDescriptor = -1;
        if ([self closeManagedZIPOutput:descriptor] != 0 && !self.failure)
            self.failure = OFTError(OFTOfflineFileIO,@"download",@"ZIP close failed",nil);
    }
    dispatch_semaphore_signal(self.finished);
    }
}
- (NSError *)managedHTTPFailure:(NSInteger)status response:(NSHTTPURLResponse *)response {
    NSMutableDictionary *facts = [@{OFTOfflineErrorStageKey:@"download", OFTOfflineHTTPStatusKey:@(status),
        OFTOfflineNetworkRetryKey:@([@[@408,@429,@500,@502,@503,@504] containsObject:@(status)])} mutableCopy];
    if (status == 429 || status == 503) {
        NSString *value = [response valueForHTTPHeaderField:@"Retry-After"];
        value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (value.length && [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location == NSNotFound) {
            // Android stores milliseconds in signed Int64; reject overflow instead of rounding huge values.
            uint64_t seconds = 0; const uint64_t maximum = INT64_MAX / 1000; BOOL valid = YES;
            for (NSUInteger i=0;i<value.length;i++) {
                unsigned digit = [value characterAtIndex:i] - '0';
                if (seconds > (maximum - digit) / 10) { valid = NO; break; }
                seconds = seconds * 10 + digit;
            }
            if (valid) facts[OFTOfflineRetryAfterKey] = @(seconds);
        }
    }
    return [NSError errorWithDomain:OFTOfflineErrorDomain code:OFTOfflineNetwork userInfo:facts];
}
- (BOOL)downloadURL:(NSURL *)url destination:(NSURL *)destination configuration:(NSURLSessionConfiguration *)input
       cancellation:(NSProgress *)cancellation onStarted:(dispatch_block_t)onStarted progress:(OFTInstallProgress)progress error:(NSError **)error {
    self.managed = YES; self.outputDescriptor = -1; self.reportedBytes = -1; self.reportedPercent = -1; self.destination = destination; self.originalURL = url;
    self.cancellation = cancellation; self.progress = progress; self.finished = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *configuration = input ? input.copy : NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil; configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSOperationQueue *queue = [NSOperationQueue new]; queue.maxConcurrentOperationCount = 1;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url];
    cancellation.cancellationHandler = ^{ [task cancel]; };
    if (cancellation.cancelled) { [session invalidateAndCancel]; cancellation.cancellationHandler = nil; if (error) *error = OFTError(OFTOfflineCancelled,@"download",@"Cancelled",nil); return NO; }
    onStarted(); // This is a real HTTP attempt even when connection fails before response bytes.
    [task resume];
    NSTimeInterval cancelDeadline = 0;
    while (dispatch_semaphore_wait(self.finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10)) != 0) {
        if (cancellation.cancelled) {
            if (!cancelDeadline) cancelDeadline = NSProcessInfo.processInfo.systemUptime + 5;
            if (NSProcessInfo.processInfo.systemUptime >= cancelDeadline) { @synchronized(self) { self.abandoned = YES; } break; }
        }
    }
    cancellation.cancellationHandler = nil; [session invalidateAndCancel];
    @synchronized(self) {
        if (cancellation.cancelled) self.failure = OFTError(OFTOfflineCancelled,@"download",@"Cancelled",nil);
        if (self.outputDescriptor >= 0) {
            int descriptor = self.outputDescriptor; self.outputDescriptor = -1;
            if ([self closeManagedZIPOutput:descriptor] != 0 && !self.failure)
                self.failure = OFTError(OFTOfflineFileIO,@"download",@"ZIP close failed",nil);
        }
        self.progress = nil; self.cancellation = nil;
        if (self.failure && error) *error = self.failure;
        return self.failure == nil;
    }
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    @synchronized(self) {
        if (self.abandoned || self.cancellation.cancelled || self.failure) { completionHandler(NSURLSessionResponseCancel); return; }
        if (![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode != 200) {
            self.failure = [self managedHTTPFailure:[response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0 response:(id)response];
            completionHandler(NSURLSessionResponseCancel); return;
        }
        self.outputDescriptor = open(self.destination.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0600);
        if (self.outputDescriptor < 0) { self.failure = OFTError(OFTOfflineFileIO,@"download",@"Cannot open ZIP output",nil); completionHandler(NSURLSessionResponseCancel); return; }
        self.expectedBytes = response.expectedContentLength > 0 ? response.expectedContentLength : -1;
        [self reportManagedProgressTail:NO];
        completionHandler(NSURLSessionResponseAllow);
    }
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    @synchronized(self) {
        if (self.abandoned || self.failure || self.cancellation.cancelled) return;
        const uint8_t *bytes = data.bytes; NSUInteger offset = 0;
        while (offset < data.length) {
            ssize_t written = write(self.outputDescriptor,bytes+offset,data.length-offset);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) { self.failure = OFTError(OFTOfflineFileIO,@"download",@"Cannot write ZIP output",nil); [task cancel]; return; }
            offset += (NSUInteger)written;
        }
        self.downloadedBytes += data.length;
        [self reportManagedProgressTail:NO];
    }
}
- (void)reportManagedProgressTail:(BOOL)tail {
    NSInteger percent = self.expectedBytes > 0 ? (NSInteger)MIN(100,((long double)self.downloadedBytes*100)/self.expectedBytes) : -1;
    BOOL changed = percent >= 0 ? percent != self.reportedPercent : self.reportedBytes < 0 || self.downloadedBytes/(256*1024) != self.reportedBytes/(256*1024);
    if (changed || (tail && self.downloadedBytes != self.reportedBytes)) {
        if (self.progress) self.progress(@"download",self.downloadedBytes,self.expectedBytes);
        self.reportedBytes = self.downloadedBytes; self.reportedPercent = percent;
    }
}
@end
