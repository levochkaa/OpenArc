// OpenArcChromeEngineMain: OpenArc's entry into Chrome's framework, and the engine's class methods
// (BrowserChromeEngine.h). Exported by chrome/app/framework.exports (patches/engine-hooks.patch).
// Based on Cra's engine entry (https://github.com/VictorKildahl/cra, MIT License).

#import "chrome/browser/chrome_browser_application_mac.h"

#include <memory>
#include <string>
#include <vector>

#include "base/command_line.h"
#include "base/version_info/version_info.h"
#include "chrome/browser/chrome_browser_main_extra_parts.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/openarc_engine_hooks.h"
#include "components/keep_alive_registry/keep_alive_types.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"

#import "openarc/chrome_page.h"
#import "openarc/scheme.h"

extern "C" int ChromeMain(int argc, const char** argv);

namespace {

void (^g_ready)(void) = nil;
// Chrome quits when its last window closes; OpenArc's windows aren't Chrome's, so this keeps it running.
ScopedKeepAlive* g_keep_alive = nullptr;

class OpenArcParts : public ChromeBrowserMainExtraParts {
 public:
  void PreProfileInit() override { openarc::RegisterScheme(); }
  void PostBrowserStart() override {
    openarc::StartPages();
    g_keep_alive = new ScopedKeepAlive(KeepAliveOrigin::APP_CONTROLLER, KeepAliveRestartOption::DISABLED);
    void (^ready)(void) = g_ready;
    g_ready = nil;
    if (ready) {
      ready();
    }
  }
};

std::unique_ptr<ChromeBrowserMainExtraParts> MakeOpenArcParts() {
  return std::make_unique<OpenArcParts>();
}

}  // namespace

// NSApp: Chrome's application class, which its message pump needs, with Cocoa's own quit. Chrome's
// -terminate: asks its AppController, which OpenArc doesn't have; OpenArc's delegate decides instead.
__attribute__((visibility("default")))
@interface OpenArcChromeApplication : BrowserCrApplication
@end

@implementation OpenArcChromeApplication

- (void)terminate:(id)sender {
  NSApplicationTerminateReply reply = NSTerminateNow;
  if ([self.delegate respondsToSelector:@selector(applicationShouldTerminate:)]) {
    reply = [self.delegate applicationShouldTerminate:self];
  }
  if (reply == NSTerminateNow) {
    chrome::CloseAllBrowsersAndQuit();
  }
}

- (void)cancelTerminate:(id)sender {
}

@end

// Exported from the framework (framework.exports), like OpenArcChromeApplication: the app looks both up by name.
__attribute__((visibility("default")))
@interface OpenArcChromeEngine : NSObject <BrowserChromeEngine>
@end

@implementation OpenArcChromeEngine

+ (id<BrowserChromePage>)pageWithURLString:(NSString*)urlString
                               profilePath:(NSString*)profilePath
                                 ephemeral:(BOOL)ephemeral
                                  delegate:(id<BrowserChromePageDelegate>)delegate {
  return [[OpenArcChromePage alloc] initWithURLString:urlString.length ? urlString : @"about:blank"
                                          profilePath:profilePath
                                            ephemeral:ephemeral
                                             delegate:delegate];
}

+ (NSString*)chromiumVersion {
  return @(std::string(version_info::GetVersionNumber()).c_str());
}

+ (void)cancelDownloadWithID:(NSString*)downloadID {
  openarc::CancelDownload(downloadID);
}

+ (void)setSchemePageProvider:(NSString* _Nullable (^)(NSString*, NSInteger*))provider {
  openarc::SetSchemePageProvider(provider);
}

+ (void)quit {
  openarc::StopPages();
  delete g_keep_alive;
  g_keep_alive = nullptr;
  chrome::CloseAllBrowsersAndQuit();
}

@end

extern "C" __attribute__((visibility("default"))) int OpenArcChromeEngineMain(int argc,
                                                                             const char** argv,
                                                                             void (^ready)(void)) {
  g_ready = [ready copy];
  openarc::g_extra_parts_factory = &MakeOpenArcParts;
  openarc::g_embedder_owns_app = true;
  openarc::g_scheme_loader_factory = &openarc::CreateSchemeLoaderFactory;
  // Before ChromeMain, which checks that NSApp is Chrome's application class. The class's +initialize reads
  // the command line (the forced text direction), so it exists for that moment; ChromeMain makes its own.
  if (!base::CommandLine::InitializedForCurrentProcess()) {
    base::CommandLine::Init(argc, argv);
  }
  [OpenArcChromeApplication sharedApplication];
  base::CommandLine::Reset();
  return ChromeMain(argc, argv);
}
