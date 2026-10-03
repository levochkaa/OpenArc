# Mobile shared profile and sync

## Implemented boundary

The UIKit app now uses one `BrowserMobileProfileDocument` per local profile, shared by all scenes through `BrowserMobileProfileRegistry`. It owns the complete logical Space/folder/tab snapshot and SQLite writes. `BrowserMobileWorkspace` is a scene adapter: stable logical tab IDs map to independent WebKit runtime IDs, selection, navigation history and dialogs. Scenes submit stable-ID actions against the current document; they never overwrite it with independent full-window snapshots.

The document uses the existing v4 folder reducer, canonical projection and typed move intent. Create, rename, pin, Favorite, move and explicit remove write the full snapshot with immutable outbox intent through `BrowserSessionWrite`. Folder moves carry roots; subtree deletion uses current membership. Failed writes remain in the bounded FIFO with their origin/order, block the coordinator and expose Retry in every scene. A terminal overflow rejects the new action before changing visible state. In-memory failed writes still cannot survive process termination; keep the existing recovery limitation explicit.

UIKit provides a Space picker, New Space, Favorites/Pinned/Today sections, nested and empty folders, expansion, New Folder/Subfolder, Rename, Pin/Unpin, Favorite, Move To and explicit Remove. The same controller appears in the iPhone sheet and iPad sidebar. Captured menu actions resolve stable IDs against current state. Native drag reorder and archive remain separate work.

Remote metadata/order changes preserve surviving WebKit views and history. Remote deletion unregisters identity before engine teardown; late callbacks cannot recreate it. Empty remote state stays empty. Unsupported desktop URLs remain durable records and show an unavailable-address state without WebKit loading them. Entering a supported address creates or navigates once after document admission.

Ordinary Close/Cmd+W and `window.close()` remove temporary tabs. For pinned/Favorite tabs they unload only that scene's runtime; the shared record and other scenes survive. Explicit sidebar Remove deletes the shared identity. Selecting an unloaded persistent tab creates a fresh runtime. User title overrides remain separate from real page titles, so clearing Rename restores each scene's current page title.

## Shared platform code

Both iOS targets compile the same Foundation wire types, v2/v3/v4 projections, immutable outbox, SQLite store, coordinator and HTTP transport used by macOS. `project.yml` explicitly lists shared sources and reuses GRDB, Gzip, HTTPTypes, OpenAPI runtime/URLSession and generation from the existing backend schema. No mobile protocol fork exists.

`BrowserSessionDefaults` removes shared references to the AppKit model. `BrowserSyncDeviceIdentity` is supplied by the platform composition root. Shared account state and Apple identity protocols live separately from the AppKit presenter. `BrowserAuthSessionNamespace` retains exact desktop Keychain names while allowing an explicit mobile namespace. Sync error reporting is injected; the desktop root keeps its existing telemetry mapping. `loadSnapshotStrict()` lets mobile restoration distinguish an empty profile from a failed read.

The mobile document can attach the production `BrowserSyncService` as its single snapshot applier. **The shipped mobile composition does not yet create an account store/service or expose sign-in and sync consent.** Shared SQLite/outbox tests and compilation do not establish mobile network synchronization. That is the next vertical slice.

## Legacy sessions and scene state

Before opening the new `MobileProfile/TheBrowser.sqlite`, the registry reads and validates every legacy `MobileSessions/*.json`. Each file becomes a separate Space with stable IDs, tab order and its selected index. Colliding IDs from separate files receive distinct IDs. Cached page titles are refreshed by WebKit; they do not become user rename overrides. Original JSON files, including those cached titles, are kept intact.

`importSessionOnce` commits the logical snapshot and marker in one SQLite transaction. A failed marker write rolls back the imported rows; after successful import, deleting tabs and restarting cannot reimport them. A damaged/unsupported source blocks restoration and shows Retry without replacing either source or durable state. Import into an already account-bound profile fails closed, because existing tombstones require an explicit merge policy. Normal product import precedes account binding.

Scene selection is stored separately under its persistent scene ID. Disconnect/reconnect retains the workspace; discarding a scene releases its runtimes without deleting the registry's document or pending writes. Concurrent first connections await one registry open operation. Initial creation of a fresh local profile creates Personal and one blank tab only once; later empty state never triggers implicit synchronized replacements.

## Remaining network and account integration

1. Add a scene-anchored UIKit Apple identity provider and visible Account/Sync controls for sign-in, explicit enable consent, pause/sign-out and errors. Configure the server explicitly; do not silently select an origin or reuse another origin's credentials. `BrowserSyncConfiguration.current()` currently reads an environment variable only.
2. Compose one account store/coordinator per profile, attach it to the document, and make foreground polling profile-owned across scene activity. Preserve owner binding, cursor, baseline and pending FIFO on sign-out. Reject a different account rather than silently rebinding local data.
3. Verify iOS entitlement, provisioning and backend Apple audience configuration. The backend currently validates one `APPLE_CLIENT_ID`; distinct desktop/mobile bundle IDs require verified account grouping/audience support. Loopback test identities do not prove production Apple authentication. Production deployment/account writes remain outside this goal.
4. Extend the real localhost HTTP fixture to the mobile test host. Prove desktop v4 tree → mobile document → selected real WebKit page, then mobile action → SQLite/outbox → production Swift transport/backend → second client. Cover offline move/rename, lost ACK/reopen, paged adoption, current-subtree delete, unsupported URL retention and two-scene isolation. Keep frozen mutation UUIDs/bytes intact.
5. Add native reorder, archive, recovery export/import and remaining mobile browser capabilities. Profile synchronous document/SQLite/reducer work before moving it off MainActor; preserve action ordering and transaction boundaries.

## Verification

Use `./build.sh ios-build`, then `./build.sh ios-test --ios-destination ...` on iPhone and iPad. Tests use the separate `BrowserMobileTestHost`, real SQLite, actual UIKit controls and localhost WebKit pages. Model callback tests use a fake engine to control closure and event order. Existing legacy JSON tests remain as migration/regression coverage; production scenes use the new document.

The shared refactor also requires warning-free desktop `./build.sh build` followed by `./build.sh test` and the existing real Swift HTTP harness. Native menu method/control invocation does not prove physical taps, drag smoothness or OS Stage Manager lifecycle. The product TheBrowser/Helper launch prohibition remains in force.
