#import <XCTest/XCTest.h>
#import <OfflineTool/OfflineTool.h>
#import <sqlite3.h>

@interface OFTManagedStorageTests : XCTestCase
@property NSURL *sandbox;
@property OFTManagedStorage *storage;
@end
@implementation OFTManagedStorageTests
- (void)setUp {
    self.sandbox = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    self.storage = [[OFTManagedStorage alloc] initWithDatabaseURL:[self.sandbox URLByAppendingPathComponent:@"webview.db"]];
}
- (void)tearDown { [NSFileManager.defaultManager removeItemAtURL:self.sandbox error:nil]; }
- (OFTPackageRecord *)record:(NSInteger)version { return [[OFTPackageRecord alloc] initWithVersion:version sha256:[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]]; }
- (void)prepareActive:(NSInteger)version {
    XCTAssertNotNil([self.storage registerTarget:[self record:version] error:nil]);
    XCTAssertTrue([self.storage setStage:OFTPackageStageReady forVersion:version error:nil]);
    XCTAssertTrue([self.storage activateVersion:version error:nil]);
}
- (int)SQL:(NSString *)SQL {
    sqlite3 *db = NULL; XCTAssertEqual(sqlite3_open(self.storage.databaseURL.fileSystemRepresentation,&db),SQLITE_OK);
    int code = sqlite3_exec(db,SQL.UTF8String,NULL,NULL,NULL); sqlite3_close(db); return code;
}
- (NSData *)damageTableDataPageAndVerifySQLiteCorruption {
    sqlite3 *db = NULL; sqlite3_stmt *query = NULL;
    XCTAssertEqual(sqlite3_open(self.storage.databaseURL.fileSystemRepresentation,&db),SQLITE_OK);
    XCTAssertEqual(sqlite3_prepare_v2(db,"PRAGMA page_size",-1,&query,NULL),SQLITE_OK);
    XCTAssertEqual(sqlite3_step(query),SQLITE_ROW); NSInteger pageSize=sqlite3_column_int(query,0); sqlite3_finalize(query);
    XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT rootpage FROM sqlite_master WHERE name='offline_package'",-1,&query,NULL),SQLITE_OK);
    XCTAssertEqual(sqlite3_step(query),SQLITE_ROW); NSInteger rootPage=sqlite3_column_int(query,0); sqlite3_finalize(query); sqlite3_close(db);
    NSMutableData *bytes=[[NSData dataWithContentsOfURL:self.storage.databaseURL] mutableCopy];
    XCTAssertGreaterThan(rootPage,1); XCTAssertGreaterThanOrEqual(bytes.length,(NSUInteger)(rootPage*pageSize));
    uint8_t invalidPageType=0; [bytes replaceBytesInRange:NSMakeRange((rootPage-1)*pageSize,1) withBytes:&invalidPageType];
    XCTAssertTrue([bytes writeToURL:self.storage.databaseURL atomically:NO]);
    XCTAssertEqual(sqlite3_open_v2(self.storage.databaseURL.fileSystemRepresentation,&db,SQLITE_OPEN_READONLY,NULL),SQLITE_OK);
    XCTAssertEqual(sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&query,NULL),SQLITE_OK);
    XCTAssertEqual(sqlite3_step(query),SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(query,0),1); sqlite3_finalize(query);
    XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT rootpage FROM sqlite_master WHERE name='offline_package'",-1,&query,NULL),SQLITE_OK);
    XCTAssertEqual(sqlite3_step(query),SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(query,0),rootPage); sqlite3_finalize(query);
    XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT version,sha256,stage FROM offline_package ORDER BY version",-1,&query,NULL),SQLITE_OK);
    int result=sqlite3_step(query); NSLog(@"OFT query-page fault: header/schema readable, step=%d errcode=%d rootpage=%ld page_size=%ld",result,sqlite3_errcode(db),(long)rootPage,(long)pageSize);
    XCTAssertEqual(result,SQLITE_CORRUPT); sqlite3_finalize(query); sqlite3_close(db); return bytes;
}
- (NSArray<NSURL *> *)quarantinedDatabases {
    NSArray *children=[NSFileManager.defaultManager contentsOfDirectoryAtURL:self.sandbox includingPropertiesForKeys:nil options:0 error:nil];
    NSPredicate *match=[NSPredicate predicateWithBlock:^BOOL(NSURL *URL,NSDictionary *bindings){ return [URL.lastPathComponent hasPrefix:@"webview.db.corrupt-"]; }];
    return [children filteredArrayUsingPredicate:match];
}
- (void)testAllRowsQueryDataPageCorruptionQuarantinesThenNextReadReopens {
    [self prepareActive:10000]; NSData *corrupt=[self damageTableDataPageAndVerifySQLiteCorruption]; NSError *error=nil;
    XCTAssertNil([self.storage readRowsWithError:&error]); XCTAssertEqual(error.code,OFTManagedStorageIOFailure);
    NSArray<NSURL *> *quarantined=[self quarantinedDatabases]; XCTAssertEqual(quarantined.count,1u);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:quarantined.firstObject],corrupt);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:self.storage.databaseURL.path]);
    error=nil; NSArray *recovered=[self.storage readRowsWithError:&error]; XCTAssertNotNil(recovered); XCTAssertEqual(recovered.count,0u); XCTAssertNil(error);
    XCTAssertEqual([self quarantinedDatabases].count,1u);
}
- (void)testVersionQueryDataPageCorruptionQuarantinesWithoutCurrentRequestRetry {
    [self prepareActive:10000]; NSData *corrupt=[self damageTableDataPageAndVerifySQLiteCorruption]; NSError *error=nil;
    XCTAssertNil([self.storage rowForVersion:10000 error:&error]); XCTAssertEqual(error.code,OFTManagedStorageIOFailure);
    NSArray<NSURL *> *quarantined=[self quarantinedDatabases]; XCTAssertEqual(quarantined.count,1u);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:quarantined.firstObject],corrupt);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:self.storage.databaseURL.path]);
    error=nil; XCTAssertNil([self.storage rowForVersion:10000 error:&error]); XCTAssertNil(error);
    XCTAssertEqual([self.storage readRowsWithError:nil].count,0u);
}
- (void)testRegistrationQueryCorruptionRollsBackAndQuarantinesAfterClosing {
    [self prepareActive:10000];NSData *corrupt=[self damageTableDataPageAndVerifySQLiteCorruption];NSError *error=nil;
    XCTAssertNil([self.storage registerTarget:[self record:10001] error:&error]);XCTAssertEqual(error.code,OFTManagedStorageIOFailure);
    NSArray<NSURL *> *quarantined=[self quarantinedDatabases];XCTAssertEqual(quarantined.count,1u);XCTAssertEqualObjects([NSData dataWithContentsOfURL:quarantined.firstObject],corrupt);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:self.storage.databaseURL.path]);
    error=nil;NSArray *rows=[self.storage readRowsWithError:&error];XCTAssertNotNil(rows);XCTAssertEqual(rows.count,0u);XCTAssertNil(error);
}
- (void)testEvictionQueryCorruptionRollsBackAndQuarantinesAfterClosing {
    [self prepareActive:10000];NSData *corrupt=[self damageTableDataPageAndVerifySQLiteCorruption];NSError *error=nil;
    XCTAssertNil([self.storage evictInactiveKeepingVersion:10000 error:&error]);XCTAssertEqual(error.code,OFTManagedStorageIOFailure);
    NSArray<NSURL *> *quarantined=[self quarantinedDatabases];XCTAssertEqual(quarantined.count,1u);XCTAssertEqualObjects([NSData dataWithContentsOfURL:quarantined.firstObject],corrupt);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:self.storage.databaseURL.path]);
    error=nil;NSArray *rows=[self.storage readRowsWithError:&error];XCTAssertNotNil(rows);XCTAssertEqual(rows.count,0u);XCTAssertNil(error);
}
- (void)testOrdinaryQueryErrorDoesNotQuarantineOrRebuildDatabase {
    [self prepareActive:10000]; XCTAssertEqual([self SQL:@"ALTER TABLE offline_package RENAME COLUMN stage TO prior_stage"],SQLITE_OK);
    NSData *before=[NSData dataWithContentsOfURL:self.storage.databaseURL]; NSError *error=nil;
    XCTAssertNil([self.storage readRowsWithError:&error]); XCTAssertEqual(error.code,OFTManagedStorageIOFailure);
    error=nil; XCTAssertNil([self.storage rowForVersion:10000 error:&error]); XCTAssertEqual(error.code,OFTManagedStorageIOFailure);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:self.storage.databaseURL],before); XCTAssertEqual([self quarantinedDatabases].count,0u);
}
- (void)testInvalidLogicalRowIsNotSQLiteReportedCorruption {
    [self prepareActive:10000]; XCTAssertEqual([self SQL:@"PRAGMA ignore_check_constraints=ON; UPDATE offline_package SET sha256='invalid'"],SQLITE_OK);
    NSData *before=[NSData dataWithContentsOfURL:self.storage.databaseURL]; NSError *error=nil;
    XCTAssertNil([self.storage readRowsWithError:&error]); XCTAssertEqual(error.code,OFTManagedStorageIOFailure);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:self.storage.databaseURL],before); XCTAssertEqual([self quarantinedDatabases].count,0u);
}
- (void)testRealSchemaHasThreeColumnsAndPersistsFixedStages {
    XCTAssertEqual([self.storage readRowsWithError:nil].count,0u);
    sqlite3 *db = NULL; XCTAssertEqual(sqlite3_open(self.storage.databaseURL.fileSystemRepresentation,&db),SQLITE_OK);
    sqlite3_stmt *query = NULL; XCTAssertEqual(sqlite3_prepare_v2(db,"PRAGMA table_info(offline_package)",-1,&query,NULL),SQLITE_OK);
    NSMutableArray *columns = [NSMutableArray array];
    while (sqlite3_step(query)==SQLITE_ROW) [columns addObject:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(query,1)]];
    XCTAssertEqualObjects(columns,(@[@"version",@"sha256",@"stage"])); sqlite3_finalize(query); sqlite3_close(db);
    XCTAssertNotNil([self.storage registerTarget:[self record:10000] error:nil]);
    for (NSString *stage in @[OFTPackageStageDownloading,OFTPackageStageDownloaded,OFTPackageStageReady]) XCTAssertTrue([self.storage setStage:stage forVersion:10000 error:nil]);
    OFTManagedStorage *reopened = [[OFTManagedStorage alloc] initWithDatabaseURL:self.storage.databaseURL];
    XCTAssertEqualObjects([reopened rowForVersion:10000 error:nil][@"stage"],OFTPackageStageReady);
}
- (void)testRegisterIdentityConflictRollsBackBeforeEviction {
    [self prepareActive:10000]; XCTAssertNotNil([self.storage registerTarget:[self record:10001] error:nil]);
    XCTAssertTrue([self.storage setStage:OFTPackageStageReady forVersion:10001 error:nil]);
    NSArray *before = [self.storage readRowsWithError:nil];
    OFTPackageRecord *conflict = [[OFTPackageRecord alloc] initWithVersion:10000 sha256:[@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0]];
    NSError *error = nil; XCTAssertNil([self.storage registerTarget:conflict error:&error]); XCTAssertEqual(error.code,OFTManagedStorageIdentityConflict);
    XCTAssertEqualObjects(before,[self.storage readRowsWithError:nil]);
    XCTAssertEqualObjects([self.storage registerTarget:[self record:10002] error:nil],(@[@10001]));
    XCTAssertEqual([self.storage readRowsWithError:nil].count,2u);
}
- (void)testReadyAndActiveUniquenessAreRealSQLiteConstraints {
    [self prepareActive:10000]; XCTAssertNotNil([self.storage registerTarget:[self record:10001] error:nil]);
    XCTAssertTrue([self.storage setStage:OFTPackageStageReady forVersion:10001 error:nil]);
    NSString *sha = [self record:10002].sha256;
    XCTAssertEqual(([self SQL:[NSString stringWithFormat:@"INSERT INTO offline_package VALUES(10002,'%@','ready')",sha]]),SQLITE_CONSTRAINT);
    XCTAssertEqual(([self SQL:[NSString stringWithFormat:@"INSERT INTO offline_package VALUES(10002,'%@','active')",sha]]),SQLITE_CONSTRAINT);
    XCTAssertEqual([self.storage readRowsWithError:nil].count,2u);
}
- (void)testMissingReadyActivationRollsBackDeletedOldActive {
    [self prepareActive:10000]; NSArray *before = [self.storage readRowsWithError:nil];
    NSError *error = nil; XCTAssertFalse([self.storage activateVersion:10001 error:&error]); XCTAssertNotNil(error);
    XCTAssertEqualObjects(before,[self.storage readRowsWithError:nil]);
}
- (void)testStageCannotChangeSHAOrActiveAndZeroRowsIsFailure {
    [self prepareActive:10000]; NSError *error = nil;
    XCTAssertFalse([self.storage setStage:OFTPackageStageDownloaded forVersion:10000 error:&error]);
    XCTAssertEqual(error.code,OFTManagedStorageMissingStageRow);
    XCTAssertFalse([self.storage setStage:OFTPackageStageReady forVersion:10001 error:nil]);
    XCTAssertEqualObjects([self.storage rowForVersion:10000 error:nil][@"sha256"],[self record:10000].sha256);
}
- (void)testTriggerReadyZeroRowsDoesNotReportSaved {
    XCTAssertNotNil([self.storage registerTarget:[self record:10000] error:nil]);
    XCTAssertEqual([self SQL:@"CREATE TRIGGER reject_ready BEFORE UPDATE OF stage ON offline_package WHEN NEW.stage='ready' BEGIN SELECT RAISE(IGNORE); END"],SQLITE_OK);
    XCTAssertFalse([self.storage setStage:OFTPackageStageReady forVersion:10000 error:nil]);
    XCTAssertEqualObjects([self.storage rowForVersion:10000 error:nil][@"stage"],OFTPackageStageDownloading);
}
- (void)testEvictionCannotEmptyDatabaseWhenMemoryActiveRowIsAbsent {
    XCTAssertNotNil([self.storage registerTarget:[self record:10001] error:nil]);
    XCTAssertEqualObjects([self.storage evictInactiveKeepingVersion:10000 error:nil],@[]);
    XCTAssertEqual([self.storage readRowsWithError:nil].count,1u);
}
- (void)testContainerRelocationKeepsSiblingDatabaseIdentityAndEnvironmentIsolation {
    NSURL *a = [self.sandbox URLByAppendingPathComponent:@"container-a" isDirectory:YES];
    NSURL *rootA = [a URLByAppendingPathComponent:@"Library/Application Support/offline/INT/lifecycle/webview" isDirectory:YES];
    OFTManagedStorage *storageA = [OFTManagedStorage defaultStorageForInstallationRootDirectory:rootA error:nil];
    XCTAssertNotNil([storageA registerTarget:[self record:10000] error:nil]);
    NSURL *b = [self.sandbox URLByAppendingPathComponent:@"container-b" isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:a toURL:b error:nil]);
    NSURL *rootB = [b URLByAppendingPathComponent:@"Library/Application Support/offline/INT/lifecycle/webview" isDirectory:YES];
    OFTManagedStorage *storageB = [OFTManagedStorage defaultStorageForInstallationRootDirectory:rootB error:nil];
    XCTAssertEqualObjects([storageA readRowsWithError:nil],[storageB readRowsWithError:nil]);
    OFTManagedStorage *other = [OFTManagedStorage defaultStorageForInstallationRootDirectory:[b URLByAppendingPathComponent:@"Library/Application Support/offline/UAT/lifecycle/webview"] error:nil];
    XCTAssertEqual([other readRowsWithError:nil].count,0u);
    XCTAssertTrue([storageB.databaseURL.path hasSuffix:@"/lifecycle/webview.db"]);
    XCTAssertFalse([storageB.databaseURL.path hasPrefix:[rootB.path stringByAppendingString:@"/"]]);
}
- (void)testRealNotADatabaseIsQuarantinedWithoutDeletingOriginalBytes {
    XCTAssertNotNil([self.storage readRowsWithError:nil]); NSData *corrupt = [@"This is deliberately not SQLite" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([corrupt writeToURL:self.storage.databaseURL atomically:NO]);
    NSError *error = nil; XCTAssertEqual([self.storage readRowsWithError:&error].count,0u); XCTAssertNil(error);
    NSArray *children = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.sandbox includingPropertiesForKeys:nil options:0 error:nil];
    NSUInteger preserved = 0; for (NSURL *child in children) if ([child.lastPathComponent containsString:@".corrupt-"]) { preserved++; XCTAssertEqualObjects([NSData dataWithContentsOfURL:child],corrupt); }
    XCTAssertEqual(preserved,1u);
}
- (void)testOrdinaryReadFailureAndUnknownSchemaNeverResetOrDelete {
    XCTAssertNotNil([self.storage readRowsWithError:nil]); XCTAssertEqual([self SQL:@"PRAGMA user_version=99"],SQLITE_OK);
    NSData *before = [NSData dataWithContentsOfURL:self.storage.databaseURL]; NSError *error = nil;
    XCTAssertNil([self.storage readRowsWithError:&error]); XCTAssertEqual(error.code,OFTManagedStorageUnsupportedSchema);
    XCTAssertEqualObjects(before,[NSData dataWithContentsOfURL:self.storage.databaseURL]);
    OFTManagedStorage *bad = [[OFTManagedStorage alloc] initWithDatabaseURL:self.sandbox];
    XCTAssertNil([bad readRowsWithError:nil]); XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:self.sandbox.path]);
}
- (void)testOrphanJournalWithoutDatabaseIsUnknownAndPreserved {
    [NSFileManager.defaultManager createDirectoryAtURL:self.sandbox withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *journal=[NSURL fileURLWithPath:[self.storage.databaseURL.path stringByAppendingString:@"-journal"]];NSData *evidence=[@"orphan journal" dataUsingEncoding:NSUTF8StringEncoding];XCTAssertTrue([evidence writeToURL:journal atomically:NO]);
    XCTAssertNil([self.storage readRowsWithError:nil]);XCTAssertEqualObjects([NSData dataWithContentsOfURL:journal],evidence);XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:self.storage.databaseURL.path]);
}
@end
