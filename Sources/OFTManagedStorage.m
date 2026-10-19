#import "OFTManagedStorage.h"
#import <sqlite3.h>
#import <sys/stat.h>

NSErrorDomain const OFTManagedStorageErrorDomain = @"com.offline.tool.storage";
NSString * const OFTPackageStageDownloading = @"downloading";
NSString * const OFTPackageStageDownloaded = @"downloaded";
NSString * const OFTPackageStageReady = @"ready";
NSString * const OFTPackageStageActive = @"active";

static NSError *OFTStorageError(OFTManagedStorageErrorCode code) {
    return [NSError errorWithDomain:OFTManagedStorageErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:@"Offline lifecycle storage operation failed"}];
}
static NSURL *OFTStorageCanonical(NSURL *URL) {
    if (!URL.isFileURL || URL.path.length <= 1) return nil;
    URL = URL.URLByStandardizingPath;
    return [[URL.URLByDeletingLastPathComponent URLByResolvingSymlinksInPath] URLByAppendingPathComponent:URL.lastPathComponent];
}
static BOOL OFTSQL(sqlite3 *db, const char *sql, NSError **error) {
    if (sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK) return YES;
    if (error) *error = OFTStorageError(OFTManagedStorageIOFailure); return NO;
}

@implementation OFTManagedStorage
- (instancetype)initWithDatabaseURL:(NSURL *)URL {
    if ((self = [super init])) _databaseURL = [OFTStorageCanonical(URL) copy]; return self;
}
- (instancetype)initWithDirectory:(NSURL *)directory {
    return [self initWithDatabaseURL:[directory URLByAppendingPathComponent:@"packages.db"]];
}
+ (instancetype)defaultStorageForInstallationRootDirectory:(NSURL *)root error:(NSError **)error {
    NSURL *canonical = OFTStorageCanonical(root);
    if (!canonical) { if (error) *error = OFTStorageError(OFTManagedStorageInvalidDirectory); return nil; }
    return [[self alloc] initWithDatabaseURL:[canonical URLByAppendingPathExtension:@"db"]];
}
- (BOOL)validateInstallationRootDirectory:(NSURL *)root error:(NSError **)error {
    NSURL *canonical = OFTStorageCanonical(root);
    NSString *prefix = [canonical.path stringByAppendingString:@"/"];
    BOOL valid = canonical && self.databaseURL && ![self.databaseURL.path isEqualToString:canonical.path] &&
        ![self.databaseURL.path hasPrefix:prefix];
    if (!valid && error) *error = OFTStorageError(OFTManagedStorageInvalidDirectory);
    return valid;
}
- (BOOL)quarantineCorruptDatabase {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *suffix = [@".corrupt-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSURL *quarantine = [NSURL fileURLWithPath:[self.databaseURL.path stringByAppendingString:suffix]];
    if (![fm moveItemAtURL:self.databaseURL toURL:quarantine error:nil]) return NO;
    NSMutableArray *moved = [NSMutableArray array];
    for (NSString *sidecar in @[@"-journal",@"-wal",@"-shm"]) {
        NSString *source = [self.databaseURL.path stringByAppendingString:sidecar];
        if (![fm fileExistsAtPath:source]) continue;
        if (![fm moveItemAtPath:source toPath:[quarantine.path stringByAppendingString:sidecar] error:nil]) {
            for (NSString *prior in moved) [fm moveItemAtPath:[quarantine.path stringByAppendingString:prior] toPath:[self.databaseURL.path stringByAppendingString:prior] error:nil];
            [fm moveItemAtURL:quarantine toURL:self.databaseURL error:nil]; return NO;
        }
        [moved addObject:sidecar];
    }
    return YES;
}
- (sqlite3 *)openDatabase:(NSError **)error { return [self openDatabase:error allowRecovery:YES]; }
- (sqlite3 *)openDatabase:(NSError **)error allowRecovery:(BOOL)allowRecovery {
    if (!self.databaseURL) { if (error) *error = OFTStorageError(OFTManagedStorageInvalidDirectory); return NULL; }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *parent = self.databaseURL.URLByDeletingLastPathComponent;
    if (![fm createDirectoryAtURL:parent withIntermediateDirectories:YES attributes:nil error:error]) return NULL;
    struct stat info;
    BOOL databaseMissing = lstat(self.databaseURL.fileSystemRepresentation, &info) < 0 && errno == ENOENT;
    if (databaseMissing) for (NSString *sidecar in @[@"-journal",@"-wal",@"-shm"]) {
        if ([fm fileExistsAtPath:[self.databaseURL.path stringByAppendingString:sidecar]]) {
            if (error) *error = OFTStorageError(OFTManagedStorageIOFailure); return NULL;
        }
    }
    if (lstat(self.databaseURL.fileSystemRepresentation, &info) == 0 && !S_ISREG(info.st_mode)) {
        if (error) *error = OFTStorageError(OFTManagedStorageInvalidDirectory); return NULL;
    }
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(self.databaseURL.fileSystemRepresentation, &db,
                      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (error) *error = OFTStorageError(OFTManagedStorageIOFailure); if (db) sqlite3_close(db); return NULL;
    }
    sqlite3_busy_timeout(db, 3000);
    sqlite3_stmt *version = NULL;
    int schema = -1;
    if (sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &version, NULL) == SQLITE_OK && sqlite3_step(version) == SQLITE_ROW)
        schema = sqlite3_column_int(version, 0);
    sqlite3_finalize(version);
    if (schema < 0 || schema > 1) {
        int failureCode = sqlite3_errcode(db);
        if (schema < 0 && allowRecovery && (failureCode == SQLITE_CORRUPT || failureCode == SQLITE_NOTADB)) {
            sqlite3_close(db);
            if ([self quarantineCorruptDatabase]) { if (error) *error = nil; return [self openDatabase:error allowRecovery:NO]; }
            if (error) *error = OFTStorageError(OFTManagedStorageIOFailure); return NULL;
        }
        if (error) *error = OFTStorageError(schema > 1 ? OFTManagedStorageUnsupportedSchema : OFTManagedStorageIOFailure);
        sqlite3_close(db); return NULL;
    }
    // Ordinary IO stays unknown. Only SQLite CORRUPT/NOTADB is quarantined and rebuilt; no old-ledger import.
    BOOL configured = OFTSQL(db, "PRAGMA synchronous=FULL", error) && OFTSQL(db, "BEGIN IMMEDIATE", error) &&
        OFTSQL(db, "CREATE TABLE IF NOT EXISTS offline_package (version INTEGER NOT NULL PRIMARY KEY, sha256 TEXT NOT NULL CHECK(length(sha256)=64 AND sha256 NOT GLOB '*[^0-9a-f]*'), stage TEXT NOT NULL CHECK(stage IN ('downloading','downloaded','ready','active')))", error) &&
        OFTSQL(db, "CREATE UNIQUE INDEX IF NOT EXISTS offline_single_active ON offline_package(stage) WHERE stage='active'", error) &&
        OFTSQL(db, "CREATE UNIQUE INDEX IF NOT EXISTS offline_single_ready ON offline_package(stage) WHERE stage='ready'", error) &&
        (schema == 1 || OFTSQL(db, "PRAGMA user_version=1", error)) && OFTSQL(db, "COMMIT", error);
    if (!configured) {
        int failureCode = sqlite3_errcode(db); OFTSQL(db,"ROLLBACK",NULL); sqlite3_close(db);
        if (allowRecovery && (failureCode == SQLITE_CORRUPT || failureCode == SQLITE_NOTADB) && [self quarantineCorruptDatabase]) {
            if (error) *error = nil; return [self openDatabase:error allowRecovery:NO];
        }
        return NULL;
    }
    [self.databaseURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return db;
}
- (void)closeDatabase:(sqlite3 *)db queryFailureCode:(int)failureCode {
    int primaryCode = failureCode & 0xff;
    if (sqlite3_close(db) == SQLITE_OK && (primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB))
        [self quarantineCorruptDatabase];
}
- (NSArray<NSDictionary *> *)rowsInDatabase:(sqlite3 *)db version:(NSNumber *)version sqliteFailureCode:(int *)failureCode error:(NSError **)error {
    if (failureCode) *failureCode = SQLITE_OK;
    sqlite3_stmt *statement = NULL;
    const char *sql = version ? "SELECT version,sha256,stage FROM offline_package WHERE version=? ORDER BY version" :
        "SELECT version,sha256,stage FROM offline_package ORDER BY version";
    int result = sqlite3_prepare_v2(db, sql, -1, &statement, NULL);
    if (result != SQLITE_OK) {
        if (failureCode) *failureCode = result;
        sqlite3_finalize(statement);
        if (error) *error = OFTStorageError(OFTManagedStorageIOFailure); return nil;
    }
    if (version) sqlite3_bind_int64(statement, 1, version.longLongValue);
    NSMutableArray *rows = [NSMutableArray array]; BOOL validRows = YES;
    while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
        NSInteger number = (NSInteger)sqlite3_column_int64(statement, 0);
        const char *hashBytes = (const char *)sqlite3_column_text(statement, 1);
        const char *stageBytes = (const char *)sqlite3_column_text(statement, 2);
        NSString *sha = hashBytes ? [NSString stringWithUTF8String:hashBytes] : nil;
        NSString *stage = stageBytes ? [NSString stringWithUTF8String:stageBytes] : nil;
        if (![[OFTPackageRecord alloc] initWithVersion:number sha256:sha] ||
            ![@[OFTPackageStageDownloading,OFTPackageStageDownloaded,OFTPackageStageReady,OFTPackageStageActive] containsObject:stage]) {
            validRows = NO; break;
        }
        [rows addObject:@{@"version":@(number), @"sha256":sha, @"stage":stage}];
    }
    // Preserve only actual SQLite failures before finalize; logical row validation cannot authorize quarantine.
    if (validRows && result != SQLITE_DONE && failureCode) *failureCode = result;
    sqlite3_finalize(statement);
    if (!validRows || result != SQLITE_DONE) { if (error) *error = OFTStorageError(OFTManagedStorageIOFailure); return nil; }
    return rows;
}
- (NSArray<NSDictionary *> *)readRowsWithError:(NSError **)error {
    @synchronized (self) {
        sqlite3 *db = [self openDatabase:error]; if (!db) return nil;
        int failureCode = SQLITE_OK;
        NSArray *rows = [self rowsInDatabase:db version:nil sqliteFailureCode:&failureCode error:error];
        [self closeDatabase:db queryFailureCode:failureCode]; return rows;
    }
}
- (NSDictionary *)rowForVersion:(NSInteger)version error:(NSError **)error {
    @synchronized (self) {
        sqlite3 *db = [self openDatabase:error]; if (!db) return nil;
        int failureCode = SQLITE_OK;
        NSArray *rows = [self rowsInDatabase:db version:@(version) sqliteFailureCode:&failureCode error:error];
        [self closeDatabase:db queryFailureCode:failureCode]; return rows.firstObject;
    }
}
- (NSArray<NSNumber *> *)inactiveInDatabase:(sqlite3 *)db keeping:(NSInteger)version sqliteFailureCode:(int *)failureCode error:(NSError **)error {
    NSArray *rows = [self rowsInDatabase:db version:nil sqliteFailureCode:failureCode error:error]; if (!rows) return nil;
    NSMutableArray *evicted = [NSMutableArray array];
    for (NSDictionary *row in rows) if ([row[@"version"] integerValue] != version && ![row[@"stage"] isEqual:OFTPackageStageActive])
        [evicted addObject:row[@"version"]];
    sqlite3_stmt *statement = NULL;
    BOOL ok = sqlite3_prepare_v2(db, "DELETE FROM offline_package WHERE version!=? AND stage!='active'", -1, &statement, NULL) == SQLITE_OK;
    if (ok) { sqlite3_bind_int64(statement, 1, version); ok = sqlite3_step(statement) == SQLITE_DONE; }
    sqlite3_finalize(statement);
    if (!ok) { if (error) *error = OFTStorageError(OFTManagedStorageIOFailure); return nil; }
    return evicted;
}
- (NSArray<NSNumber *> *)registerTarget:(OFTPackageRecord *)target error:(NSError **)error {
    @synchronized (self) {
        sqlite3 *db = [self openDatabase:error]; if (!db) return nil;
        NSArray *evicted = nil; int failureCode = SQLITE_OK;
        if (OFTSQL(db, "BEGIN IMMEDIATE", error)) {
            NSArray *existing = [self rowsInDatabase:db version:@(target.version) sqliteFailureCode:&failureCode error:error];
            BOOL valid = existing != nil;
            if (valid && existing.count && ![existing.firstObject[@"sha256"] isEqual:target.sha256]) {
                valid = NO; if (error) *error = OFTStorageError(OFTManagedStorageIdentityConflict);
            }
            if (valid && !existing.count) {
                sqlite3_stmt *insert = NULL;
                valid = sqlite3_prepare_v2(db, "INSERT INTO offline_package(version,sha256,stage) VALUES(?,?,'downloading')", -1, &insert, NULL) == SQLITE_OK;
                if (valid) { sqlite3_bind_int64(insert,1,target.version); sqlite3_bind_text(insert,2,target.sha256.UTF8String,-1,SQLITE_TRANSIENT); valid = sqlite3_step(insert) == SQLITE_DONE; }
                sqlite3_finalize(insert);
                if (!valid && error) *error = OFTStorageError(OFTManagedStorageIOFailure);
            }
            if (valid) evicted = [self inactiveInDatabase:db keeping:target.version sqliteFailureCode:&failureCode error:error];
            if (!evicted || !OFTSQL(db, "COMMIT", error)) { OFTSQL(db,"ROLLBACK",NULL); evicted = nil; }
        }
        [self closeDatabase:db queryFailureCode:failureCode]; return evicted;
    }
}
- (BOOL)setStage:(NSString *)stage forVersion:(NSInteger)version error:(NSError **)error {
    @synchronized (self) {
        sqlite3 *db = [self openDatabase:error]; if (!db) return NO;
        sqlite3_stmt *statement = NULL;
        BOOL ok = sqlite3_prepare_v2(db, "UPDATE offline_package SET stage=? WHERE version=? AND stage!='active' AND ?!='active' AND NOT EXISTS(SELECT 1 FROM offline_package WHERE ?='ready' AND stage='ready' AND version!=?)", -1, &statement, NULL) == SQLITE_OK;
        if (ok) {
            sqlite3_bind_text(statement,1,stage.UTF8String,-1,SQLITE_TRANSIENT); sqlite3_bind_int64(statement,2,version);
            sqlite3_bind_text(statement,3,stage.UTF8String,-1,SQLITE_TRANSIENT); sqlite3_bind_text(statement,4,stage.UTF8String,-1,SQLITE_TRANSIENT); sqlite3_bind_int64(statement,5,version);
            ok = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) == 1;
        }
        sqlite3_finalize(statement); sqlite3_close(db);
        if (!ok && error) *error = OFTStorageError(OFTManagedStorageMissingStageRow); return ok;
    }
}
- (BOOL)activateVersion:(NSInteger)version error:(NSError **)error {
    @synchronized (self) {
        sqlite3 *db = [self openDatabase:error]; if (!db) return NO;
        BOOL ok = OFTSQL(db,"BEGIN IMMEDIATE",error);
        if (ok) ok = OFTSQL(db,"DELETE FROM offline_package WHERE stage='active'",error);
        sqlite3_stmt *statement = NULL;
        if (ok) ok = sqlite3_prepare_v2(db,"UPDATE offline_package SET stage='active' WHERE version=? AND stage='ready'",-1,&statement,NULL) == SQLITE_OK;
        if (ok) { sqlite3_bind_int64(statement,1,version); ok = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) == 1; }
        sqlite3_finalize(statement);
        if (ok) ok = OFTSQL(db,"COMMIT",error);
        if (!ok) { OFTSQL(db,"ROLLBACK",NULL); if (error && !*error) *error = OFTStorageError(OFTManagedStorageMissingStageRow); }
        sqlite3_close(db); return ok;
    }
}
- (NSArray<NSNumber *> *)evictInactiveKeepingVersion:(NSInteger)version error:(NSError **)error {
    @synchronized (self) {
        sqlite3 *db = [self openDatabase:error]; if (!db) return nil;
        NSArray *evicted = nil; int failureCode = SQLITE_OK;
        if (OFTSQL(db,"BEGIN IMMEDIATE",error)) {
            NSArray *rows = [self rowsInDatabase:db version:@(version) sqliteFailureCode:&failureCode error:error];
            if (rows) evicted = [rows.firstObject[@"stage"] isEqual:OFTPackageStageActive] ?
                [self inactiveInDatabase:db keeping:version sqliteFailureCode:&failureCode error:error] : @[];
            if (!evicted || !OFTSQL(db,"COMMIT",error)) { OFTSQL(db,"ROLLBACK",NULL); evicted = nil; }
        }
        [self closeDatabase:db queryFailureCode:failureCode]; return evicted;
    }
}
@end
