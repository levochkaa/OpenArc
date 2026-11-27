# Mobile tab sync

Phones and tablets (iPhone, iPad, later Android) keep their own tab list, apart from desktop Spaces. They sync it through the account as mobile tabs, so every mobile device signed in to the account shows the same tabs. Desktops only read the list; they never write it.

## Identity and conflicts

A mobile tab's identity is the `entityID` the device made with the tab. Server deletions are permanent tombstones, so a page opened again after its tab was closed takes a fresh identity.

- An upsert carries the whole tab and replaces it: URL, title and `createdAt`. The last write the server commits wins; there is no field merge, so an upsert without a title clears it.
- `lastActivityAt` is the one exception. The server keeps the maximum of the stored and the incoming instant, as it does for desktop tabs ([monotonic tab activity](sync-protocol.md#monotonic-tab-activity)). An older or omitted value never lowers or erases a known one.
- A delete is permanent. An upsert of a deleted tab is rejected with reason `deleted` and the tombstone; the device then drops its copy. An edit made offline does not bring a closed tab back.
- Mobile tabs and desktop tabs are separate entities: the same ID in both names two records.

## Protocol version 7

Push carries mobile tab operations only, 1 to 1,000 per request; Spaces, tabs and folders stay on v4, boosts on v6.

```json
{
  "protocolVersion": 7,
  "mutationID": "550e8400-e29b-41d4-a716-446655440001",
  "deviceID": "550e8400-e29b-41d4-a716-446655440002",
  "operations": [
    { "kind": "upsert", "entityType": "mobileTab", "entityID": "7B2E…", "data": {
      "urlString": "https://example.com/", "title": "Example",
      "createdAt": "2026-11-27T10:00:00Z", "lastActivityAt": "2026-11-27T10:05:00.123Z" } },
    { "kind": "delete", "entityType": "mobileTab", "entityID": "9A0F…" }
  ]
}
```

Limits count UTF-16 code units: entity ID 1–200, URL 1–8,192, title 1–1,024. `createdAt` is required; `title` and `lastActivityAt` are optional and omitted, never null. Date-times are UTC only (`Z`), with the precision desktop tabs accept. The server rejects unknown fields. Outcomes follow the shared receipt rules: `applied`, `deleted` for a repeated delete, `rejected` with `deleted` for an upsert of a tombstone. An exact retry returns the original receipt.

A v7 pull returns everything a v6 pull does plus `mobileTab` events: `{id, urlString, createdAt}` with `lastActivityAt` and `title` when set, or `{id}` for a delete. `createdAt` and `lastActivityAt` are the stored values as UTC with six fractional digits. Older pulls never see mobile tab events. Like v4, v5 and v6, any older pull resets the device's v7 marker, and the first v7 pull must start at cursor 0 (`409 Protocol 7 bootstrap requires cursor 0` otherwise). Every pull advertises `supportedPushVersions: [2, 3, 4, 5, 6, 7]`.

## Client

`BrowserSQLiteSessionStore` keeps three things apart from the Spaces: the device's own list in `browser_mobile_tabs`, the server's mobile tabs in `browser_sync_mobile_tab_baseline`, and mobile tab writes as protocol 7 rows in the same immutable FIFO outbox. `BrowserSyncMobileTabState` is that baseline with queued rows replayed on top, activity kept at its maximum. `mobile_tab_revision` changes with every baseline or queue change, and the coordinator tells its `BrowserSyncMobileTabApplying` applier after a pull or acknowledgement that changed it.

The coordinator climbs one version at a time, from v6 to v7 as from v5 to v6, replaying from cursor zero, and commits only the newest read. The v7 bootstrap also does the v6 boost bootstrap, rebuilds the mobile tab baseline from cursor zero keeping known tombstones, and in the same transaction queues local tabs the server has not seen. A blank tab (`about:blank`) never syncs: it stays on its device until it opens a page. If a pull stops advertising v7, the client suspends mobile tab sync and reads at v6 from the same cursor; queued v7 rows wait in order, and the next v7 offer rebuilds the baseline from cursor zero. Before sync starts, or with a server without v7, the list saves locally and nothing queues.

### Phones and tablets

`BrowserMobileProfileDocument.mobileTabs` is the device's list, the oldest first; each scene's `BrowserMobileWorkspace` shows those tabs, plus its own private tabs, with WebKit runtimes of its own. The document is the applier:

- Creating a tab, a new URL, a page title and selection activity save the list at once and queue a whole-record upsert after one second without another change, since a loading page changes its URL and title several times. A scene going inactive queues pending changes first.
- Closing a tab queues its delete in the same transaction as the list and a local Archive entry; `window.close()` closes without an entry. Restoring an Archive entry opens a new mobile tab with a fresh ID.
- Remote changes replace each known tab's record, keeping the later activity, drop tabs deleted elsewhere and append new ones. A remote URL change navigates a page loaded here. A window left without tabs opens a blank one.

The Space snapshot still syncs on v4 and feeds the Spaces picker: the iPhone's Spaces sheet and the iPad's Spaces popover. Tapping a Space tab opens its address as a mobile tab, or selects the mobile tab already showing it; the Space keeps its tab. Pin in the page menu adds the page to a Space as a pinned tab or Favorite and leaves the mobile tab. A fresh mobile profile creates no Space. Updating from a version that showed Space tabs starts the mobile list empty, with one blank tab.

### Computers

The Mac's default profile sets a `BrowserMobileTabsFeed` as the applier. It uploads nothing and lists the synced tabs, the latest used first, in Archive › From iPhone and in the command bar's results (marked From iPhone). Choosing one opens its address in a new tab.

## Server

Migration `011_sync_mobile_tabs.sql` adds the `mobile_tabs` table, the per-device `mobile_tab_sync_enabled` marker and `mobileTab` to the event and tombstone entity types. `Backend/src/sync/mobile_tabs.rs` applies v7 operations under the account lock with the shared event log, tombstones and receipts. The upsert stores `GREATEST` of the stored and incoming activity and formats both instants in SQL. Deleting the account removes its mobile tabs with the rest of its rows.
