#include "Shared/AppFactory.h"
#include "Shared/BrowserSchemes.h"

namespace shared {

namespace {

class RendererProcessApp : public CefApp {
 public:
  void OnRegisterCustomSchemes(
      CefRawPtr<CefSchemeRegistrar> registrar) override {
    RegisterTheBrowserCustomSchemes(registrar);
  }

 private:
  IMPLEMENT_REFCOUNTING(RendererProcessApp);
};

}  // namespace

CefRefPtr<CefApp> CreateRendererProcessApp() {
  return new RendererProcessApp();
}

}  // namespace shared
