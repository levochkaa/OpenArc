#include "Shared/BrowserSchemes.h"

#include "include/internal/cef_types.h"

namespace shared {

const char kTheBrowserScheme[] = "tb";
const char kTheBrowserCreditsHost[] = "credits";
const char kTheBrowserCreditsURL[] = "tb://credits/";
const char kTheBrowserSettingsHost[] = "settings";
const char kTheBrowserSettingsURL[] = "tb://settings/";
const char kTheBrowserExtensionsHost[] = "extensions";
const char kTheBrowserExtensionsURL[] = "tb://extensions/";
const char kTheBrowserPasswordManagerHost[] = "password-manager";
const char kTheBrowserPasswordManagerURL[] = "tb://password-manager/passwords";
const char kChromiumSettingsURL[] = "chrome://settings/";
const char kChromiumExtensionsURL[] = "chrome://extensions/";
const char kChromiumPasswordManagerURL[] = "chrome://password-manager/passwords";

void RegisterTheBrowserCustomSchemes(
    CefRawPtr<CefSchemeRegistrar> registrar) {
  registrar->AddCustomScheme(
      kTheBrowserScheme,
      CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
          CEF_SCHEME_OPTION_CORS_ENABLED | CEF_SCHEME_OPTION_FETCH_ENABLED);
}

}  // namespace shared
