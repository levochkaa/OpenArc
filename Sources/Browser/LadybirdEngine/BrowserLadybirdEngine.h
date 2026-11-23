#ifndef OPENARC_BROWSER_LADYBIRD_ENGINE_H_
#define OPENARC_BROWSER_LADYBIRD_ENGINE_H_

// The contract between OpenArc and its Ladybird engine: Ladybird's libraries and helper processes with OpenArc's
// layer (Ladybird/engine). The app never links the framework. It loads it at launch when the Ladybird engine is
// chosen and reaches the layer by name (NSClassFromString, dlsym), as it reaches the Chrome engine.
// Ladybird/engine/apply.sh copies this header and BrowserChromeEngine.h into the Ladybird tree, so both sides
// compile against the same declarations.
//
// A Ladybird page is a BrowserChromePage: the tab controller shows, navigates, finds, mutes, captures and closes
// it, and takes its popups, keys, link status, downloads and permission prompts, through the code Chrome engine
// pages already use. What Ladybird has no counterpart for answers nothing (DevTools panels open Ladybird's own
// remote DevTools server instead, see the layer).

#import <AppKit/AppKit.h>

#import "Browser/ChromeEngine/BrowserChromeEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// The engine's entry points, as class methods of OpenArcLadybirdEngine in the framework.
@protocol BrowserLadybirdEngine <NSObject>
/// A new page for a tab. Ladybird keeps one profile for the process; `ephemeral` pages keep no data (a private
/// window). `profilePath` names the OpenArc profile the page belongs to, which downloads and prompts report.
+ (nullable id<BrowserChromePage>)pageWithURLString:(NSString *)urlString
                                        profilePath:(nullable NSString *)profilePath
                                          ephemeral:(BOOL)ephemeral
                                           delegate:(id<BrowserChromePageDelegate>)delegate;
/// The Ladybird version the framework was built from: Ladybird's version and its commit, as "1.0-b03e6d2bc9".
+ (NSString *)ladybirdVersion;
/// The pages of OpenArc's own `openarc://` addresses (an Easel's or a note's tab), which Ladybird has no scheme
/// for: `provider` returns a page's HTML and sets `statusCode` (200 before the call), or returns nil when the app
/// took the address itself (a shared page's Add to OpenArc button) and the navigation stops. Set before the
/// engine starts; runs on the main thread.
+ (void)setSchemePageProvider:(NSString *_Nullable (^)(NSString *urlString, NSInteger *statusCode))provider;
/// Stops a running download a page reported.
+ (void)cancelDownloadWithID:(NSString *)downloadID;
/// Ladybird's own cookie store for the process: each cookie is a dictionary with the keys
/// BrowserWebKitPage.importCookies takes (url, host, name, value, path, expires, secure, httpOnly, sameSite).
/// Returns how many it stored.
+ (NSInteger)importCookies:(NSArray<NSDictionary<NSString *, id> *> *)cookies;
/// Stops Ladybird's helper processes and ends the run loop; `OpenArcLadybirdEngineMain` returns once it has.
+ (void)quit;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// Runs the process on Ladybird, start to quit. `dataPath` is the folder Ladybird keeps its profile in
/// (cookies, history, caches). `ready` runs on the main thread once Ladybird's services are up, where CEF would
/// report its context initialized.
typedef int (*BrowserLadybirdEngineMainFunction)(int argc,
                                                 const char *_Nonnull *_Nonnull argv,
                                                 const char *_Nonnull dataPath,
                                                 void (^ready)(void));

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif  // OPENARC_BROWSER_LADYBIRD_ENGINE_H_
