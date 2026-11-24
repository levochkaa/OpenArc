# WebKit engine

OpenArc can run every page in WebKit, with no Chromium loaded. Settings ▸ Advanced ▸ Engine ▸ "Use WebKit for every
page" turns it on. It is a toggle of its own: off, the app goes back to CEF or the Chrome engine, whichever "Use
Chrome's engine" chose. Like the Chrome engine ([chrome-engine.md](chrome-engine.md)), the process runs on one engine
from launch to quit, so the switch takes effect after a relaunch, which the setting offers. `--openarc-engine=webkit`
(or `cef`, `chrome`, `ladybird`) overrides the setting for one launch. "Use Ladybird for every page"
([ladybird-engine.md](ladybird-engine.md)) is the other such toggle; turning one on turns the other off.

A bundle without `Chromium Embedded Framework.framework` always runs on WebKit, whatever the setting or the argument
says. That is the base of a Mac App Store build (below).

## Why

- A Mac App Store app runs in the App Sandbox and ships no private API. CEF's helper processes, its own sandbox and
  its size (the bundle drops from over a gigabyte to 66 MB without it) do not fit there.
- WebKit plays protected video with FairPlay and uses the system's passwords, passkeys and content blockers.

## Shape

- **Launch.** `main()` (`Sources/Browser/BrowserMain.mm`) asks `BrowserEngineChoice` first. On WebKit,
  `BrowserRunWebKitEngine` (`Sources/Browser/WebKit/BrowserWebKitEngineMain.mm`) starts `NSApplication`, creates the
  app and reports the engine ready at once, then runs the loop. CEF is never loaded, and neither is the Chrome engine.
- **Settings.** `BrowserEngineChoice` keeps the Chromium choice in `BrowserChromiumEngine` (`chrome` or absent) and the
  WebKit toggle in `BrowserWebKitEngine`, so turning WebKit off restores the Chromium engine chosen before.
- **Guards.** `BrowserUsesCEF()` is 1 only when CEF is loaded. Every call into CEF outside a CEF page's own code checks
  it, as the Chrome engine already needed; `BrowserUsesWebKitEngine()` marks what WebKit does instead.
- **Pages.** `BrowserTabController` opens every tab as a `BrowserWebKitPage`, the peer page streaming sites already
  used in CEF builds, whatever the address. "Open Page in Chromium" is off. Each profile keeps its own
  `WKWebsiteDataStore(forIdentifier:)`, made from the profile's folder; a private window keeps none.
- **OpenArc's own addresses.** `BrowserWebKitInternalPages` serves `openarc://` and `chrome://`: the empty pages under
  Easels and notes, the credits, and a short "Not Available in WebKit" page for Chromium's own pages (settings,
  history, extensions, bookmarks). The passwords page opens Settings ▸ Profiles, where OpenArc keeps saved sign-ins,
  and says so.
- **Downloads** go to the download folder and appear in the downloads list, where they can be cancelled
  (`BrowserWebKitDownloads`). This also holds for WebKit tabs in a CEF build.
- **Cookie import** from other browsers writes into the profile's WebKit store.
- **`window.print()`** opens the same print panel as File › Print: WKWebView has no public delegate call for it, so a
  page script hands it to the app.
- **Undo.** A WebKit page's text edits use their own undo manager. The window's manager holds tab actions and never
  groups by event, and WebKit's edits used to throw there and quit the app.
- **The agent CLI** runs scripts and takes screenshots in WebKit pages: `BrowserWebKitPage` answers
  `Runtime.evaluate` and `Page.captureScreenshot` as Chromium does. Clicks, snapshots and other DevTools methods still
  need Chromium.

## Data

WebKit keeps its own cookies, storage and caches, apart from Chromium's profile, so sites ask to sign in again after
the switch. OpenArc's own data (Spaces, tabs, notes, Easels, boosts, bookmarks, sync) stays the same on every engine.
Extensions the Chromium profile installed earlier, and Firefox add-ons, run through WebKit's WebExtensions where
WebKit supports them ([extensions-webkit.md](extensions-webkit.md)); new ones from the Chrome Web Store need Chromium.

## Not on WebKit

- Peek cards and small windows open as tabs; web sign-in windows need CEF.
- Developer Tools: pages are inspectable from Safari's Develop menu, but OpenArc's toolbar and menu commands do
  nothing.
- Chromium's own pages, translation, site settings, battery saver throttling, tracing, screen share through
  OpenArc's picker, and Chromium extensions' toolbar buttons and side panels.
- Chromium's History database, which the history page reads: visits on WebKit do not reach it.

## Building without Chromium

```sh
OPENARC_STAGE_CEF=0 ./build.sh build
```

`script/stage_cef_bundle.sh` then leaves out CEF, its helpers, the Chrome engine and CEF's credits, and signs what
is left. The next build without the variable puts them back. `script/cef_smoke_test.sh <app> --engine webkit`
checks such a bundle, or a full one on WebKit ([cef-smoke-test.md](cef-smoke-test.md)).

## Toward the Mac App Store

The WebKit-only bundle runs; these steps remain before a submission:

- App Sandbox entitlements: `com.apple.security.app-sandbox`, network client, user-selected and Downloads folder
  access, camera, microphone, location, print.
- No Sparkle: the store updates the app.
- `BrowserWebKitPage.setAudioMuted` calls WebKit's private `_setPageMuted:`; it needs a public replacement.
- `BrowserLaunchWarmup` loads `AppPredictionClient` from `PrivateFrameworks`.
- Features that write outside the container need a sandboxed form or must go: the `openarc` link in `~/.local/bin`,
  native messaging host manifests for other browsers, web apps (`BrowserWebApps.swift`), and imports that read other
  browsers' profiles without an open panel.
