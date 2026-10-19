#import "OFTManagedOfflineSDK.h"
#import "OFTOfflineSchemeHandler.h"
#import "OFTOfflineResourceResolver.h"
#import "OFTOfflineInternal.h"
#import <sys/stat.h>

static void OFTOnMain(dispatch_block_t block) { if (NSThread.isMainThread) block(); else dispatch_async(dispatch_get_main_queue(),block); }
static BOOL OFTUsableDirectory(NSURL *directory) {
    struct stat root, item;
    return directory && lstat(directory.URLByDeletingLastPathComponent.fileSystemRepresentation,&root) == 0 && S_ISDIR(root.st_mode) &&
        lstat(directory.fileSystemRepresentation,&item) == 0 && S_ISDIR(item.st_mode) && OFTRegularNonemptyFile([directory URLByAppendingPathComponent:@"index.html"]);
}
static OFTPackageRecord *OFTStoredRecord(NSDictionary *row) { return row ? [[OFTPackageRecord alloc] initWithVersion:[row[@"version"] integerValue] sha256:row[@"sha256"]] : nil; }
static BOOL OFTSameRecord(OFTPackageRecord *a, OFTPackageRecord *b) { return a && b && a.version == b.version && [a.sha256 isEqual:b.sha256]; }
static BOOL OFTConflict(OFTPackageRecord *a, OFTPackageRecord *b) { return a && b && a.version == b.version && ![a.sha256 isEqual:b.sha256]; }

@interface OFTStartupClient : NSObject
@property NSProgress *token;
@property (copy) void (^completion)(OFTPreparationResult *);
@property BOOL owner;
@property (copy) void (^progress)(OFTPreparationProgress *);
@end
@implementation OFTStartupClient @end
@interface OFTManagedUpdate : NSObject
@property BOOL first;
@property (atomic) BOOL cancelled;
@property NSProgress *ownerToken;
@property (nonatomic,readonly) BOOL cancellationRequested;
@property BOOL providerConsumed;
@property BOOL requested;
@property BOOL installing;
@property BOOL finishing;
@property (atomic) BOOL processingStarted;
@property NSProgress *providerToken;
@property NSProgress *installerToken;
@property OFTPackageRecord *target;
@property OFTManagedOutcome *outcome;
@property NSMutableArray<OFTStartupClient *> *clients;
@property (copy) void (^progress)(OFTPreparationProgress *);
@property NSString *pendingStage;
@property int64_t pendingDone;
@property int64_t pendingTotal;
@property BOOL progressPending;
@end
@implementation OFTManagedUpdate
- (BOOL)cancellationRequested { return self.cancelled || self.ownerToken.cancelled; }
@end
@interface OFTPageBinding ()
@property (nonatomic,strong,readwrite) OFTOfflineSchemeHandler *handler;
@property (nonatomic,weak) OFTManagedOfflineSDK *manager;
@property BOOL consumed;
@property BOOL disposed;
@property (nonatomic,weak) NSProgress *loadToken;
- (instancetype)initPrivate;
@end
@implementation OFTPageBinding
- (instancetype)initPrivate { return [super init]; }
- (void)dispose { OFTOnMain(^{ self.disposed = YES; [self.loadToken cancel]; [self.handler dispose]; }); }
- (void)dealloc { [_handler dispose]; }
@end

@interface OFTManagedOfflineSDK ()
@property NSURL *root;
@property NSURL *staticRoot;
@property NSInteger minimumVersion;
@property NSTimeInterval checkInterval;
@property (copy) OFTVersionedConfigurationProvider provider;
@property OFTManagedStorage *storage;
@property OFTPackageInstaller *installer;
@property dispatch_queue_t storageQueue;
@property dispatch_queue_t observationQueue;
@property BOOL privacy;
@property BOOL foreground;
@property BOOL closed;
@property BOOL loaded;
@property BOOL startedEmpty;
@property BOOL initialized;
@property BOOL initializing;
@property NSProgress *initializationToken;
@property NSMutableArray *initializationWaiters;
@property OFTPackageRecord *active;
@property BOOL activeUsable;
@property (atomic) BOOL resourceEnabled;
@property NSInteger startupGate; // 0 undecided, 1 first preparation, 2 released. Memory only.
@property BOOL sawConfiguration;
@property NSInteger onlineVersion;
@property NSString *onlineSHA;
@property OFTPackageRecord *attemptTarget;
@property NSUInteger packageFailures;
@property NSTimeInterval notBefore;
@property BOOL cacheClearRequested;
@property BOOL requestEverStarted;
@property NSTimeInterval lastRequestStart;
@property NSTimeInterval noRequestUntil;
@property dispatch_source_t timer;
@property OFTManagedUpdate *update;
@property NSMutableArray<OFTStartupClient *> *pendingStartupClients;
@end

@implementation OFTManagedOfflineSDK
- (instancetype)initWithRootDirectory:(NSURL *)root originalStaticRoot:(NSURL *)staticRoot configurationProvider:(OFTConfigurationProvider)provider error:(NSError **)error {
    return [self initWithRootDirectory:root originalStaticRoot:staticRoot minimumVersion:10000 checkInterval:300 storage:nil configurationProvider:provider error:error];
}
- (instancetype)initWithRootDirectory:(NSURL *)root originalStaticRoot:(NSURL *)staticRoot minimumVersion:(NSInteger)minimumVersion checkInterval:(NSTimeInterval)interval storage:(OFTManagedStorage *)storage configurationProvider:(OFTConfigurationProvider)provider error:(NSError **)error {
    OFTVersionedConfigurationProvider adapter = provider ? ^NSProgress *(NSInteger version,OFTConfigurationCompletion completion) { return provider(completion); } : nil;
    return [self initWithRootDirectory:root originalStaticRoot:staticRoot minimumVersion:minimumVersion checkInterval:interval storage:storage versionedConfigurationProvider:adapter error:error];
}
- (instancetype)initWithRootDirectory:(NSURL *)root originalStaticRoot:(NSURL *)staticRoot minimumVersion:(NSInteger)minimumVersion checkInterval:(NSTimeInterval)interval storage:(OFTManagedStorage *)storage versionedConfigurationProvider:(OFTVersionedConfigurationProvider)provider error:(NSError **)error {
    if (!root.isFileURL || root.path.length <= 1 || !provider || minimumVersion < 10000 || !isfinite(interval) || interval <= 0 || ![OFTOfflineResourceResolver isValidStaticRoot:staticRoot]) {
        if (error) *error = OFTError(OFTOfflineInvalidInput,@"prepare",@"Invalid managed parameters",nil); return nil;
    }
    if ((self = [super init])) {
        _root = [[root.URLByDeletingLastPathComponent URLByResolvingSymlinksInPath] URLByAppendingPathComponent:root.lastPathComponent isDirectory:YES];
        _staticRoot = staticRoot.copy; _minimumVersion = minimumVersion; _checkInterval = interval; _provider = [provider copy];
        _storage = storage ?: [OFTManagedStorage defaultStorageForInstallationRootDirectory:_root error:error];
        if (!_storage || ![_storage validateInstallationRootDirectory:_root error:error]) return nil;
        _installer = [[OFTPackageInstaller alloc] initWithRootDirectory:_root];
        if (![_installer claimManagedRootWithOwner:self error:error]) return nil;
        _storageQueue = dispatch_queue_create("com.offline.tool.lifecycle.io",DISPATCH_QUEUE_SERIAL);
        _observationQueue = dispatch_queue_create("com.offline.tool.lifecycle.observe",DISPATCH_QUEUE_CONCURRENT);
        _initializationWaiters = [NSMutableArray array]; _pendingStartupClients = [NSMutableArray array]; _resourceEnabled = YES;
    } return self;
}
- (NSTimeInterval)monotonicTime { return NSProcessInfo.processInfo.systemUptime; }
- (NSURL *)directoryForRecord:(OFTPackageRecord *)record { return record ? [self.root URLByAppendingPathComponent:@(record.version).stringValue isDirectory:YES] : nil; }
- (void)diagnoseStage:(NSString *)stage reason:(OFTOfflineErrorCode)reason detail:(NSString *)detail {
    @try { if (self.diagnosticHandler) self.diagnosticHandler(stage,reason,detail); } @catch (__unused NSException *e) { }
}
- (void)ensureInitialized:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread,@"Managed state is Main-only");
    if (self.closed) { completion(NO); return; }
    if (self.initialized) { completion(YES); return; }
    if (self.initializing && self.initializationToken.cancelled) {
        // A fresh explicit entrant must not consume the canceled owner's incomplete cold load as a read failure.
        [self.initializationWaiters addObject:[^(BOOL ignored) { [self ensureInitialized:completion]; } copy]]; return;
    }
    [self.initializationWaiters addObject:[completion copy]]; if (self.initializing) return;
    self.initializing = YES; self.initializationToken = [NSProgress progressWithTotalUnitCount:1];
    NSProgress *token = self.initializationToken;
    dispatch_async(self.storageQueue,^{
        NSError *error = nil; NSArray *rows = [self.storage readRowsWithError:&error];
        OFTOnMain(^{
            if (!rows || token.cancelled || self.closed) { if (!rows) [self diagnoseStage:@"storage" reason:OFTOfflineStorageRead detail:@"local_facts_unreadable"]; [self finishInitialization:NO]; return; }
            if (!self.loaded) { self.loaded = YES; self.startedEmpty = rows.count == 0; }
            dispatch_async(self.storageQueue,^{
                NSDictionary *ready = nil;
                for (NSDictionary *row in rows) if ([row[@"stage"] isEqual:OFTPackageStageReady]) ready = row;
                if (!token.cancelled && ready && OFTUsableDirectory([self directoryForRecord:OFTStoredRecord(ready)]))
                    [self.storage activateVersion:[ready[@"version"] integerValue] error:nil];
                NSArray *current = token.cancelled ? nil : [self.storage readRowsWithError:nil];
                OFTPackageRecord *active = nil; NSMutableSet *kept = [NSMutableSet set];
                for (NSDictionary *row in current) {
                    NSString *stage = row[@"stage"]; NSString *version = [row[@"version"] stringValue];
                    [kept addObject:([stage isEqual:OFTPackageStageDownloading] || [stage isEqual:OFTPackageStageDownloaded]) ? [version stringByAppendingString:@".zip"] : version];
                    if ([stage isEqual:OFTPackageStageActive]) active = OFTStoredRecord(row);
                }
                BOOL usable = active && OFTUsableDirectory([self directoryForRecord:active]);
                // Unknown reads cannot authorize file deletion. Cold cleanup is performed once per process.
                if (current && !token.cancelled) [self.installer cleanupManagedKeeping:kept cancellation:token];
                OFTOnMain(^{
                    BOOL complete = current && !token.cancelled && !self.closed;
                    if (complete) { self.active = active; self.activeUsable = usable && active.version >= self.minimumVersion; self.initialized = YES; }
                    [self finishInitialization:complete];
                });
            });
        });
    });
}
- (void)finishInitialization:(BOOL)complete {
    self.initializing = NO; self.initializationToken = nil;
    NSArray *waiters = self.initializationWaiters.copy; [self.initializationWaiters removeAllObjects];
    for (void (^waiter)(BOOL) in waiters) waiter(complete);
}
- (void)updatePrivacyGranted:(BOOL)privacy foreground:(BOOL)foreground {
    OFTOnMain(^{ if (self.closed) return; self.privacy = privacy; self.foreground = foreground;
        if (!privacy && self.update) [self cancelUpdate:self.update];
        [self scheduleSilent];
    });
}
- (NSProgress *)prepareStartupWithProgress:(void (^)(OFTPreparationProgress *))progress completion:(void (^)(OFTPreparationResult *))completion {
    NSProgress *token = [NSProgress progressWithTotalUnitCount:1]; OFTStartupClient *client = [OFTStartupClient new];
    client.token = token; client.completion = [completion copy]; client.progress = [progress copy];
    __weak typeof(self) weakSelf = self;
    token.cancellationHandler = ^{ OFTOnMain(^{ [weakSelf cancelStartupClient:client]; }); };
    OFTOnMain(^{ [self beginStartupClient:client]; }); return token;
}
- (void)beginStartupClient:(OFTStartupClient *)client {
    if (client.token.cancelled || self.closed) { [self completeClient:client disposition:OFTPreparationCancelled first:NO outcome:nil]; return; }
    if (self.update.first) {
        if (self.update.cancellationRequested) {
            // NSProgress.cancelled is synchronous; its handler may arrive later. A new invocation
            // waits for canceled work/cleanup to drain, then becomes a fresh owner rather than a waiter.
            [self.pendingStartupClients addObject:client]; [self cancelUpdate:self.update]; return;
        }
        [self.update.clients addObject:client]; return;
    }
    if (self.update) { [self completeClient:client disposition:OFTPreparationContinue first:NO outcome:nil]; return; }
    OFTManagedUpdate *update = [OFTManagedUpdate new]; update.first = YES; update.clients = [NSMutableArray arrayWithObject:client];
    update.ownerToken = client.token; update.progress = client.progress; client.owner = YES; self.update = update;
    [self ensureInitialized:^(BOOL complete) {
        if (self.update != update) return;
        if (update.cancellationRequested) { [self cancelUpdate:update]; return; }
        if (self.startupGate == 0) self.startupGate = self.loaded && self.startedEmpty ? 1 : 2;
        if (self.startupGate == 2) { [self finishUpdate:update disposition:OFTPreparationContinue performed:NO]; return; }
        if (!self.privacy || !self.foreground) { [self finishUpdate:update disposition:OFTPreparationDeferred performed:NO]; return; }
        if (!complete) { [self finishNormally:update]; return; }
        [self requestConfiguration:update];
    }];
}
- (void)completeClient:(OFTStartupClient *)client disposition:(OFTPreparationDisposition)value first:(BOOL)first outcome:(OFTManagedOutcome *)outcome {
    if (client.token.cancelled) { value = OFTPreparationCancelled; if (!client.owner) { first = NO; outcome = nil; } }
    client.token.cancellationHandler = nil; void (^completion)(OFTPreparationResult *) = client.completion; client.completion = nil; client.progress = nil;
    @try { if (completion) completion([[OFTPreparationResult alloc] initWithDisposition:value first:first outcome:outcome]); } @catch (__unused NSException *e) { }
}
- (void)cancelStartupClient:(OFTStartupClient *)client {
    if ([self.pendingStartupClients containsObject:client]) { [self.pendingStartupClients removeObject:client]; [self completeClient:client disposition:OFTPreparationCancelled first:NO outcome:nil]; return; }
    OFTManagedUpdate *update = self.update; if (![update.clients containsObject:client]) return;
    if (client.owner) [self cancelUpdate:update]; else { [update.clients removeObject:client]; [self completeClient:client disposition:OFTPreparationCancelled first:NO outcome:nil]; }
}
- (void)cancelUpdate:(OFTManagedUpdate *)update {
    if (self.update != update || update.cancelled) return;
    update.cancelled = YES; [update.providerToken cancel];
    if (update.finishing) return; // Only the short ready commit/event/optional activation section is non-cancellable.
    [update.installerToken cancel];
    if (self.initializing && update.first) [self.initializationToken cancel];
    if (update.installing) return;
    [self finishUpdate:update disposition:OFTPreparationCancelled performed:update.first];
}
- (BOOL)mayContinue:(OFTManagedUpdate *)update firstCheckpoint:(BOOL)checkpoint {
    if (self.update != update) return NO;
    if (update.cancellationRequested || self.closed || !self.privacy || (checkpoint && update.first && !self.foreground)) { [self cancelUpdate:update]; return NO; }
    return YES;
}
- (void)requestConfiguration:(OFTManagedUpdate *)update {
    if (![self mayContinue:update firstCheckpoint:YES]) return;
    [self report:update stage:@"checking" completed:0 total:-1];
    if (![self mayContinue:update firstCheckpoint:YES]) return;
    OFTPackageRecord *observed = self.active;
    dispatch_async(self.observationQueue,^{
        BOOL usable = observed && observed.version >= self.minimumVersion && OFTUsableDirectory([self directoryForRecord:observed]);
        OFTOnMain(^{
            if (![self mayContinue:update firstCheckpoint:YES]) return;
            self.activeUsable = usable;
            update.requested = YES; self.requestEverStarted = YES; self.lastRequestStart = [self monotonicTime]; self.noRequestUntil = 0;
            @try {
                NSProgress *providerToken = self.provider(usable ? observed.version : 0, ^(OFTManagedConfiguration *configuration,NSError *error) {
                    dispatch_async(dispatch_get_main_queue(),^{
                        if (self.update != update || update.providerConsumed) return;
                        if (![self mayContinue:update firstCheckpoint:NO]) return;
                        update.providerConsumed = YES; update.providerToken = nil;
                        if (error || ![configuration isKindOfClass:OFTManagedConfiguration.class]) { [self diagnoseStage:@"configuration" reason:OFTOfflineInvalidInput detail:@"configuration_unavailable"]; [self finishNormally:update]; return; }
                        [self inspectConfiguration:configuration update:update];
                    });
                });
                if (self.update == update && !update.cancellationRequested && !self.closed && self.privacy) update.providerToken = providerToken; else [providerToken cancel];
            } @catch (__unused NSException *e) { [self diagnoseStage:@"configuration" reason:OFTOfflineInvalidInput detail:@"configuration_unavailable"]; [self finishNormally:update]; }
        });
    });
}
- (void)inspectConfiguration:(OFTManagedConfiguration *)configuration update:(OFTManagedUpdate *)update {
    dispatch_async(self.storageQueue,^{
        NSError *error = nil; NSDictionary *row = configuration.enabled && configuration.packageURL ? [self.storage rowForVersion:configuration.version error:&error] : nil;
        BOOL readyUsable = [row[@"stage"] isEqual:OFTPackageStageReady] && OFTUsableDirectory([self directoryForRecord:OFTStoredRecord(row)]);
        OFTOnMain(^{
            if (![self mayContinue:update firstCheckpoint:NO]) return;
            if (error) { [self diagnoseStage:@"storage" reason:OFTOfflineStorageRead detail:@"candidate_read_failed"]; [self finishNormally:update]; return; }
            OFTPackageRecord *target = configuration.packageURL ? [[OFTPackageRecord alloc] initWithVersion:configuration.version sha256:configuration.sha256] : nil;
            BOOL valid = !configuration.enabled || (configuration.version >= self.minimumVersion &&
                ((!configuration.packageURL && self.activeUsable && self.active.version >= configuration.version) ||
                 (target && target.version >= self.minimumVersion && [self validSource:configuration.packageURL] &&
                  !OFTConflict(self.active,target) && !OFTConflict(OFTStoredRecord(row),target) && !OFTConflict(self.attemptTarget,target) &&
                  (!self.attemptTarget || target.version >= self.attemptTarget.version))));
            if (!valid) { [self diagnoseStage:@"configuration" reason:OFTOfflineInvalidInput detail:@"invalid_configuration"]; [self finishNormally:update]; return; }
            // All identity validation and DB observation precedes policy/cache/attempt mutation.
            self.sawConfiguration = YES; self.resourceEnabled = configuration.enabled;
            self.onlineVersion = configuration.enabled ? configuration.version : 0; self.onlineSHA = configuration.enabled ? target.sha256 : nil;
            if (configuration.enabled && target && !OFTSameRecord(self.attemptTarget,target)) {
                self.attemptTarget = target; self.packageFailures = 0; self.notBefore = 0; self.cacheClearRequested = NO;
            }
            if (!update.first && configuration.enabled && target && self.active && target.version > self.active.version && !self.cacheClearRequested) {
                self.cacheClearRequested = YES;
                @try { if (self.resourceCacheCleaner) self.resourceCacheCleaner(); else [self requestDefaultResourceCacheClear]; }
                @catch (__unused NSException *e) { [self diagnoseStage:@"cache" reason:OFTOfflineFileIO detail:@"cache_request_failed"]; }
            }
            if (![self mayContinue:update firstCheckpoint:YES]) return;
            if (!configuration.enabled) { [self finishNormally:update]; return; }
            if (!target || (self.active && self.active.version >= target.version)) { [self evictStaleThenFinish:update]; return; }
            update.target = target;
            if (readyUsable) {
                if (!self.active) [self activateExistingReady:target update:update]; else [self finishNormally:update];
                return;
            }
            if (self.packageFailures >= 2 || [self monotonicTime] < self.notBefore) { [self finishNormally:update]; return; }
            [self prepareTarget:target URL:configuration.packageURL update:update];
        });
    });
}
- (BOOL)validSource:(NSURL *)URL {
    return URL.isFileURL || ([@[@"http",@"https"] containsObject:URL.scheme.lowercaseString] && URL.host.length && !URL.user && !URL.password && !URL.fragment);
}
- (void)requestDefaultResourceCacheClear {
    [WKWebsiteDataStore.defaultDataStore removeDataOfTypes:[NSSet setWithObjects:WKWebsiteDataTypeMemoryCache,WKWebsiteDataTypeDiskCache,nil] modifiedSince:NSDate.distantPast completionHandler:^{}];
}
- (void)evictStaleThenFinish:(OFTManagedUpdate *)update {
    NSInteger activeVersion = self.active.version;
    dispatch_async(self.storageQueue,^{
        NSArray *removed = activeVersion ? [self.storage evictInactiveKeepingVersion:activeVersion error:nil] : nil;
        for (NSNumber *version in removed) [self.installer deleteManagedVersion:version.integerValue protectedVersion:activeVersion];
        OFTOnMain(^{ if ([self mayContinue:update firstCheckpoint:NO]) [self finishNormally:update]; });
    });
}
- (void)activateExistingReady:(OFTPackageRecord *)target update:(OFTManagedUpdate *)update {
    update.finishing = YES;
    dispatch_async(self.storageQueue,^{
        BOOL activated = [self.storage activateVersion:target.version error:nil];
        BOOL usable = activated && OFTUsableDirectory([self directoryForRecord:target]);
        OFTOnMain(^{ if (activated && !self.active) { self.active = target; self.activeUsable = usable; } update.finishing = NO; [self finishNormally:update]; });
    });
}
- (void)prepareTarget:(OFTPackageRecord *)record URL:(NSURL *)URL update:(OFTManagedUpdate *)update {
    if (![self mayContinue:update firstCheckpoint:YES]) return;
    update.installing = YES; update.installerToken = [NSProgress progressWithTotalUnitCount:1];
    NSProgress *token = update.installerToken; NSInteger protectedVersion = self.active.version;
    NSURLSessionConfiguration *configuration = self.downloadConfiguration.copy;
    [self report:update stage:@"prepare" completed:0 total:-1];
    dispatch_async(self.storageQueue,^{
        NSError *failure = nil; NSURL *directory = nil;
        if (!token.cancelled) {
            NSArray *removed = [self.storage registerTarget:record error:&failure];
            if (!removed) failure = OFTError(OFTOfflineStorageWrite,@"prepare",@"Target registration failed",failure);
            else {
                for (NSNumber *version in removed) [self.installer deleteManagedVersion:version.integerValue protectedVersion:protectedVersion];
                __block NSString *lastStage = nil; __block int64_t lastBytes = -1; __block NSInteger lastPercent = -1;
                directory = [self.installer prepareManagedRecord:record source:URL configuration:configuration cancellation:token protectedVersion:protectedVersion
                    onStarted:^{ update.processingStarted = YES; }
                    stageWrite:^BOOL(NSString *stage,NSError **error) {
                        if (token.cancelled) { *error = OFTError(OFTOfflineCancelled,@"prepare",@"Cancelled",nil); return NO; }
                        NSError *storageError = nil; BOOL saved = [self.storage setStage:stage forVersion:record.version error:&storageError];
                        if (!saved) *error = OFTError(OFTOfflineStorageWrite,@"prepare",@"Lifecycle stage write failed",storageError); return saved;
                    } progress:^(NSString *stage,int64_t done,int64_t total) {
                        NSInteger percent = total > 0 ? (NSInteger)MIN(100,((long double)done*100)/total) : -1;
                        BOOL changed = [stage isEqual:@"download"] || ![stage isEqual:lastStage] || (percent >= 0 ? percent != lastPercent : lastBytes < 0 || done/(256*1024) != lastBytes/(256*1024));
                        if (changed) { lastStage = stage; lastBytes = done; lastPercent = percent; [self enqueueProgress:update stage:stage completed:done total:total]; }
                    } error:&failure];
            }
        }
        OFTOnMain(^{
            update.installing = NO;
            if (self.update != update) return;
            if (update.cancellationRequested || token.cancelled || failure.code == OFTOfflineCancelled) { [self finishUpdate:update disposition:OFTPreparationCancelled performed:update.first]; return; }
            if (!directory || failure) { [self targetFailed:update error:failure ?: OFTError(OFTOfflineFileIO,@"prepare",@"Package preparation failed",nil)]; return; }
            [self commitReady:record update:update];
        });
    });
}
- (void)commitReady:(OFTPackageRecord *)record update:(OFTManagedUpdate *)update {
    if (![self mayContinue:update firstCheckpoint:NO]) return;
    update.finishing = YES; [self report:update stage:@"saving" completed:0 total:-1];
    NSInteger activeVersion = self.active.version;
    dispatch_async(self.storageQueue,^{
        NSError *failure = nil; BOOL saved = [self.storage setStage:OFTPackageStageReady forVersion:record.version error:&failure];
        BOOL activated = NO, usable = NO;
        if (saved) { [self.installer deleteManagedZIP:record.version]; if (!activeVersion) { activated = [self.storage activateVersion:record.version error:nil]; usable = activated && OFTUsableDirectory([self directoryForRecord:record]); } }
        OFTOnMain(^{
            update.finishing = NO; update.installerToken = nil;
            if (!saved) { [self targetFailed:update error:OFTError(OFTOfflineStorageWrite,@"publish",@"Ready write failed",failure)]; return; }
            self.packageFailures = 0; self.notBefore = 0; // Keep target and cache-clear call fact.
            update.outcome = [[OFTManagedOutcome alloc] initWithRecord:record success:YES error:nil activeVersion:activeVersion];
            if (activated && !self.active) { self.active = record; self.activeUsable = usable; }
            [self report:update stage:@"complete" completed:1 total:1];
            [self finishNormally:update];
        });
    });
}
- (void)targetFailed:(OFTManagedUpdate *)update error:(NSError *)error {
    if (update.cancellationRequested || ([error.domain isEqual:OFTOfflineErrorDomain] && error.code == OFTOfflineCancelled)) { [self finishUpdate:update disposition:OFTPreparationCancelled performed:update.first]; return; }
    if ([error.userInfo[OFTOfflineNetworkRetryKey] boolValue]) {
        NSTimeInterval wait = [error.userInfo[OFTOfflineRetryAfterKey] doubleValue]; self.notBefore = wait > 0 ? MIN(DBL_MAX,[self monotonicTime]+wait) : 0;
    } else self.packageFailures = MIN(2,self.packageFailures+1);
    if (update.processingStarted) {
        NSMutableDictionary *facts = error.userInfo.mutableCopy ?: [NSMutableDictionary dictionary]; facts[OFTOfflineRequestStartedKey] = @YES;
        NSError *reported = [NSError errorWithDomain:error.domain code:error.code userInfo:facts];
        update.outcome = [[OFTManagedOutcome alloc] initWithRecord:update.target success:NO error:reported activeVersion:self.active.version];
    }
    else [self diagnoseStage:error.userInfo[OFTOfflineErrorStageKey] ?: @"prepare" reason:([error.domain isEqual:OFTOfflineErrorDomain] ? error.code : OFTOfflineFileIO) detail:@"package_preflight_failed"];
    [self finishNormally:update];
}
- (void)enqueueProgress:(OFTManagedUpdate *)update stage:(NSString *)stage completed:(int64_t)done total:(int64_t)total {
    @synchronized(update) {
        update.pendingStage = stage; update.pendingDone = done; update.pendingTotal = total;
        if (update.progressPending) return; update.progressPending = YES;
    }
    dispatch_async(dispatch_get_main_queue(),^{
        NSString *latest; int64_t completed, count;
        @synchronized(update) { latest = update.pendingStage; completed = update.pendingDone; count = update.pendingTotal; update.progressPending = NO; }
        [self report:update stage:latest completed:completed total:count];
    });
}
- (void)report:(OFTManagedUpdate *)update stage:(NSString *)stage completed:(int64_t)done total:(int64_t)total {
    if (self.update != update || update.cancellationRequested || !update.first || !update.progress) return;
    @try { update.progress([[OFTPreparationProgress alloc] initWithStage:stage completed:done total:total]); } @catch (__unused NSException *e) { }
}
- (void)finishNormally:(OFTManagedUpdate *)update {
    if (self.update != update) return;
    if (update.cancellationRequested) { [self finishUpdate:update disposition:OFTPreparationCancelled performed:update.first]; return; }
    if (update.first) self.startupGate = 2;
    [self finishUpdate:update disposition:OFTPreparationContinue performed:update.first];
}
- (void)finishUpdate:(OFTManagedUpdate *)update disposition:(OFTPreparationDisposition)value performed:(BOOL)performed {
    if (self.update != update) return; self.update = nil;
    NSArray *clients = update.clients.copy; [update.clients removeAllObjects];
    update.providerToken = nil; update.installerToken = nil; update.progress = nil;
    if (!update.first && !update.requested) self.noRequestUntil = [self monotonicTime]+self.checkInterval;
    @try { if (update.outcome && self.outcomeHandler) self.outcomeHandler(update.outcome); } @catch (__unused NSException *e) { }
    for (OFTStartupClient *client in clients) [self completeClient:client disposition:value first:performed outcome:update.outcome];
    NSArray *pending = self.pendingStartupClients.copy; [self.pendingStartupClients removeAllObjects];
    for (OFTStartupClient *client in pending) [self beginStartupClient:client];
    [self scheduleSilent];
}
- (void)checkForUpdates { OFTOnMain(^{ [self scheduleSilent]; }); }
- (void)scheduleSilent {
    if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
    if (self.closed || !self.privacy || !self.foreground || self.update || self.startupGate != 2) return;
    NSTimeInterval now = [self monotonicTime]; NSTimeInterval due = MAX(self.noRequestUntil,self.requestEverStarted ? self.lastRequestStart+self.checkInterval : now);
    if (due <= now) {
        OFTManagedUpdate *update = [OFTManagedUpdate new]; self.update = update;
        [self ensureInitialized:^(BOOL complete) { if (self.update != update) return; if (!complete) { [self finishNormally:update]; return; }
            if (![self mayContinue:update firstCheckpoint:NO]) return;
            // Admission after cold IO precedes Checking; an admitted silent check survives later background.
            if (!self.foreground) { [self finishUpdate:update disposition:OFTPreparationDeferred performed:NO]; return; }
            [self requestConfiguration:update];
        }]; return;
    }
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(self.timer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)((due-now)*NSEC_PER_SEC)),DISPATCH_TIME_FOREVER,50*NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self; dispatch_source_set_event_handler(self.timer,^{ [weakSelf scheduleSilent]; }); dispatch_resume(self.timer);
}
- (OFTPageBinding *)pageBindingForConfiguration:(WKWebViewConfiguration *)configuration scheme:(NSString *)scheme error:(NSError **)error {
    return [self pageBindingForConfiguration:configuration scheme:scheme networkConfiguration:nil error:error];
}
- (OFTPageBinding *)pageBindingForConfiguration:(WKWebViewConfiguration *)configuration scheme:(NSString *)scheme networkConfiguration:(NSURLSessionConfiguration *)networkConfiguration error:(NSError **)error {
    if (!NSThread.isMainThread || self.closed || !configuration || [configuration urlSchemeHandlerForURLScheme:scheme]) { if (error) *error = OFTError(OFTOfflineInvalidInput,@"page",@"Invalid page configuration",nil); return nil; }
    __weak typeof(self) weakSelf = self;
    OFTOfflineSchemeHandler *handler = [OFTOfflineSchemeHandler managedHandlerWithScheme:scheme originalStaticRoot:self.staticRoot enabledProvider:^BOOL{ return weakSelf && weakSelf.resourceEnabled; } networkConfiguration:networkConfiguration error:error];
    if (!handler) return nil; [configuration setURLSchemeHandler:handler forURLScheme:scheme];
    OFTPageBinding *binding = [[OFTPageBinding alloc] initPrivate]; binding.handler = handler; binding.manager = self; return binding;
}
- (NSProgress *)loadPage:(NSURL *)URL inWebView:(WKWebView *)webView binding:(OFTPageBinding *)binding completion:(void (^)(OFTPageLoadResult *,NSError *))completion {
    NSProgress *token = [NSProgress progressWithTotalUnitCount:1];
    OFTOnMain(^{
        if (self.closed || binding.manager != self || binding.consumed || binding.disposed || !webView || !URL || [webView.configuration urlSchemeHandlerForURLScheme:binding.handler.scheme] != binding.handler || ![@[@"http",@"https"] containsObject:URL.scheme.lowercaseString]) {
            @try { if (completion) completion(nil,OFTError(OFTOfflineInvalidInput,@"page",@"Invalid page entry",nil)); } @catch (__unused NSException *e) { } return;
        }
        binding.consumed = YES; binding.loadToken = token;
        [self ensureInitialized:^(BOOL complete) {
            if (token.cancelled || binding.disposed || self.closed) { [self finishPageCancelled:completion]; return; }
            OFTPackageRecord *record = complete ? self.active : nil; NSURL *directory = [self directoryForRecord:record];
            dispatch_async(self.observationQueue,^{
                BOOL usable = record && OFTUsableDirectory(directory);
                if (usable) { OFTOfflineResourceResolver *resolver = [[OFTOfflineResourceResolver alloc] initWithDirectory:directory baseURL:self.staticRoot]; usable = [resolver resourceForRequest:[NSURLRequest requestWithURL:URL]] != nil; }
                OFTOnMain(^{
                    if (token.cancelled || binding.disposed || self.closed) { [self finishPageCancelled:completion]; return; }
                    BOOL qualified = usable && record.version >= self.minimumVersion && self.initialized && self.active == record && self.resourceEnabled &&
                        (!self.sawConfiguration || (self.onlineVersion == record.version && (!self.onlineSHA || [self.onlineSHA isEqual:record.sha256])));
                    NSURL *loadURL = URL; OFTPackageRecord *bound = nil;
                    if (qualified) { NSURL *mapped = [binding.handler offlineURLForOriginalURL:URL]; if (mapped && [self.installer markManagedRootPageBound] && [binding.handler bindDirectory:directory entryFile:@"index.html" error:nil]) { loadURL = mapped; bound = record; } }
                    [webView loadRequest:[NSURLRequest requestWithURL:loadURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60]];
                    @try { if (completion) completion([[OFTPageLoadResult alloc] initWithURL:loadURL record:bound],nil); } @catch (__unused NSException *e) { }
                });
            });
        }];
    }); return token;
}
- (void)finishPageCancelled:(void (^)(OFTPageLoadResult *,NSError *))completion { @try { if (completion) completion(nil,OFTError(OFTOfflineCancelled,@"page",@"Cancelled",nil)); } @catch (__unused NSException *e) { } }
- (void)close { OFTOnMain(^{ if (self.closed) return; self.closed = YES; self.resourceEnabled = NO; [self.initializationToken cancel]; if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; } if (self.update) [self cancelUpdate:self.update]; }); }
- (void)dealloc { if (_timer) dispatch_source_cancel(_timer); }
@end
