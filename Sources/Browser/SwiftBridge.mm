#import "Browser/SwiftBridge.h"

#import "TheBrowser-Swift.h"

#include "Shared/ClientManager.h"

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

void BrowserCloseAllBrowsers(void) {
  shared::ClientManager::GetInstance()->CloseAllBrowsers(false);
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

void BrowserRequestNotificationPermission(NSString* origin,
                                          BrowserPermissionCompletion completion) {
  [BrowserPermissionController requestNotificationPermissionFor:origin
                                                    completion:completion];
}
