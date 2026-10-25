# Conditional automatic expiry

The server supports conditional expiry, and shared Swift clients durably queue its requests and import recovery data. Mobile has one scheduler per profile and an explicit Auto-Archive timing menu; new profiles start Off. Synchronized desktop profiles remain Off until their native durable Archive restoration surface is available.

## Product policy

Automatic expiry uses activity reported to the server. A completely offline device can have newer activity that no other device knows about. An accepted server archive can therefore remove that identity when the device reconnects. The updated client must preserve its divergent local content before applying that deletion, alongside the server's canonical recovery content. Restore creates a fresh tab ID; stale edits must never resurrect the deleted ID.

This policy is an OpenArc design decision.

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

Updated Swift clients read every bootstrap page before atomically committing baseline, recovery receipts, queue reconciliation and cursor. They negotiate v5 reading after folder support; ordinary local writes stay v4. A registered replacement device can demand cursor zero again. Failure during paging or storage leaves the previous durable state intact. A server downgrade fails closed; it does not silently bypass the recovery read contract.

Recovery is imported before applying deletion or removing an acknowledged queue row, including additive recovery in v2/v3/v4 responses. Migration `addSyncExpiryRecovery` adds a separate recovery flag and import receipts without rewriting old outbox BLOBs, UUIDs or FIFO positions. Event identity is derived from account/server, sequence and tab ID. The first import stores canonical content and divergent final pending URL/title/explicit title-clearing content, plus a distinct current local snapshot if needed. Pending content is inspected even when an older binary already saved the tombstone and hid the tab. Local variants are recoverable Today entries; they do not revive the old tab or its pinned placement. Data already discarded by an old binary cannot be reconstructed.

The first-import receipt and Archive receipts survive Restore/Delete/Clear. Repeated ACKs or bootstrap cannot refill a consumed Archive or invent new local variants from later state. Malformed recovery or conflicting immutable content aborts application. A durable archive revision notifies attached mobile scenes even when their tab snapshot is unchanged; live page engines and independent selections are retained.

Archive payloads remain in permanent server events and receipts. Local Clear Archive is not server erasure, and no retention or secure-erasure guarantee is added. Recovery contains logical tab metadata, not WebKit navigation history, cookies, passwords or live page state.

## Durable conditional intents

`BrowserSyncService.enqueueExpiry` requires an active authorized runtime, capabilities 4/5 from the current session's completed pull and durable v5 recovery adoption. It generates a fresh mutation UUID and persists a separate `.expiry` queue row before waking the sender. There is no optimistic local tombstone, Archive entry, snapshot change or pending overlay. Later ordinary edits retain their own v4 rows and order. The scheduler must supply current canonical tab sequences, never the account cursor.

`addExpirySyncOutbox` widens only the queue's version constraint to 2/3/4/5. It copies existing BLOBs and UUIDs directly and preserves FIFO positions and the consumed-row AUTOINCREMENT high-water mark. The ordinary-write mode stays 4. An identical pending UUID/content enqueue is a no-op; a different codec or content under that queued UUID fails. After consumption, the server's permanent receipt remains the source of idempotency; the coordinator always chooses a new UUID for a new intent.

Requests contain 1–100 distinct tab IDs with positive JavaScript-safe canonical sequences and one supported interval. Encoded request size is checked before insertion. The typed transport and coordinator both validate protocol, UUID, outcome count/indexes, status/reason and canonical events before acknowledging a row. An `applied` outcome requires the matching full recovery delete; a `deleted` outcome may reference an earlier manual tombstone. Rejected outcomes cannot apply a delete, and `response_limit` carries no canonical event.

ACK atomically imports available recovery, applies canonical state, removes only the acknowledged row and projects the remaining queue. It never advances the pull cursor. Rejection is terminal for that UUID; no unconditional delete is substituted. Lost responses and restart preserve queued intent. A server downgrade stops sending without rewriting or skipping rows. Replacement-device cursor-zero recovery bootstrap accepts retained v4/v5 rows before retrying their original receipts.

Explicit calls to `enqueueExpiry` retain their immutable FIFO behavior: later selection or activity does not cancel the request. Existing queue rows without automatic-attempt metadata receive this conservative treatment too. The automatic scheduler uses the additional pre-send checks below.

## Mobile automatic scheduling

The UIKit Archive menu offers Off or 12 hours / 1 / 3 / 7 / 30 days. Enabled state and interval are saved together in local profile preferences and are not synchronized. Off is the default; the retained 30-day interval does not enable scheduling. A failed setting write leaves the prior choice active and exposes Retry for the exact attempted choice. Invalid/unreadable settings block scheduling until successfully reloaded.

`BrowserMobileProfileDocument` owns profile scheduling. At least one attached scene must be active, and every attached scene must finish logical restoration. Registry readiness includes an attached window whose asynchronous profile load has not yet produced a selection lease. This is not a claim that every lazy WebKit page is loaded. Selections in inactive/background attached windows remain protected; disconnect releases their leases. Failed writes, terminal recovery state and an Archive mutation in progress block admission.

For a sync-bound profile, `BrowserSyncService` checks after a successful complete pull and v5 recovery adoption. Active selected tabs receive a limited activity refresh even with Auto-Archive Off; emitted activity rows must be ACKed and pulled before candidate capture. The ordinary outbox must be empty. Defaults are at least 300 seconds between activity refreshes and 60 seconds between automatic candidate passes during steady operation. Explicit settings/lifecycle wakes and clock rollback can reset a pass; terminal ACK/rejection alone does not create a tight retry loop. Existing 15-second foreground sync polling supplies wakeups, rather than an independent expiry networking loop.

Candidate scanning runs on the GRDB reader and returns at most 100 temporary tabs with positive canonical entity sequences. Both canonical and current local activity must be known, finite and older than the chosen interval. Protected IDs, missing rows, tombstones, non-Temporary placement and future activity are excluded. The scan currently decodes/sorts the full baseline; bounded result count is not a measured large-profile memory or latency guarantee. Enqueue atomically checks that the baseline bytes still match and the outbox is still empty, then persists the conditional batch and its automatic-attempt marker. Current interval/readiness and selection protection are rechecked after the asynchronous scan.

Candidate order rotates after the last admitted `(serverSeq, tabID)` so unchanged rejected tabs cannot monopolize the first 100 positions. An ACKed `response_limit` backs off that exact tab/sequence for 60 seconds, then doubles up to one hour. Cooling candidates are excluded before applying the batch limit; a new canonical sequence is immediately eligible. This in-memory cache holds at most 1,000 entries and resets with the runtime/account generation. A backwards clock restarts the current bounded delay. First-send validation checks the queued IDs directly, so a rotated batch is not canceled merely because it is outside the initial prefix. Possibly committed retries retain their immutable payload and bypass this candidate selection.

Migration `addAutomaticExpiryAttempts` adds metadata separate from immutable request BLOBs. Immediately before the first network attempt, the service revalidates the entire batch against current readiness, interval, protected IDs, local/canonical candidates, baseline and absence of other pending rows. Invalidating any member removes the whole never-attempted batch without changing live state or Archive; a later pass can capture fresh candidates. Selection, ordinary activity/edit, Off or restart with an unavailable delegate can therefore cancel an automatic intent that has never been attempted.

The transaction marks the batch attempted before handing its unchanged payload to transport. From that point, a lost response, cancellation, pause, process restart or later selection cannot prove that the server did not commit. Retry uses the original UUID/content; it does not silently discard or rewrite the request. Even a process exit between marking and sending is treated conservatively as an unknown outcome. Accepted expiry imports recovery; explicit Restore creates a new identity. A failed or rejected synchronized expiry never becomes an ordinary delete in the manual Retry FIFO.

Never-bound mobile SQLite profiles use local Archive transactions instead of server expiry. While an eligible scene is active, the document checks at 60-second intervals and on setting/lifecycle activation, refreshes active activity at most every 300 seconds during steady operation, and archives up to 100 eligible Today tabs per pass. It rechecks current activity, placement, protection and ownership for each entry and stops at a persistence failure. Archive insertion and active deletion remain atomic; a failed admitted local write retains its fixed Archive/action IDs in the existing bounded Retry FIFO. Bound profiles never fall back to this local path during Pause, logout, offline use or ownership-read failure. Manual Close retains its existing semantics.

## Desktop boundary and verification limits

Desktop `archiveExpiredTemporaryTabs` checks durable sync ownership on every entry. A bound profile requests the shared conditional pass; native Settings → General offers Off or 12 hours / 1 / 3 / 7 / 30 days for that profile. New profiles start Off. A retained lifetime alone does not enable expiry. The setting is local and does not synchronize. Pause, sign-out, offline use and owner-read failure never fall back to unconditional local expiry.

The model strictly loads both enabled state and lifetime. Missing values yield Off and the retained 30-day default; malformed/unreadable values block scheduling and expose Retry. A selected choice writes both values atomically, then publishes it and wakes the existing coordinator. A failed write retains the previous committed mode and an exact retry intent, including Off. Off remains editable while engine creation, Archive work or a session write prevents scheduling. Changing the legacy lifetime revalidates both fields before clearing an earlier read error. Settings observes account/model changes so an already-open pane switches from the local lifetime control to the synchronized picker after binding.

The desktop delegate requires an active app, complete logical restoration/projection, ready engines, no failed session writes and no Archive operation. It protects the selected stable tab ID and exposes the enabled interval only with verified durable ownership. The shared coordinator supplies fresh-pull/activity drain/candidate scanning, cadence, first-send validation, attempted markers and exact retry; the desktop model adds no duplicate networking scheduler. Turning Off cancels eligible never-attempted automatic batches, but cannot discard an outcome that may already have committed on the server. Existing remote application force-closes canonical deleted tabs; this is not a new beforeunload approval contract.

Never-bound profiles keep the hourly local timer, 30-day default and current-Space scope. Local sweeps now confirm one candidate at a time, recheck eligibility/ownership on final closure and atomically insert durable Archive with the deletion. A tab used or otherwise disqualified during closure retains its stable identity with a replacement engine. First sync adoption waits for failed local persistence to recover. See `confirmed-tab-close.md` for the transaction and lifecycle policy.

The desktop model records outgoing/incoming ready-tab viewing, a final app-resign instant and monotonic whole-second activity. It carries already-merged remote activity into live-engine projections, protects selected stable sync IDs, blocks scheduling during pending creation/restoration/projection or failed writes, and stops sync runtime on closure/background. Foreground activity is app-level across open profile windows; key-window focus is not inferred. These are model/console-test seams, not evidence of a launched CEF runtime.

Controlled clocks, scene callbacks and hosted native menu actions do not establish physical gestures, actual OS background execution or completely offline cross-device protection. Physical desktop Archive interaction, CEF restoration and large-profile import/replay profiling remain unverified.


## Native desktop Archive

File → View Archive and Command Bar → View Archive open one AppKit recovery window for the owning profile. The window reads the shared durable Archive in 50-entry pages, supports literal/Unicode-folded search, stable-ID selection, Restore, Delete and confirmed Clear. Clear captures an insertion-sequence boundary before confirmation; entries added later survive, including when Retry follows a storage failure. Async page generations reject stale search results. Private and installed web-app windows cannot expose regular profile recovery.

Command Bar → Clear Archive and File → Clear Archive reuse that window's existing confirmation. Both commands retain the originating model across Command Bar dismissal, then recheck its registered live owner; a focus change cannot redirect them to another profile. Menus and customized shortcuts resolve the focused Archive (including its sheet) or browser before dispatch. Both commands are unassigned by default and remain available without a ready page engine. A repeated Clear while confirmation is pending cannot replace or widen its captured boundary; Cancel leaves recovery unchanged, and Retry reuses the same boundary.

Restore re-reads the entry and current logical tree. If its original Space is gone, the user must choose an existing destination; no implicit Space is created. A fresh stable tab ID, complete session snapshot, ordinary v4 outbox mutation and consumed Archive receipt commit in one SQLite transaction before an engine is requested. The old ID stays tombstoned. The restored Today tab becomes selected in its destination, while existing engines and other Space selections remain intact. Only URL/title metadata is restored, not the archived page's navigation history or live state.

Pending session writes or incomplete logical projection block Restore. Storage failure leaves the current model, selection, engines and Archive unchanged; explicit Retry rebuilds the action from the latest live tree. This action is not placed in the failed-session snapshot buffer: consuming recovery before publishing a restored tab there would let a later snapshot silently discard it. After commit, engine refusal retains the durable new tab with ordinary creation Retry. A crash between commit and engine allocation is recovered through session startup. Delete/Clear affect only recovery payloads and preserve compact receipts, the active snapshot and sync queue.

Recovery imports notify the Archive window even when the active tab snapshot does not change. Cmd+W closes that auxiliary window; Cmd+F focuses its search. Closing the owner closes its Archive, and closing Archive cancels actions that have not started. Already admitted database operations may finish.

This surface exposes stored local/server recovery, including confirmed manual Close and never-bound automatic archival. Bound automatic expiry remains explicit opt-in through the native controls above. Broader persistent-tab and window/quit beforeunload policy remains separate work. Offscreen AppKit tests and fake-driver restoration do not establish a launched CEF page or physical keyboard/pointer behavior.
