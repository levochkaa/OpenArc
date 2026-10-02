# Sync protocol

V2 and v3 share bearer authentication, account/device checks, permanent deletion tombstones, the event stream and durable mutation receipts. The server serializes account writes in one PostgreSQL transaction. No client timestamp determines conflict order.

## V3 operations

`POST /v1/sync/push` accepts `{ protocolVersion: 3, mutationID, deviceID, operations }`. A request has at most 1,000 operations and at most 8 MiB of inflated JSON, including gzip requests. The server applies operations in request order; validation or a database error rolls back the entire request. Semantic rejection applies to that operation and is included in its durable receipt. Client byte-based chunking still needs to accompany the existing item-count limit; oversized immutable queue entries must not be silently discarded or rewritten.

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

The desktop coordinator currently writes and sends v2. The v3 server and typed Swift transport are a foundation for the next client slice, not a claim that production UI reorder already uses semantic operations.

The planned SQLite transition adds an explicit version per queue row and a version for new mutations. Existing v2 UUIDs, positions and payload bytes remain unchanged. After capability discovery, only new actions become v3; the sender and pending overlay reducer consume both formats in the same FIFO. A lost v2 ACK is resolved by replaying that exact v2 mutation. A server downgrade must retain v3 rows rather than convert them to full snapshots.

No account-wide write floor blocks older devices. Mixed-version operation preserves the v2 full-record contract: an old full upsert can still overwrite fields that a newer device changed independently. V3 commutation guarantees apply to v3 intents. This limitation ends for new activity after devices upgrade and old queues drain; it cannot be repaired by guessing touched fields from old payloads.
