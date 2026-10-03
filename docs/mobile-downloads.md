# Mobile Downloads

The mobile browser hands WebKit downloads to a coordinator owned by the logical profile. A UIKit Downloads list shows progress, Cancel, persistence errors and completed files with Save to Files and individual Delete. Download files and metadata remain local; this feature adds no sync messages.

## WebKit handoff and page state

`BrowserWebKitEngine` handles explicit download actions, including generated `blob:`/`data:` files, and main-frame attachment or unsupported-MIME responses. Both navigation-to-download callbacks validate the captured runtime, navigation generation and profile coordinator before adopting the original `WKDownload`. Stale handoffs are cancelled. WebKit retains the request context; the app does not fetch the URL again. Existing navigation/UI delegates and TLS defaults remain in place. See Apple's [navigation response handoff](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webview(_:navigationresponse:didbecome:)) and [WKDownloadDelegate](https://developer.apple.com/documentation/webkit/wkdownloaddelegate) contracts, also checked against the Xcode 26.6 SDK headers.

Link/form downloads retain the source document, runtime and browser history. A response converted into a download restores the last committed page state and suppresses the converted navigation's late callbacks. An address explicitly submitted by the user is already a logical navigation intent: it may journal the requested URL before conversion restores the final source URL. That path does not promise an unchanged outbox. Back, Forward and subsequent fragment navigation remain available on the same WebView. WebKit may finish the download before its provisional URL accessor returns to the source URL; the browser state, committed DOM and history stay on the source during that interval.

Generated downloads use a safe source-page URL when available. The coordinator also sanitizes the original-request fallback: only HTTP(S) URLs with a host or `about:blank` can become durable provenance. Blob tokens, data payloads and file URLs are never persisted as download provenance. This is a scheme restriction, not general redaction of HTTP URL queries.

## Profile lifetime and storage

The profile owns transfers independently of a tab, engine or mounted scene. Once adopted, a transfer can finish after its source tab or engine closes. This does not grant background execution or survival across process termination.

The disk actor assigns each download a UUID directory and a sanitized display filename, limited to 200 UTF-8 bytes. Equal filenames occupy different directories without overwriting one another; the app does not add numeric filename suffixes. WebKit receives a nonexistent destination inside an existing writable directory.

A finished transfer enters **Saving…** until its completed record is atomically written to `downloads.json`. Completed entries record the actual file size. The manifest is limited to 8 MiB. A commit failure keeps the file and a retryable pending completion in the running process; Retry repeats persistence without downloading again or duplicating the entry. Initial storage-load and cleanup failures also expose Retry.

Only committed completed records survive reopening. After validating the manifest, startup attempts to remove uncommitted UUID directories as interrupted transfers. Cleanup failures remain retryable without hiding valid completed downloads. Pending completion intent is not durable across a crash before manifest commit. A malformed manifest fails closed without deleting its files. Missing files or symlinks cannot be exported. Completed files have no automatic expiry in this slice.

## Individual deletion

Delete is available through a destructive swipe action with full swipe disabled, a context menu and an accessibility action. A native confirmation identifies the captured filename and explains that copies already saved to Files remain. Cancel makes no removal request. Confirm rechecks the original window, current entry UUID and profile-wide eligibility after the alert dismisses; row reordering or reuse cannot retarget it.

Eligibility follows durable membership. A completed record whose file is now missing can still be deleted, even though its row displays Failed. Active transfers, pending completion commits and files held by an export lease cannot be deleted. A stale or busy confirmation does not queue a future removal.

Removal atomically writes the remaining manifest before deleting the UUID directory. A manifest-write failure leaves both record and file unchanged. Retry retains the exact failed UUID in the running coordinator; newly completed downloads are unaffected. This pre-commit retry intent is not persisted across process termination, so reopening retains the original record until another explicit removal.

After the manifest commits, the row is removed in every observing window. A file-cleanup failure does not reverse that result: it becomes a cleanup backlog with Retry. Reopening reconstructs that backlog from UUID directories absent from the valid manifest. Published disk states carry actor-ordered revisions, so a late read or completion cannot restore an older list or cleanup state. These revisions coordinate the running process; they are not a new manifest version.

## UIKit ownership and export

The page's Downloads button and Command-Option-L open its profile's list. Rows use Dynamic Type and native controls: Cancel while downloading, no action while saving, Save to Files after durable completion, and explicit failed/cancelled states. Persistence Retry does not restart network transfers.

Save to Files captures the entry UUID and requesting window. The coordinator reserves a unique export token before asynchronous file validation, blocking Delete across all windows of that profile. Presentation then rechecks the entry, attempt identity, active scene and owner. A cancelled or stale acquisition releases its exact token, including when the requesting controller has gone away. An old or duplicate completion cannot release a newer export's token.

Export uses a real `UIDocumentPickerViewController(forExporting:asCopy:)` with `asCopy: true`. The picker strongly owns its lease and handles its own success, cancellation and adaptive-dismissal callbacks independently of the Downloads controller. Those callbacks finish the lease idempotently; picker deinitialization is the final cleanup path. Multiple pickers hold independent tokens, and Delete remains blocked until all tokens for that file finish. A failed removal also reserves the file against export until removal is retried. See Apple's [document picker API](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller).

A full-screen child can temporarily detach the list's view without ending its observation. Definite dismissal or deinitialization stops the list's observation and pending preparation, but does not finish a picker-owned lease. Coverage, scene inactivity and programmatic view disappearance are not treated as picker completion. Forced picker teardown eventually releases its lease through object destruction; this is not a documented guarantee that an external Files provider has finished copying.

## Verification and remaining scope

The added tests target these contracts:

- [BrowserWebKitDownloadsTests](../Tests/TheBrowseriOSTests/BrowserWebKitDownloadsTests.swift): real WebKit and localhost transfers, exact bytes, redirects, cookie-authenticated POST bodies, generated files, source/history preservation, cancellation, truncation, engine lifetime and persistence retry.
- [BrowserMobileDownloadsTests](../Tests/TheBrowseriOSTests/BrowserMobileDownloadsTests.swift): disk reopening, filename isolation, provenance filtering, malformed manifests, interrupted-file cleanup and unsafe export rejection.
- [BrowserMobileDownloadsViewControllerTests](../Tests/TheBrowseriOSTests/BrowserMobileDownloadsViewControllerTests.swift) and [composition tests](../Tests/TheBrowseriOSTests/BrowserMobileDownloadCompositionTests.swift): native controls, picker configuration, profile ownership and late asynchronous presentation guards.
- [BrowserMobileDownloadRemovalIntegrationTests](../Tests/TheBrowseriOSTests/BrowserMobileDownloadRemovalIntegrationTests.swift): two controllers sharing a real coordinator, independent picker leases, retained picker after list destruction, durable removal/reopen and Retry from another window. [Deletion storage tests](../Tests/TheBrowseriOSTests/BrowserMobileDownloadDeletionTests.swift) and UIKit tests also cover manifest/cleanup failure, late-state publication, captured confirmation IDs, Cancel, busy rows and missing-file removal.

The original download/export slice passed root and mobile Build/Test gates on 2026-10-03 with Xcode 26.6: each full iPhone/iPad suite passed 204 declarations / 228 runs, with five opt-in HTTP skips. The subsequent deletion slice passed mobile Build and the full iPhone/iPad suites: 218 declarations / 246 runs, five opt-in HTTP skips and zero failures per device.

Hosted tests inspect real picker configuration, invoke its native delegate callbacks and present/dismiss a real full-screen covering controller. Confirmation tests verify the presented alert and call the same production callback installed on its native action. They do not operate the physical Files UI or establish provider-copy completion after forced teardown. Simulated notifications and multiple windows in the test host's scene do not prove real OS multi-scene or background-delivery behavior.

Active-transfer restart/resume, guaranteed background delivery, bulk Clear, redownload, custom download authentication and dedicated Wallet handling remain follow-ups. Real Files-provider interaction and device lifecycle behavior need separate verification.

