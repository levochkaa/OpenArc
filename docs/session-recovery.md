# Session write recovery

`BrowserChromeModel` owns the volatile recovery state. `BrowserTabSessionSnapshotStoring.writeSessionBatch` throws on failure; SQLite commits an ordered batch in one transaction. Every local action retains its snapshot and explicit moved tab IDs. A failed drag followed by a rename must replay both actions, even if a later move returns the UI to its original order.

The transaction covers the session snapshot, sync baseline/tombstones and immutable outbox rows. Each action diffs against the preceding action in that transaction. A failure anywhere rolls back the entire batch. Remote projection actions retain their origin and do not create local echo mutations. JSON fallback validates and encodes every intermediate action before atomically replacing the file with the final snapshot. Ephemeral stores explicitly opt out of durability.

## Failure policy

The healthy path writes directly. After failure, the model retains a FIFO bounded to 32 entries and an estimated 32 MiB of encoded snapshots. Identical consecutive writes do not consume another entry; distinct explicit actions are not collapsed into the latest snapshot. Size encoding occurs only on the failure path.

- A transient write failure offers Retry. A later ordinary save also retries the complete prefix atomically. Only durable success clears the failure and resumes sync.
- `mutationTooLarge`, duplicate move IDs, snapshot encoding failure or buffer overflow requires recovery outside the normal retry path. The terminal state neither evicts older actions nor reports a later small save as success. It stops growing the FIFO and disables Retry. The current model remains available for export.
- The persistent AppKit banner offers Save a Copy. It captures the latest session when the save panel is accepted and writes JSON atomically. Export does not clear the error or claim that sync succeeded. This copy contains session tabs and Spaces, not cookies, credentials or a complete profile backup. There is no guided copy-import flow in this slice.
- Ordinary window close and application quit preflight all affected models before teardown. Cancel leaves models writable. Retry rechecks every model. Close Without Saving rechecks models after the modal response and explicitly discards writes that still fail. A successful preflight prevents a second unguarded save during teardown. Open profiles cannot be deleted from another window's Settings.

## Sync guard

The profile coordinator blocks local sending and incoming durable ACK/pull application while the model owns uncommitted writes. Blocking invalidates the request generation and cancels debounce, retry, polling and the current worker. A canceled transport may still return: generation and cancellation are checked after each network await and after applying a projection to the model. The worker handle remains owned until it returns, preventing overlapping workers.

Recovery obtains fresh capabilities and remote events before replay. An old response remains invalid even when saving recovers before it arrives. Sign-out/relogin does not clear the profile's failure guard, and other profiles remain independent. Direct/deferred model projections are rejected during failure; stale deferred state is not replayed after recovery.

## Verification and limits

Swift Testing covers real SQLite rollback, FIFO move identity, projection no-echo, JSON failures, repeated failures, terminal limits, closure cancellation/retry/discard and native recovery controls. Coordinator tests use real SQLite with a cancellation-ignoring held transport to exercise late ACKs, interrupted paged pulls, auth generations and failures caused by the model applier itself.

`./script/test_swift_sync.sh` includes the mandatory `persistence-retry` case. It invokes the production model drop path with a fake engine, injects a SQLite abort, buffers rename/delete, retries through the real coordinator/HTTP server/PostgreSQL, loses an ACK, compares immutable payload bytes and checks two-client convergence against a stale offline edit of a deleted tab. Its completion manifest requires all 15 scenarios.

The FIFO is in memory and cannot survive a process crash, forced OS/CEF shutdown or power loss while disk writes fail. Terminal errors have export/discard, not in-place correction or admission control. Separate selected-tab/Space preferences remain best effort after the snapshot commit. Large snapshots and pending-tail replay still run synchronously on MainActor; background persistence, durable pending model revisions, safe queue retention and folder sync remain open. Native modal interaction and live CEF rendering were not exercised because launching TheBrowser/Helper is outside current authorization.
