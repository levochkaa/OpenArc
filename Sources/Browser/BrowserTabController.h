#ifndef THEBROWSER_BROWSER_TAB_CONTROLLER_H_
#define THEBROWSER_BROWSER_TAB_CONTROLLER_H_

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class BrowserTabController;

@protocol BrowserTabControllerDelegate <NSObject>

- (void)browserTabController:(BrowserTabController *)controller
             didCreateTabWithID:(NSString *)tabID
                          title:(NSString *)title
                      urlString:(NSString *)urlString
                       isActive:(BOOL)isActive;

- (void)browserTabController:(BrowserTabController *)controller
             didUpdateTabWithID:(NSString *)tabID
                          title:(nullable NSString *)title
                      urlString:(nullable NSString *)urlString
               faviconURLString:(nullable NSString *)faviconURLString;

- (void)browserTabController:(BrowserTabController *)controller
    didUpdateNavigationStateForTabWithID:(NSString *)tabID
                               canGoBack:(BOOL)canGoBack
                            canGoForward:(BOOL)canGoForward;

- (void)browserTabController:(BrowserTabController *)controller
       didUpdateLoadingStateForTabWithID:(NSString *)tabID
                               isLoading:(BOOL)isLoading;

- (void)browserTabController:(BrowserTabController *)controller
    didUpdateFindResultForTabWithID:(NSString *)tabID
                         matchCount:(NSInteger)matchCount
                 activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                        finalUpdate:(BOOL)finalUpdate;

- (void)browserTabController:(BrowserTabController *)controller
    didUpdateDownloadWithID:(NSString *)downloadID
                   fileName:(NSString *)fileName
                  urlString:(NSString *)urlString
                   fullPath:(nullable NSString *)fullPath
              receivedBytes:(int64_t)receivedBytes
                 totalBytes:(int64_t)totalBytes
        currentSpeedBytesPerSecond:(int64_t)currentSpeedBytesPerSecond
              stateRawValue:(NSString *)stateRawValue;

- (void)browserTabController:(BrowserTabController *)controller
              didCloseTabWithID:(NSString *)tabID;

@end

@interface BrowserTabHostView : NSView

@end

@interface BrowserTabController : NSObject

@property(nonatomic, weak, nullable) id<BrowserTabControllerDelegate> delegate;

- (instancetype)initWithHostView:(BrowserTabHostView *)hostView;
- (instancetype)initWithHostView:(BrowserTabHostView *)hostView
    usesEphemeralRequestContext:(BOOL)usesEphemeralRequestContext
                profileCachePath:(nullable NSString *)profileCachePath NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (NSString *)createTabWithURLString:(NSString *)urlString makeActive:(BOOL)makeActive;
- (void)selectTabWithID:(NSString *)tabID;
- (void)deselectActiveTab;
- (void)navigateActiveTabToURLString:(NSString *)urlString
    NS_SWIFT_NAME(navigateActiveTab(toURLString:));
- (void)goBackActiveTab;
- (void)goForwardActiveTab;
- (void)reloadActiveTab;
- (void)reloadActiveTabIgnoringCache;
- (void)clearCacheAndReloadActiveTab;
- (void)clearCookiesAndReloadActiveTab;
- (void)stopLoadingActiveTab;
- (void)saveActiveTabWithSuggestedName:(nullable NSString *)suggestedName;
- (void)captureFullPageActiveTabToPasteboard;
- (void)pasteAndMatchStyleActiveTab;
- (void)printActiveTab;
- (void)castActiveTab;
- (void)requestActiveTabWebAppManifestWithCompletion:
    (void (^)(NSString * _Nullable payloadJSON))completion
    NS_SWIFT_NAME(requestActiveTabWebAppManifest(completion:));
- (void)setActiveTabZoomLevel:(double)zoomLevel;
- (void)findInActiveTabWithText:(NSString *)text
                        forward:(BOOL)forward
                      matchCase:(BOOL)matchCase
                       findNext:(BOOL)findNext
    NS_SWIFT_NAME(findInActiveTab(withText:forward:matchCase:findNext:));
- (void)stopFindingInActiveTabWithClearSelection:(BOOL)clearSelection
    NS_SWIFT_NAME(stopFindingInActiveTab(clearSelection:));
- (void)closeTabWithID:(NSString *)tabID forceClose:(BOOL)forceClose;
- (void)closeTabWithID:(NSString *)tabID;
- (void)closeAllTabs;
- (void)prepareForCefShutdown;
- (void)hostViewDidLayout;

@end

NS_ASSUME_NONNULL_END

#endif  // THEBROWSER_BROWSER_TAB_CONTROLLER_H_
