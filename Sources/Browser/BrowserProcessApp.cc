#include "Browser/SwiftBridge.h"
#include "Browser/BrowserSchemeHandlers.h"
#include "Shared/AppFactory.h"
#include "Shared/BrowserSchemes.h"

namespace browser {

namespace {

class BrowserProcessApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (process_type.empty()) {
      command_line->AppendSwitch("use-mock-keychain");
    }
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
