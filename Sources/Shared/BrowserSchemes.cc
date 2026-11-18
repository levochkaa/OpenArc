#include "Shared/BrowserSchemes.h"

#include "include/internal/cef_types.h"

namespace shared {

const char kOpenArcScheme[] = "openarc";
const char kOpenArcCreditsHost[] = "credits";
const char kOpenArcCreditsURL[] = "openarc://credits/";
const char kOpenArcEaselHost[] = "easel";
const char kOpenArcNotesHost[] = "notes";
const char kOpenArcSettingsHost[] = "settings";
const char kOpenArcSettingsURL[] = "openarc://settings/";
const char kOpenArcExtensionsHost[] = "extensions";
const char kOpenArcExtensionsURL[] = "openarc://extensions/";
const char kOpenArcHistoryHost[] = "history";
const char kOpenArcHistoryURL[] = "openarc://history";
const char kOpenArcPasswordManagerHost[] = "password-manager";
const char kOpenArcPasswordManagerURL[] = "openarc://password-manager/passwords";
const char kOpenArcBookmarksHost[] = "bookmarks";
const char kOpenArcBookmarksURL[] = "openarc://bookmarks/";
const char kChromiumSettingsURL[] = "chrome://settings/";
const char kChromiumExtensionsURL[] = "chrome://extensions/";
const char kChromiumHistoryURL[] = "chrome://history/";
const char kChromiumPasswordManagerURL[] = "chrome://password-manager/passwords";
const char kChromiumBookmarksURL[] = "chrome://bookmarks/";

void RegisterOpenArcCustomSchemes(
    CefRawPtr<CefSchemeRegistrar> registrar) {
  registrar->AddCustomScheme(
      kOpenArcScheme,
      CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
          CEF_SCHEME_OPTION_CORS_ENABLED | CEF_SCHEME_OPTION_FETCH_ENABLED);
}

}  // namespace shared
