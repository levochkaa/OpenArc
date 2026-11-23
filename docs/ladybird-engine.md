# Ladybird engine

OpenArc can run every page on [Ladybird](https://ladybird.org), an independent engine with its own HTML, CSS and
JavaScript, with no Chromium loaded. Settings ▸ Advanced ▸ Engine ▸ "Use Ladybird for every page" turns it on. Like
"Use WebKit for every page" ([webkit-engine.md](webkit-engine.md)) it is a toggle of its own, and turning one on turns
the other off; off, the app goes back to CEF or the Chrome engine ([chrome-engine.md](chrome-engine.md)), whichever
"Use Chrome's engine" chose. The process runs on one engine from launch to quit, so the switch takes effect after a
relaunch, which the setting offers. `--openarc-engine=ladybird` (or `cef`, `chrome`, `webkit`) overrides the setting
for one launch. A bundle without the framework runs Ladybird's choice on the Chromium engine.

## Why

- A third engine that shares no code with Chromium or WebKit: pages show how they work on a browser built from the
  specifications, and OpenArc's windows, Spaces, tabs, notes and Easels stay the same around them.
- Ladybird runs every page in sandboxed helper processes of its own (WebContent, RequestServer, ImageDecoder and the
  rest), so a crash takes down one page, as on Chromium.

## Shape

- **One bundle, several engines.** The app bundle carries `OpenArc Ladybird.framework` beside CEF and the Chrome
  engine. The app never links it: `main()` (`Sources/Browser/BrowserMain.mm`) asks `BrowserEngineChoice` which engine
  this launch runs on and, for Ladybird, `BrowserRunLadybirdEngine`
  (`Sources/Browser/LadybirdEngine/BrowserLadybirdEngineMain.mm`) `dlopen`s the framework and hands the process to
  `OpenArcLadybirdEngineMain`, which runs start to quit. Neither CEF nor Chrome's framework loads.
- **The framework.** `Versions/A/OpenArc Ladybird` is OpenArc's layer linked with Ladybird's libraries;
  `Versions/A/Libraries` holds those libraries and the vcpkg ones they load (Skia, ICU, HarfBuzz, curl, FFmpeg …);
  `Versions/A/Helpers` holds Ladybird's helper processes, which find `Versions/A/Resources` (fonts, themes, Ladybird's
  own pages) beside them. Helpers run with the hardened runtime and `Support/OpenArcLadybirdHelper.entitlements`.
- **The contract** is `Sources/Browser/LadybirdEngine/BrowserLadybirdEngine.h`, which `Ladybird/engine/apply.sh`
  copies into the Ladybird tree with `BrowserChromeEngine.h`. A Ladybird page is a `BrowserChromePage`, so
  `BrowserTabController` keeps it in `TabRecord.peerPage` and shows, navigates, finds, mutes, captures, prints and
  moves it between windows, and takes its popups, keys, link status, downloads and crashes, through the code Chrome
  engine pages already use. `BrowserUsesLadybirdEngine()` marks what differs; `BrowserUsesCEF()` is 0, so no call
  into CEF runs.
- **The layer** (`Ladybird/engine/openarc`, built as the CMake target `openarc_ladybird`):
  - `engine_main.mm`: Ladybird's `WebView::Application` without windows of its own. Its event loop is AppKit's run
    loop (`EventLoopImplementationMacOS`), so `[NSApp run]` drives both; `OpenArcLadybirdApplication` is NSApp, which
    hands Ladybird's application-defined events to its event queue and keeps Cocoa's own quit, so OpenArc's app
    delegate decides. The profile lives in `~/Library/Application Support/OpenArc/Ladybird` (`Ladybird-<suffix>` for
    an isolated runtime), apart from Chromium's and WebKit's. The process neither takes URLs from another Ladybird
    process nor hands them over. Downloads go to the Downloads folder without a prompt and appear in OpenArc's
    downloads list, where they can be cancelled.
  - `ladybird_page.mm`: `OpenArcLadybirdPage`, a container view around `LadybirdWebView`, the web view of Ladybird's
    AppKit port (input, IME, drag and drop, context menus, select menus, colour and file pickers, JavaScript
    dialogs, the Metal-presented page). Ladybird's link status, `window.close()` and its requests to move or resize
    the window go to the tab controller instead of Ladybird's own window. A page's `window.open` becomes an OpenArc
    tab with its opener intact (`initAsChild`), as on the Chrome engine.
  - **Scripts.** `evaluate:` and the agent CLI's `Runtime.evaluate` run through Ladybird's console input; a returned
    promise is awaited by reading its result back from the page. `Page.captureScreenshot` and the tab's picture use
    Ladybird's own screenshots.
  - **`openarc://` addresses.** Settings, history, bookmarks, downloads and version open Ladybird's own pages
    (`about:settings` …) and show under `openarc://`. The Easel's and the note's empty pages, the credits and a
    short "Not Available in Ladybird" page for extensions and passwords come from the app
    (`BrowserWebKitInternalPages.ladybirdPageHTML`). A shared page's Add to OpenArc button goes to the app.
  - **Print.** Ladybird does not print; File › Print prints the whole page as Ladybird draws it.
  - **Developer Tools.** Ladybird speaks Firefox's DevTools protocol. The Developer Tools commands start Ladybird's
    DevTools server and say where to connect from Firefox's `about:debugging`.
- **Ladybird's code.** The layer pins Ladybird to `Ladybird/engine/LADYBIRD_COMMIT`, the last commit with the AppKit
  port (Ladybird removed it on 2026-09-29 for its Qt port). `patches/series` lists OpenArc's changes to Ladybird
  itself; `openarc-subdirectory.patch` adds the layer to Ladybird's CMake build.

## Building

Ladybird builds natively on macOS only, so `script/ladybird_engine.sh` builds on the Mac, at low priority, in
`~/ladybird-engine` (`OPENARC_LADYBIRD_ROOT`).

| Step | Command | Notes |
| --- | --- | --- |
| Get the source | `./script/ladybird_engine.sh fetch` | Clones Ladybird and checks out `LADYBIRD_COMMIT`. |
| Build | `./script/ladybird_engine.sh build` | Applies the layer (`apply.sh`), builds vcpkg's ports the first time (about an hour), then the layer and Ladybird's helpers. Incremental. `OPENARC_LADYBIRD_JOBS` caps the jobs (half the cores by default). |
| Package | `./script/ladybird_engine.sh package` | Puts `OpenArc Ladybird.framework` together in `~/ladybird-engine/dist`: the layer, helpers, libraries, resources and licenses, with their load paths set for the framework, signed ad hoc. |
| Copy | `./script/ladybird_engine.sh pull` | Copies it to `ThirdParty/ladybird-engine/export` of the primary checkout. |

`all` runs every step. Then `./build.sh build` stages the framework (`script/stage_cef_bundle.sh`; it also goes into
a bundle without CEF, `OPENARC_STAGE_CEF=0`; `OPENARC_STAGE_LADYBIRD_ENGINE=0` leaves it out) and signs its
libraries, helpers and the framework with the app's identity; `script/sign_release_app.sh` signs them for release.
`script/cef_smoke_test.sh <app> --engine ladybird` checks a build on Ladybird ([cef-smoke-test.md](cef-smoke-test.md)).

Ladybird's own switches pass through with a `--ladybird-` prefix: `--ladybird-devtools=6000` starts its DevTools
server on that port, `--ladybird-debug-process=WebContent` waits for a debugger.

## Data

Ladybird keeps its own cookies, storage, history and caches, apart from Chromium's and WebKit's, so sites ask to sign
in again after the switch; Import ▸ cookies from another browser writes into Ladybird's cookie jar. Ladybird keeps
one profile for the process: OpenArc's profiles share it on this engine, and private windows use Ladybird's private
sessions. OpenArc's own data (Spaces, tabs, notes, Easels, boosts, bookmarks, sync) stays the same on every engine.

## Not on Ladybird

- Many sites still break or look wrong: Ladybird is in development, and this is its state of 2026-09-29.
- Extensions, Peek cards and small windows (they open as tabs), web sign-in windows, translation, site settings,
  battery saver throttling and tracing.
- Protected video (no EME/FairPlay) and picture in picture. Sites whose rule sends them to WebKit still open in
  WebKit tabs.
- Passwords and passkeys: OpenArc's saved sign-ins do not fill, and Ladybird has no passkeys.
- OpenArc's site permission prompts: Ladybird asks for what it supports (location, notifications) itself.
- Developer Tools docked beside the page; Ladybird's open in Firefox.
- A page's certificate chain in the site info.
