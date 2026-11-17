#ifndef OPENARC_SHARED_BROWSER_PROTECTED_MEDIA_H_
#define OPENARC_SHARED_BROWSER_PROTECTED_MEDIA_H_

#include <string>

namespace shared {

// Whether Settings › Protected Video › Play protected media in Chromium is on.
// Read from the app's preferences, so any process and thread can ask.
bool ProtectedMediaBridgeOn();

// Top documents whose protected video the bridge plays: the video sites, and
// origins listed under `browser.debug.protectedVideoTestOrigins` for testing.
bool BridgesProtectedVideo(const std::string& url);

// A request to a video site that must see Safari: its pages and their APIs.
bool NeedsSafariUserAgent(const std::string& url);

// Safari's user agent, with the installed Safari's version.
const std::string& SafariUserAgent();

}  // namespace shared

#endif  // OPENARC_SHARED_BROWSER_PROTECTED_MEDIA_H_
