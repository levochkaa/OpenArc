# Conditional automatic expiry

This is the server foundation for automatic archiving. It does not enable a mobile timer or make the existing desktop timer safe for synchronized profiles. Client scheduling, durable recovery import and native settings remain required.

## Product policy

Automatic expiry uses activity reported to the server. A completely offline device can have newer activity that no other device knows about. An accepted server archive can therefore remove that identity when the device reconnects. The updated client must preserve its divergent local content before applying that deletion, alongside the server's canonical recovery content. Restore creates a fresh tab ID; stale edits must never resurrect the deleted ID.

This policy is a TheBrowser design decision.

## Wire contract

Version 5 uses the existing authenticated `POST /v1/sync/push`, account lock and permanent mutation receipts. It accepts expiry operations only; ordinary create/patch/move/delete operations remain v4. Discover version 5 through `supportedPushVersions` before creating these requests. Do not convert an expiry request to an ordinary delete on an older server.

```json
{
  "protocolVersion": 5,
  "mutationID": "550e8400-e29b-41d4-a716-446655440001",
  "deviceID": "550e8400-e29b-41d4-a716-446655440002",
  "operations": [{
    "kind": "expire",
    "entityType": "tab",
    "entityID": "article",
    "expectedServerSeq": 123,
    "inactiveForSeconds": 2592000
  }]
}
```

At most 100 operations are admitted. `expectedServerSeq` is a positive safe integer identifying this tab's latest canonical upsert, not the account's pull cursor. Allowed inactivity intervals are 43,200 / 86,400 / 259,200 / 604,800 / 2,592,000 seconds. The client supplies neither a cutoff nor archive content.

Within the account transaction, the server resolves the permanent tombstone first. A live tab must have the exact expected event sequence, temporary placement and known finite activity at or before server time minus the interval. Any intervening activity, URL, title, pin, move or rank update changes the sequence and invalidates the captured candidate. Null, infinite and future activity are conservative. Expiry uses server time, so a fast client clock cannot expire a fresh tab.

Outcomes are `applied`, `deleted` for an existing tombstone, or `rejected` with `missing`, `state_changed`, `not_temporary`, `activity_unknown`, `not_expired` or `response_limit`. Normal rejection returns current canonical state where available. Successful expiry keeps survivor ranks; harmless gaps avoid invalidating other candidates merely by renumbering peers.

The complete serialized ACK is bounded to 4 MiB, with space reserved for outcomes and the response envelope. Before writing, the server reserves space for the full delete event and its recovery payload. An operation that cannot fit is rejected with `response_limit`, without deleting the tab or returning an oversized canonical echo. Recovery is never truncated. Later small operations can still proceed. A smaller fresh request can retry a candidate; an individually oversized tab remains active.

The same UUID/content always returns its original receipt, including rejection. A previously rejected expiry does not become accepted merely because time passed. A new sweep uses a new UUID and fresh sequence. Reusing a UUID with different content or a different protocol returns conflict. Storage failure rolls back all accepted operations, events, tombstones, recovery data and receipt together. A push cursor never advances the client's pull cursor.

## Recovery events and upgrade

An accepted expiry creates an ordinary tab `delete` event with `data.id` and additive `data.autoArchive`:

```json
{
  "id": "article",
  "autoArchive": {
    "archivedAt": "2026-10-03T12:00:00.000000Z",
    "sourceServerSeq": 123,
    "tab": { "id": "article", "spaceID": "reading", "placement": "temporary", "rank": 0,
      "urlString": "https://example.test/article", "pinnedFolderID": null }
  }
}
```

The actual `tab` is the complete prior canonical event payload, including its original activity precision and metadata. Historical missing `pinnedFolderID` becomes null, as in v4. The content comes only from this account's stored state. The delete, permanent tombstone and recovery content commit together. A retry or later delete echo returns the original event, timestamp and content; a manual tombstone never gains invented recovery.

Older Swift clients decode only `data.id` and discard the recovery extension. They still honor deletion, but may advance their cursor without importing Archive content. Therefore v5 pull requires a new cursor-zero bootstrap after registration or any older-version pull. Migration `006_sync_expiry.sql` adds the per-device marker. V5 reads the full folder-aware history; v4/legacy reads reset expiry bootstrap capability. The marker proves a read request, not client durability or absence of offline edits.

Future upgraded clients must read every bootstrap page and atomically commit baseline, recovery receipts, queue reconciliation and cursor. Identify recovery by the immutable delete event and retain a receipt after Restore/Delete/Clear so bootstrap cannot refill a cleared Archive. Before applying a new expiry tombstone, preserve locally divergent pending URL/title content too: the server payload cannot contain unreported offline changes. These client behaviors are not implemented by the server extension alone.

Archive payloads remain in permanent server events and receipts. Local Clear Archive is not server erasure, and no retention or secure-erasure guarantee is added. Recovery contains logical tab metadata, not WebKit navigation history, cookies, passwords or live page state.

## Client work required before enabling timers

Use a separate conditional intent with no optimistic local tombstone. The existing `archiveTab` path immediately emits an ordinary delete and permanently hides the identity; it cannot represent a rejected expiry safely. ACK/pull must reconcile recovery, current state and the immutable queued intent atomically. Loss of the response or process restart must neither lose recovery nor duplicate it.

One scheduler per profile must wait for scene hydration, current pull completion and pending writes, protect every attached window's selected tab, use bounded passes and stop on persistence failure. Long-lived active selections need limited activity refresh. Candidate selection and submission must revalidate current IDs, activity, placement and leases. A failed or rejected automatic operation must not become a fixed ordinary delete in the manual Retry FIFO. Explicit manual Close keeps its existing semantics.

The current desktop `archiveExpiredTemporaryTabs` invokes ordinary close from a local timer, including before activation's pull. That path must be replaced as part of client integration. Mobile expiry remains disabled until these storage, scheduling and recovery rules have full client/server proof.
