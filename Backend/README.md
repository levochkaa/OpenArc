TheBrowser sync backend runs NestJS on Node.js 26 with PostgreSQL 17. The checked-in [OpenAPI contract](openapi.yaml) is served at `/openapi.yaml`; runtime Swagger documentation is available at `/docs`. Apply migrations before starting the server. Migration `005_sync_folders.sql` adds folders, tab membership and per-device v4 bootstrap state; `006_sync_expiry.sql` adds the recovery-aware v5 pull marker.

For local development, install dependencies with `npm ci` in `Backend`, copy `.env.example` to `.env`, and configure an isolated database plus a local JWT secret. Run `npm run migrate`, then `npm run dev`. The default API port is 8080. The repository's `script/test_local_sync.sh` starts and removes its own disposable PostgreSQL container and runs authenticated HTTP integration tests; it does not use the development database.

The shared desktop/mobile Swift coordinator negotiates v4 after draining immutable v2/v3 work and completing a cursor-zero folder bootstrap. Legacy clients can keep using v2/v3 within the compatibility rules below. The backend also exposes conditional v5 expiry; shared Swift clients queue conditional requests and import recovery durably. Mobile scheduling requires an explicit local timing choice and starts Off. Synchronized desktop automatic expiry remains Off until native Archive restoration is available.

Apple identity verification accepts the configured `APPLE_CLIENT_ID`, or an explicit comma-separated `APPLE_CLIENT_IDS` allowlist. The list replaces the fallback and must contain the exact provisioned desktop/mobile client IDs; no mobile audience is added automatically. Entries are trimmed and deduplicated. Empty entries, wildcards, URLs and malformed identifiers fail startup. Apple issuer, signature and audience validation remain required. Cross-app Apple account grouping and device provisioning must be verified separately.

`script/test_swift_sync.sh` runs the production desktop Swift transport fixture. `script/test_mobile_sync.sh --ios-destination 'platform=iOS Simulator,id=SIMULATOR-UUID'` runs its mobile counterpart in the dedicated test host. Each runner creates an isolated localhost database and fixture identities; neither proves a real Apple sign-in exchange.

| Protocol | Push body | Pull behavior |
| --- | --- | --- |
| Legacy v1 | `deviceID`, `changes` | Omit `protocolVersion`; Space/tab events only |
| v2 | `protocolVersion: 2`, `mutationID`, `deviceID`, `changes` | Same legacy pull |
| v3 | `protocolVersion: 3`, `mutationID`, `deviceID`, `operations` | Same legacy pull |
| v4 | `protocolVersion: 4`, `mutationID`, `deviceID`, `operations` | Explicit `protocolVersion: 4`; includes folders and tab membership |
| v5 | Same envelope with `protocolVersion: 5`; expiry operations only | Explicit `protocolVersion: 5`; cursor-zero recovery bootstrap after registration or older pull |

Every pull advertises `supportedPushVersions: [2, 3, 4, 5]`. Legacy pull responses retain `protocolVersion: 2`; negotiated v4/v5 responses echo their read version. V1–v4 requests allow at most 1,000 changes/operations; v5 permits at most 100 expiry operations. Moves allow at most 1,000 unique items. Inflated JSON requests are limited to 8 MiB, including gzip; v5 ACKs are additionally bounded to 4 MiB.

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

Patch changes metadata only. Absent fields remain unchanged; explicit null clears nullable metadata except `lastActivityAt`, which retains known activity. Folder patches accept title/icon, Space and tab patches keep their v3 fields. Location, parent, membership and rank cannot be patched. Delete takes `entityType` and `entityID`.

Move uses typed `items`, so folder and tab IDs cannot be confused. A Space move targets `{"kind":"spaces"}`. A tab/folder move targets `kind: "tabs"` with a Space, placement and required nullable `pinnedFolderID`; folders require pinned placement. Create and move accept typed nullable `before`/`after` anchors: after removing movers, use a live before anchor in the destination, otherwise a live after anchor, otherwise append. Survivors move as one block in request order. Missing IDs remain absent; deleted IDs remain tombstoned.

A folder move carries its current descendants, updates their Space on cross-Space moves, and orders mixed folder/tab siblings on the server. A group containing a folder and its descendant is rejected with `overlapping_items`; moving a folder into its subtree is rejected with `cycle`. Invalid destinations reject the whole operation without moving survivors. Folder deletion tombstones its current subtree and member tabs. Tabs or subfolders already moved elsewhere survive. Space deletion also deletes its folders and non-Favorite tabs. Global `app` Favorites survive deletion of their historical Space; explicit tab deletion remains terminal. Restoring a deleted item requires a new identity.

All operations in a request run in order under the account transaction lock. Each produces an outcome with `operationIndex`, `status` (`applied`, `deleted` or `rejected`) and an optional reason. Semantic rejection allows later operations to continue; a database error rolls back events, entity changes, tombstones and receipt together. Changed peers emit canonical full upserts. Pinning derives a home URL from the latest current URL, retains an existing pinned home, and clears it on unpinning.

Tab activity is nondecreasing across legacy/v2/v3/v4 writes: existing live tabs retain the maximum timestamp, and null or omission cannot erase a known value. New tabs with no activity remain null. Newly written tab-upsert events encode non-null activity in UTC with six fractional digits. ACK and pull may also echo historical events in their unchanged format. Stored receipts remain unchanged, and tombstones always dominate activity. See [monotonic tab activity](../docs/sync-protocol.md#monotonic-tab-activity).

Mutation receipts are permanent and shared across v2/v3/v4/v5 by `(userID, mutationID)`. Identical parsed content returns the original receipt after retries, restart, later writes or device rotation. Content identity includes the protocol and ordered operations/changes, with canonical object keys; it excludes `deviceID`. Reusing the ID for different content or another protocol returns HTTP 409 with no writes. Push ACKs include `cursor`, `events`, protocol/mutation identity and, for v3/v4/v5, outcomes. A push cursor is a server high-water mark, **never a replacement for the pull cursor**.

The first v4 pull for a registered device must start at cursor 0. An attempt to start above zero returns HTTP 409 with message `Protocol 4 bootstrap requires cursor 0`. Any legacy pull resets that device's bootstrap marker, so a later upgrade must replay from zero again. Bootstrap state changes and the pull run under the same device transaction lock. Future clients must rebuild a v4 baseline through every page and preserve pending local intent separately; a legacy cursor has skipped folder history. Historical tab upserts without membership return `pinnedFolderID: null` in v4.

Legacy pulls exclude folder events in SQL before applying the page limit and strip `pinnedFolderID` from tab events. The cursor is the last visible event; an empty response leaves it unchanged, including a trailing sequence of folder-only events. Later visible events remain reachable. Legacy ACKs also omit folder events, including Space-delete cascades.

Compatibility guards preserve the folder tree:

- V3 patches and deletes retain membership and mixed sibling ranks. Creating or moving into a pinned Space with live folders returns `rejected` / `upgrade_required`. Explicit moves out to another placement or a folder-free Space remain allowed and clear incompatible membership.
- V2 snapshots cannot express structural intent. Existing tabs whose pinned source or target Space contains folders keep their current Space, placement, rank, folder membership and pinned home while accepting page metadata. New v2 pinned tabs append at the root with a server-assigned rank. Explicit deletes still apply.
- Previously stored receipts replay unchanged. These guards do not provide field-level conflict resolution for unrelated legacy full-snapshot metadata writes.

## Conditional expiry (v5)

`{kind:"expire", entityType:"tab", entityID, expectedServerSeq, inactiveForSeconds}` uses the exact latest canonical tab event and one of 43,200 / 86,400 / 259,200 / 604,800 / 2,592,000 seconds. Under the account lock the tab must still be temporary, its activity finite/known and old enough according to server time. Stale metadata, activity or placement rejects expiry and echoes the canonical state. A permanent tombstone remains terminal. Rejected UUIDs stay rejected on retry, even after time passes.

Accepted expiry writes `data.autoArchive` into the immutable delete event: server `archivedAt`, `sourceServerSeq` and the complete prior canonical tab payload. Deletion, recovery data, tombstone and receipt commit together; manual deletions do not gain recovery. If a full event cannot fit the bounded ACK, `response_limit` leaves that operation unapplied and omits the oversized echo. Preimages are never truncated. Rank gaps are retained so one expiry does not invalidate other captured candidates by renumbering peers.

V5 pull requires cursor 0 after registration or a legacy/v4 read on this server. It replays recovery that older clients may have discarded. It does not prove durable client application or absence of offline use. Updated Swift clients negotiate v5 reading and atomically import canonical recovery plus divergent local content, with durable receipts after Restore/Delete/Clear. Ordinary writes remain v4. A separate immutable v5 queue sends conditional expiry without optimistic deletion; rejection consumes only that intent. The opt-in mobile scheduler protects attached selections and revalidates never-attempted automatic batches before sending. Durable attempt metadata preserves exact retry after an ambiguous response. Desktop automatic expiry remains disabled for sync-bound profiles; never-bound mobile profiles use local Archive transactions. See [the full contract and verification limits](../docs/sync-expiry.md).
