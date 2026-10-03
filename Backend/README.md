TheBrowser sync backend runs NestJS on Node.js 26 with PostgreSQL 17. The checked-in [OpenAPI contract](openapi.yaml) is served at `/openapi.yaml`; runtime Swagger documentation is available at `/docs`. Apply migrations before starting the server. Migration `005_sync_folders.sql` adds folders, tab membership and per-device v4 bootstrap state.

For local development, install dependencies with `npm ci` in `Backend`, copy `.env.example` to `.env`, and configure an isolated database plus a local JWT secret. Run `npm run migrate`, then `npm run dev`. The default API port is 8080. The repository's `script/test_local_sync.sh` starts and removes its own disposable PostgreSQL container and runs authenticated HTTP integration tests; it does not use the development database.

Current clients can keep using v2/v3. Folder synchronization is a backend v4 foundation; the production Swift sync coordinator still uploads v3 operations. A future v4 client must implement folder projection and bootstrap before enabling v4 uploads.

| Protocol | Push body | Pull behavior |
| --- | --- | --- |
| Legacy v1 | `deviceID`, `changes` | Omit `protocolVersion`; Space/tab events only |
| v2 | `protocolVersion: 2`, `mutationID`, `deviceID`, `changes` | Same legacy pull |
| v3 | `protocolVersion: 3`, `mutationID`, `deviceID`, `operations` | Same legacy pull |
| v4 | `protocolVersion: 4`, `mutationID`, `deviceID`, `operations` | Explicit `protocolVersion: 4`; includes folders and tab membership |

Every pull advertises `supportedPushVersions: [2, 3, 4]`. Legacy pull responses retain `protocolVersion: 2`; negotiated v4 responses use `4`. Requests allow at most 1,000 changes/operations, moves allow at most 1,000 unique items, and the inflated JSON body is limited to 8 MiB, including gzip requests.

V4 operations use these forms:

```json
{
  "protocolVersion": 4,
  "mutationID": "550e8400-e29b-41d4-a716-446655440001",
  "deviceID": "550e8400-e29b-41d4-a716-446655440002",
  "operations": [
    {
      "kind": "create",
      "entityType": "folder",
      "entityID": "research",
      "data": {
        "spaceID": "work",
        "parentFolderID": null,
        "title": "Research"
      }
    },
    {
      "kind": "move",
      "items": [{ "entityType": "tab", "entityID": "article" }],
      "destination": {
        "kind": "tabs",
        "spaceID": "work",
        "placement": "spacePinned",
        "pinnedFolderID": "research"
      },
      "before": null,
      "after": null
    },
    {
      "kind": "patch",
      "entityType": "folder",
      "entityID": "research",
      "fields": { "title": "Reading" }
    }
  ]
}
```

This example assumes a live `work` Space and `article` tab. Create supports `space`, `tab` and `folder`; clients omit rank. Folder create requires `spaceID`, nullable `parentFolderID` and `title`; `systemImageName` is optional and nullable. Tab create requires nullable `pinnedFolderID` in addition to the v3 fields. Only `spacePinned` tabs can have a folder. Expansion state remains local.

Patch changes metadata only. Absent fields remain unchanged; explicit null clears nullable metadata. Folder patches accept title/icon, Space and tab patches keep their v3 fields. Location, parent, membership and rank cannot be patched. Delete takes `entityType` and `entityID`.

Move uses typed `items`, so folder and tab IDs cannot be confused. A Space move targets `{"kind":"spaces"}`. A tab/folder move targets `kind: "tabs"` with a Space, placement and required nullable `pinnedFolderID`; folders require pinned placement. Create and move accept typed nullable `before`/`after` anchors: after removing movers, use a live before anchor in the destination, otherwise a live after anchor, otherwise append. Survivors move as one block in request order. Missing IDs remain absent; deleted IDs remain tombstoned.

A folder move carries its current descendants, updates their Space on cross-Space moves, and orders mixed folder/tab siblings on the server. A group containing a folder and its descendant is rejected with `overlapping_items`; moving a folder into its subtree is rejected with `cycle`. Invalid destinations reject the whole operation without moving survivors. Folder deletion tombstones its current subtree and member tabs. Tabs or subfolders already moved elsewhere survive. Space deletion also deletes its folders and non-Favorite tabs. Global `app` Favorites survive deletion of their historical Space; explicit tab deletion remains terminal. Restoring a deleted item requires a new identity.

All operations in a request run in order under the account transaction lock. Each produces an outcome with `operationIndex`, `status` (`applied`, `deleted` or `rejected`) and an optional reason. Semantic rejection allows later operations to continue; a database error rolls back events, entity changes, tombstones and receipt together. Changed peers emit canonical full upserts. Pinning derives a home URL from the latest current URL, retains an existing pinned home, and clears it on unpinning.

Mutation receipts are permanent and shared across v2/v3/v4 by `(userID, mutationID)`. Identical parsed content returns the original receipt after retries, restart, later writes or device rotation. Content identity includes the protocol and ordered operations/changes, with canonical object keys; it excludes `deviceID`. Reusing the ID for different content or another protocol returns HTTP 409 with no writes. Push ACKs include `cursor`, `events`, protocol/mutation identity and, for v3/v4, outcomes. A push cursor is a server high-water mark, **never a replacement for the pull cursor**.

The first v4 pull for a registered device must start at cursor 0. An attempt to start above zero returns HTTP 409 with message `Protocol 4 bootstrap requires cursor 0`. Any legacy pull resets that device's bootstrap marker, so a later upgrade must replay from zero again. Bootstrap state changes and the pull run under the same device transaction lock. Future clients must rebuild a v4 baseline through every page and preserve pending local intent separately; a legacy cursor has skipped folder history. Historical tab upserts without membership return `pinnedFolderID: null` in v4.

Legacy pulls exclude folder events in SQL before applying the page limit and strip `pinnedFolderID` from tab events. The cursor is the last visible event; an empty response leaves it unchanged, including a trailing sequence of folder-only events. Later visible events remain reachable. Legacy ACKs also omit folder events, including Space-delete cascades.

Compatibility guards preserve the folder tree:

- V3 patches and deletes retain membership and mixed sibling ranks. Creating or moving into a pinned Space with live folders returns `rejected` / `upgrade_required`. Explicit moves out to another placement or a folder-free Space remain allowed and clear incompatible membership.
- V2 snapshots cannot express structural intent. Existing tabs whose pinned source or target Space contains folders keep their current Space, placement, rank, folder membership and pinned home while accepting page metadata. New v2 pinned tabs append at the root with a server-assigned rank. Explicit deletes still apply.
- Previously stored receipts replay unchanged. These guards do not provide field-level conflict resolution for unrelated legacy full-snapshot metadata writes.
