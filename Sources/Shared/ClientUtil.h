#ifndef THEBROWSER_SHARED_CLIENT_UTIL_H_
#define THEBROWSER_SHARED_CLIENT_UTIL_H_

#include <string>

#include "include/cef_client.h"

namespace shared {

void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title);
void OnAfterCreated(CefRefPtr<CefBrowser> browser);
bool DoClose(CefRefPtr<CefBrowser> browser);
void OnBeforeClose(CefRefPtr<CefBrowser> browser);

void PlatformTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title);

bool IsViewsEnabled();
bool IsAlloyStyleEnabled();

}  // namespace shared

#endif  // THEBROWSER_SHARED_CLIENT_UTIL_H_

