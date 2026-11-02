#ifndef OPENARC_BROWSER_SWIFT_BRIDGE_H_
#define OPENARC_BROWSER_SWIFT_BRIDGE_H_

#ifdef __cplusplus
extern "C" {
#endif

void BrowserCreateApplication(void);
void BrowserContextInitialized(void);
int BrowserHasOpenBrowsers(void);
void BrowserCloseAllBrowsers(void);
int BrowserBeginTrace(void);
/// Writes the trace to `path`; `completion` runs on the main thread.
int BrowserEndTrace(const char* path, void (^completion)(void));
void BrowserPrepareApplicationForCefShutdown(void);

#ifdef __OBJC__

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

typedef void (^BrowserPermissionCompletion)(BOOL granted);

BOOL BrowserLoadRuntimeConfiguration(NSString** helper_path,
                                     NSString** framework_path,
                                     NSString** main_bundle_path,
                                     NSString** root_cache_path,
                                     NSString** cache_path);
NSString* BrowserChromiumVersionString(void);
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

#endif

#ifdef __cplusplus
}
#endif

#endif  // OPENARC_BROWSER_SWIFT_BRIDGE_H_
