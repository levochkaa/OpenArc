#include "Browser/SwiftBridge.h"
#include "Browser/BrowserSchemeHandlers.h"
#include "Shared/AppFactory.h"
#include "Shared/BrowserSchemes.h"

#include <string>

namespace browser {

namespace {

constexpr bool kEnablePasskeysAndWebAuthentication = false;

constexpr char kDisableBlinkFeaturesSwitch[] = "disable-blink-features";
constexpr char kDisableFeaturesSwitch[] = "disable-features";
constexpr char kImmersiveReadAnythingFeature[] = "ImmersiveReadAnything";
constexpr const char* kPasskeyAndWebAuthenticationChromiumFeatures[] = {
    "AuthenticatorPasswordsOnlyImmediateRequests",
    "AutofillReintroduceHybridPasskeyDropdownItem",
    "DelaysSuggestionsOnAutofocusWaitingForPasskeys",
    "PasskeyUnlockManager",
    "WebAuthentication",
    "WebAuthenticationAmbientSignin",
    "WebAuthenticationCable",
    "WebAuthenticationCableExtensionAnywhere",
    "WebAuthenticationConditionalUI",
    "WebAuthenticationICloudKeychainForActiveWithDrive",
    "WebAuthenticationICloudKeychainForActiveWithoutDrive",
    "WebAuthenticationICloudKeychainForGoogle",
    "WebAuthenticationICloudKeychainForInactiveWithDrive",
    "WebAuthenticationICloudKeychainForInactiveWithoutDrive",
    "WebAuthenticationImmediateGet",
    "WebAuthenticationNewRefreshFlow",
    "WebAuthenticationSignalApiHidePasskeys",
    "WebAuthenticationUseInsecureSoftwareUnexportableKeys",
    "WebAuthnDoNotAlwaysTerminateStateMachineDuringIdentityChange",
    "WebAuthnEnableRefreshingStateOfGpmEnclaveController",
    "WebAuthnHmacSecretMcExtension",
    "WebAuthnImmediateRequestRateLimit",
    "WebAuthnUsePasskeyFromAnotherDeviceInContextMenu",
};
constexpr const char* kPasskeyAndWebAuthenticationBlinkFeatures[] = {
    "WebAuth",
    "WebAuthAuthenticatorAttachment",
    "WebAuthenticationAmbient",
    "WebAuthenticationAttestationFormats",
    "WebAuthenticationChallengeUrl",
    "WebAuthenticationImmediateGet",
    "WebAuthenticationRemoteDesktopSupport",
    "WebAuthenticationSupplementalPubKeys",
};

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

template <size_t feature_count>
void AppendCommaSeparatedSwitchValues(
    CefRefPtr<CefCommandLine> command_line,
    const char* switch_name,
    const char* const (&features)[feature_count]) {
  for (const char* feature : features) {
    AppendCommaSeparatedSwitchValue(command_line, switch_name, feature);
  }
}

void DisablePasskeysAndWebAuthentication(
    CefRefPtr<CefCommandLine> command_line) {
  AppendCommaSeparatedSwitchValues(
      command_line, kDisableFeaturesSwitch,
      kPasskeyAndWebAuthenticationChromiumFeatures);
  AppendCommaSeparatedSwitchValues(
      command_line, kDisableBlinkFeaturesSwitch,
      kPasskeyAndWebAuthenticationBlinkFeatures);
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

    if (!kEnablePasskeysAndWebAuthentication) {
      // Temporarily keep passkeys/WebAuthn out of the browser process until the
      // app ships with the required Apple browser entitlement in its
      // provisioning and can safely present related privacy prompts.
      DisablePasskeysAndWebAuthentication(command_line);
    }
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
