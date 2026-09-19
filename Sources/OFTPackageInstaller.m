#import "OFTOfflineInternal.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <OfflineTool/OfflineTool-Swift.h>

NSErrorDomain const OFTOfflineErrorDomain = @"com.offline.tool";
NSString * const OFTOfflineErrorStageKey = @"stage";
NSString * const OFTOfflineHTTPStatusKey = @"httpStatus";

NSError *OFTError(OFTOfflineErrorCode code, NSString *stage, NSString *message, NSError *cause) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey:message, OFTOfflineErrorStageKey:stage} mutableCopy];
    if (cause) info[NSUnderlyingErrorKey] = cause;
    return [NSError errorWithDomain:OFTOfflineErrorDomain code:code userInfo:info];
}
BOOL OFTRegularNonemptyFile(NSURL *url) {
    struct stat info;
    return lstat(url.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0;
}

@implementation OFTPackageRecord
- (instancetype)initWithVersion:(NSInteger)version sha256:(NSString *)sha256 {
    if (version < 10000 || ![sha256 isKindOfClass:NSString.class] || sha256.length != 64 ||
        [sha256 rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) return nil;
    if ((self = [super init])) { _version = version; _sha256 = [sha256 copy]; }
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@interface OFTPackageInstaller ()
@property NSURL *requestedRoot;
@property dispatch_queue_t queue;
@end

@implementation OFTPackageInstaller
- (instancetype)initWithRootDirectory:(NSURL *)root {
    if ((self = [super init])) {
        _requestedRoot = [root copy];
        _queue = dispatch_queue_create("com.offline.tool.install", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (NSURL *)prepareRoot:(NSError **)error {
    NSURL *input = self.requestedRoot;
    if (!input.isFileURL || input.path.length <= 1) {
        *error = OFTError(OFTOfflineInvalidInput, @"prepare", @"安装根目录无效", nil); return nil;
    }
    // Resolve system parent aliases (/var -> /private/var), but never root itself.
    NSURL *root = [[input.URLByDeletingLastPathComponent URLByResolvingSymlinksInPath]
                  URLByAppendingPathComponent:input.lastPathComponent isDirectory:YES];
    struct stat info;
    if (lstat(root.fileSystemRepresentation, &info) == 0 && !S_ISDIR(info.st_mode)) {
        *error = OFTError(OFTOfflineFileIO, @"prepare", @"安装根目录不是普通目录", nil); return nil;
    }
    NSError *io;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&io] ||
        ![root setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&io]) {
        *error = OFTError(OFTOfflineFileIO, @"prepare", @"安装目录创建失败", io); return nil;
    }
    return root;
}
- (NSProgress *)installRecord:(OFTPackageRecord *)record fromURL:(NSURL *)url progress:(OFTInstallProgress)progress completion:(OFTInstallCompletion)completion {
    return [self install:record source:url remote:YES progress:progress completion:completion];
}
- (NSProgress *)installRecord:(OFTPackageRecord *)record localArchive:(NSURL *)archive progress:(OFTInstallProgress)progress completion:(OFTInstallCompletion)completion {
    return [self install:record source:archive remote:NO progress:progress completion:completion];
}
- (NSProgress *)install:(OFTPackageRecord *)record source:(NSURL *)source remote:(BOOL)remote
               progress:(OFTInstallProgress)progress completion:(OFTInstallCompletion)completion {
    NSProgress *cancellation = [NSProgress progressWithTotalUnitCount:1];
    OFTInstallProgress report = ^(NSString *stage, int64_t done, int64_t total) {
        if (!progress || cancellation.cancelled) return;
        dispatch_async(dispatch_get_main_queue(), ^{ if (!cancellation.cancelled) progress(stage, done, total); });
    };
    dispatch_async(self.queue, ^{
        NSError *error;
        NSURL *directory = [self performInstall:record source:source remote:remote cancellation:cancellation report:report error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(directory ? record : nil, directory, error); });
    });
    return cancellation;
}
- (NSURL *)performInstall:(OFTPackageRecord *)record source:(NSURL *)source remote:(BOOL)remote
             cancellation:(NSProgress *)cancellation report:(OFTInstallProgress)report error:(NSError **)error {
    NSString *stage = @"prepare";
    if (![record isKindOfClass:OFTPackageRecord.class] ||
        ![[OFTPackageRecord alloc] initWithVersion:record.version sha256:record.sha256] || !source ||
        (remote && (![@[@"http", @"https"] containsObject:source.scheme.lowercaseString] || !source.host.length || source.user || source.password || source.fragment)) ||
        (!remote && !source.isFileURL)) {
        *error = OFTError(OFTOfflineInvalidInput, stage, @"资源包参数无效", nil); return nil;
    }
    if (cancellation.cancelled) { *error = OFTError(OFTOfflineCancelled, stage, @"资源安装已取消", nil); return nil; }
    report(stage, 0, -1);
    NSURL *root = [self prepareRoot:error];
    if (!root) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *published = [root URLByAppendingPathComponent:[@(record.version) stringValue] isDirectory:YES];
    struct stat info;
    if (lstat(published.fileSystemRepresentation, &info) == 0) {
        *error = OFTError(OFTOfflineVersionExists, @"publish", @"版本目录已存在，不允许覆盖", nil); return nil;
    }
    NSURL *staging = [root URLByAppendingPathComponent:[@".staging-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL *archive = [staging URLByAppendingPathComponent:@"package.zip"];
    NSURL *content = [staging URLByAppendingPathComponent:@"content" isDirectory:YES];
    NSError *failure;
    BOOL publishedOK = NO;
    do {
        if (![fm createDirectoryAtURL:content withIntermediateDirectories:YES attributes:nil error:&failure]) break;
        stage = @"download"; report(stage, 0, -1);
        if (remote) {
            if (![[OFTDownload new] downloadURL:source destination:archive cancellation:cancellation progress:report error:&failure]) break;
        } else if (![self copyArchive:source to:archive cancellation:cancellation error:&failure]) break;
        stage = @"verify"; report(stage, 0, -1);
        NSString *digest = [self digest:archive cancellation:cancellation error:&failure];
        if (!digest) break;
        if (![digest isEqualToString:record.sha256]) { failure = OFTError(OFTOfflineDigestMismatch, stage, @"资源包 SHA-256 校验失败", nil); break; }
        stage = @"extract"; report(stage, 0, -1);
        if (![OFTArchiveReader extractArchive:archive toDirectory:content cancellation:cancellation progress:^(int64_t done, int64_t total) {
            report(@"extract", done, total);
        } error:&failure]) {
            if (![failure.domain isEqualToString:OFTOfflineErrorDomain])
                failure = OFTError([failure.domain isEqualToString:NSCocoaErrorDomain] ? OFTOfflineFileIO : OFTOfflineInvalidArchive,
                                   stage, @"资源包解压失败", failure);
            break;
        }
        NSURL *entry = [content URLByAppendingPathComponent:@"index.html"];
        if (!OFTRegularNonemptyFile(entry)) {
            content = [content URLByAppendingPathComponent:@"dist" isDirectory:YES];
            if (!OFTRegularNonemptyFile([content URLByAppendingPathComponent:@"index.html"])) {
                failure = OFTError(OFTOfflineInvalidArchive, stage, @"资源包缺少非空 index.html", nil); break;
            }
        }
        stage = @"publish";
        if (cancellation.cancelled) break;
        report(stage, 0, -1);
        if (![content setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&failure]) break;
        // Move within the same root publishes a complete immutable version; never replace.
        if (![fm moveItemAtURL:content toURL:published error:&failure]) break;
        publishedOK = YES;
    } while (NO);
    NSError *cleanup;
    if (![fm removeItemAtURL:staging error:&cleanup] && !failure) failure = OFTError(OFTOfflineFileIO, @"cleanup", @"安装临时文件清理失败", cleanup);
    // A cancelled/failed publication is an unbound residual, never a successful install.
    if (cancellation.cancelled) failure = OFTError(OFTOfflineCancelled, stage, @"资源安装已取消", failure);
    if (failure || !publishedOK) {
        if (publishedOK) [fm removeItemAtURL:published error:nil];
        *error = [failure.domain isEqualToString:OFTOfflineErrorDomain] ? failure :
                 OFTError(OFTOfflineFileIO, stage, @"资源包安装失败", failure);
        return nil;
    }
    return published;
}
- (BOOL)copyArchive:(NSURL *)source to:(NSURL *)destination cancellation:(NSProgress *)cancel error:(NSError **)error {
    NSInputStream *input = [NSInputStream inputStreamWithURL:source];
    NSOutputStream *output = [NSOutputStream outputStreamWithURL:destination append:NO];
    [input open]; [output open];
    uint8_t buffer[65536]; NSInteger count; int64_t total = 0; BOOL ok = YES;
    while ((count = [input read:buffer maxLength:sizeof(buffer)]) > 0) {
        total += count;
        if (cancel.cancelled || total > 64LL * 1024 * 1024) {
            *error = OFTError(cancel.cancelled ? OFTOfflineCancelled : OFTOfflineTooLarge, @"download", @"资源包取消或超过 64 MiB", nil); ok = NO; break;
        }
        NSInteger offset = 0;
        while (offset < count) {
            NSInteger wrote = [output write:buffer + offset maxLength:count - offset];
            if (wrote <= 0) { ok = NO; break; }
            offset += wrote;
        }
        if (!ok) break;
    }
    if (count < 0 || !ok) {
        if (!*error) *error = OFTError(OFTOfflineFileIO, @"download", @"资源文件复制失败", input.streamError ?: output.streamError);
        ok = NO;
    }
    [input close]; [output close]; return ok;
}
- (NSString *)digest:(NSURL *)url cancellation:(NSProgress *)cancel error:(NSError **)error {
    NSInputStream *input = [NSInputStream inputStreamWithURL:url]; [input open];
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    uint8_t buffer[65536]; NSInteger count = 0;
    while (!cancel.cancelled && (count = [input read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    NSError *readError = input.streamError; [input close];
    if (cancel.cancelled || count < 0) { *error = OFTError(cancel.cancelled ? OFTOfflineCancelled : OFTOfflineFileIO, @"verify", @"摘要读取失败或取消", readError); return nil; }
    uint8_t bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(bytes, &context);
    NSMutableString *digest = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [digest appendFormat:@"%02x", bytes[i]];
    return digest;
}
- (void)clearOldVersionsKeeping:(NSNumber *)activeVersion completion:(void (^)(NSError *))completion {
    dispatch_async(self.queue, ^{
        NSError *error; NSURL *root = [self prepareRoot:&error];
        NSURL *active = [root URLByAppendingPathComponent:activeVersion.stringValue ?: @"" isDirectory:YES];
        struct stat info;
        if (root && activeVersion && (activeVersion.integerValue < 10000 || lstat(active.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) ||
            !OFTRegularNonemptyFile([active URLByAppendingPathComponent:@"index.html"]))) {
            error = OFTError(OFTOfflineInvalidInput, @"cleanup", @"当前版本不可用，拒绝清理", nil);
        }
        if (root && !error) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSArray<NSURL *> *children = [fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:&error];
            for (NSURL *child in children) {
                NSString *name = child.lastPathComponent;
                BOOL numeric = name.length && [name rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
                if ((numeric && ![name isEqualToString:activeVersion.stringValue]) || [name hasPrefix:@".staging-"]) {
                    if (![fm removeItemAtURL:child error:&error]) break;
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}
- (void)discardUnboundVersion:(NSInteger)version completion:(void (^)(NSError *))completion {
    dispatch_async(self.queue, ^{
        NSError *error;
        if (version < 10000) error = OFTError(OFTOfflineInvalidInput, @"cleanup", @"版本号无效", nil);
        NSURL *root = error ? nil : [self prepareRoot:&error];
        NSURL *directory = [root URLByAppendingPathComponent:[@(version) stringValue]];
        struct stat info;
        if (root && lstat(directory.fileSystemRepresentation, &info) == 0)
            [[NSFileManager defaultManager] removeItemAtURL:directory error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}
@end
