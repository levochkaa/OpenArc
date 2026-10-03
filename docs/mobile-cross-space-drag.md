# Mobile cross-Space drag

## Interaction contract

The mobile sidebar offers a destination palette while dragging a local tab or selected group. Hovering the Space button uses Apple's [UISpringLoadedInteraction](https://developer.apple.com/documentation/uikit/uispringloadedinteraction) to open a child UIKit controller over the sidebar. The ordinary Space menu keeps its existing tap behavior. This is a designed iPhone/iPad interaction. The Apple contract and Xcode 26.6 headers were checked on 2026-10-03.

The palette lists each other Space with Pinned and Today destinations. A group containing a folder cannot enter Today; that target remains visible but unavailable. A drop appends the ordered roots to the chosen section. Empty destinations are valid. The palette captures target Space IDs when opened, so subsequent rename/reorder cannot redirect the drop to another Space.

The source Space stays selected. Moving other tabs preserves the active page. If the active tab itself leaves that Space, the existing workspace selects a surviving visible neighbor, or no tab when none remains. The moved page runtime stays alive; the palette does not select the destination or reload the moved page.

## Ownership and persistence

The originating tabs controller owns the source payload and commits the move. Admission requires the same controller, profile document and native session, with the complete exact drag-item set. This surface does not permit cross-window/profile or external payloads.

The palette proposes a stable `BrowserMobileSidebarDrop.rootTarget`. Hover and commit validate it against the current document, including the captured source containers. A deleted destination Space or deleted/reparented root rejects the entire local drop. One `document.move` records the ordered root intent in the existing v4 FIFO; folder descendants are resolved from the current tree.

The source rows and palette targets remain stable during the interaction. Source-table and palette endpoint holds are separate: leaving the table cannot release a palette drop. Preview containers remain attached through all animations and session terminals. Escape, disappearance or the owning scene's deactivation prevents a later commit; another scene's notification must not cancel this drag.

## Verification boundary

Hosted UIKit tests exercise the configured Space-button action and palette drop delegates with protocol fakes, plus the actual document and SQLite outbox. The public spring-loaded API does not expose a handler invocation method; callback wiring and control tests do not establish an observed physical spring-load gesture.

The localhost HTTP fixture separately tests a group crossing Spaces after descendants enter and escape the selected folder, converging on two independent profiles, surviving deletion of the old Space and reopening from SQLite. Existing group replay tests retain lost-ACK and deletion-dominance coverage. Physical hover, cross-surface pointer/touch feel and autoscroll need separate observation.
