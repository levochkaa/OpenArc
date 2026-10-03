# Confirmed desktop tab close

Manual Close for a Today tab now waits for the engine outcome. `BrowserChromeModel` installs a request nonce before calling `requestCloseTab`, including when an engine-less tab can finish immediately. Admission means the request started; it does not mean the tab closed. Repeated requests for the same pending tab are ignored.

The CEF bridge handles a manual close's `beforeunload` dialog with a native confirmation. Keep Tab is the default for Return, and sheet-scoped Escape also keeps the tab. Missing presentation context or an existing sheet cancels the request. The bridge checks both the browser instance and request nonce before accepting a reply. Accepting the dialog is not completion: only `OnBeforeClose` reports `.closed`. `DoClose` tears down the embedded browser view and is not the model's deletion boundary.

Cancellation clears the pending request without removing the logical tab, writing a deletion, or registering Undo. URL, metadata, readiness and selection changes that occurred independently while the request was pending remain current. Navigation accepted before the request is retained by the bridge and resumes after cancellation.

On `.closed`, the model captures the current tab content and selection, removes the Today identity, then persists one ordinary ordered session write. A newer selection is preserved. If the tab became pinned or a Favorite while the request was pending, its persistent identity remains and its closed engine becomes dormant. Remote or structural removal supersedes a pending manual request; a late confirmation cannot turn that removal into a second local action.

## Persistence and sync

The engine is already closed when the model receives `.closed`. A SQLite failure therefore retains the logical deletion in the existing session write buffer and blocks sync until Retry commits it. Later ordinary edits retain FIFO order. This path does not claim to keep the engine alive after a failed database write.

A committed deletion uses the ordinary durable v4 outbox. A lost acknowledgement preserves the mutation UUID and payload bytes across retry and restart. Existing Undo registers only after confirmed closure and restores content with a fresh sync identity; the old tombstone remains terminal. This is the existing Undo mechanism, not a new durable history format.

## Scope and verification

This foundation does **not** insert manually closed Today tabs into the durable Archive. Archive/history integration and asynchronous Redo confirmation remain follow-up work. Timer expiry, structural deletion, remote projection, shutdown and Undo/Redo have explicit separate close paths. Existing pinned/Favorite close and reset behavior is retained; this slice does not add beforeunload-aware persistent-tab unloading or window/quit confirmation.

Model tests use the production model and real SQLite with controlled engine outcomes. They cover cancellation, stale replies, latest content and selection, promotion, readiness during a pending close, remote supersession, failed writes and Retry. Native confirmation tests exercise the AppKit helper with an injected presenter. The `desktop-confirmed-close` HTTP scenario uses two production sync clients and PostgreSQL to check cancellation, failed deletion persistence, immutable lost-ACK replay, fresh-ID Undo and tombstone dominance; it explicitly expects Archive to remain empty.

These test seams do not demonstrate a real page's CEF `beforeunload` event, native sheet interaction, or the live `DoClose`/`OnBeforeClose` sequence. Build and test results are recorded separately in the task checkpoint; no browser launch is implied by this document.
