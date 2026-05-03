#ifndef THEBROWSER_SHARED_BROWSER_SCHEMES_H_
#define THEBROWSER_SHARED_BROWSER_SCHEMES_H_

#include "include/cef_app.h"

namespace shared {

extern const char kTheBrowserScheme[];
extern const char kTheBrowserCreditsHost[];
extern const char kTheBrowserCreditsURL[];
extern const char kTheBrowserSettingsHost[];
extern const char kTheBrowserSettingsURL[];
extern const char kTheBrowserExtensionsHost[];
extern const char kTheBrowserExtensionsURL[];
extern const char kChromiumSettingsURL[];
extern const char kChromiumExtensionsURL[];

void RegisterTheBrowserCustomSchemes(
    CefRawPtr<CefSchemeRegistrar> registrar);

}  // namespace shared

#endif  // THEBROWSER_SHARED_BROWSER_SCHEMES_H_
