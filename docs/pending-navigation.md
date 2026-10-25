# Navigation before browser attachment

The latest accepted address belongs to the logical tab even when its browser does not exist yet. User input must survive a late allocation notification, immediate engine refusal and process restart. Remote initialization must not navigate an already attached page or choose another selected tab as its target.

## Model and persistence

Locally requested tabs, including Undo restoration, are hydrated from the returned runtime ID before `createTab` returns. Their real allocation callback fills a matching empty title only; it cannot replace the URL or revive a tab closed in that interval. A set tracks only those outstanding callbacks, then removes each ID on delivery.

Address submission, bookmark opening and pinned reset use ID-targeted navigation. Before readiness, an accepted user address updates the model and existing transactional session/outbox immediately. Successive accepted addresses retain their immutable FIFO operations. Refused admission creates no new durable intent. Submitting an address to a failed tab also retries its browser with that address; a remote update alone does not retry it.

A per-tab runtime flag protects explicit local navigation from remote initialization until readiness is delivered. The address itself is durable; this flag is not part of the sync schema. Reopened pinned tabs and Favorites retain a newer local URL when their old allocation callback arrives. Pinned home URL, identity, placement, order and selection keep their existing contracts.

Before a remote tab is ready, newer snapshots update its queued target by runtime ID and its logical URL. Pending allocations use the latest binding, not the older callback URL. These writes keep remote-projection origin. Once ready, the existing live URL/history is preserved and normal committed navigation/redirect callbacks update it.

## Engine ordering

The app-owned bridge creates CEF with an empty initial URL while retaining the requested logical URL for runtime selection. Pinned CEF supports this: Alloy skips its initial load for an empty URL (`alloy_browser_host_impl.cc:146–154`); Chrome maps it to `chrome://ignore` to suppress navigation (`chrome_browser_host_impl.cc:31–42`). This avoids CEF scheduling the original URL after `OnAfterCreated` over a newer address.

Each runtime record retains one latest URL and at most one posted drain. The task holds a weak controller and runtime ID, then reads the current record when it executes. Creating/failed records retain their target. The first load waits for the Swift driver's readiness acknowledgement: model `ready` is delivered before any app navigation begins. Close/shutdown invalidates the record or marks it closing, so a posted task cannot load a canceled tab. A ready callback arriving after model termination force-closes that record before the driver's ACK, including remote records not yet represented by a model tab. Retry keeps the same runtime identity and resets the initial gate.

Only bootstrap address reports before the first app navigation are suppressed. There is no URL blacklist or requirement for an exact target callback, which would discard redirects and break Back. Ready navigation retains committed-address semantics; Reload keeps a queued address and valid Back/Forward or Stop can cancel it.

Background targets never select another tab. The app CEF focus handler rejects navigation focus for a background/removed record. Creation, attachment and closure visibility updates also avoid focusing the active page on behalf of a background tab. This is distinct from the still-unverified foreground focus behavior described in `tab-creation-lifecycle.md`.

## Evidence boundaries

SQLite/model tests cover local FIFO writes and reopen, ordinary creation before callbacks, canceled creation, pinned/Favorite reopen, remote supersession before and after allocation, explicit local precedence, live-page preservation and redirects. A localhost scenario uses both real coordinators, session stores, server and PostgreSQL for remote A→B, local C and pending-child deletion.

The actual Objective-C++ queue, CEF bootstrap and focus hooks are compiled and reviewed against the pinned sources. Fake-driver tests do not prove physical CEF navigation, load timing or native focus. No OpenArc/Helper launch or vendor CEF/Chromium change is part of this slice.

Cancelable page close remains a separate defect: CEF can cancel `CloseBrowser(false)` after `beforeunload`, while the model and extension controllers already abandon that runtime identity. The bridge also keeps its closing gate set. This slice does not establish a functioning “stay on page” flow; that needs coordinated close approval before removing the logical tab.
