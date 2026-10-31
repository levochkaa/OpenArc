# Mobile cross-Space drag

## Interaction contract

The mobile sidebar offers a destination palette while dragging a local tab or selected group. Hovering the Space button uses Apple's [UISpringLoadedInteraction](https://developer.apple.com/documentation/uikit/uispringloadedinteraction) to open a child UIKit controller over the sidebar. The ordinary Space menu keeps its existing tap behavior. The Apple contract and Xcode 26.6 headers were checked on 2026-10-03.

The palette lists each other Space with Pinned and Today destinations. A group containing a folder cannot enter Today; that target remains visible but unavailable. A drop appends the ordered roots to the chosen section. Empty destinations are valid. The palette captures target Space IDs when opened, so subsequent rename/reorder cannot redirect the drop to another Space.

If the originating sidebar [adds a folder to the active group](mobile-drag-adding.md), an open palette disables Today in place. The hint occupies reserved space, preserving target geometry and captured Space identities. Old hover feedback is cleared before another drop may be proposed.

The source Space stays selected. Moving other tabs preserves the active page. If the active tab itself leaves that Space, the existing workspace selects a surviving visible neighbor, or no tab when none remains. The moved page runtime stays alive; the palette does not select the destination or reload the moved page.

## Ownership and persistence

The originating tabs controller owns the source payload and opens this palette. Admission validates source ownership and the native session's complete exact drag-item set. Another window may receive the group through its table, but cannot open this palette for that source's drag. Cross-profile and external payloads are rejected.

The palette proposes a stable `BrowserMobileSidebarDrop.rootTarget`. Hover and commit validate it against the current document, including the captured source containers. A deleted destination Space or deleted/reparented root rejects the entire local drop. One `document.move` records the ordered root intent in the existing v4 FIFO; folder descendants are resolved from the current tree.

The source rows and palette targets remain stable during the interaction. Source-table and palette endpoint holds are separate: leaving the table cannot release a palette drop. Preview containers remain attached through all animations and session terminals. Escape, disappearance, background or disconnect prevents a later commit. Temporary scene deactivation suspends that controller's admission, retaining the source token for another active window; another scene's notification must not cancel this drag. See the [shared interwindow lifetime contract](mobile-interwindow-drag.md).

The palette's inner scroll view notifies the owner when its offset changes. The owner keeps a weak native drop session and reuses normal current-state validation to update the target and highlight at the session's current location. A point in a gap or over a disabled/deleted target clears feedback while retaining the active endpoint, allowing a later scroll into a valid row to recover. Exit, inactive, membership change, commit and dismissal clear the tracked session; scrolling cannot revive an old interaction. This corrects stale feedback and rejected valid drops after scrolling, without implementing a separate autoscroll driver.

## Verification boundary

Hosted UIKit tests exercise the configured Space-button action and palette drop delegates with protocol fakes, plus the actual document and SQLite outbox. The public spring-loaded API does not expose a handler invocation method; callback wiring and control tests do not establish an observed physical spring-load gesture.

The localhost HTTP fixture separately tests a group crossing Spaces after descendants enter and escape the selected folder, converging on two independent profiles, surviving deletion of the old Space and reopening from SQLite. Existing group replay tests retain lost-ACK and deletion-dominance coverage. Physical hover, cross-surface pointer/touch feel and autoscroll need separate observation.

Long-list hosted tests hold a fixed window point while changing the inner scroll offset and verify the resulting highlight and one exact v4 move. They also cover gap-to-valid recovery and deleted/exited targets. These are actual UIKit scroll delegate checks with fake native sessions; they do not prove that a held physical drag automatically scrolls this palette.
