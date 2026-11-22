# Folder synchronization protocol

Protocol v4 adds account-scoped folder identities, nesting, pinned-tab membership and mixed folder/tab ordering to the existing authenticated sync endpoints. The macOS client captures folder actions, persists versioned operations in SQLite and projects the canonical tree into the AppKit model. The [mobile client](mobile-shared-sync.md) shares this protocol. Live desktop drag verification remains open.

The reference is the user's explicit requirement for reliable bidirectional workspace sync and reorder. These conflict rules are OpenArc's contract.

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

The v2/v3 request parsers, mutation digests and existing stored receipts retain their formats and contents. New live-tab writes use the common [activity maximum](sync-protocol.md#monotonic-tab-activity), including legacy full records and patches. Legacy ACKs never contain folder events or new membership fields. A legacy Space delete still writes folder tombstones for v4 readers.

Old writers cannot express the mixed tree:

- V3 metadata patches and deletes remain supported. V3 creates/moves into a pinned Space containing folders return `upgrade_required`; an explicit move out to a folder-free destination is supported and clears membership.
- V3 incidental rank normalization preserves existing pinned ranks in Spaces containing folders.
- V2 full-record updates touching a folder-bearing source/target preserve existing structural fields and pinned home URL while applying page metadata. A new legacy pinned tab appends at the root using server order.

These compatibility restrictions prevent silent flattening; they do not give older clients the full reorder behavior. The Swift coordinator applies canonical outcomes for rejected operations and removes the acknowledged immutable row. It does not reinterpret a frozen v3 move as a v4 operation.

## Swift persistence and upgrade

`BrowserSyncFolderProjection` owns v4 canonical records, metadata diffs, typed neighbor operations and the pending-operation overlay. `BrowserSyncEvent` decodes its data using the envelope entity type; a page title cannot turn a tab or folder into a Space.

`pinnedSiblingRank` on persisted tabs and folders expresses one order per pinned container. The sidebar tree includes empty folders, infers legacy missing ranks from the first descendant tab and appends empty legacy folders. Drop and direct move actions use the same planner. Folder expansion remains local; title, icon, nesting, membership and sibling order synchronize. An empty folder survives moving or closing its last tab; **Delete Folder and Contents** explicitly removes its current subtree.

A folder drag journals only its stable folder identity. Descendant Space changes in the snapshot do not become stale tab moves. Folder deletion similarly journals the root rather than separate descendant deletes. Local rank changes are structural intent; metadata saves preserve authoritative ranks while engine callbacks are still pending.

The SQLite migration adds nullable sibling-rank columns and v4 queue/state constraints. Existing v2/v3 UUIDs, payload BLOBs, FIFO positions and the AUTOINCREMENT high-water mark are copied without decoding/re-encoding. New v4 rows retain the existing operation-count and request-size limits.

The coordinator first negotiates through the old pull endpoint and drains all immutable v2/v3 rows. It then requests every v4 page from cursor zero. One SQLite transaction rebuilds the baseline, retains tombstones, adopts eligible local folders once, writes the projected session/cursor and marks new mutations v4. A legacy local edit during paging aborts that transaction; the next cycle drains it before retrying. An already-adopted profile receiving the device bootstrap 409 repeats the zero-based read without repeating adoption, while retaining pending v4 work. Partial pages are never published to the model.

Adoption preserves stable local IDs, title/icon and the typed mixed order for missing folders. It moves legacy root-pinned members into those folders using explicit local neighbors. Existing authoritative folder metadata/location and nonnull remote membership win. A deleted folder, its absent parent or a stale descendant cannot be recreated by adoption or local snapshot writes.

## Verification

`./script/test_local_sync.sh` exercises the production controller/service/executor with independent authenticated devices and disposable localhost PostgreSQL. Its backend coverage includes paged tree reconstruction, typed identity collisions, mixed order, current-subtree movement, metadata/move ordering, tombstones, invalid topology, legacy compatibility, capability transitions, account isolation, receipt retry after process restart, rollback and migration preservation.

`./script/test_swift_sync.sh` runs the production Swift transport, coordinator and SQLite store against that server. The folder scenarios invoke the actual model with a fake browser engine, create/nest/rename folders, reorder an empty folder among tabs, reopen a second profile, preserve an escaped child during an offline folder move/delete, and retry an identical lost-ACK mutation after client restart. Historical v2/v3 cases retain explicit capability shims so adding v4 does not silently remove their coverage. Unit/integration tests separately cover migration BLOB preservation, transaction rollback, adoption, cursor/capability fences, stale snapshots, partial engine hydration and invalid receipts.

These checks do not establish live CEF behavior or native drag geometry, selection/scroll stability and animation quality. Mobile folder and HTTP verification is recorded separately in [mobile shared sync](mobile-shared-sync.md). Current executor work scales with affected sibling lists and folder subtrees. Per-entity SQL, full-history upgrade replay and synchronous client snapshot/overlay work still need measured performance work; no latency or queue-compaction claim is made.

## Pending engine creation and local moves

A remotely received tab can be durable in SQLite before its logical engine callback arrives. The model keeps that identity in `pendingRemoteTabCreations`; it must still occupy its real place in the sibling list.

`sidebarPlanningSnapshot` combines hydrated tabs and pending bindings for structural actions. The shared move planner validates the complete current subtree and computes anchors against every logical sibling. `publishPlannedTabs` publishes only hydrated rows, updates pending bindings' structural fields and keeps their URL, pinned home, title override and optional activity timestamp intact. Persistence merges those latest bindings, rather than the original remote snapshot. Late callbacks therefore adopt the current Space, folder and rank without creating another mutation.

This closes two data errors: a cross-Space folder move could previously leave pending children in their old Space and journal `deleteTab`; a reorder beside a pending sibling could choose the wrong neighbor after renumbering only visible rows. Folder actions continue to journal only the root. An escaped pending child survives a later subtree delete, and close/create callback ordering cannot restore a deleted child.

The HTTP fixture can hold a real v4 response after the server transaction, observe requested/returned cursors and register a new device through `/v1/devices`. A paged upgrade test derives the actual page boundary from server history: `server_seq` is global, so 500 events do not imply cursor 500. Existing local edits retain their legacy mutation identity before adoption; rotated devices replay from zero and retry account-scoped receipts.
