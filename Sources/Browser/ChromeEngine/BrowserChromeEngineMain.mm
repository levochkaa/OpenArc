#import "Browser/ChromeEngine/BrowserChromeEngineMain.h"

#import <AppKit/AppKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Sparkle/Sparkle.h>
#import <WebKit/WebKit.h>

#include <dlfcn.h>

#include <string>
#include <vector>

#import "Browser/ChromeEngine/BrowserChromeEngine.h"
#import "Browser/SwiftBridge.h"
#import "OpenArc-Swift.h"

namespace {

bool gUsesChromeEngine = false;

}  // namespace

int BrowserUsesChromeEngine(void) {
  return gUsesChromeEngine ? 1 : 0;
}

Class<BrowserChromeEngine> BrowserChromeEngineClass(void) {
  if (!gUsesChromeEngine) {
    return nil;
  }
  return (Class<BrowserChromeEngine>)NSClassFromString(@"OpenArcChromeEngine");
}

int BrowserShouldRunChromeEngine(void) {
  return [BrowserEngineChoice currentLaunchEngine] == BrowserChromiumEngineChrome ? 1 : 0;
}

int BrowserRunChromeEngine(int argc, char* argv[], NSString* cache_root) {
  NSString* binary = [BrowserEngineChoice frameworkBinaryPathWithBundlePath:NSBundle.mainBundle.bundlePath
                                                                fileManager:NSFileManager.defaultManager];
  if (binary.length == 0) {
    return 1;
  }
  // Loaded for the whole process: Chrome's framework never unloads.
  void* handle = dlopen(binary.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
  if (!handle) {
    NSLog(@"OpenArc: the Chrome engine did not load: %s", dlerror());
    return 1;
  }
  auto engine_main = reinterpret_cast<BrowserChromeEngineMainFunction>(
      dlsym(handle, BrowserEngineChoice.entryPointName.UTF8String));
  if (!engine_main) {
    NSLog(@"OpenArc: the Chrome engine has no entry point");
    return 1;
  }
  gUsesChromeEngine = true;

  NSArray<NSString*>* arguments = [BrowserEngineChoice chromeArgumentsForUserDataPath:cache_root];
  // Chromium keeps argv for the whole process; never freed.
  auto* storage = new std::vector<std::string>();
  for (NSString* argument in arguments) {
    storage->push_back(argument.UTF8String);
  }
  auto* pointers = new std::vector<const char*>();
  for (const std::string& argument : *storage) {
    pointers->push_back(argument.c_str());
  }
  pointers->push_back(nullptr);
  (void)argc;
  (void)argv;
  return engine_main(static_cast<int>(storage->size()), pointers->data(), ^{
    BrowserCreateApplication();
    BrowserContextInitialized();
  });
}

void BrowserStopApplicationLoop(void) {
  if (!gUsesChromeEngine) {
    [NSApp stop:nil];
    return;
  }
  // The app's windows and pages are put away by now; Chrome closes its own and quits in order.
  BrowserPrepareApplicationForCefShutdown();
  [BrowserChromeEngineClass() quit];
}
