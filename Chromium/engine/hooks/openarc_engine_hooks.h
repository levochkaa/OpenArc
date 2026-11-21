// OpenArc's hooks into Chrome's own code (Chromium/engine in the OpenArc repository). OpenArc's layer sets
// them before ChromeMain runs; Chrome never does, so nothing here changes Chrome on its own.
// Based on Cra's engine hooks (https://github.com/VictorKildahl/cra, MIT License).
#ifndef CHROME_BROWSER_OPENARC_ENGINE_HOOKS_H_
#define CHROME_BROWSER_OPENARC_ENGINE_HOOKS_H_

#include <memory>
#include <string>

#include "mojo/public/cpp/bindings/pending_remote.h"
#include "services/network/public/mojom/url_loader_factory.mojom-forward.h"

class ChromeBrowserMainExtraParts;
class GURL;

namespace content {
class NavigationThrottleRegistry;
class WebContents;
}
namespace input {
struct NativeWebKeyboardEvent;
}

namespace openarc {

// OpenArc's part of the browser process's start-up, added after Chrome's own parts.
using ExtraPartsFactory = std::unique_ptr<ChromeBrowserMainExtraParts> (*)();
inline ExtraPartsFactory g_extra_parts_factory = nullptr;

// OpenArc made NSApp, its delegate and its main menu before ChromeMain: Chrome's AppController and main menu are
// never made (chrome_browser_main_mac.mm, app_controller_mac.mm).
inline bool g_embedder_owns_app = false;

// A key press in one of OpenArc's pages, before the page (`unhandled` false) or after the page left it alone
// (true). 1: OpenArc used it, 0: it didn't, -1: not OpenArc's page, so Chrome's own handling runs
// (chrome/browser/ui/browser_web_contents_delegate).
using KeyEventHook = int (*)(content::WebContents* contents,
                             const input::NativeWebKeyboardEvent& event,
                             bool unhandled);
inline KeyEventHook g_key_event = nullptr;

// Element fullscreen (the Fullscreen API) for one of OpenArc's pages: OpenArc's window shows it, and Chrome's
// (never shown) window stays as it is. True when the page is OpenArc's.
using PageFullscreenHook = bool (*)(content::WebContents* contents, bool enter);
inline PageFullscreenHook g_page_fullscreen = nullptr;
// 1 or 0 while the page is OpenArc's and in or out of fullscreen, -1 for Chrome's own pages.
using PageIsFullscreenHook = int (*)(const content::WebContents* contents);
inline PageIsFullscreenHook g_page_is_fullscreen = nullptr;

// The link under the pointer in one of OpenArc's pages, empty when none. True when the page is OpenArc's.
using TargetURLHook = bool (*)(content::WebContents* contents, const GURL& url);
inline TargetURLHook g_target_url = nullptr;

// The loader of navigations to a scheme of OpenArc's own (openarc://), null for any other scheme
// (chrome/browser/chrome_content_browser_client.cc).
using SchemeLoaderFactoryHook = mojo::PendingRemote<network::mojom::URLLoaderFactory> (*)(const std::string& scheme);
inline SchemeLoaderFactoryHook g_scheme_loader_factory = nullptr;

// OpenArc's throttles for a navigation, after Chrome's own (chrome/browser/chrome_content_browser_client.cc).
using NavigationThrottlesHook = void (*)(content::NavigationThrottleRegistry& registry);
inline NavigationThrottlesHook g_navigation_throttles = nullptr;

}  // namespace openarc

#endif  // CHROME_BROWSER_OPENARC_ENGINE_HOOKS_H_
