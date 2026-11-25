# Extensions in WebKit

The iPhone and iPad app and the Mac's WebKit pages run browser extensions with Apple's WebExtensions engine (`WKWebExtension`, `WKWebExtensionContext`, `WKWebExtensionController`). The Mac's Chromium pages keep Chromium's own extension system and the Chrome Web Store only; Chromium 156 runs no Manifest V2, so nothing converts Firefox add-ons for it.

| Surface | Sources | Installs from |
| --- | --- | --- |
| iPhone, iPad | Chrome Web Store, Firefox Add-ons (AMO) | Add to OpenArc on the store page |
| Mac WebKit pages | the Chromium profile's extensions, AMO add-ons | Chromium; View › Add Add-on to WebKit Pages on an AMO page |

Code: `BrowserWebExtensionPackage.swift` (CRX3 and XPI checks), `BrowserWebExtensionStore.swift` (store pages, update service, AMO records, update schedule), `BrowserWebExtensionManifest.swift` (manifest reading, prompt text, background adaptation) and `BrowserWebExtensionLibrary.swift` (files, records, the controller) are shared by both apps. iOS adds `Sources/BrowseriOS/Extensions/` and `Engine/BrowserWebKitExtensionTabs.swift`; the Mac adds `Sources/Browser/WebKit/BrowserWebKitExtensions.swift`.

## Installing

Installs start only from the user: a tap on Add to OpenArc over an extension's store page, then Add in the permissions prompt.

### Chrome Web Store

1. `BrowserWebExtensionStoreItem(pageURL:)` takes the 32-letter ID (`a`–`p`) from `chromewebstore.google.com/detail/<slug>/<id>` or the older `chrome.google.com/webstore/detail/…`.
2. The package comes from Google's update service: `https://clients2.google.com/service/update2/crx?response=redirect&prodversion=158.0.8127.89&acceptformat=crx2,crx3&x=id%3D<id>%26uc`. `prodversion` is the Chromium version of the exported CEF, so the store serves packages that run there.
3. `BrowserCRXPackage.verify` checks the CRX3:
   - magic `Cr24`, version 3, and a protobuf header that fits the file;
   - the signed header data's 16-byte ID equals the page's ID;
   - the publisher proof: a key whose SHA-256 starts with that ID, and whose RSA (PKCS#1 v1.5, SHA-256) or ECDSA P-256 signature verifies;
   - the store proof: the Chrome Web Store's ECDSA P-256 key (SHA-256 `61f7f2a6…6367cf`) signed the same bytes.

   Signatures cover `"CRX3 SignedData\0"`, the signed header data's length as a little-endian `UInt32`, the signed header data and the ZIP archive. RSA uses Security (`SecKeyVerifySignature`, after taking the key out of its SubjectPublicKeyInfo); ECDSA uses CryptoKit.
4. Downloads and redirects must stay on HTTPS hosts of `google.com`, `googleusercontent.com` or `gvt1.com`.

### Firefox Add-ons

1. `addons.mozilla.org/<locale>/firefox|android/addon/<slug>/` gives the slug; numeric IDs and GUIDs work too.
2. `https://addons.mozilla.org/api/v5/addons/addon/<slug>/` gives `guid`, `current_version.version` and `current_version.file.url` and `hash`.
3. The `.xpi` downloads over HTTPS from `mozilla.org` or `mozilla.net` hosts only, and its SHA-256 must equal `hash` (`sha256:<hex>`; other algorithms are refused).
4. Mozilla's own signature (`META-INF/mozilla.rsa`, `cose.sig`, `manifest.mf`) is not checked. iOS has no CMS API to read the PKCS#7 signature, and checking it means an ASN.1 parser plus a pinned Mozilla root. The install relies on HTTPS to AMO and AMO's checksum, which come from the same server.
5. The add-on's identity is `browser_specific_settings.gecko.id` (or the older `applications.gecko.id`), else AMO's `guid`.

### Unpacking and the prompt

The ZIP unpacks with ZIPFoundation's `unzipItem`, which refuses entries and symbolic links outside the folder, into `Staging/<uuid>`. `WKWebExtension(resourceBaseURL:)` parses it. The prompt lists:

- what it can do, from `requestedPermissions` and `allRequestedMatchPatterns` (`BrowserWebExtensionPermissionText`): "Read and change your data on all websites", "Block or change content on pages" and so on;
- what will not work here (`BrowserWebExtensionManifest.unsupportedFeatures`): manifest keys WebKit ignores (`sidebar_action`, `side_panel`, `theme`, `chrome_url_overrides`, …) and permissions WebKit lacks (`contextualIdentities`, `proxy`, `webRequestBlocking`, `downloads`, `notifications`, `privacy`, …). These never fail the install;
- for AMO, "Partially compatible: written for Firefox".

Add moves the folder to `Installed/<uuid>` and grants the requested permissions and match patterns. Cancel deletes the staging folder.

## Storage

iOS keeps everything under `Application Support/WebExtensions/`; the Mac under `<Chromium profile>/WebKit Extensions/`.

- `extensions.json`: one `BrowserWebExtensionRecord` per extension: ID, source, store ID or slug, name, version from the package's manifest, folder, base host, enabled, private browsing, site access, granted permissions and patterns, unsupported features, install date, last update check.
- `Installed/<uuid>/`: the unpacked files.
- Extension storage (`storage.local`, `sync`, `session`, IndexedDB of extension pages) lives with WebKit, under a controller configuration whose identifier stays the same across launches (`BrowserMobileExtensions.controllerIdentifier` in `UserDefaults` on iOS; derived from the profile path on the Mac). Each context keeps its `uniqueIdentifier` (the extension's ID, as `runtime.id`) and a stable `webkit-extension://<uuid>/` base URL, so data survives launches and updates. Remove deletes the files, the record and the extension's WebKit data records.

## Backgrounds on iOS

Two things in iOS WebKit stop most current extensions before their first line runs:

- **No service workers.** WKWebView on iOS exposes `navigator.serviceWorker` only to apps with the `com.apple.developer.web-browser` entitlement, which Apple grants to browsers on request. OpenArc does not have it yet, so every Manifest V3 `background.service_worker` fails with `undefined is not an object (evaluating 'navigator.serviceWorker.register')`. On install and on load, `adaptBackground` rewrites such a manifest to `background.scripts`: first `__openarc_service_worker.js`, then the files of literal `importScripts("…")` calls, then numbered webpack chunks next to the worker when it builds its `importScripts` paths, then the worker. The shim makes `importScripts` of loaded files a no-op and adds do-nothing `chrome.notifications` and `chrome.idle`, which password managers subscribe to at startup. `type: module` stays. With the entitlement, this step can go: delete `adaptsBackgroundsForIOS = true`.
- **No persistent background pages.** iOS WebKit refuses `"persistent": true`, which every Manifest V2 page is by default. The adapter writes `"persistent": false`; the page then loads on events and unloads when idle.

The Mac's WKWebView has service workers and persistent pages, and its Chromium folders are never written to.

The extensions' own pages get `Version/<iOS> Mobile/15E148 Safari/604.1` in their user agent: WKWebView's default has no `Safari/`, and Bitwarden, among others, fails to tell the browser apart without it.

## Updates

On launch (`BrowserMobileExtensions.start`, the Mac host's first use) the library checks every extension whose last check is 23 hours old or more, or in the future (`BrowserWebExtensionUpdateSchedule`). Settings › Extensions › Check for Updates checks all at once.

- Chrome Web Store: one `response=updatecheck` request lists every installed ID and version (`x=id%3D<id>%26v%3D<version>%26uc`). An `updatecheck status="ok"` with a newer `version` downloads and verifies the package again, the same way as an install.
- AMO: the add-on's API record; a newer `current_version.version` downloads and checks the new `.xpi`.

Versions compare part by part as numbers. An update replaces the folder, keeps the record, the storage and the grants, and grants nothing new: permissions the new version adds stay ungranted until the extension asks and the user allows.

## The delegate and the tab model

### iOS

Each scene's `BrowserWebKitEngine` is one extension window (`BrowserWebKitExtensionWindow`); its pages are tabs (`BrowserWebKitExtensionTab`) in the order they opened. Every page's `WKWebViewConfiguration` gets the app's `webExtensionController`; popups share their opener's.

| WebKit | OpenArc |
| --- | --- |
| `didOpenTab`, `didCloseTab` | the engine creates or closes a page record, restored tabs included |
| `didActivateTab`, `didSelectTabs` | the scene selects a tab |
| `didChangeTabProperties` | the page's URL, title, loading or Reader state changes |
| `didOpenWindow`, `didCloseWindow`, `didFocusWindow` | a scene connects, shuts down, becomes active |
| tab `loadURL`, `reload`, `goBack`, `goForward`, `close`, `setZoomFactor`, `setReaderModeActive`, `takeSnapshot` | the engine's own calls; `close` goes through the workspace like a page closing itself |
| tab `activate`, `setSelected(true)` | `.activateRequested`, which the workspace turns into `selectTab` |
| `openNewTabUsing` | `.openInNewTab` through the workspace (persisted, synced), returning the new tab when it exists at once; an extension URL opens in a sheet with the context's `webViewConfiguration`, since tabs hold web pages |
| `openNewWindowUsing` | its URLs open as tabs in the focused window; one window per scene |
| `openOptionsPageFor` | a sheet with the options page |
| `promptForPermissions`, `…MatchPatterns`, `…ToAccess` | an alert; Allow is saved in the record |
| `presentActionPopup` | `action.popupViewController` as a sheet on iPhone, a popover from the Extensions button on iPad |
| `sendMessage`, `connectUsing` (native messaging) | an error: there is no native app |

Clicks in a page count as a user gesture for `activeTab` (`shouldGrantPermissionsOnUserGesture`).

The action list: the page menu's Extensions row on iPhone, the Extensions button in the address row on iPad. It shows each running extension's action icon, label and badge for the selected tab; a tap runs `performAction`, which opens the popup or fires `action.onClicked`. Manage Extensions opens Settings › Extensions.

### Mac WebKit pages

`BrowserWebKitExtensionHost` exists per Chromium profile path. Its controller goes into every `BrowserWebKitPage` of the profile; the profile's pages are the tabs of two windows, normal and private. It loads each extension of the profile's preferences (`extensions.settings`, read like the toolbar does) from `Extensions/<id>/<version>`, skips ones that fail and logs why (`WebExtensions` category), and follows Chromium: `refreshBrowserExtensions` posts `browserChromiumExtensionsDidChange` when the list changes, and the host loads, unloads and switches extensions to match, with Allow in Incognito as private access. Content scripts and declarative blocking run; action popups do not open on the Mac yet. New tabs from extensions open through the page's tab; Chromium's install prompt already granted the permissions, so runtime requests are declined.

AMO add-ons install for the selected Space's profile from View › Add Add-on to WebKit Pages on an AMO add-on page (in either engine), with an alert as the prompt; View › Add-ons in WebKit Pages lists them and removes one after asking.

## Private browsing

A window is private when its pages' data store is not persistent: the Mac's incognito windows, and any iOS engine made with a non-persistent store. WebKit runs only contexts with `hasAccessToPrivateData` there, and `openWindows`/`focusedWindow` hide private windows from the others. The switch is Allow in Private Browsing in an extension's Settings page (off by default) on iOS, and Chromium's Allow in Incognito on the Mac. The iOS app has no private tabs today, so the switch matters once it does.

## Settings on iOS

Settings › Extensions lists installed extensions with their source (Chrome Web Store, Firefox · Partially compatible), version and state, links to both stores, and Check for Updates. An extension's page: Enabled, Source, Version, the load error if any, Site Access (All Requested Sites, or Only Selected Sites with a list of hosts, each also covering its subdomains), Allow in Private Browsing, Extension Options, Not Supported Here, Remove Extension.

## Test results

Checked on an iPhone 17 Pro simulator, iOS 27.2, Debug build without signing (so without the browser entitlement), 2026-11-19.

| Extension | Install | What works | What does not |
| --- | --- | --- | --- |
| uBlock Origin Lite 2026.1116.1650 (Chrome) | yes | declarative blocking (`googletagmanager.com`, `googlesyndication.com` blocked from a page; allowed again when disabled), popup with filtering modes | its options need `offscreen` and `userScripts`, which WebKit lacks |
| Dark Reader 4.9.135 (Chrome) | yes | after the background adaptation: dark pages, popup, per-site toggle | font list (`fontSettings`), context menu (no `contextMenus` on iOS) |
| Bitwarden 2026.10.2 (Chrome) | yes | background starts after the adaptation, chunks preloaded and Safari user agent | its popup never opens: WebKit does not present it; `sidePanel`, `idle`, `notifications`, `privacy` missing |
| 1Password 8.12.46.29 (Chrome) | yes | nothing usable | background stops: its WASM core does not initialize, and `webNavigation.onCreatedNavigationTarget`, `contextMenus`, `notifications`, `privacy`, `downloads` are missing |
| Dark Reader 4.9.135 (AMO, MV2) | yes | dark pages once its persistent page becomes non-persistent; listed as Firefox, partially compatible; `theme` listed as unsupported | Firefox theme integration |
| uBlock Origin 1.76.4 (AMO, MV2, blocking `webRequest`) | yes, listed with Blocking network requests, DNS lookups, Privacy settings as unsupported | — | blocks nothing, as expected: WebKit's `webRequest` only observes, and its background stops on `requestIdleCallback` and its `commands` entry |

On the Mac, the seven extensions of a real Chromium profile (uBlock Origin Lite, Refined GitHub, SponsorBlock, Material Icons for GitHub, iCloud Passwords, ChatGPT, Claude; all Manifest V3 service workers) parse and load into a `WKWebExtensionController` from their `Extensions/<id>/<version>` folders, read in place. Their behavior inside the app's WebKit pages has not been checked in the GUI yet.

## Known gaps

- **Service workers on iOS** need the `com.apple.developer.web-browser` entitlement. Until Apple grants it, service workers run as background pages, and code that needs a real worker (`clients`, `registration`, `importScripts` of computed paths beyond webpack chunks, `fetch` events) fails.
- **Blocking `webRequest`** does not exist in WebKit; blockers must use `declarativeNetRequest`.
- **APIs WebKit lacks**: `notifications` (stubbed in adapted backgrounds), `idle` (stubbed), `contextMenus`/`menus` on iOS, `fontSettings`, `sidePanel`, `offscreen`, `userScripts`, `downloads`, `history`, `bookmarks`, `privacy`, `proxy`, `contextualIdentities`, `identity`, `management`, `webNavigation.onCreatedNavigationTarget`.
- **Native messaging** has no app on the other end; Bitwarden's and 1Password's desktop integrations do not connect.
- **Mac WebKit pages** have no action buttons or popups yet.
- **Mozilla's signature** on add-ons is not verified (see above).

## App Store

Review guideline 2.5.2 bars apps from downloading code that changes their features. Extensions here are web content, HTML, CSS and JavaScript that WebKit runs in its own sandboxed web processes, as Safari and other App Store browsers run them; the app's native code does not change. Installs happen only when the user taps Add to OpenArc on an extension's public store page and approves its permissions; nothing installs in the background, and updates come from the same store for extensions the user installed. Extension code cannot reach native APIs: native messaging is refused.
