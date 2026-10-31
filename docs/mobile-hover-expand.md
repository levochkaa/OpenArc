# Mobile folder hover expansion

## Interaction contract

While dragging a tab or selected group, hovering inside a collapsed folder for 600 ms reveals its descendants as drop targets. Expansion belongs to that sidebar's current interaction. It does not change the folder's saved expansion state or create a sync operation. Nested collapsed folders can reveal their own children after a separate dwell.

Expansion leaves the source's ordered roots and exact native items unchanged. Explicit [row addition](mobile-drag-adding.md) can extend that group and cancels any pending dwell. A receiver keeps a frozen tree snapshot, captured Space and available tab identities. Temporary expansion projects only from this base; incoming inserts, moves or deletions do not silently replace the displayed geometry. Every proposed drop still validates against the latest document, so a deleted or reparented source/target cannot receive a stale operation.

Hover eligibility differs from a nonempty move: a tab already last in its parent can still reveal that folder to choose a different sibling position. Dropping back into the same place remains a semantic no-op and writes nothing. Invalid cycles, stale identities and unsupported containers remain rejected.

## Timing and row updates

One cancellable dwell belongs to the current token and hovered folder. Moving within the same target preserves its elapsed dwell; leaving it cancels the pending action. Before firing, the receiver reads the session's current location again and verifies the same inside target, scene activity and latest semantic validity. Scroll must update this location rather than reuse an old index path.

Revealing descendants uses a controlled UIKit row batch. The controller holds the shared session while applying the projection; no participant may commit a drop midway through that batch. An interrupted animation still releases the hold. The controller does not call ordinary render/reloadData or adopt live document rows. Apple's [batch update API](https://developer.apple.com/documentation/uikit/uitableview/performbatchupdates(_:completion:)) and Xcode 26.6 UITableView headers were checked on 2026-10-03; the headers caution against reloadData while user interactions have uncommitted updates.

If UIKit still has uncommitted updates when dwell expires, the same candidate retries at 50 ms intervals, at most ten times. Each retry checks current pointer, lifecycle and target validity. Only one timer is pending; ordinary cancellation also cancels retry. After the bound, a new native hover/scroll callback can resume a still-valid candidate. This lets short UIKit updates settle without requiring the user to move the pointer or polling indefinitely.

Exit, inactive/background, Escape, commit and token replacement cancel pending dwell. Already revealed rows remain until the existing endpoint/preview barrier permits refresh. The next normal projection uses current persisted expansion state. Each window owns its temporary expansion; it cannot alter another sidebar's view or active page.

## Verification boundary

Hosted tests exercise actual production delegates and UIKit row batches with a controlled dwell scheduler and protocol-fake native sessions. They verify revealed identities and geometry, unchanged SQLite/outbox before a drop, current-state rejection, exact move intent and terminal refresh. They do not establish physical hover recognition, native auto-scroll or pointer/touch smoothness. Separate HTTP scenarios cover the unchanged document/persistence/transport path.
