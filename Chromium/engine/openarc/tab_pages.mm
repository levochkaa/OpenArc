// The chrome:// pages an OpenArc tab opens on Chrome's engine. Each page on the list was opened in a tab and works
// there. Left out: pages that hang or crash the app in a tab (bluetooth-internals waits on Bluetooth on the main
// thread; history-sync-optin and signout-confirmation hit a CHECK), Chrome's own panels and bubbles (*.top-chrome,
// actor-overlay, extensions-zero-state, newtab-footer), its dialogs (sign-in, sync, profiles, print, certificate
// viewer, feedback, default browser), Gemini's pages (glic, contextual-tasks, skills), and internal debugging pages,
// which Chrome keeps off. Add a page only after opening it in a tab on this engine.

#import "openarc/tab_pages.h"

#include <algorithm>
#include <memory>
#include <string_view>

#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_url_handler.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/webui_config.h"
#include "content/public/browser/webui_config_map.h"
#include "content/public/common/url_constants.h"
#include "url/gurl.h"

namespace openarc {

namespace {

constexpr std::string_view kTabPages[] = {
    "accessibility",
    "app-service-internals",
    "apps",
    "autofill-internals",
    "bookmarks",
    "certificate-manager",
    "chrome-urls",
    "components",
    "connection-help",
    "connection-monitoring-detected",
    "connectors-internals",
    "crashes",
    "credits",
    "device-log",
    "downloads",
    "extensions",
    "flags",
    "gcm-internals",
    "gpu",
    "histograms",
    "history",
    "indexeddb-internals",
    "inspect",
    "iwa-dev",
    "management",
    "media-engagement",
    "media-internals",
    "metrics-internals",
    "net-export",
    "net-internals",
    "new-tab-page",
    "ntp-tiles-internals",
    "on-device-translation-internals",
    "password-manager",
    "password-manager-internals",
    "policy",
    "predictors",
    "process-internals",
    "quota-internals",
    "segmentation-internals",
    "serviceworker-internals",
    "settings",
    "signin-internals",
    "site-engagement",
    "suggest-internals",
    "support-tool",
    "sync-internals",
    "system",
    "terms",
    "traces",
    "traces-internals",
    "translate-internals",
    "updater",
    "usb-internals",
    "version",
    "watermark",
    "web-app-internals",
    "webnn-internals",
    "webrtc-internals",
};

bool IsTabPage(const GURL& url) {
  return !url.SchemeIs(content::kChromeUIScheme) ||
         std::ranges::find(kTabPages, url.host()) != std::end(kTabPages);
}

class TabPageThrottle : public content::NavigationThrottle {
 public:
  using content::NavigationThrottle::NavigationThrottle;

  ThrottleCheckResult WillStartRequest() override { return Check(); }
  ThrottleCheckResult WillRedirectRequest() override { return Check(); }
  const char* GetNameForLogging() override { return "OpenArcTabPageThrottle"; }

 private:
  ThrottleCheckResult Check() { return IsTabPage(navigation_handle()->GetURL()) ? PROCEED : CANCEL; }
};

}  // namespace

bool OpensInTab(content::BrowserContext* context, const GURL& url) {
  if (!url.SchemeIs(content::kChromeUIScheme)) {
    return true;
  }
  GURL rewritten = url;
  content::BrowserURLHandler::GetInstance()->RewriteURLIfNecessary(&rewritten, context);
  if (!rewritten.SchemeIs(content::kChromeUIScheme)) {
    return true;
  }
  if (!IsTabPage(rewritten)) {
    return false;
  }
  content::WebUIConfig* config = content::WebUIConfigMap::GetInstance().GetConfig(context, rewritten);
  return config && config->IsWebUIEnabled(context);
}

std::unique_ptr<content::NavigationThrottle> CreateTabPageThrottle(content::NavigationThrottleRegistry& registry) {
  return std::make_unique<TabPageThrottle>(registry);
}

}  // namespace openarc
