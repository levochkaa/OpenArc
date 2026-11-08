#include "Browser/SwiftBridge.h"
#include "Browser/BrowserSchemeHandlers.h"
#include "Shared/AppFactory.h"
#include "Shared/BrowserSchemes.h"

#include <string>

namespace browser {

namespace {

constexpr char kDisableBackgroundingOccludedWindowsSwitch[] =
    "disable-backgrounding-occluded-windows";
constexpr char kDisableChromeLoginPromptSwitch[] = "disable-chrome-login-prompt";
constexpr char kDisableFeaturesSwitch[] = "disable-features";
constexpr char kImmersiveReadAnythingFeature[] = "ImmersiveReadAnything";
constexpr char kJourneysFeature[] = "Journeys";
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

void AppendCommaSeparatedSwitchValue(CefRefPtr<CefCommandLine> command_line,
                                     const char* switch_name,
                                     const std::string& feature) {
  if (!command_line) {
    return;
  }

  std::string switch_value = command_line->GetSwitchValue(switch_name);
  if (FeatureListContains(switch_value, feature)) {
    return;
  }

  if (!switch_value.empty()) {
    switch_value += ",";
  }
  switch_value += feature;
  command_line->AppendSwitchWithValue(switch_name, switch_value);
}

void DisableChromiumFeature(CefRefPtr<CefCommandLine> command_line,
                            const std::string& feature) {
  AppendCommaSeparatedSwitchValue(command_line, kDisableFeaturesSwitch,
                                  feature);
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

    // History lists visits by date only; its "By group" tab needs Chrome's
    // history clustering, which CEF pages do not feed.
    DisableChromiumFeature(command_line, kJourneysFeature);

    // Keep visible CEF WebContents composited when macOS reports the app window
    // as occluded. Chromium otherwise evicts the surface and Mission Control can
    // reveal a blank layer before the active tab paints again.
    command_line->AppendSwitch(kDisableBackgroundingOccludedWindowsSwitch);

    // Sites' password requests reach GetAuthCredentials, for OpenArc's own sheet.
    // Chromium's window closes a turn after its page and can crash the app then.
    command_line->AppendSwitch(kDisableChromeLoginPromptSwitch);

    // Passkeys: phones and USB keys work as they are. Chromium itself leaves out
    // iCloud Keychain and Touch ID without Apple's entitlements. Bluetooth for
    // phones needs NSBluetoothAlwaysUsageDescription, or macOS kills the app.
  }

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnRegisterCustomSchemes(
      CefRawPtr<CefSchemeRegistrar> registrar) override {
    shared::RegisterOpenArcCustomSchemes(registrar);
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
