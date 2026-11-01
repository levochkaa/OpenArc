#import "Browser/SwiftBridge.h"

#import <AuthenticationServices/AuthenticationServices.h>

#import <Sparkle/Sparkle.h>

#import "OpenArc-Swift.h"

#include "Shared/ClientManager.h"
#include "include/cef_version.h"

namespace {

BrowserApplicationController* gController = nil;
BOOL gHasPendingContextInitialization = NO;

}  // namespace

void BrowserCreateApplication(void) {
  gController = [[BrowserApplicationController alloc] init];
  [(NSObject*)gController performSelectorOnMainThread:@selector(createApplication)
                                           withObject:nil
                                        waitUntilDone:NO];

  if (gHasPendingContextInitialization) {
    [(NSObject*)gController
        performSelectorOnMainThread:@selector(handleBrowserContextInitialized)
                         withObject:nil
                      waitUntilDone:NO];
  }
}

void BrowserContextInitialized(void) {
  gHasPendingContextInitialization = YES;

  if (gController == nil) {
    return;
  }

  [(NSObject*)gController
      performSelectorOnMainThread:@selector(handleBrowserContextInitialized)
                       withObject:nil
                    waitUntilDone:NO];
}

int BrowserHasOpenBrowsers(void) {
  return shared::ClientManager::GetInstance()->HasBrowsers() ? 1 : 0;
}

/// Chromium's own sign-in window closes on a later turn of the run loop, and crashes the app if
/// its page has gone by then. Escape cancels it while the page is alive. Nonzero if there was one.
int BrowserCancelChromiumSignInWindows(void) {
  int cancelled = 0;
  for (NSWindow *window in NSApp.windows) {
    if (![NSStringFromClass(window.class) isEqualToString:@"NativeWidgetMacNSWindow"]) continue;
    for (NSEventType type : {NSEventTypeKeyDown, NSEventTypeKeyUp}) {
      [window sendEvent:[NSEvent keyEventWithType:type
                                         location:NSZeroPoint
                                    modifierFlags:0
                                        timestamp:NSProcessInfo.processInfo.systemUptime
                                     windowNumber:window.windowNumber
                                          context:nil
                                       characters:@"\x1b"
                      charactersIgnoringModifiers:@"\x1b"
                                        isARepeat:NO
                                          keyCode:53]];
    }
    cancelled = 1;
  }
  return cancelled;
}

void BrowserCloseAllBrowsers(void) {
  if (!BrowserCancelChromiumSignInWindows()) {
    shared::ClientManager::GetInstance()->CloseAllBrowsers(false);
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    shared::ClientManager::GetInstance()->CloseAllBrowsers(false);
  });
}

void BrowserPrepareApplicationForCefShutdown(void) {
  if (gController == nil) {
    return;
  }

  [gController prepareForCefShutdown];
  gController = nil;
}

BOOL BrowserLoadRuntimeConfiguration(NSString** helper_path,
                                     NSString** framework_path,
                                     NSString** main_bundle_path,
                                     NSString** root_cache_path,
                                     NSString** cache_path) {
  BrowserRuntimeConfiguration* configuration =
      [BrowserRuntimeConfiguration currentConfiguration];
  if (!configuration) {
    return NO;
  }

  if (helper_path) {
    *helper_path = configuration.helperExecutablePath;
  }
  if (framework_path) {
    *framework_path = configuration.frameworkPath;
  }
  if (main_bundle_path) {
    *main_bundle_path = configuration.mainBundlePath;
  }
  if (root_cache_path) {
    *root_cache_path = configuration.rootCachePath;
  }
  if (cache_path) {
    *cache_path = configuration.cachePath;
  }

  return YES;
}

NSString* BrowserChromiumVersionString(void) {
  return [NSString
      stringWithFormat:@"%d.%d.%d.%d", CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR,
                       CHROME_VERSION_BUILD, CHROME_VERSION_PATCH];
}

void BrowserRequestNotificationPermission(NSString* origin,
                                          BrowserPermissionCompletion completion) {
  [BrowserPermissionController requestNotificationPermissionFor:origin
                                                    completion:completion];
}
