# Folder synchronization protocol

Protocol v4 adds account-scoped folder identities, nesting, pinned-tab membership and mixed folder/tab ordering to the existing authenticated sync endpoints. This is a server foundation for S08. Desktop capture, SQLite outbox/overlay, remote model application and mobile synchronization still use their previous contracts; no folder sync through the product UI is claimed yet.

The reference is the user's explicit requirement for reliable bidirectional workspace sync and reorder. These conflict rules are TheBrowser's contract.

## Identities and containers

A folder has a stable ID, `spaceID`, nullable `parentFolderID`, title, optional icon and server rank. A pinned tab adds nullable `pinnedFolderID`. Expanded/collapsed folder state remains local. Temporary tabs and global Favorites cannot belong to folders.

Identity is the pair `(entityType, entityID)`. A folder and a tab can share the same string ID without colliding. Sibling lists are:

- The global Spaces list.
- The global Favorites list, independent of each Favorite's historical Space ID.
- A Space's temporary-tab list.
- A Space's pinned root or one folder's children, containing both tabs and folders.

The server assigns consecutive ranks after v4 structural changes. Typed identity breaks existing rank ties deterministically. Legacy deletes can leave harmless rank gaps until the next v4 reorder. Rank is not a patchable metadata field.

## Operations and conflicts

Push uses `{protocolVersion:4, deviceID, mutationID, operations}`. Create, patch and delete specify an entity type and ID. Create omits rank and may supply typed `before` and `after` neighbors. Folder parents and tab membership must be present, using `null` for the root. Patches name only changed metadata fields; location and order require a move.

A mixed move has this shape:

```json
{
  "kind": "move",
  "items": [
    {"entityType": "folder", "entityID": "folder-id"},
    {"entityType": "tab", "entityID": "tab-id"}
  ],
  "destination": {
    "kind": "tabs",
    "spaceID": "space-id",
    "placement": "spacePinned",
    "pinnedFolderID": null
  },
  "before": {"entityType": "tab", "entityID": "neighbor-id"}
}
```

Spaces use the same `items` form with `destination: {"kind":"spaces"}`. Temporary/Favorite destinations allow only tabs. Explicit group order is preserved. The server tries the current `before` neighbor, then `after`, then appends. A neighbor in another container is absent; its move does not redirect the operation.

Every push holds the existing account row lock through commit. Independent metadata patches commute with moves. Competing structural operations apply in server commit order. Before any structural write, the executor validates every surviving root and destination. A missing/deleted/wrong-Space parent, cycle, or selection containing both an ancestor and its descendant rejects that operation without partial movement. Deleted group members return their tombstones; other surviving members can still move.

A folder move carries its **current server subtree**, including members added after the initiating client went offline. It does not use a stale client descendant list. A child moved out before the folder operation remains outside. Cross-Space moves update descendants' Space IDs while preserving nesting, metadata and internal order.

Folder and Space deletes traverse current membership. Descendants still inside receive persistent individual tombstones. Previously moved-out children and global Favorites survive. Delete-before-create, stale creates/patches/moves and duplicate delivery cannot resurrect an identity. Explicit restore needs a new identity; this slice adds no restore operation. No tombstone or receipt expiry is introduced.

Operations in one mutation are evaluated in order. A rejected semantic operation produces an outcome; it does not reject other valid operations in that mutation. An unexpected storage error rolls back the entire transaction, including events and receipt.

## Receipts and negotiation

V4 uses the existing account-scoped immutable receipt table. The digest includes protocol version and canonical parsed operations, excluding the replaceable device ID. Retrying the same UUID/content returns the original response, even after a restart, device rotation, newer move or deletion. Reusing a UUID for different content or another protocol returns HTTP 409. ACK cursors never advance a client's pull cursor.

Pull advertises `[2,3,4]`. A v4 reader explicitly sends `protocolVersion:4`. The first v4 pull for a device, or the first after a legacy pull, must start at cursor zero; otherwise the server returns HTTP 409. This ensures folder events hidden from older readers are replayed. The device capability flag changes in the same transaction as the successful read. Clients must keep baseline schema/capability and cursor together; server negotiation does not prove the client applied a response.

Legacy pull filters folder events **before** applying the page limit and strips `pinnedFolderID` from tabs. Its cursor is the last visible event. Trailing folder-only history returns an empty page with an unchanged cursor; later visible events are still reachable. V4 historical tab events that predate membership are represented with `pinnedFolderID:null`, preserving their historical meaning.

## Older writers

The v2/v3 request parsers, mutation digests and existing stored receipts retain their old semantics and contents. Legacy ACKs never contain folder events or new membership fields. A legacy Space delete still writes folder tombstones for v4 readers.

Old writers cannot express the mixed tree:

- V3 metadata patches and deletes remain supported. V3 creates/moves into a pinned Space containing folders return `upgrade_required`; an explicit move out to a folder-free destination is supported and clears membership.
- V3 incidental rank normalization preserves existing pinned ranks in Spaces containing folders.
- V2 full-record updates touching a folder-bearing source/target preserve existing structural fields and pinned home URL while applying page metadata. A new legacy pinned tab appends at the root using server order.

These compatibility restrictions prevent silent flattening; they are not full reorder parity for older clients. The next client slice must handle canonical rejections and capability transitions explicitly.

## Verification and next client slice

`./script/test_local_sync.sh` uses two independent authenticated HTTP devices, the production controller/service/executor and a disposable localhost PostgreSQL database. `Backend/tests/sync-folders.ts` registers folder scenarios within that existing fixture. It verifies paged tree reconstruction, typed identity collisions, mixed order, current-subtree movement, metadata/move ordering, tombstones, invalid topology, legacy compatibility, capability downgrade/upgrade, account isolation, receipt retry after process restart, rollback and migration preservation.

This does not prove production Swift folder capture or UI behavior. Next:

1. Add v4 Swift transport/event/operation types and semantic overlay without rewriting frozen v2/v3 rows.
2. Migrate SQLite queue/state version constraints while preserving UUID, payload bytes and FIFO. Persist the baseline protocol with its cursor; negotiate and replay from zero atomically.
3. Adopt existing local folder IDs/membership once. Preserve local expansion state and define durable mixed sibling order, including empty folders.
4. Capture exact model actions with typed roots/anchors, excluding descendants already carried by a selected ancestor. Project canonical folder entities into a fresh profile without echo or recreation.
5. Prove actual model → SQLite/outbox → HTTP/backend → second model → restart, including loss of ACK, failed writes, pending old rows and deletion/move races. Then verify native drag geometry/selection/scroll under the existing runtime permission boundary.

Current executor work scales with affected sibling lists and folder subtrees. Per-entity queries/writes and full-history upgrade replay are not yet profiled at large tree sizes. No latency or queue-compaction claim is made.
