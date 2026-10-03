# Split View

The iPad browser split is TheBrowser's own design.

## Model

`BrowserChromeModel.splitGroups` holds local groups. A group stores member tab sync IDs in pane order, an orientation (`horizontal` side by side, `vertical` stacked), optional pane fractions and the last focused member. Sync IDs are used because runtime IDs change when a dormant tab reopens.

Members keep their own rows in the shared tab tree, so order, drag, Undo and sync keep using the existing paths. Validation (`validatedSplitGroups()`) applies these rules on every read:

- Members exist, are unique across groups and are not Favorites.
- Members share one Space, section and folder. If one moves elsewhere, the container holding most members keeps the group; ties prefer the focused member.
- A group has two to four panes; a group left with one pane dissolves.
- Fractions must name every pane, be finite and positive; they are normalized to sum to 1 and reset when membership changes.

The selected tab is the focused pane, so the toolbar, Find and active-tab commands need no split awareness. Selecting a member records it as the group's focus. Switching to or away from a split touches every pane's activity, and automatic archive and sync expiry protect every pane of the selected split.

## Engine layout and focus

`syncSplitLayout()` sends `BrowserTabVisibleLayout` (panes, orientation, fractions) through `BrowserTabDriving.setVisibleTabLayout` whenever the selected split or its groups change, or nil outside a split; an identical layout is not resent. `BrowserTabController` keeps all CEF views in one host view: it shows every listed pane with a live engine while the active tab is one of them, hides the rest, and lays panes out on each host layout with `BrowserSplitPaneLayout` (6 pt gap, integer edges, left to right or top to bottom in flipped and unflipped hosts). Fewer than two live panes fall back to the active tab alone. Layout changes never move keyboard focus.

`CefFocusHandler::OnGotFocus` in a visible non-active pane reports `didFocusTabWithID`; the model selects that tab, so the toolbar follows the clicked pane. Hidden tabs and panes of an unselected split cannot take selection this way. Navigation focus stealing stays blocked for inactive panes.

## Actions

| Action | Behavior |
| --- | --- |
| `openInSplitView(tabID:)` | Open in Split View: the selected tab keeps its pane and sidebar position; the chosen tab becomes the next pane, moves directly after the last pane through `commitSidebarDrop` (persisted order and sync move) and is focused. Adding to an existing split appends a pane, up to four |
| `separateSplitGroup(id:)` | Separate All Tabs: rows stay in pane order at the group's position; the focused tab stays selected |
| `separateTabFromSplit(tabID:)` | Separate Tab from Split: the tab leaves and its row moves after the remaining panes |
| `setSplitOrientation(_:groupID:)` | Convert between horizontal and vertical |
| `setSplitFractions(_:groupID:)` | Commit pane sizes once, for example when a divider drag ends |

Closing a member or moving it to another Space or section removes it through validation.

## Persistence and sync

`BrowserTabSessionSnapshot.splitGroups` is optional and keeps snapshot version 4, so older builds ignore it. SQLite stores groups in `browser_tab_split_groups` (migration `addTabSplitGroups`) as validated JSON rows. A writer that passes `nil` (remote projections, mobile, archive transitions without split state) keeps the stored groups. Every write drops members missing from the written tabs, duplicate claims and groups with fewer than two members. Malformed rows or unknown orientations are skipped or defaulted instead of failing restore.

Split groups never enter sync payloads: a split-only edit queues no sync mutation, and remote projections cannot create or change groups. Splits stay local per device for now.

## Status and next slices

Implemented: model, actions, validation, persistence, archive/expiry protection, engine pane layout and click focus, with tests. CEF layout is compile-verified and covered through the fake driver; it has not run in a launched TheBrowser. Not implemented yet:

1. Divider drag to resize panes (commit with `setSplitFractions` on drag end) and the focused-pane border.
2. Sidebar: one row with member chips at the first member, hidden member rows, split context menu (Separate All Tabs, Add Tab, Convert, Tab Options) and the tab menu's Open in Split View.
3. Pane chrome and commands: per-pane back/forward/host/close strip, Split View Menu, Cmd-L for the focused pane, Add Left/Right/Top/Bottom Split in the command bar, Cmd-Shift-Plus and drag into the center.
4. iPad browser split in UIKit/WebKit.
