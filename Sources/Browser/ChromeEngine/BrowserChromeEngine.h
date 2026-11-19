#ifndef OPENARC_BROWSER_CHROME_ENGINE_H_
#define OPENARC_BROWSER_CHROME_ENGINE_H_

// The contract between OpenArc and its Chrome engine: Chrome's own framework with OpenArc's layer
// linked in (Chromium/engine). The app never links the framework. It loads it at launch when the
// Chrome engine is chosen and reaches the layer by name (NSClassFromString, dlsym), so one bundle
// carries CEF and the Chrome engine side by side. Chromium/engine/apply.sh copies this header into the
// Chromium tree, so both sides compile against the same declarations.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserPeerPage;

/// What a page that is not a CEF browser tells its tab: a WebKit page or a Chrome engine page. The
/// selectors match BrowserWebKitPageDelegate, so the tab controller answers both kinds the same way.
@protocol BrowserPeerPageDelegate <NSObject>
- (void)webKitPageDidChangeTitle:(id)page;
- (void)webKitPageDidChangeURL:(id)page;
- (void)webKitPageDidChangeLoading:(id)page;
- (void)webKitPageDidChangeNavigationState:(id)page;
- (void)webKitPage:(id)page didChangeFaviconURLString:(nullable NSString *)urlString;
- (void)webKitPage:(id)page openURLStringInNewTab:(NSString *)urlString inBackground:(BOOL)inBackground;
- (void)webKitPageDidRequestClose:(id)page;
- (void)webKitPage:(id)page
    didChangeMediaAudible:(BOOL)audible
                  playing:(BOOL)playing
                   paused:(BOOL)paused
                    video:(BOOL)video
                    title:(NSString *)title;
- (void)webKitPage:(id)page didChangeFullscreen:(BOOL)fullscreen;
- (void)webKitPage:(id)page didChangeCaptureVideo:(BOOL)video audio:(BOOL)audio;
- (void)webKitPage:(id)page didFindMatch:(BOOL)found;
- (void)webKitPageDidBecomeFocused:(id)page;
@end

/// A page the tab controller shows without CEF. BrowserWebKitPage has these members as it is; a Chrome
/// engine page (OpenArcChromePage in the framework) has them too.
@protocol BrowserPeerPage <NSObject>
@property(nonatomic, readonly) NSView *view;
@property(nonatomic, readonly) NSString *title;
@property(nonatomic, readonly) NSString *urlString;
@property(nonatomic, readonly) BOOL isLoading;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
@property(nonatomic, readonly) BOOL isFullscreen;
@property(nonatomic) double zoomLevel;
@property(nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *navigationEntries;
@property(nonatomic, readonly) NSInteger currentNavigationIndex;
@property(nonatomic, readonly) NSArray<NSData *> *certificateChain;
- (void)loadWithUrlString:(NSString *)urlString;
- (void)goBack;
- (void)goForward;
- (void)goToHistoryOffset:(NSInteger)offset;
- (void)reloadWithIgnoringCache:(BOOL)ignoringCache;
- (void)stopLoading;
- (void)focus;
- (void)evaluate:(NSString *)script completion:(void (^)(NSString *_Nullable))completion;
- (void)find:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase;
- (void)stopFinding;
- (void)setAudioMuted:(BOOL)muted;
- (void)setMediaVolume:(double)volume;
- (void)controlMedia:(NSString *)action;
- (void)togglePictureInPicture;
- (void)exitFullscreen;
- (void)selectedTextWithCompletion:(void (^)(NSString *_Nullable))completion;
- (void)capturePictureWithCompletion:(void (^)(NSData *_Nullable))completion;
- (void)capturePictureWithFraction:(CGRect)fraction completion:(void (^)(NSData *_Nullable))completion;
- (void)print;
- (void)close;
@end

/// The tab controller's side of a Chrome engine page, beyond what a WebKit page reports.
@protocol BrowserChromePageDelegate <BrowserPeerPageDelegate>
/// A link or script in `page` opened `opened`, which already has its contents (and `window.opener`).
- (void)chromePage:(id)page didOpenPage:(id<BrowserPeerPage>)opened inBackground:(BOOL)inBackground;
/// A find in the page reported its matches.
- (void)chromePage:(id)page
    didFindMatches:(NSInteger)matchCount
     activeOrdinal:(NSInteger)activeMatchOrdinal
       finalUpdate:(BOOL)finalUpdate;
/// The address of the link under the pointer, empty when there is none.
- (void)chromePage:(id)page didChangeStatus:(NSString *)status;
/// The page's renderer crashed or was killed; errorCode is Chromium's termination status.
- (void)chromePage:(id)page renderProcessTerminatedWithErrorCode:(NSInteger)errorCode;
/// A key press in the page. Before the page sees it (`unhandled` NO), YES keeps it from the page; after
/// the page left it alone (`unhandled` YES), YES means the app used it. The layer offers what is left to
/// the main menu.
- (BOOL)chromePage:(id)page handleKeyEvent:(NSEvent *)event unhandled:(BOOL)unhandled;
/// A download this page started, or one of its profile with no page of its own. `info` holds id,
/// fileName, url, fullPath, receivedBytes, totalBytes, currentSpeed (bytes a second) and state, a
/// BrowserDownloadState raw value ("inProgress", "completed", "canceled" or "interrupted").
- (void)chromePage:(id)page didUpdateDownload:(NSDictionary<NSString *, id> *)info;
@end

/// A Chrome engine page, as the layer makes it.
@protocol BrowserChromePage <BrowserPeerPage>
@property(nonatomic, weak, nullable) id<BrowserChromePageDelegate> delegate;
/// Chromium's renderer process for the page, 0 without one.
@property(nonatomic, readonly) int rendererProcessID;
/// Runs a DevTools protocol method on the page; the result is JSON, or nil on failure.
- (void)executeDevToolsMethod:(NSString *)method
                       params:(NSString *)paramsJSON
                   completion:(void (^)(NSString *_Nullable result))completion;
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;
- (void)stopFindingClearingSelection:(BOOL)clearSelection;
/// Shows the page's Developer Tools: nil for the last panel, or "console", "network" or "inspect".
- (void)showDevToolsPanel:(nullable NSString *)panel;
/// The page is on screen (or kept drawn) or not, which Chromium's scheduling follows.
- (void)setPageVisible:(BOOL)visible;
/// Sends a Cocoa action such as `copy:` to the page's view. NO without such a view.
- (BOOL)sendAction:(SEL)action;
@end

/// The engine's entry points, as class methods of OpenArcChromeEngine in the framework.
@protocol BrowserChromeEngine <NSObject>
/// A new page for a tab: `profilePath` is the profile's folder, nil for the default one; ephemeral pages keep no data.
+ (id<BrowserChromePage>)pageWithURLString:(NSString *)urlString
                               profilePath:(nullable NSString *)profilePath
                                 ephemeral:(BOOL)ephemeral
                                  delegate:(id<BrowserChromePageDelegate>)delegate;
/// The Chromium version the framework was built from, as "148.0.7778.180".
+ (NSString *)chromiumVersion;
/// Stops a running download a page reported.
+ (void)cancelDownloadWithID:(NSString *)downloadID;
/// Asks Chrome to close its windows and quit; `OpenArcChromeEngineMain` returns once it has.
+ (void)quit;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// Runs the process on Chrome's framework, start to quit. `ready` runs on the main thread once Chrome's
/// browser process is up, where CEF would report its context initialized.
typedef int (*BrowserChromeEngineMainFunction)(int argc, const char *_Nonnull *_Nonnull argv, void (^ready)(void));

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif  // OPENARC_BROWSER_CHROME_ENGINE_H_
