# Adding rows to an active mobile drag

## Interaction contract

During a native drag, tapping another row in the originating sidebar can add that tab or folder to the group. Each callback returns one new `UIDragItem`. The semantic move order follows the frozen sidebar, including temporarily revealed descendants; UIKit's native item append order is independent. This ordering is an app policy, not a UIKit guarantee.

Only the originating controller, exact session and captured document/Space may add rows. Other sidebars, windows and apps cannot contribute items. Adding is unavailable while the originating sidebar is inactive, any participant is applying a hover projection, or the group is committed or canceled. Rejected additions do not navigate, change selection or write document/SQLite/outbox state.

## Identity and conflict rules

Existing roots retain their original captured containers. The new row is captured from the frozen rendered snapshot; all old and new roots are then validated against the latest document. A remotely deleted or reparented root cannot become valid by recapturing it during addition. A new row moved since the frozen snapshot is also rejected.

Duplicates, more than 1000 roots, and parent/descendant overlap in either direction are rejected. Unlike initial selection normalization, adding cannot remove an already issued native item or absorb the new item into a parent. The complete root set must survive normalization unchanged.

The token atomically updates ordered roots, expected native item identities and a membership revision. UIKit adds the returned item after the callback. Until the native session contains the new complete identity set, admission rejects further additions and drops. Copied, missing, duplicate or foreign native items remain invalid. An accepted final drop records one existing v4 move and waits for every item's preview completion and native endpoint.

Membership changes cancel old dwell, hover feedback and cached plans across participating sidebars. Already revealed frozen rows remain available. An open Space palette retains its captured Space IDs and row geometry; adding a folder disables Today and reveals its reserved “Tabs only” hint in place. Fresh native callbacks must establish a new target before commit.

Apple's [adding-items callback](https://developer.apple.com/documentation/uikit/uitableviewdragdelegate/tableview(_:itemsforaddingto:at:point:)) and [read-only session items](https://developer.apple.com/documentation/uikit/uidragdropsession/items) contracts were checked with Xcode 26.6 headers on 2026-10-03. Tests append returned items to the fake session only after the callback, matching that ordering.

## Verification boundary

Hosted tests call production UIKit delegates, use real table geometry and document/SQLite state, and supply protocol-fake native sessions/coordinators. They cover append timing, semantic order, stale containers, exact identity sets, shared projection exclusion, palette stability, hover cancellation and one interwindow move with all preview completions. Pure planner tests cover the root limit and captured-container rules. These checks do not establish physical tap-to-add recognition, OS scene ordering, auto-scroll or touch/pointer smoothness.

The existing HTTP group replay and cross-Space scenarios separately verify the unchanged v4 operation through localhost NestJS/PostgreSQL.
