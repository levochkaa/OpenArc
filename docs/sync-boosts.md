# Boost sync

Boosts (per-site CSS, JavaScript and zapped elements) are app-wide. They sync through the default profile's account, so every Mac signed in to that account shows the same boosts. Other profiles and incognito windows carry no boost sync of their own; which pages a boost applies to is decided elsewhere.

## Identity and conflicts

A boost's identity is `BrowserBoost.syncID`, a UUID made with the boost, not its host. Boosts saved before sync get one the first time the preferences load. Server deletions are permanent tombstones, so a boost made again for the same host after a delete takes a fresh identity.

- An upsert carries the whole boost and replaces it. The last write the server commits wins; there is no field merge.
- A delete is permanent. An upsert of a deleted boost is rejected with reason `deleted` and the tombstone; the device then drops its copy. An edit made offline does not bring a deleted boost back.
- Two devices can each make a boost for one host before they hear of the other. Both records live on the server; each device shows the most recently written one (`BrowserSyncBoostState.winners`: highest server sequence, queued local writes above all of them). The next local edit of that host deletes the hidden one, and removing the host deletes every boost of it, so a hidden duplicate never reappears.

## Protocol version 6

Push carries boost operations only; Spaces, tabs and folders stay on v4.

```json
{
  "protocolVersion": 6,
  "mutationID": "550e8400-e29b-41d4-a716-446655440001",
  "deviceID": "550e8400-e29b-41d4-a716-446655440002",
  "operations": [
    { "kind": "upsert", "entityType": "boost", "entityID": "5C1D…", "data": {
      "host": "example.com", "isEnabled": true, "css": "body { margin: 0 }",
      "javaScript": "", "zappedSelectors": ["#cookie-banner"] } },
    { "kind": "delete", "entityType": "boost", "entityID": "9A0F…" }
  ]
}
```

Limits count UTF-16 code units: host 1–253, CSS and JavaScript up to 262,144 each, at most 1,000 zapped selectors of 1–4,096. A boost over a limit stays on its Mac and is not queued. Outcomes follow the shared receipt rules: `applied`, `deleted` for a repeated delete, `rejected` with `deleted` for an upsert of a tombstone.

A v6 pull returns everything a v5 pull does plus `boost` events (`{id, host, isEnabled, css, javaScript, zappedSelectors}`, or `{id}` for a delete). Older pulls never see boost events, which older clients could not read. Like v4 and v5, any older pull resets the device's v6 marker, and the first v6 pull must start at cursor 0 (`409 Protocol 6 bootstrap requires cursor 0` otherwise). Every pull advertises `supportedPushVersions: [2, 3, 4, 5, 6]`.

## Client

`BrowserSQLiteSessionStore` keeps the server's boosts in `browser_sync_boost_baseline`, apart from the tab baseline, and queues boost writes as protocol 6 rows in the same immutable FIFO outbox. `BrowserSyncBoostState` is that baseline with queued rows replayed on top. `boost_revision` changes with every baseline or queue change, and the coordinator tells its boost applier after a pull or acknowledgement that changed it.

The coordinator climbs one version at a time, as from v4 to v5, replaying from cursor zero each time, and commits only the newest read. The v6 bootstrap rebuilds the boost baseline from cursor zero, keeping known tombstones, and in the same transaction queues local boosts the server has not seen (`adoptionOperations`). A local boost for a host the server already has replaces that boost's content under the server's identity: enabling sync is the latest write.

`BrowserBoostSyncBridge` connects the store to `BrowserUserPreferencesStore.boosts`:

- Removals queue at once. Edits queue after two seconds without another edit, since the boost editor saves CSS while the user types; quitting queues pending edits first.
- Before showing remote changes it queues pending edits, then replaces each host's boost with the synced one, keeping this Mac's order and appending new hosts. A local boost sync has not seen stays.
- At launch it queues boosts the store has never seen and shows the synced state. An edit lost in the two seconds before a crash is replaced by the synced boost.

Boost rows wait in the FIFO like other rows, so automatic expiry, which needs an empty queue, runs once they drain.

If a pull stops advertising v6 (a server rolled back behind a newer proxy, say), the client suspends boost sync and reads at v5 from the same cursor, so Spaces and tabs keep syncing. Queued boost rows stay in order and wait, as rows of any withdrawn version do. When v6 is offered again the boost baseline is rebuilt from cursor zero. A server that rejects v6 pulls outright stops sync for clients already on v6, as a server without v5 does for v5 clients.

## Server

Migration `008_sync_boosts.sql` adds the `boosts` table, the per-device `boost_sync_enabled` marker and `boost` to the event and tombstone entity types. `Backend/src/sync/boosts.rs` applies v6 operations under the account lock with the shared event log, tombstones and receipts.

## Security

A boost's JavaScript runs in every page of its site. Syncing it means anyone who can write to the account can run script on the user's pages on every signed-in Mac. The account's sign-in protects it, as it protects the rest of synced data.
