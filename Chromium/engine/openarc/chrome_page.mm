// OpenArc's pages on Chrome's framework. Based on Cra's engine bridge
// (https://github.com/VictorKildahl/cra, MIT License).
//
// Shape: one hidden Chrome Browser per profile holds that profile's pages as background tabs, behind a blank
// first tab that keeps the Browser open while OpenArc has no page in it. Each of OpenArc's pages carries
// views::OpenArcHostedPageKey, so Chrome's (never shown) window never attaches its view
// (patches/hosted-pages.patch); OpenArc puts the view in its own windows. Chrome's tab helpers (favicons, find,
// zoom, permissions, autofill, passkeys, extensions) attach to the pages as they do to Chrome's own tabs.

#import "openarc/chrome_page.h"

#include <objc/runtime.h>

#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/process/kill.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/values.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/devtools/devtools_toggle_action.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/openarc_engine_hooks.h"
#include "chrome/browser/openarc_permission_hooks.h"
#include "chrome/browser/printing/print_view_manager_common.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_muted_utils.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/common/chrome_constants.h"
#include "components/download/public/common/download_item.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "components/find_in_page/find_result_observer.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_types.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/tabs/public/tab_interface.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "components/zoom/zoom_controller.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_item_utils.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/media_player_id.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_details.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/ssl_status.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/isolated_world_ids.h"
#include "net/cert/x509_certificate.h"
#include "net/cert/x509_util.h"
#include "third_party/blink/public/common/input/web_input_event.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "ui/base/base_window.h"
#include "ui/base/page_transition_types.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image.h"
#include "ui/views/controls/webview/openarc_hosted_page.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"
#include "url/gurl.h"

#include "openarc/page_session.h"
#include "openarc/permission_prompt.h"
#include "openarc/tab_pages.h"

@interface OpenArcChromePage ()
- (void)adoptContents:(content::WebContents*)contents;
- (content::WebContents*)contents;
- (void)pageTitleChanged;
- (void)pageAddressChanged;
- (void)pageLoadingChanged;
- (void)pageFavicon:(NSString*)urlString;
- (void)pageFindResult:(const find_in_page::FindNotificationDetails&)details;
- (void)pageMediaChanged;
- (void)pageFocused;
- (void)pageRenderProcessGone:(int)status;
- (void)pageDestroyed;
- (void)reportDownload:(NSDictionary<NSString*, id>*)info;
@end

namespace {

NSString* NS(const std::string& text) {
  return base::SysUTF8ToNSString(text);
}

std::string UTF8(NSString* text) {
  return text ? base::SysNSStringToUTF8(text) : std::string();
}

// Pages by their contents, for the hooks, which Chrome calls with contents.
std::map<content::WebContents*, OpenArcChromePage* __weak>& PagesByContents() {
  static auto* pages = new std::map<content::WebContents*, OpenArcChromePage* __weak>();
  return *pages;
}

OpenArcChromePage* PageFor(const content::WebContents* contents) {
  auto it = PagesByContents().find(const_cast<content::WebContents*>(contents));
  return it == PagesByContents().end() ? nil : it->second;
}

// The page used last in each profile: a download or a tab no page of OpenArc's opened (an extension's) goes there.
std::map<content::BrowserContext*, OpenArcChromePage* __weak>& LastPages() {
  static auto* pages = new std::map<content::BrowserContext*, OpenArcChromePage* __weak>();
  return *pages;
}

bool g_quitting = false;
// Set while OpenArc adds a page of its own to a host's tab strip, so the host doesn't take it for a popup.
bool g_adding_own_page = false;

void Later(base::OnceClosure task) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, std::move(task));
}

// A Browser's window that holds OpenArc's pages: never seen, never clicked, never captured, never key or main.
// It follows the OpenArc window in use as a child window of the same frame, so what Chrome anchors to it (a
// JavaScript dialog, an extension's popup, a permission bubble) shows over OpenArc's window.
NSHashTable<NSWindow*>* g_host_windows = nil;

// Gives a window class its own implementation of a method, built from the one it answers with now. A method the
// class only inherits is added to it, so NSWindow and Chrome's other window classes keep theirs.
void ReplaceWindowMethod(Class cls, SEL selector, id (^make)(IMP original, SEL selector)) {
  Method method = class_getInstanceMethod(cls, selector);
  if (!method) {
    return;
  }
  IMP replacement = imp_implementationWithBlock(make(method_getImplementation(method), selector));
  if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
    method_setImplementation(method, replacement);
  }
}

void MakeHostWindow(NSWindow* window) {
  if (!window) {
    return;
  }
  window.alphaValue = 0;
  window.ignoresMouseEvents = YES;
  // A transparent window that ignores mouse events still gets its tracking areas' moves and enters, so
  // Chrome's views under the pointer (a tab and its hover card) would react to it over OpenArc's window.
  NSView* content = window.contentView;
  for (NSTrackingArea* area in content.trackingAreas) {
    [content removeTrackingArea:area];
  }
  window.sharingType = NSWindowSharingNone;
  window.animationBehavior = NSWindowAnimationBehaviorNone;
  // Out of the Window menu, ⌘` and Mission Control: the window is OpenArc's machinery, not a window of its own.
  window.excludedFromWindowsMenu = YES;
  NSWindowCollectionBehavior behavior = window.collectionBehavior;
  behavior &= ~(NSWindowCollectionBehaviorFullScreenPrimary | NSWindowCollectionBehaviorFullScreenAllowsTiling);
  behavior |= NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle |
              NSWindowCollectionBehaviorTransient;
  window.collectionBehavior = behavior;
  if (!g_host_windows) {
    g_host_windows = [NSHashTable weakObjectsHashTable];
  }
  // Once per class: Chrome's window class answers NO for the host windows, and they ignore mouse events for good,
  // whatever Chrome sets later.
  static NSMutableSet<NSString*>* patched = [NSMutableSet set];
  Class cls = [window class];
  if (![patched containsObject:NSStringFromClass(cls)]) {
    [patched addObject:NSStringFromClass(cls)];
    using BoolIMP = BOOL (*)(id, SEL);
    for (NSString* name in @[ @"canBecomeKeyWindow", @"canBecomeMainWindow" ]) {
      ReplaceWindowMethod(cls, NSSelectorFromString(name), ^id(IMP imp, SEL selector) {
        BoolIMP original = reinterpret_cast<BoolIMP>(imp);
        return ^BOOL(id me) {
          return [g_host_windows containsObject:me] ? NO : original(me, selector);
        };
      });
    }
    // Only the setter: the getter keeps reporting the window's real state.
    ReplaceWindowMethod(cls, @selector(setIgnoresMouseEvents:), ^id(IMP imp, SEL selector) {
      using SetIMP = void (*)(id, SEL, BOOL);
      SetIMP original = reinterpret_cast<SetIMP>(imp);
      return ^(id me, BOOL ignores) {
        original(me, selector, [g_host_windows containsObject:me] ? YES : ignores);
      };
    });
  }
  [g_host_windows addObject:window];
}

// The hidden Browser that holds a profile's pages, and what arrives in it that OpenArc didn't put there: a page's
// popup or a link opened in a new tab, which becomes an OpenArc tab through the opener's delegate.
class PageHost : public TabStripModelObserver {
 public:
  explicit PageHost(BrowserWindowInterface* browser) : browser_(browser) {
    // Never navigated, so the blank page has no renderer process.
    std::unique_ptr<content::WebContents> blank =
        content::WebContents::Create(content::WebContents::CreateParams(browser->GetProfile()));
    placeholder_ = blank.get();
    browser->GetTabStripModel()->AppendWebContents(std::move(blank), /*foreground=*/true);
    browser->GetTabStripModel()->AddObserver(this);
    MakeHostWindow(window());
  }

  BrowserWindowInterface* browser() { return browser_; }

  NSWindow* window() {
    return browser_ ? browser_->GetWindow()->GetNativeWindow().GetNativeNSWindow() : nil;
  }

  // Rides along with the OpenArc window of the page in use, as a child of the same frame.
  void FollowWindow(NSWindow* openarc) {
    NSWindow* hidden = window();
    if (!hidden || !openarc || hidden == openarc) {
      return;
    }
    if (hidden.parentWindow != openarc) {
      [hidden.parentWindow removeChildWindow:hidden];
      [openarc addChildWindow:hidden ordered:NSWindowAbove];
    }
    if (!NSEqualRects(hidden.frame, openarc.frame)) {
      [hidden setFrame:openarc.frame display:NO];
    }
  }

  void KeepPlaceholderActive() {
    TabStripModel* tabs = browser_->GetTabStripModel();
    int index = tabs->GetIndexOfWebContents(placeholder_);
    if (index != TabStripModel::kNoTab && tabs->active_index() != index) {
      tabs->ActivateTabAt(index);
    }
  }

  // Takes the page out of the tab strip and destroys it, without its unload handlers.
  void Destroy(content::WebContents* contents) {
    TabStripModel* tabs = browser_ ? browser_->GetTabStripModel() : nullptr;
    int index = tabs ? tabs->GetIndexOfWebContents(contents) : TabStripModel::kNoTab;
    if (index == TabStripModel::kNoTab) {
      return;
    }
    tabs->DetachAndDeleteWebContentsAt(index);
  }

  void OnTabStripModelChanged(TabStripModel* model,
                              const TabStripModelChange& change,
                              const TabStripSelectionChange& selection) override {
    if (change.type() != TabStripModelChange::kInserted || g_adding_own_page) {
      return;
    }
    for (const auto& inserted : change.GetInsert()->contents) {
      content::WebContents* page = inserted.contents;
      if (page == placeholder_ || PageFor(page)) {
        continue;
      }
      content::WebContents* opener = nullptr;
      if (content::RenderFrameHost* frame = page->GetOpener()) {
        opener = content::WebContents::FromRenderFrameHost(frame);
      }
      if (!opener) {
        if (tabs::TabInterface* tab = model->GetOpenerOfTabAt(inserted.index)) {
          opener = tab->GetContents();
        }
      }
      bool background = model->GetActiveWebContents() != page;
      Later(base::BindOnce(&PageHost::Adopt, base::Unretained(this), page->GetWeakPtr(),
                           opener ? opener->GetWeakPtr() : base::WeakPtr<content::WebContents>(), background));
    }
  }

  void OnTabStripModelDestroyed(TabStripModel* model) override;

 private:
  void Adopt(base::WeakPtr<content::WebContents> page, base::WeakPtr<content::WebContents> opener, bool background) {
    if (!page || !browser_) {
      return;
    }
    if (!background) {
      KeepPlaceholderActive();
    }
    OpenArcChromePage* from = opener ? PageFor(opener.get()) : nil;
    if (!from && opener) {
      // A link a page's DevTools opened (a source's address) is a tab from the page they inspect.
      if (DevToolsWindow* devtools = DevToolsWindow::AsDevToolsWindow(opener.get())) {
        from = PageFor(devtools->GetInspectedWebContents());
      }
    }
    if (!from) {
      // No page of OpenArc's opened it (an extension's chrome.tabs.create): the profile's last page takes it.
      auto last = LastPages().find(page->GetBrowserContext());
      from = last == LastPages().end() ? nil : last->second;
    }
    id<BrowserChromePageDelegate> delegate = from.delegate;
    if (!delegate) {
      Destroy(page.get());
      return;
    }
    OpenArcChromePage* opened = [[OpenArcChromePage alloc] initWithURLString:@""
                                                                  profilePath:nil
                                                                    ephemeral:NO
                                                                     delegate:nil];
    [opened adoptContents:page.get()];
    [delegate chromePage:from didOpenPage:opened inBackground:background];
  }

  raw_ptr<BrowserWindowInterface> browser_;
  raw_ptr<content::WebContents> placeholder_ = nullptr;
};

std::map<Profile*, PageHost*>& Hosts() {
  static auto* hosts = new std::map<Profile*, PageHost*>();
  return *hosts;
}

void PageHost::OnTabStripModelDestroyed(TabStripModel* model) {
  for (auto it = Hosts().begin(); it != Hosts().end(); ++it) {
    if (it->second == this) {
      Hosts().erase(it);
      break;
    }
  }
  browser_ = nullptr;
  placeholder_ = nullptr;
}

PageHost* HostOf(content::WebContents* contents) {
  for (auto& [profile, host] : Hosts()) {
    if (host->browser() &&
        host->browser()->GetTabStripModel()->GetIndexOfWebContents(contents) != TabStripModel::kNoTab) {
      return host;
    }
  }
  return nullptr;
}

PageHost* HostFor(Profile* profile) {
  auto it = Hosts().find(profile);
  if (it != Hosts().end() && it->second->browser() && !it->second->browser()->IsDeleteScheduled()) {
    return it->second;
  }
  if (it != Hosts().end()) {
    Hosts().erase(it);
  }
  if (g_quitting || browser_shutdown::IsTryingToQuit() || browser_shutdown::HasShutdownStarted()) {
    return nullptr;
  }
  BrowserWindowInterface* browser = CreateBrowserWindow(BrowserWindowCreateParams(*profile, false));
  if (!browser) {
    return nullptr;
  }
  if (views::Widget* widget = views::Widget::GetWidgetForNativeWindow(browser->GetWindow()->GetNativeWindow())) {
    widget->SetNativeWindowProperty(views::kOpenArcPageHostWindow, widget);
    // Chrome adds the content view's tracking area again when the window moves or changes level; its views
    // take no mouse event either way, so nothing in the window hovers.
    widget->GetRootView()->SetCanProcessEventsWithinSubtree(false);
  }
  auto* host = new PageHost(browser);
  Hosts()[profile] = host;
  return host;
}

base::FilePath ProfileDir(NSString* profilePath) {
  ProfileManager* profiles = g_browser_process->profile_manager();
  if (profilePath.length) {
    return base::FilePath(UTF8(profilePath));
  }
  return profiles->user_data_dir().AppendASCII(chrome::kInitialProfile);
}

class PageObserver : public content::WebContentsObserver,
                     public favicon::FaviconDriverObserver,
                     public find_in_page::FindResultObserver {
 public:
  PageObserver(content::WebContents* contents, OpenArcChromePage* owner)
      : content::WebContentsObserver(contents), owner_(owner) {
    if (auto* favicons = favicon::ContentFaviconDriver::FromWebContents(contents)) {
      favicons->AddObserver(this);
      favicons_ = favicons;
    }
    if (auto* find = find_in_page::FindTabHelper::FromWebContents(contents)) {
      find->AddObserver(this);
      find_ = find;
    }
  }

  ~PageObserver() override {
    if (favicons_) {
      favicons_->RemoveObserver(this);
    }
    if (find_) {
      find_->RemoveObserver(this);
    }
  }

  bool audible() const { return audible_; }
  bool playing() const { return !playing_.empty(); }
  bool video() const { return video_; }

  // favicon::FaviconDriverObserver:
  void OnFaviconUpdated(favicon::FaviconDriver* driver,
                        NotificationIconType type,
                        const GURL& icon_url,
                        bool icon_url_changed,
                        const gfx::Image& image) override {
    if (type == NON_TOUCH_16_DIP && icon_url.is_valid()) {
      [owner_ pageFavicon:NS(icon_url.spec())];
    }
  }

  // find_in_page::FindResultObserver:
  void OnFindResultAvailable(content::WebContents* contents) override {
    if (find_) {
      [owner_ pageFindResult:find_->find_result()];
    }
  }
  void OnFindTabHelperDestroyed(find_in_page::FindTabHelper* helper) override { find_ = nullptr; }

  // content::WebContentsObserver:
  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame()) {
      [owner_ pageAddressChanged];
    }
  }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame()) {
      [owner_ pageAddressChanged];
      // A page Back or Forward restores from the back-forward cache sets no title, so TitleWasSet never comes.
      if (handle->HasCommitted()) {
        [owner_ pageTitleChanged];
      }
      [owner_ pageLoadingChanged];
    }
  }
  void NavigationEntryCommitted(const content::LoadCommittedDetails& details) override {
    [owner_ pageLoadingChanged];
  }
  void DidStartLoading() override { [owner_ pageLoadingChanged]; }
  void DidStopLoading() override { [owner_ pageLoadingChanged]; }
  void TitleWasSet(content::NavigationEntry* entry) override { [owner_ pageTitleChanged]; }
  void OnAudioStateChanged(bool audible) override {
    audible_ = audible;
    [owner_ pageMediaChanged];
  }
  void MediaStartedPlaying(const MediaPlayerInfo& info, const content::MediaPlayerId& id) override {
    playing_.insert(id);
    video_ = video_ || info.has_video;
    [owner_ pageMediaChanged];
  }
  void MediaStoppedPlaying(const MediaPlayerInfo& info,
                           const content::MediaPlayerId& id,
                           WebContentsObserver::MediaStoppedReason reason) override {
    playing_.erase(id);
    if (playing_.empty()) {
      video_ = false;
    }
    [owner_ pageMediaChanged];
  }
  void OnWebContentsFocused(content::RenderWidgetHost* widget) override { [owner_ pageFocused]; }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus status) override {
    [owner_ pageRenderProcessGone:static_cast<int>(status)];
  }
  void WebContentsDestroyed() override { [owner_ pageDestroyed]; }

 private:
  OpenArcChromePage* __weak owner_;
  raw_ptr<favicon::ContentFaviconDriver> favicons_ = nullptr;
  raw_ptr<find_in_page::FindTabHelper> find_ = nullptr;
  bool audible_ = false;
  bool video_ = false;
  std::set<content::MediaPlayerId> playing_;
};

// Keys in OpenArc's pages (patches/browser-delegate.patch): the app's shortcuts before the page, the rest after
// it; what both leave goes to the menu bar, where Copy, Paste and Undo are Edit menu items sent to the page.
int KeyEvent(content::WebContents* contents, const input::NativeWebKeyboardEvent& event, bool unhandled) {
  OpenArcChromePage* page = PageFor(contents);
  if (!page) {
    // A page's DevTools: their keys are the page's, as in Chrome.
    if (DevToolsWindow* devtools = DevToolsWindow::AsDevToolsWindow(contents)) {
      page = PageFor(devtools->GetInspectedWebContents());
      if (!page) {
        return -1;
      }
      if (!unhandled) {
        return 0;
      }
      NSEvent* key = event.os_event.Get();
      return key && [NSApp.mainMenu performKeyEquivalent:key] ? 1 : 0;
    }
    return -1;
  }
  NSEvent* key = event.os_event.Get();
  // Modifier-only presses arrive as flagsChanged, and each press comes as a raw key down and a char.
  if (!key || key.type != NSEventTypeKeyDown || event.GetType() != blink::WebInputEvent::Type::kRawKeyDown) {
    return 0;
  }
  id<BrowserChromePageDelegate> delegate = page.delegate;
  if (!unhandled) {
    return [delegate chromePage:page handleKeyEvent:key unhandled:NO] ? 1 : 0;
  }
  if ([delegate chromePage:page handleKeyEvent:key unhandled:YES]) {
    return 1;
  }
  return [NSApp.mainMenu performKeyEquivalent:key] ? 1 : 0;
}

bool PageFullscreen(content::WebContents* contents, bool enter) {
  OpenArcChromePage* page = PageFor(contents);
  if (!page) {
    return false;
  }
  if (page.inPageFullscreen == enter) {
    return true;
  }
  page.inPageFullscreen = enter;
  [page.delegate webKitPage:page didChangeFullscreen:enter];
  // The page lays out at its new size once it knows its fullscreen state.
  Later(base::BindOnce(
      [](base::WeakPtr<content::WebContents> contents) {
        if (contents) {
          if (content::RenderWidgetHostView* view = contents->GetRenderWidgetHostView()) {
            view->GetRenderWidgetHost()->SynchronizeVisualProperties();
          }
        }
      },
      contents->GetWeakPtr()));
  return true;
}

int PageIsFullscreen(const content::WebContents* contents) {
  OpenArcChromePage* page = PageFor(contents);
  return page ? (page.inPageFullscreen ? 1 : 0) : -1;
}

bool TargetURL(content::WebContents* contents, const GURL& url) {
  OpenArcChromePage* page = PageFor(contents);
  if (!page) {
    return false;
  }
  [page.delegate chromePage:page didChangeStatus:url.is_valid() ? NS(url.spec()) : @""];
  return true;
}

// Downloads of OpenArc's profiles, for the page that started each (else the profile's last page).
class DownloadsWatch : public content::DownloadManager::Observer, public download::DownloadItem::Observer {
 public:
  void Watch(Profile* profile) {
    content::DownloadManager* manager = profile->GetDownloadManager();
    if (!manager || managers_.count(manager)) {
      return;
    }
    managers_.insert(manager);
    manager->AddObserver(this);
  }

  void Cancel(uint32_t identifier) {
    for (content::DownloadManager* manager : managers_) {
      if (download::DownloadItem* item = manager->GetDownload(identifier)) {
        item->Cancel(/*user_cancel=*/true);
        return;
      }
    }
  }

  // content::DownloadManager::Observer:
  void OnDownloadCreated(content::DownloadManager* manager, download::DownloadItem* item) override {
    // Chrome makes an item for every download in the profile's history as it starts; only new ones are news.
    if (item->GetState() != download::DownloadItem::IN_PROGRESS) {
      return;
    }
    item->AddObserver(this);
    Report(item);
  }
  void ManagerGoingDown(content::DownloadManager* manager) override {
    manager->RemoveObserver(this);
    managers_.erase(manager);
  }

  // download::DownloadItem::Observer:
  void OnDownloadUpdated(download::DownloadItem* item) override {
    Report(item);
    if (item->IsDone()) {
      item->RemoveObserver(this);
    }
  }
  void OnDownloadDestroyed(download::DownloadItem* item) override { item->RemoveObserver(this); }

 private:
  void Report(download::DownloadItem* item) {
    OpenArcChromePage* page = PageFor(content::DownloadItemUtils::GetWebContents(item));
    if (!page) {
      auto last = LastPages().find(content::DownloadItemUtils::GetBrowserContext(item));
      page = last == LastPages().end() ? nil : last->second;
    }
    // The app's BrowserDownloadState raw values, as the CEF bridge reports them.
    NSString* state = @"inProgress";
    switch (item->GetState()) {
      case download::DownloadItem::COMPLETE:
        state = @"completed";
        break;
      case download::DownloadItem::CANCELLED:
        state = @"canceled";
        break;
      case download::DownloadItem::INTERRUPTED:
        state = @"interrupted";
        break;
      default:
        break;
    }
    NSDictionary<NSString*, id>* info = @{
      @"id" : [NSString stringWithFormat:@"chrome-%u", item->GetId()],
      @"fileName" : NS(item->GetFileNameToReportUser().value()),
      @"url" : NS(item->GetURL().spec()),
      @"fullPath" : NS(item->GetTargetFilePath().value()),
      @"receivedBytes" : @(item->GetReceivedBytes()),
      @"totalBytes" : @(item->GetTotalBytes()),
      @"currentSpeed" : @(item->CurrentSpeed()),
      @"state" : state,
    };
    [page reportDownload:info];
  }

  std::set<raw_ptr<content::DownloadManager>> managers_;
};

DownloadsWatch& Downloads() {
  static auto* watch = new DownloadsWatch();
  return *watch;
}

NSData* PNGData(const SkBitmap& bitmap) {
  std::optional<std::vector<uint8_t>> png = gfx::PNGCodec::EncodeBGRASkBitmap(bitmap, /*discard_transparency=*/false);
  return png ? [NSData dataWithBytes:png->data() length:png->size()] : nil;
}

NSString* TextOfValue(const base::Value& value) {
  if (value.is_none()) {
    return nil;
  }
  if (value.is_string()) {
    return NS(value.GetString());
  }
  if (value.is_bool()) {
    return value.GetBool() ? @"true" : @"false";
  }
  if (value.is_int()) {
    return [NSString stringWithFormat:@"%d", value.GetInt()];
  }
  if (value.is_double()) {
    return [NSString stringWithFormat:@"%g", value.GetDouble()];
  }
  return nil;
}

}  // namespace

namespace openarc {

// OpenArc's throttles: its tabs open only the chrome:// pages that work in a tab.
void NavigationThrottles(content::NavigationThrottleRegistry& registry) {
  content::NavigationHandle& handle = registry.GetNavigationHandle();
  if (handle.IsInPrimaryMainFrame() && PageFor(handle.GetWebContents())) {
    registry.AddThrottle(CreateTabPageThrottle(registry));
  }
}

// A permission prompt for one of OpenArc's pages shows in OpenArc's window, as on CEF.
std::unique_ptr<permissions::PermissionPrompt> PagePermissionPrompt(content::WebContents* contents,
                                                                    permissions::PermissionPrompt::Delegate* delegate) {
  OpenArcChromePage* page = PageFor(contents);
  if (!page) {
    return nullptr;
  }
  return CreatePermissionPrompt(page, page.delegate, delegate);
}

void StartPages() {
  g_key_event = &KeyEvent;
  g_page_fullscreen = &PageFullscreen;
  g_page_is_fullscreen = &PageIsFullscreen;
  g_target_url = &TargetURL;
  g_navigation_throttles = &NavigationThrottles;
  g_permission_prompt = &PagePermissionPrompt;
}

void StopPages() {
  g_quitting = true;
}

void CancelDownload(NSString* downloadID) {
  NSString* prefix = @"chrome-";
  if (![downloadID hasPrefix:prefix]) {
    return;
  }
  Downloads().Cancel(static_cast<uint32_t>([downloadID substringFromIndex:prefix.length].longLongValue));
}

}  // namespace openarc

#pragma mark - OpenArcChromePage

@implementation OpenArcChromePage {
  NSView* _container;
  raw_ptr<content::WebContents> _contents;
  std::unique_ptr<PageObserver> _observer;
  std::unique_ptr<openarc::PageSession> _session;
  NSString* _profilePath;
  BOOL _ephemeral;
  NSString* _pendingURL;
  // The address the page starts on (about:blank for a tab's page), until the app loads its own.
  NSString* _startURL;
  NSString* _currentURL;
  NSString* _title;
  // The page shows something: the app loaded an address in it, or Chrome made it for a page that opened it.
  BOOL _hasPage;
  BOOL _isLoading;
  BOOL _canGoBack;
  BOOL _canGoForward;
  BOOL _audioMuted;
  BOOL _closed;
  BOOL _pendingFocus;
  BOOL _reportedAudible;
  BOOL _reportedPlaying;
  BOOL _reportedVideo;
  double _mediaVolume;
}

@synthesize delegate = _delegate;
@synthesize inPageFullscreen = _inPageFullscreen;

- (instancetype)initWithURLString:(NSString*)urlString
                      profilePath:(NSString*)profilePath
                        ephemeral:(BOOL)ephemeral
                         delegate:(id<BrowserChromePageDelegate>)delegate {
  self = [super init];
  if (!self) {
    return nil;
  }
  _delegate = delegate;
  _profilePath = [profilePath copy];
  _ephemeral = ephemeral;
  _container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  _container.wantsLayer = YES;
  _container.autoresizesSubviews = YES;
  _currentURL = urlString ?: @"";
  _title = @"";
  _mediaVolume = 1;
  if (urlString.length == 0) {
    return self;  // Contents arrive through -adoptContents: (a page's popup).
  }
  _pendingURL = [urlString copy];
  _startURL = _pendingURL;
  if (g_quitting || !g_browser_process || !g_browser_process->profile_manager()) {
    return self;
  }
  ProfileManager* profiles = g_browser_process->profile_manager();
  base::FilePath dir = ProfileDir(_profilePath);
  if (Profile* profile = profiles->GetProfileByPath(dir)) {
    [self createPageInProfile:profile];
  } else {
    OpenArcChromePage* __weak weakSelf = self;
    profiles->CreateProfileAsync(dir, base::BindOnce(^(Profile* loaded) {
                                   if (loaded) {
                                     [weakSelf createPageInProfile:loaded];
                                   }
                                 }));
  }
  return self;
}

- (void)dealloc {
  [self close];
}

- (void)createPageInProfile:(Profile*)profile {
  if (_closed || g_quitting) {
    return;
  }
  if (_ephemeral) {
    profile = profile->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  }
  PageHost* host = HostFor(profile);
  if (!host) {
    return;
  }
  std::unique_ptr<content::WebContents> made =
      content::WebContents::Create(content::WebContents::CreateParams(profile));
  content::WebContents* contents = made.get();
  g_adding_own_page = true;
  host->browser()->GetTabStripModel()->AppendWebContents(std::move(made), /*foreground=*/false);
  g_adding_own_page = false;
  [self contentsCreated:contents];
  NSString* url = _pendingURL;
  _pendingURL = nil;
  if (url.length) {
    const BOOL hadPage = _hasPage;
    [self loadWithUrlString:url];
    // The blank page a tab's page starts on is no page of its own.
    if (url == _startURL) {
      _hasPage = hadPage;
    }
  }
}

- (void)adoptContents:(content::WebContents*)contents {
  _hasPage = YES;
  [self contentsCreated:contents];
  [self pageTitleChanged];
}

- (content::WebContents*)contents {
  return _contents;
}

- (void)contentsCreated:(content::WebContents*)contents {
  _contents = contents;
  contents->SetUserData(views::OpenArcHostedPageKey(), std::make_unique<base::SupportsUserData::Data>());
  _observer = std::make_unique<PageObserver>(contents, self);
  PagesByContents()[contents] = self;
  Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  Downloads().Watch(profile->GetOriginalProfile());
  if (profile->IsOffTheRecord()) {
    Downloads().Watch(profile);
  }
  if (_audioMuted) {
    SetTabAudioMuted(contents, true, TabMutedReason::kAudioIndicator, std::string());
  }
  NSView* page = contents->GetNativeView().GetNativeNSView();
  [page removeFromSuperview];
  page.frame = _container.bounds;
  page.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [_container addSubview:page];
  // A page made hidden (a background tab) gets a hidden view, which Chrome's own view host would unhide as it
  // attaches the page. OpenArc's pages never attach there, so the page shows and hides with OpenArc's container.
  page.hidden = NO;
  [self pageAddressChanged];
  [self pageLoadingChanged];
  if (_pendingFocus) {
    _pendingFocus = NO;
    [self focus];
  }
}

#pragma mark Page events

- (void)pageTitleChanged {
  if (!_contents) {
    return;
  }
  // The blank page a page starts on, and stays on when the first address loads nothing, has no title: Chrome's
  // would be "about:blank", and the tab keeps its own, as on CEF.
  if (!_hasPage) {
    return;
  }
  NSString* title = base::SysUTF16ToNSString(_contents->GetTitle());
  if ([title isEqualToString:_title]) {
    return;
  }
  _title = title;
  [_delegate webKitPageDidChangeTitle:self];
}

- (void)pageAddressChanged {
  if (!_contents) {
    return;
  }
  GURL visible = _contents->GetVisibleURL();
  if (visible.is_empty()) {
    return;
  }
  NSString* url = NS(visible.spec());
  if ([url isEqualToString:_currentURL]) {
    return;
  }
  _currentURL = url;
  [_delegate webKitPageDidChangeURL:self];
}

- (void)pageLoadingChanged {
  if (!_contents) {
    return;
  }
  content::NavigationController& history = _contents->GetController();
  BOOL loading = _contents->IsLoading();
  BOOL back = history.CanGoBack();
  BOOL forward = history.CanGoForward();
  if (loading != _isLoading) {
    _isLoading = loading;
    [_delegate webKitPageDidChangeLoading:self];
  }
  if (back != _canGoBack || forward != _canGoForward) {
    _canGoBack = back;
    _canGoForward = forward;
    [_delegate webKitPageDidChangeNavigationState:self];
  }
}

- (void)pageFavicon:(NSString*)urlString {
  [_delegate webKitPage:self didChangeFaviconURLString:urlString];
}

- (void)pageFindResult:(const find_in_page::FindNotificationDetails&)details {
  [_delegate chromePage:self
         didFindMatches:details.number_of_matches()
          activeOrdinal:details.active_match_ordinal()
            finalUpdate:details.final_update()];
}

- (void)pageMediaChanged {
  if (!_observer) {
    return;
  }
  BOOL audible = _observer->audible();
  BOOL playing = _observer->playing();
  BOOL video = _observer->video();
  if (audible == _reportedAudible && playing == _reportedPlaying && video == _reportedVideo) {
    return;
  }
  _reportedAudible = audible;
  _reportedPlaying = playing;
  _reportedVideo = video;
  [_delegate webKitPage:self didChangeMediaAudible:audible playing:playing paused:NO video:video title:@""];
}

- (void)pageFocused {
  if (_contents) {
    LastPages()[_contents->GetBrowserContext()] = self;
    if (PageHost* host = HostOf(_contents)) {
      host->FollowWindow(_container.window);
      // Chrome's active tab follows the page in use, so extensions see the tab the user is on.
      TabStripModel* tabs = host->browser()->GetTabStripModel();
      int index = tabs->GetIndexOfWebContents(_contents);
      if (index != TabStripModel::kNoTab && tabs->active_index() != index) {
        tabs->ActivateTabAt(index);
      }
    }
  }
  [_delegate webKitPageDidBecomeFocused:self];
}

- (void)pageRenderProcessGone:(int)status {
  [_delegate chromePage:self renderProcessTerminatedWithErrorCode:status];
}

- (void)pageDestroyed {
  if (_contents) {
    PagesByContents().erase(_contents);
  }
  _observer.reset();
  _session.reset();
  _contents = nullptr;
  if (!_closed) {
    // Chrome closed the page itself: the page's script (window.close()) or an extension. A page Chrome
    // closes as it quits keeps its tab for the next launch.
    _closed = YES;
    if (!g_quitting && !browser_shutdown::IsTryingToQuit() && !browser_shutdown::HasShutdownStarted()) {
      [_delegate webKitPageDidRequestClose:self];
    }
  }
}

- (void)reportDownload:(NSDictionary<NSString*, id>*)info {
  [_delegate chromePage:self didUpdateDownload:info];
}

#pragma mark BrowserPeerPage

- (NSView*)view {
  return _container;
}

- (NSString*)title {
  return _title.length ? _title : _currentURL;
}

- (NSString*)urlString {
  return _currentURL ?: @"";
}

- (BOOL)isLoading {
  return _isLoading;
}

- (BOOL)canGoBack {
  return _canGoBack;
}

- (BOOL)canGoForward {
  return _canGoForward;
}

- (BOOL)isFullscreen {
  return _inPageFullscreen;
}

- (double)zoomLevel {
  return _contents ? zoom::ZoomController::GetZoomLevelForWebContents(_contents) : 0;
}

- (NSArray<NSDictionary<NSString*, NSString*>*>*)navigationEntries {
  NSMutableArray* entries = [NSMutableArray array];
  if (!_contents) {
    return entries;
  }
  content::NavigationController& history = _contents->GetController();
  for (int i = 0; i < history.GetEntryCount(); ++i) {
    content::NavigationEntry* entry = history.GetEntryAtIndex(i);
    [entries addObject:@{
      @"url" : NS(entry->GetURL().spec()),
      @"title" : base::SysUTF16ToNSString(entry->GetTitleForDisplay()),
    }];
  }
  return entries;
}

- (NSInteger)currentNavigationIndex {
  return _contents ? _contents->GetController().GetCurrentEntryIndex() : 0;
}

- (NSArray<NSData*>*)certificateChain {
  NSMutableArray<NSData*>* chain = [NSMutableArray array];
  content::NavigationEntry* entry = _contents ? _contents->GetController().GetLastCommittedEntry() : nullptr;
  if (!entry || !entry->GetSSL().certificate) {
    return chain;
  }
  const net::X509Certificate* certificate = entry->GetSSL().certificate.get();
  base::span<const uint8_t> leaf = net::x509_util::CryptoBufferAsSpan(certificate->cert_buffer());
  [chain addObject:[NSData dataWithBytes:leaf.data() length:leaf.size()]];
  for (const auto& buffer : certificate->intermediate_buffers()) {
    base::span<const uint8_t> bytes = net::x509_util::CryptoBufferAsSpan(buffer.get());
    [chain addObject:[NSData dataWithBytes:bytes.data() length:bytes.size()]];
  }
  return chain;
}

- (int)rendererProcessID {
  if (!_contents) {
    return 0;
  }
  content::RenderProcessHost* process = _contents->GetPrimaryMainFrame()->GetProcess();
  return process && process->GetProcess().IsValid() ? process->GetProcess().Pid() : 0;
}

- (void)loadWithUrlString:(NSString*)urlString {
  if (!_contents) {
    _pendingURL = [urlString copy];
    return;
  }
  GURL url(UTF8(urlString));
  if (!url.is_valid() || !openarc::OpensInTab(_contents->GetBrowserContext(), url)) {
    return;
  }
  _hasPage = YES;
  content::NavigationController::LoadURLParams params(url);
  params.transition_type = ui::PageTransitionFromInt(ui::PAGE_TRANSITION_TYPED | ui::PAGE_TRANSITION_FROM_ADDRESS_BAR);
  _contents->GetController().LoadURLWithParams(params);
  [self pageAddressChanged];
}

- (void)goBack {
  if (_contents && _contents->GetController().CanGoBack()) {
    _contents->GetController().GoBack();
  }
}

- (void)goForward {
  if (_contents && _contents->GetController().CanGoForward()) {
    _contents->GetController().GoForward();
  }
}

- (void)goToHistoryOffset:(NSInteger)offset {
  if (_contents && _contents->GetController().CanGoToOffset(static_cast<int>(offset))) {
    _contents->GetController().GoToOffset(static_cast<int>(offset));
  }
}

- (void)reloadWithIgnoringCache:(BOOL)ignoringCache {
  if (_contents) {
    _contents->GetController().Reload(
        ignoringCache ? content::ReloadType::BYPASSING_CACHE : content::ReloadType::NORMAL, true);
  }
}

- (void)stopLoading {
  if (_contents) {
    _contents->Stop();
  }
}

- (void)focus {
  if (!_contents) {
    _pendingFocus = YES;
    return;
  }
  _contents->Focus();
}

- (void)evaluate:(NSString*)script completion:(void (^)(NSString*))completion {
  void (^done)(NSString*) = [completion copy];
  if (!_contents) {
    done(nil);
    return;
  }
  _contents->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
      base::SysNSStringToUTF16(script), base::BindOnce(^(base::Value value) {
        done(TextOfValue(value));
      }),
      content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)executeDevToolsMethod:(NSString*)method
                       params:(NSString*)paramsJSON
                   completion:(void (^)(NSString*))completion {
  if (!_contents) {
    void (^done)(NSString*) = [completion copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      done(nil);
    });
    return;
  }
  if (!_session) {
    _session = std::make_unique<openarc::PageSession>(_contents);
  }
  _session->Send(UTF8(method), UTF8(paramsJSON), completion);
}

- (void)find:(NSString*)text forward:(BOOL)forward matchCase:(BOOL)matchCase {
  [self findText:text forward:forward matchCase:matchCase findNext:YES];
}

- (void)findText:(NSString*)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext {
  auto* find = _contents ? find_in_page::FindTabHelper::FromWebContents(_contents) : nullptr;
  if (!find) {
    return;
  }
  find->StartFinding(base::SysNSStringToUTF16(text), forward, matchCase, /*find_match=*/true);
}

- (void)stopFinding {
  [self stopFindingClearingSelection:NO];
}

- (void)stopFindingClearingSelection:(BOOL)clearSelection {
  auto* find = _contents ? find_in_page::FindTabHelper::FromWebContents(_contents) : nullptr;
  if (find) {
    find->StopFinding(clearSelection ? find_in_page::SelectionAction::kClear
                                     : find_in_page::SelectionAction::kKeep);
  }
}

- (void)setAudioMuted:(BOOL)muted {
  _audioMuted = muted;
  if (_contents) {
    SetTabAudioMuted(_contents, muted, TabMutedReason::kAudioIndicator, std::string());
  }
}

- (void)setMediaVolume:(double)volume {
  _mediaVolume = volume;
  NSString* script = [NSString
      stringWithFormat:@"document.querySelectorAll('audio,video').forEach(function(m){m.volume=%g;})", volume];
  [self evaluate:script
      completion:^(NSString*){
      }];
}

- (void)controlMedia:(NSString*)action {
  content::MediaSession* session = _contents ? content::MediaSession::Get(_contents) : nullptr;
  if (!session) {
    return;
  }
  if ([action isEqualToString:@"play"]) {
    session->Resume(content::MediaSession::SuspendType::kUI);
  } else if ([action isEqualToString:@"pause"]) {
    session->Suspend(content::MediaSession::SuspendType::kUI);
  } else if ([action isEqualToString:@"previoustrack"]) {
    session->PreviousTrack();
  } else if ([action isEqualToString:@"nexttrack"]) {
    session->NextTrack();
  }
}

- (void)togglePictureInPicture {
  if (!_contents) {
    return;
  }
  _contents->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      u"(function(){if(document.pictureInPictureElement){document.exitPictureInPicture();return;}"
      u"var v=Array.from(document.querySelectorAll('video')).find(function(e){return !e.paused;})"
      u"||document.querySelector('video');if(v)v.requestPictureInPicture();})()",
      base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)exitFullscreen {
  if (_contents) {
    _contents->ExitFullscreen(/*will_cause_resize=*/true);
  }
}

- (void)selectedTextWithCompletion:(void (^)(NSString*))completion {
  void (^done)(NSString*) = [completion copy];
  [self evaluate:@"window.getSelection().toString()"
      completion:^(NSString* text) {
        done(text.length ? text : nil);
      }];
}

- (void)capturePictureWithCompletion:(void (^)(NSData*))completion {
  [self capturePictureWithFraction:CGRectMake(0, 0, 1, 1) completion:completion];
}

- (void)capturePictureWithFraction:(CGRect)fraction completion:(void (^)(NSData*))completion {
  void (^done)(NSData*) = [completion copy];
  content::RenderWidgetHostView* view = _contents ? _contents->GetRenderWidgetHostView() : nullptr;
  if (!view) {
    done(nil);
    return;
  }
  gfx::Size size = view->GetViewBounds().size();
  gfx::Rect source(static_cast<int>(fraction.origin.x * size.width()),
                   static_cast<int>(fraction.origin.y * size.height()),
                   static_cast<int>(fraction.size.width * size.width()),
                   static_cast<int>(fraction.size.height * size.height()));
  if (source.IsEmpty()) {
    done(nil);
    return;
  }
  view->CopyFromSurface(source, gfx::Size(), base::Seconds(5),
                        base::BindOnce(^(const content::CopyFromSurfaceResult& result) {
                          done(result.has_value() ? PNGData(result->bitmap) : nil);
                        }));
}

- (void)print {
  if (_contents) {
    printing::StartPrint(_contents, /*print_preview_disabled=*/false, /*has_selection=*/false);
  }
}

- (void)close {
  if (_closed) {
    return;
  }
  _closed = YES;
  _delegate = nil;
  content::WebContents* contents = _contents;
  if (!contents) {
    return;
  }
  PagesByContents().erase(contents);
  _observer.reset();
  _session.reset();
  _contents = nullptr;
  if (PageHost* host = HostOf(contents)) {
    host->Destroy(contents);
  }
}

#pragma mark BrowserChromePage

- (void)setZoomLevel:(double)zoomLevel {
  if (auto* zoom = _contents ? zoom::ZoomController::FromWebContents(_contents) : nullptr) {
    zoom->SetZoomLevel(zoomLevel);
  }
}

- (void)showDevToolsPanel:(NSString*)panel {
  if (!_contents) {
    return;
  }
  if ([panel isEqualToString:@"console"]) {
    DevToolsWindow::OpenDevToolsWindow(_contents, DevToolsToggleAction::ShowConsolePanel(),
                                       DevToolsOpenedByAction::kMainMenuOrMainShortcut);
  } else if ([panel isEqualToString:@"inspect"]) {
    DevToolsWindow::OpenDevToolsWindow(_contents, DevToolsToggleAction::Inspect(),
                                       DevToolsOpenedByAction::kMainMenuOrMainShortcut);
  } else {
    DevToolsWindow::OpenDevToolsWindow(_contents, DevToolsToggleAction::Show(),
                                       DevToolsOpenedByAction::kMainMenuOrMainShortcut);
  }
}

- (void)setPageVisible:(BOOL)visible {
  // Chrome follows the page view's own visibility in OpenArc's window.
}

- (BOOL)sendAction:(SEL)action {
  content::RenderWidgetHostView* view = _contents ? _contents->GetRenderWidgetHostView() : nullptr;
  NSView* target = view ? view->GetNativeView().GetNativeNSView() : nil;
  if (!target) {
    return NO;
  }
  return [NSApp sendAction:action to:target from:nil];
}

@end
