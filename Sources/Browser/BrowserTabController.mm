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
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_download_handler.h"
#include "include/cef_download_item.h"
#include "include/cef_find_handler.h"
#include "include/cef_frame.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_handler.h"
#include "include/cef_values.h"
#include "include/internal/cef_mac.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"

@interface SavePageFormatAccessoryController : NSObject

- (instancetype)initWithPanel:(NSSavePanel *)panel baseName:(NSString *)baseName;
- (void)formatDidChange:(NSPopUpButton *)sender;

@end

namespace {

constexpr char kSavePageResourceTreeMethod[] = "Page.getResourceTree";
constexpr char kSavePageResourceContentMethod[] = "Page.getResourceContent";
constexpr char kSavePageSingleFileMethod[] = "Page.captureSnapshot";
constexpr char kSavePageSerializeDocumentMethod[] = "Runtime.evaluate";
constexpr char kPageLayoutMetricsMethod[] = "Page.getLayoutMetrics";
constexpr char kPageCaptureScreenshotMethod[] = "Page.captureScreenshot";

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

NSString *DisplayHostForHost(NSString *host) {
  if (host.length > 4 &&
      [[host substringToIndex:4] caseInsensitiveCompare:@"www."] ==
          NSOrderedSame) {
    return [host substringFromIndex:4];
  }
  return host;
}

NSString *DefaultTitleForURLString(NSString *urlString) {
  NSURL *url = [NSURL URLWithString:urlString];
  NSString *host = url.host;
  if (host.length > 0) {
    return DisplayHostForHost(host);
  }
  return LocalizedBrowserString(@"browser.tab.new");
}

NSString *SanitizedDownloadFileName(NSString *value) {
  NSString *fallback =
      LocalizedBrowserString(@"browser.downloads.default_file_name");
  NSString *candidate = value.length > 0 ? value.lastPathComponent : fallback;
  if (candidate.length == 0) {
    candidate = fallback;
  }

  NSCharacterSet *invalidCharacters =
      [NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"];
  candidate = [[candidate componentsSeparatedByCharactersInSet:invalidCharacters]
      componentsJoinedByString:@"-"];
  candidate = [candidate stringByTrimmingCharactersInSet:
                             NSCharacterSet.whitespaceAndNewlineCharacterSet];

  return candidate.length > 0 ? candidate : fallback;
}

NSString *SuggestedDownloadFileName(CefRefPtr<CefDownloadItem> download_item,
                                    const CefString &suggested_name) {
  NSString *suggestedName = ToNSString(suggested_name.ToString());
  if (suggestedName.length > 0) {
    return SanitizedDownloadFileName(suggestedName);
  }

  if (download_item && download_item->IsValid()) {
    NSString *downloadSuggestedName =
        ToNSString(download_item->GetSuggestedFileName().ToString());
    if (downloadSuggestedName.length > 0) {
      return SanitizedDownloadFileName(downloadSuggestedName);
    }

    NSString *urlString = ToNSString(download_item->GetURL().ToString());
    NSURL *url = [NSURL URLWithString:urlString];
    if (url.lastPathComponent.length > 0) {
      return SanitizedDownloadFileName(url.lastPathComponent);
    }
  }

  return SanitizedDownloadFileName(nil);
}

NSString *DownloadsDirectoryPath() {
  NSArray<NSURL *> *urls =
      [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory
                                           inDomains:NSUserDomainMask];
  NSURL *downloadsURL = urls.firstObject;
  return downloadsURL.path.length > 0 ? downloadsURL.path : NSTemporaryDirectory();
}

NSString *UniqueDownloadPathForFileName(NSString *fileName) {
  NSString *downloadsDirectory = DownloadsDirectoryPath();
  NSError *directoryError = nil;
  [NSFileManager.defaultManager createDirectoryAtPath:downloadsDirectory
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:&directoryError];

  NSString *sanitizedFileName = SanitizedDownloadFileName(fileName);
  NSString *baseName = sanitizedFileName.stringByDeletingPathExtension;
  NSString *pathExtension = sanitizedFileName.pathExtension;
  if (baseName.length == 0) {
    baseName = LocalizedBrowserString(@"browser.downloads.default_file_name");
  }

  for (NSInteger index = 0; index < 1000; index += 1) {
    NSString *candidateName = sanitizedFileName;
    if (index > 0) {
      candidateName = pathExtension.length > 0
                          ? [NSString stringWithFormat:@"%@ %ld.%@", baseName,
                                                       static_cast<long>(index + 1),
                                                       pathExtension]
                          : [NSString stringWithFormat:@"%@ %ld", baseName,
                                                       static_cast<long>(index + 1)];
    }

    NSString *candidatePath =
        [downloadsDirectory stringByAppendingPathComponent:candidateName];
    if (![NSFileManager.defaultManager fileExistsAtPath:candidatePath]) {
      return candidatePath;
    }
  }

  NSString *fallbackName =
      [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString,
                                 sanitizedFileName];
  return [downloadsDirectory stringByAppendingPathComponent:fallbackName];
}

NSString *DownloadStateRawValue(CefRefPtr<CefDownloadItem> download_item) {
  if (!download_item || !download_item->IsValid()) {
    return @"interrupted";
  }

  if (download_item->IsComplete()) {
    return @"completed";
  }
  if (download_item->IsCanceled()) {
    return @"canceled";
  }
  if (download_item->IsInterrupted()) {
    return @"interrupted";
  }

  return @"inProgress";
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

void CopyBase64PNGToPasteboardOnMain(const std::string &base64_png) {
  NSString *base64String = ToNSString(base64_png);
  dispatch_async(dispatch_get_main_queue(), ^{
    NSData *pngData =
        [[NSData alloc] initWithBase64EncodedString:base64String options:0];
    if (pngData.length == 0) {
      return;
    }

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setData:pngData forType:NSPasteboardTypePNG];
  });
}

class FullPageScreenshotObserver final : public CefDevToolsMessageObserver {
 public:
  void Start(CefRefPtr<CefBrowserHost> host) {
    if (!host) {
      return;
    }

    registration_ = host->AddDevToolsMessageObserver(this);
    message_id_ = NextDevToolsMessageID();
    if (host->ExecuteDevToolsMethod(message_id_, kPageLayoutMetricsMethod,
                                    nullptr) == 0) {
      registration_ = nullptr;
    }
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void *result,
                              size_t result_size) override {
    if (message_id != message_id_) {
      return;
    }

    CefRefPtr<CefDictionaryValue> dictionary =
        success ? ParseDevToolsResultDictionary(result, result_size) : nullptr;
    if (!dictionary) {
      registration_ = nullptr;
      return;
    }

    if (stage_ == Stage::LayoutMetrics) {
      CaptureScreenshot(browser, dictionary);
      return;
    }

    registration_ = nullptr;
    std::string pngData = dictionary->GetString("data").ToString();
    if (!pngData.empty()) {
      CopyBase64PNGToPasteboardOnMain(pngData);
    }
  }

  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override {
    registration_ = nullptr;
  }

 private:
  enum class Stage {
    LayoutMetrics,
    Screenshot,
  };

  void CaptureScreenshot(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDictionaryValue> metrics) {
    CefRefPtr<CefBrowserHost> host = browser ? browser->GetHost() : nullptr;
    CefRefPtr<CefDictionaryValue> contentSize =
        metrics->GetDictionary("cssContentSize");
    if (!host || !contentSize) {
      registration_ = nullptr;
      return;
    }

    double width = contentSize->GetDouble("width");
    double height = contentSize->GetDouble("height");
    if (width <= 0 || height <= 0) {
      registration_ = nullptr;
      return;
    }

    CefRefPtr<CefDictionaryValue> clip = CefDictionaryValue::Create();
    clip->SetDouble("x", 0);
    clip->SetDouble("y", 0);
    clip->SetDouble("width", width);
    clip->SetDouble("height", height);
    clip->SetDouble("scale", 1);

    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("format", "png");
    params->SetBool("fromSurface", true);
    params->SetBool("captureBeyondViewport", true);
    params->SetDictionary("clip", clip);

    stage_ = Stage::Screenshot;
    message_id_ = NextDevToolsMessageID();
    if (host->ExecuteDevToolsMethod(message_id_, kPageCaptureScreenshotMethod,
                                    params) == 0) {
      registration_ = nullptr;
    }
  }

  Stage stage_ = Stage::LayoutMetrics;
  int message_id_ = 0;
  CefRefPtr<CefRegistration> registration_;

  IMPLEMENT_REFCOUNTING(FullPageScreenshotObserver);
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

class ReloadBrowserCompletionCallback : public CefCompletionCallback {
 public:
  explicit ReloadBrowserCompletionCallback(CefRefPtr<CefBrowser> browser)
      : browser_(browser) {}

  void OnComplete() override { ReloadBrowser(browser_, false); }

 private:
  CefRefPtr<CefBrowser> browser_;

  IMPLEMENT_REFCOUNTING(ReloadBrowserCompletionCallback);
};

class ReloadBrowserDeleteCookiesCallback : public CefDeleteCookiesCallback {
 public:
  explicit ReloadBrowserDeleteCookiesCallback(CefRefPtr<CefBrowser> browser)
      : browser_(browser) {}

  void OnComplete(int num_deleted) override {
    (void)num_deleted;
    ReloadBrowser(browser_, false);
  }

 private:
  CefRefPtr<CefBrowser> browser_;

  IMPLEMENT_REFCOUNTING(ReloadBrowserDeleteCookiesCallback);
};

void ClearHttpCacheAndReloadBrowser(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefRequestContext> request_context) {
  if (!browser) {
    return;
  }

  if (!request_context) {
    ReloadBrowser(browser, false);
    return;
  }

#if CEF_API_ADDED(14400)
  request_context->ClearHttpCache(new ReloadBrowserCompletionCallback(browser));
#else
  ReloadBrowser(browser, true);
#endif
}

void ClearHttpCacheAndReloadBrowserOnUI(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefRequestContext> request_context) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    ClearHttpCacheAndReloadBrowser(browser, request_context);
    return;
  }

  CefPostTask(
      TID_UI,
      CefCreateClosureTask(
          base::BindOnce(
              &ClearHttpCacheAndReloadBrowser, browser, request_context)));
}

void ClearCookiesAndReloadBrowser(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefRequestContext> request_context) {
  if (!browser) {
    return;
  }

  if (!request_context) {
    ReloadBrowser(browser, false);
    return;
  }

  CefRefPtr<CefCookieManager> cookie_manager =
      request_context->GetCookieManager(nullptr);
  if (!cookie_manager ||
      !cookie_manager->DeleteCookies(
          CefString(), CefString(),
          new ReloadBrowserDeleteCookiesCallback(browser))) {
    ReloadBrowser(browser, false);
  }
}

void ClearCookiesAndReloadBrowserOnUI(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefRequestContext> request_context) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    ClearCookiesAndReloadBrowser(browser, request_context);
    return;
  }

  CefPostTask(
      TID_UI,
      CefCreateClosureTask(
          base::BindOnce(
              &ClearCookiesAndReloadBrowser, browser, request_context)));
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

bool URLHasSchemeAndInternalHost(const CefString &url,
                                 const std::string &scheme) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }

  std::string host = LowercaseASCII(URLPartToString(parts.host));
  if (host.empty() || host == shared::kTheBrowserCreditsHost) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) == scheme;
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

bool IsChromiumInternalWindowURL(const CefString &url) {
  return URLHasSchemeAndInternalHost(url, "chrome");
}

bool IsTheBrowserExtensionsURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) ==
             shared::kTheBrowserScheme &&
         LowercaseASCII(URLPartToString(parts.host)) ==
             shared::kTheBrowserExtensionsHost;
}

bool IsTheBrowserHistoryURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) ==
             shared::kTheBrowserScheme &&
         LowercaseASCII(URLPartToString(parts.host)) ==
             shared::kTheBrowserHistoryHost;
}

bool IsTheBrowserPasswordManagerURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) ==
             shared::kTheBrowserScheme &&
         LowercaseASCII(URLPartToString(parts.host)) ==
             shared::kTheBrowserPasswordManagerHost;
}

bool IsTheBrowserBookmarksURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) ==
             shared::kTheBrowserScheme &&
         LowercaseASCII(URLPartToString(parts.host)) ==
             shared::kTheBrowserBookmarksHost;
}

bool IsTheBrowserInternalWindowURL(const CefString &url) {
  return URLHasSchemeAndInternalHost(url, shared::kTheBrowserScheme);
}

std::string ChromiumInternalWindowURLForTheBrowserURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts) || !IsTheBrowserInternalWindowURL(url)) {
    return std::string();
  }

  std::string host = LowercaseASCII(URLPartToString(parts.host));
  std::string path = URLPartToString(parts.path);
  if (path.empty()) {
    path = "/";
  }

  std::string chromiumURL = "chrome://" + host + path;
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
  if (IsChromiumInternalWindowURL(url)) {
    std::string displayURL = TheBrowserURLForChromiumInternalURL(url);
    if (!displayURL.empty()) {
      return displayURL;
    }
  }

  return url.ToString();
}

bool ShouldUseEmbeddedChromeRuntimeForURL(const std::string &) {
  return false;
}

class BrowserTabClient final : public CefClient,
                               public CefDisplayHandler,
                               public CefDownloadHandler,
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
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
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
  bool OnBeforeDownload(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDownloadItem> download_item,
      const CefString &suggested_name,
      CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDownloadItem> download_item,
      CefRefPtr<CefDownloadItemCallback> callback) override;
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool /*isLoading*/,
                            bool canGoBack,
                            bool canGoForward) override;
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override;
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString &target_url,
                        WindowOpenDisposition target_disposition,
                        bool user_gesture) override;
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
  bool allow_next_chromium_internal_navigation_ = false;

  IMPLEMENT_REFCOUNTING(BrowserTabClient);
};

struct TabRecord {
  CefRefPtr<CefClient> client;
  CefRefPtr<CefBrowser> browser;
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
- (void)handleLoadingStateChangeForTabID:(NSString *)tabID
                               isLoading:(BOOL)isLoading;
- (void)handleNavigationStateChangeForTabID:(NSString *)tabID
                                  canGoBack:(BOOL)canGoBack
                               canGoForward:(BOOL)canGoForward;
- (void)handleFindResultForTabID:(NSString *)tabID
                       matchCount:(NSInteger)matchCount
               activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                      finalUpdate:(BOOL)finalUpdate;
- (void)handleDownloadUpdateWithID:(NSString *)downloadID
                          fileName:(NSString *)fileName
                         urlString:(NSString *)urlString
                          fullPath:(nullable NSString *)fullPath
                     receivedBytes:(int64_t)receivedBytes
                        totalBytes:(int64_t)totalBytes
        currentSpeedBytesPerSecond:(int64_t)currentSpeedBytesPerSecond
                     stateRawValue:(NSString *)stateRawValue;
- (BOOL)openURLFromTabWithURLString:(NSString *)urlString
                         sourceTabID:(NSString *)sourceTabID
                   targetDisposition:(cef_window_open_disposition_t)targetDisposition;
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
  CefRefPtr<CefRequestContext> _requestContext;
  NSString *_activeTabID;
}

- (instancetype)initWithHostView:(BrowserTabHostView *)hostView {
  return [self initWithHostView:hostView
    usesEphemeralRequestContext:NO
                profileCachePath:nil];
}

- (instancetype)initWithHostView:(BrowserTabHostView *)hostView
    usesEphemeralRequestContext:(BOOL)usesEphemeralRequestContext
                profileCachePath:(NSString *)profileCachePath {
  self = [super init];
  if (self == nil) {
    return nil;
  }

  _hostView = hostView;
  _hostView.controller = self;
  if (usesEphemeralRequestContext) {
    CefRequestContextSettings settings;
    _requestContext = CefRequestContext::CreateContext(settings, nullptr);
  } else if (profileCachePath.length > 0) {
    CefRequestContextSettings settings;
    CefString(&settings.cache_path) = ToStdString(profileCachePath);
    _requestContext = CefRequestContext::CreateContext(settings, nullptr);
  }
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

  BOOL isActive = makeActive || _activeTabID == nil;
  if (isActive) {
    _activeTabID = [tabID copy];
  }

  [self.delegate browserTabController:self
                      didCreateTabWithID:tabID
                                   title:DefaultTitleForURLString(resolvedURLString)
                               urlString:resolvedURLString
                                isActive:isActive];

  std::string resolvedURL = ToStdString(resolvedURLString);
  CefWindowInfo windowInfo;
  windowInfo.SetAsChild((__bridge CefWindowHandle)_hostView,
                        CefRectFromBounds(_hostView.bounds));
  if (ShouldUseEmbeddedChromeRuntimeForURL(resolvedURL)) {
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  } else if (shared::IsAlloyStyleEnabled()) {
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  }

  CefBrowserHost::CreateBrowser(windowInfo, client, resolvedURL,
                                CefBrowserSettings(), nullptr, _requestContext);
  [self updateBrowserVisibility];
  return tabID;
}

- (void)selectTabWithID:(NSString *)tabID {
  _activeTabID = [tabID copy];
  [self updateBrowserVisibility];
}

- (void)deselectActiveTab {
  _activeTabID = nil;
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

- (void)clearCacheAndReloadActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  CefRefPtr<CefRequestContext> requestContext = _requestContext;
  if (!requestContext) {
    requestContext = CefRequestContext::GetGlobalContext();
  }
  ClearHttpCacheAndReloadBrowserOnUI(it->second.browser, requestContext);
}

- (void)clearCookiesAndReloadActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  CefRefPtr<CefRequestContext> requestContext = _requestContext;
  if (!requestContext) {
    requestContext = CefRequestContext::GetGlobalContext();
  }
  ClearCookiesAndReloadBrowserOnUI(it->second.browser, requestContext);
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

- (void)captureFullPageActiveTabToPasteboard {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end() || !it->second.browser) {
    return;
  }

  CefRefPtr<CefBrowserHost> host = it->second.browser->GetHost();
  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
                          [](CefRefPtr<CefBrowserHost> host) {
                            CefRefPtr<FullPageScreenshotObserver> observer =
                                new FullPageScreenshotObserver();
                            observer->Start(host);
                          },
                          host)));
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

- (void)prepareForCefShutdown {
  self.delegate = nil;
  _hostView.controller = nil;
  _hostView = nil;
  _activeTabID = nil;
  _tabRecords.clear();
  _requestContext = nullptr;
}

- (void)hostViewDidLayout {
  [self syncBrowserFrames];
}

- (void)syncBrowserFrames {
  std::string activeKey = ToStdString(_activeTabID);
  for (auto &entry : _tabRecords) {
    BOOL isActive = entry.first == activeKey;
    if (isActive) {
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
  SyncBrowserViewFrame(_hostView, browser);
  [self handleNavigationStateChangeForTabID:tabID
                                  canGoBack:browser->CanGoBack()
                               canGoForward:browser->CanGoForward()];

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

- (void)handleDownloadUpdateWithID:(NSString *)downloadID
                          fileName:(NSString *)fileName
                         urlString:(NSString *)urlString
                          fullPath:(NSString *)fullPath
                     receivedBytes:(int64_t)receivedBytes
                        totalBytes:(int64_t)totalBytes
        currentSpeedBytesPerSecond:(int64_t)currentSpeedBytesPerSecond
                     stateRawValue:(NSString *)stateRawValue {
  [self.delegate browserTabController:self
              didUpdateDownloadWithID:downloadID
                             fileName:fileName
                            urlString:urlString
                             fullPath:fullPath
                        receivedBytes:receivedBytes
                           totalBytes:totalBytes
           currentSpeedBytesPerSecond:currentSpeedBytesPerSecond
                        stateRawValue:stateRawValue];
}

- (BOOL)openURLFromTabWithURLString:(NSString *)urlString
                         sourceTabID:(NSString *)sourceTabID
                   targetDisposition:(cef_window_open_disposition_t)targetDisposition {
  NSString *resolvedURLString =
      urlString.length > 0 ? urlString : @"about:blank";

  switch (targetDisposition) {
    case CEF_WOD_CURRENT_TAB:
    case CEF_WOD_SINGLETON_TAB:
    case CEF_WOD_SWITCH_TO_TAB:
    case CEF_WOD_UNKNOWN: {
      std::string tabKey = ToStdString(sourceTabID);
      auto it = _tabRecords.find(tabKey);
      if (it == _tabRecords.end()) {
        [self createTabWithURLString:resolvedURLString makeActive:YES];
        return YES;
      }

      NavigateBrowserOnUI(it->second.browser, ToStdString(resolvedURLString));
      return YES;
    }
    case CEF_WOD_NEW_BACKGROUND_TAB:
      [self createTabWithURLString:resolvedURLString makeActive:NO];
      return YES;
    case CEF_WOD_IGNORE_ACTION:
      return YES;
    case CEF_WOD_NEW_FOREGROUND_TAB:
    case CEF_WOD_NEW_SPLIT_VIEW:
    case CEF_WOD_NEW_POPUP:
    case CEF_WOD_NEW_WINDOW:
    case CEF_WOD_OFF_THE_RECORD:
      [self createTabWithURLString:resolvedURLString makeActive:YES];
      return YES;
    case CEF_WOD_SAVE_TO_DISK:
    case CEF_WOD_NEW_PICTURE_IN_PICTURE:
    case CEF_WOD_NUM_VALUES:
      return NO;
  }

  return NO;
}

- (void)updateBrowserVisibility {
  std::string activeKey = ToStdString(_activeTabID);
  for (auto &entry : _tabRecords) {
    BOOL isActive = entry.first == activeKey;
    if (isActive) {
      continue;
    }

    NSView *browserView = BrowserViewForBrowser(entry.second.browser);
    if (browserView != nil) {
      browserView.hidden = YES;
    }
  }

  auto activeIt = _tabRecords.find(activeKey);
  if (activeIt == _tabRecords.end()) {
    return;
  }

  NSView *browserView = BrowserViewForBrowser(activeIt->second.browser);
  if (browserView != nil) {
    browserView.hidden = NO;
    SyncBrowserViewFrame(_hostView, activeIt->second.browser);
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

bool BrowserTabClient::OnBeforeDownload(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    const CefString &suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();

  if (!download_item || !download_item->IsValid() || !callback) {
    return false;
  }

  NSString *fileName = SuggestedDownloadFileName(download_item, suggested_name);
  NSString *downloadPath = UniqueDownloadPathForFileName(fileName);
  callback->Continue(ToStdString(downloadPath), false);

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    return true;
  }

  [controller handleDownloadUpdateWithID:ToNSString(std::to_string(download_item->GetId()))
                                fileName:fileName
                               urlString:ToNSString(download_item->GetURL().ToString())
                                fullPath:downloadPath
                           receivedBytes:download_item->GetReceivedBytes()
                              totalBytes:download_item->GetTotalBytes()
              currentSpeedBytesPerSecond:download_item->GetCurrentSpeed()
                           stateRawValue:DownloadStateRawValue(download_item)];
  return true;
}

void BrowserTabClient::OnDownloadUpdated(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    CefRefPtr<CefDownloadItemCallback> callback) {
  CEF_REQUIRE_UI_THREAD();

  if (!download_item || !download_item->IsValid()) {
    return;
  }

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    return;
  }

  NSString *fullPath = ToNSString(download_item->GetFullPath().ToString());
  if (fullPath.length == 0) {
    fullPath = nil;
  }

  [controller handleDownloadUpdateWithID:ToNSString(std::to_string(download_item->GetId()))
                                fileName:SuggestedDownloadFileName(download_item, CefString())
                               urlString:ToNSString(download_item->GetURL().ToString())
                                fullPath:fullPath
                           receivedBytes:download_item->GetReceivedBytes()
                              totalBytes:download_item->GetTotalBytes()
              currentSpeedBytesPerSecond:download_item->GetCurrentSpeed()
                           stateRawValue:DownloadStateRawValue(download_item)];
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

  if (allow_next_chromium_internal_navigation_ &&
      IsChromiumInternalWindowURL(request->GetURL())) {
    allow_next_chromium_internal_navigation_ = false;
    return false;
  }
  allow_next_chromium_internal_navigation_ = false;

  std::string redirectURL =
      TheBrowserURLForChromiumInternalURL(request->GetURL());
  if (!redirectURL.empty()) {
    frame->LoadURL(redirectURL);
    return true;
  }

  if (IsTheBrowserInternalWindowURL(request->GetURL())) {
    std::string chromiumInternalURL =
        ChromiumInternalWindowURLForTheBrowserURL(request->GetURL());
    if (chromiumInternalURL.empty()) {
      if (IsTheBrowserExtensionsURL(request->GetURL())) {
        chromiumInternalURL = shared::kChromiumExtensionsURL;
      } else if (IsTheBrowserHistoryURL(request->GetURL())) {
        chromiumInternalURL = shared::kChromiumHistoryURL;
      } else if (IsTheBrowserPasswordManagerURL(request->GetURL())) {
        chromiumInternalURL = shared::kChromiumPasswordManagerURL;
      } else if (IsTheBrowserBookmarksURL(request->GetURL())) {
        chromiumInternalURL = shared::kChromiumBookmarksURL;
      } else {
        chromiumInternalURL = shared::kChromiumSettingsURL;
      }
    }
    allow_next_chromium_internal_navigation_ = true;
    frame->LoadURL(chromiumInternalURL);
    return true;
  }

  return false;
}

bool BrowserTabClient::OnOpenURLFromTab(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const CefString &target_url,
    WindowOpenDisposition target_disposition,
    bool user_gesture) {
  CEF_REQUIRE_UI_THREAD();

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    return false;
  }

  NSString *urlString = ToNSString(target_url.ToString());
  return [controller openURLFromTabWithURLString:urlString
                                     sourceTabID:ToNSString(tab_id_)
                               targetDisposition:target_disposition];
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

bool BrowserTabClient::OnPreKeyEvent(CefRefPtr<CefBrowser>,
                                     const CefKeyEvent &,
                                     CefEventHandle,
                                     bool *) {
  CEF_REQUIRE_UI_THREAD();
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
  return [controller openURLFromTabWithURLString:urlString
                                    sourceTabID:ToNSString(tab_id_)
                              targetDisposition:target_disposition];
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
