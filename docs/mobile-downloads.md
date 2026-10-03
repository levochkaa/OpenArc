# Mobile Downloads

The mobile browser hands WebKit downloads to a coordinator owned by the logical profile. A UIKit Downloads list shows progress, Cancel, persistence errors and completed files with Save to Files. Download files and metadata remain local; this feature adds no sync messages.

## WebKit handoff and page state

`BrowserWebKitEngine` handles explicit download actions, including generated `blob:`/`data:` files, and main-frame attachment or unsupported-MIME responses. Both navigation-to-download callbacks validate the captured runtime, navigation generation and profile coordinator before adopting the original `WKDownload`. Stale handoffs are cancelled. WebKit retains the request context; the app does not fetch the URL again. Existing navigation/UI delegates and TLS defaults remain in place. See Apple's [navigation response handoff](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webview(_:navigationresponse:didbecome:)) and [WKDownloadDelegate](https://developer.apple.com/documentation/webkit/wkdownloaddelegate) contracts, also checked against the Xcode 26.6 SDK headers.

Link/form downloads retain the source document, runtime and browser history. A response converted into a download restores the last committed page state and suppresses the converted navigation's late callbacks. An address explicitly submitted by the user is already a logical navigation intent: it may journal the requested URL before conversion restores the final source URL. That path does not promise an unchanged outbox. Back, Forward and subsequent fragment navigation remain available on the same WebView. WebKit may finish the download before its provisional URL accessor returns to the source URL; the browser state, committed DOM and history stay on the source during that interval.

Generated downloads use a safe source-page URL when available. The coordinator also sanitizes the original-request fallback: only HTTP(S) URLs with a host or `about:blank` can become durable provenance. Blob tokens, data payloads and file URLs are never persisted as download provenance. This is a scheme restriction, not general redaction of HTTP URL queries.

## Profile lifetime and storage

The profile owns transfers independently of a tab, engine or mounted scene. Once adopted, a transfer can finish after its source tab or engine closes. This does not grant background execution or survival across process termination.

The disk actor assigns each download a UUID directory and a sanitized display filename, limited to 200 UTF-8 bytes. Equal filenames occupy different directories without overwriting one another; the app does not add numeric filename suffixes. WebKit receives a nonexistent destination inside an existing writable directory.

A finished transfer enters **Saving…** until its completed record is atomically written to `downloads.json`. Completed entries record the actual file size. The manifest is limited to 8 MiB. A commit failure keeps the file and a retryable pending completion in the running process; Retry repeats persistence without downloading again or duplicating the entry. Initial storage-load and cleanup failures also expose Retry.

Only committed completed records survive reopening. After validating the manifest, startup removes uncommitted UUID directories as interrupted transfers. Pending completion intent is not durable across a crash before manifest commit. A malformed manifest fails closed without deleting its files. Missing files or symlinks cannot be exported. Completed files have no automatic expiry in this slice.

## UIKit ownership and export

The page's Downloads button and Command-Option-L open its profile's list. Rows use Dynamic Type and native controls: Cancel while downloading, no action while saving, Save to Files after durable completion, and explicit failed/cancelled states. Persistence Retry does not restart network transfers.

Save to Files captures the entry UUID and requesting window, validates the file asynchronously, then rechecks the entry, attempt identity, active scene and presentation owner. Reordering rows cannot change the exported file. A stale completion cannot present from a hidden, dismissed, disconnected or superseded owner. Export uses a real `UIDocumentPickerViewController(forExporting:asCopy:)` with `asCopy: true`; the app-owned original remains available. See Apple's [document picker API](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller).

A full-screen child can temporarily detach the list's view. That does not end its observation or invalidate an existing picker; dismissal/removal of the Downloads controller does. The list remains usable when the child returns. Controller deinitialization also removes its observation and cancels pending tasks when scene teardown releases a window without dismissal callbacks.

## Verification and remaining scope

The added tests target these contracts:

- [BrowserWebKitDownloadsTests](../Tests/TheBrowseriOSTests/BrowserWebKitDownloadsTests.swift): real WebKit and localhost transfers, exact bytes, redirects, cookie-authenticated POST bodies, generated files, source/history preservation, cancellation, truncation, engine lifetime and persistence retry.
- [BrowserMobileDownloadsTests](../Tests/TheBrowseriOSTests/BrowserMobileDownloadsTests.swift): disk reopening, filename isolation, provenance filtering, malformed manifests, interrupted-file cleanup and unsafe export rejection.
- [BrowserMobileDownloadsViewControllerTests](../Tests/TheBrowseriOSTests/BrowserMobileDownloadsViewControllerTests.swift) and [composition tests](../Tests/TheBrowseriOSTests/BrowserMobileDownloadCompositionTests.swift): native controls, picker configuration, profile ownership and late asynchronous presentation guards.

Root and mobile Build/Test gates passed on 2026-10-03 with Xcode 26.6; the full iPhone and iPad suites each passed 204 declarations / 228 runs, with five opt-in HTTP skips. Hosted tests inspect the real picker configuration through an injected presenter and present/dismiss a real full-screen covering controller; they do not operate the physical Files UI. Simulated scene notifications do not establish OS background-delivery behavior.

Active-transfer restart/resume, guaranteed background delivery, Delete/Clear, redownload, custom download authentication and dedicated Wallet handling remain follow-ups. Real Files-provider interaction and device lifecycle behavior need separate verification.

