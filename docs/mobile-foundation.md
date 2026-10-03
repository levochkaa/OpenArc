# UIKit and WebKit foundation

## Scope and references

This is the first working iPhone/iPad slice, not the full mobile app. The required path is address/search → page loading → navigation → tabs → persistence → restoration. Mobile Spaces/pins, archive, search and gestures come later. The iPad layout is our own design.

The old `7c4ed73` SwiftUI shell was not carried forward. Its default-store-only engine, regenerated restoration IDs and silent persistence errors were unsuitable. The new target reuses the desktop URL resolver, search-engine definitions and translations, plus existing DomainParser credits. Desktop CEF flags stay on macOS targets; mobile commands do not stage CEF or Sparkle.

## Ownership and navigation

`BrowserMobileWorkspace` owns stable tab IDs, URL/title, order and selected identity. Runtime IDs belong to one `BrowserWebKitEngine`; restoring a file generates fresh runtime IDs while preserving stable IDs. Logical identities exist before synchronous engine events. A closed runtime cannot recreate a tab through a late callback.

The engine registers restored tabs without creating WKWebViews. Selection or an explicit navigation creates a view; visited background tabs retain their history. Only the selected view is mounted. Callbacks revalidate view identity and navigation generation, and queued observations read current values. Failed loads and a web-content-process termination callback expose Retry; the latter is distinct from detecting or testing a real process kill.

Popup construction preserves WebKit's supplied configuration and lets WebKit perform the load. This follows Apple's [WKUIDelegate contract](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:createwebviewwith:for:windowfeatures:)). Website data stores are injected; ordinary production scenes use the persistent default store. Nonpersistent stores in tests prove isolation, not a completed private-browsing UI. TLS/auth use WebKit defaults. Unsupported schemes produce an error instead of launching an external application or showing mock internal pages.

## Storage and scene lifetime

`BrowserMobileFileSessionStore` performs Codable validation and atomic file writes on an actor. The version-1 envelope stores stable IDs, URL/title, order and selected identity. Unknown versions, malformed files, duplicate IDs or unsupported stored URLs do not grant permission to overwrite existing bytes. The file limit is 8 MiB. Errors remain visible with Retry.

The workspace serializes writes through one worker and one replaceable pending full snapshot. A failed write retains the latest state until explicit Retry. This is local session persistence, not the immutable sync operation/outbox contract. Mobile backend sync and migration to the shared sync storage remain separate work.

`BrowserMobileSceneSessions` keeps one workspace/store/engine per UIKit session. Disconnect and reconnect reuse that instance, including a failed pending save, so there is no second writer for the same file. Attachment tokens reject stale disconnects. Explicit session discard closes the engine and waits for in-flight writes before allowing same-ID replacement. An already failed save is not retried automatically; the scene file remains on disk. Failed writes leave the prior file intact; forced termination or explicit session discard can lose unsaved in-memory edits. Disconnected visited WebKit views currently remain allocated until discard; memory-pressure eviction is still required.

## UIKit behavior

The scene owns its window. A split controller provides the wide sidebar and compact tab sheet; layout follows current size classes rather than device identity or global screen bounds. Narrow portrait windows place chrome below the page. Wide/short windows place it above. Safe-area constraints and [UIKeyboardLayoutGuide](https://developer.apple.com/documentation/uikit/uikeyboardlayoutguide) reserve space for content and input. Reordering chrome keeps it in the view hierarchy to preserve address editing during resize.

Tabs expose selection, creation, swipe/context-menu close and captured-ID actions. The address field preserves an active query across updates to the same tab, clears that draft when selection changes, supports Return and Escape, and avoids submitting marked IME text. Controls include back/forward/reload/stop, share, keyboard shortcuts and accessibility labels. Cmd+R always reloads; the toolbar button stops an active load and reloads an idle page. Error/empty/loading states are connected to the model. The app has a launch screen, all iPad orientations, multiple scenes and no full-screen opt-out.

## Verification and remaining work

Use `./build.sh ios-build` and `./build.sh ios-test --ios-destination 'platform=iOS Simulator,id=UUID'`. Mobile output uses `.build/xcode-ios`; desktop Build/Test remain mandatory. The separate `BrowserMobileTestHost` has no browser bootstrap and supplies a real UIWindowScene for console UIKit/WebKit tests. Tests must not launch the TheBrowser product or move the user's desktop pointer.

Proof is split between actual local WebKit navigation, model/file/scene regressions and native controller layout/input checks. On 2026-10-03, Xcode 26.6 / iOS Simulator 26.5 passed all 26 test declarations (29 parameterized runs) on both iPhone 17 Pro and iPad Air (5th generation), without failures, skips or compiler warnings. The composed case uses actual UIKit address submission, a localhost WebKit page and link, Back/Forward, tab actions, atomic JSON and a fresh workspace/engine restore. Desktop Build/Test also passed: 570 tests, 15 opt-in skips, zero failures. Compilation alone does not prove WebKit or UI behavior; manually operated product/Stage Manager/device flows remain unverified. Scene tests call the real registry directly; AppDelegate/SceneDelegate wiring is compile-verified, not an observed OS disconnect/reconnect/discard flow.

Next mobile work includes Spaces/pinned/archive and shared backend sync; tab reorder; browser split; full scene/external-link routing; private browsing; JS dialogs, auth/permission presentation, uploads/downloads, find and site settings; background/memory recovery; and observed gesture/visual polish. No placeholder controls claim these features exist.
