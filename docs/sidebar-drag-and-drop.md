# Sidebar drag and drop

The drag implementation uses AppKit events and a shared tab tree. A drop destination names a container and the next sibling's stable ID. It never passes a visible-row index into an unrelated flat tab array.

## Interaction contract

- Dragging between temporary, pinned and app tabs changes placement using the existing model rules. App capacity remains enforced; app-grid drops accept one tab. Command-click toggles selection across pinned and temporary rows, and Shift-click selects a range in visible tree order. Hidden collapsed children are not added by a range selection. Groups preserve their relative order when moving between pinned folders, temporary sections and spaces.
- The pointer chooses the destination. A list shows one insertion cue in the real gap; list items do not reorder during hover.
- Starting to drag a single tab activates it. The tab stays active after a cancelled or no-op drop. An explicit multi-selection or a folder keeps the current tab. A tab from another Space is not activated, so starting a drag never switches Spaces.
- Dropping on a space header inserts at the start of its pinned section. Dropping on a folder body inserts at the start of that folder. Both use a stronger row highlight, not an insertion line.
- Expanded folder children support insertion between siblings. An outside insertion follows the entire visible subtree, not the folder header. A collapsed folder's visible gap has one destination even when hidden children lie between the visible siblings.
- The app grid previews the actual planned order. Preview dimensions match the future cell, including stretched partial rows. An empty app target uses existing chrome spacing instead of moving the list when the gesture begins.
- After the app grid expands, leaving it holds the actual allocated height until release. A neutral empty cell marks the available space. The list therefore does not move away from the pointer when the projected app item is removed.
- The preview keeps the normalized grab point captured on mouse-down. This remains true if the source row moves before the drag threshold or the preview changes between a row and a tile.
- On release, the preview travels to the final row/cell. The real moved rows remain hidden until it arrives; they do not fly independently from their old positions. Hidden destinations merge into the visible folder/space header. The settling preview can be picked up immediately for another drag.
- An insertion cue has a small hollow ring in the row margin. The line starts at the ring's edge and avoids the floating preview, so the destination remains visible without drawing a line through preview text. The ring stays in the margin because the opaque preview usually covers the gap.
- Edge autoscroll updates both the viewport and drop geometry. Offscreen rows and other cached space pages cannot advertise a drop in the active page.
- Escape, release outside a valid destination, loss of window/application activity, closure and removal of the source clean up the session. Cancelled gestures do not change tab order. No system copy/plus badge is involved.

## Owners

| Component | Responsibility |
| --- | --- |
| `BrowserSidebarTabTree` | Ordered immediate siblings and folder subtrees; shared by rendering and move planning |
| `BrowserSidebarDropDestination` | Section/space/folder plus `beforeItem`; nil means the end of the container |
| `BrowserSidebarMovePlan` | Validate and project a move without mutating the model |
| `BrowserChromeModel.commitSidebarDrop` | Revalidate stable IDs on release, commit one order, preserve placement/selection metadata and persist |
| `BrowserSidebarDragGeometry` | Build hit regions and feedback from the completed native layout and current visible viewport |
| `BrowserSidebarDragState` | Payload, proposal, grab point and `idle → dragging → settling → idle` lifecycle |
| `BrowserSidebarDragEventSession` | Scoped native event ownership, cancellation and autoscroll clock |
| `BrowserNativeSidebarNSView` | Layout, input conversion, preview/indicator rendering and landing animation |

Pointer motion updates the preview and feedback, not every sidebar row. Move validity is cached by semantic destination for the current model state. Only app-grid projections retain complete planned arrays. Model changes invalidate validation; an anchor that disappeared is rejected rather than silently becoming an append operation.

Native page layout supplies every row frame. There are no estimated row positions, lagging SwiftUI preference maps or independent target/indicator resolvers. List order stays fixed during a drag; viewport changes rebase geometry. Before a new gesture, pending row-position animations finish after the visible grab point has been captured. Landing uses final parent geometry, including app-grid contraction.

The existing numeric `moveTab`/`moveTabs`/`movePinnedTabFolder` APIs remain available to their existing callers. Sidebar drag and drop uses the semantic planner instead; it does not reinterpret their different index conventions.

## Historical decisions

The interaction contract was recovered from these earlier Codex tasks and checked against the source:

- **Добавить drag and drop табов** — `019da7ad-d234-7352-97a2-cc89a6938bec`: moving between sections pins/unpins; one insertion line.
- **Улучшить перетаскивание табов** — `019dca2c-7d49-75c0-961c-a76125b8b791`: no system plus badge, alignment haptics, no lingering disabled rows, and preview-to-destination landing.
- **Починить индексы табов** — `019dcb89-7356-7a41-8b3e-dcde78b5e780`: use pointer position and preserve selection through repeated cross-section moves.
- **Почини сброс переноса табов** — `019dedc7-a2ac-7df3-aab4-bf56d5a54d9c`: fresh re-drags must not reuse the previous position or lose valid gaps.
- **Пересмотри drag-and-drop табов** — `019f3255-34ed-7423-b655-5ed9dc93e691`: lists keep their order during hover; folders/spaces use highlight; the app grid projects its layout; nested previews adapt to their destination.

The earlier frozen-coordinate session solved feedback from animated list reordering, but absolute frozen coordinates did not survive app-grid height changes or scrolling. The current implementation keeps sibling identity stable while deriving geometry from the current native viewport.

## Verification without taking over the desktop

Run the normal **Build** and **Test** actions:

```sh
./build.sh build
./build.sh test
```

The Swift Testing suite covers semantic model moves, every pinned/temporary root insertion gap for all nonempty subsets of four tabs, mixed group moves across spaces, incoming/missing tabs, native modifier selection, nested and collapsed folders, missing anchors, capacity/no-op rejection, cross-space selection and activity preservation. It also checks that repeated motion inside one destination does not trigger replanning, layout changes or repeated haptics.

`BrowserNativeSidebarDragTests` instantiates the actual sidebar in an offscreen window that is never ordered or activated. It calls the same native drag methods/responders and checks geometry, model commits, scrolling, cancellation, landing and immediate re-grabs. Its native render captures are written to `/tmp/thebrowser-drag-gap.png`, `/tmp/thebrowser-drag-grid.png`, `/tmp/thebrowser-drag-scroll.png` and `/tmp/thebrowser-drag-folder.png`.

These tests do not move the system pointer or inject keyboard events. The opt-in live UI scripts described in [appkit-ui.md](appkit-ui.md) do use the real desktop and are not part of this background verification.
