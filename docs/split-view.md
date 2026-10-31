# Split View

## Model

`BrowserChromeModel.splitGroups` holds local groups. A group stores member tab sync IDs in pane order, an orientation (`horizontal` side by side, `vertical` stacked), optional pane fractions and the last focused member. Sync IDs are used because runtime IDs change when a dormant tab reopens.

Members keep their own rows in the shared tab tree, so order, drag, Undo and sync keep using the existing paths. Validation (`validatedSplitGroups()`) applies these rules on every read:

- Members exist, are unique across groups and are not Favorites.
- Members share one Space, section and folder. If one moves elsewhere, the container holding most members keeps the group; ties prefer the focused member.
- A group has two to four panes; a group left with one pane dissolves.
- Fractions must name every pane, be finite and positive; they are normalized to sum to 1 and reset when membership changes.

The selected tab is the focused pane, so the toolbar, Find and active-tab commands need no split awareness. Selecting a member records it as the group's focus. Switching to or away from a split touches every pane's activity, and automatic archive and sync expiry protect every pane of the selected split.

## Engine layout and focus

`syncSplitLayout()` sends `BrowserTabVisibleLayout` (panes, orientation, fractions) through `BrowserTabDriving.setVisibleTabLayout` whenever the selected split or its groups change, or nil outside a split; an identical layout is not resent. `BrowserTabController` keeps all CEF views in one host view: it shows every listed pane with a live engine while the active tab is one of them, hides the rest, and lays panes out on each host layout with `BrowserSplitPaneLayout` (a gap equal to the content inset, integer edges, left to right or top to bottom in flipped and unflipped hosts). Fewer than two live panes fall back to the active tab alone. Layout changes never move keyboard focus.

`CefFocusHandler::OnGotFocus` in a visible non-active pane reports `didFocusTabWithID`; the model selects that tab, so the toolbar follows the clicked pane. Hidden tabs and panes of an unselected split cannot take selection this way. Navigation focus stealing stays blocked for inactive panes.

Panes sit `BrowserWindowGeometry.browserContentEdgeInset` (8 pt) apart, the same distance as the content from the window edge. Every pane view rounds all four corners with the content corner radius while a split is shown, so the inner corners match the outer ones.

### Pane bars

Every pane of a visible split has its own 32 pt bar above the page (`BrowserSplitPaneLayout.paneBarHeight`). The engine lays each page out below its pane's bar and rounds only the page's bottom corners; it reports the pane frames synchronously through `didLayoutSplitPanesWithTabIDs:frames:` → `BrowserTabDriving.onSplitPaneLayout` → `BrowserChromeModel.splitPaneLayoutTabIDs/Frames` (not published, so a divider drag does not refresh the whole window). `BrowserSplitPaneBarsView`, a transparent layer above the engine host in `BrowserContentNSView`, puts a `BrowserSplitPaneBarView` on each pane: back, forward, reload or stop on the focused pane, the page host with a link icon (click copies the URL) and Close this Split Pane. A bar acts on its own pane: an unfocused pane is focused first, then the active-tab command runs. The bar draws the pane's top corners and stays inside the focus ring. The focused pane's bar has a 24 × 2 grip at its top center (`BrowserSplitPaneGripView`, 56 × 8 hit area): dragging it outlines the pane with the nearest center along the split axis, and releasing there moves the dragged pane to that position through `moveSplitPane(tabID:to:)`. The pane keeps its size and focus; the other panes keep their order. While the sidebar is hidden, the top-leading pane's bar shows the window controls before its back button; that host leaves the system buttons to the sidebar header's host (`managesSystemButtons = false`).

### Divider

A `BrowserSplitDividerView` fills each gap above the pane views. Dragging resizes the two neighbors live in the controller; the sizes reach the model once, on release, through `BrowserTabControllerDelegate.didResizeSplitWithTabIDs:fractions:` → `BrowserTabDriving.onSplitResized` → `setSplitFractions`, so the session store sees one change per drag. The model ignores a report whose tab IDs are no longer the selected split's panes. The rules:

- A pane never shrinks below 220 pt unless its neighbors together are shorter.
- Within 14 pt of the point where the two neighbors are equal, the divider snaps there.
- A double click makes the divider's two neighbors equal and leaves other panes alone.
- A 2 × 24 pt grip fades in over 0.16 s while the divider is hovered or dragged.

Dividers only act when every pane has a live engine, because the fractions name all panes.

While two or more panes are shown, the controller draws a 2 pt accent ring (`BrowserSplitFocusRingView`, rounded like the content corners) inside the active pane's frame. It sits above the pane views, ignores mouse events and hides outside a split.

## Actions

| Action | Behavior |
| --- | --- |
| `openInSplitView(tabID:)` | Open in Split View: the selected tab keeps its pane and sidebar position; the chosen tab becomes the next pane, moves directly after the last pane through `commitSidebarDrop` (persisted order and sync move) and is focused. Adding to an existing split appends a pane, up to four |
| `separateSplitGroup(id:)` | Separate All Tabs: rows stay in pane order at the group's position; the focused tab stays selected |
| `separateTabFromSplit(tabID:)` | Separate Tab from Split: the tab leaves and its row moves after the remaining panes |
| `setSplitOrientation(_:groupID:)` | Convert between horizontal and vertical |
| `setSplitFractions(_:groupID:)` | Commit pane sizes once, for example when a divider drag ends |
| `moveSelectedSplitPane(by:)` | Move Left/Right (Up/Down for stacked panes): the focused pane trades places and size with its neighbor |
| `presentSplitViewCommandBar(insertion:)` | `.end` appends after the last pane; Add Right/Left Split (Bottom/Top when stacked) use `.after`/`.before` the focused pane |
| `toggleExpandedSplitPane()` | Expand Current Split: only the focused pane is shown until focus moves or the command runs again; the split stays |
| `presentSplitViewCommandBar()` | Add Split View: opens the command bar with the selected tab as anchor. A submitted URL opens a new tab and an open-tab result reuses that tab; either becomes the next pane through `openInSplitView`. Any other command bar presentation or model dismissal clears the anchor |
| `closeFocusedSplitPane()` | Close this Split Pane: the focused tab leaves the group, the next pane (the previous one at the end) is selected, then the tab closes like Close Tab. A pinned tab with a pinned URL unloads and keeps its row |
| `separateSelectedTabFromSplit()`, `separateSelectedSplitGroup()`, `toggleSelectedSplitOrientation()` | The row actions for the selected split |

Closing a member or moving it to another Space or section removes it through validation. Close Tab (`Cmd+W`) on a pane selects the next pane, else the previous one, instead of the row below the split.

## Sidebar row

A split is one sidebar row in place of its first member (in sidebar order); the other members have no row of their own. `BrowserSidebarSnapshot.splitGroups` carries the runtime tab IDs of each split in pane order, and the page builds entries from it. The row (`BrowserNativeSidebarRowNSView`, kind `.split`) shows a chip per pane in pane order: 28 pt tall, equal widths, 4 pt apart and 4 pt inside the row, radius 8, with the focused pane's chip filled more strongly. A click on a chip selects that pane, a click elsewhere selects the focused pane, and a chip shows a close button on hover. The row menu offers Separate All Tabs, Add Split View, Convert, Move to another Space (every pane together, through the sidebar drop path, so the split stays whole), Archive Split View (closes every pane), Rename Split View… and Change Icon (a named split row shows its icon and name, with each pane as a favicon chip at the trailing edge; an empty name brings the pane chips back; name and icon live in the local split JSON and are never synced) and a submenu per pane (Separate from Split View, Copy Link, Close).

Resting a dragged tab for 0.5 s on the middle band of another tab row offers drop-to-split: the row splits into two halves, the half under the pointer fills, and the insertion line disappears. Dropping there runs `openInSplitView` with the dragged tab before (leading half) or after (trailing half) the row's tab, or adds it to that row's split. The row edges keep reordering, a quick pass never splits, and the target must accept another pane (`canOpenInSplitView`).

A single tab dragged out of the sidebar over the page uses page drop zones: min(W/3, 80) pt at a pane's left and right edges and min(H/3, 50) pt at its top and bottom (`BrowserSplitPaneLayout.pageDropEdge`). The half of the pane the tab would take is outlined by `BrowserSplitPaneBarsView`; dropping runs `openInSplitView` with the pane under the pointer as the anchor, before it on the leading or top edge and after it otherwise. Without a split the whole page is one pane and a top or bottom drop makes a stacked split; a shown split grows only along its own axis. In a shown split, the middle of a pane, away from the edge zones, outlines the whole pane: dropping runs `replaceSplitPane`, so the tab takes that pane's place and size and is focused, and the replaced tab leaves the split with its row after the group's last pane. A tab that is already a pane moves to that position instead. The middle of a single page is not a drop target. As with the row combine, the dropped tab joins the anchor pane's section, so a pinned tab dropped on a temporary page becomes temporary.

Dragging the row carries every pane as one group through the existing sidebar drop path, so the split moves as a block and stays valid. Drop slots exist only before and after the row, never between panes. Starting a drag on a split that is already selected keeps its focused pane.

## Commands and controls

Add Split View (`Ctrl+Shift+=`), Close this Split Pane (`Ctrl+Shift+-`), Separate Page from Split View, Separate All Tabs and Convert are `BrowserCommandID`s, so they appear in the View menu, the command bar and the Settings shortcut list. Expand Current Split, Move Left/Right and Add Left/Right Split come from the Split View Menu:

| Command | Default | Available |
| --- | --- | --- |
| Add Split View | `Ctrl+Shift+=` | A selected non-Favorite tab whose split has fewer than four panes |
| Close this Split Pane | `Ctrl+Shift+-` | A split is selected |
| Separate Page from Split View | none | A split is selected |
| Separate All Tabs | none | A split is selected |
| Convert to Vertical/Horizontal Split View | none | A split is selected; the title follows the current orientation |
| Expand Current Split / Show All Split Panes | none | A split is selected |
| Switch to Split Pane 1–4 | `⌃⇧1` … `⌃⇧4` | The selected split has that pane |
| Switch to Next/Previous Split Pane | `⌃⇧]` / `⌃⇧[` | A split is selected; focus wraps around |

The physical-key monitor also dispatches Control shortcuts and the `=`/`-` keys, because Shift changes their characters (`+`, `_`) and menu key equivalents do not match them reliably.

Controls:

- The tab context menu offers Open in Split View on rows other than the selected tab (when the selected split can take a pane) and, on split members, Separate Tab from Split, Separate All Tabs and Convert.
- A Split View button (`rectangle.split.2x1`) sits left of the site controls in the toolbar and among the hover actions of the sidebar URL row. Outside a split it starts Add Split View; inside one it opens the Split View Menu (Add Split View, Move Left/Right, Add Right/Left Split, Expand Current Split, Separate Tab from Split, Convert, Separate All Tabs, Close this Split Pane). It is highlighted while a split is selected.

## Persistence and sync

`BrowserTabSessionSnapshot.splitGroups` is optional and keeps snapshot version 4, so older builds ignore it. SQLite stores groups in `browser_tab_split_groups` (migration `addTabSplitGroups`) as validated JSON rows. A writer that passes `nil` (remote projections, mobile, archive transitions without split state) keeps the stored groups. Every write drops members missing from the written tabs, duplicate claims and groups with fewer than two members. Malformed rows or unknown orientations are skipped or defaulted instead of failing restore.

Split groups never enter sync payloads: a split-only edit queues no sync mutation, and remote projections cannot create or change groups. Splits stay local per device for now.

## Status and next slices

Open Location (`⌘L`) edits the focused pane's URL, because the focused pane is the selected tab.

Implemented: model, actions, validation, persistence, archive/expiry protection, engine pane layout, click focus, the focused-pane ring, pane bars with grip reorder and window controls, dividers, the one-row sidebar entry, drop-to-split on rows and page edges, pane replacement from a drop in a pane's middle, commands with default shortcuts, pane moves and expansion, View menu, command bar actions, tab context menu items and the Split View button, with tests. The engine layout and ring are covered through the fake driver and build; the commands and menus have model and dispatch tests. Not implemented yet:

1. iPad browser split in UIKit/WebKit.
