# Confirmed desktop tab close and Archive

Manual Close for a Today tab waits for the engine outcome. `BrowserChromeModel` installs a request nonce before `requestCloseTab`, including when an engine-less tab can finish immediately. Admission leaves the logical tab intact. Repeated requests for the same pending tab are ignored.

The CEF bridge handles a manual close's `beforeunload` dialog with a native confirmation. Return and sheet-scoped Escape keep the tab. Missing presentation context or an existing sheet cancels safely. Browser identity and request nonce reject stale replies. Accepting the dialog is not completion: only `OnBeforeClose` reports `.closed`. `DoClose` tears down the embedded view and is not the model's deletion boundary.

Cancellation clears the request without deleting the tab or registering a close action. Independent URL, metadata, readiness and selection changes remain current. Navigation accepted before the request resumes after cancellation. Pin/Favorite promotion during a pending manual Close retains the persistent identity and makes its closed engine dormant. Remote or structural removal supersedes local confirmation without a second local action.

## Atomic recovery and persistence

On confirmed manual Today Close, the model captures current metadata, creates one fixed archive ID and writes its recovery entry, the remaining session snapshot and the ordinary sync deletion/outbox atomically. The entry preserves the source tab identity, URL, override, title, original Space and activity. A newer selection remains selected. Duplicate callbacks do not repeat the write. The Archive is profile-local; the remote client receives the deletion, not this manual recovery entry.

During an unfinished remote projection, SQLite can contain a remote URL while the live page retains its current URL. The Archive write carries a fixed pre-close projection that includes pending engine creations. SQLite checks the Archive receipt before applying this projection, then validates and archives the live row in the same transaction. This emits only the deletion and cannot replay a stale projection after an already-committed Archive action. A SQL failure rolls back projection, recovery and outbox together.

The engine is already closed when `.closed` arrives. A failed SQLite write retains the exact Archive action and snapshot in the existing FIFO and blocks sync. Later ordinary edits keep their order; Retry commits the same archive ID and payload. The session buffer remains in memory until a successful commit; it does not promise crash recovery for a write the database never accepted.

The normal Close history marker is reserved at logical confirmation, before attempting storage. Persistence failure disables executing browser history. This preserves Close→New Tab ordering when a later edit retries the earlier failed write. A committed deletion uses the existing durable v4 outbox; lost acknowledgements retain mutation IDs and bytes across retry and restart.

## Undo and Redo

`BrowserTabUndoManager` retains Foundation's history and native responder routing. A tab action is a named marker with a unique target. Undo/Redo preflight its asynchronous business action before transferring that marker through Foundation. Only successful engine/storage completion registers its inverse. Cancellation keeps the original action and the remaining branch. Pending transitions disable further Undo/Redo, while ordinary new actions remain available.

Native text actions remain Foundation actions. Tab registrations wait for an open native group to close so a marker cannot misidentify a mixed group. New edits during pending Undo clear its obsolete redo branch without losing those edits. If an outstanding Redo commits after a new edit cleared its old branch, its inverse becomes the newest Undo at actual completion. Reset epochs and request nonces reject stale or duplicate history callbacks. Native menu/keyboard delivery is unchanged; synthetic grouping/action tests do not prove physical input delivery.

Undo Close consumes the Archive entry and creates a fresh tab ID in one transaction before allocating an engine. It restores content, insertion position and applicable selection and reconnects the original creation-history reference. The old tombstone stays terminal. A failed restore keeps the chosen fresh ID and original action pending; Retry rebuilds its snapshot from the latest live edits. It does not replay a stale full snapshot over tabs or renames added during the failure. The ordinary session Retry and close/quit recovery Retry both finish this operation.

Redo Close requests engine confirmation again, creates a new archive ID for the new incarnation and transfers history only after persistence succeeds. Cancel leaves the tab and Redo branch intact. Undo Create also waits for confirmation but creates no recovery entry. A known dormant pinned/Favorite tab has no engine to confirm; Undo Create removes its logical identity directly and durably. Creation Redo preserves a folder only when it still belongs to the destination Space, otherwise restoring at that Space's pinned root.

An already-consumed or cleared Archive entry cannot be restored through stale history. The obsolete action is dropped with an Archive error. If the original Space is gone, Undo cancels and retains recovery; the native Archive surface can select a destination explicitly. Undo history itself is session-local and does not survive restart.

## Scope and evidence

The never-bound timer still uses its earlier expiry path; confirmed timer archival is follow-up work. Persistent-tab unload/reset, structural deletion, remote force-close and window/quit approval retain separate policies. This does not implement beforeunload approval for every close source. Synchronized automatic expiry continues to use the existing conditional server protocol and waits for outstanding manual requests.

Model tests use real SQLite with controlled engine outcomes. They cover atomic Archive/deletion, rollback/FIFO Retry, fresh-ID consumption, multiple Undo/Redo, cancellation, new actions during pending transitions, original creation references, missing entries, dormant engines, closure Retry, cross-Space folders and live-URL projection with pending creation. Store tests cover exact Archive replay after later edits. The HTTP scenario uses two production sync clients and PostgreSQL for SQL failure, immutable lost-ACK replay, restoration, Redo, reopen and tombstone dominance.

Native confirmation tests inject presentation and key events. These seams do not demonstrate a real page's CEF `beforeunload`, native sheet interaction or live callback sequence. The product browser and Helper remain unlaunched.
