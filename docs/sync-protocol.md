# Sync protocol

V2 and v3 share bearer authentication, account/device checks, permanent deletion tombstones, the event stream and durable mutation receipts. The server serializes account writes in one PostgreSQL transaction. Client timestamps do not determine structural or metadata conflict order; live-tab activity has the value-merge exception below. [V4](sync-folders.md) extends these foundations with folders and typed mixed ordering.

## V3 operations

`POST /v1/sync/push` accepts `{ protocolVersion: 3, mutationID, deviceID, operations }`. A request has at most 1,000 operations and at most 8 MiB of inflated JSON, including gzip requests. New client batches count encoded item bytes with envelope headroom and cap each move at 1,000 IDs. An oversized individual operation rolls back local persistence and logs a storage error; visible recovery UI remains required. Existing immutable rows are never silently rewritten or discarded. The server applies operations in request order; validation or a database error rolls back the entire request. Semantic rejection applies to that operation and is included in its durable receipt.

| Kind | Identity and content | Effect |
| --- | --- | --- |
| `create` | `entityType`, `entityID`, `data`, optional `beforeID`/`afterID` | Create a fresh Space or tab. Data has no client rank. A live identity cannot be overwritten by create. |
| `patch` | `entityType`, `entityID`, `fields` | Change only named metadata. Missing fields stay unchanged; nullable fields accept explicit `null`, except that null activity cannot erase a known time. Rank, placement and Space membership are not patch fields. |
| `move` | `entityType`, ordered `entityIDs`, optional anchors; tabs also supply `destination: { spaceID, placement }` | Move surviving identities as a block, preserving their request order and current metadata. |
| `delete` | `entityType`, `entityID` | Permanently delete this identity. A Space cascades to its ordinary children; global Favorites survive. |

Lists are scoped independently: Spaces in the account; global `.app` Favorites; and each Space's `.spacePinned` and `.temporary` tabs. Folder hierarchy remains outside this version's synced contract. Favorite `spaceID` is historical selection context, not a lifetime parent or list key.

The server removes the moving IDs before resolving anchors. A live `beforeID` in the destination wins; otherwise a live `afterID` is used; otherwise the block appends. Deleted, missing or moved-away anchors never redirect the destination. Anchors inside the moving block are invalid. Canonical ranks are assigned within affected lists from current server rows. Rank updates emit current metadata, not a stale copy supplied by the client.

Missing or deleted ordinary destinations reject the move and preserve live source tabs. Deleted source IDs stay deleted; surviving members can move. Promotion to pinned initializes its home URL from the current canonical URL, movement of an already pinned tab retains its home URL, and leaving pinned clears it. Explicit home-URL edits use a patch.

Two patches to different fields commute. A patch and a move preserve each other's independent changes. Two changes to the same field or two moves of the same identity follow server commit order, except for the activity maximum below. This provides convergence to a valid server history; it does not promise identical order for conflicting moves delivered in different orders.

## Monotonic tab activity

For each live tab, the common v1/v2/v3/v4 SQL upsert stores the maximum of the known and incoming `lastActivityAt` instants. Older, equal, omitted or explicit-null activity cannot lower or erase a known value. A new tab with no known activity remains null. This is a deliberate exception to nullable metadata clearing. Other fields retain their existing conflict rules; an old activity value does not reject the whole operation or its independent title, URL or placement changes. Moves, peer-rank normalization and folder-subtree updates preserve the maximum too.

Newly written tab-upsert events publish the actual PostgreSQL result as UTC with six fractional digits. ACK and pull carry those events, but can also echo historical events in their unchanged format, including for a new rejected or no-op operation. Formatting occurs in SQL, avoiding JavaScript Date's loss of submillisecond precision. Request schemas remain UTC-only and accept their existing ISO 8601 precision; this change does not enable offset-form inputs. No-op activity writes may still create events and receipts under the existing mutation rules.

Tombstones dominate every activity value, including future timestamps. A late patch/upsert cannot resurrect a deleted identity; explicit restore uses a fresh ID. Existing request bytes, digests, historical events and stored receipts are never rewritten. Exact retry returns its original historical receipt even after newer activity or deletion, without another write. Previously regressed database values cannot be recovered from this rule alone; no historical repair or migration is claimed.

Updated Swift clients merge pending v2 full-record and v3/v4 patch activity by parsed instant. Thus a frozen older request cannot hide newer pulled activity while awaiting its ACK. Queue UUIDs, payload bytes and FIFO positions remain unchanged. The canonical baseline still accepts events by server sequence; it does not substitute a local maximum or reject an entire newer event because its activity is older. This preserves compatibility with historical events and older servers. The canonical guarantee requires the updated server; old installed client binaries are not repaired by a protocol-compatible server update.

Snapshot materialization reads fractional canonical times without millisecond truncation. When a whole-second value represents the same second as a more precise local value, it preserves that local fraction. A different canonical instant remains authoritative; arbitrary future local values do not permanently override the baseline. Null/invalid materialization retains the existing finite local fallback. Newly captured mobile activity still uses whole seconds.

Future timestamps are not capped and therefore conservatively delay expiry. Even this maximum cannot reveal activity a completely offline device has never reported. The [conditional expiry foundation](sync-expiry.md) defines the reported-activity policy and server checks. Shared clients now import recovery durably; mobile auto-archive remains disabled until conditional intents and scheduling are implemented. Local attached-window protection and activity capture are documented in [mobile foundation](mobile-foundation.md#tab-activity-and-attached-windows). These merge rules are TheBrowser policy.

## Receipts and pulls

A v3 receipt contains `protocolVersion`, `mutationID`, `cursor`, canonical `events`, and one `outcomes` item per operation: `{ operationIndex, status, reason? }`. Status is `applied`, `deleted` or `rejected`. Rejections and no-op results are terminal, replayable outcomes; they must not become an endlessly retried queue entry. Clients reconcile the returned canonical events before removing that mutation's local overlay.

Mutation IDs are unique within an account across both protocol versions. V3 digests include the version and immutable operations; v2 retains its original canonical changes digest for compatibility. Both exclude replaceable device identity. Exact retry returns the original stored response without applying the operation again. A different payload or protocol under that UUID returns conflict. Entity writes, events and receipt insertion commit together. Receipts and deletion history have no unsafe expiry.

ACK cursor is informational; it is not a pull cursor. Clients advance a pull cursor only after atomically applying all read events with their baseline. `POST /v1/sync/pull` retains `protocolVersion: 2` for existing readers and advertises `supportedPushVersions: [2, 3]`. Events remain full canonical entity snapshots or deletes.

## Client transition

The desktop coordinator negotiates push versions across every bootstrap page. Capability upgrade, remote baseline, projection and pull cursor commit in one SQLite transaction. New actions become v3 after successful discovery; failed discovery cannot partially enable them. Old-server responses without the additive capability field retain v2 behavior.

SQLite stores `protocol_version` per queue row and durable `new_mutation_version`. Migration preserves existing v2 UUIDs, positions and payload bytes. The sender and pending overlay reducer consume both formats in one FIFO. A lost ACK retries that exact mutation and version; a valid receipt applies canonical events and removes only the matching row. Rejected/no-op semantic outcomes are terminal. Wrong identity/version or incomplete outcomes retain the row. Unknown/already removed ACKs do not inject new events. A server downgrade retains v3 rows and retries after capability recovery; it never converts them to full snapshots or bypasses their FIFO position.

Local-only tombstones hide deleted objects after replay while retaining acknowledged canonical parents needed by earlier pending creates/moves. Authoritative server tombstones remain permanent from the start of replay. New v3 Space removal emits the parent delete and lets the server cascade through current membership. It does not infer explicit deletes for every child seen in the old snapshot, so a child moved away by another device survives. Explicit tab deletes remain terminal.

No account-wide write floor blocks older devices. An old v2 full upsert can still overwrite independent newer changes, and a frozen v2 parent-deletion batch may already contain explicit child deletes. Existing payloads retain those semantics; touched fields or parent-deletion intent cannot be safely recovered by guessing. V3 guarantees apply to new v3 intents after upgrade and queue drain.

## Capture boundary

The model persists snapshots with an optional `BrowserSyncMoveIntent`. Sidebar drop, direct single/group moves, folder moves and folder creation carry the actual acted-on stable tab IDs in final sidebar order. SQLite resolves their destination and outside-group neighbor anchors from the normalized snapshot, then commits snapshot and immutable outbox rows together. It does not infer complementary moves for that action. Changed metadata, creates and deletes remain separate operations.

Thus dragging A after B emits a move of A even when moving B before A would produce the same local order. Concurrent conflicting moves follow server commit order; an unrelated remote metadata patch survives either order. Deleted/missing members are filtered, groups retain order across the 1,000-ID operation limit, and retry preserves the original IDs and bytes even after members or anchors disappear. Global Favorites share one rank list while retaining individual historical Space IDs. Identical snapshots are no-ops; folder-only changes may still carry a move of their actual members.

Snapshot-only callers retain longest-unchanged-subsequence inference for compatibility. Scoped projection renders global Favorites, then each Space's pinned and temporary lists; it never compares ranks across unrelated lists. V2 queues retain their old full-record behavior. Folder hierarchy and membership remain local-only; carrying folder descendants in a move does not sync the folder itself. Native gesture quality and live CEF behavior require separate runtime verification.
