# Mobile interwindow drag

## Contract

Two open mobile sidebars may exchange a tab, folder or selected group when they share the exact `BrowserMobileProfileDocument` instance. The source retains ordered typed roots and their captured containers. The destination uses its own displayed Space and stable target. Equal account/profile strings do not authorize a drop between separate documents. External payloads, copied drag items and another app's session are rejected.

The operation changes shared membership/order once through the existing document and v4 persistence path. Each window keeps its selected Space and independent page selection. When the source's active tab leaves that Space, existing workspace fallback selects a surviving visible neighbor. A destination does not automatically select the moved tab. WebKit runtime identities remain owned by each workspace; drag/drop does not transfer a web view between windows.

## Native lifetime

The native [local drag session](https://developer.apple.com/documentation/uikit/uidropsession/localdragsession) and its [local context](https://developer.apple.com/documentation/uikit/uidragsession/localcontext) carry the shared token. Source ownership, destination admission, endpoint lifetimes and preview animations are separate concerns. A participant freezes its base tree before synchronous document observers run. [Hover expansion](mobile-hover-expand.md) can reveal descendants from that base in a controlled local batch; every participant rejects commit until that batch completes. Normal source/destination refresh waits for the relevant native terminals, projection batches and every pending preview. Late callbacks from an older batch cannot unlock a newer drag or commit twice.

Source admission remains valid only while its controller still owns the session and captured document/Space. Destination admission requires an attached, active window and unchanged captured document/Space. Hover and commit revalidate source containers and stable targets against the latest shared snapshot. Deleting or reparenting a captured root or target rejects the complete local drop; current folder descendants remain reducer-owned.

Temporary [`foregroundInactive`](https://developer.apple.com/documentation/uikit/uiscene/activationstate-swift.enum/foregroundinactive) suspends that controller's own admission while retaining the source token for another active destination. Background, disconnect, disappearance or explicit cancellation invalidates the interaction. This policy follows the distinction between a visible inactive scene and a background scene; exact Stage Manager notification ordering needs physical verification. Apple contracts were checked on 2026-10-03.

## Verification boundary

Hosted tests use two real UIWindows and workspaces sharing document/SQLite, with independent engines and selections. Native drag sessions, coordinators and animation completions use protocol fakes. The test host has one UIWindowScene, so these tests do not establish physical inter-scene dragging, window activation order or Stage Manager behavior.

Existing real HTTP scenarios verify the unchanged document/planner operation through localhost NestJS/PostgreSQL, including group replay and cross-Space deletion dominance. They are separate from native participant tests.
