#ifndef THEBROWSER_SHARED_APP_FACTORY_H_
#define THEBROWSER_SHARED_APP_FACTORY_H_

#include "include/cef_app.h"

namespace shared {

CefRefPtr<CefApp> CreateBrowserProcessApp();
CefRefPtr<CefApp> CreateRendererProcessApp();
CefRefPtr<CefApp> CreateOtherProcessApp();

}  // namespace shared

#endif  // THEBROWSER_SHARED_APP_FACTORY_H_

