# Sync protocol

V2 and v3 share bearer authentication, account/device checks, permanent deletion tombstones, the event stream and durable mutation receipts. The server serializes account writes in one PostgreSQL transaction. No client timestamp determines conflict order.

## V3 operations

`POST /v1/sync/push` accepts `{ protocolVersion: 3, mutationID, deviceID, operations }`. A request has at most 1,000 operations and at most 8 MiB of inflated JSON, including gzip requests. New client batches count encoded item bytes with envelope headroom and cap each move at 1,000 IDs. An oversized individual operation rolls back local persistence and logs a storage error; visible recovery UI remains required. Existing immutable rows are never silently rewritten or discarded. The server applies operations in request order; validation or a database error rolls back the entire request. Semantic rejection applies to that operation and is included in its durable receipt.

| Kind | Identity and content | Effect |
| --- | --- | --- |
| `create` | `entityType`, `entityID`, `data`, optional `beforeID`/`afterID` | Create a fresh Space or tab. Data has no client rank. A live identity cannot be overwritten by create. |
| `patch` | `entityType`, `entityID`, `fields` | Change only named metadata. Missing fields stay unchanged; nullable fields accept explicit `null`. Rank, placement and Space membership are not patch fields. |
| `move` | `entityType`, ordered `entityIDs`, optional anchors; tabs also supply `destination: { spaceID, placement }` | Move surviving identities as a block, preserving their request order and current metadata. |
| `delete` | `entityType`, `entityID` | Permanently delete this identity. A Space cascades to its ordinary children; global Favorites survive. |

Lists are scoped independently: Spaces in the account; global `.app` Favorites; and each Space's `.spacePinned` and `.temporary` tabs. Folder hierarchy remains outside this version's synced contract. Favorite `spaceID` is historical selection context, not a lifetime parent or list key.

The server removes the moving IDs before resolving anchors. A live `beforeID` in the destination wins; otherwise a live `afterID` is used; otherwise the block appends. Deleted, missing or moved-away anchors never redirect the destination. Anchors inside the moving block are invalid. Canonical ranks are assigned within affected lists from current server rows. Rank updates emit current metadata, not a stale copy supplied by the client.

Missing or deleted ordinary destinations reject the move and preserve live source tabs. Deleted source IDs stay deleted; surviving members can move. Promotion to pinned initializes its home URL from the current canonical URL, movement of an already pinned tab retains its home URL, and leaving pinned clears it. Explicit home-URL edits use a patch.

Two patches to different fields commute. A patch and a move preserve each other's independent changes. Two changes to the same field or two moves of the same identity follow server commit order. This provides convergence to a valid server history; it does not promise identical order for conflicting moves delivered in different orders.

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

The current model persists snapshots. Capture emits only changed metadata and infers a minimal move set using the longest unchanged subsequence in each list. This keeps shifted peers out of reorder mutations and preserves independent remote metadata. Scoped rank projection renders global Favorites, then each Space's pinned and temporary lists; it never compares ranks across unrelated lists.

Snapshot inference cannot distinguish dragging A after B from dragging B before A when both yield the same order. Direct drag capture must still persist the actual moved sync IDs and neighbor anchors atomically with the snapshot/outbox. Until that seam is connected, convergence of inferred operations is verified, but exact user drag intent under conflicting moves is not. Folder hierarchy and membership sync remain outside v3.
