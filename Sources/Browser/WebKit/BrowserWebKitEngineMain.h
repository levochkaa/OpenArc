#ifndef OPENARC_BROWSER_WEBKIT_ENGINE_MAIN_H_
#define OPENARC_BROWSER_WEBKIT_ENGINE_MAIN_H_

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when this launch should run on WebKit: chosen, or the bundle carries no CEF.
int BrowserShouldRunWebKitEngine(void);
/// Runs the process on WebKit alone, start to quit. No Chromium loads.
int BrowserRunWebKitEngine(int argc, char* _Nonnull argv[_Nonnull]);

#ifdef __cplusplus
}
#endif

#endif  // OPENARC_BROWSER_WEBKIT_ENGINE_MAIN_H_
