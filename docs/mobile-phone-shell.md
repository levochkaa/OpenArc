# iPhone browsing shell

On iPhone (`userInterfaceIdiom == .phone`) the scene's root is `BrowserMobilePhoneViewController`; iPad keeps the split controller from [mobile-foundation.md](mobile-foundation.md). Both read the same `BrowserMobileWorkspace`, so tabs, Spaces, sync, downloads, Archive and Find behave the same.

## Layout

The page fills the screen, under the status bar and the bottom bar. The engine receives the covered edges as `obscuredContentInsets`, so pages lay out above the bar and below the status bar while drawing behind both.

The bottom bar (`BrowserMobilePhoneBarView`) is a blurred material over the page (`BrowserMobileBarMaterial`): `systemMaterialLight` on light pages, the thinner `systemThinMaterialDark` on dark ones so a colored page keeps more of its color. The page's own background color (WebKit's `underPageBackgroundColor`) decides: relative luminance under 0.179, where white and black text contrast the same, is dark. Until a page reports its background, a 32-pixel picture of the page under the bar decides. Over the app's own views (a page that could not load, a blank tab) the system appearance decides. Glyphs are white on dark and 21% gray on light.

Under the status bar an opaque band takes the page's `theme-color`, or its background, so scrolled content never shows there; the status bar's text turns light over a dark band.

The bar holds three controls:

- the tab stack: two tilted pictures of the previous tabs; tap opens the switcher;
- New Tab, a 76×40 capsule;
- the page menu chevron, a 34-point circle.

Scrolling down by 14 points slides the bar down until only the home-indicator strip shows (0.06 s, controls fade in 0.05 s); scrolling up or reaching the top brings it back (0.09 s, controls 0.12 s). The bar keeps its height while it slides, so its blur never resizes. While collapsed, a tap on the strip expands it; that recognizer is off while the controls show, so it never takes their taps.

Over the tab switcher the same bar stays: the tab stack and the page menu crossfade into Spaces and Settings, New Tab stays put, and the material goes so the switcher shows through.

A drag on the bar starts from anywhere on it, buttons included:

- sideways: to the previous tab (see below);
- up from the tab stack: the page shrinks into a card resting on the bar (0.72 of its size after 380 points) while the previous tab's picture comes out of the stack over it; letting go after 40 points lands on that tab, which fills the screen while the card drops into the stack;
- up anywhere else: the search panel follows the finger out of the bar, its field still the New Tab capsule, with the suggestions under it. Letting go after 50 points (or a flick) opens it; less closes it.

## Panels

The page menu and the search panel grow out of the bar: a surface takes the bar's frame and color, then springs to its height (0.42 s, bounce 0.12, corner radius 36). Closing springs back into the bar with a small bounce (0.5 s, bounce 0.28).

New Tab's capsule becomes the panel's top row: it widens into the search field or the page menu's address row, its plus fading first and the field's text or the row's controls after it. Copies of the tab stack and the page menu button ride the panel's top edge and fade out; closing, the row narrows back into the capsule and they fade back in, so the bar's real controls take over in place.

The page menu dims the page under it (black, 0.18, over 0.25 s). A drag down on an open panel follows the finger, and the page grows back from its search card along with it; letting go after 80 points (or a flick) closes the panel, less springs back. Up, it follows the finger at first and harder with each point, and stops at the top of the safe area; a lifted search panel's list reaches down to the keyboard, so it shows more rows. Over the suggestions, a drag scrolls them unless they are at the top and the drag goes down. With the keyboard up, a drag scrolls the suggestions until they reach their top and from there moves the panel, never both at once: the list holds still while the panel follows the finger down, sliding under the keyboard until the finger reaches it and takes it along, and back up past its place, harder with each point. Once the keyboard goes, search closes into the bar with it; let go otherwise, the panel goes back on top of the keyboard. The suggestions scroll up behind the field: its capsule is cut out of the list, so rows pass around the lower half of its rounded ends and never show through it or above it. A panel let go to close takes longer the farther it has to go and starts at the finger's speed.

- **Page menu** (`BrowserMobilePagePanel`): an address capsule with Back, Forward, the host (tap to edit), Copy Link and Reload/Stop; tiles for Find on Page, Pin/Unpin (adds the page to the Spaces sheet's Space, or a Space or folder from its menu, as a pinned tab or Favorite, and removes that copy again; the mobile tab stays), Downloads and Share; Display Options, which folds open in place (0.3 s spring, the panel growing with it; the choice is remembered) with Translate, Reader Mode, Page Zoom −/+ and Request Desktop or Mobile Site; and Site Settings. Page Zoom sets `-webkit-text-size-adjust` on the page so text reflows; `pageZoom` would keep the mobile layout's width and push text past the screen edge. It is reapplied on every committed navigation. The desktop request sets `WKWebpagePreferences.preferredContentMode` for main-frame navigations and reloads.
- **Translate** (`BrowserMobilePageTranslator`): Apple's Translation framework, on the device, into the app's language. The page's text nodes (not code, form fields or `translate="no"`) are read in the page-tools world, the source language comes from `NLLanguageRecognizer` (else the page's `lang`), and each translation replaces its node as soon as it arrives, from the top (the on-device model takes up to a second a paragraph). The system asks to download a language the first time. The row becomes View Original Site, which puts the text back; a page already in the app's language, or a pair the device can't translate, shows an alert.
- **Reader Mode**: Readability.js decides on every loaded page whether it reads like an article; the row is dimmed when it doesn't. Reader swaps the document for the extracted article (white, or black in dark mode; 28 point title, the byline and host in small capitals, 19 point text) with a View Normal Page button on top, and puts the original document back on exit. The row becomes Hide Reader Mode.
- **Site Settings** (`BrowserMobileSiteSettingsViewController`): a sheet for the page's site (`www.` is the same site) with Block Ads, Block Cookie Banners and Block Trackers for that site (the page reloads when the sheet closes after a change), Collapse Bottom Bar, which keeps the bar expanded while scrolling that site when off, and App Settings.
- **Search** (`BrowserMobileSearchPanel`): the page shrinks into a card, dimmed by 0.2, over a dark backdrop, above a thin dark material panel and the keyboard. Suggestions (`BrowserMobileSearchSuggestions`) list open tabs for an empty query; for typed text, the site it completes to (with an inline completion), a web search, then matching tabs. The completed part shows highlighted with no caret or selection handles (`BrowserMobileCompletingField`): the next keystroke replaces it, Delete removes it, Go keeps it, and so does a touch or a caret moved off its start, leaving the text as it is so the same touch places the caret, selects or brings up Paste. The highlight is a plate behind the text, not a text attribute, so keeping it never rewrites the text under the finger. Typing in the middle of the text fills nothing in. Go stays off while the field is empty. New Tab opens results in a new tab, or in the current one while it is blank.

## The page

The engine's own scripts (`Resources/Reader`: Readability.js, its readerable check, and `BrowserMobilePageTools.js`) run in a separate `WKContentWorld`, so pages can't see or call them. Pulling the page down past the top reloads it (`UIRefreshControl`). Touching and holding a link shows a live preview of its page (a `WKWebView` with the tab's configuration, so the same cookies and blocker) with Open Link, Open in New Tab, Open in Background Tab, Copy Link and Share Link under the address; tapping the preview opens the link. Other elements keep WebKit's menu.

A cold launch opens the search panel over the last tab while Auto-Open Keyboard is on in Settings (the default); returning from the background does not.

## Tab switcher

`BrowserMobileTabSwitcherView` lays out the mobile tabs ([mobile tab sync](sync-mobile-tabs.md)), oldest to newest, by last selection (`BrowserMobileWorkspace.recentTabIDs`, saved per scene), then the rest by activity. Cards keep the screen's shape at 0.644 of its width. The focused card's left edge is at 0.211 of the width, the next card 0.495 to its right, and the newest card 0.062 further. Older cards bunch toward the left edge on an exponential curve. Over each card sit the site's icon (20 points, 18 in from the card's edge, 9 above it) and, for the middle card only, its title, which ends 4 points before the next card's icon; the neighbors keep their icons. A horizontal pan pages the row with a scroll view; after a flick the row settles on a critically damped spring (ω 20) instead of the scroll view's long deceleration.

- Opening: the live page shrinks into its card while the other cards fly out of the tab stack, landing on the previous tab (spring 0.36 s, bounce 0.1). The dark backdrop and buttons fade in over 0.2 s.
- Tap a card: the other cards fade in 0.1 s and the card grows to full screen (0.24 s) under the bar, whose controls change back.
- Tap between the cards: the open tab's card grows back to full screen while the others fly into the tab stack, the way they came (0.26 s).
- Flick a card up: it keeps the flick's speed off the top (0.12–0.25 s, linear) and its tab closes; the neighbors close the gap (spring 0.32 s).
- The bar opens the Spaces sheet, New Tab and Settings.

Settings (`BrowserMobilePhoneSettingsViewController`, also behind the iPad sidebar's gear) lists Downloads and Archive; Global Site Settings (`BrowserMobileContentBlockingViewController`), the blocker's switches for every site, Update Filter Lists and the sites with exceptions; Search Engine, a choice of the engines the Mac offers, kept in `BrowserMobileSearchEngineSetting` and read by the scene's `BrowserNavigationResolver` on every search, with the Auto-Open Keyboard switch; Clear Website Data, which empties the default `WKWebsiteDataStore` after a confirmation and keeps tabs; Account; and the licenses.

The Spaces sheet is `BrowserMobileTabsViewController` with `isPhoneSheet`, a picker of the computers' Spaces: tapping a tab opens its address as a mobile tab, or selects the mobile tab already showing it, and the Space keeps its tab. It shows the Space's name (with the Space menu), plain rows with site icons, a line before Today, and the Spaces as icons in the toolbar. A sideways drag pages between Spaces: the rows follow the finger with the next Space's rows beside them, the name crossfades and the toolbar's Space changes at the halfway point; letting go past half the width (counting the flick) switches Spaces. Rows have no swipe actions there; their context menu closes tabs.

## Moving between tabs

A horizontal pan on the bar goes to the previous tab: it grows out of the tab stack while the current page slides right and shrinks (spring 0.3 s). The bar's tint changes when the finger lifts, from the incoming tab's picture. On the newest tab, a pan left rubber-bands. A tab whose page is not loaded yet keeps its last picture over the page until it loads, for up to 3 seconds.

## Content blocking

The Mac's blocker runs on iOS through the same files (the `BrowserContentBlockingCore` template in `project.yml`): EasyList, EasyPrivacy and EasyList Cookie List ship in the app, `BrowserFilterListUpdater` downloads fresh copies every four days, and `BrowserWebKitContentRules` compiles each list into a `WKContentRuleList` once per version. iOS skips the Mac's request-level index, which only Chromium needs. `BrowserMobileContentBlocking` keeps the settings under the Mac's key; besides allowing every list on a site, a site can let one list through (`allowedSitesByKind`). The engine puts the lists into each tab's controller for the site it navigates to.

## Pictures and icons

`BrowserMobileTabThumbnails` keeps tab pictures in memory and as JPEG in Caches. `BrowserMobileFavicons` keeps one icon per host (`www.` is the same site) in memory and as PNG in Caches. A loaded page lists its icons; SVG icons are drawn to PNG in the page. Blank images are rejected. On the dark switcher, search panel and sheet, an icon that is dark throughout sits on a light plate.

## Verification

`Tests/OpenArciOSTests/BrowserMobilePhoneTests.swift` covers suggestions, backdrop luminance, favicon ranking and filtering, text-size steps and switcher geometry; `BrowserMobileWorkspaceTests` covers switcher order. Animations were checked frame by frame from simulator recordings; physical-device feel remains unverified.
