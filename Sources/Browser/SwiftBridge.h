#ifndef OPENARC_BROWSER_SWIFT_BRIDGE_H_
#define OPENARC_BROWSER_SWIFT_BRIDGE_H_

#ifdef __cplusplus
extern "C" {
#endif

void BrowserStartLaunchWarmup(void);
void BrowserCreateApplication(void);
void BrowserContextInitialized(void);
int BrowserHasOpenBrowsers(void);
void BrowserCloseAllBrowsers(void);
int BrowserBeginTrace(void);
/// Writes the trace to `path`; `completion` runs on the main thread.
int BrowserEndTrace(const char* path, void (^completion)(void));
void BrowserPrepareApplicationForCefShutdown(void);
/// 1 when this process runs on the Chrome engine (Chrome's own framework), 0 on CEF. Fixed at launch.
int BrowserUsesChromeEngine(void);
/// 1 when this process runs on WebKit alone, with no Chromium loaded. Fixed at launch.
int BrowserUsesWebKitEngine(void);
/// 1 when this process runs on Ladybird, with no Chromium loaded. Fixed at launch.
int BrowserUsesLadybirdEngine(void);
/// 1 when CEF is loaded: neither the Chrome engine, WebKit nor Ladybird. Only then may CEF's functions run.
int BrowserUsesCEF(void);
/// Ends the app's run loop: CEF's or WebKit's, Chrome's orderly quit on the Chrome engine, or Ladybird's.
void BrowserStopApplicationLoop(void);
/// Ends CefRunMessageLoop the way CEF expects; does nothing without CEF.
void BrowserQuitCefMessageLoop(void);

#ifdef __OBJC__

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

typedef void (^BrowserPermissionCompletion)(BOOL granted);

BOOL BrowserLoadRuntimeConfiguration(NSString** framework_path,
                                     NSString** main_bundle_path,
                                     NSString** root_cache_path,
                                     NSString** cache_path);
NSString* BrowserChromiumVersionString(void);
/// The Ladybird engine's version, nil unless this process runs on Ladybird.
NSString* BrowserLadybirdVersionString(void);
/// Stores cookies (BrowserTabControllerDriver.importCookies's dictionaries) in Ladybird's cookie jar; 0 off Ladybird.
NSInteger BrowserLadybirdImportCookies(NSArray<NSDictionary<NSString*, id>*>* cookies);
void BrowserSetBatterySaverModeEnabled(BOOL enabled);

void BrowserRequestNotificationPermission(NSString* origin,
                                          BrowserPermissionCompletion completion);
NSString* BrowserCopyInstalledExtensionsJSON(NSString* profile_path);
BOOL BrowserSetExtensionEnabled(NSString* profile_path, NSString* extension_id,
                                BOOL is_enabled);
NSString* BrowserRunExtensionAction(NSString* profile_path,
                                    NSString* extension_id);
BOOL BrowserRemoveExtension(NSString* profile_path, NSString* extension_id);
/// Tells extensions which pages are the tabs of a window, as JSON:
/// [{browserId, index, active, pinned}].
void BrowserSetExtensionTabs(NSString* window_key, BOOL focused,
                             NSString* tabs_json);
/// `action` is 0 to select the tab and 1 to close it.
void BrowserSetExtensionTabActionHandler(void (^handler)(int browser_id,
                                                         int action));
/// 0: cannot translate, 1: started, 2: already in that language.
int BrowserTranslatePage(int browser_id, NSString* language);
void BrowserRevertTranslation(int browser_id);
/// 0: not translated, 1: translating, 2: translated.
int BrowserTranslationState(int browser_id);
/// The screen or window the next screen share captures, as "screen:1:0" or "window:9:0".
void BrowserSetNextDesktopMediaID(NSString* media_id);

#endif

#ifdef __cplusplus
}
#endif

#endif  // OPENARC_BROWSER_SWIFT_BRIDGE_H_
