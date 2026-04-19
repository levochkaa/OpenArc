#import "Browser/BrowserTabController.h"

#import <QuartzCore/QuartzCore.h>

#import "Browser/SwiftBridge.h"
#include "Shared/ClientManager.h"
#include "Shared/ClientUtil.h"

#include <map>
#include <string>
#include <vector>

#include "include/base/cef_callback.h"
#include "include/cef_client.h"
#include "include/cef_browser.h"
#include "include/cef_frame.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_permission_handler.h"
#include "include/internal/cef_mac.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"

namespace {

constexpr char kFallbackTabTitle[] = "New Tab";
constexpr CGFloat kDefaultContentCornerRadius = 12.0;
constexpr CFTimeInterval kCornerRadiusAnimationDuration = 0.18;

std::string ToStdString(NSString *value) {
  if (value.length == 0) {
    return std::string();
  }
  return std::string(value.UTF8String);
}

NSString *ToNSString(const std::string &value) {
  return [[NSString alloc] initWithUTF8String:value.c_str()];
}

NSString *DefaultTitleForURLString(NSString *urlString) {
  NSURL *url = [NSURL URLWithString:urlString];
  NSString *host = url.host;
  if (host.length > 0) {
    return host;
  }
  return @(kFallbackTabTitle);
}

CefRect CefRectFromBounds(NSRect bounds) {
  return CefRect(0, 0, static_cast<int>(NSWidth(bounds)),
                 static_cast<int>(NSHeight(bounds)));
}

NSView *BrowserViewForBrowser(CefRefPtr<CefBrowser> browser);

void SyncBrowserViewFrame(BrowserTabHostView *hostView,
                          CefRefPtr<CefBrowser> browser) {
  if (hostView == nil || !browser) {
    return;
  }

  NSView *browserView = BrowserViewForBrowser(browser);
  if (browserView == nil) {
    return;
  }

  browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  const NSRect hostBounds = hostView.bounds;
  browserView.frame =
      NSMakeRect(0, 0, NSWidth(hostBounds), NSHeight(hostBounds));
}

NSView *BrowserViewForBrowser(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return nil;
  }
  return CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
}

void ContinuePermissionRequest(
    CefRefPtr<CefPermissionPromptCallback> callback,
    cef_permission_request_result_t result) {
  callback->Continue(result);
}

void ReloadBrowser(CefRefPtr<CefBrowser> browser, bool ignore_cache) {
  if (!browser) {
    return;
  }

  if (ignore_cache) {
    browser->ReloadIgnoreCache();
  } else {
    browser->Reload();
  }
}

void ReloadBrowserOnUI(CefRefPtr<CefBrowser> browser, bool ignore_cache) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    ReloadBrowser(browser, ignore_cache);
    return;
  }

  CefPostTask(
      TID_UI,
      CefCreateClosureTask(
          base::BindOnce(&ReloadBrowser, browser, ignore_cache)));
}

void ContinuePermissionRequestOnUI(
    CefRefPtr<CefPermissionPromptCallback> callback,
    cef_permission_request_result_t result) {
  if (CefCurrentlyOn(TID_UI)) {
    callback->Continue(result);
    return;
  }

  CefPostTask(
      TID_UI,
      CefCreateClosureTask(
          base::BindOnce(&ContinuePermissionRequest, callback, result)));
}

bool IsNotificationsOnlyRequest(uint32_t requestedPermissions) {
  return requestedPermissions == CEF_PERMISSION_TYPE_NOTIFICATIONS;
}

class BrowserTabClient final : public CefClient,
                               public CefDisplayHandler,
                               public CefLifeSpanHandler,
                               public CefLoadHandler,
                               public CefPermissionHandler {
 public:
  BrowserTabClient(BrowserTabController *controller, const std::string &tabID)
      : controller_(controller), tab_id_(tabID) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return this;
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString &url) override;

  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString &title) override;

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString> &icon_urls) override;

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString &target_url,
                     const CefString &target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures &popupFeatures,
                     CefWindowInfo &windowInfo,
                     CefRefPtr<CefClient> &client,
                     CefBrowserSettings &settings,
                     CefRefPtr<CefDictionaryValue> &extra_info,
                     bool *no_javascript_access) override;

  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser,
      uint64_t prompt_id,
      const CefString &requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override;

 private:
  __weak BrowserTabController *controller_;
  const std::string tab_id_;

  IMPLEMENT_REFCOUNTING(BrowserTabClient);
};

struct TabRecord {
  CefRefPtr<CefClient> client;
  CefRefPtr<CefBrowser> browser;
  bool pending_close = false;
};

}  // namespace

@interface BrowserTabHostView ()

@property(nonatomic, weak) BrowserTabController *controller;

@end

@interface BrowserTabController ()

- (void)handleBrowserCreated:(CefRefPtr<CefBrowser>)browser
                     forTabID:(NSString *)tabID;
- (void)handleBrowserClosedForTabID:(NSString *)tabID;
- (void)handleTitleChange:(NSString *)title forTabID:(NSString *)tabID;
- (void)handleAddressChange:(NSString *)urlString forTabID:(NSString *)tabID;
- (void)handleFaviconURLChange:(nullable NSString *)faviconURLString
                      forTabID:(NSString *)tabID;
- (void)openPopupTabWithURLString:(NSString *)urlString;
- (void)syncBrowserFrames;
- (void)updateBrowserVisibility;

@end

@implementation BrowserTabHostView

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self == nil) {
    return nil;
  }

  self.wantsLayer = YES;
  self.layer.backgroundColor = NSColor.clearColor.CGColor;
  self.layer.cornerRadius = kDefaultContentCornerRadius;
  self.layer.masksToBounds = YES;
  return self;
}

- (void)setContentCornerRadius:(CGFloat)contentCornerRadius animated:(BOOL)animated {
  CALayer *layer = self.layer;
  if (layer == nil) {
    return;
  }

  CALayer *presentationLayer = layer.presentationLayer;
  CGFloat currentCornerRadius =
      presentationLayer != nil ? presentationLayer.cornerRadius : layer.cornerRadius;
  if (currentCornerRadius == contentCornerRadius &&
      layer.cornerRadius == contentCornerRadius) {
    return;
  }

  [layer removeAnimationForKey:@"contentCornerRadius"];

  if (animated) {
    CABasicAnimation *animation =
        [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
    animation.fromValue = @(currentCornerRadius);
    animation.toValue = @(contentCornerRadius);
    animation.duration = kCornerRadiusAnimationDuration;
    animation.timingFunction =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [layer addAnimation:animation forKey:@"contentCornerRadius"];
  }

  layer.cornerRadius = contentCornerRadius;
}

- (void)setFrame:(NSRect)frame {
  NSRect previousFrame = self.frame;
  [super setFrame:frame];

  if (!NSEqualRects(previousFrame, frame)) {
    [self.controller syncBrowserFrames];
  }
}

- (void)setBounds:(NSRect)bounds {
  NSRect previousBounds = self.bounds;
  [super setBounds:bounds];

  if (!NSEqualRects(previousBounds, bounds)) {
    [self.controller syncBrowserFrames];
  }
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self.controller syncBrowserFrames];
}

- (void)layout {
  [super layout];
  [self.controller syncBrowserFrames];
}

@end

@implementation BrowserTabController {
  __weak BrowserTabHostView *_hostView;
  std::map<std::string, TabRecord> _tabRecords;
  NSString *_activeTabID;
}

- (instancetype)initWithHostView:(BrowserTabHostView *)hostView {
  self = [super init];
  if (self == nil) {
    return nil;
  }

  _hostView = hostView;
  _hostView.controller = self;
  return self;
}

- (NSString *)createTabWithURLString:(NSString *)urlString makeActive:(BOOL)makeActive {
  NSString *resolvedURLString =
      urlString.length > 0 ? [urlString copy] : @"about:blank";
  NSString *tabID = NSUUID.UUID.UUIDString;
  std::string tabKey = ToStdString(tabID);

  CefRefPtr<CefClient> client =
      new BrowserTabClient(self, tabKey);

  TabRecord record;
  record.client = client;
  _tabRecords[tabKey] = record;

  if (makeActive || _activeTabID == nil) {
    _activeTabID = [tabID copy];
  }

  [self.delegate browserTabController:self
                      didCreateTabWithID:tabID
                                   title:DefaultTitleForURLString(resolvedURLString)
                               urlString:resolvedURLString];

  CefWindowInfo windowInfo;
  windowInfo.SetAsChild((__bridge CefWindowHandle)_hostView,
                        CefRectFromBounds(_hostView.bounds));
  if (shared::IsAlloyStyleEnabled()) {
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  }

  CefBrowserHost::CreateBrowser(windowInfo, client, ToStdString(resolvedURLString),
                                CefBrowserSettings(), nullptr, nullptr);
  [self updateBrowserVisibility];
  return tabID;
}

- (void)selectTabWithID:(NSString *)tabID {
  _activeTabID = [tabID copy];
  [self updateBrowserVisibility];
}

- (void)reloadActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  ReloadBrowserOnUI(it->second.browser, false);
}

- (void)reloadActiveTabIgnoringCache {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  ReloadBrowserOnUI(it->second.browser, true);
}

- (void)closeTabWithID:(NSString *)tabID {
  std::string tabKey = ToStdString(tabID);
  auto it = _tabRecords.find(tabKey);
  if (it == _tabRecords.end()) {
    return;
  }

  if (it->second.browser) {
    it->second.browser->GetHost()->CloseBrowser(false);
    return;
  }

  _tabRecords.erase(tabKey);
  [self.delegate browserTabController:self didCloseTabWithID:tabID];
  [self updateBrowserVisibility];
}

- (void)closeAllTabs {
  std::vector<CefRefPtr<CefBrowser>> browsers;
  browsers.reserve(_tabRecords.size());
  for (const auto &entry : _tabRecords) {
    if (entry.second.browser) {
      browsers.push_back(entry.second.browser);
    }
  }

  for (const auto &browser : browsers) {
    browser->GetHost()->CloseBrowser(false);
  }
}

- (void)hostViewDidLayout {
  [self syncBrowserFrames];
}

- (void)syncBrowserFrames {
  for (const auto &entry : _tabRecords) {
    SyncBrowserViewFrame(_hostView, entry.second.browser);
  }
}

- (void)handleBrowserCreated:(CefRefPtr<CefBrowser>)browser
                     forTabID:(NSString *)tabID {
  std::string tabKey = ToStdString(tabID);
  auto it = _tabRecords.find(tabKey);
  if (it == _tabRecords.end()) {
    browser->GetHost()->CloseBrowser(false);
    return;
  }

  it->second.browser = browser;
  SyncBrowserViewFrame(_hostView, browser);

  if (it->second.pending_close) {
    browser->GetHost()->CloseBrowser(false);
    return;
  }

  [self updateBrowserVisibility];
}

- (void)handleBrowserClosedForTabID:(NSString *)tabID {
  std::string tabKey = ToStdString(tabID);
  _tabRecords.erase(tabKey);

  if ([_activeTabID isEqualToString:tabID]) {
    if (_tabRecords.empty()) {
      _activeTabID = nil;
    } else {
      _activeTabID = ToNSString(_tabRecords.begin()->first);
    }
  }

  [self.delegate browserTabController:self didCloseTabWithID:tabID];
  [self updateBrowserVisibility];
}

- (void)handleTitleChange:(NSString *)title forTabID:(NSString *)tabID {
  if (title.length == 0) {
    return;
  }

  [self.delegate browserTabController:self
                      didUpdateTabWithID:tabID
                                   title:title
                               urlString:nil
                        faviconURLString:nil];
}

- (void)handleAddressChange:(NSString *)urlString forTabID:(NSString *)tabID {
  if (urlString.length == 0) {
    return;
  }

  [self.delegate browserTabController:self
                      didUpdateTabWithID:tabID
                                   title:nil
                               urlString:urlString
                        faviconURLString:nil];
}

- (void)handleFaviconURLChange:(NSString *)faviconURLString
                      forTabID:(NSString *)tabID {
  [self.delegate browserTabController:self
                      didUpdateTabWithID:tabID
                                   title:nil
                               urlString:nil
                        faviconURLString:faviconURLString];
}

- (void)openPopupTabWithURLString:(NSString *)urlString {
  [self createTabWithURLString:urlString.length > 0 ? urlString : @"about:blank"
                    makeActive:YES];
}

- (void)updateBrowserVisibility {
  std::string activeKey = ToStdString(_activeTabID);
  for (const auto &entry : _tabRecords) {
    NSView *browserView = BrowserViewForBrowser(entry.second.browser);
    if (browserView == nil) {
      continue;
    }

    BOOL isActive = entry.first == activeKey;
    browserView.hidden = !isActive;
    SyncBrowserViewFrame(_hostView, entry.second.browser);

    if (isActive) {
      entry.second.browser->GetHost()->SetFocus(true);
    }
  }
}

@end

namespace {

void BrowserTabClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       const CefString &url) {
  CEF_REQUIRE_UI_THREAD();

  if (!frame->IsMain()) {
    return;
  }

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    return;
  }

  [controller handleAddressChange:ToNSString(url.ToString())
                         forTabID:ToNSString(tab_id_)];
}

void BrowserTabClient::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                     const CefString &title) {
  CEF_REQUIRE_UI_THREAD();

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    return;
  }

  [controller handleTitleChange:ToNSString(title.ToString())
                       forTabID:ToNSString(tab_id_)];
}

void BrowserTabClient::OnFaviconURLChange(
    CefRefPtr<CefBrowser> browser,
    const std::vector<CefString> &icon_urls) {
  CEF_REQUIRE_UI_THREAD();

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    return;
  }

  NSString *faviconURLString = nil;
  if (!icon_urls.empty()) {
    faviconURLString = ToNSString(icon_urls.front().ToString());
  }

  [controller handleFaviconURLChange:faviconURLString
                            forTabID:ToNSString(tab_id_)];
}

void BrowserTabClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();

  shared::ClientManager::GetInstance()->OnAfterCreated(browser);

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    browser->GetHost()->CloseBrowser(false);
    return;
  }

  [controller handleBrowserCreated:browser forTabID:ToNSString(tab_id_)];
}

bool BrowserTabClient::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  shared::ClientManager::GetInstance()->DoClose(browser);
  return false;
}

void BrowserTabClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();

  shared::ClientManager::GetInstance()->OnBeforeClose(browser);

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    return;
  }

  [controller handleBrowserClosedForTabID:ToNSString(tab_id_)];
}

bool BrowserTabClient::OnBeforePopup(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    int popup_id,
    const CefString &target_url,
    const CefString &target_frame_name,
    WindowOpenDisposition target_disposition,
    bool user_gesture,
    const CefPopupFeatures &popupFeatures,
    CefWindowInfo &windowInfo,
    CefRefPtr<CefClient> &client,
    CefBrowserSettings &settings,
    CefRefPtr<CefDictionaryValue> &extra_info,
    bool *no_javascript_access) {
  CEF_REQUIRE_UI_THREAD();

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    return false;
  }

  NSString *urlString = ToNSString(target_url.ToString());
  [controller openPopupTabWithURLString:urlString];
  return true;
}

bool BrowserTabClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    const CefString &requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
  CEF_REQUIRE_UI_THREAD();

  if (!IsNotificationsOnlyRequest(requested_permissions)) {
    return false;
  }

  NSString *origin =
      [NSString stringWithUTF8String:requesting_origin.ToString().c_str()];
  BrowserRequestNotificationPermission(origin, ^(BOOL granted) {
    ContinuePermissionRequestOnUI(callback,
                                  granted ? CEF_PERMISSION_RESULT_ACCEPT
                                          : CEF_PERMISSION_RESULT_DENY);
  });
  return true;
}

}  // namespace
