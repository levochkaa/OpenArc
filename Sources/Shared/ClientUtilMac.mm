#include "Shared/ClientUtil.h"

#import <Cocoa/Cocoa.h>

namespace shared {

void PlatformTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
  NSView* view =
      CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  NSWindow* window = [view window];
  std::string title_string(title);
  NSString* native_title = [NSString stringWithUTF8String:title_string.c_str()];
  [window setTitle:native_title];
}

}  // namespace shared

