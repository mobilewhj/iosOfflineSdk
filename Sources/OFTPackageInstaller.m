#import "OFTOfflineInternal.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <OfflineTool/OfflineTool-Swift.h>

NSErrorDomain const OFTOfflineErrorDomain = @"com.offline.tool";
NSString * const OFTOfflineErrorStageKey = @"stage";
NSString * const OFTOfflineHTTPStatusKey = @"httpStatus";
NSString * const OFTOfflineCleanupErrorsKey = @"cleanupErrors";
NSString * const OFTOfflinePublishedRecordKey = @"publishedRecord";
NSString * const OFTOfflinePublishedDirectoryKey = @"publishedDirectory";
NSString * const OFTOfflinePublishedDirectoryRemainsKey = @"publishedDirectoryRemains";
NSString * const OFTOfflinePublishedDirectoryStateUnknownKey = @"publishedDirectoryStateUnknown";
NSString * const OFTOfflineRequestStartedKey = @"requestStarted";
NSString * const OFTOfflineNetworkRetryKey = @"networkRetry";
NSString * const OFTOfflineRetryAfterKey = @"retryAfter";

NSError *OFTError(OFTOfflineErrorCode code, NSString *stage, NSString *message, NSError *cause) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey:message, OFTOfflineErrorStageKey:stage} mutableCopy];
    if (cause) info[NSUnderlyingErrorKey] = cause;
    return [NSError errorWithDomain:OFTOfflineErrorDomain code:code userInfo:info];
}
BOOL OFTRegularNonemptyFile(NSURL *url) {
    struct stat info;
    if (lstat(url.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0) return NO;
    // 文件属性不代表可用入口；实际打开并读首字节，同时拒绝换成链接或特殊文件。
    int descriptor = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) return NO;
    struct stat opened;
    BOOL regular = fstat(descriptor, &opened) == 0 && S_ISREG(opened.st_mode) && opened.st_size > 0 &&
                   opened.st_dev == info.st_dev && opened.st_ino == info.st_ino;
    uint8_t byte; ssize_t count = -1;
    if (regular) do { count = read(descriptor, &byte, 1); } while (count < 0 && errno == EINTR);
    close(descriptor);
    return regular && count == 1;
}

@interface OFTManagedRootClaim : NSObject
@property NSString *installerIdentity;
@property BOOL everBound;
@property NSUInteger writes;
@property NSUInteger destructiveWrites;
@end
@implementation OFTManagedRootClaim
@end

static NSMutableDictionary<NSString *, OFTManagedRootClaim *> *OFTRootClaims(void) {
    static NSMutableDictionary *claims; static dispatch_once_t once;
    dispatch_once(&once, ^{ claims = [NSMutableDictionary new]; }); return claims;
}
static NSURL *OFTCanonicalRoot(NSURL *input) {
    if (!input.isFileURL || input.path.length <= 1) return nil;
    input = input.URLByStandardizingPath;
    return [[input.URLByDeletingLastPathComponent URLByResolvingSymlinksInPath]
            URLByAppendingPathComponent:input.lastPathComponent isDirectory:YES];
}

@implementation OFTPackageRecord
- (instancetype)initWithVersion:(NSInteger)version sha256:(NSString *)sha256 {
    if (version < 10000 || ![sha256 isKindOfClass:NSString.class] || sha256.length != 64 ||
        [sha256 rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location != NSNotFound) return nil;
    if ((self = [super init])) { _version = version; _sha256 = [sha256.lowercaseString copy]; }
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@interface OFTPackageInstaller ()
@property NSURL *requestedRoot;
@property dispatch_queue_t queue;
@property NSString *installerIdentity;
@property NSString *canonicalRootIdentity;
@end

@implementation OFTPackageInstaller
- (instancetype)initWithRootDirectory:(NSURL *)root {
    if ((self = [super init])) {
        _requestedRoot = [root copy];
        // 认领身份只解析一次；页面在 Main 提交时只读此字符串，不访问文件系统。
        _canonicalRootIdentity = OFTCanonicalRoot(root).path;
        _queue = dispatch_queue_create("com.offline.tool.install", DISPATCH_QUEUE_SERIAL);
        _installerIdentity = NSUUID.UUID.UUIDString;
    }
    return self;
}
- (BOOL)claimManagedRootWithOwner:(id)owner error:(NSError **)error {
    NSString *path = self.canonicalRootIdentity;
    if (!path || !owner) { if (error) *error = OFTError(OFTOfflineInvalidInput, @"prepare", @"托管根目录无效", nil); return NO; }
    @synchronized (OFTRootClaims()) {
        OFTManagedRootClaim *claim = OFTRootClaims()[path];
        if (claim.installerIdentity || claim.writes) {
            if (error) *error = OFTError(OFTOfflineInvalidInput, @"prepare", @"托管根目录已被认领或正在修改", nil);
            return NO;
        }
        if (!claim) claim = [OFTManagedRootClaim new];
        claim.installerIdentity = self.installerIdentity; OFTRootClaims()[path] = claim;
        return YES;
    }
}
- (BOOL)markManagedRootPageBound {
    NSString *path = self.canonicalRootIdentity;
    if (!path) return NO;
    @synchronized (OFTRootClaims()) {
        OFTManagedRootClaim *claim = OFTRootClaims()[path];
        if (![claim.installerIdentity isEqualToString:self.installerIdentity] || claim.destructiveWrites) return NO;
        claim.everBound = YES; return YES;
    }
}
- (BOOL)canModifyExistingVersions {
    NSString *path = self.canonicalRootIdentity;
    if (!path) return NO;
    @synchronized (OFTRootClaims()) {
        OFTManagedRootClaim *claim = OFTRootClaims()[path];
        return !claim || ((!claim.installerIdentity || [claim.installerIdentity isEqualToString:self.installerIdentity]) &&
                         !claim.everBound && !claim.destructiveWrites);
    }
}
- (BOOL)beginRootWrite:(BOOL)destructive error:(NSError **)error {
    NSString *path = self.canonicalRootIdentity;
    if (!path) { *error = OFTError(OFTOfflineInvalidInput, @"prepare", @"安装根目录无效", nil); return NO; }
    @synchronized (OFTRootClaims()) {
        OFTManagedRootClaim *claim = OFTRootClaims()[path];
        if (!claim) { claim = [OFTManagedRootClaim new]; OFTRootClaims()[path] = claim; }
        if ((claim.installerIdentity && ![claim.installerIdentity isEqualToString:self.installerIdentity]) ||
            (destructive && claim.everBound)) {
            *error = OFTError(OFTOfflineInvalidInput, destructive ? @"cleanup" : @"prepare", @"托管目录修改权或页面保护拒绝此操作", nil);
            return NO;
        }
        claim.writes++; if (destructive) claim.destructiveWrites++;
        return YES;
    }
}
- (void)endRootWrite:(BOOL)destructive {
    NSString *path = self.canonicalRootIdentity;
    @synchronized (OFTRootClaims()) {
        OFTManagedRootClaim *claim = OFTRootClaims()[path];
        if (claim.writes) claim.writes--; if (destructive && claim.destructiveWrites) claim.destructiveWrites--;
        if (!claim.installerIdentity && !claim.writes) [OFTRootClaims() removeObjectForKey:path];
    }
}
- (BOOL)removeItemAtURL:(NSURL *)url error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtURL:url error:error];
}
- (NSURL *)prepareRoot:(NSError **)error {
    NSURL *input = self.requestedRoot;
    if (!input.isFileURL || input.path.length <= 1) {
        if (error) *error = OFTError(OFTOfflineInvalidInput, @"prepare", @"安装根目录无效", nil); return nil;
    }
    // 规范父目录别名（如 /var），安装根本身仍拒绝符号链接。
    NSURL *root = OFTCanonicalRoot(input);
    if (![root.path isEqualToString:self.canonicalRootIdentity]) {
        if (error) *error = OFTError(OFTOfflineFileIO, @"prepare", @"安装根目录身份已变化，拒绝写入", nil); return nil;
    }
    struct stat info;
    if (lstat(root.fileSystemRepresentation, &info) == 0 && !S_ISDIR(info.st_mode)) {
        if (error) *error = OFTError(OFTOfflineFileIO, @"prepare", @"安装根目录不是普通目录", nil); return nil;
    }
    NSError *io;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&io] ||
        ![root setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&io]) {
        if (error) *error = OFTError(OFTOfflineFileIO, @"prepare", @"安装目录创建失败", io); return nil;
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
        NSURL *directory;
        if ([self beginRootWrite:NO error:&error]) {
            directory = [self performInstall:record source:source remote:remote cancellation:cancellation report:report error:&error];
            [self endRootWrite:NO];
        }
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
    BOOL requestStarted = NO;
    do {
        if (![fm createDirectoryAtURL:content withIntermediateDirectories:YES attributes:nil error:&failure]) break;
        stage = @"download"; report(stage, 0, -1);
        if (remote) {
            requestStarted = YES;
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
        // 同根移动只发布完整的新目录，不覆盖任何已有版本。
        if (![fm moveItemAtURL:content toURL:published error:&failure]) break;
        publishedOK = YES;
    } while (NO);
    NSMutableArray<NSError *> *cleanupErrors = [NSMutableArray new];
    NSError *cleanup;
    if (![self removeItemAtURL:staging error:&cleanup]) {
        if (cleanup) [cleanupErrors addObject:cleanup];
        if (!failure) failure = OFTError(OFTOfflineFileIO, @"cleanup", @"安装临时文件清理失败", cleanup);
    }
    // 主错误、取消与清理事实分别保存；发布残留绝不自动升级为 active。
    if (cancellation.cancelled) failure = OFTError(OFTOfflineCancelled, stage, @"资源安装已取消", failure);
    if (failure || !publishedOK) {
        if (publishedOK) {
            NSError *removeError;
            if ([self beginRootWrite:YES error:&removeError]) {
                if (![self removeItemAtURL:published error:&removeError] && removeError) [cleanupErrors addObject:removeError];
                [self endRootWrite:YES];
            } else if (removeError) [cleanupErrors addObject:removeError];
        }
        NSError *primary = [failure.domain isEqualToString:OFTOfflineErrorDomain] ? failure :
                           OFTError(OFTOfflineFileIO, stage, @"资源包安装失败", failure);
        NSMutableDictionary *facts = [primary.userInfo mutableCopy];
        facts[OFTOfflineRequestStartedKey] = @(requestStarted);
        if (cleanupErrors.count) facts[OFTOfflineCleanupErrorsKey] = cleanupErrors.copy;
        if (publishedOK) {
            facts[OFTOfflinePublishedRecordKey] = record; facts[OFTOfflinePublishedDirectoryKey] = published;
            if (lstat(published.fileSystemRepresentation, &info) == 0) facts[OFTOfflinePublishedDirectoryRemainsKey] = @YES;
            else if (errno == ENOENT) facts[OFTOfflinePublishedDirectoryRemainsKey] = @NO;
            else facts[OFTOfflinePublishedDirectoryStateUnknownKey] = @YES;
        }
        *error = [NSError errorWithDomain:primary.domain code:primary.code userInfo:facts];
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
        NSError *error;
        BOOL authorized = [self beginRootWrite:YES error:&error];
        NSURL *root = authorized ? [self prepareRoot:&error] : nil;
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
                    if (![self removeItemAtURL:child error:&error]) break;
                }
            }
        }
        if (authorized) [self endRootWrite:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}
- (void)discardUnboundVersion:(NSInteger)version completion:(void (^)(NSError *))completion {
    dispatch_async(self.queue, ^{
        NSError *error;
        if (version < 10000) error = OFTError(OFTOfflineInvalidInput, @"cleanup", @"版本号无效", nil);
        BOOL authorized = !error && [self beginRootWrite:YES error:&error];
        NSURL *root = authorized ? [self prepareRoot:&error] : nil;
        NSURL *directory = [root URLByAppendingPathComponent:[@(version) stringValue]];
        struct stat info;
        if (root && lstat(directory.fileSystemRepresentation, &info) == 0)
            [self removeItemAtURL:directory error:&error];
        if (authorized) [self endRootWrite:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}
// Managed lifecycle files use stable N.zip/N paths. Only the process active directory is protected.
- (NSURL *)prepareManagedRecord:(OFTPackageRecord *)record source:(NSURL *)source
                 configuration:(NSURLSessionConfiguration *)configuration cancellation:(NSProgress *)cancel
               protectedVersion:(NSInteger)protectedVersion onStarted:(dispatch_block_t)onStarted
                      stageWrite:(BOOL (^)(NSString *, NSError **))stageWrite
                       progress:(OFTInstallProgress)progress error:(NSError **)error {
    if (record.version == protectedVersion) { *error = OFTError(OFTOfflineInvalidInput,@"prepare",@"Cannot replace process active package",nil); return nil; }
    NSURL *root = [self prepareRoot:error]; if (!root) return nil;
    NSURL *zip = [root URLByAppendingPathComponent:[NSString stringWithFormat:@"%ld.zip",(long)record.version]];
    NSURL *directory = [root URLByAppendingPathComponent:@(record.version).stringValue isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager; struct stat info;
    NSString *existingHash = nil;
    if (lstat(zip.fileSystemRepresentation,&info) == 0) {
        if (!S_ISREG(info.st_mode)) { *error = OFTError(OFTOfflineFileIO,@"prepare",@"ZIP preflight failed",nil); return nil; }
        existingHash = [self digest:zip cancellation:cancel error:error];
        if (!existingHash) return nil;
    } else if (errno != ENOENT) { *error = OFTError(OFTOfflineFileIO,@"prepare",@"ZIP preflight failed",nil); return nil; }
    if (cancel.cancelled) { *error = OFTError(OFTOfflineCancelled,@"prepare",@"Cancelled",nil); return nil; }
    if ([existingHash isEqual:record.sha256]) {
        onStarted(); // Verified ZIP processing, without an invented HTTP download.
    } else {
        if (!stageWrite(@"downloading",error)) return nil;
        if (existingHash && ![self removeItemAtURL:zip error:error]) { *error = OFTError(OFTOfflineFileIO,@"prepare",@"Cannot replace ZIP",*error); return nil; }
        BOOL downloaded = NO;
        if (source.isFileURL) downloaded = [self copyManagedArchive:source to:zip cancellation:cancel onStarted:onStarted progress:progress error:error];
        else downloaded = [[OFTDownload new] downloadURL:source destination:zip configuration:configuration cancellation:cancel onStarted:onStarted progress:progress error:error];
        if (!downloaded) { [self removeItemAtURL:zip error:nil]; return nil; }
        progress(@"verify",0,-1);
        NSString *hash = [self digest:zip cancellation:cancel error:error];
        if (!hash || ![hash isEqual:record.sha256]) {
            if (hash) *error = OFTError(OFTOfflineDigestMismatch,@"verify",@"ZIP SHA mismatch",nil);
            [self removeItemAtURL:zip error:nil]; return nil;
        }
    }
    if (!stageWrite(@"downloaded",error)) return nil;
    progress(@"extract",0,-1);
    if (lstat(directory.fileSystemRepresentation,&info) == 0 && ![self removeItemAtURL:directory error:error]) {
        *error = OFTError(OFTOfflineFileIO,@"extract",@"Cannot remove incomplete directory",*error); return nil;
    }
    if (cancel.cancelled) { *error = OFTError(OFTOfflineCancelled,@"extract",@"Cancelled",nil); return nil; }
    if (![fm createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:error]) {
        *error = OFTError(OFTOfflineFileIO,@"extract",@"Cannot create package directory",*error); return nil;
    }
    NSError *failure = nil;
    BOOL extracted = [OFTArchiveReader extractManagedArchive:zip toDirectory:directory cancellation:cancel progress:^(int64_t done,int64_t total){ progress(@"extract",done,total); } error:&failure];
    if (cancel.cancelled) failure = OFTError(OFTOfflineCancelled,@"extract",@"Cancelled",nil);
    else if (!extracted && ![failure.domain isEqual:OFTOfflineErrorDomain]) failure = OFTError([failure.domain isEqual:NSCocoaErrorDomain] ? OFTOfflineFileIO : OFTOfflineInvalidArchive,@"extract",@"Archive extraction failed",failure);
    else if (extracted && !OFTRegularNonemptyFile([directory URLByAppendingPathComponent:@"index.html"])) failure = OFTError(OFTOfflineInvalidArchive,@"extract",@"Package entry unavailable",nil);
    if (failure || !extracted) { [self removeItemAtURL:directory error:nil]; *error = failure ?: OFTError(OFTOfflineInvalidArchive,@"extract",@"Archive extraction failed",nil); return nil; }
    [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return directory;
}
- (int)closeManagedZIPOutput:(int)descriptor { return close(descriptor); }
- (BOOL)copyManagedArchive:(NSURL *)source to:(NSURL *)destination cancellation:(NSProgress *)cancel
                onStarted:(dispatch_block_t)onStarted progress:(OFTInstallProgress)progress error:(NSError **)error {
    int output = open(destination.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0600);
    if (output < 0) { *error = OFTError(OFTOfflineFileIO,@"download",@"Cannot open ZIP output",nil); return NO; }
    if (cancel.cancelled) { [self closeManagedZIPOutput:output]; *error = OFTError(OFTOfflineCancelled,@"download",@"Cancelled",nil); return NO; }
    onStarted();
    int input = open(source.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);
    struct stat stat = {0}; BOOL ok = input >= 0 && fstat(input,&stat) == 0 && S_ISREG(stat.st_mode);
    uint8_t buffer[65536]; __block int64_t total = 0; ssize_t count = 0;
    __block int64_t reportedBytes = -1; __block NSInteger reportedPercent = -1;
    void (^report)(BOOL) = ^(BOOL tail) {
        int64_t length = ok && stat.st_size > 0 ? stat.st_size : -1;
        NSInteger percent = length > 0 ? (NSInteger)MIN(100,((long double)total*100)/length) : -1;
        BOOL changed = percent >= 0 ? percent != reportedPercent : reportedBytes < 0 || total/(256*1024) != reportedBytes/(256*1024);
        if (changed || (tail && total != reportedBytes)) { progress(@"download",total,length); reportedBytes=total; reportedPercent=percent; }
    };
    report(NO);
    while (ok && !cancel.cancelled) {
        count = read(input,buffer,sizeof(buffer)); if (count < 0 && errno == EINTR) continue;
        if (count < 0) { ok = NO; break; } if (count == 0) break;
        ssize_t offset = 0;
        while (offset < count) { ssize_t wrote = write(output,buffer+offset,(size_t)(count-offset)); if (wrote < 0 && errno == EINTR) continue; if (wrote <= 0) { ok = NO; break; } offset += wrote; }
        total += count; report(NO);
    }
    if (ok) report(YES);
    if (ok && fsync(output)) ok = NO;
    if (input >= 0) close(input);
    if ([self closeManagedZIPOutput:output] != 0) ok = NO;
    if (cancel.cancelled || !ok || !total) { *error = OFTError(cancel.cancelled ? OFTOfflineCancelled : OFTOfflineFileIO,@"download",@"Local ZIP read/write failed",nil); return NO; }
    return YES;
}
- (void)deleteManagedVersion:(NSInteger)version protectedVersion:(NSInteger)protectedVersion {
    if (version == protectedVersion) return;
    NSURL *root = [self prepareRoot:nil]; if (!root) return;
    [self removeItemAtURL:[root URLByAppendingPathComponent:@(version).stringValue] error:nil];
    [self deleteManagedZIP:version];
}
- (void)deleteManagedZIP:(NSInteger)version {
    NSURL *root = [self prepareRoot:nil]; if (root) [self removeItemAtURL:[root URLByAppendingPathComponent:[NSString stringWithFormat:@"%ld.zip",(long)version]] error:nil];
}
- (void)cleanupManagedKeeping:(NSSet<NSString *> *)kept cancellation:(NSProgress *)cancellation {
    NSURL *root = [self prepareRoot:nil]; if (!root) return;
    NSArray *children = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL *child in children) { if (cancellation.cancelled) return; if (![kept containsObject:child.lastPathComponent]) [self removeItemAtURL:child error:nil]; }
}
@end
