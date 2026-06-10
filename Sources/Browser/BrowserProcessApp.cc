#include "Browser/SwiftBridge.h"
#include "Browser/BrowserSchemeHandlers.h"
#include "Shared/AppFactory.h"
#include "Shared/BrowserSchemes.h"

#include <string>

namespace browser {

namespace {

constexpr char kDisableFeaturesSwitch[] = "disable-features";
constexpr char kImmersiveReadAnythingFeature[] = "ImmersiveReadAnything";
constexpr char kWebAuthenticationFeature[] = "WebAuthentication";
constexpr char kWebAuthenticationCableFeature[] = "WebAuthenticationCable";
constexpr char kWebAuthenticationConditionalUIFeature[] =
    "WebAuthenticationConditionalUI";

bool FeatureListContains(const std::string& features,
                         const std::string& feature) {
  size_t start = 0;
  while (start <= features.size()) {
    const size_t end = features.find(',', start);
    const std::string token = features.substr(
        start, end == std::string::npos ? std::string::npos : end - start);
    if (token == feature) {
      return true;
    }
    if (end == std::string::npos) {
      return false;
    }
    start = end + 1;
  }
  return false;
}

void DisableChromiumFeature(CefRefPtr<CefCommandLine> command_line,
                            const std::string& feature) {
  if (!command_line) {
    return;
  }

  std::string disabled_features =
      command_line->GetSwitchValue(kDisableFeaturesSwitch);
  if (FeatureListContains(disabled_features, feature)) {
    return;
  }

  if (!disabled_features.empty()) {
    disabled_features += ",";
  }
  disabled_features += feature;
  command_line->AppendSwitchWithValue(kDisableFeaturesSwitch,
                                      disabled_features);
}

class BrowserProcessApp : public CefApp, public CefBrowserProcessHandler {
 public:
  void OnBeforeCommandLineProcessing(
      const CefString&,
      CefRefPtr<CefCommandLine> command_line) override {
    // CEF WebContents instances are not always backed by Chrome's TabInterface.
    // Immersive Read Anything currently assumes they are during soft navigation
    // metrics, which crashes CEF-hosted pages before its null check can run.
    DisableChromiumFeature(command_line, kImmersiveReadAnythingFeature);

    // Temporarily keep passkeys/WebAuthn out of the browser process until the
    // app ships with the required Apple browser entitlement in its provisioning.
    DisableChromiumFeature(command_line, kWebAuthenticationFeature);
    DisableChromiumFeature(command_line, kWebAuthenticationCableFeature);
    DisableChromiumFeature(command_line, kWebAuthenticationConditionalUIFeature);
  }

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnRegisterCustomSchemes(
      CefRawPtr<CefSchemeRegistrar> registrar) override {
    shared::RegisterTheBrowserCustomSchemes(registrar);
  }

  void OnContextInitialized() override {
    RegisterBrowserSchemeHandlers();
    ::BrowserContextInitialized();
  }

 private:
  IMPLEMENT_REFCOUNTING(BrowserProcessApp);
};

}  // namespace

}  // namespace browser

namespace shared {

CefRefPtr<CefApp> CreateBrowserProcessApp() {
  return new browser::BrowserProcessApp();
}

}  // namespace shared
