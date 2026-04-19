#include "Browser/BrowserClient.h"

#import "Browser/SwiftBridge.h"
#include "Shared/ClientUtil.h"

#include "include/base/cef_callback.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"

namespace browser {

namespace {

bool IsNotificationsOnlyRequest(uint32_t requested_permissions) {
  return requested_permissions == CEF_PERMISSION_TYPE_NOTIFICATIONS;
}

void ContinuePermissionRequest(
    CefRefPtr<CefPermissionPromptCallback> callback,
    cef_permission_request_result_t result) {
  callback->Continue(result);
}

void ContinuePermissionRequestOnUI(
    CefRefPtr<CefPermissionPromptCallback> callback,
    cef_permission_request_result_t result) {
  if (CefCurrentlyOn(TID_UI)) {
    callback->Continue(result);
    return;
  }

  CefPostTask(
      TID_UI,
      CefCreateClosureTask(
          base::BindOnce(&ContinuePermissionRequest, callback, result)));
}

}  // namespace

void BrowserClient::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                  const CefString& title) {
  shared::OnTitleChange(browser, title);
}

void BrowserClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  shared::OnAfterCreated(browser);
}

bool BrowserClient::DoClose(CefRefPtr<CefBrowser> browser) {
  return shared::DoClose(browser);
}

void BrowserClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  shared::OnBeforeClose(browser);
}

bool BrowserClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
  CEF_REQUIRE_UI_THREAD();

  if (!IsNotificationsOnlyRequest(requested_permissions)) {
    return false;
  }

  NSString* origin = [NSString stringWithUTF8String:
                                   requesting_origin.ToString().c_str()];
  BrowserRequestNotificationPermission(origin, ^(BOOL granted) {
    ContinuePermissionRequestOnUI(callback,
                                  granted ? CEF_PERMISSION_RESULT_ACCEPT
                                          : CEF_PERMISSION_RESULT_DENY);
  });
  return true;
}

}  // namespace browser
