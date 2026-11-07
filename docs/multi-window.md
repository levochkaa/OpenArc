# More than one window per profile

New Window (`⌘N`) opens another window of the same profile. The windows show the same
sidebar: Spaces, pinned tabs, folders, Favorites and Today. Each has its own selected
Space and tab, sidebar width, find bar and command bar.

## How it works

- Every window has its own `BrowserChromeModel` and its own engine, and all of them use
  the profile's session store.
- `BrowserProfileWindowGroup` passes each saved session to the other windows, which apply
  it through the same path a synced snapshot takes, without saving it again.
- A tab has one page at a time. An additional window starts with no pages. Opening a tab
  moves its live page from the window that had it (`detachTab`/`adoptTabPage` in
  `BrowserTabController`), so scroll position, form input and playing media stay. That
  window keeps the tab selected and shows a faded picture of the page; a click brings the
  page back. A page still loading its first address, closing or showing a dialog cannot
  move: it closes there and loads again here.
- Page titles go to the other windows as they change, without saving the session.
- Selecting a Space never takes a page from another window. If its remembered tab is open
  elsewhere the window shows no page until a tab is chosen.
- The oldest window expires temporary tabs. Closing a window gives its pages to the other
  windows: one showing the page's picture takes it and shows it, otherwise the oldest keeps
  it in the background. Pages that cannot move close with the window. Its tabs stay in the
  other windows and in the store.

Extra windows come back at launch with their frame, Space and shown tab, unless restoring
windows is turned off.
