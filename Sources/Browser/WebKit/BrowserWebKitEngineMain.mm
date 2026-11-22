#import "Browser/WebKit/BrowserWebKitEngineMain.h"

#import <AppKit/AppKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Sparkle/Sparkle.h>
#import <WebKit/WebKit.h>

#import "Browser/SwiftBridge.h"
#import "OpenArc-Swift.h"

namespace {

bool gUsesWebKitEngine = false;

}  // namespace

int BrowserUsesWebKitEngine(void) {
  return gUsesWebKitEngine ? 1 : 0;
}

int BrowserUsesCEF(void) {
  return !BrowserUsesChromeEngine() && !BrowserUsesWebKitEngine() ? 1 : 0;
}

int BrowserShouldRunWebKitEngine(void) {
  return [BrowserEngineChoice currentLaunchEngine] == BrowserEngineWebKit ? 1 : 0;
}

int BrowserRunWebKitEngine(int argc, char* argv[]) {
  (void)argc;
  (void)argv;
  gUsesWebKitEngine = true;
  @autoreleasepool {
    [NSApplication sharedApplication];
    // WebKit needs no engine start-up: the app is ready as soon as it exists.
    BrowserCreateApplication();
    BrowserContextInitialized();
    [NSApp run];
    BrowserPrepareApplicationForCefShutdown();
  }
  return 0;
}
