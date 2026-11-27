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
  own pages) beside them, and `cranelift-compiler`, WebAssembly's compiler, which WasmCompiler runs for each module
  (the layer points it there with `LADYBIRD_CRANELIFT_COMPILER`; Ladybird's own app runs it from its build tree).
  Helpers run with the hardened runtime and `Support/OpenArcLadybirdHelper.entitlements`; the compiler needs no
  exceptions and runs with the hardened runtime alone.
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
  - **Scripts.** `evaluate:` and the agent CLI's `Runtime.evaluate` run as Ladybird's console input, which a page's
    Content Security Policy does not block. An expression runs inside a wrapper that keeps its value, or its promise's
    result, in the page as JSON, read back until it settles; statements do not parse there and run as they are, with
    the completion value the console reports. `Page.captureScreenshot` and the tab's picture copy the frame the view
    shows (`--full` asks WebContent for the whole page). The agent CLI's clicks, keys and text arrive as AppKit
    events in `LadybirdWebView` (`BrowserPeerPageInput`), and its snapshots and selectors come from the page's DOM
    ([agent-access.md](agent-access.md)). A page in a covered window is hidden and hits nothing, so one that takes
    pointer input counts as shown for 5 seconds: only an agent clicks into a covered window.
  - **`openarc://` addresses.** Settings, history, bookmarks, downloads and version open Ladybird's own pages
    (`about:settings` …) and show under `openarc://`. The Easel's and the note's empty pages, the credits and a
    short "Not Available in Ladybird" page for extensions come from the app
    (`BrowserWebKitInternalPages.ladybirdPageHTML`). The passwords page opens Settings ▸ Profiles, where OpenArc
    keeps saved sign-ins. A shared page's Add to OpenArc button goes to the app.
  - **Sign-ins.** The layer watches a page's password fields with a script of its own: the app learns a page has a
    sign-in form, offers to save what a sent form held (on submit, or when a page with typed fields navigates away), and
    fills a saved sign-in into the fields, as on the Chrome engine.
  - **Site permissions.** Location, the microphone and notifications go through OpenArc's site permission prompt, and
    the answer holds for the site until quit (`navigator.permissions.query` reports it). After an Allow the app asks
    macOS once, as on the other engines; an allowed location reads Core Location. Ladybird answers a location request
    only for a visible document, so a page loaded in a covered window waits until it shows.
  - **Notifications.** A site's `new Notification(…)` shows as a macOS notification from OpenArc, with the site under
    the title, as a banner even while OpenArc is in front; a tag replaces the site's earlier one. Clicking it brings
    the page's window forward.
  - **Accessibility.** VoiceOver and other assistive apps read the page from the accessibility tree LibWeb builds
    (asked for again when it is older than two seconds, and at each load while VoiceOver runs): links, buttons,
    headings, images, form controls and the text between them, in document order, as children of the web view.
    Pressing a link, button or check box clicks it in the page.
  - **Links to `openarc://`** on a page (the passwords page's Open Settings) open in the page's tab, as the app's own
    navigations do, rather than going to macOS, which would hand them to the default OpenArc.
  - **Print.** Ladybird has no printing of its own; File › Print and a page's `window.print()` print the whole page
    as Ladybird draws it.
  - **Developer Tools.** Ladybird speaks Firefox's DevTools protocol. The Developer Tools commands start Ladybird's
    DevTools server and say where to connect from Firefox's `about:debugging`.
- **Ladybird's code.** The layer pins Ladybird to `Ladybird/engine/LADYBIRD_COMMIT`, the last commit with the AppKit
  port (Ladybird removed it on 2026-09-29 for its Qt port). `patches/series` lists OpenArc's changes to Ladybird
  itself:
  - `openarc-subdirectory.patch` adds the layer to Ladybird's CMake build;
  - `web-view-current-frame.patch` lets the page copy the frame its view shows, for captures of a page WebContent
    does not paint on request;
  - `context-menu-position.patch` opens context and select menus at the pointer when the web view does not start at
    the window's origin;
  - `request-finish-reentrancy.patch` keeps a request's read notifier alive until its activation returns; a download
    from a server without range requests crashed Ladybird's own browser too.
  - `site-permissions.patch` asks the UI process before the microphone and notifications (Ladybird granted the
    microphone without asking, and had no notification permission or display), exposes `navigator.permissions`, and
    hands a shown notification to the UI;
  - `sandbox-child-dyld.patch` lets a sandboxed helper's child start: dyld in `cranelift-compiler`, which inherits
    WasmCompiler's sandbox, aborted at launch on macOS 26 without `F_GETPATH`, so every module ran in the interpreter
    and left a crash report;
  - `window-print.patch` implements `window.print()`, which Ladybird left out: it fires `beforeprint` and
    `afterprint` around a request to the UI process.

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
- Passkeys: Ladybird has no WebAuthn.
- The camera and screen sharing: Ladybird captures audio only and has no `getDisplayMedia`. Pages on plain
  `http://127.0.0.1` are not a secure context in Ladybird, so they get no `navigator.mediaDevices` either.
- Notification actions, and `show`, `click` and `close` events on the page's `Notification`.
- Developer Tools docked beside the page; Ladybird's open in Firefox.
- A page's certificate chain in the site info.
- Positions inside pages for assistive apps: LibWeb reports none, so each element covers the page, and VoiceOver
  outlines the whole page rather than the element it reads. Heading levels, tables and live regions are not
  reported either.
- A page in a window covered by others is not drawn (Ladybird skips occluded pages, as Chromium does), so a capture
  of it gives no picture until the window shows.

## First launch

Ladybird looks through the Downloads folder for unfinished downloads when it starts. An app the user never let into
Downloads waits there for macOS's prompt before its first window; OpenArc itself already has the permission. Isolated
test copies with their own bundle id see the prompt once, as long as they are signed with the same identity.
