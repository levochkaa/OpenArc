#ifndef OPENARC_SHARED_BROWSER_UTIL_H_
#define OPENARC_SHARED_BROWSER_UTIL_H_

#include "include/cef_client.h"

namespace shared {

void CreateBrowser(CefRefPtr<CefClient> client,
                   const CefString& startup_url,
                   const CefBrowserSettings& settings);

}  // namespace shared

#endif  // OPENARC_SHARED_BROWSER_UTIL_H_

