# Protected video

Chromium in OpenArc has no Widevine: Google licenses the CDM only to browsers it signs. Sites that need DRM play through Apple's FairPlay instead, in one of two ways.

## WebKit pages

A tab can show its page in WebKit (`BrowserWebKitPage`, a `WKWebView`), whose FairPlay plays protected video as Safari does. `BrowserTabController` keeps the WebKit page in the tab's record next to the Chromium fields, so the model, the sidebar, Split View and moving tabs between windows see one kind of tab.

- `BrowserPageEnginePolicy` picks the engine by site: a rule the user saved wins; otherwise streaming sites (`streamingDomains`, https, subdomains included) open in WebKit while Settings › Advanced › Protected Video › Open streaming sites in WebKit is on (the default).
- Typed, restored and app-opened addresses choose their engine; a Chromium page that follows a link or redirect to a WebKit site moves there (`OnBeforeBrowse`); links inside a WebKit page stay in WebKit. Moving closes the old page and loads the address in the other engine; Back from the first page returns to the address the other engine showed (`engineBackURL`).
- View › Open Page in WebKit / Open Page in Chromium switches the shown page and saves a rule for its site. Settings › Forget Website Choices removes the rules. Changing a setting or a rule moves open pages (`reapplyEnginePolicy`).
- WebKit pages keep one persistent `WKWebsiteDataStore` per profile (an identifier derived from the profile's data path), none in private windows. They use Safari's user agent, open popups as tabs, report media to the sidebar through an injected observer, and support find, zoom, mute, print, snapshots and Picture in Picture. Not in WebKit: extensions, password autofill, Chromium's site settings, translation and DevTools docking (Web Inspector opens from the context menu).

When Chromium refuses a page with a video the Widevine, PlayReady or FairPlay it asked for (`kProtectedMediaObserverScript` in the renderer), a prompt over the page offers Open in WebKit (saves a rule), Stay on Page (not asked again until quit) or Don't Ask Again (saves a Chromium rule). Private windows save no rules.

## FairPlay bridge in Chromium

Settings › Advanced › Protected Video › Play Spotify in Chromium with FairPlay (off by default) keeps `open.spotify.com` in Chromium, with extensions. The renderer installs `kFairPlayBridgeScript` in that page's main world; it asks the browser whether the bridge is on (`hello` → `config`) before answering key system requests. When on:

1. `requestMediaKeySystemAccess` grants `com.apple.fps` with keys of the script's own and refuses Widevine and PlayReady, so the player picks FairPlay, as on Safari.
2. When the element with those keys gets an HLS playlist in a `data:` address with an `skd://` key, the playlist and the license server certificate go to `BrowserFairPlayAudioBridge` in the browser process, which plays it with `AVPlayer` and `AVContentKeySession`.
3. Each key request's SPC goes to the page as the session's `message`; the page's own code fetches the license and calls `update`, whose CKC goes back to the key session.
4. The element reports the native player's time, duration and state, so the page's controls, the media observer, the sidebar's mini player and the media keys work as usual. Tab mute mutes the native player.

Failures are logged under the `FairPlay` category of the `com.levochkaa.OpenArc` subsystem (`log show --predicate 'category == "FairPlay"'`); the page sees a media error.

Video sites are not bridged: their players feed encrypted fragments through Media Source Extensions, which would need a native sample-buffer player drawn over the page and the site's controls drawn above it. They open in WebKit.
