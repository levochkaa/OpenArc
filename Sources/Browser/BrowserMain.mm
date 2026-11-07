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
  [super terminate:sender];
}
@end

namespace shared {

/// Chromium adds an extension to every profile once its manifest is in this folder, and
/// remembers when the user removes it.
static void BrowserWriteDefaultExtensionManifests(NSString* cache_root) {
  NSString* folder = [cache_root stringByAppendingPathComponent:@"External Extensions"];
  [NSFileManager.defaultManager createDirectoryAtPath:folder
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  NSString* manifest =
      [folder stringByAppendingPathComponent:@"ddkjiahejlhfcafbddmgiahcphecmpfh.json"];
  [@"{\"external_update_url\":\"https://clients2.google.com/service/update2/crx\"}\n"
      writeToFile:manifest
       atomically:YES
         encoding:NSUTF8StringEncoding
            error:nil];
}

/// Chromium calls an unnamed profile "Your Chromium" in its settings and menus. Naming
/// the default profile before Chromium reads Local State shows the app's name there; a name
/// the user chose stays.
static void BrowserNameDefaultProfile(NSString* cache_root) {
  NSString* path = [cache_root stringByAppendingPathComponent:@"Local State"];
  NSData* data = [NSData dataWithContentsOfFile:path];
  NSMutableDictionary* state = [NSMutableDictionary dictionary];
  if (data) {
    id parsed = [NSJSONSerialization JSONObjectWithData:data
                                                options:NSJSONReadingMutableContainers
                                                  error:nil];
    if (![parsed isKindOfClass:NSMutableDictionary.class]) {
      return;
    }
    state = parsed;
  }
  NSMutableDictionary* profile = state[@"profile"];
  if (![profile isKindOfClass:NSMutableDictionary.class]) {
    profile = [NSMutableDictionary dictionary];
    state[@"profile"] = profile;
  }
  NSMutableDictionary* info_cache = profile[@"info_cache"];
  if (![info_cache isKindOfClass:NSMutableDictionary.class]) {
    info_cache = [NSMutableDictionary dictionary];
    profile[@"info_cache"] = info_cache;
  }
  NSMutableDictionary* entry = info_cache[@"Default"];
  if (![entry isKindOfClass:NSMutableDictionary.class]) {
    entry = [NSMutableDictionary dictionary];
    info_cache[@"Default"] = entry;
  }
  if ([entry[@"is_using_default_name"] isEqual:@NO]) {
    return;
  }
  entry[@"name"] = @"Your OpenArc";
  entry[@"is_using_default_name"] = @NO;
  NSData* output = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
  [output writeToFile:path atomically:YES];
}

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

    BrowserWriteDefaultExtensionManifests(cache_root);
    BrowserNameDefaultProfile(cache_root);

    if (!CefInitialize(main_args, settings, app, nullptr)) {
      return 1;
    }

    BrowserCreateApplication();

    CefRunMessageLoop();
    BrowserPrepareApplicationForCefShutdown();
    CefShutdown();
  }

  return 0;
}

}  // namespace shared

int main(int argc, char* argv[]) {
  return shared::main(argc, argv);
}
