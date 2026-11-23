#ifndef OPENARC_BROWSER_LADYBIRD_ENGINE_MAIN_H_
#define OPENARC_BROWSER_LADYBIRD_ENGINE_MAIN_H_

#import <Foundation/Foundation.h>

#import "Browser/SwiftBridge.h"

#ifdef __cplusplus
extern "C" {
#endif

@protocol BrowserLadybirdEngine;

/// The engine's class methods; nil unless this process runs on Ladybird.
Class<BrowserLadybirdEngine> _Nullable BrowserLadybirdEngineClass(void);
/// 1 when this launch should run on Ladybird: chosen, and the bundle carries its framework.
int BrowserShouldRunLadybirdEngine(void);
/// Runs the process on Ladybird, start to quit, with its profile beside Chromium's data in `cache_root`'s parent.
int BrowserRunLadybirdEngine(int argc, char* _Nonnull argv[_Nonnull], NSString* _Nonnull cache_root);

#ifdef __cplusplus
}
#endif

#endif  // OPENARC_BROWSER_LADYBIRD_ENGINE_MAIN_H_
