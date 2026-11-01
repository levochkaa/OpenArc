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
  closes its page in the window that had it; the row stays there and reopens at the same
  address. Page state such as scroll position and form input does not move across.
- Selecting a Space never takes a page from another window. If its remembered tab is open
  elsewhere the window shows no page until a tab is chosen.
- The oldest window expires temporary tabs. Closing a window closes its pages and keeps
  its tabs, which stay in the other windows and in the store.

Extra windows come back at launch with their frame, Space and shown tab, unless restoring
windows is turned off.
