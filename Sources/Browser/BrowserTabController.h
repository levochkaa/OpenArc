#ifndef OPENARC_BROWSER_TAB_CONTROLLER_H_
#define OPENARC_BROWSER_TAB_CONTROLLER_H_

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

@class BrowserPeekSpace;
@class BrowserPeekPanel;

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

/// A page's context menu asked for something only the window can do. The command
/// is the raw value of `BrowserPageContextCommand`.
- (void)browserTabController:(BrowserTabController *)controller
    performPageContextCommand:(NSString *)command
                     argument:(NSString *)argument;
// The address of the link under the pointer, empty when there is none.
- (void)browserTabController:(BrowserTabController *)controller
             didChangeStatus:(NSString *)status
                forTabWithID:(NSString *)tabID;
// The page asks the user before closing, on the main thread.
- (void)browserTabController:(BrowserTabController *)controller
    willConfirmCloseForTabWithID:(NSString *)tabID;
// Emitted before didCloseTabWithID for a confirmed manual request.
- (void)browserTabController:(BrowserTabController *)controller
    didFinishCloseRequestForTabWithID:(NSString *)tabID
                           requestID:(NSString *)requestID
                             outcome:(BrowserTabCloseRequestOutcome)outcome;
// The window's Spaces for a Peek card's or small window's Open In menu.
- (NSArray<BrowserPeekSpace *> *)peekSpacesForBrowserTabController:(BrowserTabController *)controller;
// The user closed a Peek card or small window, which Undo can reopen.
- (void)browserTabController:(BrowserTabController *)controller
    didClosePeekWithURLString:(NSString *)urlString
                   standalone:(BOOL)standalone;
// A Peek card's page joins the shown page in a Split View.
- (void)browserTabController:(BrowserTabController *)controller
    openPeekURLStringInSplitView:(NSString *)urlString;
// Open In: a card's or small window's page becomes a tab of that Space.
- (void)browserTabController:(BrowserTabController *)controller
           openPeekURLString:(NSString *)urlString
               inSpaceWithID:(NSString *)spaceID;
// Asked on the main thread before a link click in a tab's page; YES cancels
// the navigation and opens the link in Peek instead (the setting for links
// to other sites from pinned tabs).
- (BOOL)browserTabController:(BrowserTabController *)controller
    shouldPeekNavigationFromTabWithID:(NSString *)tabID
                          toURLString:(NSString *)urlString;
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
// A tab's page asks for permissions: `kinds` are BrowserSitePermissionKind raw
// values. `mediaAccess` marks camera and microphone, which CEF leaves to the
// app; Chromium remembers the answers to the others. Answer with
// resolveSitePermissionRequest:allowed:.
- (void)browserTabController:(BrowserTabController *)controller
    didRequestSitePermission:(NSInteger)requestID
                forTabWithID:(NSString *)tabID
                      origin:(NSString *)origin
                       kinds:(NSArray<NSString *> *)kinds
                 mediaAccess:(BOOL)mediaAccess;
// The engine withdrew a request: its page navigated or closed.
- (void)browserTabController:(BrowserTabController *)controller
    didDismissSitePermissionRequest:(NSInteger)requestID;
// The tab's renderer crashed or was killed; the page is gone until it
// loads again. errorCode is Chromium's.
- (void)browserTabController:(BrowserTabController *)controller
    renderProcessTerminatedForTabWithID:(NSString *)tabID
                              errorCode:(NSInteger)errorCode;
// The tab's pages started, paused or stopped playing media. The renderer
// reports it, since CEF has no audible signal: audible media has sound,
// paused media can resume, video is visible; the tracks and title come
// from the page's Media Session.
- (void)browserTabController:(BrowserTabController *)controller
    didChangeMediaStateForTabWithID:(NSString *)tabID
                            audible:(BOOL)audible
                            playing:(BOOL)playing
                             paused:(BOOL)paused
                              video:(BOOL)video
                   hasPreviousTrack:(BOOL)hasPreviousTrack
                       hasNextTrack:(BOOL)hasNextTrack
                   pictureInPicture:(BOOL)pictureInPicture
                              title:(NSString *)title;

@end

@interface BrowserTabHostView : NSView

@end

@interface BrowserTabController : NSObject

/// Runs in this controller's pages as they start to load.
@property(nonatomic, copy, nullable) NSString *pageLoadStartScript;
/// Pages size themselves to their content, as an extension's popup does.
@property(nonatomic) BOOL autoResizesPages;
@property(nonatomic, copy, nullable) void (^onPageContentSizeChange)(NSSize size);
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
/// The active tab's pages in history order, each with `url` and `title`.
- (void)visitNavigationEntriesForActiveTab:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *entries,
                                                     NSInteger currentIndex))completion;
- (void)goToHistoryOffsetInActiveTab:(NSInteger)offset;
- (void)goForwardActiveTab;
- (void)reloadActiveTab;
- (void)reloadActiveTabIgnoringCache;
- (void)clearCacheAndReloadActiveTab;
- (void)clearCookiesAndReloadActiveTab;
- (void)stopLoadingActiveTab;
/// Where the next page keeps its data; nil uses the controller's own profile.
@property(nonatomic, copy, nullable) NSString *profileCachePathForNewTabs;
- (void)showDevToolsForActiveTab;
- (void)inspectElementsInActiveTab;
- (void)showJavaScriptConsoleForActiveTab;
- (void)showNetworkInspectorForActiveTab;
/// Peek: opens the page in a floating card over the window.
- (void)showPeekWithURLString:(NSString *)urlString;
/// Opens the page in a small window of its own.
- (void)showLittleWindowWithURLString:(NSString *)urlString;
/// An empty small window with its address field focused.
- (void)showNewLittleWindow;
/// Closes every Peek card and small window of this window's pages.
- (void)closeAllPeeks;
- (void)setPictureInPicture:(BOOL)active forTabWithID:(NSString *)tabID;
- (void)togglePictureInPictureInActiveTab;
- (void)setAudioMuted:(BOOL)muted forTabWithID:(NSString *)tabID;
/// Answers a site permission request: YES allows, NO blocks and nil
/// dismisses it without an answer. Unknown or withdrawn requests are ignored.
- (void)resolveSitePermissionRequest:(NSInteger)requestID allowed:(nullable NSNumber *)allowed
    NS_SWIFT_NAME(resolveSitePermissionRequest(_:allowed:));
/// Sends "play", "pause", "previoustrack" or "nexttrack" to the frame playing
/// the tab's media.
- (void)controlMediaInTabWithID:(NSString *)tabID action:(NSString *)action
    NS_SWIFT_NAME(controlMedia(inTabWithID:action:));
/// The open Peek card or small window of a session; its pages ask for
/// permissions as the tab "peek:<session>".
- (nullable BrowserPeekPanel *)peekPanelForSessionID:(NSInteger)sessionID
    NS_SWIFT_NAME(peekPanel(forSessionID:));
/// Chromium's content settings for a page that differ from the profile
/// default, by BrowserSiteSettingKind raw value: "allow", "block" or "ask".
- (NSDictionary<NSString *, NSString *> *)siteSettingsForURLString:(NSString *)urlString
    NS_SWIFT_NAME(siteSettings(forURLString:));
/// Sets one, or with "default" removes the page's own value.
- (void)setSiteSetting:(NSString *)kind value:(NSString *)value forURLString:(NSString *)urlString
    NS_SWIFT_NAME(setSiteSetting(_:value:forURLString:));
- (void)saveActiveTabWithSuggestedName:(nullable NSString *)suggestedName;
- (void)captureFullPageActiveTabToPasteboard;
/// Sends a Cocoa action such as `copyToFindPboard:` to the active page's
/// Chromium view, wherever the window's focus is. NO without such a view.
- (BOOL)sendActionToActivePage:(SEL)action NS_SWIFT_NAME(sendActionToActivePage(_:));
/// Gives the keyboard back to the active page.
- (void)focusActivePage;
/// Capture: `fraction` is the outlined part of the active page view,
/// each coordinate from 0 to 1 with y growing downward.
- (void)captureActiveTabRegionToPasteboard:(CGRect)fraction
    NS_SWIFT_NAME(captureActiveTabRegionToPasteboard(fraction:));
- (void)pasteAndMatchStyleActiveTab;
- (void)printActiveTab;
- (void)castActiveTab;
- (void)requestActiveTabWebAppManifestWithCompletion:
    (void (^)(NSString * _Nullable payloadJSON))completion
    NS_SWIFT_NAME(requestActiveTabWebAppManifest(completion:));
/// The text selected in the active page, or nil without a selection.
- (void)requestActiveTabSelectedTextWithCompletion:(void (^)(NSString * _Nullable text))completion
    NS_SWIFT_NAME(requestActiveTabSelectedText(completion:));
- (void)setActiveTabZoomLevel:(double)zoomLevel;
/// NAN without an attached page or off the UI thread.
- (double)zoomLevelForTabWithID:(NSString *)tabID NS_SWIFT_NAME(zoomLevel(forTabWithID:));
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

/// Scripts the browser adds to pages.
@interface BrowserPageScripts : NSObject
/// A script to run at the start of each page, such as a Space's theme variables.
@property(class, nonatomic, copy, nullable) NSString *pageStartScript;
@end

NS_ASSUME_NONNULL_END

#endif  // OPENARC_BROWSER_TAB_CONTROLLER_H_
