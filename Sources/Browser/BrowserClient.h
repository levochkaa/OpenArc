#ifndef THEBROWSER_BROWSER_CLIENT_H_
#define THEBROWSER_BROWSER_CLIENT_H_

#include "include/cef_client.h"
#include "include/cef_permission_handler.h"

namespace browser {

class BrowserClient : public CefClient,
                      public CefDisplayHandler,
                      public CefLifeSpanHandler,
                      public CefPermissionHandler {
 public:
  BrowserClient() = default;

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return this;
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser,
      uint64_t prompt_id,
      const CefString& requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override;

 private:
  IMPLEMENT_REFCOUNTING(BrowserClient);
};

}  // namespace browser

#endif  // THEBROWSER_BROWSER_CLIENT_H_
