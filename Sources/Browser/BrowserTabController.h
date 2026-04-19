#ifndef THEBROWSER_BROWSER_TAB_CONTROLLER_H_
#define THEBROWSER_BROWSER_TAB_CONTROLLER_H_

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class BrowserTabController;

@protocol BrowserTabControllerDelegate <NSObject>

- (void)browserTabController:(BrowserTabController *)controller
             didCreateTabWithID:(NSString *)tabID
                          title:(NSString *)title
                      urlString:(NSString *)urlString;

- (void)browserTabController:(BrowserTabController *)controller
             didUpdateTabWithID:(NSString *)tabID
                          title:(nullable NSString *)title
                      urlString:(nullable NSString *)urlString
               faviconURLString:(nullable NSString *)faviconURLString;

- (void)browserTabController:(BrowserTabController *)controller
              didCloseTabWithID:(NSString *)tabID;

@end

@interface BrowserTabHostView : NSView

- (void)setContentCornerRadius:(CGFloat)contentCornerRadius animated:(BOOL)animated;

@end

@interface BrowserTabController : NSObject

@property(nonatomic, weak, nullable) id<BrowserTabControllerDelegate> delegate;

- (instancetype)initWithHostView:(BrowserTabHostView *)hostView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (NSString *)createTabWithURLString:(NSString *)urlString makeActive:(BOOL)makeActive;
- (void)selectTabWithID:(NSString *)tabID;
- (void)reloadActiveTab;
- (void)reloadActiveTabIgnoringCache;
- (void)closeTabWithID:(NSString *)tabID;
- (void)closeAllTabs;
- (void)hostViewDidLayout;

@end

NS_ASSUME_NONNULL_END

#endif  // THEBROWSER_BROWSER_TAB_CONTROLLER_H_
