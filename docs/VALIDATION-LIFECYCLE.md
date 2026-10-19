# Managed lifecycle validation

This document defines the SDK regression and integration evidence boundaries for 0.3.1. Exact commands, results and binary identities belong to each validation run; historical local-candidate results do not establish formal-release or business acceptance.

## Native regression

Run the real Objective-C/Swift implementation with SQLite, including all standalone and managed test classes:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project OfflineTool.xcodeproj -scheme OfflineTool -destination 'platform=macOS' \
  -derivedDataPath "$OUT/native" -resultBundlePath "$OUT/native.xcresult" \
  CODE_SIGNING_ALLOWED=NO
```

Use a fresh private output directory and preserve logs, exit code, xcresult and source hashes. Do not exclude the standalone 120-second timeout case from a claimed complete regression. Managed downloads have no artificial total deadline.

The storage matrix covers the real three-column schema and partial unique indexes, transaction rollback, immutable SHA registration before eviction, exact-one-row ready writes, whole-container-relative database relocation, CORRUPT/NOTADB quarantine, ordinary read failure and orphan-journal preservation. Query-time corruption tests keep the SQLite header/schema readable, corrupt a real data page, observe the actual SQLite failure through production storage calls and retain the corrupt bytes. Invalid logical rows are not treated as physical SQLite corruption. A failed query remains a failure; a later ordinary entrance can reopen storage. Runtime recovery must protect the in-memory active directory and avoid a second cold cleanup or activation.

Lifecycle tests cover first/non-first preparation, stable ZIP reuse, ready/cold activation, fixed active package, same-version conflicts, owner/waiter cancellation, immediate reentry after canceled cold loading, foreground admission/checkpoints, ordinary-background continuation after silent Checking, privacy cancellation, retry quota/Retry-After and statistics boundaries.

Package-processing tests use real local files and loopback HTTP for refusal before bytes, status classes, truncated responses without fabricated status, SHA/archive/file failures, ready-write failures and success. Local/reused ZIP processing is distinct from a network request. The unknown-length producer preserves its final byte tail without inventing a percentage. Real ZIP output close failures remain file failures; cancellation and an earlier primary failure retain their classifications. Extracted files use checked writes, fsync and close. Output-creation and injected close tests establish their stated boundaries, not every possible disk or filesystem failure.

Valid managed capacity fixtures test actual output above the historical standalone limits: a 67,108,865-byte file, 10,001 regular files, and 272,629,762 total extracted bytes. They contain real deflated content and valid CRC values. Standalone compatibility tests retain their original limit rejections; managed mode retains path, symlink, structural, CRC and SHA protections.

Handler tests cover original URL/root bounds, streaming, Range/headers, MIME/status, redirects and late-callback cancellation. These tests do not prove real business gateway receipt.

## Separate evidence boundaries

macOS native tests and test-clock scheduling do not prove iOS15, a physical device, natural five-minute timing, a true cold process, final iOS binary consumption, actual WK cache effects or business login/Bridge/API behavior. Bind each result to its actual binary, source inputs and runtime. A signed/unsigned build is separate from an executed application.

The synthetic Demo/consumer can observe first and later launches, A remaining bound while B is ready, online new pages under the newer policy, and B activation in a separate true cold process. It retains synthetic Cookie/identity and localStorage probes. Keep physical-device/business/backend acceptance separate, and record missing conditions as unverified. Existing page failures must not be closed automatically after an SDK upgrade.
