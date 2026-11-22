#import "Browser/SwiftBridge.h"

#import <AuthenticationServices/AuthenticationServices.h>

#import <Sparkle/Sparkle.h>

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <WebKit/WebKit.h>

#import "OpenArc-Swift.h"

#include "Shared/ClientManager.h"
#include "include/cef_trace.h"
#include "include/cef_version.h"

namespace {

BrowserApplicationController* gController = nil;
BOOL gHasPendingContextInitialization = NO;

}  // namespace

void BrowserStartLaunchWarmup(void) {
  [BrowserLaunchWarmup start];
}

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
  // Chrome engine pages are not CEF browsers; Chrome closes them as it quits.
  if (!BrowserUsesCEF()) {
    return 0;
  }
  return shared::ClientManager::GetInstance()->HasBrowsers() ? 1 : 0;
}

namespace {

class BrowserTraceEnd final : public CefEndTracingCallback {
 public:
  explicit BrowserTraceEnd(void (^completion)(void)) : completion_(completion) {}
  void OnEndTracingComplete(const CefString&) override {
    void (^completion)(void) = completion_;
    dispatch_async(dispatch_get_main_queue(), ^{
      completion();
    });
  }

 private:
  void (^completion_)(void);
  IMPLEMENT_REFCOUNTING(BrowserTraceEnd);
};

}  // namespace

int BrowserBeginTrace(void) {
  if (!BrowserUsesCEF()) {
    return 0;
  }
  return CefBeginTracing("toplevel,benchmark,blink,cc,gpu,renderer.scheduler,v8,viz,disabled-by-default-devtools.timeline",
                         nullptr)
             ? 1
             : 0;
}

int BrowserEndTrace(const char* path, void (^completion)(void)) {
  if (!BrowserUsesCEF()) {
    return 0;
  }
  return CefEndTracing(path, new BrowserTraceEnd([completion copy])) ? 1 : 0;
}

void BrowserCloseAllBrowsers(void) {
  if (!BrowserUsesCEF()) {
    return;
  }
  shared::ClientManager::GetInstance()->CloseAllBrowsers(false);
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
