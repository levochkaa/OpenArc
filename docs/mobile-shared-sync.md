# Mobile shared profile and sync

## Implemented boundary

A phone or tablet shows mobile tabs, a list of its own that every mobile device of the account shares and that computers only read; [mobile tab sync](sync-mobile-tabs.md) describes the list and protocol v7. The Space snapshot below still syncs and feeds the Spaces picker, whose tabs open as mobile tabs; no Space tab gets a WebKit runtime of its own.

The UIKit app now uses one `BrowserMobileProfileDocument` per local profile, shared by all scenes through `BrowserMobileProfileRegistry`. It owns the complete logical Space/folder/tab snapshot and SQLite writes. `BrowserMobileWorkspace` is a scene adapter: stable logical tab IDs map to independent WebKit runtime IDs, selection, navigation history and dialogs. Scenes submit stable-ID actions against the current document; they never overwrite it with independent full-window snapshots.

The document uses the existing v4 folder reducer, canonical projection and typed move intent. Create, rename, pin, Favorite, move and explicit remove write the full snapshot with immutable outbox intent through `BrowserSessionWrite`. Folder moves carry roots; subtree deletion uses current membership. Failed writes remain in the bounded FIFO with their origin/order, block the coordinator and expose Retry in every scene. A terminal overflow rejects the new action before changing visible state. In-memory failed writes still cannot survive process termination; keep the existing recovery limitation explicit.

UIKit provides a Space picker, New Space, Favorites/Pinned/Today sections, nested and empty folders, expansion, New Folder/Subfolder, Rename, Pin/Unpin, Favorite, Move To and explicit Remove. The same controller appears in the iPhone sheet and iPad sidebar. Captured menu actions resolve stable IDs against current state. Native drag reorder is described in `mobile-reorder.md`; durable local Archive is described in `mobile-foundation.md`. Archive entries stay local while close and fresh-ID restore use the existing sync protocol.

Remote metadata/order changes preserve surviving WebKit views and history. Remote deletion unregisters identity before engine teardown; late callbacks cannot recreate it. Empty remote state stays empty. Unsupported desktop URLs remain durable records and show an unavailable-address state without WebKit loading them. Entering a supported address creates or navigates once after document admission.

Ordinary Close/Cmd+W and `window.close()` remove temporary tabs. For pinned/Favorite tabs they unload only that scene's runtime; the shared record and other scenes survive. Explicit sidebar Remove deletes the shared identity. Selecting an unloaded persistent tab creates a fresh runtime. User title overrides remain separate from real page titles, so clearing Rename restores each scene's current page title.

## Shared platform code

Both iOS targets compile the same Foundation wire types, v2/v3/v4 projections, immutable outbox, SQLite store, coordinator and HTTP transport used by macOS. `project.yml` explicitly lists shared sources and reuses GRDB, Gzip, HTTPTypes, OpenAPI runtime/URLSession and generation from the existing backend schema. No mobile protocol fork exists.

`BrowserSessionDefaults` removes shared references to the AppKit model. `BrowserSyncDeviceIdentity` is supplied by the platform composition root. Shared account state and Apple identity protocols live separately from the AppKit presenter. `BrowserAuthSessionNamespace` retains exact desktop Keychain names while allowing an explicit mobile namespace. Sync error reporting is injected; the desktop root keeps its existing telemetry mapping. `loadSnapshotStrict()` lets mobile restoration distinguish an empty profile from a failed read.

`BrowserMobileProfileRegistry` also owns one `BrowserMobileSyncSession` for the profile. That session composes the shared account store, production HTTP client and coordinator; the document remains the coordinator's sole snapshot applier. The document's link back to the session is weak. Scenes contribute foreground activity, with attachment guards rejecting callbacks from an old scene connection. The last inactive scene suspends transport without removing credentials, changing durable Pause or discarding queued writes. A later active scene resumes polling and queue delivery only when sync is enabled.

## Account and server configuration

The Tabs controller exposes Account on both iPhone and iPad. Its sheet provides server configuration, Sign in with Apple, explicit Enable Sync consent, Pause/Resume, Sign Out, errors and Retry. The Apple provider anchors authorization to the caller's active window. Cancellation and stale-result guards prevent dismissed or superseded requests from writing credentials. Account state is shared across scenes; each presentation owns its sign-in attempt.

Server selection uses `OPENARC_SYNC_BASE_URL` from the process environment, then the saved mobile server preference, then the packaged `OpenArcSyncBaseURL` Info.plist value. The packaged value comes from the `OPENARC_SYNC_BASE_URL` build setting, `https://api.openarc.su` unless a build sets another or leaves it empty. The Account sheet saves a canonical root URL. HTTPS is required except for HTTP loopback testing; paths, credentials, query strings and fragments are rejected.

Mobile credentials use the explicit Keychain namespace `.profile("mobile")`. A profile binds durably to the normalized server URL and user ID after consent. Signing out preserves the owner, cursor, baseline and immutable queue, pauses sync and attempts to remove credentials. Another account or server cannot silently adopt those records. Local persistence failure blocks transport until the document's buffered writes commit successfully.

**Pause and Sign Out:** the shared account lifecycle distinguishes a transport pause from a profile-level requirement to sign in again. Explicit Pause preserves credentials and remains paused after reopening the profile. Publishing that cached paused account does not start transport; Resume uses the existing matching session without another Apple request. Foreground activity cannot override the durable pause.

Sign Out invalidates requests, then atomically records the sign-in requirement and pauses the owner-bound transport if one exists. The requirement also persists before Enable Sync, when no owner row exists. Keychain deletion is attempted even if the database write fails. A surviving cached credential cannot authorize ordinary Enable/Resume or background transport while the requirement is set. Only fresh explicit authentication, validated against the server/profile owner and saved to Keychain, can clear it. Unbound profiles still require Enable Sync consent after authentication. Owner, cursor, snapshot and immutable queue are preserved.

Old paused profiles cannot reveal whether the user paused or a past Keychain deletion failed. Migration therefore requires a fresh sign-in for those ambiguous records. Marker read errors fail closed. If both the database write and Keychain deletion fail, Sign Out reports both failures; durable protection after termination cannot be guaranteed.

The iOS target declares `com.apple.developer.applesignin` in `Support/OpenArciOS.entitlements`. Signing capability, provisioning and cross-app Apple subject/account grouping still require verification with provisioned desktop and mobile clients. Adding the local entitlement does not provision an Apple account or establish production authentication.

The backend accepts an optional explicit `APPLE_CLIENT_IDS` comma-list. Entries are trimmed and deduplicated; empty entries, wildcards, URL-shaped values and malformed identifiers fail configuration. The list replaces the single `APPLE_CLIENT_ID` fallback; it never adds a mobile audience automatically. Compose forwards the list only when configured. See `Backend/.env.example` for the setting and use the exact provisioned client IDs. JWT verification retains Apple's issuer and signing-key checks and requires an allowed audience. Local-JWKS tests exercise signed desktop/mobile audiences and rejected issuer/audience/expiry claims; they do not verify real Apple provisioning.

## Legacy sessions and scene state

Before opening the new `MobileProfile/OpenArc.sqlite`, the registry reads and validates every legacy `MobileSessions/*.json`. Each file becomes a separate Space with stable IDs, tab order and its selected index. Colliding IDs from separate files receive distinct IDs. Cached page titles are refreshed by WebKit; they do not become user rename overrides. Original JSON files, including those cached titles, are kept intact.

`importSessionOnce` commits the logical snapshot and marker in one SQLite transaction. A failed marker write rolls back the imported rows; after successful import, deleting tabs and restarting cannot reimport them. A damaged/unsupported source blocks restoration and shows Retry without replacing either source or durable state. Import into an already account-bound profile fails closed, because existing tombstones require an explicit merge policy. Normal product import precedes account binding.

Scene selection is stored separately under its persistent scene ID. Disconnect/reconnect retains the workspace; discarding a scene releases its runtimes without deleting the registry's document or pending writes. Concurrent first connections await one registry open operation. A fresh local profile creates no Space. A window without mobile tabs opens a blank one, which stays on the device until it opens a page.

User selection and foreground transitions record activity through the shared document's normal v4 write path. Selection itself stays local. Attached windows keep independent in-memory selection protection until disconnect/discard/shutdown, including while backgrounded; retained disconnected workspaces do not keep protection. The [activity contract](mobile-foundation.md#tab-activity-and-attached-windows) defines local capture and leases. The updated server and shared pending reducers preserve the maximum known activity date across v2/v3/v4 writes, including fractional dates; null/omitted activity never erases a known value. Queued bytes, UUIDs, receipts and canonical server-sequence guards remain intact. See [Monotonic tab activity](sync-protocol.md#monotonic-tab-activity).

Snapshot materialization preserves local fractional precision only for the same incoming whole-second value; a different valid canonical date wins. Older servers and client binaries do not provide all these guarantees, historical events/receipts are unchanged, and this change does not repair previously regressed activity values. Completely offline activity remains unknown to other devices. Auto-archive stays disabled until offline-device protection and conditional expiry are defined and enforced.

## Localhost integration fixture

`BrowserMobileSyncHTTPIntegrationTests` uses the profile session, document, scene workspace, real SQLite/outbox and production Swift HTTP transport against the production Rust sync server and PostgreSQL. Its isolated accounts each register two devices through the real device endpoint. The test authorization adapter supplies fixture credentials signed with the server's test secret; it does not contact Apple or exercise a real Apple sign-in exchange.

`mobile-v4-roundtrip` exercises a real WebKit link and Back/Forward navigation, shared tab metadata and nested/empty folders. A second scene shares the document while retaining independent selection and runtime IDs. A folder move from the other device preserves live views/history; a later subtree delete closes affected runtimes in both scenes. An activity-only patch reaches the second client and SQLite reopen while both live pages retain their runtime IDs, history and JavaScript sentinels; touching the subsequently tombstoned ID creates no outbox work. An unsupported desktop URL remains durable without loading. Closing a Today tab writes a local Archive entry and a server tombstone; fresh-ID restore reaches the second device while the old tombstone persists, neither profile receives remote archive entries, and the final state/consumed receipt survive SQLite reopen. `mobile-v4-recovery` covers a committed push with a lost acknowledgement, immutable mutation UUID/payload bytes across reopen, and deletion defeating later stale rename/move intent. `mobile-v4-group-replay` sends one mixed folder/tab root move from the production planner, preserves concurrent remote titles and verifies exact replay after a lost acknowledgement and SQLite reopen. The replay cannot undo a newer move or resurrect a deleted folder/child. `mobile-v4-cross-space` moves a group after remote descendants enter/escape its folder, then deletes the old Space. Moved descendants and loaded page runtimes survive; both clients and SQLite reopen converge without new echo operations. These are test definitions.

The runner creates a disposable PostgreSQL container with no persistent volume and only a loopback port. The test-only proxy can drop or hold an acknowledgement after the real server commits; authenticated HTTP controls expose bootstrap credentials, observations and completion. Unauthenticated static `/mobile-test-page` and `/mobile-test-second` routes provide linked WebKit content for navigation history. Neither fault controls nor these pages are production backend routes.

Simulator tests receive only the control URL/token through `TEST_RUNNER_` environment forwarding and fetch their fixture over authenticated HTTP. They do not read a host fixture path. Credentials stay out of command arguments and ordinary fixture logs. Completion permits the real first-login v2/v3 queue drain, then requires successful v4 writes from both devices in each v4 scenario (plus an accepted v5 expiry in the scheduler scenario). The mobile-v7-tabs scenario instead requires v7 mobile tab writes from both phones and a v7 pull from cursor 0 on each. A missing, skipped or filtered scenario fails the wrapper. The existing desktop HTTP fixture defaults and runner are retained.

## Remaining work

Verify real Apple authentication and account identity across provisioned clients, then separately verify any authorized production deployment. Extend mobile-specific HTTP coverage for paged adoption, device rotation and concurrent subtree/scene lifecycle races; the desktop fixture already exercises broader protocol behavior. Add auto-archive after defining offline-device protection and conditional expiry. Recovery export/import and remaining browser capabilities are separate work; retain native reorder physical-input verification separately. Profile synchronous document/SQLite/reducer work before moving it off MainActor, preserving action ordering and transaction boundaries.

## Verification

Use `./build.sh ios-build`, then `./build.sh ios-test --ios-destination ...` on iPhone and iPad. Tests use the separate `BrowserMobileTestHost`, real SQLite, actual UIKit controls and localhost WebKit pages. Model callback tests use a fake engine to control closure and event order. Existing legacy JSON tests remain as migration/regression coverage; production scenes use the new document.

For the mobile HTTP suite, install Rust, install the backend test dependencies with Node.js 26 and have Docker available, then run this command for each chosen simulator:

```sh
./script/test_mobile_sync.sh \
  --ios-destination 'platform=iOS Simulator,id=SIMULATOR-UUID'
```

The wrapper invokes `./build.sh ios-test` with the mobile HTTP suite selected and checks its completion report. Running the ordinary iOS suite without its fixture environment intentionally skips these network scenarios. The dedicated UIKit test host is used; this command does not launch the OpenArc product.

The shared refactor also requires warning-free desktop `./build.sh build` followed by `./build.sh test` and the existing real Swift HTTP harness. Native menu method/control invocation does not prove physical taps, drag smoothness or OS Stage Manager lifecycle. The product OpenArc/Helper launch prohibition remains in force.
