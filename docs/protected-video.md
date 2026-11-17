# Protected video

Chromium in OpenArc has no Widevine: Google licenses the CDM only to browsers it signs. Sites that need DRM play through Apple's FairPlay instead, in one of two ways.

## WebKit pages

A tab can show its page in WebKit (`BrowserWebKitPage`, a `WKWebView`), whose FairPlay plays protected video as Safari does. `BrowserTabController` keeps the WebKit page in the tab's record next to the Chromium fields, so the model, the sidebar, Split View and moving tabs between windows see one kind of tab.

- `BrowserPageEnginePolicy` picks the engine by site: a rule the user saved wins; otherwise streaming sites (`streamingDomains`, https, subdomains included) open in WebKit while Settings › Advanced › Protected Video › Open streaming sites in WebKit is on (the default).
- Typed, restored and app-opened addresses choose their engine; a Chromium page that follows a link or redirect to a WebKit site moves there (`OnBeforeBrowse`); links inside a WebKit page stay in WebKit. Moving closes the old page and loads the address in the other engine; Back from the first page returns to the address the other engine showed (`engineBackURL`).
- View › Open Page in WebKit / Open Page in Chromium switches the shown page and saves a rule for its site. Settings › Forget Website Choices removes the rules. Changing a setting or a rule moves open pages (`reapplyEnginePolicy`).
- WebKit pages keep one persistent `WKWebsiteDataStore` per profile (an identifier derived from the profile's data path), none in private windows. They use Safari's user agent, open popups as tabs, report media to the sidebar through an injected observer, and support find, zoom, mute, print, snapshots and Picture in Picture. Not in WebKit: extensions, password autofill, Chromium's site settings, translation and DevTools docking (Web Inspector opens from the context menu).

When Chromium refuses a page with a video the Widevine, PlayReady or FairPlay it asked for (`kProtectedMediaObserverScript` in the renderer), a prompt over the page offers Open in WebKit (saves a rule), Stay on Page (not asked again until quit) or Don't Ask Again (saves a Chromium rule). Private windows save no rules.

## FairPlay bridges in Chromium

Settings › Advanced › Protected Video › Play protected media in Chromium with FairPlay (off by default) keeps Spotify (`open.spotify.com`), Netflix (`www.netflix.com`) and Disney+ (`www.disneyplus.com`) in Chromium, with extensions.

### Spotify: audio

The renderer installs `kFairPlayBridgeScript` in that page's main world; it asks the browser whether the bridge is on (`hello` → `config`) before answering key system requests. When on:

1. `requestMediaKeySystemAccess` grants `com.apple.fps` with keys of the script's own and refuses Widevine and PlayReady, so the player picks FairPlay, as on Safari.
2. When the element with those keys gets an HLS playlist in a `data:` address with an `skd://` key, the playlist and the license server certificate go to `BrowserFairPlayAudioBridge` in the browser process, which plays it with `AVPlayer` and `AVContentKeySession`.
3. Each key request's SPC goes to the page as the session's `message`; the page's own code fetches the license and calls `update`, whose CKC goes back to the key session.
4. The element reports the native player's time, duration and state, so the page's controls, the media observer, the sidebar's mini player and the media keys work as usual. Tab mute mutes the native player.

### Netflix and Disney+: video

The sites must see Safari: their requests go out with Safari's user agent and without client hints (`SafariUserAgentRequestHandler`), and `kProtectedVideoBridgeScript`, installed in the top document while the switch is on (the renderer reads it with `CFPreferences`), gives `navigator` Safari's user agent and vendor. The script replaces `MediaSource` and `SourceBuffer` and the state of media elements whose source is such a MediaSource:

1. Appended fragments go to the browser as binary process messages. `BrowserProtectedVideoBridge` gives each element a `BrowserProtectedVideoPlayer`: each SourceBuffer parses with AVFoundation's stream parser (`AVStreamDataParser`, called by name), and the samples join a video or audio lane, which answers buffered ranges, `remove`, the timestamp offset and the append window.
2. The lanes feed an `AVSampleBufferDisplayLayer` and an `AVSampleBufferAudioRenderer` on one synchronizer: from the sync sample before a seek target, frames before it decoded but not shown. The player stalls when data runs out and resumes with a second ahead, and ends after `endOfStream`. The element reports time, ready state, size, rate, volume and the usual events.
3. Init data the parser finds in an encrypted fragment reaches the element as an `encrypted` event (`sinf`). `generateRequest` with `sinf` or `cenc` (a FairPlay `pssh`, key IDs from its `fkri` boxes) goes to one `AVContentKeySession`; each key's SPC, made with the page's server certificate, goes to the page as `message` (one bare SPC at a time, or a JSON list for `com.apple.fps.3_0`), and `update` returns the license. Keys from licenses are attached to each encrypted sample with `AVSampleBufferAttachContentKey`.
4. The page reports the element's box in CSS pixels; the view with the layer sits over the page view at that place, above it in the host view, and lets clicks through. Its layer blends with the page in screen mode: the player behind it is black, so the video shows there, and the site's controls and subtitles, drawn bright, show over it. Dark scrims over the video are lost, and light panels tint with the video.

Not yet: Picture in Picture for bridged video, the page's dropped-frame counts.

### Testing without an account

`defaults write com.levochkaa.OpenArc browser.debug.protectedVideoTestOrigins -array "http://localhost:8765"` makes the video bridge serve a local origin, so a Media Source test page with clear fragmented MP4 runs through the native player. Netflix's title pages, signed out, play their trailers as plain MP4, but their DRM check sends a `cenc` request, which shows that the certificate and SPC steps work.

Logs: the `FairPlay` and `ProtectedVideo` categories of the `com.levochkaa.OpenArc` subsystem (`log show --info --predicate 'category == "ProtectedVideo"'`). The page sees a media error when playback fails.
