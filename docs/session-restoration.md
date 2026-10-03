# Session restoration and callback identity

## Boundary

The durable session describes logical tabs, their stable sync IDs, Spaces, folders, order and selection. An engine ID identifies the runtime record for one logical tab. Restoring those relationships must not depend on callback delivery order.

`BrowserTabController.createTab` allocates the runtime record and calls its `didCreateTab` delegate before invoking `CefBrowserHost::CreateBrowser`. The Swift driver delivers that callback asynchronously on the main queue. This is a placeholder notification, not evidence that CEF has created or loaded a page. The real `OnAfterCreated` path attaches the browser later. Readiness and immediate engine refusal use the separate [tab creation lifecycle](tab-creation-lifecycle.md).

## Current repair

The previous startup path ignored the returned runtime ID and consumed saved tabs with `removeFirst()` when callbacks arrived. Reversed callbacks could associate a saved sync ID with the wrong URL/metadata. An ordinary new tab callback could also consume a restored identity and prematurely finish restoration. Persistence was suppressed while waiting, which left intervening user edits vulnerable to a deferred remote snapshot.

The repair hydrates the entire logical session synchronously from the saved snapshot and returned engine IDs. After `handleContextReady`, every saved tab is represented and ordinary user actions can persist normally. Later placeholder callbacks update only the corresponding runtime record; they cannot allocate a second logical tab, restore a removed identity or override a later user action. Saved order and selection are established independently of callback order.

The change preserves snapshot/SQLite schemas, stable IDs, profile isolation, pinned home URLs, folder membership, normal new-tab creation and existing live-engine reconciliation. It does not rewrite committed sync mutations or imply CEF readiness.

The restored runtime-ID set is retained for the model's lifetime so duplicate delayed callbacks cannot revive a removed restored tab. Its size is bounded by the initial saved session; later ordinary tab creation does not grow it.

Deleting a Space also cancels pending remote creations belonging to that Space, except global Favorites. Otherwise a late callback could assign a deleted Space's ordinary tab to the fallback Space and persist it without a user move. Canceled callbacks are consumed without recreating the tab. Global Favorites retain their independent lifetime.

Unknown or duplicate close receipts do not save or schedule sync. Closing an already-removed restored placeholder does not issue a second engine close; the controller already canceled its pending record, and closes a late real browser when that record no longer exists.

## Durable handoff

SQLite ACK/pull already commits the full projected snapshot together with baseline/outbox/cursor changes. A normal restart reads that snapshot, including tabs whose placeholder callbacks were never delivered. There is no demonstrated need to introduce an additional persisted application revision merely to recover this interruption. Tests must reopen real SQLite before claiming this behavior verified.

Late attachment of an applier to an already-running coordinator still lacks repeat delivery when the stored snapshot is unchanged. Production currently attaches the model during synchronous profile construction, before its queued sync tasks run. A future attachment/replacement workflow must define delivery acknowledgement or explicit replay; the current callback fixes do not establish a general delivery protocol.

## Verification limits

Regression cases cover reversed and duplicate callbacks, local creation and edits before callback delivery, saved selection, remote supersession, deleting pending remote children, global Favorite survival and offline SQLite reopen. Fake engine callbacks establish model behavior, not actual CEF loading or native UI quality.

The subsequent tab-creation slice handles `CreateBrowser(false)` and exposes actual ready/refused states with Retry. The [pending-navigation repair](pending-navigation.md) also hydrates ordinary local/Undo creations synchronously and retains newer addresses before attachment. An accepted request that never completes remains a gap. Do not label a timeout as a confirmed engine failure or equate the placeholder callback with successful page creation. No CEF/Chromium source, artifacts or baseline changes are part of these repairs.
