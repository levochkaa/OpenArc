#ifndef THEBROWSER_BROWSER_SWIFT_BRIDGE_H_
#define THEBROWSER_BROWSER_SWIFT_BRIDGE_H_

void BrowserCreateApplication(void);
void BrowserContextInitialized(void);

#ifdef __OBJC__

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

typedef void (^BrowserPermissionCompletion)(BOOL granted);

BOOL BrowserLoadRuntimeConfiguration(NSString** helper_path,
                                     NSString** framework_path,
                                     NSString** main_bundle_path,
                                     NSString** root_cache_path,
                                     NSString** cache_path);

void BrowserRequestNotificationPermission(NSString* origin,
                                          BrowserPermissionCompletion completion);

#endif

#endif  // THEBROWSER_BROWSER_SWIFT_BRIDGE_H_
