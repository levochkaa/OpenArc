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

JavaScript alert/confirm/prompt ownership and presentation are covered by [mobile-javascript-dialogs.md](mobile-javascript-dialogs.md). Shared profile/SQLite/sync and native reorder were added later; see [mobile-shared-sync.md](mobile-shared-sync.md) and [mobile-reorder.md](mobile-reorder.md) for their current contracts and the ledger for completed proof.

## Native Find in Page

Find uses the selected WKWebView's existing `UIFindInteraction`. WebKit owns the search field, matching, result count, highlighting and next/previous navigation. The browser does not inject a JavaScript text walker, copy page content into another index or replace WebKit's find/navigation/UI delegates. The API and native keyboard behavior follow Apple's [WKWebView find interaction introduction](https://developer.apple.com/videos/play/wwdc2022/10049/), checked with Xcode 26.6 headers on 2026-10-03. The action is required by the user scope.

The toolbar's Find in Page action and Cmd+F enter through the current page. Address editing ends without submitting the draft. Only an existing selected, mounted and eligible document may start Find; a background or unloaded tab is not instantiated for it. The query and results are transient view state, with no session or sync operation. Same-document fragment navigation retains the document's search context; replacing a document, changing/removing its tab, scene deactivation, failure/shutdown or a competing modal closes Find. WebKit's native Find shortcut is disabled outside the admitted context so it cannot reopen a hidden panel behind other UI.

Hosted verification uses actual WK HTML and the public native interaction/session after invoking the real action. It distinguishes presenting the panel, finding matches, selecting next/previous results and zero results. Bounded waits are required because presentation and matching have no completion callback. Keyboard action dispatch and layout checks are separate from physical hardware-key/touch verification.

Remaining mobile work includes auto-archive; browser split; full scene/external-link routing; private browsing; auth/permission presentation, uploads/downloads and site settings; background/memory recovery; and observed gesture/visual polish. Find implementation and verification status belong in the ledger. No placeholder controls claim these features exist.


## Durable local Archive

Explicit Close on a Today tab, including the sidebar swipe/context action, stores a profile-local recovery entry. The Archive button in the tab sheet/sidebar opens a native UIKit list. Pinned/Favorite close still unloads that window's runtime. Engine close, incoming remote deletes and folder/Space cascades do not implicitly archive anything. Closing the last Today tab leaves an empty Space without creating a blank tab.

The shared document reads the latest logical row; a runtime page title is accepted only when its URL matches that row. SQLite commits the archive entry, active deletion and sync outbox together. Restore consumes that entry and creates a fresh temporary-tab identity in one transaction. It preserves the saved URL and title override, sets activity to now and keeps the original identity's tombstone. The original Space is used when available; otherwise the user must select an existing Space. A Space is never recreated implicitly. Restore reloads the URL; it does not restore WebKit back-forward history.

Archive entries are local to the profile and shared by its windows. Only active deletion/new-tab creation enter sync; archive payloads and receipts are not sent to the server. An exact repeated archive/restore receipt skips its old full snapshot, so it cannot overwrite later edits. A second restore with a different ID fails. Compact receipts remain durable in a separate table, with an entry fingerprint and optional restored ID; consumed or explicitly deleted entries retain no active payload or search text. Parent deletion that filters the proposed restored tab rolls back consumption too. Legacy JSON/ephemeral stores reject archive effects; their existing close behavior remains and their Archive button is hidden.

A failed archive/restore SQL transaction retains the fixed archive/action IDs in the existing bounded FIFO and blocks sync. The visible tree may reflect the admitted action, but the Archive sheet stays open with an error and Retry after failed restore. Further archive/restore actions wait for pending writes; ordinary edits can join the ordered retry tail. Successful Retry updates the list and other windows. This queue remains in memory: process termination before recovery can lose unsaved actions, while the last durable state remains intact. This slice does not solve crash-durable failed-write recovery.

SQLite reads use a timestamp/ID keyset and a maximum of 100 entries; UIKit displays 50-entry pages with Older/Newer controls. Archive list/search/clear/delete reads and writes use asynchronous GRDB operations, with SQL work on the database queue. Committed archive changes reset open lists to the first page. Selection and action callbacks revalidate current IDs. Missing-Space choice waits for its native picker dismissal before restoring and dismissing the Archive sheet. Errors, empty state, Dynamic Type and native iPad popover anchoring are present.

The choices above are TheBrowser policies.

Retention, automatic archiving and desktop durable archive remain separate work. Archive records and compact receipts have no automatic expiry. Local activity and attached-window protection are defined below; expiry still needs a cross-device policy and restart/sweep timing. Native callback execution does not establish physical gesture quality or OS scene behavior.


### Archive search and removal

The native search field matches a literal substring independently in saved URL, custom title or loaded title. Matching folds Unicode case and diacritics with a fixed locale; percent and underscore are ordinary characters. Queries are limited to 256 characters and 4096 UTF-8 bytes. The UI waits 200 ms after input and does not issue queries for marked IME text. Query, page and archive revision changes cancel the earlier read; generation checks also reject a stale response that ignores cancellation. Cancel/Escape returns to the full list, while Done closes the Archive even when search is active. Empty, loading, no-match and error states remain distinct. Search SQL can scan archive rows, but it neither decodes all payloads nor runs on MainActor; no large-profile latency bound is claimed.

Swipe Delete removes only that captured archive entry. Full-swipe execution is disabled. Clear Archive requires native confirmation and applies to the whole archive, including entries hidden by a query. Before presenting confirmation, SQLite captures a monotonic insertion sequence. The operation removes only content at or below that sequence: a tab archived afterward survives even if the clock moved backward. Cancel makes no write. A failed removal leaves its contents intact and exposes Retry for the same entry or captured clear boundary; a failed boundary read retries capture and asks for confirmation again.

The profile document serializes Archive mutations across windows. Restore, another deletion and explicit archive close wait while a removal is in flight; ordinary navigation, selected-tab state and current-tab persistence remain usable. Successful completion increments the shared archive revision and refreshes other windows. Delete/Clear never write an active snapshot, sync queue, cursor or baseline. If ordinary persistence fails independently, its FIFO/error is retained.

The migration separates legacy active content from receipts and removes consumed payloads from the active table. Receipts use SHA-256 over a canonical encoding to recognize an exact insert; a consumed restore also remembers its fresh tab ID. An old insert cannot recreate cleared content, and a delayed same-ID restore cannot reinstall its old snapshot. Compact receipts and permanent sync tombstones remain. Logical content removal is not a secure-erasure claim for SQLite free pages, WAL files or backups. Migration still runs in the existing synchronous store-open path; opening a very large legacy archive has not been profiled.

The native mobile interaction and captured confirmation scope above are TheBrowser's own design.

## Tab activity and attached windows

An active connected window records both the tab it leaves and the tab it selects when the user switches tabs or Spaces. An explicit later click on the already selected tab also counts as activity. Entering active state records its selected tab; leaving active state records the final viewing instant. Repeated lifecycle callbacks do not write. If activation arrives before asynchronous profile loading completes, the selected identity is recorded after hydration. Loading an inactive/disconnected workspace and applying a remote projection do not fabricate activity. Explicit Close on the selected tab records the surviving fallback; missing/deleted IDs are ignored. Engine close and remote deletion update selection protection without an activity echo.

The document samples one time for each group of activity updates and uses the existing ordered SQLite/sync write path. Patches contain activity only. They do not share a window's selection or instantiate/navigate another window's page. An accepted move from pinned/Favorite into Today also advances activity in that same move transaction, so unpinning does not retain an old idle time. Ordinary URL changes use the same local monotonic rule. A whole-second timestamp must be strictly newer than the current known value; same-second callbacks and clock rollback do not write activity, and unchanged fractional stored values survive other local edits. Unknown timestamps can acquire a value on actual use. Future known timestamps remain conservative. The existing bounded failed-write FIFO and visible Retry apply; crash-durable recovery of failed writes remains open.

Each workspace has an independent selection lease in its profile document. All attached windows protect their selected live tab, including inactive/background windows. Disconnect, discard and shutdown release the lease even when the workspace remains retained for save recovery. Replacing a scene connection preserves selection, and the registry's attachment token rejects stale activation/disconnect callbacks. A remote deletion/fallback refreshes the lease without emitting an activity patch; deleted identities are excluded. Leases are in memory, are never synced or persisted, and do not by themselves enable an expiry sweep.

Local monotonicity is not a cross-device maximum. V4 still orders canonical updates by server sequence and assigns the received activity value; a delayed older activity patch can replace a newer one. Even a conditional server delete could protect only activity already reported to the server, not an active completely offline device. Automatic archiving stays disabled until the product defines that case and the protocol enforces the chosen policy. Whole-second wire precision, synchronous snapshot persistence and unprofiled large-profile activity cost remain existing limits.

The lifecycle and lease rules above are TheBrowser policy. Scene-registry callbacks and controlled clocks are testable independently of OS scene delivery.
