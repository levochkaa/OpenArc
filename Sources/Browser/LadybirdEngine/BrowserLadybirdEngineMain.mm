#import "Browser/LadybirdEngine/BrowserLadybirdEngineMain.h"

#import <AppKit/AppKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Sparkle/Sparkle.h>
#import <WebKit/WebKit.h>

#include <dlfcn.h>

#include <string>
#include <vector>

#import "Browser/LadybirdEngine/BrowserLadybirdEngine.h"
#import "Browser/SwiftBridge.h"
#import "OpenArc-Swift.h"

namespace {

bool gUsesLadybirdEngine = false;

/// Ladybird's openarc:// pages (setSchemePageProvider:): a shared page's Add to OpenArc button goes to the app and
/// stops the navigation; other addresses get the pages WebKit gets when the app runs on it alone.
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
  return [BrowserWebKitInternalPages ladybirdPageHTMLForURLString:urlString statusCode:statusCode];
}

}  // namespace

int BrowserUsesLadybirdEngine(void) {
  return gUsesLadybirdEngine ? 1 : 0;
}

Class<BrowserLadybirdEngine> BrowserLadybirdEngineClass(void) {
  if (!gUsesLadybirdEngine) {
    return nil;
  }
  return (Class<BrowserLadybirdEngine>)NSClassFromString(@"OpenArcLadybirdEngine");
}

NSString* BrowserLadybirdVersionString(void) {
  return [BrowserLadybirdEngineClass() ladybirdVersion];
}

NSInteger BrowserLadybirdImportCookies(NSArray<NSDictionary<NSString*, id>*>* cookies) {
  return [BrowserLadybirdEngineClass() importCookies:cookies];
}

int BrowserShouldRunLadybirdEngine(void) {
  return [BrowserEngineChoice currentLaunchEngine] == BrowserEngineLadybird ? 1 : 0;
}

int BrowserRunLadybirdEngine(int argc, char* argv[], NSString* cache_root) {
  NSString* binary = [BrowserEngineChoice ladybirdFrameworkBinaryPathWithBundlePath:NSBundle.mainBundle.bundlePath
                                                                        fileManager:NSFileManager.defaultManager];
  if (binary.length == 0) {
    return 1;
  }
  // Loaded for the whole process: Ladybird's libraries never unload.
  void* handle = dlopen(binary.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
  if (!handle) {
    NSLog(@"OpenArc: the Ladybird engine did not load: %s", dlerror());
    return 1;
  }
  auto engine_main = reinterpret_cast<BrowserLadybirdEngineMainFunction>(
      dlsym(handle, BrowserEngineChoice.ladybirdEntryPointName.UTF8String));
  if (!engine_main) {
    NSLog(@"OpenArc: the Ladybird engine has no entry point");
    return 1;
  }
  gUsesLadybirdEngine = true;
  [BrowserLadybirdEngineClass() setSchemePageProvider:^NSString*(NSString* urlString, NSInteger* statusCode) {
    return SchemePage(urlString, statusCode);
  }];

  NSString* data_path = [BrowserEngineChoice ladybirdDataPathForCacheRoot:cache_root];
  [NSFileManager.defaultManager createDirectoryAtPath:data_path withIntermediateDirectories:YES attributes:nil error:nil];
  // Ladybird parses its own switches; the app's (the engine choice, AppKit's -NS… defaults) stay out.
  std::vector<std::string> storage;
  storage.push_back(argc > 0 ? argv[0] : "OpenArc");
  for (int i = 1; i < argc; ++i) {
    const std::string argument = argv[i];
    if (argument.rfind("--ladybird-", 0) == 0) {
      storage.push_back("--" + argument.substr(strlen("--ladybird-")));
    }
  }
  // Ladybird keeps argv for the whole process; never freed.
  auto* pointers = new std::vector<const char*>();
  auto* kept = new std::vector<std::string>(std::move(storage));
  for (const std::string& argument : *kept) {
    pointers->push_back(argument.c_str());
  }
  pointers->push_back(nullptr);
  return engine_main(static_cast<int>(kept->size()), pointers->data(), data_path.fileSystemRepresentation, ^{
    BrowserCreateApplication();
    BrowserContextInitialized();
  });
}
