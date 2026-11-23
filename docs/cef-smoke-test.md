# Engine smoke test

`script/cef_smoke_test.sh` checks that a build's engine works: it starts a copy of the app, drives real pages through the agent CLI and the copy's windows through cua-driver, and fails on anything broken. Unit tests (`./build.sh test`) use fake tab drivers and never start CEF, so run this after every CEF or Chromium update, before a Beta release. It runs in the background: the copy never activates and its windows stay behind other apps, so the Mac stays usable.

    ./build.sh build
    script/cef_smoke_test.sh .build/xcode/Build/Products/Debug/OpenArc.app

`--engine chrome` runs the same checks on the Chrome engine ([chrome-engine.md](chrome-engine.md)) for a build that carries `OpenArc Framework.framework`: the copy starts with `--openarc-engine=chrome`, and checks of features the engine does not have yet skip with the reason.

    ./script/chrome_engine.sh pull && ./build.sh build
    script/cef_smoke_test.sh .build/xcode/Build/Products/Debug/OpenArc.app --engine chrome

`--engine webkit` starts the copy with `--openarc-engine=webkit` ([webkit-engine.md](webkit-engine.md)), on a full
build or one made with `OPENARC_STAGE_CEF=0`. chromium-engine then checks that no Chromium runs: no helper process
from the bundle, and neither CEF nor the Chrome engine among the main process's open files. engine-version expects
Safari's user agent, webkit-engine expects WebKit on both ports, and the checks of Chromium's own features skip.

`--engine ladybird` starts the copy with `--openarc-engine=ladybird` ([ladybird-engine.md](ladybird-engine.md)) for a
build that carries `OpenArc Ladybird.framework`. chromium-engine then checks that pages run in WebContent helpers
from that framework, that no Chromium renderer runs and that the main process loaded no framework but Ladybird's;
sandbox checks that Ladybird's page, worker, image, request, media and drawing helpers run in the macOS sandbox.
engine-version expects Ladybird's user agent, webkit-engine expects WebKit for the site routed there and Ladybird
for the other, and the checks of what Ladybird lacks skip.

    ./script/ladybird_engine.sh all && ./build.sh build
    script/cef_smoke_test.sh .build/xcode/Build/Products/Debug/OpenArc.app --engine ladybird

It prints a report and a JSON summary, and writes `report.json`, `app.log`, `notification-log.txt` and screenshots to the report folder (`--out DIR`, by default a new folder in `$TMPDIR`). Exit status: 0 when no check failed, 1 when one did, 2 when the copy did not start. A check is PASS, WARN (works, with a note on what it could not prove), FAIL or SKIP (with the reason). `--help` lists the options.

Needs: an Apple Development signing identity, `cua-driver` with Accessibility and Screen Recording (without it, `--no-gui` runs the rest), and the network for translation.

## The copy

The script copies the app to `~/Library/Caches/OpenArcSmokeTest/OpenArcSmoke.app` and gives it the bundle id `com.levochkaa.OpenArc.smoketest` and the name "OpenArc Smoke", helpers included, so it has defaults, macOS permissions and notification settings of its own, and any prompt it causes names it. It removes `embedded.provisionprofile`, re-signs the helpers (the Chrome engine's inside its framework too, then the framework) and the app with only `get-task-allow`, and presets onboarding as done, agent access on and update checks off.

It starts the copy through LaunchServices with `open -g` and `--no-activate`, `--runtime-suffix=cef-smoke-<random>`, `--agent-socket=/tmp/oa-smoke-<random>.sock`, `--use-mock-keychain` (no keychain prompts) and `--load-extension` with the test extension. A copy started from a shell becomes the frontmost app even though it never activates itself; `open -g` keeps it in the background. Apps that LaunchServices starts get launchd's environment, so `OPENARC_SYNC_BASE_URL` never reaches the copy and it does not sync. Afterwards the script kills it with SIGKILL (SIGTERM shows the quit alert) and deletes the app copy, `CEF-<suffix>`, `Session-<suffix>` and the defaults domain.

`--no-activate` is a launch argument for automated checks: OpenArc then never activates itself and opens its windows behind other apps' windows. A copy started with `--agent-socket` leaves `~/.local/bin/openarc` alone.

## Checks

| Check | How |
| --- | --- |
| chromium-engine | The copy's renderer processes run from the engine `--engine` names: CEF's helpers in `Contents/Frameworks`, or the helpers inside `OpenArc Framework.framework`. |
| sandbox | `sandbox_check()` returns 1 for every renderer, GPU and utility process of the copy, and none has `--no-sandbox`: a page that breaks the engine stays inside the macOS sandbox. Chromium starts `VideoCaptureService` without a sandbox on macOS, so it is left out. |
| no-notification-request-at-launch | `Notification.permission` is `default` and `permissions.query` is `prompt` on a page; the system log, streamed from before launch, has no `Requesting authorization` from the copy and no `Sending request for permission` from `usernoted` for its bundle ids; no NotificationCenter banner names "OpenArc Smoke" in the first 10 s. |
| engine-version | `navigator.userAgent` and `userAgentData` report the `CHROME_VERSION_MAJOR` of `ThirdParty/cef/export/include/cef_version.h`. |
| page-load-js-navigation | A fixture page runs its script; `navigate`, `back` and `forward` land on the right titles. |
| proprietary-codecs | `canPlayType` is `probably` for H.264 (`avc1.42E01E`) and AAC (`mp4a.40.2`); `fixtures/h264-aac.mp4` (2 s, 96x64, made with ffmpeg's `testsrc` and `sine` sources) plays and `currentTime` advances. |
| extension-sees-tabs | The test extension's service worker answers `chrome.tabs.query({})`; the count matches `openarc tabs`, including a tab that was never shown. |
| passkeys | `isUserVerifyingPlatformAuthenticatorAvailable()` and `getClientCapabilities()` resolve. False is a WARN: the copy has no webauthn keychain group. |
| media-devices | `navigator.mediaDevices` exists, `getDisplayMedia` is a function, `enumerateDevices` resolves. |
| history | The visited fixture URLs are in the profile's `History` database, which OpenArc's history reads; the CLI has no history command. |
| webkit-engine | The copy's `browser.settings.siteEngines` sends a second fixture port to WebKit. The fixture writes the engine it sees into its title, which `openarc tabs` lists: `Engine webkit 42` there, `Engine chromium 42` on the other port. |
| print-preview | `window.print()` opens a "Print" window over the browser window; Escape, sent in the background, closes it and the page still runs scripts. |
| screen-share-picker | `getDisplayMedia` from a click opens OpenArc's picker sheet. With Screen Recording allowed for the copy it shares the first source and checks the track, then stops it; otherwise it presses Cancel and expects `NotAllowedError`. |
| extension-popup | Extensions > OpenArc Smoke Test, pressed through accessibility, opens the popup; its `chrome.tabs.query({active: true, currentWindow: true})` sees the selected tab. |
| notification-after-site-permission | A click calls `Notification.requestPermission()`; the script presses Allow on OpenArc's prompt. The copy must turn to macOS only after that. The page gets `granted` whatever macOS answers, and the notification fires `onshow`; whether macOS shows it depends on the copy's notification settings and Focus. |
| translate-in-place | `openarc command translatePage` on a German page changes the text at the same address; the command again brings the original back. |
| background-launch | `lsappinfo front` never names the copy during the run. |
| stability | The main process is alive at the end, and no crash report newer than the launch names the copy's path. |

## Set up once per Mac

These depend on decisions macOS keeps for `com.levochkaa.OpenArc.smoketest`, which stay across runs.

- **Screen Recording.** The picker asks ScreenCaptureKit for screens and windows, and macOS prompts while the copy has no decision. The script reads the TCC databases (this needs Full Disk Access for the terminal; otherwise the state is `unknown`) and skips the check until someone decides. To decide: run once with `--allow-system-prompts` and answer the prompt. Allowed: the picker lists screens and windows and the check shares one. Denied: the check covers the sheet and Cancel only.
- **Notifications.** Turn on notifications for "OpenArc Smoke" in System Settings > Notifications to check delivery; while they are off, OpenArc shows its hint about System Settings after Allow, and macOS shows no banner. System Settings lists the copy only while it exists, so run with `--keep` to change its toggle.
- **Launch requests.** The engine asks macOS for notification permission only while macOS has no decision for the app, so once the copy has one, a clean launch proves nothing and no-notification-request-at-launch is a WARN. `--fresh-identity` gives the copy a new bundle id for one run and makes the check conclusive; macOS then keeps a notification entry for that id, and screen-share-picker skips.

## What a person still does

- Answer macOS's own prompts. The notification prompt banner on macOS 26 shows Allow only while the pointer hovers it and gives accessibility no button for it, so the script reads it and leaves it; TCC prompts (Screen Recording) are the person's by rule.
- See passkeys sign in with Touch ID: that needs a build signed with the webauthn keychain group (a Developer ID release), which a re-signed copy is not.

