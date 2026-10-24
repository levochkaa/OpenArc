#ifndef THEBROWSER_BROWSER_TAB_CONTROLLER_H_
#define THEBROWSER_BROWSER_TAB_CONTROLLER_H_

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class BrowserTabController;

typedef NS_ENUM(NSInteger, BrowserTabEngineCreationState) {
  BrowserTabEngineCreationStateCreating,
  BrowserTabEngineCreationStateReady,
  BrowserTabEngineCreationStateFailed,
};

typedef NS_ENUM(NSInteger, BrowserTabCloseRequestOutcome) {
  BrowserTabCloseRequestOutcomeClosed,
  BrowserTabCloseRequestOutcomeCancelled,
};

@protocol BrowserTabControllerDelegate <NSObject>

- (void)browserTabController:(BrowserTabController *)controller
             didCreateTabWithID:(NSString *)tabID
                          title:(NSString *)title
                      urlString:(NSString *)urlString
                       isActive:(BOOL)isActive;

- (void)browserTabController:(BrowserTabController *)controller
    didChangeCreationStateForTabWithID:(NSString *)tabID
                                state:(BrowserTabEngineCreationState)state;

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

@optional
// Emitted before didCloseTabWithID for a confirmed manual request.
- (void)browserTabController:(BrowserTabController *)controller
    didFinishCloseRequestForTabWithID:(NSString *)tabID
                           requestID:(NSString *)requestID
                             outcome:(BrowserTabCloseRequestOutcome)outcome;
// A visible Split View pane other than the active tab received focus.
- (void)browserTabController:(BrowserTabController *)controller
             didFocusTabWithID:(NSString *)tabID;
// Pane frames of the visible Split View in host view coordinates, in pane
// order, after every layout that changes them; empty when no split is shown.
- (void)browserTabController:(BrowserTabController *)controller
    didLayoutSplitPanesWithTabIDs:(NSArray<NSString *> *)tabIDs
                           frames:(NSArray<NSValue *> *)frames;
// A divider drag or reset in the visible Split View ended. Fractions follow
// tabIDs, which are every pane of the split in pane order.
- (void)browserTabController:(BrowserTabController *)controller
    didResizeSplitWithTabIDs:(NSArray<NSString *> *)tabIDs
                   fractions:(NSArray<NSNumber *> *)fractions;

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
// YES means a failed record admitted a retry, even if CEF refuses it again.
// Creating, ready, removed and unknown records are not eligible.
- (BOOL)retryTabCreationWithID:(NSString *)tabID urlString:(NSString *)urlString
    NS_SWIFT_NAME(retryTabCreation(withID:urlString:));
// The delegate acknowledges after delivering ready to its model. The first
// app navigation remains queued until then; removed/closing tabs are ignored.
- (void)acknowledgeTabReadyWithID:(NSString *)tabID
    NS_SWIFT_NAME(acknowledgeTabReady(withID:));
- (void)selectTabWithID:(NSString *)tabID;
// Shows every listed tab as a Split View pane while the active tab is one of
// them. nil or fewer than two tabs shows only the active tab.
- (void)setVisibleTabLayoutWithTabIDs:(nullable NSArray<NSString *> *)tabIDs
                             vertical:(BOOL)vertical
                            fractions:(nullable NSArray<NSNumber *> *)fractions
    NS_SWIFT_NAME(setVisibleTabLayout(withTabIDs:vertical:fractions:));
- (void)deselectActiveTab;
// YES accepts the latest target for an existing tab, including one whose engine
// is still creating or failed. It does not mean the page has loaded.
- (BOOL)navigateTabWithID:(NSString *)tabID toURLString:(NSString *)urlString
    NS_SWIFT_NAME(navigateTab(withID:toURLString:));
- (void)navigateActiveTabToURLString:(NSString *)urlString
    NS_SWIFT_NAME(navigateActiveTab(toURLString:));
- (void)goBackActiveTab;
- (void)goForwardActiveTab;
- (void)reloadActiveTab;
- (void)reloadActiveTabIgnoringCache;
- (void)clearCacheAndReloadActiveTab;
- (void)clearCookiesAndReloadActiveTab;
- (void)stopLoadingActiveTab;
- (void)showDevToolsForActiveTab;
- (void)setPictureInPicture:(BOOL)active forTabWithID:(NSString *)tabID;
- (void)setAudioMuted:(BOOL)muted forTabWithID:(NSString *)tabID;
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
// YES means admitted, not closed. Exactly one nonce may be pending per tab.
// A subsequent structural/forced close invalidates the manual request.
- (BOOL)requestCloseTabWithID:(NSString *)tabID requestID:(NSString *)requestID
    NS_SWIFT_NAME(requestCloseTab(withID:requestID:));
- (void)closeTabWithID:(NSString *)tabID forceClose:(BOOL)forceClose;
- (void)closeTabWithID:(NSString *)tabID;
- (void)closeAllTabs;
- (void)prepareForCefShutdown;
- (void)hostViewDidLayout;

@end

NS_ASSUME_NONNULL_END

#endif  // THEBROWSER_BROWSER_TAB_CONTROLLER_H_
