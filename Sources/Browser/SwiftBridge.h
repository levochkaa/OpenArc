#ifndef THEBROWSER_BROWSER_SWIFT_BRIDGE_H_
#define THEBROWSER_BROWSER_SWIFT_BRIDGE_H_

#ifdef __cplusplus
extern "C" {
#endif

void BrowserCreateApplication(void);
void BrowserContextInitialized(void);
int BrowserHasOpenBrowsers(void);
void BrowserCloseAllBrowsers(void);

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

void BrowserRequestNotificationPermission(NSString* origin,
                                          BrowserPermissionCompletion completion);
NSString* BrowserCopyInstalledExtensionsJSON(void);
BOOL BrowserSetExtensionEnabled(NSString* extension_id, BOOL is_enabled);
BOOL BrowserRemoveExtension(NSString* extension_id);

#endif

#ifdef __cplusplus
}
#endif

#endif  // THEBROWSER_BROWSER_SWIFT_BRIDGE_H_
