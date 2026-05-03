#import "Browser/BrowserTabController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "Browser/SwiftBridge.h"
#include "Shared/BrowserSchemes.h"
#include "Shared/ClientManager.h"
#include "Shared/ClientUtil.h"

#include <atomic>
#include <cctype>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "include/base/cef_callback.h"
#include "include/cef_client.h"
#include "include/cef_browser.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_find_handler.h"
#include "include/cef_frame.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_values.h"
#include "include/internal/cef_mac.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"

@interface SavePageFormatAccessoryController : NSObject

- (instancetype)initWithPanel:(NSSavePanel *)panel baseName:(NSString *)baseName;
- (void)formatDidChange:(NSPopUpButton *)sender;

@end

@interface BrowserTabController (ChromeWindowHosting)

- (void)handleChromeWindowCreated:(CefRefPtr<CefWindow>)window
                          forTabID:(NSString *)tabID;
- (void)handleChromeWindowDestroyedForTabID:(NSString *)tabID;

@end

namespace {

constexpr char kSavePageResourceTreeMethod[] = "Page.getResourceTree";
constexpr char kSavePageResourceContentMethod[] = "Page.getResourceContent";
constexpr char kSavePageSingleFileMethod[] = "Page.captureSnapshot";
constexpr char kSavePageSerializeDocumentMethod[] = "Runtime.evaluate";
constexpr char kFocusSettingsSearchScript[] = R"JS(
(() => {
  const focusSettingsSearch = (attempt) => {
    const settingsUI = document.querySelector('settings-ui');
    const toolbar = settingsUI && settingsUI.shadowRoot &&
      settingsUI.shadowRoot.querySelector('cr-toolbar');

    if (settingsUI && typeof settingsUI.handleFindShortcut === 'function' &&
        settingsUI.handleFindShortcut(false)) {
      return;
    }

    const searchField = toolbar && typeof toolbar.getSearchField === 'function' &&
      toolbar.getSearchField();
    if (searchField && typeof searchField.showAndFocus === 'function') {
      searchField.showAndFocus();
      return;
    }

    const toolbarSearchField = toolbar && toolbar.shadowRoot &&
      toolbar.shadowRoot.querySelector('cr-toolbar-search-field');
    const searchInput = toolbarSearchField && toolbarSearchField.shadowRoot &&
      toolbarSearchField.shadowRoot.querySelector('#searchInput, input[type="search"]');
    if (searchInput) {
      searchInput.focus();
      searchInput.select();
      return;
    }

    if (attempt < 10) {
      window.setTimeout(() => focusSettingsSearch(attempt + 1), 50);
    }
  };

  focusSettingsSearch(0);
})();
)JS";

enum class SavePageFormat : NSInteger {
  Complete = 0,
  SingleFile = 1,
  HTMLOnly = 2,
};

std::string ToStdString(NSString *value) {
  if (value.length == 0) {
    return std::string();
  }
  return std::string(value.UTF8String);
}

NSString *ToNSString(const std::string &value) {
  return [[NSString alloc] initWithUTF8String:value.c_str()];
}

NSString *LocalizedBrowserString(NSString *key) {
  return [[NSBundle mainBundle] localizedStringForKey:key value:nil table:nil];
}

NSString *DefaultTitleForURLString(NSString *urlString) {
  NSURL *url = [NSURL URLWithString:urlString];
  NSString *host = url.host;
  if (host.length > 0) {
    return host;
  }
  return LocalizedBrowserString(@"browser.tab.new");
}

CefRect CefRectFromBounds(NSRect bounds) {
  return CefRect(0, 0, static_cast<int>(NSWidth(bounds)),
                 static_cast<int>(NSHeight(bounds)));
}

NSView *BrowserViewForBrowser(CefRefPtr<CefBrowser> browser);

void PresentSavePageError(NSString *message) {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = LocalizedBrowserString(@"browser.save_page.error.title");
    alert.informativeText =
        message ?: LocalizedBrowserString(@"browser.save_page.error.default");
    [alert runModal];
  });
}

bool WriteStringToPath(NSString *contents, NSString *destination_path) {
  NSError *error = nil;
  BOOL didWriteFile =
      [contents writeToFile:destination_path
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:&error];
  if (didWriteFile) {
    return true;
  }

  PresentSavePageError(
      error.localizedDescription ?: LocalizedBrowserString(@"browser.save_page.error.default"));
  return false;
}

bool WriteDataToPath(NSData *contents, NSString *destination_path) {
  NSError *error = nil;
  BOOL didWriteFile = [contents writeToFile:destination_path
                                    options:NSDataWritingAtomic
                                      error:&error];
  if (didWriteFile) {
    return true;
  }

  PresentSavePageError(
      error.localizedDescription ?: LocalizedBrowserString(@"browser.save_page.error.default"));
  return false;
}

NSString *SanitizedSavePageBaseName(NSString *value) {
  NSString *fallback = LocalizedBrowserString(@"browser.save_page.default_filename");
  if (value.length == 0) {
    return fallback;
  }

  NSCharacterSet *invalidCharacters =
      [NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"];
  NSString *sanitizedValue =
      [[value componentsSeparatedByCharactersInSet:invalidCharacters]
          componentsJoinedByString:@"-"];
  sanitizedValue = [sanitizedValue
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];

  while ([sanitizedValue containsString:@"--"]) {
    sanitizedValue =
        [sanitizedValue stringByReplacingOccurrencesOfString:@"--"
                                                 withString:@"-"];
  }

  return sanitizedValue.length > 0 ? sanitizedValue : fallback;
}

NSString *DefaultExtensionForSavePageFormat(SavePageFormat format) {
  switch (format) {
    case SavePageFormat::Complete:
      return @"html";
    case SavePageFormat::SingleFile:
      return @"mhtml";
    case SavePageFormat::HTMLOnly:
      return @"html";
  }

  return @"html";
}

UTType *ContentTypeForSavePageFormat(SavePageFormat format) {
  switch (format) {
    case SavePageFormat::Complete:
      return UTTypeHTML;
    case SavePageFormat::SingleFile:
      return [UTType typeWithFilenameExtension:@"mhtml"] ?: UTTypeData;
    case SavePageFormat::HTMLOnly:
      return UTTypeHTML;
  }

  return UTTypeData;
}

NSString *SuggestedFileName(NSString *base_name, SavePageFormat format) {
  return [base_name stringByAppendingPathExtension:DefaultExtensionForSavePageFormat(format)];
}

NSURL *NormalizedSaveURL(NSURL *url, SavePageFormat format) {
  if (url == nil) {
    return nil;
  }

  NSString *requiredExtension = DefaultExtensionForSavePageFormat(format);
  NSURL *baseURL = url;
  if (baseURL.pathExtension.length > 0) {
    baseURL = [baseURL URLByDeletingPathExtension];
  }
  return [baseURL URLByAppendingPathExtension:requiredExtension];
}

SavePageFormat SavePageFormatForTag(NSInteger tag) {
  switch (tag) {
    case static_cast<NSInteger>(SavePageFormat::Complete):
      return SavePageFormat::Complete;
    case static_cast<NSInteger>(SavePageFormat::HTMLOnly):
      return SavePageFormat::HTMLOnly;
    case static_cast<NSInteger>(SavePageFormat::SingleFile):
    default:
      return SavePageFormat::SingleFile;
  }
}

int NextDevToolsMessageID() {
  static std::atomic<int> next_message_id{1};
  return next_message_id.fetch_add(1);
}

bool EnsureDirectoryAtPath(NSString *directory_path) {
  NSError *error = nil;
  BOOL didCreate = [[NSFileManager defaultManager] createDirectoryAtPath:directory_path
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:&error];
  if (didCreate) {
    return true;
  }

  PresentSavePageError(
      error.localizedDescription ?: LocalizedBrowserString(@"browser.save_page.error.default"));
  return false;
}

bool RemoveItemIfExistsAtPath(NSString *path) {
  NSFileManager *fileManager = [NSFileManager defaultManager];
  if (![fileManager fileExistsAtPath:path]) {
    return true;
  }

  NSError *error = nil;
  BOOL didRemove = [fileManager removeItemAtPath:path error:&error];
  if (didRemove) {
    return true;
  }

  PresentSavePageError(
      error.localizedDescription ?: LocalizedBrowserString(@"browser.save_page.error.default"));
  return false;
}

NSString *CompleteSaveDirectoryName(NSString *base_name) {
  return [SanitizedSavePageBaseName(base_name) stringByAppendingString:@"_files"];
}

NSString *PreferredExtensionForSaveResource(NSString *mime_type,
                                            NSString *resource_type) {
  NSString *normalizedMIMEType = mime_type.lowercaseString;
  NSString *normalizedResourceType = resource_type.lowercaseString;

  if ([normalizedResourceType isEqualToString:@"document"]) {
    return @"html";
  }
  if ([normalizedResourceType isEqualToString:@"stylesheet"]) {
    return @"css";
  }
  if ([normalizedResourceType isEqualToString:@"script"]) {
    return @"js";
  }
  if ([normalizedMIMEType containsString:@"javascript"]) {
    return @"js";
  }
  if ([normalizedMIMEType containsString:@"json"]) {
    return @"json";
  }
  if ([normalizedMIMEType containsString:@"xml"]) {
    return @"xml";
  }
  if ([normalizedMIMEType hasPrefix:@"text/html"]) {
    return @"html";
  }
  if ([normalizedMIMEType hasPrefix:@"text/css"]) {
    return @"css";
  }

  UTType *type = [UTType typeWithMIMEType:mime_type];
  NSString *preferredExtension = type.preferredFilenameExtension;
  if (preferredExtension.length > 0) {
    return preferredExtension;
  }

  return normalizedMIMEType.length > 0 ? @"dat" : @"";
}

bool ShouldSkipSaveResourceURL(NSString *url_string) {
  NSURL *url = [NSURL URLWithString:url_string];
  NSString *scheme = url.scheme.lowercaseString;
  if (scheme.length == 0) {
    return true;
  }

  return [scheme isEqualToString:@"data"] || [scheme isEqualToString:@"javascript"] ||
         [scheme isEqualToString:@"mailto"] || [scheme isEqualToString:@"tel"] ||
         [scheme isEqualToString:@"about"];
}

NSString *ResolvedSavePageURLString(NSString *raw_value, NSString *base_url_string) {
  NSString *trimmedValue =
      [raw_value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (trimmedValue.length == 0 || [trimmedValue hasPrefix:@"#"]) {
    return nil;
  }

  NSString *unescapedValue =
      [trimmedValue stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
  NSURL *baseURL = [NSURL URLWithString:base_url_string];
  NSURL *resolvedURL =
      [NSURL URLWithString:unescapedValue relativeToURL:baseURL].absoluteURL;
  return resolvedURL.absoluteString;
}

NSRange FirstCapturedRange(NSTextCheckingResult *match,
                           std::initializer_list<NSUInteger> group_indexes) {
  for (NSUInteger groupIndex : group_indexes) {
    NSRange range = [match rangeAtIndex:groupIndex];
    if (range.location != NSNotFound) {
      return range;
    }
  }

  return NSMakeRange(NSNotFound, 0);
}

NSString *RewriteSrcsetValue(NSString *value,
                             NSString *base_url_string,
                             NSDictionary<NSString *, NSString *> *mapping) {
  NSArray<NSString *> *components = [value componentsSeparatedByString:@","];
  NSMutableArray<NSString *> *rewrittenComponents =
      [NSMutableArray arrayWithCapacity:components.count];

  for (NSString *component in components) {
    NSString *trimmedComponent =
        [component stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedComponent.length == 0) {
      continue;
    }

    NSRange separatorRange =
        [trimmedComponent rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *urlPart = separatorRange.location == NSNotFound
                            ? trimmedComponent
                            : [trimmedComponent substringToIndex:separatorRange.location];
    NSString *descriptor = separatorRange.location == NSNotFound
                               ? @""
                               : [trimmedComponent substringFromIndex:separatorRange.location];

    NSString *resolvedURL = ResolvedSavePageURLString(urlPart, base_url_string);
    NSString *mappedValue = resolvedURL.length > 0 ? mapping[resolvedURL] : nil;
    NSString *finalURL = mappedValue.length > 0 ? mappedValue : urlPart;
    [rewrittenComponents addObject:[finalURL stringByAppendingString:descriptor]];
  }

  return [rewrittenComponents componentsJoinedByString:@", "];
}

NSString *RewriteCSSText(NSString *css_text,
                         NSString *base_url_string,
                         NSDictionary<NSString *, NSString *> *mapping) {
  if (css_text.length == 0) {
    return css_text ?: @"";
  }

  NSError *error = nil;
  NSRegularExpression *urlRegex =
      [NSRegularExpression regularExpressionWithPattern:@"(?i)url\\(\\s*(['\"]?)([^'\"\\)]+)\\1\\s*\\)"
                                                options:0
                                                  error:&error];
  if (urlRegex == nil) {
    return css_text;
  }

  NSMutableString *rewrittenText = [css_text mutableCopy];
  NSArray<NSTextCheckingResult *> *urlMatches =
      [urlRegex matchesInString:rewrittenText options:0 range:NSMakeRange(0, rewrittenText.length)];
  for (NSTextCheckingResult *match in urlMatches.reverseObjectEnumerator) {
    NSRange urlRange = [match rangeAtIndex:2];
    if (urlRange.location == NSNotFound) {
      continue;
    }

    NSString *candidateURL = [rewrittenText substringWithRange:urlRange];
    NSString *resolvedURL = ResolvedSavePageURLString(candidateURL, base_url_string);
    NSString *mappedValue = resolvedURL.length > 0 ? mapping[resolvedURL] : nil;
    if (mappedValue.length == 0) {
      continue;
    }

    [rewrittenText replaceCharactersInRange:urlRange withString:mappedValue];
  }

  NSRegularExpression *importRegex =
      [NSRegularExpression regularExpressionWithPattern:@"(?i)@import\\s+['\"]([^'\"]+)['\"]"
                                                options:0
                                                  error:&error];
  if (importRegex == nil) {
    return rewrittenText;
  }

  NSArray<NSTextCheckingResult *> *importMatches =
      [importRegex matchesInString:rewrittenText options:0 range:NSMakeRange(0, rewrittenText.length)];
  for (NSTextCheckingResult *match in importMatches.reverseObjectEnumerator) {
    NSRange urlRange = [match rangeAtIndex:1];
    if (urlRange.location == NSNotFound) {
      continue;
    }

    NSString *candidateURL = [rewrittenText substringWithRange:urlRange];
    NSString *resolvedURL = ResolvedSavePageURLString(candidateURL, base_url_string);
    NSString *mappedValue = resolvedURL.length > 0 ? mapping[resolvedURL] : nil;
    if (mappedValue.length == 0) {
      continue;
    }

    [rewrittenText replaceCharactersInRange:urlRange withString:mappedValue];
  }

  return rewrittenText;
}

NSString *RewriteHTMLText(NSString *html_text,
                          NSString *base_url_string,
                          NSDictionary<NSString *, NSString *> *mapping) {
  if (html_text.length == 0) {
    return html_text ?: @"";
  }

  NSError *error = nil;
  NSMutableString *rewrittenHTML = [html_text mutableCopy];

  NSRegularExpression *styleBlockRegex =
      [NSRegularExpression regularExpressionWithPattern:@"(?is)<style\\b[^>]*>(.*?)</style>"
                                                options:0
                                                  error:&error];
  NSArray<NSTextCheckingResult *> *styleBlockMatches =
      [styleBlockRegex matchesInString:rewrittenHTML
                               options:0
                                 range:NSMakeRange(0, rewrittenHTML.length)];
  for (NSTextCheckingResult *match in styleBlockMatches.reverseObjectEnumerator) {
    NSRange contentRange = [match rangeAtIndex:1];
    if (contentRange.location == NSNotFound) {
      continue;
    }

    NSString *styleText = [rewrittenHTML substringWithRange:contentRange];
    NSString *rewrittenStyle = RewriteCSSText(styleText, base_url_string, mapping);
    if (![rewrittenStyle isEqualToString:styleText]) {
      [rewrittenHTML replaceCharactersInRange:contentRange withString:rewrittenStyle];
    }
  }

  NSRegularExpression *styleAttributeRegex =
      [NSRegularExpression regularExpressionWithPattern:@"(?i)\\bstyle\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
                                                options:0
                                                  error:&error];
  NSArray<NSTextCheckingResult *> *styleAttributeMatches =
      [styleAttributeRegex matchesInString:rewrittenHTML
                                   options:0
                                     range:NSMakeRange(0, rewrittenHTML.length)];
  for (NSTextCheckingResult *match in styleAttributeMatches.reverseObjectEnumerator) {
    NSRange valueRange = FirstCapturedRange(match, {2, 3});
    if (valueRange.location == NSNotFound) {
      continue;
    }

    NSString *styleText = [rewrittenHTML substringWithRange:valueRange];
    NSString *rewrittenStyle = RewriteCSSText(styleText, base_url_string, mapping);
    if (![rewrittenStyle isEqualToString:styleText]) {
      [rewrittenHTML replaceCharactersInRange:valueRange withString:rewrittenStyle];
    }
  }

  NSRegularExpression *srcsetRegex =
      [NSRegularExpression regularExpressionWithPattern:@"(?i)\\bsrcset\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
                                                options:0
                                                  error:&error];
  NSArray<NSTextCheckingResult *> *srcsetMatches =
      [srcsetRegex matchesInString:rewrittenHTML
                           options:0
                             range:NSMakeRange(0, rewrittenHTML.length)];
  for (NSTextCheckingResult *match in srcsetMatches.reverseObjectEnumerator) {
    NSRange valueRange = FirstCapturedRange(match, {2, 3});
    if (valueRange.location == NSNotFound) {
      continue;
    }

    NSString *srcsetText = [rewrittenHTML substringWithRange:valueRange];
    NSString *rewrittenSrcset =
        RewriteSrcsetValue(srcsetText, base_url_string, mapping);
    if (![rewrittenSrcset isEqualToString:srcsetText]) {
      [rewrittenHTML replaceCharactersInRange:valueRange withString:rewrittenSrcset];
    }
  }

  NSRegularExpression *attributeRegex =
      [NSRegularExpression regularExpressionWithPattern:@"(?i)\\b(src|href|poster|data|action)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
                                                options:0
                                                  error:&error];
  NSArray<NSTextCheckingResult *> *attributeMatches =
      [attributeRegex matchesInString:rewrittenHTML
                              options:0
                                range:NSMakeRange(0, rewrittenHTML.length)];
  for (NSTextCheckingResult *match in attributeMatches.reverseObjectEnumerator) {
    NSRange valueRange = FirstCapturedRange(match, {3, 4, 5});
    if (valueRange.location == NSNotFound) {
      continue;
    }

    NSString *attributeValue = [rewrittenHTML substringWithRange:valueRange];
    NSString *resolvedURL =
        ResolvedSavePageURLString(attributeValue, base_url_string);
    NSString *mappedValue = resolvedURL.length > 0 ? mapping[resolvedURL] : nil;
    if (mappedValue.length == 0 || [mappedValue isEqualToString:attributeValue]) {
      continue;
    }

    [rewrittenHTML replaceCharactersInRange:valueRange withString:mappedValue];
  }

  return rewrittenHTML;
}

NSData *DecodedSaveResourceData(NSString *content, bool base64_encoded) {
  if (base64_encoded) {
    return [[NSData alloc] initWithBase64EncodedString:content options:0];
  }

  return [content dataUsingEncoding:NSUTF8StringEncoding];
}

void UpdateSavePanelSelection(NSSavePanel *panel,
                              NSString *base_name,
                              SavePageFormat format) {
  if (panel == nil) {
    return;
  }

  panel.nameFieldStringValue = SuggestedFileName(base_name, format);
  panel.allowedContentTypes = @[ ContentTypeForSavePageFormat(format) ];
}

CefRefPtr<CefDictionaryValue> ParseDevToolsResultDictionary(const void *result,
                                                            size_t result_size) {
  if (result == nullptr || result_size == 0) {
    return nullptr;
  }

  CefRefPtr<CefValue> value =
      CefParseJSON(result, result_size, JSON_PARSER_RFC);
  if (!value || value->GetType() != VTYPE_DICTIONARY) {
    return nullptr;
  }

  return value->GetDictionary();
}

}  // namespace

@implementation SavePageFormatAccessoryController {
  __weak NSSavePanel *_panel;
  NSString *_baseName;
}

- (instancetype)initWithPanel:(NSSavePanel *)panel baseName:(NSString *)baseName {
  self = [super init];
  if (self == nil) {
    return nil;
  }

  _panel = panel;
  _baseName = [baseName copy];
  return self;
}

- (void)formatDidChange:(NSPopUpButton *)sender {
  NSString *currentBaseName =
      _panel.nameFieldStringValue.stringByDeletingPathExtension;
  if (currentBaseName.length == 0) {
    currentBaseName = _baseName;
  }

  UpdateSavePanelSelection(_panel, currentBaseName,
                           SavePageFormatForTag(sender.selectedTag));
}

@end

namespace {

class SavePageSourceVisitor final : public CefStringVisitor {
 public:
  explicit SavePageSourceVisitor(NSString *destination_path)
      : destination_path_([destination_path copy]) {}

  void Visit(const CefString &string) override {
    @autoreleasepool {
      NSString *html = ToNSString(string.ToString());
      if (html == nil) {
        html = @"";
      }

      WriteStringToPath(html, destination_path_);
    }
  }

 private:
  NSString *destination_path_;

  IMPLEMENT_REFCOUNTING(SavePageSourceVisitor);
};

struct SavePageResourceRecord {
  std::string frame_id;
  std::string url;
  std::string mime_type;
  std::string resource_type;
  std::string file_name;
  std::string destination_path;
  std::string content;
  bool is_document = false;
  bool is_main_document = false;
  bool fetched = false;
  bool base64_encoded = false;
};

class SavePageCompleteObserver final : public CefDevToolsMessageObserver {
 public:
  explicit SavePageCompleteObserver(NSString *destination_path)
      : destination_path_(ToStdString(destination_path)),
        destination_file_name_(ToStdString(destination_path.lastPathComponent)) {
    NSString *baseName = destination_path.lastPathComponent.stringByDeletingPathExtension;
    NSString *resourcesDirectoryName = CompleteSaveDirectoryName(baseName);
    resources_directory_name_ = ToStdString(resourcesDirectoryName);
    resources_directory_path_ = ToStdString(
        [destination_path.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:resourcesDirectoryName]);
  }

  void Start(CefRefPtr<CefBrowserHost> host) {
    if (!host) {
      PresentSavePageError(
          LocalizedBrowserString(@"browser.save_page.error.browser_save_failed"));
      return;
    }

    registration_ = host->AddDevToolsMessageObserver(this);
    RequestResourceTree(host);
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void *result,
                              size_t result_size) override {
    if (message_id != message_id_) {
      return;
    }

    CefRefPtr<CefBrowserHost> host = browser ? browser->GetHost() : nullptr;
    if (!host) {
      registration_ = nullptr;
      PresentSavePageError(
          LocalizedBrowserString(@"browser.save_page.error.browser_save_failed"));
      return;
    }

    switch (stage_) {
      case Stage::FetchResourceTree:
        HandleResourceTreeResult(host, success, result, result_size);
        return;
      case Stage::FetchResourceContent:
        HandleResourceContentResult(host, success, result, result_size);
        return;
      case Stage::SerializeMainDocument:
        HandleSerializeMainDocumentResult(success, result, result_size);
        return;
      case Stage::Idle:
        return;
    }
  }

  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override {
    if (registration_ == nullptr) {
      return;
    }

    registration_ = nullptr;
    PresentSavePageError(
        LocalizedBrowserString(@"browser.save_page.error.devtools_detached"));
  }

 private:
  enum class Stage {
    Idle,
    FetchResourceTree,
    FetchResourceContent,
    SerializeMainDocument,
  };

  std::string MakeUniqueFileName(const std::string &url,
                                 const std::string &mime_type,
                                 const std::string &resource_type) {
    @autoreleasepool {
      NSString *urlString = ToNSString(url);
      NSURL *resourceURL = [NSURL URLWithString:urlString];
      NSString *candidateName =
          resourceURL.lastPathComponent.stringByRemovingPercentEncoding
              ?: resourceURL.lastPathComponent;
      NSString *baseName = candidateName.stringByDeletingPathExtension;
      NSString *extension = candidateName.pathExtension.lowercaseString;

      if (baseName.length == 0) {
        baseName = resourceURL.host;
      }
      if (baseName.length == 0) {
        baseName = resource_type.length() > 0 ? ToNSString(resource_type).lowercaseString
                                            : @"resource";
      }

      baseName = SanitizedSavePageBaseName(baseName);
      if (extension.length == 0) {
        extension = PreferredExtensionForSaveResource(ToNSString(mime_type),
                                                      ToNSString(resource_type));
      }

      NSString *fileName =
          extension.length > 0 ? [baseName stringByAppendingPathExtension:extension]
                               : baseName;
      std::string uniqueName = ToStdString(fileName);
      NSUInteger suffix = 2;
      while (used_file_names_.find(uniqueName) != used_file_names_.end()) {
        NSString *suffixedName =
            extension.length > 0
                ? [[NSString stringWithFormat:@"%@-%lu", baseName,
                                                 static_cast<unsigned long>(suffix)]
                      stringByAppendingPathExtension:extension]
                : [NSString stringWithFormat:@"%@-%lu", baseName,
                                                 static_cast<unsigned long>(suffix)];
        uniqueName = ToStdString(suffixedName);
        suffix += 1;
      }

      used_file_names_.insert(uniqueName);
      return uniqueName;
    }
  }

  void AddResource(const std::string &frame_id,
                   const std::string &url,
                   const std::string &mime_type,
                   const std::string &resource_type,
                   bool is_main_document) {
    if (url.empty() || seen_urls_.find(url) != seen_urls_.end()) {
      return;
    }

    NSString *urlString = ToNSString(url);
    if (ShouldSkipSaveResourceURL(urlString)) {
      return;
    }

    SavePageResourceRecord resource;
    resource.frame_id = frame_id;
    resource.url = url;
    resource.mime_type = mime_type;
    resource.resource_type = resource_type;
    resource.is_document =
        [ToNSString(resource_type).lowercaseString isEqualToString:@"document"];
    resource.is_main_document = is_main_document;

    if (!is_main_document) {
      resource.file_name = MakeUniqueFileName(url, mime_type, resource_type);
      NSString *destinationPath =
          [ToNSString(resources_directory_path_)
              stringByAppendingPathComponent:ToNSString(resource.file_name)];
      resource.destination_path = ToStdString(destinationPath);
    }

    seen_urls_.insert(url);
    resources_.push_back(resource);
  }

  void CollectFrameTreeResources(CefRefPtr<CefDictionaryValue> frame_tree,
                                 bool is_main_frame) {
    if (!frame_tree) {
      return;
    }

    CefRefPtr<CefDictionaryValue> frame = frame_tree->GetDictionary("frame");
    if (!frame) {
      return;
    }

    std::string frame_id = frame->GetString("id").ToString();
    std::string frame_url = frame->GetString("url").ToString();
    std::string frame_mime_type = frame->GetString("mimeType").ToString();

    if (is_main_frame) {
      main_frame_url_ = frame_url;
    }

    if (!frame_url.empty()) {
      AddResource(frame_id, frame_url, frame_mime_type, "Document", is_main_frame);
    }

    CefRefPtr<CefListValue> frame_resources = frame_tree->GetList("resources");
    if (frame_resources) {
      for (size_t index = 0; index < frame_resources->GetSize(); ++index) {
        CefRefPtr<CefDictionaryValue> resource = frame_resources->GetDictionary(index);
        if (!resource || resource->GetBool("failed") || resource->GetBool("canceled")) {
          continue;
        }

        AddResource(frame_id, resource->GetString("url").ToString(),
                    resource->GetString("mimeType").ToString(),
                    resource->GetString("type").ToString(), false);
      }
    }

    CefRefPtr<CefListValue> child_frames = frame_tree->GetList("childFrames");
    if (!child_frames) {
      return;
    }

    for (size_t index = 0; index < child_frames->GetSize(); ++index) {
      CollectFrameTreeResources(child_frames->GetDictionary(index), false);
    }
  }

  void RequestResourceTree(CefRefPtr<CefBrowserHost> host) {
    stage_ = Stage::FetchResourceTree;
    message_id_ = NextDevToolsMessageID();
    if (host->ExecuteDevToolsMethod(message_id_, kSavePageResourceTreeMethod,
                                    nullptr) == 0) {
      registration_ = nullptr;
      PresentSavePageError(
          LocalizedBrowserString(@"browser.save_page.error.inspect_resources"));
    }
  }

  void RequestCurrentResourceContent(CefRefPtr<CefBrowserHost> host) {
    if (current_resource_index_ >= resources_.size()) {
      RequestMainDocumentSerialization(host);
      return;
    }

    const SavePageResourceRecord &resource = resources_[current_resource_index_];
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("frameId", resource.frame_id);
    params->SetString("url", resource.url);

    stage_ = Stage::FetchResourceContent;
    message_id_ = NextDevToolsMessageID();
    if (host->ExecuteDevToolsMethod(message_id_, kSavePageResourceContentMethod,
                                    params) == 0) {
      current_resource_index_ += 1;
      RequestCurrentResourceContent(host);
    }
  }

  void RequestMainDocumentSerialization(CefRefPtr<CefBrowserHost> host) {
    stage_ = Stage::SerializeMainDocument;

    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString(
        "expression",
        "(function(){const doc=document;const doctype=doc.doctype?"
        "new XMLSerializer().serializeToString(doc.doctype)+'\\n':'';"
        "const root=doc.documentElement?doc.documentElement.outerHTML:'';"
        "return doctype+root;})()");
    params->SetBool("returnByValue", true);
    params->SetBool("awaitPromise", true);

    message_id_ = NextDevToolsMessageID();
    if (host->ExecuteDevToolsMethod(message_id_, kSavePageSerializeDocumentMethod,
                                    params) == 0) {
      WriteCompletePackage(std::string());
    }
  }

  SavePageResourceRecord *MainDocumentResource() {
    for (SavePageResourceRecord &resource : resources_) {
      if (resource.is_main_document) {
        return &resource;
      }
    }

    return nullptr;
  }

  NSDictionary<NSString *, NSString *> *BuildRootContextMapping() const {
    NSMutableDictionary<NSString *, NSString *> *mapping = [NSMutableDictionary dictionary];
    if (!main_frame_url_.empty()) {
      mapping[ToNSString(main_frame_url_)] = ToNSString(destination_file_name_);
    }

    NSString *resourcesDirectoryName = ToNSString(resources_directory_name_);
    for (const SavePageResourceRecord &resource : resources_) {
      if (resource.is_main_document || !resource.fetched || resource.file_name.empty()) {
        continue;
      }

      mapping[ToNSString(resource.url)] =
          [resourcesDirectoryName stringByAppendingPathComponent:ToNSString(resource.file_name)];
    }

    return mapping;
  }

  NSDictionary<NSString *, NSString *> *BuildResourceContextMapping() const {
    NSMutableDictionary<NSString *, NSString *> *mapping = [NSMutableDictionary dictionary];
    if (!main_frame_url_.empty()) {
      mapping[ToNSString(main_frame_url_)] =
          [@".." stringByAppendingPathComponent:ToNSString(destination_file_name_)];
    }

    for (const SavePageResourceRecord &resource : resources_) {
      if (resource.is_main_document || !resource.fetched || resource.file_name.empty()) {
        continue;
      }

      mapping[ToNSString(resource.url)] = ToNSString(resource.file_name);
    }

    return mapping;
  }

  bool WriteFetchedResource(const SavePageResourceRecord &resource,
                            NSDictionary<NSString *, NSString *> *resource_mapping) const {
    NSString *destinationPath = ToNSString(resource.destination_path);
    NSString *content = ToNSString(resource.content);

    if (resource.is_document) {
      NSString *rewrittenHTML =
          RewriteHTMLText(content, ToNSString(resource.url), resource_mapping);
      return WriteStringToPath(rewrittenHTML, destinationPath);
    }

    if ([ToNSString(resource.resource_type).lowercaseString isEqualToString:@"stylesheet"]) {
      NSString *rewrittenCSS =
          RewriteCSSText(content, ToNSString(resource.url), resource_mapping);
      return WriteStringToPath(rewrittenCSS, destinationPath);
    }

    NSData *data = DecodedSaveResourceData(content, resource.base64_encoded);
    if (data == nil) {
      PresentSavePageError(
          LocalizedBrowserString(@"browser.save_page.error.invalid_resource_payload"));
      return false;
    }

    return WriteDataToPath(data, destinationPath);
  }

  void WriteCompletePackage(const std::string &serialized_main_document) {
    registration_ = nullptr;

    NSString *resourcesDirectoryPath = ToNSString(resources_directory_path_);
    if (!RemoveItemIfExistsAtPath(resourcesDirectoryPath)) {
      return;
    }

    bool hasFetchedAuxiliaryResources = false;
    for (const SavePageResourceRecord &resource : resources_) {
      if (!resource.is_main_document && resource.fetched) {
        hasFetchedAuxiliaryResources = true;
        break;
      }
    }

    if (hasFetchedAuxiliaryResources && !EnsureDirectoryAtPath(resourcesDirectoryPath)) {
      return;
    }

    NSDictionary<NSString *, NSString *> *rootMapping = BuildRootContextMapping();
    NSDictionary<NSString *, NSString *> *resourceMapping = BuildResourceContextMapping();

    for (const SavePageResourceRecord &resource : resources_) {
      if (resource.is_main_document || !resource.fetched || resource.destination_path.empty()) {
        continue;
      }

      if (!WriteFetchedResource(resource, resourceMapping)) {
        return;
      }
    }

    SavePageResourceRecord *mainDocument = MainDocumentResource();
    NSString *mainDocumentContent = serialized_main_document.empty()
                                        ? (mainDocument != nullptr ? ToNSString(mainDocument->content) : @"")
                                        : ToNSString(serialized_main_document);
    if (mainDocumentContent.length == 0) {
      PresentSavePageError(
          LocalizedBrowserString(@"browser.save_page.error.serialize_document"));
      return;
    }

    NSString *rewrittenMainHTML =
        RewriteHTMLText(mainDocumentContent, ToNSString(main_frame_url_), rootMapping);
    WriteStringToPath(rewrittenMainHTML, ToNSString(destination_path_));
  }

  void HandleResourceTreeResult(CefRefPtr<CefBrowserHost> host,
                                bool success,
                                const void *result,
                                size_t result_size) {
    if (!success) {
      registration_ = nullptr;
      PresentSavePageError(
          LocalizedBrowserString(@"browser.save_page.error.inspect_resources"));
      return;
    }

    CefRefPtr<CefDictionaryValue> dictionary =
        ParseDevToolsResultDictionary(result, result_size);
    CefRefPtr<CefDictionaryValue> frameTree =
        dictionary ? dictionary->GetDictionary("frameTree") : nullptr;
    if (!frameTree) {
      registration_ = nullptr;
      PresentSavePageError(
          LocalizedBrowserString(@"browser.save_page.error.invalid_resource_tree"));
      return;
    }

    CollectFrameTreeResources(frameTree, true);
    current_resource_index_ = 0;
    RequestCurrentResourceContent(host);
  }

  void HandleResourceContentResult(CefRefPtr<CefBrowserHost> host,
                                   bool success,
                                   const void *result,
                                   size_t result_size) {
    if (current_resource_index_ >= resources_.size()) {
      RequestMainDocumentSerialization(host);
      return;
    }

    SavePageResourceRecord &resource = resources_[current_resource_index_];
    if (success) {
      CefRefPtr<CefDictionaryValue> dictionary =
          ParseDevToolsResultDictionary(result, result_size);
      if (dictionary) {
        resource.content = dictionary->GetString("content").ToString();
        resource.base64_encoded = dictionary->GetBool("base64Encoded");
        resource.fetched = true;
      }
    }

    current_resource_index_ += 1;
    RequestCurrentResourceContent(host);
  }

  void HandleSerializeMainDocumentResult(bool success,
                                         const void *result,
                                         size_t result_size) {
    std::string serializedDocument;
    if (success) {
      CefRefPtr<CefDictionaryValue> dictionary =
          ParseDevToolsResultDictionary(result, result_size);
      CefRefPtr<CefDictionaryValue> resultDictionary =
          dictionary ? dictionary->GetDictionary("result") : nullptr;
      serializedDocument = resultDictionary ? resultDictionary->GetString("value").ToString()
                                            : std::string();
    }

    WriteCompletePackage(serializedDocument);
  }

  Stage stage_ = Stage::Idle;
  int message_id_ = 0;
  size_t current_resource_index_ = 0;
  std::string destination_path_;
  std::string destination_file_name_;
  std::string resources_directory_name_;
  std::string resources_directory_path_;
  std::string main_frame_url_;
  std::set<std::string> seen_urls_;
  std::set<std::string> used_file_names_;
  std::vector<SavePageResourceRecord> resources_;
  CefRefPtr<CefRegistration> registration_;

  IMPLEMENT_REFCOUNTING(SavePageCompleteObserver);
};

class SavePageSnapshotObserver final : public CefDevToolsMessageObserver {
 public:
  explicit SavePageSnapshotObserver(NSString *destination_path)
      : destination_path_([destination_path copy]) {}

  void SetMessageID(int message_id) { message_id_ = message_id; }

  void SetRegistration(CefRefPtr<CefRegistration> registration) {
    registration_ = registration;
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void *result,
                              size_t result_size) override {
    if (message_id != message_id_) {
      return;
    }

    registration_ = nullptr;

    if (!browser || !success || result == nullptr || result_size == 0) {
      PresentSavePageError(
          LocalizedBrowserString(@"browser.save_page.error.create_snapshot"));
      return;
    }

    CefRefPtr<CefDictionaryValue> dictionary =
        ParseDevToolsResultDictionary(result, result_size);
    if (!dictionary) {
      PresentSavePageError(
          LocalizedBrowserString(@"browser.save_page.error.invalid_snapshot_payload"));
      return;
    }

    NSString *snapshot = ToNSString(dictionary->GetString("data").ToString());
    if (snapshot.length == 0) {
      PresentSavePageError(
          LocalizedBrowserString(@"browser.save_page.error.empty_snapshot"));
      return;
    }

    WriteStringToPath(snapshot, destination_path_);
  }

  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override {
    if (!browser || registration_ == nullptr) {
      return;
    }

    registration_ = nullptr;
    PresentSavePageError(
        LocalizedBrowserString(@"browser.save_page.error.snapshot_detached"));
  }

 private:
  int message_id_ = 0;
  NSString *destination_path_;
  CefRefPtr<CefRegistration> registration_;

  IMPLEMENT_REFCOUNTING(SavePageSnapshotObserver);
};

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
  const NSRect targetFrame =
      NSMakeRect(0, 0, NSWidth(hostBounds), NSHeight(hostBounds));
  browserView.frame = targetFrame;
}

NSView *BrowserViewForBrowser(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return nil;
  }
  if (CefBrowserView::GetForBrowser(browser)) {
    return nil;
  }
  return CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
}

NSWindow *NativeWindowForCefWindow(CefRefPtr<CefWindow> window) {
  if (!window) {
    return nil;
  }

  id nativeHandle = (__bridge id)window->GetWindowHandle();
  if ([nativeHandle isKindOfClass:NSWindow.class]) {
    return (NSWindow *)nativeHandle;
  }
  if ([nativeHandle isKindOfClass:NSView.class]) {
    return [(NSView *)nativeHandle window];
  }
  return nil;
}

NSRect ScreenFrameForHostView(BrowserTabHostView *hostView) {
  if (hostView == nil || hostView.window == nil || NSIsEmptyRect(hostView.bounds)) {
    return NSZeroRect;
  }

  NSRect windowFrame = [hostView convertRect:hostView.bounds toView:nil];
  return [hostView.window convertRectToScreen:windowFrame];
}

void ConfigureNativeBrowserWindow(NSWindow *browserWindow) {
  if (browserWindow == nil) {
    return;
  }

  browserWindow.hasShadow = false;
  browserWindow.opaque = true;
  browserWindow.backgroundColor = NSColor.blackColor;
  browserWindow.styleMask = browserWindow.styleMask & ~NSWindowStyleMaskResizable;
  browserWindow.movable = false;
  browserWindow.movableByWindowBackground = false;
  browserWindow.collectionBehavior =
      browserWindow.collectionBehavior | NSWindowCollectionBehaviorFullScreenAuxiliary;
}

void AttachBrowserWindowToHost(NSWindow *browserWindow, BrowserTabHostView *hostView) {
  if (browserWindow == nil || hostView.window == nil) {
    return;
  }

  NSWindow *parentWindow = hostView.window;
  if (browserWindow.parentWindow != parentWindow) {
    [browserWindow.parentWindow removeChildWindow:browserWindow];
    [parentWindow addChildWindow:browserWindow ordered:NSWindowAbove];
  }
}

void DetachBrowserWindow(NSWindow *browserWindow) {
  if (browserWindow == nil) {
    return;
  }

  [browserWindow.parentWindow removeChildWindow:browserWindow];
  [browserWindow orderOut:nil];
}

void SyncNativeBrowserWindowFrame(BrowserTabHostView *hostView,
                                  NSWindow *browserWindow) {
  if (browserWindow == nil) {
    return;
  }

  NSRect screenFrame = ScreenFrameForHostView(hostView);
  if (NSIsEmptyRect(screenFrame)) {
    [browserWindow orderOut:nil];
    return;
  }

  AttachBrowserWindowToHost(browserWindow, hostView);
  if (!NSEqualRects(browserWindow.frame, screenFrame)) {
    [browserWindow setFrame:screenFrame display:YES];
  }
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

void NavigateBrowser(CefRefPtr<CefBrowser> browser, std::string url) {
  if (!browser || url.empty()) {
    return;
  }

  CefRefPtr<CefFrame> frame = browser->GetMainFrame();
  if (!frame) {
    return;
  }

  frame->LoadURL(url);
}

void NavigateBrowserOnUI(CefRefPtr<CefBrowser> browser,
                         std::string url) {
  if (!browser || url.empty()) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    NavigateBrowser(browser, url);
    return;
  }

  CefPostTask(TID_UI,
              CefCreateClosureTask(
                  base::BindOnce(&NavigateBrowser, browser, url)));
}

void StopLoadingBrowser(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  browser->StopLoad();
}

void StopLoadingBrowserOnUI(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    StopLoadingBrowser(browser);
    return;
  }

  CefPostTask(
      TID_UI,
      CefCreateClosureTask(base::BindOnce(&StopLoadingBrowser, browser)));
}

void SavePageBrowser(CefRefPtr<CefBrowser> browser, NSString *suggested_name) {
  if (!browser) {
    return;
  }

  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  CefRefPtr<CefFrame> mainFrame = browser->GetMainFrame();
  NSString *suggestedBaseName = SanitizedSavePageBaseName(suggested_name);
  if (suggested_name.length == 0 && mainFrame && mainFrame->IsValid()) {
    NSString *urlString = ToNSString(mainFrame->GetURL().ToString());
    NSURL *url = [NSURL URLWithString:urlString];
    NSString *candidate = url.lastPathComponent;
    if (candidate.length == 0) {
      candidate = url.host;
    }
    candidate = candidate.stringByRemovingPercentEncoding ?: candidate;
    suggestedBaseName = SanitizedSavePageBaseName(candidate);
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    SavePageFormat defaultFormat = SavePageFormat::Complete;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = LocalizedBrowserString(@"browser.save_page.title");
    panel.prompt = LocalizedBrowserString(@"browser.save_page.prompt");
    panel.canCreateDirectories = YES;
    UpdateSavePanelSelection(panel, suggestedBaseName, defaultFormat);

    NSTextField *formatLabel =
        [NSTextField labelWithString:LocalizedBrowserString(@"browser.save_page.format")];
    NSPopUpButton *formatPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [formatPopup addItemWithTitle:LocalizedBrowserString(@"browser.save_page.format.complete")];
    [formatPopup addItemWithTitle:LocalizedBrowserString(@"browser.save_page.format.single_file")];
    [formatPopup addItemWithTitle:LocalizedBrowserString(@"browser.save_page.format.html_only")];
    [[formatPopup itemAtIndex:0] setTag:static_cast<NSInteger>(SavePageFormat::Complete)];
    [[formatPopup itemAtIndex:1] setTag:static_cast<NSInteger>(SavePageFormat::SingleFile)];
    [[formatPopup itemAtIndex:2] setTag:static_cast<NSInteger>(SavePageFormat::HTMLOnly)];
    [formatPopup selectItemAtIndex:0];

    SavePageFormatAccessoryController *formatController =
        [[SavePageFormatAccessoryController alloc] initWithPanel:panel
                                                        baseName:suggestedBaseName];
    formatPopup.target = formatController;
    formatPopup.action = @selector(formatDidChange:);

    NSStackView *formatRow = [[NSStackView alloc] init];
    formatRow.translatesAutoresizingMaskIntoConstraints = NO;
    formatRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    formatRow.alignment = NSLayoutAttributeFirstBaseline;
    formatRow.spacing = 8;
    [formatRow addArrangedSubview:formatLabel];
    [formatRow addArrangedSubview:formatPopup];

    NSView *accessoryView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 28)];
    [accessoryView addSubview:formatRow];
    [NSLayoutConstraint activateConstraints:@[
      [formatRow.centerXAnchor constraintEqualToAnchor:accessoryView.centerXAnchor],
      [formatRow.topAnchor constraintEqualToAnchor:accessoryView.topAnchor],
      [formatRow.bottomAnchor constraintEqualToAnchor:accessoryView.bottomAnchor],
    ]];
    panel.accessoryView = accessoryView;

    void (^completionHandler)(NSModalResponse) = ^(NSModalResponse response) {
      (void)formatController;
      if (response != NSModalResponseOK || panel.URL == nil) {
        return;
      }

      SavePageFormat selectedFormat =
          SavePageFormatForTag(formatPopup.selectedTag);
      NSURL *destinationURL = NormalizedSaveURL(panel.URL, selectedFormat);
      if (destinationURL == nil) {
        PresentSavePageError(
            LocalizedBrowserString(@"browser.save_page.error.invalid_location"));
        return;
      }

      CefRefPtr<CefFrame> selectedFrame = browser->GetMainFrame();
      if (!selectedFrame || !selectedFrame->IsValid()) {
        return;
      }

      switch (selectedFormat) {
        case SavePageFormat::Complete:
          if (!host) {
            PresentSavePageError(
                LocalizedBrowserString(@"browser.save_page.error.browser_save_failed"));
            return;
          }

          {
            CefRefPtr<SavePageCompleteObserver> observer =
                new SavePageCompleteObserver(destinationURL.path);
            observer->Start(host);
          }
          return;
        case SavePageFormat::HTMLOnly:
          selectedFrame->GetSource(
              new SavePageSourceVisitor(destinationURL.path));
          return;
        case SavePageFormat::SingleFile: {
          if (!host) {
            PresentSavePageError(
                LocalizedBrowserString(@"browser.save_page.error.browser_save_failed"));
            return;
          }

          CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
          params->SetString("format", "mhtml");

          CefRefPtr<SavePageSnapshotObserver> observer =
              new SavePageSnapshotObserver(destinationURL.path);
          observer->SetRegistration(
              host->AddDevToolsMessageObserver(observer));
          int messageID = NextDevToolsMessageID();
          observer->SetMessageID(messageID);
          if (host->ExecuteDevToolsMethod(
                  messageID,
                  kSavePageSingleFileMethod,
                  params) == 0) {
            observer->SetRegistration(nullptr);
            PresentSavePageError(
                LocalizedBrowserString(@"browser.save_page.error.start_snapshot"));
          }
          return;
        }
      }
    };

    NSWindow *window = BrowserViewForBrowser(browser).window ?: NSApp.keyWindow;
    if (window != nil) {
      [panel beginSheetModalForWindow:window completionHandler:completionHandler];
      return;
    }

    completionHandler([panel runModal]);
  });
}

void SavePageBrowserOnUI(CefRefPtr<CefBrowser> browser, NSString *suggested_name) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    SavePageBrowser(browser, suggested_name);
    return;
  }

  CefPostTask(
      TID_UI,
      CefCreateClosureTask(
          base::BindOnce(&SavePageBrowser, browser, suggested_name)));
}

void PrintBrowser(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (host) {
    host->Print();
  }
}

void PrintBrowserOnUI(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    PrintBrowser(browser);
    return;
  }

  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(&PrintBrowser, browser)));
}

void PasteAndMatchStyleBrowser(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  CefRefPtr<CefFrame> frame = browser->GetFocusedFrame();
  if (frame) {
    frame->PasteAndMatchStyle();
  }
}

void PasteAndMatchStyleBrowserOnUI(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    PasteAndMatchStyleBrowser(browser);
    return;
  }

  CefPostTask(
      TID_UI,
      CefCreateClosureTask(base::BindOnce(&PasteAndMatchStyleBrowser, browser)));
}

void FindBrowser(CefRefPtr<CefBrowser> browser,
                 NSString *text,
                 bool forward,
                 bool match_case,
                 bool find_next) {
  if (!browser) {
    return;
  }

  if (text.length == 0) {
    CefRefPtr<CefBrowserHost> host = browser->GetHost();
    if (host) {
      host->StopFinding(true);
    }
    return;
  }

  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (host) {
    host->Find(ToStdString(text), forward, match_case, find_next);
  }
}

void FindBrowserOnUI(CefRefPtr<CefBrowser> browser,
                     NSString *text,
                     bool forward,
                     bool match_case,
                     bool find_next) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    FindBrowser(browser, text, forward, match_case, find_next);
    return;
  }

  CefPostTask(TID_UI,
              CefCreateClosureTask(base::BindOnce(
                  &FindBrowser, browser, text, forward, match_case, find_next)));
}

void StopFindingBrowser(CefRefPtr<CefBrowser> browser, bool clear_selection) {
  if (!browser) {
    return;
  }

  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (host) {
    host->StopFinding(clear_selection);
  }
}

void StopFindingBrowserOnUI(CefRefPtr<CefBrowser> browser, bool clear_selection) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    StopFindingBrowser(browser, clear_selection);
    return;
  }

  CefPostTask(TID_UI,
              CefCreateClosureTask(
                  base::BindOnce(&StopFindingBrowser, browser, clear_selection)));
}

void GoBackBrowser(CefRefPtr<CefBrowser> browser) {
  if (browser && browser->CanGoBack()) {
    browser->GoBack();
  }
}

void GoBackBrowserOnUI(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    GoBackBrowser(browser);
    return;
  }

  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(&GoBackBrowser, browser)));
}

void GoForwardBrowser(CefRefPtr<CefBrowser> browser) {
  if (browser && browser->CanGoForward()) {
    browser->GoForward();
  }
}

void GoForwardBrowserOnUI(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    GoForwardBrowser(browser);
    return;
  }

  CefPostTask(TID_UI,
              CefCreateClosureTask(base::BindOnce(&GoForwardBrowser, browser)));
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

std::string URLPartToString(const cef_string_t &value) {
  return CefString(&value).ToString();
}

std::string LowercaseASCII(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char character) {
                   return static_cast<char>(std::tolower(character));
                 });
  return value;
}

std::string TheBrowserURLForChromiumInternalURL(const CefString &url) {
  std::string urlString = LowercaseASCII(url.ToString());
  if (urlString == "about:credits") {
    return shared::kTheBrowserCreditsURL;
  }
  if (urlString == "about:settings") {
    return shared::kTheBrowserSettingsURL;
  }

  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return std::string();
  }

  if (LowercaseASCII(URLPartToString(parts.scheme)) != "chrome") {
    return std::string();
  }

  std::string host = LowercaseASCII(URLPartToString(parts.host));
  if (host.empty()) {
    return std::string();
  }

  std::string path = URLPartToString(parts.path);
  if (path.empty()) {
    path = "/";
  }

  std::string redirectURL = std::string(shared::kTheBrowserScheme) + "://" +
                            host + path;
  std::string query = URLPartToString(parts.query);
  if (!query.empty()) {
    redirectURL += "?" + query;
  }
  std::string fragment = URLPartToString(parts.fragment);
  if (!fragment.empty()) {
    redirectURL += "#" + fragment;
  }
  return redirectURL;
}

bool IsChromiumSettingsURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) == "chrome" &&
         LowercaseASCII(URLPartToString(parts.host)) ==
             shared::kTheBrowserSettingsHost;
}

bool IsTheBrowserSettingsURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) ==
             shared::kTheBrowserScheme &&
         LowercaseASCII(URLPartToString(parts.host)) ==
             shared::kTheBrowserSettingsHost;
}

std::string ChromiumSettingsURLForTheBrowserSettingsURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts) || !IsTheBrowserSettingsURL(url)) {
    return std::string();
  }

  std::string path = URLPartToString(parts.path);
  if (path.empty()) {
    path = "/";
  }

  std::string chromiumURL = "chrome://" +
                            std::string(shared::kTheBrowserSettingsHost) +
                            path;
  std::string query = URLPartToString(parts.query);
  if (!query.empty()) {
    chromiumURL += "?" + query;
  }
  std::string fragment = URLPartToString(parts.fragment);
  if (!fragment.empty()) {
    chromiumURL += "#" + fragment;
  }
  return chromiumURL;
}

std::string DisplayURLStringForCommittedURL(const CefString &url) {
  if (IsChromiumSettingsURL(url)) {
    std::string displayURL = TheBrowserURLForChromiumInternalURL(url);
    if (!displayURL.empty()) {
      return displayURL;
    }
  }

  return url.ToString();
}

bool ShouldUseChromeWindowForURL(const std::string &urlString) {
  if (LowercaseASCII(urlString) == "about:settings") {
    return true;
  }

  CefString url(urlString);
  return IsChromiumSettingsURL(url) || IsTheBrowserSettingsURL(url);
}

bool FocusSettingsSearchInBrowser(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();

  if (!browser || !CefBrowserView::GetForBrowser(browser)) {
    return false;
  }

  CefRefPtr<CefFrame> mainFrame = browser->GetMainFrame();
  if (!mainFrame || !ShouldUseChromeWindowForURL(mainFrame->GetURL().ToString())) {
    return false;
  }

  mainFrame->ExecuteJavaScript(kFocusSettingsSearchScript, mainFrame->GetURL(), 1);
  return true;
}

void FocusSettingsSearchInBrowserIgnoringResult(CefRefPtr<CefBrowser> browser) {
  (void)FocusSettingsSearchInBrowser(browser);
}

bool FocusSettingsSearchInBrowserOnUI(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return false;
  }

  if (CefCurrentlyOn(TID_UI)) {
    return FocusSettingsSearchInBrowser(browser);
  }

  CefPostTask(
      TID_UI,
      CefCreateClosureTask(
          base::BindOnce(&FocusSettingsSearchInBrowserIgnoringResult, browser)));
  return true;
}

bool IsCommandFindShortcut(const CefKeyEvent &event) {
  if (event.type != KEYEVENT_RAWKEYDOWN && event.type != KEYEVENT_KEYDOWN) {
    return false;
  }

  if ((event.modifiers & EVENTFLAG_COMMAND_DOWN) == 0) {
    return false;
  }

  if ((event.modifiers &
       (EVENTFLAG_SHIFT_DOWN | EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN)) != 0) {
    return false;
  }

  return event.windows_key_code == 'F' ||
         event.unmodified_character == 'f' ||
         event.unmodified_character == 'F' ||
         event.character == 'f' ||
         event.character == 'F';
}

class BrowserTabClient final : public CefClient,
                               public CefDisplayHandler,
                               public CefKeyboardHandler,
                               public CefLifeSpanHandler,
                               public CefLoadHandler,
                               public CefRequestHandler,
                               public CefPermissionHandler,
                               public CefFindHandler {
 public:
  BrowserTabClient(BrowserTabController *controller, const std::string &tabID)
      : controller_(controller), tab_id_(tabID) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return this;
  }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString &url) override;

  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString &title) override;

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString> &icon_urls) override;
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool /*isLoading*/,
                            bool canGoBack,
                            bool canGoForward) override;
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override;
  void OnFindResult(CefRefPtr<CefBrowser> browser,
                    int identifier,
                    int count,
                    const CefRect &selectionRect,
                    int activeMatchOrdinal,
                    bool finalUpdate) override;
  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                     const CefKeyEvent &event,
                     CefEventHandle os_event,
                     bool *is_keyboard_shortcut) override;

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
  bool allow_next_chromium_settings_navigation_ = false;

  IMPLEMENT_REFCOUNTING(BrowserTabClient);
};

class BrowserPopupWindowDelegate final : public CefWindowDelegate {
 public:
  explicit BrowserPopupWindowDelegate(CefRefPtr<CefBrowserView> browser_view)
      : browser_view_(browser_view) {}

  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window->AddChildView(browser_view_);
    window->Show();
    browser_view_->RequestFocus();
  }

  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override {
    browser_view_ = nullptr;
  }

  bool CanClose(CefRefPtr<CefWindow> window) override {
    auto browser = browser_view_ ? browser_view_->GetBrowser() : nullptr;
    return browser ? browser->GetHost()->TryCloseBrowser() : true;
  }

  CefSize GetPreferredSize(CefRefPtr<CefView> view) override {
    return CefSize(960, 700);
  }

  cef_runtime_style_t GetWindowRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }

 private:
  CefRefPtr<CefBrowserView> browser_view_;

  IMPLEMENT_REFCOUNTING(BrowserPopupWindowDelegate);
};

class BrowserTabBrowserViewDelegate final : public CefBrowserViewDelegate {
 public:
  CefRefPtr<CefBrowserViewDelegate> GetDelegateForPopupBrowserView(
      CefRefPtr<CefBrowserView> browser_view,
      const CefBrowserSettings& settings,
      CefRefPtr<CefClient> client,
      bool is_devtools) override {
    return new BrowserTabBrowserViewDelegate();
  }

  bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView> browser_view,
                                 CefRefPtr<CefBrowserView> popup_browser_view,
                                 bool is_devtools) override {
    CefWindow::CreateTopLevelWindow(
        new BrowserPopupWindowDelegate(popup_browser_view));
    return true;
  }

  ChromeToolbarType GetChromeToolbarType(
      CefRefPtr<CefBrowserView> browser_view) override {
    return CEF_CTT_NONE;
  }

  cef_runtime_style_t GetBrowserRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }

 private:
  IMPLEMENT_REFCOUNTING(BrowserTabBrowserViewDelegate);
};

class BrowserTabWindowDelegate final : public CefWindowDelegate {
 public:
  BrowserTabWindowDelegate(BrowserTabController *controller,
                           std::string tab_id,
                           CefRefPtr<CefBrowserView> browser_view)
      : controller_(controller),
        tab_id_(std::move(tab_id)),
        browser_view_(browser_view) {}

  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window->AddChildView(browser_view_);

    BrowserTabController *controller = controller_;
    if (controller != nil) {
      [controller handleChromeWindowCreated:window forTabID:ToNSString(tab_id_)];
    }
  }

  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override {
    browser_view_ = nullptr;

    BrowserTabController *controller = controller_;
    if (controller != nil) {
      [controller handleChromeWindowDestroyedForTabID:ToNSString(tab_id_)];
    }
  }

  bool CanClose(CefRefPtr<CefWindow> window) override {
    auto browser = browser_view_ ? browser_view_->GetBrowser() : nullptr;
    return browser ? browser->GetHost()->TryCloseBrowser() : true;
  }

  CefSize GetPreferredSize(CefRefPtr<CefView> view) override {
    return CefSize(1280, 900);
  }

  cef_show_state_t GetInitialShowState(CefRefPtr<CefWindow> window) override {
    return CEF_SHOW_STATE_HIDDEN;
  }

  bool IsFrameless(CefRefPtr<CefWindow> window) override {
    return true;
  }

  bool WithStandardWindowButtons(CefRefPtr<CefWindow> window) override {
    return false;
  }

  bool CanResize(CefRefPtr<CefWindow> window) override {
    return false;
  }

  bool CanMaximize(CefRefPtr<CefWindow> window) override {
    return false;
  }

  bool CanMinimize(CefRefPtr<CefWindow> window) override {
    return false;
  }

  cef_runtime_style_t GetWindowRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }

 private:
  __weak BrowserTabController *controller_;
  const std::string tab_id_;
  CefRefPtr<CefBrowserView> browser_view_;

  IMPLEMENT_REFCOUNTING(BrowserTabWindowDelegate);
};

struct TabRecord {
  CefRefPtr<CefClient> client;
  CefRefPtr<CefBrowserView> browser_view;
  CefRefPtr<CefWindow> window;
  NSWindow *native_window = nil;
  CefRefPtr<CefBrowser> browser;
  bool pending_close = false;
};

NSWindow *EnsureNativeWindowForRecord(TabRecord &record) {
  if (record.native_window != nil) {
    return record.native_window;
  }

  record.native_window = NativeWindowForCefWindow(record.window);
  ConfigureNativeBrowserWindow(record.native_window);
  return record.native_window;
}

}  // namespace

@interface BrowserTabHostView ()

@property(nonatomic, weak) BrowserTabController *controller;

@end

@interface BrowserTabController ()

- (void)handleBrowserCreated:(CefRefPtr<CefBrowser>)browser
                     forTabID:(NSString *)tabID;
- (void)handleBrowserClosedForTabID:(NSString *)tabID;
- (void)handleChromeWindowCreated:(CefRefPtr<CefWindow>)window
                          forTabID:(NSString *)tabID;
- (void)handleChromeWindowDestroyedForTabID:(NSString *)tabID;
- (void)handleTitleChange:(NSString *)title forTabID:(NSString *)tabID;
- (void)handleAddressChange:(NSString *)urlString forTabID:(NSString *)tabID;
- (void)handleFaviconURLChange:(nullable NSString *)faviconURLString
                      forTabID:(NSString *)tabID;
- (void)handleLoadingStateChangeForTabID:(NSString *)tabID
                               isLoading:(BOOL)isLoading;
- (void)handleNavigationStateChangeForTabID:(NSString *)tabID
                                  canGoBack:(BOOL)canGoBack
                               canGoForward:(BOOL)canGoForward;
- (void)handleFindResultForTabID:(NSString *)tabID
                       matchCount:(NSInteger)matchCount
               activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                      finalUpdate:(BOOL)finalUpdate;
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
  return self;
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

  std::string resolvedURL = ToStdString(resolvedURLString);
  if (ShouldUseChromeWindowForURL(resolvedURL)) {
    CefRefPtr<CefBrowserView> browserView = CefBrowserView::CreateBrowserView(
        client, resolvedURL, CefBrowserSettings(), nullptr,
        nullptr, new BrowserTabBrowserViewDelegate());
    auto recordIt = _tabRecords.find(tabKey);
    if (recordIt != _tabRecords.end()) {
      recordIt->second.browser_view = browserView;
    }
    CefWindow::CreateTopLevelWindow(
        new BrowserTabWindowDelegate(self, tabKey, browserView));
  } else {
    CefWindowInfo windowInfo;
    windowInfo.SetAsChild((__bridge CefWindowHandle)_hostView,
                          CefRectFromBounds(_hostView.bounds));
    if (shared::IsAlloyStyleEnabled()) {
      windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    }

    CefBrowserHost::CreateBrowser(windowInfo, client, resolvedURL,
                                  CefBrowserSettings(), nullptr, nullptr);
  }
  [self updateBrowserVisibility];
  return tabID;
}

- (void)selectTabWithID:(NSString *)tabID {
  _activeTabID = [tabID copy];
  [self updateBrowserVisibility];
}

- (void)navigateActiveTabToURLString:(NSString *)urlString {
  if (urlString.length == 0) {
    return;
  }

  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  NavigateBrowserOnUI(it->second.browser, ToStdString(urlString));
}

- (void)goBackActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  GoBackBrowserOnUI(it->second.browser);
}

- (void)goForwardActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  GoForwardBrowserOnUI(it->second.browser);
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

- (void)stopLoadingActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  StopLoadingBrowserOnUI(it->second.browser);
}

- (void)saveActiveTabWithSuggestedName:(NSString *)suggestedName {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  SavePageBrowserOnUI(it->second.browser, suggestedName);
}

- (void)pasteAndMatchStyleActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  PasteAndMatchStyleBrowserOnUI(it->second.browser);
}

- (void)printActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  PrintBrowserOnUI(it->second.browser);
}

- (void)findInActiveTabWithText:(NSString *)text
                         forward:(BOOL)forward
                       matchCase:(BOOL)matchCase
                        findNext:(BOOL)findNext {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  FindBrowserOnUI(it->second.browser, text, forward, matchCase, findNext);
}

- (BOOL)focusSearchInActiveChromeSettingsTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return NO;
  }

  return FocusSettingsSearchInBrowserOnUI(it->second.browser) ? YES : NO;
}

- (void)stopFindingInActiveTabWithClearSelection:(BOOL)clearSelection {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  StopFindingBrowserOnUI(it->second.browser, clearSelection);
}

- (void)closeTabWithID:(NSString *)tabID {
  [self closeTabWithID:tabID forceClose:NO];
}

- (void)closeTabWithID:(NSString *)tabID forceClose:(BOOL)forceClose {
  std::string tabKey = ToStdString(tabID);
  auto it = _tabRecords.find(tabKey);
  if (it == _tabRecords.end()) {
    return;
  }

  if (it->second.browser) {
    it->second.browser->GetHost()->CloseBrowser(forceClose);
    return;
  }

  if (it->second.window) {
    it->second.pending_close = true;
    it->second.window->Close();
    return;
  }

  DetachBrowserWindow(it->second.native_window);
  _tabRecords.erase(tabKey);
  [self.delegate browserTabController:self didCloseTabWithID:tabID];
  [self updateBrowserVisibility];
}

- (void)closeAllTabs {
  std::vector<CefRefPtr<CefBrowser>> browsers;
  std::vector<CefRefPtr<CefWindow>> windows;
  browsers.reserve(_tabRecords.size());
  windows.reserve(_tabRecords.size());
  for (const auto &entry : _tabRecords) {
    if (entry.second.browser) {
      browsers.push_back(entry.second.browser);
    } else if (entry.second.window) {
      windows.push_back(entry.second.window);
    }
  }

  for (const auto &browser : browsers) {
    browser->GetHost()->CloseBrowser(false);
  }
  for (const auto &window : windows) {
    window->Close();
  }
}

- (void)hostViewDidLayout {
  [self syncBrowserFrames];
}

- (void)syncBrowserFrames {
  std::string activeKey = ToStdString(_activeTabID);
  for (auto &entry : _tabRecords) {
    BOOL isActive = entry.first == activeKey;
    NSWindow *nativeWindow = EnsureNativeWindowForRecord(entry.second);
    if (nativeWindow != nil) {
      if (isActive) {
        SyncNativeBrowserWindowFrame(_hostView, nativeWindow);
      } else {
        if (entry.second.window) {
          entry.second.window->Hide();
        }
        [nativeWindow orderOut:nil];
      }
    } else if (isActive) {
      SyncBrowserViewFrame(_hostView, entry.second.browser);
    }
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
  NSWindow *nativeWindow = EnsureNativeWindowForRecord(it->second);
  if (nativeWindow != nil) {
    SyncNativeBrowserWindowFrame(_hostView, nativeWindow);
  } else {
    SyncBrowserViewFrame(_hostView, browser);
  }
  [self handleNavigationStateChangeForTabID:tabID
                                  canGoBack:browser->CanGoBack()
                               canGoForward:browser->CanGoForward()];

  if (it->second.pending_close) {
    browser->GetHost()->CloseBrowser(false);
    return;
  }

  [self updateBrowserVisibility];
}

- (void)handleChromeWindowCreated:(CefRefPtr<CefWindow>)window
                          forTabID:(NSString *)tabID {
  std::string tabKey = ToStdString(tabID);
  auto it = _tabRecords.find(tabKey);
  if (it == _tabRecords.end()) {
    window->Close();
    return;
  }

  it->second.window = window;
  NSWindow *nativeWindow = EnsureNativeWindowForRecord(it->second);
  SyncNativeBrowserWindowFrame(_hostView, nativeWindow);

  if (it->second.pending_close) {
    window->Close();
    return;
  }

  [self updateBrowserVisibility];
}

- (void)handleChromeWindowDestroyedForTabID:(NSString *)tabID {
  std::string tabKey = ToStdString(tabID);
  auto it = _tabRecords.find(tabKey);
  if (it == _tabRecords.end()) {
    return;
  }

  DetachBrowserWindow(it->second.native_window);
  it->second.native_window = nil;
  it->second.window = nullptr;
}

- (void)handleBrowserClosedForTabID:(NSString *)tabID {
  std::string tabKey = ToStdString(tabID);
  auto it = _tabRecords.find(tabKey);
  if (it != _tabRecords.end()) {
    DetachBrowserWindow(it->second.native_window);
  }
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

- (void)handleLoadingStateChangeForTabID:(NSString *)tabID
                               isLoading:(BOOL)isLoading {
  [self.delegate browserTabController:self
      didUpdateLoadingStateForTabWithID:tabID
                              isLoading:isLoading];
}

- (void)handleNavigationStateChangeForTabID:(NSString *)tabID
                                  canGoBack:(BOOL)canGoBack
                               canGoForward:(BOOL)canGoForward {
  [self.delegate browserTabController:self
      didUpdateNavigationStateForTabWithID:tabID
                                 canGoBack:canGoBack
                              canGoForward:canGoForward];
}

- (void)handleFindResultForTabID:(NSString *)tabID
                       matchCount:(NSInteger)matchCount
               activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                      finalUpdate:(BOOL)finalUpdate {
  [self.delegate browserTabController:self
      didUpdateFindResultForTabWithID:tabID
                           matchCount:matchCount
                   activeMatchOrdinal:activeMatchOrdinal
                          finalUpdate:finalUpdate];
}

- (void)openPopupTabWithURLString:(NSString *)urlString {
  [self createTabWithURLString:urlString.length > 0 ? urlString : @"about:blank"
                    makeActive:YES];
}

- (void)updateBrowserVisibility {
  std::string activeKey = ToStdString(_activeTabID);
  for (auto &entry : _tabRecords) {
    BOOL isActive = entry.first == activeKey;
    if (isActive) {
      continue;
    }

    NSWindow *nativeWindow = EnsureNativeWindowForRecord(entry.second);
    if (nativeWindow != nil) {
      if (entry.second.window) {
        entry.second.window->Hide();
      }
      [nativeWindow orderOut:nil];
    } else {
      NSView *browserView = BrowserViewForBrowser(entry.second.browser);
      if (browserView == nil) {
        continue;
      }

      browserView.hidden = YES;
    }
  }

  auto activeIt = _tabRecords.find(activeKey);
  if (activeIt == _tabRecords.end()) {
    return;
  }

  NSWindow *nativeWindow = EnsureNativeWindowForRecord(activeIt->second);
  if (nativeWindow != nil) {
    SyncNativeBrowserWindowFrame(_hostView, nativeWindow);
    if (!NSIsEmptyRect(ScreenFrameForHostView(_hostView))) {
      if (activeIt->second.window) {
        activeIt->second.window->Show();
      }
      [nativeWindow orderFront:nil];
    }
  } else {
    NSView *browserView = BrowserViewForBrowser(activeIt->second.browser);
    if (browserView != nil) {
      browserView.hidden = NO;
      SyncBrowserViewFrame(_hostView, activeIt->second.browser);
    }
  }

  if (activeIt->second.browser) {
    activeIt->second.browser->GetHost()->SetFocus(true);
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

  [controller handleAddressChange:ToNSString(DisplayURLStringForCommittedURL(url))
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

void BrowserTabClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                            bool isLoading,
                                            bool canGoBack,
                                            bool canGoForward) {
  CEF_REQUIRE_UI_THREAD();

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    return;
  }

  [controller handleLoadingStateChangeForTabID:ToNSString(tab_id_)
                                     isLoading:isLoading];
  [controller handleNavigationStateChangeForTabID:ToNSString(tab_id_)
                                        canGoBack:canGoBack
                                     canGoForward:canGoForward];
}

bool BrowserTabClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      CefRefPtr<CefRequest> request,
                                      bool user_gesture,
                                      bool is_redirect) {
  CEF_REQUIRE_UI_THREAD();

  if (!frame || !frame->IsMain() || !request) {
    return false;
  }

  if (allow_next_chromium_settings_navigation_ &&
      IsChromiumSettingsURL(request->GetURL())) {
    allow_next_chromium_settings_navigation_ = false;
    return false;
  }
  allow_next_chromium_settings_navigation_ = false;

  std::string redirectURL =
      TheBrowserURLForChromiumInternalURL(request->GetURL());
  if (!redirectURL.empty()) {
    frame->LoadURL(redirectURL);
    return true;
  }

  if (IsTheBrowserSettingsURL(request->GetURL())) {
    std::string chromiumSettingsURL =
        ChromiumSettingsURLForTheBrowserSettingsURL(request->GetURL());
    if (chromiumSettingsURL.empty()) {
      chromiumSettingsURL = shared::kChromiumSettingsURL;
    }
    allow_next_chromium_settings_navigation_ = true;
    frame->LoadURL(chromiumSettingsURL);
    return true;
  }

  return false;
}

void BrowserTabClient::OnFindResult(CefRefPtr<CefBrowser>,
                                    int,
                                    int count,
                                    const CefRect &,
                                    int activeMatchOrdinal,
                                    bool finalUpdate) {
  CEF_REQUIRE_UI_THREAD();

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    return;
  }

  [controller handleFindResultForTabID:ToNSString(tab_id_)
                            matchCount:count
                    activeMatchOrdinal:activeMatchOrdinal
                           finalUpdate:finalUpdate];
}

bool BrowserTabClient::OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                                     const CefKeyEvent &event,
                                     CefEventHandle,
                                     bool *is_keyboard_shortcut) {
  CEF_REQUIRE_UI_THREAD();

  if (CefBrowserView::GetForBrowser(browser) && IsCommandFindShortcut(event)) {
    if (FocusSettingsSearchInBrowser(browser)) {
      if (is_keyboard_shortcut != nullptr) {
        *is_keyboard_shortcut = true;
      }
      return true;
    }
  }

  return false;
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

  if (CefBrowserView::GetForBrowser(browser)) {
    return false;
  }

  NSView *browserView = BrowserViewForBrowser(browser);
  if (browserView != nil) {
    // Embedded child browsers must tear down their host NSView here. Returning
    // false asks CEF to close the top-level NSWindow instead, which blocks our
    // tab-level shutdown flow and can deadlock app quit.
    [browserView removeFromSuperview];
    return true;
  }

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
