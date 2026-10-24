# More than one window per profile

Status: design only, not started. A New Window command (`⌘N`) would open another window of
the same profile with the same sidebar: Spaces, pinned tabs, folders and
Favorites are shared, while each window has its own selected Space and tab.
TheBrowser keeps one window per profile; `openProfile` focuses the open one.

## Why it is not a small change

- `BrowserChromeModel` is both the profile's state (Spaces, tabs, folders,
  splits, icons, colors, archive, undo) and one window's state (selected Space
  and tab, split layout, find, command bar, sidebar width and visibility).
- The model owns the profile's persistence: it writes whole snapshots to the
  profile's SQLite store and is the sync coordinator's snapshot applier
  (`setSnapshotApplier`). Two models on one store would overwrite each other.
- The model owns one `BrowserTabDriving` engine whose CEF browsers are child
  views of that window's host view. A tab shown in a second window needs its
  browser in that window: either moving the CEF view between windows or a
  per-window engine with tab ownership handed over.
- Undo, closing confirmation (`BrowserSessionClosureGuard`), quit, archive
  timers and extension side panels assume one model per profile.

## Plan

1. Split the model into `BrowserProfileState` (shared, owns persistence, sync
   and undo) and `BrowserWindowState` (selection, layout, find, command bar),
   with today's single window as the only client. No behavior change; the
   existing tests must pass unchanged.
2. Give each window its own engine controller and host view. A tab belongs to
   at most one window's engine at a time; showing it in another window closes
   its page there and opens it here, as an unloaded pinned tab reopens today.
   Measure whether moving the CEF view between windows is reliable before
   choosing it over reopening.
3. Add New Window (`⌘N`): a window on the same profile state with its own
   selected Space. Persist the open windows and their selected Spaces locally.
4. Closing a window closes only its own pages; quitting closes all. Window
   frames and selection restore at launch.

Each step ships separately with the root Build and Test passing. Step 1 is the
risky one: it touches every model path that sync, archive and persistence tests
cover.
