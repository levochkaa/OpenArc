#include "Browser/SwiftBridge.h"
#include "Shared/AppFactory.h"

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

  void OnContextInitialized() override {
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
