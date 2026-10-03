# Mobile shared workspace and sync plan

This is an implementation plan based on the mobile foundation and desktop v4 client at `48d638c`. It does not claim mobile Spaces, folders, account authentication or synchronization are implemented. The existing iPhone/iPad app has scene-owned WebKit runtimes, a flat tab list and version-1 JSON session persistence.

## Shared core

Reuse the existing v2/v3/v4 wire types, projections, immutable outbox and coordinator. Do not introduce a separate mobile protocol or reinterpret frozen mutation payloads. The shared source set should include `BrowserSyncModels`, `BrowserSyncSemanticModels`, `BrowserSyncFolderModels`, both semantic projections, `BrowserSyncOutbox`, `BrowserSyncQueuedMutation`, `BrowserSyncOwner`, `BrowserSyncMoveIntent`, session snapshot/write types, `BrowserSessionWriteBuffer`, `BrowserSQLiteSessionStore` and `BrowserSyncService`/transport.

The concrete extraction seams are:

- Move `BrowserChromeModel.defaultSpaceID` and `defaultSpaceIconName` to a Foundation-only defaults type. Outbox, folder projection and the older snapshot merger currently reference the AppKit model for these constants.
- Inject device name/platform into authentication instead of using `Host.current()` and `macOS` defaults in `BrowserRemoteSyncClient.swift` and `BrowserAccountStore`.
- Give `BrowserAuthSessionStore` an explicit profile namespace rather than depending on `BrowserProfile.defaultDirectoryName`. Preserve existing desktop Keychain account names.
- Separate shared account state/protocols from the AppKit provider in `BrowserAppleSignInService.swift`. The mobile Apple identity provider must receive the presenting scene's window.
- Inject the coordinator's error reporter rather than requiring `BrowserTelemetry` and Sentry in the shared sync core.
- Add the same source files, GRDB, Gzip, HTTPTypes, OpenAPI runtime/URLSession transport and authentication code generation to both iOS targets in `project.yml`. The current targets include only shared navigation/search/strings and DomainParser. A new package is optional; source inclusion can establish the boundary first.

CoreGraphics preference types and Foundation/Security logging are not themselves AppKit dependencies. Desktop profile discovery, Chromium files, browser engines and native views should stay outside the shared source set.

## One document, separate scene runtimes

A proposed `BrowserMobileProfileDocument` owns one profile's logical Spaces, folders, tabs, SQLite store, authentication state and sync coordinator. It is the coordinator's single `BrowserSyncSnapshotApplying` receiver and publishes changes to multiple scene subscribers. Do not attach the last connected window directly as the service's weak applier.

`BrowserMobileWorkspace` remains the scene adapter: stable logical tab ID to scene-local runtime ID, selected Space/tab, WebKit state and dialogs. Each scene keeps its own engine and host view. Existing live WebKit views/history survive remote metadata and order changes; new remote identities register lazily. Remote deletion removes the logical identity before closing its runtime. An empty remote document must not implicitly create and upload a replacement blank tab.

All structural actions pass through the document and commit `BrowserSessionWrite` plus the immutable outbox in one SQLite transaction. Capture typed acted-on roots for folder/tab moves. The current mobile worker's replaceable latest snapshot is suitable for its flat JSON session, but cannot retain a failed move followed by another action. Reuse the bounded failed-write FIFO, retain each origin/move intent, block remote application while writes are unresolved and resume through a fresh pull after recovery.

Separate complete snapshots from independent iPad windows must never write to the same database: each would treat the other window's omitted tabs as deletions. Scene selection is local presentation state, not a competing full document. `BrowserMobileSceneSessions` should acquire the shared document while retaining each scene's engine and reconnect lifecycle. Foreground polling should be owned at the profile level; background suspension must not pause another active window or change durable sign-out state.

## Existing sessions and unsupported URLs

Import each `MobileSessions/*.json` once into a separate Space, preserving stable tab IDs, order and per-scene selection. Allocate and persist the destination Space ID with the import marker and document rows in one SQLite transaction. Preserve source JSON files; only a committed marker suppresses a later import. A corrupt or unsupported file must remain available for recovery rather than being replaced by an empty session. Handle stable-ID collisions explicitly before committing; do not silently overwrite an imported tab.

The mobile validator currently accepts HTTP, HTTPS and `about:blank`. A synchronized desktop record with an unsupported address, such as an internal browser page, must remain in the document and outbox projection. Present an unsupported-address state without asking WebKit to load it. Filtering that record from a local snapshot would become an unintended synchronized deletion.

Reuse the coordinator's existing negotiation, legacy FIFO drain, zero-cursor v4 bootstrap and atomic adoption. Signing out preserves the profile owner, baseline and pending queue. A different account cannot silently rebind or upload the existing profile.

## First product entry point

Extend `BrowserMobileTabsViewController` in `BrowserMobileViewController.swift`: it already appears as the iPad sidebar and iPhone sheet. The first useful slice includes a Space picker, Favorites, pinned mixed folder/tab tree, temporary tabs and empty-folder expansion. Context menus provide Pin, Rename, New Folder, Move To and explicit Remove actions. Closing a pinned page runtime must remain distinct from deleting its shared identity. Native drag geometry can be a later interaction slice.

Add an Account/Sync entry with authentication, explicit enable consent, pause/sign-out, persistence recovery and visible errors. Keep engine errors distinct from persistence and account errors.

## Provisioning and authorization boundary

`BrowserSyncConfiguration.current()` currently reads only `THEBROWSER_SYNC_BASE_URL`; a normal mobile installation needs an explicit app configuration source. Do not silently select a server or reuse credentials issued by another origin.

The iOS target currently has no Apple Sign In entitlement. `Backend/src/auth.service.ts` validates one configured `APPLE_CLIENT_ID`, while desktop and iOS have different bundle identifiers. Mobile provisioning, allowed audiences and Apple account grouping must be verified before claiming a shared production account. A loopback fixture with injected test identity proves transport and data behavior, not real Apple authentication or provisioning. Production deployment and production account writes remain outside this goal.

## First vertical acceptance

1. Desktop v4 tree, including nested/empty folders and Favorites, reaches the mobile document; selecting a tab loads a local WebKit fixture. IDs, tree order and scene selection survive restart.
2. Mobile Pin/Rename/Move/Remove actions pass through the actual document, SQLite queue, production HTTP client/backend and a second independent client. Folder actions carry roots, not stale descendants.
3. Two iPad scene adapters observe shared edits while keeping independent selection and runtime identities. Disconnect/reconnect does not delete shared records or lose failed writes.
4. Offline move followed by rename, SQL write failure/retry and lost ACK/reopen retain immutable mutation IDs, bytes and FIFO order. Remote application cannot overwrite unresolved local actions.
5. Concurrent subtree move/delete preserves escaped children, rejects dead destinations and produces no resurrection or remote echo. Unsupported desktop URLs remain durable records.
6. JSON import is atomic and repeatable after interruption. Corrupt input and a different signed-in account cannot overwrite existing data.

Use the existing desktop Build/Test gates for the shared-core refactor and `./build.sh ios-build` plus `./build.sh ios-test --ios-destination ...` for the mobile test host. Add composed mobile-model/SQLite/HTTP tests and real local-document WebKit checks; keep real Apple sign-in, deployment and live product UI proof as separate evidence. No build, test or product launch was performed for this planning audit.
