# iPhone browsing shell

On iPhone (`userInterfaceIdiom == .phone`) the scene's root is `BrowserMobilePhoneViewController`; iPad keeps the split controller from [mobile-foundation.md](mobile-foundation.md). Both read the same `BrowserMobileWorkspace`, so tabs, Spaces, sync, downloads, Archive and Find behave the same.

## Layout

The page fills the screen, under the status bar and the bottom bar. The engine receives the covered edges as `obscuredContentInsets`, so pages lay out above the bar and below the status bar while drawing behind both.

The bottom bar (`BrowserMobilePhoneBarView`) is Liquid Glass with a light or dark tint. `BrowserMobileBackdrop` measures the luminance of the page under the bar from a 32-pixel snapshot and switches with hysteresis (dark below 0.16, light above 0.24), so a mixed page does not flicker. The bar holds three controls:

- the tab stack: two tilted pictures of the previous tabs; tap opens the switcher;
- New Tab, a 76×40 capsule;
- the page menu chevron, a 34-point circle.

Scrolling down by 14 points shrinks the bar to the home-indicator strip; scrolling up or reaching the top brings it back. While collapsed, a tap on the strip expands it; that recognizer is off while the controls show, so it never takes their taps.

Over the tab switcher the same bar stays: the tab stack and the page menu crossfade into Spaces and Settings, New Tab stays put, and the glass goes so the switcher shows through.

A drag on the bar starts from anywhere on it, buttons included:

- sideways: to the previous tab (see below);
- up from the tab stack: the page shrinks into a card resting on the bar (0.72 of its size after 380 points) while the previous tab's picture comes out of the stack over it; letting go after 40 points lands on that tab, which fills the screen while the card drops into the stack;
- up anywhere else: the search panel follows the finger out of the bar, its field still the New Tab capsule, with the suggestions under it. Letting go after 50 points (or a flick) opens it; less closes it.

## Panels

The page menu and the search panel grow out of the bar: a surface takes the bar's frame and color, then springs to its height (0.42 s, bounce 0.12, corner radius 36). Closing springs back into the bar with a small bounce (0.5 s, bounce 0.28).

New Tab's capsule becomes the panel's top row: it widens into the search field or the page menu's address row, its plus fading first and the field's text or the row's controls after it. Copies of the tab stack and the page menu button ride the panel's top edge and fade out; closing, the row narrows back into the capsule and they fade back in, so the bar's real controls take over in place.

A drag down on an open panel follows the finger, and the page grows back from its search card along with it; letting go after 80 points (or a flick) closes the panel, less springs back. Up, it gives only a little. Over the suggestions, a drag scrolls them unless they are at the top and the drag goes down.

- **Page menu** (`BrowserMobilePagePanel`): an address capsule with Back, Forward, the host (tap to edit), Copy Link and Reload/Stop; tiles for Find on Page, Pin/Unpin, Downloads and Share; Display Options with text size and the desktop or mobile website. Text size sets `-webkit-text-size-adjust` on the page so text reflows; `pageZoom` would keep the mobile layout's width and push text past the screen edge. It is reapplied on every committed navigation. The desktop request sets `WKWebpagePreferences.preferredContentMode` for main-frame navigations and reloads.
- **Search** (`BrowserMobileSearchPanel`): the page shrinks into a card above a dark panel and the keyboard. Suggestions (`BrowserMobileSearchSuggestions`) list open tabs for an empty query; for typed text, the site it completes to (with an inline completion), a web search, then matching tabs. New Tab opens results in a new tab, or in the current one while it is blank.

## Tab switcher

`BrowserMobileTabSwitcherView` lays tabs out oldest to newest, by last selection (`BrowserMobileWorkspace.recentTabIDs`, saved per scene). Cards keep the screen's shape at 0.644 of its width. The focused card's left edge is at 0.211 of the width, the next card 0.495 to its right, and the newest card 0.062 further. Older cards bunch toward the left edge on an exponential curve. A horizontal pan pages the row with a scroll view.

- Opening: the live page shrinks into its card while the other cards fly out of the tab stack, landing on the previous tab (spring 0.36 s, bounce 0.1). The dark backdrop and buttons fade in over 0.2 s.
- Tap a card: the other cards fade in 0.1 s and the card grows to full screen (0.24 s) under the bar, whose controls change back.
- Tap between the cards: the open tab's card grows back to full screen while the others fly into the tab stack, the way they came (0.26 s).
- Flick a card up: it keeps the flick's speed off the top (0.12–0.25 s, linear) and its tab closes; the neighbors close the gap (spring 0.32 s).
- The bar opens the Spaces sheet, New Tab and Settings.

The Spaces sheet is `BrowserMobileTabsViewController` with `isPhoneSheet`: the Space's name (with the Space menu), plain rows with site icons, a line before Today, and the Spaces as icons in the toolbar. A sideways drag pages between Spaces: the rows follow the finger with the next Space's rows beside them, the name crossfades and the toolbar's Space changes at the halfway point; letting go past half the width (counting the flick) switches Spaces. Rows have no swipe actions there; their context menu closes tabs.

## Moving between tabs

A horizontal pan on the bar goes to the previous tab: it grows out of the tab stack while the current page slides right and shrinks (spring 0.3 s). The bar's tint changes when the finger lifts, from the incoming tab's picture. On the newest tab, a pan left rubber-bands. A tab whose page is not loaded yet keeps its last picture over the page until it loads, for up to 3 seconds.

## Pictures and icons

`BrowserMobileTabThumbnails` keeps tab pictures in memory and as JPEG in Caches. `BrowserMobileFavicons` keeps one icon per host (`www.` is the same site) in memory and as PNG in Caches. A loaded page lists its icons; SVG icons are drawn to PNG in the page. Blank images are rejected. On the dark switcher, search panel and sheet, an icon that is dark throughout sits on a light plate.

## Verification

`Tests/OpenArciOSTests/BrowserMobilePhoneTests.swift` covers suggestions, backdrop luminance, favicon ranking and filtering, text-size steps and switcher geometry; `BrowserMobileWorkspaceTests` covers switcher order. Animations were checked frame by frame from simulator recordings; physical-device feel remains unverified.
