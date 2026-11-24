/*
 * OpenArcLadybirdEngineMain: OpenArc's entry into Ladybird, and the engine's class methods
 * (BrowserLadybirdEngine.h). Ladybird's application runs without windows of its own: OpenArc's windows hold its
 * pages, OpenArc's app delegate decides when to quit, and Ladybird's event loop is AppKit's run loop.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <AK/LexicalPath.h>
#include <LibHTTP/Cookie/ParsedCookie.h>
#include <LibWebView/BrowsingSession.h>
#include <LibCore/EventLoop.h>
#include <LibCore/StandardPaths.h>
#include <LibCore/ThreadEventQueue.h>
#include <LibFileSystem/FileSystem.h>
#include <LibHTTP/Cookie/Cookie.h>
#include <LibMain/Main.h>
#include <LibURL/Parser.h>
#include <LibWebView/Application.h>
#include <LibWebView/CookieJar.h>
#include <LibWebView/FileDownloader.h>
#include <LibWebView/URL.h>
#include <LibWebView/Settings.h>
#include <LibWebView/Utilities.h>
#include <LibWebView/ViewImplementation.h>

#import <Application/ClipboardTypes.h>
#import <Application/EventLoopImplementationMacOS.h>
#import <Interface/LadybirdWebView.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Utilities/Conversions.h>
#import <Utilities/ExternalURLHandler.h>

#import "openarc/ladybird_page.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#    error "This project requires ARC"
#endif

static int s_screenshot_captures = 0;
static bool s_devtools_enabled = false;

void OpenArc::begin_screenshot_capture() { ++s_screenshot_captures; }
void OpenArc::end_screenshot_capture()
{
    if (s_screenshot_captures > 0)
        --s_screenshot_captures;
}

static NSString* download_state(WebView::FileDownloader::DownloadStatus status)
{
    switch (status) {
    case WebView::FileDownloader::DownloadStatus::InProgress:
    case WebView::FileDownloader::DownloadStatus::Paused:
        return @"inProgress";
    case WebView::FileDownloader::DownloadStatus::Completed:
        return @"completed";
    case WebView::FileDownloader::DownloadStatus::Canceled:
        return @"canceled";
    case WebView::FileDownloader::DownloadStatus::Failed:
        return @"interrupted";
    }
    return @"inProgress";
}

static NSString* download_id(u64 id)
{
    // Never the same as CEF's numbers or WebKit's identifiers.
    return [NSString stringWithFormat:@"ladybird-%llu", id];
}

namespace OpenArc {

// The handler for OpenArc's own addresses a page links to (openarc://, chrome://): they open in the page's tab, as the
// app's own navigations do, rather than going to macOS, which would hand them to whichever OpenArc is the default.
class InternalURLHandler final : public WebView::ExternalURLHandler {
public:
    InternalURLHandler()
        : WebView::ExternalURLHandler("OpenArc"_string, true)
    {
    }

    virtual void launch(URL::URL const&, LaunchCallback callback) const override { callback(true); }
};

// Reports Ladybird's downloads to the tab controller, as the Chrome engine reports Chrome's.
class DownloadsObserver final : public WebView::FileDownloaderObserver {
public:
    AK_ALLOC_WITH_KMALLOC;

    virtual void download_added(WebView::FileDownloader::Download const& download) override { report(download); }
    virtual void download_updated(WebView::FileDownloader::Download const& download) override { report(download); }

private:
    static void report(WebView::FileDownloader::Download const& download)
    {
        OpenArcLadybirdPage* page = last_focused_page();
        if (page == nil)
            return;
        auto path = Ladybird::string_to_ns_string(download.destination.string());
        NSDictionary* info = @{
            @"id" : download_id(download.id),
            @"fileName" : [path lastPathComponent] ?: @"",
            @"url" : Ladybird::string_to_ns_string(download.url.serialize()),
            @"fullPath" : path ?: @"",
            @"receivedBytes" : @(download.downloaded_size),
            @"totalBytes" : @(download.total_size.value_or(0)),
            @"currentSpeed" : @(download.bytes_per_second.value_or(0)),
            @"state" : download_state(download.status),
        };
        [page.delegate chromePage:page didUpdateDownload:info];
    }
};

class Application final : public WebView::Application {
    WEB_VIEW_APPLICATION(Application)

public:
    AK_ALLOC_WITH_KMALLOC;

private:
    // `helpers_path` is the framework's Helpers/, where Ladybird looks for its helper processes; its resources sit in
    // Resources/ beside it.
    explicit Application(Optional<ByteString> helpers_path)
        : WebView::Application(move(helpers_path))
    {
    }

    // OpenArc runs one process per runtime with its own data folder; it neither hands URLs to another Ladybird
    // process nor takes them from one.
    virtual bool should_coordinate_browser_process() const override { return false; }
    virtual bool supports_private_browsing_windows() const override { return true; }
    virtual bool supports_system_menu_bar() const override { return true; }

    virtual void create_platform_arguments(Core::ArgsParser&) override { }

    virtual Core::EventLoop& create_platform_event_loop() override
    {
        Core::EventLoopManager::install(*new Ladybird::EventLoopManagerMacOS);
        auto& event_loop = WebView::Application::create_platform_event_loop();
        static_cast<Ladybird::EventLoopImplementationMacOS&>(event_loop.impl()).set_main_loop();
        return event_loop;
    }

    virtual Optional<String> ui_font_family() const override
    {
        return Ladybird::ns_string_to_string([[NSFont systemFontOfSize:[NSFont systemFontSize]] familyName]);
    }

    virtual Optional<WebView::ViewImplementation&> active_web_view() const override
    {
        if (OpenArcLadybirdPage* page = OpenArc::last_focused_page())
            return [page.webView view];
        return {};
    }

    virtual Vector<WebView::ViewImplementation&> active_window_web_views() const override
    {
        Vector<WebView::ViewImplementation&> views;
        for (OpenArcLadybirdPage* page in OpenArc::open_pages()) {
            if ([page.view window] == [NSApp keyWindow])
                views.append([page.webView view]);
        }
        return views;
    }

    virtual void open_url_in_new_tab(URL::URL const& url, Web::HTML::ActivateTab activate_tab) const override
    {
        OpenArc::open_url_in_new_tab_from_page(OpenArc::last_focused_page(), Ladybird::string_to_ns_string(url.serialize()), activate_tab == Web::HTML::ActivateTab::No);
    }

    virtual void open_urls_in_new_tabs(ReadonlySpan<URL::URL> urls) const override
    {
        for (auto const& url : urls)
            open_url_in_new_tab(url, Web::HTML::ActivateTab::No);
    }

    virtual void open_url_in_new_window(URL::URL const& url, WebView::IsPrivate) override
    {
        open_url_in_new_tab(url, Web::HTML::ActivateTab::Yes);
    }

    virtual void resolve_external_url_handler(URL::URL const& url, WebView::ExternalURLHandlerCallback callback) const override
    {
        if (url.scheme() == "openarc"sv || url.scheme() == "chrome"sv) {
            NSString* address = Ladybird::string_to_ns_string(url.serialize());
            dispatch_async(dispatch_get_main_queue(), ^{
                [last_focused_page() loadWithUrlString:address];
            });
            callback(make_ref_counted<InternalURLHandler>());
            return;
        }
        Ladybird::resolve_external_url_handler(url, move(callback));
    }

    // Downloads go to the Downloads folder without asking, as on OpenArc's other engines; a page capture goes to a
    // temporary file the page reads back.
    virtual Optional<ByteString> ask_user_for_download_path(ByteString const& file) const override
    {
        ByteString directory;
        if (s_screenshot_captures > 0 && file.starts_with("screenshot-"sv) && file.ends_with(".png"sv))
            directory = Ladybird::ns_string_to_byte_string(NSTemporaryDirectory());
        else
            directory = Core::StandardPaths::downloads_directory();
        if (!FileSystem::is_directory(directory))
            return {};
        auto name = LexicalPath { file };
        auto candidate = LexicalPath::join(directory, file);
        for (int i = 1; FileSystem::exists(candidate.string()); ++i) {
            auto numbered = name.extension().is_empty()
                ? ByteString::formatted("{} ({})", name.title(), i)
                : ByteString::formatted("{} ({}).{}", name.title(), i, name.extension());
            candidate = LexicalPath::join(directory, numbered);
        }
        return candidate.string();
    }

    // The downloads list shows a finished download; no dialog.
    virtual void display_download_confirmation_dialog(StringView, LexicalPath const&) const override { }

    virtual void display_error_dialog(StringView error_message) const override
    {
        auto* alert = [[NSAlert alloc] init];
        [alert setMessageText:Ladybird::string_to_ns_string(error_message)];
        if (NSWindow* window = [NSApp keyWindow])
            [alert beginSheetModalForWindow:window completionHandler:nil];
        else
            [alert runModal];
    }

    virtual Utf16String clipboard_text(ClipboardType) const override
    {
        if (auto* contents = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString])
            return Ladybird::ns_string_to_utf16_string(contents);
        return {};
    }

    virtual Web::Clipboard::SystemClipboardItem clipboard_item() const override
    {
        Vector<Web::Clipboard::SystemClipboardRepresentation> representations;
        auto* paste_board = [NSPasteboard generalPasteboard];

        auto* file_list = [paste_board readObjectsForClasses:@[ [NSURL class] ]
                                                     options:@{ NSPasteboardURLReadingFileURLsOnlyKey : @YES }];
        for (NSURL* url in file_list) {
            auto file_path = Ladybird::ns_string_to_byte_string([url path]);
            if (auto file = WebView::create_selected_file(file_path); !file.is_error()) {
                if (auto* resource_values = [url resourceValuesForKeys:@[ NSURLContentTypeKey ] error:nil]) {
                    UTType* content_type = resource_values[NSURLContentTypeKey];
                    if (auto* mime_type = [content_type preferredMIMEType])
                        representations.empend(Ladybird::ns_string_to_string(mime_type), file.release_value());
                }
            }
        }

        if (representations.is_empty()) {
            for (NSPasteboardType type : [paste_board types]) {
                auto mime_type = Ladybird::mime_type_for_pasteboard_type(type);
                if (!mime_type.has_value())
                    continue;
                representations.empend(mime_type.release_value(), Ladybird::ns_data_to_string([paste_board dataForType:type]));
            }
        }

        return { move(representations) };
    }

    virtual void insert_clipboard_item(Web::Clipboard::SystemClipboardItem item) override
    {
        auto* paste_board = [NSPasteboard generalPasteboard];
        [paste_board clearContents];
        for (auto const& entry : item.system_clipboard_representations) {
            NSPasteboardType pasteboard_type = Ladybird::pasteboard_type_for_mime_type(entry.name);
            if (!pasteboard_type)
                continue;
            if (auto const* data = entry.data.get_pointer<ByteString>())
                [paste_board setData:Ladybird::string_to_ns_data(*data) forType:pasteboard_type];
        }
    }

    virtual void on_devtools_enabled() const override
    {
        s_devtools_enabled = true;
        WebView::Application::on_devtools_enabled();
    }

    virtual void on_devtools_disabled() const override
    {
        s_devtools_enabled = false;
        WebView::Application::on_devtools_disabled();
    }
};

}

// NSApp while the process runs on Ladybird: Ladybird's events arrive as application-defined events, and
// Cocoa's own quit lets OpenArc's app delegate decide.
__attribute__((visibility("default")))
@interface OpenArcLadybirdApplication : NSApplication
@end

@implementation OpenArcLadybirdApplication

- (void)sendEvent:(NSEvent*)event
{
    if ([event type] == NSEventTypeApplicationDefined) {
        Core::ThreadEventQueue::current().process();
        return;
    }
    [super sendEvent:event];
}

@end

static OwnPtr<OpenArc::Application> s_application;
static OwnPtr<OpenArc::DownloadsObserver> s_downloads_observer;

__attribute__((visibility("default")))
@interface OpenArcLadybirdEngine : NSObject <BrowserLadybirdEngine>
@end

@implementation OpenArcLadybirdEngine

+ (id<BrowserChromePage>)pageWithURLString:(NSString*)urlString
                               profilePath:(NSString*)profilePath
                                 ephemeral:(BOOL)ephemeral
                                  delegate:(id<BrowserChromePageDelegate>)delegate
{
    if (!s_application)
        return nil;
    return [[OpenArcLadybirdPage alloc] initWithURLString:urlString ?: @""
                                              profilePath:profilePath
                                                ephemeral:ephemeral
                                                 delegate:delegate];
}

+ (NSString*)ladybirdVersion
{
    return [NSString stringWithFormat:@"%s-%s", OPENARC_LADYBIRD_VERSION, OPENARC_LADYBIRD_COMMIT];
}

+ (void)setSchemePageProvider:(NSString* _Nullable (^)(NSString*, NSInteger*))provider
{
    OpenArc::set_scheme_page_provider(provider);
}

+ (void)cancelDownloadWithID:(NSString*)downloadID
{
    if (!s_application || ![downloadID hasPrefix:@"ladybird-"])
        return;
    auto id = strtoull([[downloadID substringFromIndex:strlen("ladybird-")] UTF8String], nullptr, 10);
    WebView::Application::the().file_downloader().cancel_download(id);
}

+ (NSInteger)importCookies:(NSArray<NSDictionary<NSString*, id>*>*)cookies
{
    if (!s_application)
        return 0;
    auto& jar = *WebView::Application::default_session().cookie_jar;
    NSInteger stored = 0;
    for (NSDictionary* cookie in cookies) {
        NSString* url_string = cookie[@"url"];
        NSString* name = cookie[@"name"];
        if (![url_string isKindOfClass:[NSString class]] || ![name isKindOfClass:[NSString class]])
            continue;
        auto url = URL::Parser::basic_parse(Ladybird::ns_string_to_string(url_string));
        if (!url.has_value())
            continue;
        auto* line = [NSMutableString stringWithFormat:@"%@=%@", name, cookie[@"value"] ?: @""];
        if (NSString* host = cookie[@"host"]; [host isKindOfClass:[NSString class]] && [host hasPrefix:@"."])
            [line appendFormat:@"; Domain=%@", host];
        [line appendFormat:@"; Path=%@", cookie[@"path"] ?: @"/"];
        if (NSNumber* expires = cookie[@"expires"]; [expires isKindOfClass:[NSNumber class]] && expires.doubleValue > 0) {
            auto* formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
            formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'GMT'";
            [line appendFormat:@"; Expires=%@", [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:expires.doubleValue]]];
        }
        if ([cookie[@"secure"] boolValue])
            [line appendString:@"; Secure"];
        if ([cookie[@"httpOnly"] boolValue])
            [line appendString:@"; HttpOnly"];
        if (NSString* same_site = cookie[@"sameSite"]; [same_site isKindOfClass:[NSString class]] && same_site.length > 0)
            [line appendFormat:@"; SameSite=%@", same_site];
        auto parsed = HTTP::Cookie::parse_cookie(*url, Ladybird::ns_string_to_string(line));
        if (!parsed.has_value())
            continue;
        jar.set_cookie(*url, *parsed, HTTP::Cookie::Source::NonHttp);
        ++stored;
    }
    return stored;
}

+ (void)quit
{
    if (!s_application)
        return;
    WebView::Application::the().file_downloader().pause_active_downloads();
    Core::EventLoop::current().quit(0);
}

@end

bool OpenArc::devtools_enabled() { return s_devtools_enabled; }

extern "C" __attribute__((visibility("default"))) int OpenArcLadybirdEngineMain(int argc, char const** argv, char const* data_path, void (^ready)(void));
extern "C" int OpenArcLadybirdEngineMain(int argc, char const** argv, char const* data_path, void (^ready)(void))
{
    AK::set_rich_debug_enabled(false);

    // Ladybird's helpers, libraries and resources sit inside this framework: Helpers/, Libraries/ and Resources/.
    Dl_info info {};
    if (dladdr(reinterpret_cast<void*>(&OpenArcLadybirdEngineMain), &info) == 0 || info.dli_fname == nullptr)
        return 1;
    auto framework_directory = LexicalPath { info.dli_fname }.parent();
    auto helpers_path = LexicalPath::join(framework_directory.string(), "Helpers"sv).string();

    // WasmCompiler runs WebAssembly's compiler from the build tree it was built in unless told otherwise; the helpers
    // inherit this and run the one in Helpers/, which their sandbox then admits.
    auto cranelift_compiler = LexicalPath::join(helpers_path, "cranelift-compiler"sv).string();
    if (access(cranelift_compiler.characters(), X_OK) == 0)
        setenv("LADYBIRD_CRANELIFT_COMPILER", cranelift_compiler.characters(), 1);

    [OpenArcLadybirdApplication sharedApplication];

    // Ladybird's own switches (--ladybird-… from the app's launch) plus its profile in OpenArc's data folder.
    Vector<StringView> arguments;
    for (int i = 0; i < argc; ++i)
        arguments.append(StringView { argv[i], strlen(argv[i]) });
    auto profile_argument = ByteString::formatted("--profile-path={}", data_path);
    arguments.append(profile_argument.view());

    Main::Arguments main_arguments {
        .argc = static_cast<int>(arguments.size()),
        .argv = const_cast<char**>(argv),
        .strings = arguments.span(),
    };

    auto application = OpenArc::Application::create(main_arguments, Optional<ByteString> { helpers_path });
    if (application.is_error()) {
        warnln("OpenArc: Ladybird did not start: {}", application.error());
        return 1;
    }
    s_application = application.release_value();
    s_downloads_observer = make<OpenArc::DownloadsObserver>();
    // Pages ask the app for their location; each site's answer comes from OpenArc's prompt (OpenArcLadybirdPage), so
    // Ladybird's own switch stays on.
    if (!WebView::Application::settings().geolocation_enabled())
        WebView::Application::settings().set_geolocation_enabled(true);

    // Ladybird's services are up once the run loop turns; the app starts in its first turn, as on CEF.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (ready)
            ready();
    });

    auto result = WebView::Application::the().execute();
    s_downloads_observer.clear();
    s_application.clear();
    if (result.is_error()) {
        warnln("OpenArc: Ladybird stopped: {}", result.error());
        return 1;
    }
    return result.value();
}
