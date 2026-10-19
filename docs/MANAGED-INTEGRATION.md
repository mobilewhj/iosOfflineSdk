# iOS 15+ managed integration

The managed SDK owns the package lifecycle, file preparation, retry quota and the single foreground five-minute scheduler. Objective-C callbacks and NSProgress remain the integration surface. Version 0.3.1 is distributed as a formal XCFramework and an exact-version remote Swift package. A compiled deployment target does not prove iOS 15 runtime validation.

## Minimal Objective-C integration

Create one process instance after the host's ordinary business configuration is ready. Keep configuration requests, parsing, consent, authentication, advertisements and navigation in the host's existing chain.

```objc
self.offlineSDK = [[OFTManagedOfflineSDK alloc]
    initWithRootDirectory:packageRoot
    originalStaticRoot:[NSURL URLWithString:@"https://example.com/app/"]
    minimumVersion:10000 checkInterval:300 storage:nil
    versionedConfigurationProvider:^NSProgress *(NSInteger currentVersion,
                                                 OFTConfigurationCompletion completion) {
        return [configurationAdapter requestWithCurrentVersion:currentVersion
                                                   completion:completion];
    } error:&error];
self.offlineSDK.outcomeHandler = ^(OFTManagedOutcome *outcome) {
    // Prepared success or actual package-processing failure only.
    // Capture outcome.record/version, stage, reason, HTTPStatus and activeVersion.
    // Upload failure never changes preparation or navigation.
};
self.offlineSDK.diagnosticHandler = ^(NSString *stage, OFTOfflineErrorCode reason, NSString *detail) {
    // Diagnostics are separate from installation statistics.
};
[self.offlineSDK updatePrivacyGranted:consent foreground:foreground];
self.startupJob = [self.offlineSDK prepareStartupWithProgress:^(OFTPreparationProgress *p) {
    // Real stage progress; fraction==-1 is indeterminate, and complete follows ready persistence.
} completion:^(OFTPreparationResult *result) {
    if (result.disposition == OFTPreparationContinue) {
        // Release only offline waiting. Preserve the host's business/privacy/advertisement gates.
    }
    // Deferred/Cancelled allows explicit reentry. Do not navigate from replayed progress.
}];
```

The versioned provider receives the SDK's physically usable process-active version, or 0. This is independent of page eligibility: disabled policy or a different online version does not erase a readable active version. Disabled responses need no package metadata. A missing URL can represent no candidate when a usable current package already meets the reported online version. Actual target validation, SHA identity and rollback decisions belong to the SDK. SHA accepts ASCII hex case and normalizes lowercase without trimming.

The two original configurationProvider initializers remain available through a typed adapter. A file packageURL is a trusted Local ZIP input. A remote URL must be HTTP(S) without user information or fragment. Set downloadConfiguration before starting work to inherit host NSURLSession timeouts; nil uses platform ephemeral defaults. Managed downloads add no arbitrary total deadline, ZIP size, expanded size, entry count or individual-file size limit. Path, symlink, structural and CRC/SHA checks remain. The historical standalone installer keeps its original limits and publication contract.

## Lifecycle and persistence

A single SQLite table offline_package contains exactly version, sha256 and stage. The only stored stages are downloading, downloaded, ready and active; active and ready are each unique. SHA is immutable after registration. The database is packageRoot.path + ".db", outside package cleanup and stable when an entire app container moves. No enabled, History, first-preparation, retry or cacheDirty ledger is stored. No previous KV ledger is imported or deleted. Use a separate root namespace when adopting this incompatible lifecycle to preserve old packages and old state.

First preparation is based on whether the first successful database read in the process was empty. The startup decision is made once per process. A read failure releases offline waiting and authorizes no cleanup; a later natural entrance retries the read. An ordinary first result releases the silent gate. Cancellation keeps that gate closed until explicit startup reentry.

Before a page gets a directory, cold loading tries to promote a usable ready row in a transaction, then fixes the process-active package. Existing active remains fixed for this process, including when its directory becomes unusable. A new package is prepared as ready and waits for the next true cold process; only absence of any process-active package allows immediate activation. An unusable current version is never repaired in place. Activation failure retains ready and emits no additional installation success/failure.

Preparation uses one path: transactional identity registration before eviction, actual SHA reuse of N.zip or a new fsynced download, downloaded persistence, fresh direct extraction into N with checked file fsync/close, readable entry confirmation, then ready persistence. Root and dist/index.html ZIP layouts are accepted. A failed/canceled extraction removes N but retains its verified ZIP. Cold cleanup preserves active/ready directories and incomplete-record ZIPs; database read failure cannot authorize deletion. Runtime cleanup protects the in-memory active directory even if the database has been rebuilt.

SQLite CORRUPT/NOTADB is a platform-specific recovery: the owned database and known sidecars are moved beside it with a .corrupt-UUID suffix. Initialization may then open a fresh schema; actual query-time corruption fails that call and lets a later ordinary entrance reopen storage, without an internal retry loop. Actual SQLite codes are captured before statement finalization; invalid logical rows do not authorize quarantine. Quarantine failure or ordinary IO/permission/unsupported-schema errors remain read failures; they never reset data. No package directory is used to infer database facts. In a new process a successfully rebuilt empty table follows normal first/cold cleanup rules. Runtime recovery never reruns cold cleanup or replaces the in-memory active package. Schema changes require explicit migration; unsupported versions are preserved.

## Scheduling, cancellation and retries

Only the SDK schedules checks, at a default 300 seconds from actual provider invocation. Silent scheduling requires privacy, foreground and a released startup gate. After admission/Checking, ordinary background does not cancel that silent check, including configuration returning before preparation begins. A silent no-request round yields a full cycle. First preparation checks foreground at invocation, before requesting configuration and before starting preparation. Once download/extraction starts, ordinary background permits completion while the OS allows execution. iOS suspension or process termination provides no background-keepalive guarantee.

The first caller owns preparation and progress; waiters share its result. Waiter cancellation affects only that waiter. Owner/privacy/close cancels real work, and late callbacks are ignored. Only the short ready commit/event/optional activation finishing section is noncancellable. Cancellation during that section can leave a real Prepared event, while the canceled startup call still keeps its gate closed.

Retry quota is memory-only per version+SHA. Transfer/timeout and HTTP 408/429/500/502/503/504 do not consume the non-network quota. Other preparation failures allow one additional attempt, then stop for that target in this process. Cancellation consumes none. A higher target starts fresh; success resets quota/wait but preserves the target and cache request fact. Retry-After seconds on download 429/503 limit subsequent downloads. Every retry still uses the sole five-minute cadence and refetches configuration.

## Policy, cache and page binding

Online policy is memory-only: unknown, forced online or known version/SHA. Configuration failure/invalidity and candidate-record read failure preserve the previous policy, cache and attempt facts. Identity conflicts are rejected before eviction or file deletion. A new page can use a readable fixed active package only under unknown or matching policy. Existing pages retain their bound directory; forced online stops subsequent local resource decisions without refreshing the page.

For a silent higher target with an active package, SDK order is policy update → synchronous cache-removal request → preparation. The request happens at most once for that target in the process, even if the cleaner throws. There is no page-time/persistent dirty cache ledger. resourceCacheCleaner may be supplied by the host; nil requests only WKWebsiteDataTypeMemoryCache and WKWebsiteDataTypeDiskCache removal on the default data store. Hosts using a different WK data store must target that store. The SDK continues without awaiting disk removal and does not claim actual disk completion. Cookie, localStorage, login and business data must be retained.

```objc
WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
// Preserve the host's original content controller, scripts, Cookie/Bridge and delegates.
OFTPageBinding *binding = [self.offlineSDK pageBindingForConfiguration:configuration
    scheme:@"app-offline" error:&error];
WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
self.pageJob = [self.offlineSDK loadPage:originalURL inWebView:webView binding:binding
    completion:^(OFTPageLoadResult *result, NSError *failure) {
        // result.record is this page's immutable package identity.
    }];
// At actual page closure: [self.pageJob cancel]; [binding dispose];
```

A binding follows the same WKWebView through reload/external navigation/back. Do not call loadPage again to switch that page's version. Keep identity injection restricted to the exact managed main-document root; suspend it for external documents and restore current identity when returning to the managed root. The custom scheme is not the original HTTP(S) origin. Existing H5 adapters must explicitly retain original HTTP(S) API identity, authenticated state, Cookie coordination, Bridge and navigation behavior.

The handler maps only exact original static-root GET requests. Missing/read-failed/Range/disabled resources fall back to that original HTTP(S) URL, keeping query, headers, real status, MIME and bytes. It does not proxy business POST/API or foreign navigation. Default fallback uses no Cookie/credential stores or URLCache; authenticated static resources require explicit controlled networkConfiguration and host WK Cookie coordination. No CORS/CSP/TLS/ATS weakening is provided. Per-task cancellation and disposal reject late callbacks and produce at most one terminal event.

## Installation statistics and validation

outcomeHandler has one process consumer. It delivers success once only after ready was actually persisted, including when cold activation is pending. Failure is emitted only after actual Remote HTTP attempt (before even zero-byte connection failure), Local input open attempt after output preflight, or verified ZIP processing after SHA preflight. The historical requestStarted property denotes this package-processing boundary, including Local/reuse; it does not imply a network request. Configuration, registration and ZIP preflight before this boundary are diagnostic only, while preparation retry quota is still updated independently. Real download, verification, extraction, file and ready-write categories remain; ready row0 is StorageWrite/publish. Cancellation, activation, repeated ready queries, progress and resource failures do not add installation reports. Delivery is best effort; there is no persisted queue or backend exactly-once guarantee.

The generic Demo uses synthetic A/B packages and loopback API/Bridge data. B success records ready-awaits-cold-start; new pages are online while old A stays fixed. A separate true cold launch activates B. Native real SQLite tests, in-memory test seams, actual WebKit simulator observations, final binary consumers and physical-device/business/backend acceptance are distinct evidence. A missing device or iOS15 runtime must be recorded as unverified.

build_release.sh rebuilds the VERSION-matched formal device/simulator XCFramework and calculates the final ZIP checksum for Package.swift. generate_consumer.py links only the specified XCFramework. create_local_candidate.py remains a separate local verification tool: its marketing metadata is 0.0.0 with OFTLocalCandidateIdentity and is not a formal release. Private verification directories are never copied into public source inputs or release packaging. See SPM.md for the immutable release workflow.
