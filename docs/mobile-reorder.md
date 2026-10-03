# Mobile sidebar reorder

## Scope and contract

Native UIKit drag/drop operates within the current mobile Space. The source is a tab, folder root or selected group. Tabs can move between Favorites, Pinned and Today; a group containing folders stays in Pinned. A folder move carries its current subtree through the existing v4 operation. The existing Move To menus continue to support explicit cross-Space moves.

Select/Done enters native multiple selection without changing the active page or expanding folders. Group order follows the rendered sidebar, independent of selection order or callback order. Selecting both a folder and its descendants contributes only that folder root. Dragging an unselected row replaces the selection with that row. A single move accepts at most 1000 normalized roots, matching the v4 operation limit.

Cross-Space drag, interwindow drag, adding items during an active drag and hover expansion remain required follow-up work. Unsupported sessions are rejected without copying records or synthesizing IDs. Native auto-scroll and physical touch/pointer smoothness require separate runtime observation; delegate tests alone do not prove them.

## Stable identity and conflict rules

`BrowserMobileSidebarDrop` resolves typed Space/folder/tab identities against the full shared profile snapshot. Captured source and target tokens include their semantic containers. Any captured root or target moved to another container, or deleted while the drag is active, invalidates the entire local drop. Rename, page progress and insertion/reorder of other siblings do not turn a stable identity into an index. Anchors inside the moving group or a moving folder's current subtree are invalid.

Before/after targets address a sibling in its own container. A folder's inside target appends into that folder, including when it is empty or collapsed. A section root target appends to that section. Moving a folder into itself or its descendant, placing a folder in Favorites/Today, dropping against a missing required Space/container and semantic no-ops must produce no document write or outbox operation.

Favorites remain a global list and can reorder after the last Space is deleted; their historical Space value is not a live-container requirement.

The planner returns the existing typed `BrowserSyncFolderDestination` and before/after references. Admission calls `BrowserMobileProfileDocument.move` once with the ordered source roots. It does not write an independently reordered snapshot or enumerate folder descendants into a frozen drag payload. The production reducer, persistence FIFO and immutable v4 outbox retain ownership of the operation.

## UIKit integration

Native drag/drop delegates use the table's geometry to choose a semantic target. UIKit index paths are not stored as durable destinations. Empty section headers and section ends need explicit root targets. The controller does not implement `tableView(_:moveRowAt:to:)`; this avoids UIKit's single-local-move shortcut bypassing the guarded drop coordinator path.

UIKit requests initial drag items once for each selected row. One session shares a captured source/payload; each normalized root provides its own native item, and duplicate/descendant callbacks add no duplicate. Admission requires the exact full set from that session/document/controller. See Apple's [initial drag callback](https://developer.apple.com/documentation/uikit/uitableviewdragdelegate/tableview(_:itemsforbeginning:at:)) and [multiple selection](https://developer.apple.com/documentation/uikit/uitableview/allowsmultipleselectionduringediting) contracts, checked 2026-10-03.

The displayed structural rows and their snapshot remain frozen during a drag. Incoming profile changes continue to update the document and page runtimes. Hover and commit validate against the latest snapshot; a Space change or hidden controller cancels admission. Synchronous document notifications during drop cannot reload the table inside UIKit's animation. Every preview completion and both session terminals must finish before refresh, including inline or reverse-order completion. Terminal refresh applies the latest rows, prunes deleted selections and restores scroll using a surviving typed row identity and offset where possible.

Escape marks the local payload canceled. The public drag-session API does not expose imperative cancellation; the controller must reject further proposals/commit and release the frozen rows when the native session ends. This distinction must remain visible in verification notes.

## Verification boundary

Pure planner tests cover mixed folder/tab sibling order, root normalization/limits, empty/collapsed folders, no-op, cycles, typed identity collisions and concurrent snapshot changes. UIKit test-host tests call the configured production delegates with protocol fakes and verify target geometry, rejected sessions, deferred reload, selection/runtime stability and committed SQLite/outbox semantics. A folder drag emits one root intent and moves its current descendants, including children that entered or escaped during the drag. Cancel/no-op checks compare decoded durable state and queue contents.

The localhost sync fixture separately exercises planner → document → real HTTP/PostgreSQL and proves delivery and deletion dominance. The UIKit delegate and HTTP tests are separate evidence; they do not establish a physical end-to-end drag. Physical lift/cancel, pointer/touch smoothness, native auto-scroll, keyboard Escape routing and full reorder parity remain unverified.
