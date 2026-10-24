# AppKit UI

The macOS application UI uses AppKit and Swift. `BrowserRootView` owns the normal and incognito window hierarchy; `BrowserWebAppRootView` owns installed web-app windows. Neither root uses SwiftUI or `NSHostingView`.

## State and layout

- `BrowserChromeModel` and its existing services remain the source of browser state and actions. Views observe model changes on the main run loop and retain native controls across updates.
- `BrowserWindowChromeLayout` calculates window geometry. A pinned sidebar reserves viewport width; a hover sidebar overlays the page. Toolbars reserve height, while extension side panels reserve only page width.
- `BrowserSidebarChromeView` owns the sidebar header, list, footer, and resize handle. `BrowserNativeSidebarState` owns selection, rename, paging, and the two-step Clear interaction. Tab drag/drop has one gesture owner and uses the same semantic tree for rendering, proposals and commits; see [sidebar-drag-and-drop.md](sidebar-drag-and-drop.md).
- The sidebar edge snaps to the default width within 14 pt, a double click restores the default, dragging below 82 pt hides the sidebar, and the width tops out at 500 pt. The minimum stays at the 224 pt default because the header has no compact layout.
- The sidebar sits on the window edge chosen in Settings (General → Sidebar position) or with View → Move Sidebar to the Right/Left. `BrowserWindowChromeLayout.sidebarPosition` mirrors the sidebar, content insets, extension panel, hover overlay and reveal edge; the resize handle moves to the edge facing the content, and the window controls stay in the sidebar header, as in Zen.
- Keyboard navigation lives in `BrowserChromeModel+SidebarItems`. `⌘1…⌘8` go to sidebar items 1–8 and `⌘9` to the last one, `⇧⌘]` / `⇧⌘[`, and the alternates `⌥⌘↓` / `⌥⌘↑`, select the next or previous item and wrap; `⌥⌘→` / `⌥⌘←` switch to the next or previous Space. Items follow the sidebar: app tiles first, then the visible pinned rows and the temporary tabs; a Split View counts once and returns to its focused pane. `⌘=`/`⌘-`/`⌘0` zoom the page (CEF keeps zoom per site; `zoomPercent` is read back from the selected page on selection and navigation), `⌘.` stops loading, leaving a tab with a playing video sends it to Picture in Picture and returning brings it back (Settings → Picture in Picture when leaving a tab; a probe without a gesture checks for a playing video first, and only then `Runtime.evaluate` runs with a user gesture, so other pages gain no activation; top document only, not for split panes that stay on screen), `⌥⌘I` opens the page's Developer Tools in their own CEF window (Alloy-style pages only; the DevTools browser has no client of ours and closes before CEF shuts down), `⇧⌘T` (Restore Last Closed Tab) runs Undo when the latest undoable action closed a tab, keeping Undo's fresh sync identity; `⌘L` (Open Location) opens the compact current-page command bar with the selected tab's URL, `⇧⌘D` shows or hides the URL toolbar, `⌘E` (Open Extensions) opens the site control center of the visible URL controls, or points it at the page's top corner while they are hidden, `⌥⇧⌘C` copies the page as a Markdown link (`BrowserMarkdownLink`), and `⇧⌘J` (View Downloads) opens the sidebar footer's downloads list, pointing at the page's bottom corner on the sidebar side while the sidebar is hidden. The Go to Sidebar Item entries and the Next/Previous Tab alternates are hidden View menu items that keep their key equivalents; shortcuts show arrow keys as arrows. A default added in a later version yields to a key the user already assigned to another command (`BrowserShortcutStore.shortcut(for:)`). `⌘←` / `⌘→` are not Back/Forward alternates, because they would take line start and end from page text fields. Reveal Current Tab has no default, because macOS uses `⌃␣` to switch input sources; the command is in the View menu and opens a collapsed pinned section, scrolls the row into view and shows a hidden sidebar over the page until the pointer moves. TheBrowser has no Library: Downloads stay in the sidebar footer popover and Archive in its own window.
- The menu bar has the standard Mac items: Services and Hide/Hide Others/Show All in the app menu, Close Window (`⇧⌘W`, since `⌘W` archives the tab) in File, and a Window menu with Minimize (`⌘M`), Zoom and Bring All to Front that AppKit fills with the window list and tiling items. Web-app windows get the same app and Window menus. These keys are reserved in the shortcut editor and reach the menu from non-Latin layouts through the physical-key monitor. The browser menu bar has Spaces (Next/Previous Space, one item per Space with its `⌃1…⌃4` key, New Space) and Tabs (Pin/Unpin, Duplicate, Rename, Reset to Original URL, Next/Previous Tab, Reveal Current Tab, New Folder with the selected tab (folders hold at least one tab here), Collapse/Expand All Folders, Clear temporary tabs) and File gains Capture Full Page; the Space list is rebuilt when the menu opens. Pin/Unpin has no default because `⌘D` is Add Bookmark here.
- Peek: a Shift-clicked link (`CEF_WOD_NEW_WINDOW` with a user gesture) opens in `BrowserPeekPanel`, a borderless child card at 84 % of the window with the host, Open as Tab and Close; Escape, Command-W, Close or a click on the window behind closes it. The page is its own CEF browser (`BrowserPeekClient`, same request context as tabs, tracked by the client manager so quitting waits for it); links that open new windows from it become tabs, and a generation number drops callbacks of a card that was closed or replaced. Settings → General → Open Shift-clicked links in Peek turns it off. The same card, standalone, is the small window: with Settings → General → Open links from other apps in a small window (off by default, so links from other apps keep opening as tabs), such a link opens in a resizable window of its own with the traffic lights, the host and Open as Tab; Escape stays with its page.
- Pinned tabs restore unloaded at launch, with their last title, and load at the page they showed last when selected; the shown tab, split panes and Favorites load at launch (`restoreSessionIfAvailable`).
- Tab row menus offer Copy Link, Share, Rename, pinned URL actions, split actions, Duplicate (a temporary copy below a temporary tab, else at the top of the temporary tabs), Move to another Space (top of the same section), then Archive, Archive Other Tabs and Archive Tabs Above on temporary rows (temporary tabs only, a split counts as one) and Archive Tabs Below. Mute Tab silences the engine (`CefBrowserHost::SetAudioMuted`, reapplied when a page attaches) for this run, and the row shows a crossed-out speaker that unmutes; an audible indicator would need CEF's audio handler, which captures the streams, so it is not shown. Change Icon is not implemented (`BrowserChromeModel+TabActions`).
- `BrowserContentNSView` and `BrowserViewportClipView` embed the existing CEF host. The engine, navigation, persistence, and content lifecycle remain outside the UI layer.
- The root preserves the hover sidebar during fullscreen transitions and resumes pointer dismissal after actual pointer movement. Geometry animations ignore unrelated model notifications.

## Shared appearance and controls

Use `BrowserChromeColors` for adaptive colors and `BrowserChromeLayout` for dimensions. Reuse the native controls in `Sources/Browser/NativeUI`:

- `BrowserNativeSurface`, `BrowserNativeMaterialPanel`, and `BrowserChromeBackgroundNSView` provide fills, borders, clipping, and blur.
- `BrowserNativeChromeButton` and `BrowserNativePressableView` provide press, hover, keyboard/accessibility, and tooltip behavior.
- `BrowserNativeTooltipPresenter` shares the delayed tooltip coordinator and placement policy across controls.
- `BrowserNativeResizeHandle` shares delayed hover, cursor cleanup, haptics, and default-width snapping.
- `BrowserFaviconNSView` uses the existing favicon cache. Raster resizing continues through `BrowserImageThumbnailer`.

Native settings remain separate from Chromium's `tb://settings` page. General → Import also brings in Arc's Spaces, pinned tabs, folders and Favorites from its `StorableSidebar.json` as dormant tabs (`BrowserArcSidebar`, `importArcSidebar`). General → Downloads holds the download location: the engine saves into the chosen folder through `BrowserDownloadLocation` while it exists and falls back to the user's Downloads folder; TheBrowser keeps one location for the app. The Settings package hosts AppKit pane controllers. About, downloads, extension popovers, find, command input, bookmarks, and the tab switcher are native views/controllers.

Animation timing and state triggers are documented in [appkit-animations.md](appkit-animations.md).

## Verification

The Codex **Build** and **Test** actions remain separate, console-only actions:

```sh
./build.sh build
./build.sh test
```

Both scripts select Xcode 27.1. Format changed Swift files with the repository `.swiftformat` before Build. Unit tests use Swift Testing and cover models, native text editing, IME protection, selection, drag proposals, menus, clipping, and window geometry.

Build, Test, and offscreen control-rendering tests do not move the system pointer, inject keyboard events, or activate browser windows. Prefer them while the user works on the same desktop.

Live checks are explicit, opt-in actions requiring Accessibility permission. They move the real pointer and type into the foreground app; run them only when the user has made the desktop available. Launch an isolated browsing runtime before running them:

```sh
./build.sh run --skip-build --runtime-suffix appkit-ui-verification
export DEVELOPER_DIR=/Applications/Xcode-27.1.0.app/Contents/Developer
xcrun swift -swift-version 6 script/verify_appkit_sidebar_ui.swift .build/xcode/Build/Products/Debug/TheBrowser.app
xcrun swift -swift-version 6 script/verify_appkit_site_ui.swift .build/xcode/Build/Products/Debug/TheBrowser.app
xcrun swift -swift-version 6 script/verify_appkit_bookmarks_ui.swift .build/xcode/Build/Products/Debug/TheBrowser.app
xcrun swift -swift-version 6 script/verify_appkit_window_ui.swift .build/xcode/Build/Products/Debug/TheBrowser.app
xcrun swift -swift-version 6 script/verify_appkit_ui.swift .build/xcode/Build/Products/Debug/TheBrowser.app
xcrun swift -swift-version 6 script/verify_appkit_webapp_ui.swift .build/xcode/Build/Products/Debug/TheBrowser.app
```

Start window checks with a visible pinned sidebar and a normal, non-fullscreen window. The scripts use local fixtures and generated test titles. The runtime suffix isolates browser data; application preferences are shared, so the checks restore the preferences they toggle. The general UI script ends in Settings. The web-app check creates its own temporary bundle configuration, loopback HTTP server, and application instance and stops that instance afterward.

These checks exercise actual AX controls and mouse/keyboard events: command suggestions, find, settings, rename commit/cancel/blur, reorder/pin/folders, Clear, spaces, downloads, site controls, bookmarks, CEF input, resize, hover reveal, fullscreen, incognito, and web-app toolbar behavior. They do not claim coverage of every third-party extension, authentication provider, network failure, or OS configuration.
