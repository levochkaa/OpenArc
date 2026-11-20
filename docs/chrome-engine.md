# Chrome engine

OpenArc can draw Chromium pages with Chrome's own framework (`//chrome:chrome_framework`) instead of CEF.
Settings ▸ Advanced ▸ Engine ▸ "Use Chrome's engine" switches it; CEF stays the default. The process runs on one
engine from launch to quit, so the switch takes effect after a relaunch, which the setting offers. A launch with
`--openarc-engine=chrome` or `--openarc-engine=cef` overrides the setting once.

## Why

- CEF makes every tab a browser of its own. Chrome's framework holds a window's pages as tabs of one Chrome
  `Browser`, which needs less memory in the browser process.
- Chrome's tab helpers (extensions, permissions, autofill, passkeys, find, zoom, favicons) attach to the pages
  as they do to Chrome's own tabs, without CEF's glue.
- A Chrome stable tag can be built the day it ships, without waiting for a CEF branch.

## Shape

- **One bundle, two engines.** The app bundle carries `Chromium Embedded Framework.framework` and, when it was
  built, `OpenArc Framework.framework` (Chrome's framework with OpenArc's layer and its own helpers inside). The
  app never links either: `main()` (`Sources/Browser/BrowserMain.mm`) asks `BrowserEngineChoice` which engine
  this launch runs on, then loads CEF as before or `dlopen`s Chrome's framework and hands the process to
  `OpenArcChromeEngineMain`, which runs `ChromeMain` start to quit. CEF is never loaded on the Chrome engine.
- **Same Chromium, same profile.** The engine builds from the Chromium tag of the exported CEF (158.0.8127.18
  now), and Chrome gets OpenArc's data folder (`~/Library/Application Support/OpenArc/CEF`, profile `Default`)
  as its user data. Cookies, passwords, history and extensions open on either engine, and switching back is safe:
  neither engine meets a profile written by a newer Chromium. Both use the "Chromium Safe Storage" Keychain item.
  Moving the engine to a newer Chromium than CEF's would make switching back a downgrade; move both together.
- **The contract** is `Sources/Browser/ChromeEngine/BrowserChromeEngine.h`, which `Chromium/engine/apply.sh`
  copies into the Chromium tree. A page on the Chrome engine is a `BrowserPeerPage`, the same members
  `BrowserWebKitPage` has, so `BrowserTabController` keeps it in `TabRecord.peerPage` beside WebKit pages and
  shows, navigates, finds, mutes, captures, prints and moves it between windows through the code WebKit pages
  already use. What only a Chrome page does (DevTools protocol, Developer Tools, renderer process, popups,
  downloads, keys) is `BrowserChromePage` and `BrowserChromePageDelegate`.
- **OpenArc's changes to Chromium itself** that are not CEF's (notification permission, the history database,
  the passkey keychain group, the About page's update status) come along: `Chromium/engine/overrides` lists the
  files of `Chromium/chromium_src` the engine takes too. A new override that is pure Chromium belongs there.
- **The layer** (`Chromium/engine/openarc`, linked into Chrome's framework as `//openarc:core`):
  - one hidden Chrome `Browser` per profile holds that profile's pages as background tabs behind a blank one;
    its window is invisible, never key, and rides along with the OpenArc window in use as a child of the same
    frame, so what Chrome anchors to it (JavaScript dialogs, permission bubbles, extension popups) shows over
    OpenArc's window. The window and its views take no pointer events, so Chrome's tab strip under the pointer
    shows no hover or tab hover card: a transparent window that ignores mouse events still gets its tracking
    areas' moves;
  - each page's view lives in OpenArc's windows; `views::OpenArcHostedPageKey` keeps Chrome's window from
    taking it back (`patches/hosted-pages.patch`);
  - a page Chrome opens (a link in a new tab, `window.open`, an extension's tab) becomes an OpenArc tab through
    the opener's delegate, with its contents and `window.opener` intact;
  - downloads of OpenArc's profiles are reported to the page that started them;
  - `OpenArcChromeApplication` is NSApp: Chrome's application class, which its message pump needs, with Cocoa's
    own quit, so OpenArc's app delegate decides.
- **Chrome's own code** changes in `Chromium/engine/patches` (`series` lists the order):
  - `engine-hooks.patch`: OpenArc's start-up part, no AppController or main menu of Chrome's, the framework's
    exports, `//openarc:core` in `chrome_dll`;
  - `hosted-pages.patch`: pages stay in OpenArc's windows;
  - `browser-delegate.patch`: keys (OpenArc's shortcuts before the page, its menus after), element fullscreen in
    OpenArc's window, and the link under the pointer for OpenArc's status line.
  - `frame-sink-destruction.patch`: a page hidden in OpenArc's window drops its own compositor, and the GPU side of
    it is destroyed without the synchronous wait Chrome does for a window the GPU process draws into, which a Mac
    window never is. The wait stalled tab switches.
- The hooks (`Chromium/engine/hooks/openarc_engine_hooks.h`) are null until `OpenArcChromeEngineMain` sets them,
  so the patched code behaves as Chrome's own otherwise.
- The layer is based on Cra's engine bridge (github.com/VictorKildahl/cra, MIT License), credited in
  `Sources/Browser/Resources/Credits.html`.

## Building

The engine builds on the Linux build host, beside CEF ([cef-build.md](cef-build.md)), and comes to the Mac as a
finished framework. `script/chrome_engine.sh` drives it over ssh from the Mac; the host side is
`script/cef_cross/chrome_engine_cross.sh`.

| Step | Command | Notes |
| --- | --- | --- |
| Configure | `./script/chrome_engine.sh prepare` | Copies the CEF build root's Chromium checkout without `src/cef` and `src/out` (once per base), reverts CEF's patches and OpenArc's CEF overrides in every repository, applies the cross-build fixes and OpenArc's layer, runs `gn gen out/OpenArc_arm64`. |
| Build | `./script/chrome_engine.sh build` | Applies the layer again and builds `chrome_framework`. Incremental. |
| Package | `./script/chrome_engine.sh package` | Puts `OpenArc Framework.framework` in the host's `artifacts/dist`. |
| Copy | `./script/chrome_engine.sh pull` | rsyncs the framework to `ThirdParty/chrome-engine/export` in the primary checkout (in this checkout while it uses a CEF export other than the shared one, `cef_remote_build.sh use`) and strips local symbols with Xcode 26.6's `strip -x`. Refuses a framework whose Chromium differs from the exported CEF's. |

`all` runs prepare, build and package. As with CEF, remote steps run in a tmux session on the host (`status`,
`wait`, `WAIT=1`). After a layer change:

```sh
WAIT=1 ./script/chrome_engine.sh build
WAIT=1 ./script/chrome_engine.sh package
./script/chrome_engine.sh pull
./build.sh build                    # stages the exported framework next to CEF and signs it
```

`OPENARC_CEF_REMOTE_HOST` (default `wsl`) picks the host, `OPENARC_CHROME_ENGINE_REMOTE_ROOT` (default
`~/chrome-engine`) the engine's build root, and `OPENARC_CEF_REMOTE_ROOT` (default `~/cef-mac`) the CEF build root
whose checkout, depot_tools and hermetic Xcode the engine uses. The build runs at idle CPU and disk priority;
`NINJA_JOBS` caps its jobs, so the host stays usable for other work. The engine builds the Chromium version of
`ThirdParty/cef/export/include/cef_version.h`; when CEF moves to a new base, run CEF's `fetch` first, then
`prepare` copies the new checkout. The GN arguments match CEF's (official, PGO, ThinLTO, Chrome's codecs) with
`target_os="mac" use_system_xcode=false`; like the cross-built CEF, the framework ships `snapshot_blob.bin`
instead of the V8 context snapshot.

`script/stage_cef_bundle.sh` stages the framework when the export exists and its Chromium is CEF's
(`OPENARC_STAGE_CHROME_ENGINE=0` leaves it out; after CEF moves, the build runs on CEF only until the engine is
rebuilt), and `script/sign_release_app.sh` signs its helpers with the CEF helpers' entitlements.

## Not yet on the Chrome engine

The CEF code paths stay as they are; on the Chrome engine these answer nothing or fall back:

- Peek cards and small windows open as tabs; web sign-in windows and cookie import need CEF.
- `openarc://` pages (CEF scheme handlers), the renderer-side scripts of `Sources/Helper` (password and address
  form detection, protected video bridges) and site permission prompts in OpenArc's own card (Chrome shows its
  bubbles over the window instead).
- Site settings, translate, battery saver throttling, tracing and the extension bridge's CEF exports.
- OpenArc's screen share picker: `getDisplayMedia` shows no picker in OpenArc's window.
- Extensions see one more tab in `chrome.tabs.query`: the blank tab of the profile's hidden window.
- The built-in ad, tracker and cookie banner blocking (it filters CEF's resource requests), Easel tabs (their
  blank page is an `openarc://` page) and moving a page whose protected video fails to WebKit.
- Chrome's background mode stays on: Chromium 156 no longer builds extensions without it.
- Developer Tools open in Chrome's own window instead of docking beside the page.
- Downloads go where Chrome's download settings say.
