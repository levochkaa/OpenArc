#include "Shared/AppFactory.h"
#include "Shared/ClientManager.h"
#include "Shared/Main.h"

#import "Browser/SwiftBridge.h"
#import <Cocoa/Cocoa.h>

#include "include/cef_application_mac.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

@interface BrowserApplication : NSApplication <CefAppProtocol> {
 @private
  BOOL handlingSendEvent_;
}
@end

@implementation BrowserApplication
- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  handlingSendEvent_ = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sending_event_scoper;
  [super sendEvent:event];
}

- (void)terminate:(id)sender {
  shared::ClientManager* manager = shared::ClientManager::GetInstance();
  if (!manager) {
    [super terminate:sender];
    return;
  }

  if (manager->IsClosing()) {
    return;
  }

  if (manager->HasBrowsers()) {
    manager->CloseAllBrowsers(false);
    return;
  }

  CefQuitMessageLoop();
}
@end

namespace shared {

int main(int argc, char* argv[]) {
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInMain()) {
    return 1;
  }

  @autoreleasepool {
    CefMainArgs main_args(argc, argv);
    CefRefPtr<CefApp> app = CreateBrowserProcessApp();

    [BrowserApplication sharedApplication];

    ClientManager manager;
    CefSettings settings;
    settings.no_sandbox = true;
    settings.log_severity = LOGSEVERITY_INFO;

    NSString* helper_path = nil;
    NSString* framework_path = nil;
    NSString* bundle_path = nil;
    NSString* cache_root = nil;
    NSString* cache_path = nil;
    if (!BrowserLoadRuntimeConfiguration(&helper_path, &framework_path,
                                         &bundle_path, &cache_root,
                                         &cache_path)) {
      return 1;
    }

    CefString(&settings.browser_subprocess_path) =
        std::string(helper_path.UTF8String);
    CefString(&settings.framework_dir_path) =
        std::string(framework_path.UTF8String);
    CefString(&settings.main_bundle_path) =
        std::string(bundle_path.UTF8String);
    CefString(&settings.root_cache_path) =
        std::string(cache_root.UTF8String);
    CefString(&settings.cache_path) =
        std::string(cache_path.UTF8String);

    if (!CefInitialize(main_args, settings, app, nullptr)) {
      return 1;
    }

    BrowserCreateApplication();

    CefRunMessageLoop();
    CefShutdown();
  }

  return 0;
}

}  // namespace shared

int main(int argc, char* argv[]) {
  return shared::main(argc, argv);
}
