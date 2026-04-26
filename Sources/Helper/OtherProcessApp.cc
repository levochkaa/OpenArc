#include "Shared/AppFactory.h"
#include "Shared/BrowserSchemes.h"

namespace shared {

namespace {

class OtherProcessApp : public CefApp {
 public:
  void OnRegisterCustomSchemes(
      CefRawPtr<CefSchemeRegistrar> registrar) override {
    RegisterTheBrowserCustomSchemes(registrar);
  }

 private:
  IMPLEMENT_REFCOUNTING(OtherProcessApp);
};

}  // namespace

CefRefPtr<CefApp> CreateOtherProcessApp() {
  return new OtherProcessApp();
}

}  // namespace shared
