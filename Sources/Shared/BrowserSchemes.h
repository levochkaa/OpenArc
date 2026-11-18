#ifndef OPENARC_SHARED_BROWSER_SCHEMES_H_
#define OPENARC_SHARED_BROWSER_SCHEMES_H_

#include "include/cef_app.h"

namespace shared {

extern const char kOpenArcScheme[];
extern const char kOpenArcCreditsHost[];
extern const char kOpenArcEaselHost[];
extern const char kOpenArcCreditsURL[];
extern const char kOpenArcNotesHost[];
extern const char kOpenArcSettingsHost[];
extern const char kOpenArcSettingsURL[];
extern const char kOpenArcExtensionsHost[];
extern const char kOpenArcExtensionsURL[];
extern const char kOpenArcHistoryHost[];
extern const char kOpenArcHistoryURL[];
extern const char kOpenArcPasswordManagerHost[];
extern const char kOpenArcPasswordManagerURL[];
extern const char kOpenArcBookmarksHost[];
extern const char kOpenArcBookmarksURL[];
extern const char kChromiumSettingsURL[];
extern const char kChromiumExtensionsURL[];
extern const char kChromiumHistoryURL[];
extern const char kChromiumPasswordManagerURL[];
extern const char kChromiumBookmarksURL[];

void RegisterOpenArcCustomSchemes(
    CefRawPtr<CefSchemeRegistrar> registrar);

}  // namespace shared

#endif  // OPENARC_SHARED_BROWSER_SCHEMES_H_
