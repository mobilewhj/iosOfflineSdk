#import "OFTManagedTypes.h"
#import "OFTOfflineInternal.h"

@implementation OFTManagedConfiguration
- (instancetype)initWithEnabled:(BOOL)enabled version:(NSInteger)version packageURL:(NSURL *)URL sha256:(NSString *)sha {
    if ((self = [super init])) { _enabled = enabled; _version = version; _packageURL = [URL copy]; _sha256 = [sha copy]; } return self;
}
@end
@implementation OFTPreparationProgress
- (instancetype)initWithStage:(NSString *)stage completed:(int64_t)done total:(int64_t)total {
    if ((self = [super init])) {
        _stage = [stage copy]; _completed = done; _total = total;
        _fraction = [stage isEqual:@"complete"] ? 1 : (total > 0 ? MIN(.99, MAX(0, (double)done / total)) : -1);
    } return self;
}
@end
@implementation OFTManagedOutcome
- (instancetype)initWithRecord:(OFTPackageRecord *)record success:(BOOL)success error:(NSError *)error {
    return [self initWithRecord:record success:success error:error activeVersion:0];
}
- (instancetype)initWithRecord:(OFTPackageRecord *)record success:(BOOL)success error:(NSError *)error activeVersion:(NSInteger)activeVersion {
    if ((self = [super init])) {
        _activeVersion = activeVersion;
        _record = record; _success = success; _stage = success ? @"publish" : (error.userInfo[OFTOfflineErrorStageKey] ?: @"prepare");
        _reason = success ? 0 : ([error.domain isEqual:OFTOfflineErrorDomain] ? error.code : OFTOfflineFileIO);
        _detail = success ? @"prepared" : @[@"unused", @"invalid_input", @"file_io", @"network", @"timeout", @"too_large", @"digest_mismatch", @"invalid_archive", @"version_exists", @"cancelled", @"storage_read", @"storage_write"][MIN(MAX(_reason, 1), 11)];
        _HTTPStatus = error.userInfo[OFTOfflineHTTPStatusKey];
        _requestStarted = success || [error.userInfo[OFTOfflineRequestStartedKey] boolValue];
        _publishedRecord = success ? record : error.userInfo[OFTOfflinePublishedRecordKey];
        _publishedDirectoryRemains = [error.userInfo[OFTOfflinePublishedDirectoryRemainsKey] boolValue];
        _publishedDirectoryStateUnknown = [error.userInfo[OFTOfflinePublishedDirectoryStateUnknownKey] boolValue];
        _cleanupFailureCount = [error.userInfo[OFTOfflineCleanupErrorsKey] count];
    } return self;
}
@end
@implementation OFTPreparationResult
- (instancetype)initWithDisposition:(OFTPreparationDisposition)value first:(BOOL)first outcome:(OFTManagedOutcome *)outcome {
    if ((self = [super init])) { _disposition = value; _performedFirstPreparation = first; _outcome = outcome; } return self;
}
@end
@implementation OFTPageLoadResult
- (instancetype)initWithURL:(NSURL *)URL record:(OFTPackageRecord *)record {
    if ((self = [super init])) { _loadedURL = [URL copy]; _record = record; _offline = record != nil; } return self;
}
@end
