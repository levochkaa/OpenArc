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

#import "Browser/BrowserSchemeHandlers.h"
#import "Browser/ChromeEngine/BrowserChromeEngine.h"
#import "Browser/SwiftBridge.h"
#import "OpenArc-Swift.h"

namespace {

bool gUsesChromeEngine = false;

/// The Chrome engine's openarc:// pages (setSchemePageProvider:): a shared page's Add to OpenArc button goes to
/// the app and stops the navigation, as CEF's tabs hand it over before loading; other addresses get the HTML CEF's
/// scheme handler serves.
NSString* SchemePage(NSString* urlString, NSInteger* statusCode) {
  NSString* host = [NSURLComponents componentsWithString:urlString].host.lowercaseString ?: @"";
  if ([host isEqualToString:@"share"]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSNotificationCenter.defaultCenter postNotificationName:BrowserShareLinkEvents.open
                                                        object:nil
                                                      userInfo:@{BrowserShareLinkEvents.urlKey : urlString}];
    });
    return nil;
  }
  int status_code = 200;
  const std::string html = browser::OpenArcSchemePageHTML(host.UTF8String, &status_code);
  *statusCode = status_code;
  return [NSString stringWithUTF8String:html.c_str()];
}

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
  return [BrowserEngineChoice currentLaunchEngine] == BrowserEngineChrome ? 1 : 0;
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
  // An engine built before setSchemePageProvider: shows no openarc:// pages of the app's own.
  Class<BrowserChromeEngine> engine = BrowserChromeEngineClass();
  if ([(Class)engine respondsToSelector:@selector(setSchemePageProvider:)]) {
    [engine setSchemePageProvider:^NSString*(NSString* urlString, NSInteger* statusCode) {
      return SchemePage(urlString, statusCode);
    }];
  }

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
    // -stop: ends the loop after the next event; outside one, this event is it.
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                        location:NSZeroPoint
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                         subtype:0
                                           data1:0
                                           data2:0]
             atStart:NO];
    return;
  }
  // The app's windows and pages are put away by now; Chrome closes its own and quits in order.
  BrowserPrepareApplicationForCefShutdown();
  [BrowserChromeEngineClass() quit];
}
