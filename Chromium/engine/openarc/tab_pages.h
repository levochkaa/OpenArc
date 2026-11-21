// The chrome:// pages an OpenArc tab opens on Chrome's engine: those that work in a tab, as CEF opens only the
// pages on its own list.
#ifndef OPENARC_TAB_PAGES_H_
#define OPENARC_TAB_PAGES_H_

#include <memory>

class GURL;

namespace content {
class BrowserContext;
class NavigationThrottle;
class NavigationThrottleRegistry;
}  // namespace content

namespace openarc {

// Whether an OpenArc tab opens `url`: any address but a chrome:// one, and a chrome:// one (after Chrome's own
// rewrites, chrome://newtab or chrome://about) only when it is one of the pages that work in a tab.
bool OpensInTab(content::BrowserContext* context, const GURL& url);

// Cancels a navigation of an OpenArc tab to a chrome:// page it doesn't open, as CEF blocks one: the tab keeps its
// page. Covers links and scripts in a page, which never reach the tab controller.
std::unique_ptr<content::NavigationThrottle> CreateTabPageThrottle(content::NavigationThrottleRegistry& registry);

}  // namespace openarc

#endif  // OPENARC_TAB_PAGES_H_
