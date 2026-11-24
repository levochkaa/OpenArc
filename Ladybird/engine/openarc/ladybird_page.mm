/*
 * OpenArcLadybirdPage: a tab's page on Ladybird. It wraps Ladybird's LadybirdWebView in a container the tab
 * controller places in OpenArc's windows, answers BrowserChromePage, and reports Ladybird's page events to the
 * tab controller as BrowserChromePageDelegate calls.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <AK/Base64.h>
#include <AK/JsonArray.h>
#include <AK/JsonObject.h>
#include <AK/JsonValue.h>
#include <AK/LexicalPath.h>
#include <AK/String.h>
#include <LibCore/Promise.h>
#include <LibGfx/Bitmap.h>
#include <LibURL/Parser.h>
#include <LibURL/URL.h>
#include <LibWebView/Application.h>
#include <LibWebView/Menu.h>
#include <LibWebView/URL.h>
#include <LibWebCommon/Geolocation/GeolocationPositionErrorCode.h>
#include <LibWebView/Settings.h>
#include <LibWebView/ViewImplementation.h>
#include <LibWebView/WebContentPage.h>

#import <Interface/Event.h>
#import <UserNotifications/UserNotifications.h>
#import <Interface/LadybirdWebView.h>
#import <Utilities/Conversions.h>

#import "openarc/ladybird_page.h"

#if !__has_feature(objc_arc)
#    error "This project requires ARC"
#endif

static NSString* (^s_scheme_page_provider)(NSString*, NSInteger*) = nil;
static __weak OpenArcLadybirdPage* s_last_focused_page = nil;
static NSHashTable<OpenArcLadybirdPage*>* s_open_pages = nil;
// Each site's answers to OpenArc's permission prompts ("location https://example.com"), for as long as the app runs.
static NSMutableDictionary<NSString*, NSNumber*>* s_site_decisions = nil;
static uint64_t s_next_permission_prompt_id = 0;
// Ladybird asks for a new page's handle by reference; the new page stays alive here until the run loop turns,
// even if the tab controller had no tab for it.
static NSMutableArray<OpenArcLadybirdPage*>* s_pages_being_opened = nil;

// Ladybird's internal pages the app opens under openarc:// (as Chromium's are on the other engines).
static constexpr auto s_internal_hosts = Array { "settings"sv, "history"sv, "bookmarks"sv, "downloads"sv, "version"sv, "about"sv, "newtab"sv, "blocking"sv, "services"sv };

@class OpenArcLadybirdPage;

// LadybirdWebView with OpenArc's keys first: the tab controller takes Escape out of fullscreen before the page sees
// it, and is told when the page takes focus.
@interface OpenArcLadybirdWebView : LadybirdWebView
@property (nonatomic, weak) OpenArcLadybirdPage* openArcPage;
@end

// The tab's view: the container the tab controller sizes and moves between windows, with the web view filling it.
@interface OpenArcLadybirdContainerView : NSView
@property (nonatomic, weak) OpenArcLadybirdPage* page;
@property (nonatomic, weak) NSWindow* observedWindow;
@end

@interface OpenArcLadybirdPage () <LadybirdWebViewObserver>
- (void)webViewDidBecomeFirstResponder;
- (BOOL)handleKeyEventBeforePage:(NSEvent*)event;
- (void)askForPermission:(NSString*)kind then:(void (^)(NSNumber* _Nullable allowed))then;
- (void)showNotificationWithTitle:(NSString*)title body:(NSString*)body tag:(NSString*)tag;
- (void)bringToFront;
- (NSArray*)accessibilityElementsForWebView:(NSView*)webView;
- (void)refreshAccessibility;
- (void)pressElementWithRole:(NSString*)role name:(NSString*)name occurrence:(NSInteger)occurrence;
- (void)containerDidResize;
- (void)containerDidMoveToWindow:(NSWindow*)window;
- (void)windowDidChangeOcclusionState;
@end

// Shows a page's notifications in the app, as banners even while OpenArc is in front, and brings the page's window
// forward when one is clicked. Installed only when the app has no notification delegate of its own.
@interface OpenArcLadybirdNotifications : NSObject <UNUserNotificationCenterDelegate>
@end

static NSString* const OpenArcLadybirdPageKey = @"OpenArcLadybirdPage";

@implementation OpenArcLadybirdNotifications

+ (void)installIfNeeded
{
    static OpenArcLadybirdNotifications* s_shared = nil;
    auto* center = [UNUserNotificationCenter currentNotificationCenter];
    if (s_shared != nil || center.delegate != nil)
        return;
    s_shared = [OpenArcLadybirdNotifications new];
    center.delegate = s_shared;
}

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    (void)center;
    (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList | UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
    didReceiveNotificationResponse:(UNNotificationResponse*)response
             withCompletionHandler:(void (^)(void))completionHandler
{
    (void)center;
    NSString* page_id = response.notification.request.content.userInfo[OpenArcLadybirdPageKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (OpenArcLadybirdPage* page in s_open_pages) {
            if ([[NSString stringWithFormat:@"%p", page] isEqualToString:page_id]) {
                [page bringToFront];
                break;
            }
        }
    });
    completionHandler();
}

@end

// One node of a page's accessibility tree, as LibWeb reports it: its role and name, read in document order. Ladybird
// reports no positions, so each node covers the page; links, buttons and form controls press through the page.
@interface OpenArcLadybirdAccessibleNode : NSAccessibilityElement
@property (nonatomic, weak) OpenArcLadybirdPage* page;
@property (nonatomic, weak) NSView* webView;
@property (nonatomic, copy) NSString* webRole;
@property (nonatomic, copy) NSString* name;
@property (nonatomic) NSInteger occurrence;
@end

@implementation OpenArcLadybirdAccessibleNode

- (NSRect)accessibilityFrame
{
    NSView* view = self.webView;
    return view.window != nil ? NSAccessibilityFrameInView(view, view.bounds) : NSZeroRect;
}

- (BOOL)isAccessibilityElement
{
    return YES;
}

- (BOOL)accessibilityPerformPress
{
    static NSSet<NSString*>* pressable = [NSSet setWithArray:@[ @"link", @"button", @"checkbox", @"radio", @"switch", @"menuitem", @"tab", @"option" ]];
    if (![pressable containsObject:self.webRole])
        return NO;
    [self.page pressElementWithRole:self.webRole name:self.name occurrence:self.occurrence];
    return YES;
}

@end

@implementation OpenArcLadybirdWebView

- (NSAccessibilityRole)accessibilityRole
{
    return NSAccessibilityGroupRole;
}

- (NSString*)accessibilityLabel
{
    return self.openArcPage.title;
}

- (NSArray*)accessibilityChildren
{
    return [self.openArcPage accessibilityElementsForWebView:self] ?: @[];
}

- (BOOL)becomeFirstResponder
{
    BOOL became = [super becomeFirstResponder];
    if (became)
        [self.openArcPage webViewDidBecomeFirstResponder];
    return became;
}

- (BOOL)performKeyEquivalent:(NSEvent*)event
{
    if ([event window] == [self window] && [[self window] firstResponder] == self && [self.openArcPage handleKeyEventBeforePage:event])
        return YES;
    return [super performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent*)event
{
    if ([self.openArcPage handleKeyEventBeforePage:event])
        return;
    [super keyDown:event];
}

@end

@implementation OpenArcLadybirdContainerView

- (BOOL)isFlipped
{
    return YES;
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [self.page containerDidResize];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self.page containerDidMoveToWindow:[self window]];
}

- (void)viewDidHide
{
    [super viewDidHide];
    [self.page windowDidChangeOcclusionState];
}

- (void)viewDidUnhide
{
    [super viewDidUnhide];
    [self.page windowDidChangeOcclusionState];
}

@end

namespace OpenArc {

OpenArcLadybirdPage* last_focused_page()
{
    OpenArcLadybirdPage* page = s_last_focused_page;
    if (page != nil)
        return page;
    return [[s_open_pages allObjects] lastObject];
}

NSArray<OpenArcLadybirdPage*>* open_pages()
{
    return [s_open_pages allObjects] ?: @[];
}

void set_scheme_page_provider(NSString* (^provider)(NSString*, NSInteger*))
{
    s_scheme_page_provider = [provider copy];
}

void open_url_in_new_tab_from_page(OpenArcLadybirdPage* page, NSString* url_string, BOOL in_background)
{
    if (page == nil)
        return;
    [page.delegate webKitPage:page openURLStringInNewTab:url_string inBackground:in_background];
}

}

static NSString* json_string(NSString* string)
{
    auto* data = [NSJSONSerialization dataWithJSONObject:string ?: @"" options:NSJSONWritingFragmentsAllowed error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"\"\"";
}

// Keeps what the page's sign-in fields hold, and whether a form with them was sent, in window.__openArcSignIn; answers
// whether the document has a password field, and its address.
static NSString* const s_sign_in_watch_script = @"(() => {"
     " const field = (root) => [...(root || document).querySelectorAll('input[type=password]')];"
     " const userFor = (pass) => { const inputs = [...(pass.form || document).querySelectorAll('input')];"
     "   return inputs.slice(0, inputs.indexOf(pass)).reverse().find((i) => i.autocomplete === 'username' || /^(text|email|tel)$/.test(i.type)); };"
     " if (!window.__openArcSignIn) {"
     "   window.__openArcSignIn = { u: '', p: '', submitted: false };"
     "   const grab = (root) => { const pass = field(root).find((i) => i.value); if (!pass) return false;"
     "     const user = userFor(pass); const state = window.__openArcSignIn;"
     "     state.u = user ? user.value : state.u; state.p = pass.value; state.url = location.href; return true; };"
     "   document.addEventListener('input', () => { grab(); }, true);"
     "   document.addEventListener('submit', (e) => { if (grab(e.target)) window.__openArcSignIn.submitted = true; }, true);"
     "   document.addEventListener('keydown', (e) => { if (e.key === 'Enter' && e.target && e.target.type === 'password' && grab()) window.__openArcSignIn.submitted = true; }, true);"
     "   document.addEventListener('click', (e) => { const b = e.target && e.target.closest && e.target.closest('button, input[type=submit]');"
     "     if (b && grab()) window.__openArcSignIn.submitted = true; }, true);"
     " }"
     " return JSON.stringify({ form: field().length > 0, url: location.href, state: window.__openArcSignIn });"
     "})()";

static NSData* png_data_for_image(NSImage* image)
{
    auto* cg_image = [image CGImageForProposedRect:nil context:nil hints:nil];
    if (cg_image == nil)
        return nil;
    auto* representation = [[NSBitmapImageRep alloc] initWithCGImage:cg_image];
    return [representation representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

// Ladybird's geolocation handler, shared by the blocks that wait for OpenArc's prompt.
struct RefCountedFunction final : public RefCounted<RefCountedFunction> {
    explicit RefCountedFunction(Function<void(WebView::WebContentPage&, u64)> function)
        : function(move(function))
    {
    }

    Function<void(WebView::WebContentPage&, u64)> function;
};

// Reports Back and Forward turning on or off as the page's navigation state.
struct NavigationActionObserver final : public WebView::Action::Observer {
    explicit NavigationActionObserver(OpenArcLadybirdPage* page)
        : page(page)
    {
    }

    virtual void on_enabled_state_changed(WebView::Action&) override
    {
        OpenArcLadybirdPage* strong_page = page;
        if (strong_page != nil)
            [strong_page.delegate webKitPageDidChangeNavigationState:strong_page];
    }

    __weak OpenArcLadybirdPage* page;
};

// One evaluation in flight per page: Ladybird reports a console input's result through one callback.
struct PendingEvaluation {
    NSString* script;
    void (^completion)(NSString* _Nullable result, BOOL answered);
};

@implementation OpenArcLadybirdPage {
    OpenArcLadybirdContainerView* _container;
    OpenArcLadybirdWebView* _webView;
    NSString* _profilePath;
    BOOL _ephemeral;
    BOOL _closed;
    // The page's accessibility tree as AppKit elements, and when it was last asked for.
    NSArray* _accessibilityElements;
    NSDate* _accessibilityRefreshed;
    BOOL _accessibilityRefreshing;
    BOOL _fullscreen;
    BOOL _visible;
    // openarc:// pages Ladybird shows from the app's HTML: the address the tab shows while the page is up.
    NSString* _schemeURLString;
    NSString* _lastFindText;
    BOOL _lastFindMatchCase;
    Vector<PendingEvaluation> _evaluations;
    BOOL _evaluationInFlight;
    u64 _evaluationGeneration;
    double _mediaVolume;
    BOOL _audioMuted;
    // Sign-ins: the page has a password field, the address it was reported for, and what its fields held last.
    NSTimer* _signInTimer;
    NSString* _reportedPasswordFormURL;
    NSString* _signInURL;
    NSString* _signInUsername;
    NSString* _signInPassword;
}

@synthesize delegate = _delegate;

+ (void)initialize
{
    if (self == [OpenArcLadybirdPage class]) {
        s_open_pages = [NSHashTable weakObjectsHashTable];
        s_pages_being_opened = [NSMutableArray array];
        s_site_decisions = [NSMutableDictionary dictionary];
    }
}

- (instancetype)initWithURLString:(NSString*)urlString
                      profilePath:(NSString*)profilePath
                        ephemeral:(BOOL)ephemeral
                         delegate:(id<BrowserChromePageDelegate>)delegate
{
    if (self = [super init]) {
        [self setUpWithProfilePath:profilePath ephemeral:ephemeral delegate:delegate];
        _webView = [[OpenArcLadybirdWebView alloc] init:self isPrivate:ephemeral ? WebView::IsPrivate::Yes : WebView::IsPrivate::No];
        [self finishSetUp];
        if (urlString.length > 0)
            [self loadWithUrlString:urlString];
    }
    return self;
}

- (instancetype)initAsChildOfPage:(OpenArcLadybirdPage*)parent
                      pageProcess:(WebView::WebContentClient&)page_process
                        pageIndex:(Compositing::PageId)page_index
{
    if (self = [super init]) {
        [self setUpWithProfilePath:parent->_profilePath ephemeral:parent->_ephemeral delegate:parent.delegate];
        _webView = [[OpenArcLadybirdWebView alloc] initAsChild:self parent:parent.webView pageProcess:page_process pageIndex:page_index];
        [self finishSetUp];
    }
    return self;
}

- (void)setUpWithProfilePath:(NSString*)profilePath ephemeral:(BOOL)ephemeral delegate:(id<BrowserChromePageDelegate>)delegate
{
    _profilePath = [profilePath copy];
    _ephemeral = ephemeral;
    _delegate = delegate;
    _visible = YES;
    _mediaVolume = 1;
    _container = [[OpenArcLadybirdContainerView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    _container.page = self;
    _container.wantsLayer = YES;
    [s_open_pages addObject:self];
}

- (void)finishSetUp
{
    _webView.openArcPage = self;
    [_webView setFrame:[_container bounds]];
    [_webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_container addSubview:_webView];
    [self overrideWebViewCallbacks];
}

- (LadybirdWebView*)webView
{
    return _webView;
}

- (BOOL)isEphemeral
{
    return _ephemeral;
}

#pragma mark - Ladybird's callbacks OpenArc answers itself

- (void)overrideWebViewCallbacks
{
    auto& view = [_webView view];
    __weak OpenArcLadybirdPage* weak_self = self;

    // The tab controller shows the link under the pointer in its own status line.
    view.on_link_hover = [weak_self](URL::URL const& url) {
        OpenArcLadybirdPage* self = weak_self;
        if (self == nil)
            return;
        [self.delegate chromePage:self didChangeStatus:Ladybird::string_to_ns_string(url.serialize())];
    };
    view.on_link_unhover = [weak_self]() {
        OpenArcLadybirdPage* self = weak_self;
        if (self == nil)
            return;
        [self.delegate chromePage:self didChangeStatus:@""];
    };

    // window.close() asks the tab to close; OpenArc's window stays.
    view.on_close = [weak_self]() {
        OpenArcLadybirdPage* self = weak_self;
        if (self == nil)
            return;
        [self.delegate webKitPageDidRequestClose:self];
    };

    // A page moves, sizes, minimizes or raises no OpenArc window.
    view.on_activate_tab = nullptr;
    view.on_reposition_window = nullptr;
    view.on_resize_window = nullptr;
    view.on_maximize_window = nullptr;
    view.on_minimize_window = nullptr;
    view.on_restore_window = nullptr;

    // Keys the page left alone go to the tab controller, then to the main menu as Ladybird's own view sends them: the
    // view ignores the event while it goes round again. Ladybird hands each key's NSEvent out once.
    view.on_finish_handling_key_event = [weak_self](Compositing::KeyEvent const& key_event) {
        OpenArcLadybirdPage* self = weak_self;
        if (self == nil)
            return;
        auto* event = Ladybird::key_event_to_ns_event(key_event);
        if (event == nil)
            return;
        if ([event type] == NSEventTypeKeyDown && [self.delegate chromePage:self handleKeyEvent:event unhandled:YES])
            return;
        [self->_webView setValue:event forKey:@"event_being_redispatched"];
        [NSApp sendEvent:event];
        [self->_webView setValue:nil forKey:@"event_being_redispatched"];
    };

    // Ladybird's renderer went away: Ladybird's view closes its dialogs and shows its reload overlay, and the tab
    // controller learns the page crashed.
    auto crashed = move(view.on_web_content_crashed);
    view.on_web_content_crashed = [weak_self, crashed = move(crashed)](auto reason) mutable {
        if (crashed)
            crashed(reason);
        OpenArcLadybirdPage* self = weak_self;
        if (self == nil)
            return;
        // Chromium's TERMINATION_STATUS_PROCESS_CRASHED.
        [self.delegate chromePage:self renderProcessTerminatedWithErrorCode:2];
    };

    // A site's location goes through OpenArc's prompt first, as on the other engines; Ladybird reads it from Core
    // Location once the site may have it.
    using GeolocationHandler = Function<void(WebView::WebContentPage&, u64)>;
    auto gate_location = [weak_self](GeolocationHandler handler) {
        auto shared_handler = make_ref_counted<RefCountedFunction>(move(handler));
        return [weak_self, shared_handler](WebView::WebContentPage& requesting_page, u64 request_id) {
            OpenArcLadybirdPage* self = weak_self;
            NonnullRefPtr<WebView::WebContentPage> page = requesting_page;
            auto deny = [page, request_id] {
                if (page->is_open())
                    page->async_geolocation_position_response(request_id, {}, to_underlying(Web::Geolocation::GeolocationPositionErrorCode::PermissionDenied));
            };
            if (self == nil) {
                deny();
                return;
            }
            [self askForLocationThen:^(BOOL allowed) {
                if (!allowed) {
                    deny();
                    return;
                }
                if (!page->is_open())
                    return;
                if (!WebView::Application::settings().geolocation_enabled())
                    WebView::Application::settings().set_geolocation_enabled(true);
                shared_handler->function(*page, request_id);
            }];
        };
    };
    view.on_request_geolocation_position = gate_location(move(view.on_request_geolocation_position));
    view.on_start_geolocation_position_watch = gate_location(move(view.on_start_geolocation_position_watch));

    // The microphone and notifications go through OpenArc's prompt too; Ladybird keeps the answer for the site.
    view.on_request_permission = [weak_self](WebView::WebContentPage& requesting_page, u64 request_id, String const& name) {
        OpenArcLadybirdPage* self = weak_self;
        NonnullRefPtr<WebView::WebContentPage> page = requesting_page;
        NSString* kind = nil;
        if (name == "microphone"sv)
            kind = @"microphone";
        else if (name == "camera"sv)
            kind = @"camera";
        else if (name == "notifications"sv)
            kind = @"notifications";
        if (self == nil || kind == nil) {
            page->async_permission_response(request_id, false);
            return;
        }
        [self askForPermission:kind
                          then:^(NSNumber* _Nullable allowed) {
                              if (!page->is_open())
                                  return;
                              Optional<bool> answer;
                              if (allowed != nil)
                                  answer = allowed.boolValue;
                              page->async_permission_response(request_id, answer);
                          }];
    };
    view.on_show_notification = [weak_self](String const& title, String const& body, String const& tag, String const&) {
        OpenArcLadybirdPage* self = weak_self;
        [self showNotificationWithTitle:Ladybird::string_to_ns_string(title.bytes_as_string_view())
                                   body:Ladybird::string_to_ns_string(body.bytes_as_string_view())
                                    tag:Ladybird::string_to_ns_string(tag.bytes_as_string_view())];
    };

    // The navigation state follows the back and forward actions Ladybird keeps for its toolbar.
    view.navigate_back_action().add_observer(make<NavigationActionObserver>(self));
    view.navigate_forward_action().add_observer(make<NavigationActionObserver>(self));
}

#pragma mark - LadybirdWebViewObserver

- (String const&)onCreateNewTab:(Optional<URL::URL> const&)url
                    activateTab:(Web::HTML::ActivateTab)activate_tab
{
    auto* page = [[OpenArcLadybirdPage alloc] initWithURLString:@""
                                                    profilePath:_profilePath
                                                      ephemeral:_ephemeral
                                                       delegate:self.delegate];
    if (url.has_value())
        [page.webView loadURL:*url];
    [self reportOpenedPage:page activateTab:activate_tab];
    return [page.webView handle];
}

- (String const&)onCreateChildTab:(Optional<URL::URL> const&)url
                      activateTab:(Web::HTML::ActivateTab)activate_tab
                      pageProcess:(WebView::WebContentClient&)page_process
                        pageIndex:(Compositing::PageId)page_index
{
    auto* page = [[OpenArcLadybirdPage alloc] initAsChildOfPage:self pageProcess:page_process pageIndex:page_index];
    if (url.has_value())
        [page.webView loadURL:*url];
    [self reportOpenedPage:page activateTab:activate_tab];
    return [page.webView handle];
}

- (void)reportOpenedPage:(OpenArcLadybirdPage*)page activateTab:(Web::HTML::ActivateTab)activate_tab
{
    [s_pages_being_opened addObject:page];
    dispatch_async(dispatch_get_main_queue(), ^{
        [s_pages_being_opened removeObject:page];
    });
    id<BrowserChromePageDelegate> delegate = self.delegate;
    if (delegate == nil) {
        [page close];
        return;
    }
    [delegate chromePage:self didOpenPage:page inBackground:activate_tab == Web::HTML::ActivateTab::No];
}

- (void)onLoadStart
{
    // A sign-in form usually sends itself by navigating; what its fields held goes to the app before the page goes.
    [self reportSignInIfSent:YES];
    [self.delegate webKitPageDidChangeLoading:self];
}

- (void)onLoadFinish
{
    [self.delegate webKitPageDidChangeLoading:self];
    // A navigation that turned into a download leaves the document and its title as they were; the tab shows them
    // again.
    [self.delegate webKitPageDidChangeURL:self];
    [self.delegate webKitPageDidChangeTitle:self];
    [self watchForSignIn];
    // Pages that build their sign-in form with script get a second look.
    __weak OpenArcLadybirdPage* weak_self = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [weak_self watchForSignIn];
    });
    [self.delegate webKitPageDidChangeNavigationState:self];
    [self applyMediaVolume];
    _accessibilityRefreshed = nil;
    if (NSWorkspace.sharedWorkspace.isVoiceOverEnabled)
        [self refreshAccessibility];
}

- (void)onURLChange:(URL::URL const&)url
{
    // An openarc:// page keeps its address while Ladybird shows the app's HTML for it.
    if (_schemeURLString != nil && !url.serialize().starts_with_bytes("about:"sv) && !url.serialize().starts_with_bytes("data:"sv))
        _schemeURLString = nil;
    [self.delegate webKitPageDidChangeURL:self];
    [self.delegate webKitPageDidChangeNavigationState:self];
}

- (void)onTitleChange:(Utf16String const&)title
{
    (void)title;
    [self.delegate webKitPageDidChangeTitle:self];
}

- (void)onFaviconChange:(Optional<Gfx::Bitmap const&>)bitmap
{
    if (!bitmap.has_value()) {
        [self.delegate webKitPage:self didChangeFaviconURLString:nil];
        return;
    }
    auto* image = Ladybird::gfx_bitmap_to_ns_image(*bitmap);
    auto* png = image ? png_data_for_image(image) : nil;
    if (png == nil)
        return;
    // The tab's icon loads through URLSession, which reads data: addresses as they are.
    auto* url = [@"data:image/png;base64," stringByAppendingString:[png base64EncodedStringWithOptions:0]];
    [self.delegate webKitPage:self didChangeFaviconURLString:url];
}

- (void)onAudioPlayStateChange:(Web::HTML::AudioPlayState)play_state
{
    BOOL playing = play_state == Web::HTML::AudioPlayState::Playing;
    BOOL muted = [_webView view].page_mute_state() == Web::HTML::MuteState::Muted;
    [self.delegate webKitPage:self
        didChangeMediaAudible:playing && !muted
                      playing:playing
                       paused:!playing
                        video:NO
                        title:self.title];
}

- (void)onEnterFullscreenWindow
{
    _fullscreen = YES;
    [_webView handleEnteredFullScreen];
    [self.delegate webKitPage:self didChangeFullscreen:YES];
}

- (void)onExitFullscreenWindow
{
    _fullscreen = NO;
    [_webView handleExitedFullScreen];
    [self.delegate webKitPage:self didChangeFullscreen:NO];
}

- (void)onFindInPageResult:(size_t)current_match_index
           totalMatchCount:(Optional<size_t> const&)total_match_count
{
    auto total = total_match_count.value_or(0);
    [self.delegate chromePage:self
               didFindMatches:static_cast<NSInteger>(total)
                activeOrdinal:total > 0 ? static_cast<NSInteger>(current_match_index) : 0
                  finalUpdate:YES];
}

#pragma mark - Site permissions

- (NSString*)siteOrigin
{
    NSURLComponents* components = [NSURLComponents componentsWithString:self.urlString];
    if (components.scheme.length == 0 || components.host.length == 0)
        return self.urlString;
    NSString* origin = [NSString stringWithFormat:@"%@://%@", components.scheme, components.host];
    return components.port ? [origin stringByAppendingFormat:@":%@", components.port] : origin;
}

// Runs `then` with the site's answer to OpenArc's location prompt: remembered, or asked now. A page OpenArc cannot ask
// for (no tab) gets no location.
- (void)askForLocationThen:(void (^)(BOOL allowed))then
{
    [self askForPermission:@"location"
                      then:^(NSNumber* _Nullable allowed) {
                          then(allowed.boolValue);
                      }];
}

// Runs `then` with the site's answer to OpenArc's prompt for `kind` (BrowserSitePermissionKind's raw value): remembered,
// or asked now; nil when the prompt was dismissed or OpenArc could not ask (no tab).
- (void)askForPermission:(NSString*)kind then:(void (^)(NSNumber* _Nullable allowed))then
{
    NSString* origin = [self siteOrigin];
    NSString* key = [NSString stringWithFormat:@"%@ %@", kind, origin];
    if (NSNumber* decision = s_site_decisions[key]) {
        then(decision);
        return;
    }
    id<BrowserChromePageDelegate> delegate = self.delegate;
    BOOL asked = [delegate chromePage:self
          requestSitePermissionPrompt:++s_next_permission_prompt_id
                               origin:origin
                                kinds:@[ kind ]
                             decision:^(NSNumber* _Nullable allowed) {
                                 if (allowed != nil)
                                     s_site_decisions[key] = allowed;
                                 then(allowed);
                             }];
    if (!asked)
        then(nil);
}

#pragma mark - Accessibility

static NSAccessibilityRole ax_role_for(NSString* role)
{
    static NSDictionary<NSString*, NSAccessibilityRole>* roles = @{
        @"link" : NSAccessibilityLinkRole,
        @"button" : NSAccessibilityButtonRole,
        @"heading" : @"AXHeading",
        @"img" : NSAccessibilityImageRole,
        @"image" : NSAccessibilityImageRole,
        @"textbox" : NSAccessibilityTextFieldRole,
        @"searchbox" : NSAccessibilityTextFieldRole,
        @"checkbox" : NSAccessibilityCheckBoxRole,
        @"switch" : NSAccessibilityCheckBoxRole,
        @"radio" : NSAccessibilityRadioButtonRole,
        @"combobox" : NSAccessibilityPopUpButtonRole,
        @"listbox" : NSAccessibilityListRole,
        @"slider" : NSAccessibilitySliderRole,
        @"menuitem" : NSAccessibilityMenuItemRole,
        @"tab" : NSAccessibilityRadioButtonRole,
        @"option" : NSAccessibilityStaticTextRole,
    };
    return roles[role] ?: NSAccessibilityStaticTextRole;
}

// Flattens the tree LibWeb reports into what a reader goes through in order: each named control, heading, link or
// image, and the text between them.
// Elements keep their identity across refreshes (by role, name and position among their namesakes), as assistive
// apps hold on to the ones they read.
static void collect_accessible_nodes(JsonObject const& node, NSMutableArray* out, NSMutableDictionary<NSString*, NSNumber*>* counts, NSDictionary<NSString*, OpenArcLadybirdAccessibleNode*>* previous, OpenArcLadybirdPage* page, NSView* web_view)
{
    static NSSet<NSString*>* leaves = [NSSet setWithArray:@[ @"link", @"button", @"heading", @"img", @"image", @"textbox", @"searchbox", @"checkbox", @"switch", @"radio", @"combobox", @"slider", @"menuitem", @"tab", @"option" ]];
    auto string_of = [&](StringView key) -> NSString* {
        auto value = node.get_string(key);
        return value.has_value() ? Ladybird::string_to_ns_string(value->bytes_as_string_view()) : @"";
    };
    NSString* type = string_of("type"sv);
    NSString* role = string_of("role"sv);
    NSString* name = [string_of("name"sv) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL is_text = [type isEqualToString:@"text"];
    if (is_text || [leaves containsObject:role]) {
        if (is_text && name.length == 0)
            return;
        NSString* web_role = is_text ? @"text" : role;
        NSString* key = [NSString stringWithFormat:@"%@\n%@", web_role, name];
        NSInteger occurrence = counts[key].integerValue;
        counts[key] = @(occurrence + 1);
        if (OpenArcLadybirdAccessibleNode* kept = previous[[NSString stringWithFormat:@"%@\n%ld", key, (long)occurrence]]) {
            [out addObject:kept];
            return;
        }
        OpenArcLadybirdAccessibleNode* element = [OpenArcLadybirdAccessibleNode accessibilityElementWithRole:ax_role_for(web_role) frame:NSZeroRect label:name parent:web_view];
        element.page = page;
        element.webView = web_view;
        element.webRole = web_role;
        element.name = name;
        element.occurrence = occurrence;
        if (is_text)
            [element setAccessibilityValue:name];
        [out addObject:element];
        return;
    }
    if (auto children = node.get_array("children"sv); children.has_value()) {
        children->for_each([&](JsonValue const& child) {
            if (child.is_object())
                collect_accessible_nodes(child.as_object(), out, counts, previous, page, web_view);
        });
    }
}

// What VoiceOver and other assistive apps read: the last tree LibWeb reported, asked for again when it is older than
// two seconds, which posts a layout change once it arrives.
- (NSArray*)accessibilityElementsForWebView:(NSView*)webView
{
    if (_accessibilityRefreshed == nil || -_accessibilityRefreshed.timeIntervalSinceNow > 2)
        [self refreshAccessibility];
    (void)webView;
    return _accessibilityElements;
}

- (void)refreshAccessibility
{
    if (_closed || _accessibilityRefreshing)
        return;
    _accessibilityRefreshing = YES;
    _accessibilityRefreshed = [NSDate date];
    __weak OpenArcLadybirdPage* weak_self = self;
    auto& view = [_webView view];
    view.on_received_accessibility_tree = [weak_self](JsonObject tree) {
        OpenArcLadybirdPage* self = weak_self;
        if (self == nil)
            return;
        [self->_webView view].on_received_accessibility_tree = nullptr;
        self->_accessibilityRefreshing = NO;
        NSMutableDictionary<NSString*, OpenArcLadybirdAccessibleNode*>* previous = [NSMutableDictionary dictionary];
        for (OpenArcLadybirdAccessibleNode* element in self->_accessibilityElements)
            previous[[NSString stringWithFormat:@"%@\n%@\n%ld", element.webRole, element.name, (long)element.occurrence]] = element;
        NSMutableArray* elements = [NSMutableArray array];
        collect_accessible_nodes(tree, elements, [NSMutableDictionary dictionary], previous, self, self->_webView);
        self->_accessibilityElements = elements;
        NSAccessibilityPostNotification(self->_webView, NSAccessibilityLayoutChangedNotification);
    };
    view.inspect_accessibility_tree();
}

// Presses the `occurrence`th element with this role and accessible name, as the reader saw it: the page finds it by
// its text, label or title, which is what its accessible name comes from.
- (void)pressElementWithRole:(NSString*)role name:(NSString*)name occurrence:(NSInteger)occurrence
{
    NSDictionary* arguments = @{ @"role" : role, @"name" : name, @"occurrence" : @(occurrence) };
    NSData* json = [NSJSONSerialization dataWithJSONObject:arguments options:0 error:nil];
    NSString* script = [NSString stringWithFormat:@"(() => {"
                                                   "const a = %@;"
                                                   "const selectors = {link: 'a[href],[role=link]', button: 'button,input[type=button],input[type=submit],input[type=reset],[role=button]',"
                                                   " checkbox: 'input[type=checkbox],[role=checkbox]', radio: 'input[type=radio],[role=radio]', switch: '[role=switch]',"
                                                   " menuitem: '[role=menuitem]', tab: '[role=tab]', option: 'option,[role=option]'};"
                                                   "const norm = s => (s || '').replace(/\\s+/g, ' ').trim();"
                                                   "const nameOf = e => norm(e.getAttribute('aria-label') || e.innerText || e.value || e.title || e.alt);"
                                                   "const found = [...document.querySelectorAll(selectors[a.role] || '*')].filter(e => nameOf(e) === norm(a.name));"
                                                   "const target = found[a.occurrence] || found[0];"
                                                   "if (!target) return '';"
                                                   "if (/^(openarc|chrome):/i.test(target.href || '')) return target.href;"
                                                   "target.focus(); target.click(); return ''; })()",
                                  [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    // A script's click carries no user activation, so Ladybird would not follow a link to the app's own addresses;
    // those load here instead, as the app's own navigations do.
    __weak OpenArcLadybirdPage* weak_self = self;
    [self evaluate:script
        completion:^(NSString* _Nullable result) {
            if ([result hasPrefix:@"openarc:"] || [result hasPrefix:@"chrome:"])
                [weak_self loadWithUrlString:result];
        }];
}

#pragma mark - Notifications

- (void)showNotificationWithTitle:(NSString*)title body:(NSString*)body tag:(NSString*)tag
{
    [OpenArcLadybirdNotifications installIfNeeded];
    NSString* origin = [self siteOrigin];
    auto* content = [UNMutableNotificationContent new];
    content.title = title;
    content.body = body;
    content.subtitle = [NSURL URLWithString:origin].host ?: origin;
    content.sound = UNNotificationSound.defaultSound;
    content.threadIdentifier = origin;
    content.userInfo = @{ OpenArcLadybirdPageKey : [NSString stringWithFormat:@"%p", self] };
    // A tag replaces the site's earlier notification with the same tag, as the spec asks.
    NSString* identifier = tag.length > 0 ? [NSString stringWithFormat:@"%@ %@", origin, tag] : NSUUID.UUID.UUIDString;
    auto* request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

- (void)bringToFront
{
    [NSApp activate];
    NSWindow* window = _container.window;
    [window makeKeyAndOrderFront:nil];
    [self focus];
}

#pragma mark - Sign-ins

// Looks for a password field, tells the app once per document, and follows the fields while there is one.
- (void)watchForSignIn
{
    if (_closed)
        return;
    __weak OpenArcLadybirdPage* weak_self = self;
    [self evaluate:s_sign_in_watch_script completion:^(NSString* _Nullable text) {
        OpenArcLadybirdPage* self = weak_self;
        if (self == nil || self->_closed || text == nil)
            return;
        NSDictionary* answer = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![answer isKindOfClass:[NSDictionary class]])
            return;
        [self takeSignInState:answer[@"state"]];
        NSString* url = answer[@"url"];
        BOOL has_form = [answer[@"form"] boolValue];
        if (has_form && [url isKindOfClass:[NSString class]] && ![url isEqualToString:self->_reportedPasswordFormURL]) {
            self->_reportedPasswordFormURL = url;
            if ([self.delegate respondsToSelector:@selector(chromePage:didFindPasswordFormInFrame:urlString:)])
                [self.delegate chromePage:self didFindPasswordFormInFrame:@"" urlString:url];
        }
        if (has_form && self->_signInTimer == nil) {
            self->_signInTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer* timer) {
                (void)timer;
                [weak_self watchForSignIn];
            }];
        } else if (!has_form && self->_signInPassword.length == 0) {
            [self->_signInTimer invalidate];
            self->_signInTimer = nil;
        }
        [self reportSignInIfSent:NO];
    }];
}

- (void)takeSignInState:(id)state
{
    if (![state isKindOfClass:[NSDictionary class]])
        return;
    NSString* password = state[@"p"];
    if (![password isKindOfClass:[NSString class]] || password.length == 0)
        return;
    _signInPassword = [password copy];
    _signInUsername = [state[@"u"] isKindOfClass:[NSString class]] ? [state[@"u"] copy] : @"";
    _signInURL = [state[@"url"] isKindOfClass:[NSString class]] ? [state[@"url"] copy] : self.urlString;
    if ([state[@"submitted"] boolValue])
        _signInURL = [_signInURL stringByAppendingString:@"\n"];
}

// Hands a sent sign-in to the app, which asks whether to keep it: one the page marked sent, or with `leaving`, the
// last one typed into a page that is navigating away.
- (void)reportSignInIfSent:(BOOL)leaving
{
    BOOL sent = [_signInURL hasSuffix:@"\n"];
    if (_signInPassword.length == 0 || (!sent && !leaving))
        return;
    NSString* url = sent ? [_signInURL substringToIndex:_signInURL.length - 1] : _signInURL;
    NSString* username = _signInUsername ?: @"";
    NSString* password = _signInPassword;
    _signInPassword = nil;
    _signInUsername = nil;
    _signInURL = nil;
    _reportedPasswordFormURL = nil;
    [_signInTimer invalidate];
    _signInTimer = nil;
    if (!sent)
        [_webView view].run_javascript("window.__openArcSignIn = undefined"_string);
    else
        [self evaluate:@"(() => { window.__openArcSignIn = { u: '', p: '', submitted: false }; return 1; })()" completion:^(NSString*) {}];
    if ([self.delegate respondsToSelector:@selector(chromePage:didSubmitPasswordWithURLString:username:password:)])
        [self.delegate chromePage:self didSubmitPasswordWithURLString:url ?: self.urlString username:username password:password];
}

// Fills a saved sign-in into the main frame while it is still on the sign-in's site, as the fields' own typing would.
- (void)fillPasswordInFrame:(NSString*)frameID urlPrefix:(NSString*)urlPrefix username:(NSString*)username password:(NSString*)password
{
    if (frameID.length > 0)
        return;
    auto* script = [NSString stringWithFormat:
                                 @"((prefix, u, p) => { const href = location.href;"
                                  " if (!href.startsWith(prefix) || (href.length > prefix.length && !'/:'.includes(href[prefix.length]))) return false;"
                                  " const pass = [...document.querySelectorAll('input[type=password]')].find((i) => !i.disabled) ; if (!pass) return false;"
                                  " const inputs = [...(pass.form || document).querySelectorAll('input')];"
                                  " const user = inputs.slice(0, inputs.indexOf(pass)).reverse().find((i) => i.autocomplete === 'username' || /^(text|email|tel)$/.test(i.type));"
                                  " const set = (el, v) => { el.focus(); el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); };"
                                  " if (user && u) set(user, u); set(pass, p); return true; })(%@, %@, %@)",
                             json_string(urlPrefix), json_string(username), json_string(password)];
    [self evaluate:script completion:^(NSString*) {}];
}

#pragma mark - Focus and keys

- (void)webViewDidBecomeFirstResponder
{
    s_last_focused_page = self;
    [self.delegate webKitPageDidBecomeFocused:self];
}

- (BOOL)handleKeyEventBeforePage:(NSEvent*)event
{
    if ([event type] != NSEventTypeKeyDown)
        return NO;
    return [self.delegate chromePage:self handleKeyEvent:event unhandled:NO];
}

#pragma mark - The container in OpenArc's windows

- (void)containerDidResize
{
    [_webView handleResize];
}

- (void)containerDidMoveToWindow:(NSWindow*)window
{
    auto* center = [NSNotificationCenter defaultCenter];
    if (NSWindow* old_window = _container.observedWindow) {
        [center removeObserver:self name:nil object:old_window];
    }
    _container.observedWindow = window;
    if (window == nil) {
        [_webView handleVisibility:NO];
        return;
    }
    [center addObserver:self selector:@selector(windowDidMoveOrResize:) name:NSWindowDidMoveNotification object:window];
    [center addObserver:self selector:@selector(windowDidMoveOrResize:) name:NSWindowDidResizeNotification object:window];
    [center addObserver:self selector:@selector(windowDidChangeBacking:) name:NSWindowDidChangeBackingPropertiesNotification object:window];
    [center addObserver:self selector:@selector(windowDidChangeScreen:) name:NSWindowDidChangeScreenNotification object:window];
    [center addObserver:self selector:@selector(windowOcclusionDidChange:) name:NSWindowDidChangeOcclusionStateNotification object:window];
    [_webView handleDevicePixelRatioChange];
    [_webView handleDisplayRefreshRateChange];
    [self windowDidMoveOrResize:nil];
    [self windowDidChangeOcclusionState];
}

- (void)windowDidMoveOrResize:(NSNotification*)notification
{
    (void)notification;
    NSWindow* window = _container.window;
    if (window == nil)
        return;
    auto frame = Ladybird::ns_rect_to_gfx_rect([window frame]);
    [_webView setWindowPosition:frame.location()];
    [_webView setWindowSize:frame.size()];
    [_webView handleResize];
}

- (void)windowDidChangeBacking:(NSNotification*)notification
{
    (void)notification;
    [_webView handleDevicePixelRatioChange];
}

- (void)windowDidChangeScreen:(NSNotification*)notification
{
    (void)notification;
    [_webView handleDisplayRefreshRateChange];
    [_webView handleDevicePixelRatioChange];
}

- (void)windowOcclusionDidChange:(NSNotification*)notification
{
    (void)notification;
    [self windowDidChangeOcclusionState];
}

- (void)windowDidChangeOcclusionState
{
    NSWindow* window = _container.window;
    BOOL on_screen = window != nil && ([window occlusionState] & NSWindowOcclusionStateVisible) != 0 && ![_container isHiddenOrHasHiddenAncestor];
    [_webView handleVisibility:on_screen && _visible];
}

#pragma mark - BrowserPeerPage

- (NSView*)view
{
    return _container;
}

- (NSString*)title
{
    auto const& title = [_webView view].title();
    if (title.is_empty())
        return @"";
    return Ladybird::utf16_string_to_ns_string(title);
}

- (NSString*)urlString
{
    if (_schemeURLString != nil)
        return _schemeURLString;
    auto const& url = [_webView view].url();
    auto serialized = url.serialize();
    // Ladybird's own pages show under openarc://, as Chromium's do on the other engines.
    if (url.scheme() == "about"sv) {
        auto path = url.serialize_path();
        for (auto host : s_internal_hosts) {
            if (path == host)
                return [@"openarc://" stringByAppendingString:Ladybird::string_to_ns_string(host)];
        }
    }
    return Ladybird::string_to_ns_string(serialized);
}

- (BOOL)isLoading
{
    return [_webView view].is_loading();
}

- (BOOL)canGoBack
{
    return [_webView view].navigate_back_action().enabled();
}

- (BOOL)canGoForward
{
    return [_webView view].navigate_forward_action().enabled();
}

- (BOOL)isFullscreen
{
    return _fullscreen;
}

// Chromium's zoom level: 0 is 100 %, each step is 20 %.
- (double)zoomLevel
{
    return log([_webView view].zoom_level()) / log(1.2);
}

- (void)setZoomLevel:(double)zoomLevel
{
    [_webView view].set_zoom(pow(1.2, zoomLevel));
}

- (NSArray<NSDictionary<NSString*, NSString*>*>*)navigationEntries
{
    auto& view = [_webView view];
    auto* entries = [NSMutableArray array];
    // Ladybird lists the steps away from the current one, nearest first.
    auto back = view.session_history_traversal_menu_items(-1);
    for (size_t i = back.size(); i > 0; --i) {
        auto const& item = back[i - 1];
        [entries addObject:@ { @"url" : Ladybird::string_to_ns_string(item.url), @"title" : Ladybird::string_to_ns_string(item.title) }];
    }
    [entries addObject:@ { @"url" : self.urlString ?: @"", @"title" : self.title ?: @"" }];
    for (auto const& item : view.session_history_traversal_menu_items(1))
        [entries addObject:@ { @"url" : Ladybird::string_to_ns_string(item.url), @"title" : Ladybird::string_to_ns_string(item.title) }];
    return entries;
}

- (NSInteger)currentNavigationIndex
{
    return static_cast<NSInteger>([_webView view].session_history_traversal_menu_items(-1).size());
}

- (NSArray<NSData*>*)certificateChain
{
    return @[];
}

- (void)loadWithUrlString:(NSString*)urlString
{
    if (_closed)
        return;
    NSURLComponents* components = [NSURLComponents componentsWithString:urlString];
    NSString* scheme = components.scheme.lowercaseString;
    if ([scheme isEqualToString:@"openarc"] || [scheme isEqualToString:@"chrome"]) {
        NSString* host = components.host.lowercaseString ?: @"";
        for (auto internal_host : s_internal_hosts) {
            if ([host isEqualToString:Ladybird::string_to_ns_string(internal_host)]) {
                _schemeURLString = nil;
                auto url = URL::Parser::basic_parse(MUST(String::formatted("about:{}", internal_host)));
                if (url.has_value())
                    [_webView view].load(*url);
                return;
            }
        }
        if (s_scheme_page_provider != nil) {
            NSInteger status_code = 200;
            NSString* html = s_scheme_page_provider(urlString, &status_code);
            if (html == nil)
                return;
            _schemeURLString = [urlString copy];
            [_webView view].load_html(Ladybird::ns_string_to_string(html));
            [self.delegate webKitPageDidChangeURL:self];
            return;
        }
    }
    _schemeURLString = nil;
    if (auto url = WebView::sanitize_url(Ladybird::ns_string_to_string(urlString)); url.has_value()) {
        [_webView view].load(*url);
        return;
    }
    [_webView view].load_from_user_input(Ladybird::ns_string_to_string(urlString));
}

- (void)goBack
{
    if ([self canGoBack])
        [_webView view].traverse_the_history_by_delta(-1);
}

- (void)goForward
{
    if ([self canGoForward])
        [_webView view].traverse_the_history_by_delta(1);
}

- (void)goToHistoryOffset:(NSInteger)offset
{
    if (offset != 0)
        [_webView view].traverse_the_history_by_delta(static_cast<int>(offset));
}

- (void)reloadWithIgnoringCache:(BOOL)ignoringCache
{
    (void)ignoringCache;
    if (_schemeURLString != nil) {
        [self loadWithUrlString:_schemeURLString];
        return;
    }
    [_webView view].reload();
}

- (void)stopLoading
{
    [_webView view].stop_loading();
}

- (void)focus
{
    [[_webView window] makeFirstResponder:_webView];
}

// Runs `script` in the page's global scope and answers the value as text: strings as they are, other values as
// JSON, nil for undefined, null, an exception or no answer in 5 seconds. A returned promise is awaited.
- (void)evaluate:(NSString*)script completion:(void (^)(NSString* _Nullable))completion
{
    [self evaluateRawScript:script completion:^(NSString* json) {
        if (json == nil) {
            completion(nil);
            return;
        }
        id value = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:nil];
        if (value == nil || value == [NSNull null] || ![value isKindOfClass:[NSDictionary class]]) {
            completion(nil);
            return;
        }
        id result = ((NSDictionary*)value)[@"value"];
        if (result == nil || result == [NSNull null]) {
            completion(nil);
        } else if ([result isKindOfClass:[NSString class]]) {
            completion(result);
        } else if ([result isKindOfClass:[NSNumber class]]) {
            completion([result stringValue]);
        } else {
            auto* data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingFragmentsAllowed error:nil];
            completion(data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil);
        }
    }];
}

// The page's answer as `{"value": …}` or `{"error": "…"}` JSON text. Scripts run as Ladybird's console input, which
// a page's Content Security Policy does not block. An expression runs inside a wrapper that keeps its value, or its
// promise's result, in the page as JSON, read back until it settles. Statements do not parse there and run as they
// are, answering their completion value as the console serializes it.
- (void)evaluateRawScript:(NSString*)script completion:(void (^)(NSString* _Nullable json))completion
{
    auto token = [NSString stringWithFormat:@"__openArcEvaluation%llu", ++_evaluationGeneration];
    auto* wrapped = [NSString stringWithFormat:
                                  @"window.%@ = { done: false }; (() => { const box = window.%@;"
                                   " const finish = (k, r) => { box.done = true; try { box.text = JSON.stringify(k === 'value' ? { value: r === undefined ? null : r } : { error: String(r && r.message || r) }); }"
                                   " catch (e) { box.text = JSON.stringify({ value: String(r) }); } };"
                                   " try { Promise.resolve((\n%@\n)).then((r) => finish('value', r), (e) => finish('error', e)); } catch (e) { finish('error', e); } })(); 0",
                              token, token, script];
    auto* read = [NSString stringWithFormat:@"(() => { const box = window.%@; if (!box || !box.done) return '__openArcPending__';"
                                             " delete window.%@; return box.text; })()",
                                            token, token];
    __weak OpenArcLadybirdPage* weak_self = self;
    [self runConsoleInput:wrapped completion:^(NSString* _Nullable, BOOL answered) {
        OpenArcLadybirdPage* self = weak_self;
        if (self == nil || self->_closed) {
            completion(nil);
            return;
        }
        if (answered) {
            [self pollEvaluation:read deadline:[NSDate dateWithTimeIntervalSinceNow:5] completion:completion];
            return;
        }
        [self runConsoleInput:script completion:^(NSString* _Nullable answer, BOOL script_answered) {
            if (!script_answered) {
                completion(@"{\"error\":\"The script threw or did not parse\"}");
                return;
            }
            id value = answer ? [NSJSONSerialization JSONObjectWithData:[answer dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:nil] : nil;
            // The console describes undefined, null and the like as {"type": …}.
            if ([value isKindOfClass:[NSDictionary class]] && ((NSDictionary*)value)[@"type"] != nil)
                value = nil;
            NSData* data = [NSJSONSerialization dataWithJSONObject:@ { @"value" : value ?: [NSNull null] } options:0 error:nil];
            completion(data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil);
        }];
    }];
}

- (void)pollEvaluation:(NSString*)read deadline:(NSDate*)deadline completion:(void (^)(NSString* _Nullable json))completion
{
    if (_closed) {
        completion(nil);
        return;
    }
    __weak OpenArcLadybirdPage* weak_self = self;
    [self runConsoleInput:read completion:^(NSString* _Nullable answer, BOOL) {
        id parsed = answer ? [NSJSONSerialization JSONObjectWithData:[answer dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:nil] : nil;
        NSString* text = [parsed isKindOfClass:[NSString class]] ? parsed : nil;
        if (text != nil && ![text isEqualToString:@"__openArcPending__"]) {
            completion(text);
            return;
        }
        if ([deadline timeIntervalSinceNow] <= 0) {
            completion(nil);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            OpenArcLadybirdPage* self = weak_self;
            if (self == nil)
                completion(nil);
            else
                [self pollEvaluation:read deadline:deadline completion:completion];
        });
    }];
}

// Ladybird's console input with its string result; one at a time per page.
- (void)runConsoleInput:(NSString*)source completion:(void (^)(NSString* _Nullable text, BOOL answered))completion
{
    _evaluations.append({ [source copy], [completion copy] });
    [self runNextConsoleInput];
}

- (void)runNextConsoleInput
{
    if (_evaluationInFlight || _evaluations.is_empty() || _closed)
        return;
    _evaluationInFlight = YES;
    auto evaluation = _evaluations.take_first();
    __weak OpenArcLadybirdPage* weak_self = self;
    __block BOOL finished = NO;
    void (^finish)(NSString*, BOOL) = ^(NSString* text, BOOL answered) {
        if (finished)
            return;
        finished = YES;
        OpenArcLadybirdPage* self = weak_self;
        if (self != nil) {
            self->_evaluationInFlight = NO;
            [self webView].view.on_received_js_console_result = nullptr;
        }
        evaluation.completion(text, answered);
        if (self != nil)
            [self runNextConsoleInput];
    };
    // The callback may not replace itself while Ladybird calls it, so the answer goes on after this turn.
    // The answer goes on as JSON text: a string, a number, true or false, or the console's description of
    // anything else ({"type": "undefined"} and the like).
    [_webView view].on_received_js_console_result = [finish](JsonValue result) {
        NSString* text = Ladybird::string_to_ns_string(result.serialized());
        dispatch_async(dispatch_get_main_queue(), ^{
            finish(text, YES);
        });
    };
    [_webView view].js_console_input(Ladybird::ns_string_to_string(evaluation.script));
    // A script that throws or does not parse answers nothing.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        finish(nil, NO);
    });
}

- (void)find:(NSString*)text forward:(BOOL)forward matchCase:(BOOL)matchCase
{
    BOOL next = [text isEqualToString:_lastFindText] && matchCase == _lastFindMatchCase;
    [self findText:text forward:forward matchCase:matchCase findNext:next];
}

- (void)stopFinding
{
    [self stopFindingClearingSelection:YES];
}

- (void)setAudioMuted:(BOOL)muted
{
    _audioMuted = muted;
    auto& view = [_webView view];
    BOOL is_muted = view.page_mute_state() == Web::HTML::MuteState::Muted;
    if (is_muted != muted)
        view.toggle_page_mute_state();
}

- (void)setMediaVolume:(double)volume
{
    _mediaVolume = volume;
    [self applyMediaVolume];
}

- (void)applyMediaVolume
{
    if (_mediaVolume >= 1)
        return;
    [_webView view].run_javascript(Ladybird::ns_string_to_string([NSString stringWithFormat:@"document.querySelectorAll('audio,video').forEach((m) => { m.volume = %f; })", _mediaVolume]));
}

// play, pause, previoustrack or nexttrack.
- (void)controlMedia:(NSString*)action
{
    NSString* script = nil;
    if ([action isEqualToString:@"play"])
        script = @"(() => { const m = [...document.querySelectorAll('audio,video')].find((e) => e.paused && e.currentTime > 0) || document.querySelector('audio,video'); m && m.play(); })()";
    else if ([action isEqualToString:@"pause"])
        script = @"document.querySelectorAll('audio,video').forEach((m) => m.pause())";
    else if ([action isEqualToString:@"nexttrack"] || [action isEqualToString:@"previoustrack"])
        script = [NSString stringWithFormat:@"(() => { const m = document.querySelector('audio,video'); if (m) m.currentTime = %@; })()", [action isEqualToString:@"nexttrack"] ? @"m.duration" : @"0"];
    if (script != nil)
        [_webView view].run_javascript(Ladybird::ns_string_to_string(script));
}

- (void)togglePictureInPicture
{
    // Ladybird has no picture in picture yet.
}

- (void)exitFullscreen
{
    if (_fullscreen)
        [_webView handleExitFullScreen];
}

- (void)selectedTextWithCompletion:(void (^)(NSString* _Nullable))completion
{
    [_webView view].selected_text()->when_resolved([completion](ByteString const& text) {
        completion(text.is_empty() ? nil : [NSString stringWithUTF8String:text.characters()]);
    });
}

- (void)capturePictureWithCompletion:(void (^)(NSData* _Nullable))completion
{
    [self capturePictureWithFraction:CGRectMake(0, 0, 1, 1) completion:completion];
}

// The part of the page in `fraction` of its view, y downward: the frame the view shows now.
- (void)capturePictureWithFraction:(CGRect)fraction completion:(void (^)(NSData* _Nullable))completion
{
    CGImageRef image = [_webView copyCurrentFrame];
    if (image == nullptr) {
        completion(nil);
        return;
    }
    if (!CGRectEqualToRect(fraction, CGRectMake(0, 0, 1, 1))) {
        auto width = CGImageGetWidth(image), height = CGImageGetHeight(image);
        auto crop = CGRectIntegral(CGRectMake(width * fraction.origin.x, height * fraction.origin.y, width * fraction.size.width, height * fraction.size.height));
        CGImageRef cropped = CGImageCreateWithImageInRect(image, crop);
        CGImageRelease(image);
        image = cropped;
        if (image == nullptr) {
            completion(nil);
            return;
        }
    }
    auto* representation = [[NSBitmapImageRep alloc] initWithCGImage:image];
    CGImageRelease(image);
    completion([representation representationUsingType:NSBitmapImageFileTypePNG properties:@{}]);
}

- (void)captureScreenshotOfType:(WebView::ViewImplementation::ScreenshotType)type completion:(void (^)(NSData* _Nullable))completion
{
    if (type == WebView::ViewImplementation::ScreenshotType::Visible) {
        [self capturePictureWithFraction:CGRectMake(0, 0, 1, 1) completion:completion];
        return;
    }
    // WebContent paints the whole document; a page that never answers gets no picture after 10 seconds.
    __block BOOL answered = NO;
    void (^answer)(NSData*) = ^(NSData* png) {
        if (answered)
            return;
        answered = YES;
        completion(png);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        answer(nil);
    });
    OpenArc::begin_screenshot_capture();
    auto promise = [_webView view].take_screenshot(type);
    promise->when_resolved([completion = answer](LexicalPath const& path) {
        OpenArc::end_screenshot_capture();
        auto* ns_path = Ladybird::string_to_ns_string(path.string());
        auto* data = [NSData dataWithContentsOfFile:ns_path];
        [[NSFileManager defaultManager] removeItemAtPath:ns_path error:nil];
        completion(data);
    });
    promise->when_rejected([completion = answer](Error const& error) {
        OpenArc::end_screenshot_capture();
        warnln("OpenArc: Ladybird's screenshot failed: {}", error);
        completion(nil);
    });
}

// Ladybird does not print; File › Print prints the whole page as Ladybird draws it.
- (void)print
{
    NSWindow* window = [_container window];
    [self captureScreenshotOfType:WebView::ViewImplementation::ScreenshotType::Full completion:^(NSData* png) {
        if (png == nil || window == nil)
            return;
        auto* image = [[NSImage alloc] initWithData:png];
        if (image == nil)
            return;
        NSPrintInfo* print_info = [[NSPrintInfo sharedPrintInfo] copy];
        print_info.horizontalPagination = NSPrintingPaginationModeFit;
        print_info.verticalPagination = NSPrintingPaginationModeAutomatic;
        auto* image_view = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, image.size.width, image.size.height)];
        image_view.image = image;
        image_view.imageScaling = NSImageScaleNone;
        auto* operation = [NSPrintOperation printOperationWithView:image_view printInfo:print_info];
        operation.jobTitle = self.title;
        [operation runOperationModalForWindow:window delegate:nil didRunSelector:nil contextInfo:nil];
    }];
}

- (void)close
{
    if (_closed)
        return;
    _closed = YES;
    [_signInTimer invalidate];
    _signInTimer = nil;
    if (s_last_focused_page == self)
        s_last_focused_page = nil;
    [s_open_pages removeObject:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    auto& view = [_webView view];
    view.on_received_js_console_result = nullptr;
    // Closing skips beforeunload: the tab controller already asked.
    if (auto close = [_webView prepareForImmediateClose])
        close();
    [_webView removeFromSuperview];
    [_container removeFromSuperview];
    _evaluations.clear();
}

#pragma mark - BrowserChromePage

- (int)rendererProcessID
{
    return static_cast<int>([_webView view].client().pid());
}

- (void)executeDevToolsMethod:(NSString*)method
                       params:(NSString*)paramsJSON
                   completion:(void (^)(NSString* _Nullable result))completion
{
    NSDictionary* params = [NSJSONSerialization JSONObjectWithData:[paramsJSON dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data] options:0 error:nil];
    if (![params isKindOfClass:[NSDictionary class]])
        params = @{};
    if ([method isEqualToString:@"Page.captureScreenshot"]) {
        auto type = [params[@"captureBeyondViewport"] boolValue] ? WebView::ViewImplementation::ScreenshotType::Full : WebView::ViewImplementation::ScreenshotType::Visible;
        [self captureScreenshotOfType:type completion:^(NSData* png) {
            if (png == nil) {
                completion(nil);
                return;
            }
            auto* answer = [NSJSONSerialization dataWithJSONObject:@ { @"data" : [png base64EncodedStringWithOptions:0] } options:0 error:nil];
            completion([[NSString alloc] initWithData:answer encoding:NSUTF8StringEncoding]);
        }];
        return;
    }
    NSString* expression = params[@"expression"];
    if (![method isEqualToString:@"Runtime.evaluate"] || ![expression isKindOfClass:[NSString class]]) {
        completion(nil);
        return;
    }
    [self evaluateRawScript:expression completion:^(NSString* json) {
        id value = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        NSDictionary* answer = nil;
        if ([value isKindOfClass:[NSDictionary class]] && ((NSDictionary*)value)[@"error"] != nil) {
            NSString* message = [((NSDictionary*)value)[@"error"] description];
            answer = @ { @"exceptionDetails" : @ { @"text" : message, @"exception" : @ { @"description" : message } } };
        } else if ([value isKindOfClass:[NSDictionary class]]) {
            id result = ((NSDictionary*)value)[@"value"] ?: [NSNull null];
            NSString* type = @"object";
            if ([result isKindOfClass:[NSString class]])
                type = @"string";
            else if ([result isKindOfClass:[NSNumber class]])
                type = CFGetTypeID((__bridge CFTypeRef)result) == CFBooleanGetTypeID() ? @"boolean" : @"number";
            answer = @ { @"result" : @ { @"type" : type, @"value" : result } };
        } else {
            answer = @ { @"exceptionDetails" : @ { @"text" : @"No answer", @"exception" : @ { @"description" : @"No answer" } } };
        }
        auto* data = [NSJSONSerialization dataWithJSONObject:answer options:0 error:nil];
        completion(data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil);
    }];
}

- (void)findText:(NSString*)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext
{
    if (text.length == 0) {
        [self stopFindingClearingSelection:YES];
        return;
    }
    auto& view = [_webView view];
    if (!findNext || ![text isEqualToString:_lastFindText] || matchCase != _lastFindMatchCase) {
        _lastFindText = [text copy];
        _lastFindMatchCase = matchCase;
        view.find_in_page(Ladybird::ns_string_to_utf16_string(text), matchCase ? CaseSensitivity::CaseSensitive : CaseSensitivity::CaseInsensitive);
        return;
    }
    if (forward)
        view.find_in_page_next_match();
    else
        view.find_in_page_previous_match();
}

- (void)stopFindingClearingSelection:(BOOL)clearSelection
{
    _lastFindText = nil;
    [_webView view].find_in_page(Utf16String {}, CaseSensitivity::CaseInsensitive);
    if (clearSelection)
        [_webView view].run_javascript("getSelection().removeAllRanges()"_string);
}

// Ladybird's Developer Tools are Firefox's, attached to Ladybird's DevTools server: the first call starts the server
// and Ladybird opens Firefox on this page. Without Firefox, an alert says where to connect.
- (void)showDevToolsPanel:(NSString*)panel
{
    (void)panel;
    s_last_focused_page = self;
    auto& application = WebView::Application::the();
    if (!OpenArc::devtools_enabled()) {
        if (auto result = application.toggle_devtools_enabled(); result.is_error()) {
            [self showDevToolsMessage:Ladybird::string_to_ns_string(MUST(String::formatted("{}", result.error())))];
            return;
        }
    }
    if (auto result = application.launch_devtools_client(); result.is_error()) {
        auto port = WebView::Application::browser_options().devtools_port.value_or(6000);
        [self showDevToolsMessage:[NSString stringWithFormat:@"Ladybird's DevTools server listens on localhost:%u (%@). Open about:debugging in Firefox, add localhost:%u as a network location, and inspect this page there.", port, Ladybird::string_to_ns_string(MUST(String::formatted("{}", result.error()))), port]];
    }
}

- (void)showDevToolsMessage:(NSString*)message
{
    auto* alert = [[NSAlert alloc] init];
    alert.messageText = @"Ladybird Developer Tools";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    if (NSWindow* window = [_container window])
        [alert beginSheetModalForWindow:window completionHandler:nil];
    else
        [alert runModal];
}

- (void)setPageVisible:(BOOL)visible
{
    _visible = visible;
    [self windowDidChangeOcclusionState];
}

- (BOOL)sendAction:(SEL)action
{
    if (![_webView respondsToSelector:action] && action != @selector(copy:) && action != @selector(paste:) && action != @selector(cut:) && action != @selector(selectAll:) && action != @selector(undo:) && action != @selector(redo:))
        return NO;
    auto& view = [_webView view];
    if (action == @selector(selectAll:)) {
        view.select_all();
        return YES;
    }
    if (action == @selector(paste:)) {
        view.paste_from_clipboard();
        return YES;
    }
    if (action == @selector(undo:)) {
        view.undo();
        return YES;
    }
    if (action == @selector(redo:)) {
        view.redo();
        return YES;
    }
    if (action == @selector(copy:)) {
        view.selected_text()->when_resolved([](ByteString const& text) {
            auto* pasteboard = [NSPasteboard generalPasteboard];
            [pasteboard clearContents];
            [pasteboard setString:[NSString stringWithUTF8String:text.characters()] forType:NSPasteboardTypeString];
        });
        return YES;
    }
    if (action == @selector(cut:)) {
        view.cut_selected_text()->when_resolved([](ByteString const& text) {
            auto* pasteboard = [NSPasteboard generalPasteboard];
            [pasteboard clearContents];
            [pasteboard setString:[NSString stringWithUTF8String:text.characters()] forType:NSPasteboardTypeString];
        });
        return YES;
    }
    return [NSApp sendAction:action to:_webView from:nil];
}

@end
