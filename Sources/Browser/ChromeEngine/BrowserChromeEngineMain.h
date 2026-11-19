#ifndef OPENARC_BROWSER_CHROME_ENGINE_MAIN_H_
#define OPENARC_BROWSER_CHROME_ENGINE_MAIN_H_

#import <Foundation/Foundation.h>

#import "Browser/SwiftBridge.h"

#ifdef __cplusplus
extern "C" {
#endif

@protocol BrowserChromeEngine;

/// The engine's class methods; nil on CEF.
Class<BrowserChromeEngine> _Nullable BrowserChromeEngineClass(void);
/// 1 when this launch should run on the Chrome engine: chosen, and the bundle carries its framework.
int BrowserShouldRunChromeEngine(void);
/// Runs the process on the Chrome engine, start to quit, with `cache_root` as Chrome's user data.
int BrowserRunChromeEngine(int argc, char* _Nonnull argv[_Nonnull], NSString* _Nonnull cache_root);

#ifdef __cplusplus
}
#endif

#endif  // OPENARC_BROWSER_CHROME_ENGINE_MAIN_H_
