#import "Browser/BrowserTabController.h"

#import <AuthenticationServices/AuthenticationServices.h>
#import <QuartzCore/QuartzCore.h>
#import <Sparkle/Sparkle.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "OpenArc-Swift.h"
#import "Browser/SwiftBridge.h"
#include "Shared/BrowserMediaMessages.h"
#include "Shared/BrowserSchemes.h"
#include "Shared/ClientManager.h"
#include "Shared/ClientUtil.h"

#include <atomic>
#include <cctype>
#include <algorithm>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "include/base/cef_callback.h"
#include "include/cef_client.h"
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>

#include "include/cef_browser.h"
#include "include/cef_command_ids.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_image.h"
#include "include/cef_urlrequest.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_download_handler.h"
#include "include/cef_download_item.h"
#include "include/cef_find_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_frame.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_resource_request_handler.h"
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
// CEF creates a page in well under a second; a page missing this long is lost.
constexpr double kBrowserCreationTimeoutSeconds = 30;
constexpr char kRuntimeEvaluateMethod[] = "Runtime.evaluate";
// The selected text, widened to whole words at its ends as a text fragment
// needs (Chromium's own link to highlight does the same). The widened range
// is selected for one synchronous step to read it with line breaks between
// blocks, and the user's selection is put back before anything paints.
constexpr char kSelectedTextExpression[] = R"JS((() => {
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
    return '';
  }
  const original = selection.getRangeAt(0);
  const range = original.cloneRange();
  if (typeof Intl.Segmenter === 'function') {
    const words = new Intl.Segmenter(undefined, { granularity: 'word' });
    const snap = (node, offset, toStart) => {
      if (node.nodeType !== Node.TEXT_NODE) {
        return offset;
      }
      for (const part of words.segment(node.data)) {
        const end = part.index + part.segment.length;
        if (part.isWordLike && part.index < offset && offset < end) {
          return toStart ? part.index : end;
        }
      }
      return offset;
    };
    range.setStart(range.startContainer, snap(range.startContainer, range.startOffset, true));
    range.setEnd(range.endContainer, snap(range.endContainer, range.endOffset, false));
  }
  selection.removeAllRanges();
  selection.addRange(range);
  const text = String(selection);
  selection.removeAllRanges();
  selection.addRange(original);
  return text;
})())JS";
// A page that never answers gives up after this long.
constexpr int64_t kRuntimeEvaluateTimeoutMs = 2000;

constexpr char kWebAppManifestExpression[] = R"JS(
(async () => {
  const links = Array.from(document.querySelectorAll('link[rel]'));
  const documentIcons = links.map((link) => ({
    href: link.href || null,
    rel: link.rel || null,
    sizes: link.sizes ? link.sizes.value : null,
    type: link.type || null
  }));
  const manifestLink = links.find((link) =>
    (link.rel || '').toLowerCase().split(/\s+/).includes('manifest'));
  const manifestURL = manifestLink && manifestLink.href
    ? manifestLink.href
    : null;
  let manifest = null;

  if (manifestURL) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    try {
      const usesCredentials =
        (manifestLink.crossOrigin || '').toLowerCase() === 'use-credentials';
      const response = await fetch(manifestURL, {
        credentials: usesCredentials ? 'include' : 'same-origin',
        signal: controller.signal
      });
      if (response.ok) {
        const rawManifest = await response.json();
        if (rawManifest && typeof rawManifest === 'object' && !Array.isArray(rawManifest)) {
          manifest = {
            id: typeof rawManifest.id === 'string' ? rawManifest.id : null,
            name: typeof rawManifest.name === 'string' ? rawManifest.name : null,
            short_name: typeof rawManifest.short_name === 'string'
              ? rawManifest.short_name
              : null,
            description: typeof rawManifest.description === 'string'
              ? rawManifest.description
              : null,
            start_url: typeof rawManifest.start_url === 'string'
              ? rawManifest.start_url
              : null,
            scope: typeof rawManifest.scope === 'string' ? rawManifest.scope : null,
            display: typeof rawManifest.display === 'string'
              ? rawManifest.display
              : null,
            display_override: Array.isArray(rawManifest.display_override)
              ? rawManifest.display_override.filter((value) => typeof value === 'string')
              : null,
            theme_color: typeof rawManifest.theme_color === 'string'
              ? rawManifest.theme_color
              : null,
            background_color: typeof rawManifest.background_color === 'string'
              ? rawManifest.background_color
              : null,
            icons: Array.isArray(rawManifest.icons)
              ? rawManifest.icons.filter((icon) => icon && typeof icon === 'object')
                  .map((icon) => ({
                    src: typeof icon.src === 'string' ? icon.src : null,
                    type: typeof icon.type === 'string' ? icon.type : null,
                    sizes: typeof icon.sizes === 'string' ? icon.sizes : null,
                    purpose: typeof icon.purpose === 'string' ? icon.purpose : null
                  }))
              : null
          };
        }
      }
    } catch (_) {
      manifest = null;
    } finally {
      clearTimeout(timeout);
    }
  }

  return JSON.stringify({
    documentURL: document.URL,
    documentIcons,
    manifestURL,
    manifest
  });
})()
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
  // The folder chosen in Settings, or the user's Downloads folder.
  NSString *path = [BrowserDownloadLocation directoryPath];
  return path.length > 0 ? path : NSTemporaryDirectory();
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
void SetBrowserViewCornerRadius(NSView *browserView, CGFloat radius,
                                CACornerMask corners);

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

/// Chromium's page view inside a CEF browser view, which implements the page's
/// Cocoa editing actions.
NSView *PageViewHandlingAction(NSView *view, SEL action) {
  if (view == nil) {
    return nil;
  }
  if ([NSStringFromClass(view.class) containsString:@"RenderWidgetHostViewCocoa"] &&
      [view respondsToSelector:action]) {
    return view;
  }
  for (NSView *subview in view.subviews) {
    if (NSView *found = PageViewHandlingAction(subview, action)) {
      return found;
    }
  }
  return nil;
}

/// DevTools JSON writes whole numbers as integers, which CEF parses as ints;
/// `GetDouble` reads those as 0.
double DevToolsNumber(CefRefPtr<CefDictionaryValue> dictionary, const char *key, double fallback = 0) {
  if (!dictionary || !dictionary->HasKey(key)) {
    return fallback;
  }
  switch (dictionary->GetType(key)) {
    case VTYPE_INT:
      return dictionary->GetInt(key);
    case VTYPE_DOUBLE:
      return dictionary->GetDouble(key);
    default:
      return fallback;
  }
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
    [NSNotificationCenter.defaultCenter postNotificationName:@"BrowserCaptureDidCopy" object:pngData];
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

    // The clip is in device-independent pixels: CSS pixels times page zoom.
    const double zoom =
        DevToolsNumber(metrics->GetDictionary("cssVisualViewport"), "zoom", 1);
    const double width = DevToolsNumber(contentSize, "width") * zoom;
    const double height = DevToolsNumber(contentSize, "height") * zoom;
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

/// Capture: the part of the visible page the user outlined, as a PNG on
/// the pasteboard. The outline arrives as fractions of the page view, which
/// the visual viewport turns into page CSS pixels.
class RegionScreenshotObserver final : public CefDevToolsMessageObserver {
 public:
  explicit RegionScreenshotObserver(CGRect fraction) : fraction_(fraction) {}

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

    if (!captured_) {
      captured_ = true;
      CaptureRegion(browser, dictionary);
      return;
    }

    registration_ = nullptr;
    std::string pngData = dictionary->GetString("data").ToString();
    if (!pngData.empty()) {
      if (completion_ != nil) {
        NSString *base64 = ToNSString(pngData);
        void (^completion)(NSData *) = completion_;
        dispatch_async(dispatch_get_main_queue(), ^{
          completion([[NSData alloc] initWithBase64EncodedString:base64 options:0]);
        });
      } else {
        CopyBase64PNGToPasteboardOnMain(pngData);
      }
    }
  }

  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override {
    registration_ = nullptr;
  }

  /// With a completion the picture goes there instead of the clipboard.
  void (^completion_)(NSData *) = nil;

 private:
  void CaptureRegion(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefDictionaryValue> metrics) {
    CefRefPtr<CefBrowserHost> host = browser ? browser->GetHost() : nullptr;
    CefRefPtr<CefDictionaryValue> viewport =
        metrics->GetDictionary("cssVisualViewport");
    if (!host || !viewport) {
      registration_ = nullptr;
      return;
    }

    const double width = DevToolsNumber(viewport, "clientWidth");
    const double height = DevToolsNumber(viewport, "clientHeight");
    if (width <= 0 || height <= 0) {
      registration_ = nullptr;
      return;
    }

    // The clip is in device-independent pixels: CSS pixels times page zoom.
    const double zoom = DevToolsNumber(viewport, "zoom", 1);
    CefRefPtr<CefDictionaryValue> clip = CefDictionaryValue::Create();
    clip->SetDouble("x", (DevToolsNumber(viewport, "pageX") + fraction_.origin.x * width) * zoom);
    clip->SetDouble("y", (DevToolsNumber(viewport, "pageY") + fraction_.origin.y * height) * zoom);
    clip->SetDouble("width", std::max(fraction_.size.width * width * zoom, 1.0));
    clip->SetDouble("height", std::max(fraction_.size.height * height * zoom, 1.0));
    clip->SetDouble("scale", 1);

    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("format", "png");
    params->SetBool("fromSurface", true);
    params->SetDictionary("clip", clip);

    message_id_ = NextDevToolsMessageID();
    if (host->ExecuteDevToolsMethod(message_id_, kPageCaptureScreenshotMethod,
                                    params) == 0) {
      registration_ = nullptr;
    }
  }

  const CGRect fraction_;
  bool captured_ = false;
  int message_id_ = 0;
  CefRefPtr<CefRegistration> registration_;

  IMPLEMENT_REFCOUNTING(RegionScreenshotObserver);
};

/// Evaluates an expression in the page and returns its string value.
// Runs one DevTools method and hands back its result as JSON, or nil.
class DevToolsMethodObserver final : public CefDevToolsMessageObserver {
 public:
  DevToolsMethodObserver(const char *method, const char *params_json, void (^completion)(NSString *))
      : method_(method), params_json_(params_json), completion_([completion copy]) {}

  void Start(CefRefPtr<CefBrowserHost> host) {
    CefRefPtr<CefValue> parsed = CefParseJSON(params_json_, JSON_PARSER_RFC);
    CefRefPtr<CefDictionaryValue> params =
        parsed && parsed->GetType() == VTYPE_DICTIONARY ? parsed->GetDictionary() : CefDictionaryValue::Create();
    if (!host) {
      Finish(nil);
      return;
    }
    registration_ = host->AddDevToolsMessageObserver(this);
    message_id_ = NextDevToolsMessageID();
    if (host->ExecuteDevToolsMethod(message_id_, method_, params) == 0) {
      Finish(nil);
      return;
    }
    CefRefPtr<DevToolsMethodObserver> observer(this);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      observer->Finish(nil);
    });
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>,
                              int message_id,
                              bool success,
                              const void *result,
                              size_t result_size) override {
    if (message_id != message_id_) {
      return;
    }
    NSString *payload = nil;
    if (result && result_size > 0) {
      payload = [[NSString alloc] initWithBytes:result length:result_size encoding:NSUTF8StringEncoding];
    }
    Finish(success ? payload : nil);
  }

 private:
  void Finish(NSString *payload) {
    registration_ = nullptr;
    void (^completion)(NSString *) = completion_;
    completion_ = nil;
    if (completion) {
      completion(payload);
    }
  }

  std::string method_;
  std::string params_json_;
  void (^completion_)(NSString *);
  CefRefPtr<CefRegistration> registration_;
  int message_id_ = 0;

  IMPLEMENT_REFCOUNTING(DevToolsMethodObserver);
};

class RuntimeEvaluateObserver final : public CefDevToolsMessageObserver {
 public:
  RuntimeEvaluateObserver(const char *expression, void (^completion)(NSString *))
      : expression_(expression), completion_([completion copy]) {}

  void Start(CefRefPtr<CefBrowserHost> host) {
    if (!host) {
      Finish(nil);
      return;
    }

    registration_ = host->AddDevToolsMessageObserver(this);
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("expression", expression_);
    params->SetBool("returnByValue", true);
    params->SetBool("awaitPromise", true);

    message_id_ = NextDevToolsMessageID();
    if (host->ExecuteDevToolsMethod(message_id_, kRuntimeEvaluateMethod,
                                    params) == 0) {
      Finish(nil);
      return;
    }
    // A busy or hung page, or one whose answer never resolves, gives nil.
    CefRefPtr<RuntimeEvaluateObserver> observer(this);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kRuntimeEvaluateTimeoutMs * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     observer->Finish(nil);
                   });
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>,
                              int message_id,
                              bool success,
                              const void *result,
                              size_t result_size) override {
    if (message_id != message_id_) {
      return;
    }

    CefRefPtr<CefDictionaryValue> dictionary =
        success ? ParseDevToolsResultDictionary(result, result_size) : nullptr;
    CefRefPtr<CefDictionaryValue> resultDictionary =
        dictionary ? dictionary->GetDictionary("result") : nullptr;
    NSString *payload = nil;
    if (resultDictionary) {
      CefRefPtr<CefValue> value = resultDictionary->GetValue("value");
      if (value && value->GetType() == VTYPE_STRING) {
        payload = ToNSString(value->GetString().ToString());
      } else if (value && value->GetType() != VTYPE_NULL && value->GetType() != VTYPE_INVALID) {
        payload = ToNSString(CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString());
      }
    }
    Finish(payload.length > 0 ? payload : nil);
  }

  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override {
    Finish(nil);
  }

 private:
  void Finish(NSString *payload) {
    if (completion_ == nil) {
      return;
    }

    void (^completion)(NSString *) = [completion_ copy];
    completion_ = nil;
    registration_ = nullptr;
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(payload);
    });
  }

  int message_id_ = 0;
  std::string expression_;
  CefRefPtr<CefRegistration> registration_;
  void (^completion_)(NSString *);

  IMPLEMENT_REFCOUNTING(RuntimeEvaluateObserver);
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
  // The viewport rounds the outer corners of a single page.
  SetBrowserViewCornerRadius(browserView, 0, 0);
}

// A Split View pane's page rounds its bottom corners; the pane bar above it
// draws the top ones, so pane edges match the outer content corners.
void SetBrowserViewCornerRadius(NSView *browserView, CGFloat radius,
                                CACornerMask corners) {
  if (radius <= 0 && !browserView.wantsLayer) {
    return;
  }
  browserView.wantsLayer = YES;
  CALayer *layer = browserView.layer;
  if (layer.cornerRadius == radius && layer.masksToBounds == (radius > 0) &&
      (radius <= 0 || layer.maskedCorners == corners)) {
    return;
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.cornerRadius = radius;
  layer.cornerCurve = kCACornerCurveContinuous;
  layer.masksToBounds = radius > 0;
  if (radius > 0) {
    layer.maskedCorners = corners;
  }
  [CATransaction commit];
}

// Visual bottom corners of a layer: MinY is the bottom unless the layer
// renders flipped.
CACornerMask BottomCornersOfLayer(CALayer *layer) {
  return layer.contentsAreFlipped
             ? (kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner)
             : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner);
}

// A Split View pane is laid out on every host layout, so it must not also
// autoresize to the whole host.
void SyncBrowserViewPaneFrame(CefRefPtr<CefBrowser> browser, NSRect frame) {
  NSView *browserView = BrowserViewForBrowser(browser);
  if (browserView == nil) {
    return;
  }
  browserView.autoresizingMask = NSViewNotSizable;
  if (!NSEqualRects(browserView.frame, frame)) {
    browserView.frame = frame;
  }
  browserView.wantsLayer = YES;
  SetBrowserViewCornerRadius(browserView, BrowserSplitPaneLayout.paneCornerRadius,
                             BottomCornersOfLayer(browserView.layer));
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

void SetBrowserAudioMuted(CefRefPtr<CefBrowser> browser, bool muted) {
  if (!browser) {
    return;
  }

  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (host) {
    host->SetAudioMuted(muted);
  }
}

void SetBrowserAudioMutedOnUI(CefRefPtr<CefBrowser> browser, bool muted) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    SetBrowserAudioMuted(browser, muted);
    return;
  }

  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(&SetBrowserAudioMuted, browser, muted)));
}

void SetBrowserZoomLevel(CefRefPtr<CefBrowser> browser, double zoom_level) {
  if (!browser) {
    return;
  }

  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (host) {
    host->SetZoomLevel(zoom_level);
  }
}

void SetBrowserZoomLevelOnUI(CefRefPtr<CefBrowser> browser,
                             double zoom_level) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    SetBrowserZoomLevel(browser, zoom_level);
    return;
  }

  CefPostTask(
      TID_UI,
      CefCreateClosureTask(
          base::BindOnce(&SetBrowserZoomLevel, browser, zoom_level)));
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

  // Only this site's cookies: an empty URL would delete every cookie in the
  // profile and sign the user out everywhere.
  CefRefPtr<CefFrame> frame = browser->GetMainFrame();
  const std::string url = frame ? frame->GetURL().ToString() : std::string();
  const bool is_web = url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0;
  CefRefPtr<CefCookieManager> cookie_manager =
      request_context->GetCookieManager(nullptr);
  if (!is_web || !cookie_manager ||
      !cookie_manager->DeleteCookies(
          url, CefString(),
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

// Picture in Picture needs user activation, which Runtime.evaluate grants with
// userGesture. The gesture is only sent after a probe without one finds a
// playing video, so other pages never gain activation from a tab switch. Only
// the top document's videos are considered.
constexpr char kHasPlayingVideoScript[] =
    "!document.pictureInPictureElement && Array.from(document.querySelectorAll('video')).some("
    "v => !v.paused && !v.ended && v.readyState > 2 && !v.disablePictureInPicture)";
constexpr char kEnterPictureInPictureScript[] =
    "(() => { const video = Array.from(document.querySelectorAll('video')).find("
    "v => !v.paused && !v.ended && v.readyState > 2 && !v.disablePictureInPicture); "
    "if (video && !document.pictureInPictureElement) "
    "return video.requestPictureInPicture().catch(() => {}); })()";
constexpr char kTogglePictureInPictureScript[] =
    "(() => { if (document.pictureInPictureElement) return document.exitPictureInPicture().catch(() => {}); "
    "const videos = Array.from(document.querySelectorAll('video')).filter("
    "v => !v.disablePictureInPicture && v.readyState > 0); "
    "const video = videos.find(v => !v.paused) || videos[0]; "
    "if (video) return video.requestPictureInPicture().catch(() => {}); })()";
constexpr char kExitPictureInPictureScript[] =
    "document.pictureInPictureElement && document.exitPictureInPicture().catch(() => {})";

void EvaluateInPage(CefRefPtr<CefBrowser> browser, std::string expression, bool userGesture) {
  CefRefPtr<CefBrowserHost> host = browser ? browser->GetHost() : nullptr;
  if (!host) {
    return;
  }

  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", expression);
  params->SetBool("userGesture", userGesture);
  host->ExecuteDevToolsMethod(NextDevToolsMessageID(), "Runtime.evaluate", params);
}

/// Asks the page, without a gesture, whether a video is playing, and only then
/// requests Picture in Picture with one.
class PictureInPictureProbe final : public CefDevToolsMessageObserver {
 public:
  explicit PictureInPictureProbe(void (^done)(void)) : done_(done) {}

  void Start(CefRefPtr<CefBrowserHost> host) {
    registration_ = host->AddDevToolsMessageObserver(this);
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("expression", kHasPlayingVideoScript);
    params->SetBool("returnByValue", true);
    probe_id_ = NextDevToolsMessageID();
    if (host->ExecuteDevToolsMethod(probe_id_, "Runtime.evaluate", params) == 0) {
      Finish();
    }
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void *result,
                              size_t result_size) override {
    if (message_id == enter_id_) {
      Finish();
      return;
    }
    if (message_id != probe_id_) {
      return;
    }

    CefRefPtr<CefDictionaryValue> dictionary =
        success ? ParseDevToolsResultDictionary(result, result_size) : nullptr;
    CefRefPtr<CefDictionaryValue> value = dictionary ? dictionary->GetDictionary("result") : nullptr;
    CefRefPtr<CefBrowserHost> host = browser ? browser->GetHost() : nullptr;
    if (!(value && value->GetBool("value")) || !host) {
      Finish();
      return;
    }
    // Waits for the request to settle, since the page must stay visible until then.
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("expression", kEnterPictureInPictureScript);
    params->SetBool("userGesture", true);
    params->SetBool("awaitPromise", true);
    enter_id_ = NextDevToolsMessageID();
    if (host->ExecuteDevToolsMethod(enter_id_, "Runtime.evaluate", params) == 0) {
      Finish();
    }
  }

  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override {
    Finish();
  }

 private:
  void Finish() {
    registration_ = nullptr;
    if (done_) {
      done_();
      done_ = nil;
    }
  }

  int probe_id_ = 0;
  int enter_id_ = -1;
  void (^done_)(void);
  CefRefPtr<CefRegistration> registration_;

  IMPLEMENT_REFCOUNTING(PictureInPictureProbe);
};

void SetPictureInPicture(CefRefPtr<CefBrowser> browser, bool active, void (^done)(void)) {
  CefRefPtr<CefBrowserHost> host = browser ? browser->GetHost() : nullptr;
  if (!host) {
    done();
    return;
  }

  if (active) {
    CefRefPtr<PictureInPictureProbe> probe = new PictureInPictureProbe(done);
    probe->Start(host);
  } else {
    EvaluateInPage(browser, kExitPictureInPictureScript, false);
    done();
  }
}

// DevTools open in their own CEF window without a client, so none of the
// tab callbacks see that browser. Chrome-style pages (internal pages) are left
// alone: their DevTools would open a Chrome window.
void ShowBrowserDevTools(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (!host || host->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME) {
    return;
  }

  CefWindowInfo windowInfo;
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  host->ShowDevTools(windowInfo, nullptr, CefBrowserSettings(), CefPoint());
}

void ShowBrowserDevToolsOnUI(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    ShowBrowserDevTools(browser);
    return;
  }

  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(&ShowBrowserDevTools, browser)));
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

void CastBrowser(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (host && host->CanExecuteChromeCommand(IDC_ROUTE_MEDIA)) {
    host->ExecuteChromeCommand(IDC_ROUTE_MEDIA, CEF_WOD_CURRENT_TAB);
  }
}

void CastBrowserOnUI(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return;
  }

  if (CefCurrentlyOn(TID_UI)) {
    CastBrowser(browser);
    return;
  }

  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(&CastBrowser, browser)));
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

constexpr uint32_t kDeviceMediaPermissions =
    CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;

/// The tab ID a Peek card's or small window's requests use.
NSString *PeekSitePermissionTabID(int sessionID) {
  return [NSString stringWithFormat:@"peek:%d", sessionID];
}

/// A site permission request waiting for the user: a camera and microphone
/// request from getUserMedia, or one of Chromium's permission prompts.
struct PendingSitePermission {
  std::string tabID;
  CefRefPtr<CefMediaAccessCallback> mediaCallback;
  uint32_t mediaPermissions = 0;
  CefRefPtr<CefPermissionPromptCallback> promptCallback;
  uint64_t promptID = 0;
};

/// Chromium content settings the site control center lists, by
/// BrowserSiteSettingKind raw value.
const std::vector<std::pair<NSString *, cef_content_setting_types_t>> &SiteSettingTypes() {
  static const std::vector<std::pair<NSString *, cef_content_setting_types_t>> types = {
      {@"location", CEF_CONTENT_SETTING_TYPE_GEOLOCATION},
      {@"notifications", CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS},
      {@"clipboard", CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE},
      {@"popups", CEF_CONTENT_SETTING_TYPE_POPUPS},
      {@"sound", CEF_CONTENT_SETTING_TYPE_SOUND},
      {@"automaticDownloads", CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS},
      {@"midi", CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX},
      {@"windowManagement", CEF_CONTENT_SETTING_TYPE_WINDOW_MANAGEMENT},
      {@"localFonts", CEF_CONTENT_SETTING_TYPE_LOCAL_FONTS},
      {@"idleDetection", CEF_CONTENT_SETTING_TYPE_IDLE_DETECTION},
      {@"autoPictureInPicture", CEF_CONTENT_SETTING_TYPE_AUTO_PICTURE_IN_PICTURE},
  };
  return types;
}

NSString *SiteSettingValueName(cef_content_setting_values_t value) {
  switch (value) {
    case CEF_CONTENT_SETTING_VALUE_ALLOW:
      return @"allow";
    case CEF_CONTENT_SETTING_VALUE_BLOCK:
      return @"block";
    case CEF_CONTENT_SETTING_VALUE_ASK:
      return @"ask";
    default:
      return nil;
  }
}

cef_content_setting_values_t SiteSettingValue(NSString *name) {
  if ([name isEqualToString:@"allow"]) return CEF_CONTENT_SETTING_VALUE_ALLOW;
  if ([name isEqualToString:@"block"]) return CEF_CONTENT_SETTING_VALUE_BLOCK;
  if ([name isEqualToString:@"ask"]) return CEF_CONTENT_SETTING_VALUE_ASK;
  return CEF_CONTENT_SETTING_VALUE_DEFAULT;
}

/// BrowserSitePermissionKind raw values for getUserMedia devices.
NSArray<NSString *> *SitePermissionKindsForMedia(uint32_t permissions) {
  NSMutableArray<NSString *> *kinds = [NSMutableArray array];
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) {
    [kinds addObject:@"camera"];
  }
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) {
    [kinds addObject:@"microphone"];
  }
  return kinds;
}

/// BrowserSitePermissionKind raw values for a Chromium permission prompt, in
/// prompt order; types without a name of their own share "other".
NSArray<NSString *> *SitePermissionKindsForPrompt(uint32_t permissions) {
  static const std::pair<uint32_t, NSString *> kKinds[] = {
      {CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, @"camera"},
      {CEF_PERMISSION_TYPE_MIC_STREAM, @"microphone"},
      {CEF_PERMISSION_TYPE_GEOLOCATION, @"location"},
      {CEF_PERMISSION_TYPE_NOTIFICATIONS, @"notifications"},
      {CEF_PERMISSION_TYPE_CLIPBOARD, @"clipboard"},
      {CEF_PERMISSION_TYPE_MIDI_SYSEX, @"midi"},
      {CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, @"windowManagement"},
      {CEF_PERMISSION_TYPE_LOCAL_FONTS, @"localFonts"},
      {CEF_PERMISSION_TYPE_IDLE_DETECTION, @"idleDetection"},
      {CEF_PERMISSION_TYPE_STORAGE_ACCESS | CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, @"storageAccess"},
      {CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, @"multipleDownloads"},
  };
  NSMutableArray<NSString *> *kinds = [NSMutableArray array];
  uint32_t named = 0;
  for (const auto &kind : kKinds) {
    named |= kind.first;
    if (permissions & kind.first) {
      [kinds addObject:kind.second];
    }
  }
  if (permissions & ~named) {
    [kinds addObject:@"other"];
  }
  return kinds;
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
  if (host.empty() || host == shared::kOpenArcCreditsHost) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) == scheme;
}

std::string OpenArcURLForChromiumInternalURL(const CefString &url) {
  std::string urlString = LowercaseASCII(url.ToString());
  if (urlString == "about:credits") {
    return shared::kOpenArcCreditsURL;
  }
  if (urlString == "about:settings") {
    return shared::kOpenArcSettingsURL;
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

  std::string redirectURL = std::string(shared::kOpenArcScheme) + "://" +
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

bool IsOpenArcExtensionsURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) ==
             shared::kOpenArcScheme &&
         LowercaseASCII(URLPartToString(parts.host)) ==
             shared::kOpenArcExtensionsHost;
}

bool IsOpenArcHistoryURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) ==
             shared::kOpenArcScheme &&
         LowercaseASCII(URLPartToString(parts.host)) ==
             shared::kOpenArcHistoryHost;
}

bool IsOpenArcPasswordManagerURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) ==
             shared::kOpenArcScheme &&
         LowercaseASCII(URLPartToString(parts.host)) ==
             shared::kOpenArcPasswordManagerHost;
}

bool IsOpenArcBookmarksURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) {
    return false;
  }

  return LowercaseASCII(URLPartToString(parts.scheme)) ==
             shared::kOpenArcScheme &&
         LowercaseASCII(URLPartToString(parts.host)) ==
             shared::kOpenArcBookmarksHost;
}

bool IsOpenArcInternalWindowURL(const CefString &url) {
  return URLHasSchemeAndInternalHost(url, shared::kOpenArcScheme);
}

std::string ChromiumInternalWindowURLForOpenArcURL(const CefString &url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts) || !IsOpenArcInternalWindowURL(url)) {
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
    std::string displayURL = OpenArcURLForChromiumInternalURL(url);
    if (!displayURL.empty()) {
      return displayURL;
    }
  }

  return url.ToString();
}

bool ShouldUseEmbeddedChromeRuntimeForURL(const std::string &) {
  return false;
}

/// Menu commands the page's context menu adds to CEF's own.
enum PageContextMenuCommand {
  kContextOpenLinkInNewTab = MENU_ID_USER_FIRST,
  kContextOpenLinkInSplitView,
  kContextOpenLinkInLittleWindow,
  kContextOpenLinkInIncognito,
  kContextSaveLink,
  kContextCopyLinkAddress,
  kContextOpenMediaInNewTab,
  kContextSaveMedia,
  kContextPictureInPicture,
  kContextCopyImage,
  kContextCopyMediaAddress,
  kContextCopyLinkToHighlight,
  kContextSearchForSelection,
  kContextSavePage,
  kContextPrint,
  kContextViewSource,
  kContextInspect,
};

CefString LocalizedMenuTitle(NSString *key) {
  return CefString(NSLocalizedString(key, nil).UTF8String);
}

/// Copies a page's image as a picture once it has downloaded.
class CopyImageCallback final : public CefDownloadImageCallback {
 public:
  void OnDownloadImageFinished(const CefString &, int, CefRefPtr<CefImage> image) override {
    if (!image) {
      return;
    }
    int width = 0;
    int height = 0;
    CefRefPtr<CefBinaryValue> png = image->GetAsPNG(1.0, true, width, height);
    if (!png) {
      return;
    }
    NSMutableData *data = [NSMutableData dataWithLength:png->GetSize()];
    png->GetData(data.mutableBytes, data.length, 0);
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setData:data forType:NSPasteboardTypePNG];
  }

 private:
  IMPLEMENT_REFCOUNTING(CopyImageCallback);
};

/// Builds the menu from what lies under the pointer: a link, an image or video,
/// selected text, an editable field, or the page itself.
void BuildPageContextMenu(CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model, bool allowsLinkTargets) {
  model->Clear();
  const auto flags = params->GetTypeFlags();
  const bool hasLink = (flags & CM_TYPEFLAG_LINK) != 0;
  const bool hasSelection = (flags & CM_TYPEFLAG_SELECTION) != 0;
  const bool isEditable = (flags & CM_TYPEFLAG_EDITABLE) != 0;
  const auto mediaType = params->GetMediaType();
  const bool hasImage = mediaType == CM_MEDIATYPE_IMAGE;
  const bool hasPlayer = mediaType == CM_MEDIATYPE_VIDEO || mediaType == CM_MEDIATYPE_AUDIO;
  const auto separate = [&model]() {
    if (model->GetCount() > 0) {
      model->AddSeparator();
    }
  };
  if (hasLink) {
    model->AddItem(kContextOpenLinkInNewTab, LocalizedMenuTitle(@"browser.context.open_link_new_tab"));
    if (allowsLinkTargets) {
      model->AddItem(kContextOpenLinkInSplitView, LocalizedMenuTitle(@"browser.context.open_link_split_view"));
      model->AddItem(kContextOpenLinkInLittleWindow, LocalizedMenuTitle(@"browser.context.open_link_little_window"));
      model->AddItem(kContextOpenLinkInIncognito, LocalizedMenuTitle(@"browser.context.open_link_incognito"));
    }
    separate();
    model->AddItem(kContextSaveLink, LocalizedMenuTitle(@"browser.context.save_link"));
    model->AddItem(kContextCopyLinkAddress, LocalizedMenuTitle(@"browser.context.copy_link"));
  }
  if (mediaType == CM_MEDIATYPE_VIDEO) {
    separate();
    model->AddItem(kContextPictureInPicture, LocalizedMenuTitle(@"browser.context.picture_in_picture"));
  }
  if (hasImage || hasPlayer) {
    separate();
    model->AddItem(kContextOpenMediaInNewTab,
                   LocalizedMenuTitle(hasImage ? @"browser.context.open_image_new_tab" : @"browser.context.open_media_new_tab"));
    model->AddItem(kContextSaveMedia,
                   LocalizedMenuTitle(hasImage ? @"browser.context.save_image" : @"browser.context.save_media"));
    if (hasImage) {
      model->AddItem(kContextCopyImage, LocalizedMenuTitle(@"browser.context.copy_image"));
    }
    model->AddItem(kContextCopyMediaAddress,
                   LocalizedMenuTitle(hasImage ? @"browser.context.copy_image_address" : @"browser.context.copy_media_address"));
  }
  if (isEditable) {
    separate();
    std::vector<CefString> suggestions;
    if (params->GetDictionarySuggestions(suggestions) && !suggestions.empty()) {
      int index = 0;
      for (const auto &suggestion : suggestions) {
        if (MENU_ID_SPELLCHECK_SUGGESTION_0 + index > MENU_ID_SPELLCHECK_SUGGESTION_LAST) {
          break;
        }
        model->AddItem(MENU_ID_SPELLCHECK_SUGGESTION_0 + index, suggestion);
        ++index;
      }
      model->AddSeparator();
    }
    const auto edit = params->GetEditStateFlags();
    const auto addEdit = [&](int command, NSString *key, cef_context_menu_edit_state_flags_t flag) {
      model->AddItem(command, LocalizedMenuTitle(key));
      model->SetEnabled(command, (edit & flag) != 0);
    };
    addEdit(MENU_ID_UNDO, @"browser.context.undo", CM_EDITFLAG_CAN_UNDO);
    addEdit(MENU_ID_REDO, @"browser.context.redo", CM_EDITFLAG_CAN_REDO);
    model->AddSeparator();
    addEdit(MENU_ID_CUT, @"browser.context.cut", CM_EDITFLAG_CAN_CUT);
    addEdit(MENU_ID_COPY, @"browser.context.copy", CM_EDITFLAG_CAN_COPY);
    addEdit(MENU_ID_PASTE, @"browser.context.paste", CM_EDITFLAG_CAN_PASTE);
    addEdit(MENU_ID_PASTE_MATCH_STYLE, @"browser.context.paste_match_style", CM_EDITFLAG_CAN_PASTE);
    addEdit(MENU_ID_SELECT_ALL, @"browser.context.select_all", CM_EDITFLAG_CAN_SELECT_ALL);
  } else if (hasSelection) {
    separate();
    model->AddItem(MENU_ID_COPY, LocalizedMenuTitle(@"browser.context.copy"));
    if (allowsLinkTargets) {
      model->AddItem(kContextCopyLinkToHighlight, LocalizedMenuTitle(@"browser.context.copy_link_to_highlight"));
    }
    NSString *selection = ToNSString(params->GetSelectionText().ToString());
    selection = [selection stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (selection.length > 40) {
      selection = [[selection substringToIndex:40] stringByAppendingString:@"…"];
    }
    NSString *format = NSLocalizedString(@"browser.context.search_for_selection", nil);
    model->AddItem(kContextSearchForSelection, CefString([NSString stringWithFormat:format, selection].UTF8String));
  }
  if (!hasLink && !hasImage && !hasPlayer && !hasSelection && !isEditable) {
    model->AddItem(MENU_ID_BACK, LocalizedMenuTitle(@"browser.context.back"));
    model->AddItem(MENU_ID_FORWARD, LocalizedMenuTitle(@"browser.context.forward"));
    model->AddItem(MENU_ID_RELOAD, LocalizedMenuTitle(@"browser.context.reload"));
    model->AddSeparator();
    if (allowsLinkTargets) {
      model->AddItem(kContextSavePage, LocalizedMenuTitle(@"browser.context.save_page"));
    }
    model->AddItem(kContextPrint, LocalizedMenuTitle(@"browser.context.print"));
    model->AddSeparator();
    if (allowsLinkTargets) {
      model->AddItem(kContextViewSource, LocalizedMenuTitle(@"browser.context.view_source"));
    }
  } else if (hasSelection && !isEditable && !hasLink) {
    model->AddItem(kContextPrint, LocalizedMenuTitle(@"browser.context.print"));
  }
  separate();
  model->AddItem(kContextInspect, LocalizedMenuTitle(@"browser.context.inspect"));
}

/// Runs a command that does not need the window; false hands it to the caller.
bool RunBasicPageContextCommand(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefContextMenuParams> params,
                                int command) {
  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (!host) {
    return false;
  }
  const auto copyToPasteboard = [](const CefString &value) {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:ToNSString(value.ToString()) forType:NSPasteboardTypeString];
  };
  switch (command) {
    case kContextPictureInPicture:
      EvaluateInPage(browser, kTogglePictureInPictureScript, true);
      return true;
    case kContextSaveLink:
      host->StartDownload(params->GetLinkUrl());
      return true;
    case kContextCopyLinkAddress:
      copyToPasteboard(params->GetLinkUrl());
      return true;
    case kContextSaveMedia:
      host->StartDownload(params->GetSourceUrl());
      return true;
    case kContextCopyImage:
      host->DownloadImage(params->GetSourceUrl(), false, 0, false, new CopyImageCallback());
      return true;
    case kContextCopyMediaAddress:
      copyToPasteboard(params->GetSourceUrl());
      return true;
    case kContextPrint:
      host->Print();
      return true;
    case kContextInspect: {
      CefWindowInfo windowInfo;
      windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
      host->ShowDevTools(windowInfo, nullptr, CefBrowserSettings(), CefPoint(params->GetXCoord(), params->GetYCoord()));
      return true;
    }
    default:
      return false;
  }
}

/// One GET, read to the end. A 401 fails it here instead of opening Chromium's password window.
class BrowserTextRequestClient final : public CefURLRequestClient {
 public:
  explicit BrowserTextRequestClient(void (^completion)(NSString *)) : completion_([completion copy]) {}

  void Start(CefRefPtr<CefRequest> request, CefRefPtr<CefRequestContext> context) {
    request_ = CefURLRequest::Create(request, this, context);
  }

  void OnRequestComplete(CefRefPtr<CefURLRequest> request) override {
    CefRefPtr<CefResponse> response = request->GetResponse();
    const bool succeeded = request->GetRequestStatus() == UR_SUCCESS && response && response->GetStatus() == 200;
    NSString *text = succeeded ? ToNSString(body_) : nil;
    void (^completion)(NSString *) = completion_;
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(text);
    });
    request_ = nullptr;
  }
  void OnUploadProgress(CefRefPtr<CefURLRequest>, int64_t, int64_t) override {}
  void OnDownloadProgress(CefRefPtr<CefURLRequest>, int64_t, int64_t) override {}
  void OnDownloadData(CefRefPtr<CefURLRequest>, const void *data, size_t data_length) override {
    body_.append(static_cast<const char *>(data), data_length);
  }
  bool GetAuthCredentials(bool,
                          const CefString &,
                          int,
                          const CefString &,
                          const CefString &,
                          CefRefPtr<CefAuthCallback>) override {
    return false;
  }

 private:
  void (^completion_)(NSString *);
  CefRefPtr<CefURLRequest> request_;
  std::string body_;
  IMPLEMENT_REFCOUNTING(BrowserTextRequestClient);
};

class BrowserTabClient final : public CefClient,
                               public CefContextMenuHandler,
                               public CefDisplayHandler,
                               public CefDownloadHandler,
                               public CefFocusHandler,
                               public CefFrameHandler,
                               public CefKeyboardHandler,
                               public CefJSDialogHandler,
                               public CefLifeSpanHandler,
                               public CefLoadHandler,
                               public CefRequestHandler,
                               public CefPermissionHandler,
                               public CefFindHandler {
 public:
  BrowserTabClient(BrowserTabController *controller, const std::string &tabID)
      : controller_(controller), tab_id_(tabID) {}

  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefFrameHandler> GetFrameHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
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

  bool OnAutoResize(CefRefPtr<CefBrowser> browser,
                    const CefSize& new_size) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString &title) override;

  void OnStatusMessage(CefRefPtr<CefBrowser> browser,
                       const CefString &value) override;

  void OnMediaAccessChange(CefRefPtr<CefBrowser> browser,
                           bool has_video_access,
                           bool has_audio_access) override;

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
  void OnBeforeContextMenu(CefRefPtr<CefBrowser>,
                           CefRefPtr<CefFrame>,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    BuildPageContextMenu(params, model, true);
  }
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params,
                            int command_id,
                            EventFlags event_flags) override;
  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override;
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString &error_string) override;
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;
  void OnFrameDetached(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame) override;
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
  bool OnKeyEvent(CefRefPtr<CefBrowser> browser,
                  const CefKeyEvent &event,
                  CefEventHandle os_event) override;

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString &message_text,
                            bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override;
  bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                  const CefString &origin_url,
                  JSDialogType dialog_type,
                  const CefString &message_text,
                  const CefString &default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool &suppress_message) override;
  bool GetAuthCredentials(CefRefPtr<CefBrowser> browser,
                          const CefString &origin_url,
                          bool isProxy,
                          const CefString &host,
                          int port,
                          const CefString &realm,
                          const CefString &scheme,
                          CefRefPtr<CefAuthCallback> callback) override;
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override;
  void OnGotFocus(CefRefPtr<CefBrowser> browser) override;
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
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser,
                                 uint64_t prompt_id,
                                 cef_permission_request_result_t result) override;
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const CefString &requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override;

 private:
  __weak BrowserTabController *controller_;
  const std::string tab_id_;
  bool allow_next_chromium_internal_navigation_ = false;

  IMPLEMENT_REFCOUNTING(BrowserTabClient);
};

/// Peek and the small window: the page in a floating card or small window.
/// It reports its address, lifetime and downloads to the controller, routes
/// new windows to tabs and closes cards on Escape. The client manager tracks
/// it, so quitting waits for it like a tab.
class BrowserPeekClient final : public CefClient,
                                public CefContextMenuHandler,
                                public CefDisplayHandler,
                                public CefDownloadHandler,
                                public CefFocusHandler,
                                public CefKeyboardHandler,
                                public CefLifeSpanHandler,
                                public CefLoadHandler,
                                public CefRequestHandler,
                                public CefJSDialogHandler,
                                public CefPermissionHandler {
 public:
  BrowserPeekClient(BrowserTabController *controller, int sessionID)
      : controller_(controller), session_id_(sessionID) {}

  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                  const CefString &origin_url,
                  JSDialogType dialog_type,
                  const CefString &message_text,
                  const CefString &default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool &suppress_message) override;
  bool GetAuthCredentials(CefRefPtr<CefBrowser> browser,
                          const CefString &origin_url,
                          bool isProxy,
                          const CefString &host,
                          int port,
                          const CefString &realm,
                          const CefString &scheme,
                          CefRefPtr<CefAuthCallback> callback) override;
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override;

  void OnBeforeContextMenu(CefRefPtr<CefBrowser>,
                           CefRefPtr<CefFrame>,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    BuildPageContextMenu(params, model, false);
  }
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame>,
                            CefRefPtr<CefContextMenuParams> params,
                            int command_id,
                            EventFlags) override {
    if (RunBasicPageContextCommand(browser, params, command_id)) {
      return true;
    }
    if (command_id == kContextOpenLinkInNewTab) {
      [controller_ showPeekWithURLString:ToNSString(params->GetLinkUrl().ToString())];
      return true;
    }
    return false;
  }
  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override;
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser,
      uint64_t prompt_id,
      const CefString &requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override;
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser,
                                 uint64_t prompt_id,
                                 cef_permission_request_result_t result) override;
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const CefString &requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString &url) override;
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString &suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;
  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                     const CefKeyEvent &event,
                     CefEventHandle os_event,
                     bool *is_keyboard_shortcut) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString &target_url,
                        WindowOpenDisposition target_disposition,
                        bool user_gesture) override;
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
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString &error_string) override;

 private:
  __weak BrowserTabController *controller_;
  // The controller looks the session up; callbacks of a finished one are dropped.
  const int session_id_;

  IMPLEMENT_REFCOUNTING(BrowserPeekClient);
};

/// One frame's media, as its renderer last reported it.
struct MediaFrameState {
  bool audible = false;
  bool playing = false;
  bool paused = false;
  bool video = false;
  bool hasPreviousTrack = false;
  bool hasNextTrack = false;
  bool pictureInPicture = false;
  std::string title;

  bool operator==(const MediaFrameState &other) const {
    return audible == other.audible && playing == other.playing && paused == other.paused &&
           video == other.video &&
           hasPreviousTrack == other.hasPreviousTrack && hasNextTrack == other.hasNextTrack &&
           pictureInPicture == other.pictureInPicture &&
           title == other.title;
  }
};

struct TabRecord {
  // Stays visible under the active tab while its video moves to Picture in Picture.
  bool keptVisibleForPictureInPicture = false;
  // The data store of the tab's profile, fixed while the page lives.
  CefRefPtr<CefRequestContext> requestContext;
  CefRefPtr<CefClient> client;
  CefRefPtr<CefBrowser> browser;
  BrowserTabEngineCreationState creationState =
      BrowserTabEngineCreationStateCreating;
  // Counts accepted creation attempts, so a watchdog only fails its own.
  int creationAttempt = 0;
  // Failed by the watchdog rather than refused: a late page still attaches.
  bool creationTimedOut = false;
  std::string latestURL;
  bool navigationPending = false;
  bool navigationDrainScheduled = false;
  bool initialNavigationEnabled = false;
  bool hasIssuedNavigation = false;
  bool isClosing = false;
  // Applied again when the engine attaches, so a mute set early survives.
  bool audioMuted = false;
  // Playing frames by identifier, the frame the controls reach, and the
  // state last sent to the delegate.
  std::map<std::string, MediaFrameState> mediaFrames;
  std::string mediaControlFrameID;
  // The frame that last had sound keeps the controls while all are paused.
  std::string lastAudibleMediaFrameID;
  MediaFrameState reportedMedia;
  std::string closeRequestID;
  CefRefPtr<CefJSDialogCallback> closeDialogCallback;
  int rendererProcessID = 0;
  __strong BrowserBeforeUnloadConfirmation *closeConfirmation = nil;
};

}  // namespace

@interface BrowserTabHostView ()

@property(nonatomic, weak) BrowserTabController *controller;

@end

@class BrowserPeekSession;

@interface BrowserTabController ()

- (void)startBrowserCreationForTabID:(NSString *)tabID
                         URLString:(NSString *)urlString;
- (void)watchBrowserCreationForTabID:(NSString *)tabID;
- (void)failStalledBrowserCreationForTabID:(NSString *)tabID attempt:(int)attempt;
- (void)scheduleNavigationForTabID:(NSString *)tabID;
- (void)drainNavigationForTabID:(NSString *)tabID;
- (BOOL)shouldBlockNavigationFocusForTabID:(NSString *)tabID;
- (void)handleBrowserCreated:(CefRefPtr<CefBrowser>)browser
                     forTabID:(NSString *)tabID;
- (void)handleBrowserClosed:(CefRefPtr<CefBrowser>)browser forTabID:(NSString *)tabID;
- (BOOL)handleBeforeUnloadForTabID:(NSString *)tabID
                         browser:(CefRefPtr<CefBrowser>)browser
                        callback:(CefRefPtr<CefJSDialogCallback>)callback;
- (void)resetCloseDialogForTabID:(NSString *)tabID browser:(CefRefPtr<CefBrowser>)browser;
- (void)presentPageDialogForTabID:(NSString *)tabID
                             kind:(NSInteger)kind
                           origin:(NSString *)origin
                          message:(NSString *)message
                      defaultText:(NSString *)defaultText
                         callback:(CefRefPtr<CefJSDialogCallback>)callback;
- (void)cancelPageDialogForTabID:(NSString *)tabID;
- (void)presentAuthDialogForTabID:(NSString *)tabID
                             host:(NSString *)host
                           origin:(NSString *)origin
                         callback:(CefRefPtr<CefAuthCallback>)callback;
- (void)cancelDialogsForTabID:(NSString *)tabID;
- (void)presentScreenSharePickerForTabID:(NSString *)tabID
                                  origin:(NSString *)origin
                                callback:(CefRefPtr<CefMediaAccessCallback>)callback;
- (BOOL)isDialogTabVisible:(NSString *)tabID;
- (void)presentWaitingDialogs;
- (void)noteRendererProcessID:(int)processID forTabID:(NSString *)tabID;
- (void)finishCloseDialogForTabID:(NSString *)tabID
                      requestID:(NSString *)requestID
                        browser:(CefRefPtr<CefBrowser>)browser
                      confirmed:(BOOL)confirmed;
- (void)invalidateCloseRequestForTabID:(NSString *)tabID;
- (void)handlePeekCreated:(CefRefPtr<CefBrowser>)browser session:(int)sessionID;
- (void)handlePeekClosed:(CefRefPtr<CefBrowser>)browser session:(int)sessionID;
- (void)handlePeekAddressChange:(NSString *)urlString session:(int)sessionID;
- (void)closePeekSession:(int)sessionID;
- (void)closePeekSessionByUser:(int)sessionID;
- (void)closePeekBrowserForSession:(BrowserPeekSession *)session;
- (BOOL)isPeekSessionStandalone:(int)sessionID;
- (BOOL)isPeekSessionEditingAddress:(int)sessionID;
- (void)presentPeekWithURLString:(NSString *)urlString standalone:(BOOL)standalone;
- (void)navigatePeekSession:(int)sessionID toURLString:(NSString *)urlString;
- (BOOL)shouldPeekNavigationFromTabID:(NSString *)tabID toURLString:(NSString *)urlString;
- (void)notifyCloseRequestForTabID:(NSString *)tabID
                       requestID:(NSString *)requestID
                         outcome:(BrowserTabCloseRequestOutcome)outcome;
- (void)handleTitleChange:(NSString *)title forTabID:(NSString *)tabID;
- (void)applyMediaVolumeForTabID:(NSString *)tabID toFrame:(CefRefPtr<CefFrame>)frame;
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
- (void)updateBrowserVisibilityFocusingActiveTab:(BOOL)focusActive;
- (void)handleFocusForTabID:(NSString *)tabID;
- (void)requestSitePermissionForTabID:(NSString *)tabID
                               origin:(NSString *)origin
                                kinds:(NSArray<NSString *> *)kinds
                              pending:(PendingSitePermission)pending;
- (void)dismissSitePermissionPromptWithID:(uint64_t)promptID;
- (CefRefPtr<CefRequestContext>)siteSettingsContext;
- (CefRefPtr<CefRequestContext>)activeTabRequestContext;
- (void)cancelSitePermissionsForTabID:(NSString *)tabID;
- (void)cancelMediaSitePermissionsForTabID:(NSString *)tabID;
- (void)handleMediaState:(const MediaFrameState &)state
                 frameID:(const std::string &)frameID
                forTabID:(NSString *)tabID;
- (void)resetMediaForTabID:(NSString *)tabID;
- (void)forgetMediaFrame:(const std::string &)frameID forTabID:(NSString *)tabID;
- (void)handleRenderProcessTerminatedForTabID:(NSString *)tabID errorCode:(int)errorCode;
- (void)reportMedia:(const MediaFrameState &)state forTabID:(NSString *)tabID record:(TabRecord &)record;
- (void)combineMediaForTabID:(NSString *)tabID record:(TabRecord &)record;
- (void)notifySitePermissionDismissed:(NSInteger)requestID;
- (void)handlePasswordFormInFrame:(CefRefPtr<CefFrame>)frame forTabID:(NSString *)tabID;
- (void)handleAddressFormInFrame:(CefRefPtr<CefFrame>)frame forTabID:(NSString *)tabID;
- (void)handleCardFormInFrame:(CefRefPtr<CefFrame>)frame forTabID:(NSString *)tabID;
- (void)handleAddressSubmittedInFrame:(CefRefPtr<CefFrame>)frame
                                 json:(NSString *)json
                             forTabID:(NSString *)tabID;
- (void)handlePasswordSubmittedInFrame:(CefRefPtr<CefFrame>)frame
                              username:(NSString *)username
                              password:(NSString *)password
                              forTabID:(NSString *)tabID;

@end

/// One Peek card or small window. The session owns its panel until the
/// page has closed, because CEF keeps a pointer to the panel's host view while
/// the page is created or torn down.
@interface BrowserPeekSession : NSObject
@property(nonatomic, strong) BrowserPeekPanel *panel;
@property(nonatomic, copy) NSString *urlString;
/// The address the page was created with; a later one typed before the page
/// attached loads when it does.
@property(nonatomic, copy) NSString *initialURLString;
@property(nonatomic) BOOL closing;
/// A small window rather than a card over a page.
@property(nonatomic) BOOL standalone;
/// When a small window was last in front.
@property(nonatomic, strong) NSDate *lastUsed;
/// The tab a card was opened on. The card hides while another tab is shown and
/// comes back with its tab; closing the tab closes it.
@property(nonatomic, copy, nullable) NSString *ownerTabID;
/// A card put away because its tab is not the one shown.
@property(nonatomic) BOOL hiddenWithTab;
@end

@implementation BrowserPeekSession {
 @public
  CefRefPtr<CefBrowser> _browser;
}
@end

namespace {

class BrowserTabCloseReplyTask final : public CefTask {
 public:
  BrowserTabCloseReplyTask(BrowserTabController *controller,
                          const std::string &tabID,
                          const std::string &requestID,
                          CefRefPtr<CefBrowser> browser,
                          bool confirmed)
      : controller_(controller), tab_id_(tabID), request_id_(requestID),
        browser_(browser), confirmed_(confirmed) {}

  void Execute() override {
    CEF_REQUIRE_UI_THREAD();
    BrowserTabController *controller = controller_;
    [controller finishCloseDialogForTabID:ToNSString(tab_id_)
                               requestID:ToNSString(request_id_)
                                 browser:browser_
                               confirmed:confirmed_];
  }

 private:
  __weak BrowserTabController *controller_;
  const std::string tab_id_;
  const std::string request_id_;
  CefRefPtr<CefBrowser> browser_;
  const bool confirmed_;
  IMPLEMENT_REFCOUNTING(BrowserTabCloseReplyTask);
};

// Resolve the record and latest target when the task runs. Holding a browser or
// URL here would load obsolete work after another navigation or a tab close.
class BrowserTabNavigationTask final : public CefTask {
 public:
  BrowserTabNavigationTask(BrowserTabController *controller,
                           const std::string &tabID)
      : controller_(controller), tab_id_(tabID) {}

  void Execute() override {
    CEF_REQUIRE_UI_THREAD();
    BrowserTabController *controller = controller_;
    [controller drainNavigationForTabID:ToNSString(tab_id_)];
  }

 private:
  __weak BrowserTabController *controller_;
  const std::string tab_id_;

  IMPLEMENT_REFCOUNTING(BrowserTabNavigationTask);
};

}  // namespace

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

// Accent border inside the focused Split View pane. It stays above the pane
// views and never takes mouse events, so clicks still reach the page.
@interface BrowserSplitFocusRingView : NSView
@end

@implementation BrowserSplitFocusRingView

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self == nil) {
    return nil;
  }
  self.wantsLayer = YES;
  self.layer.borderWidth = BrowserSplitPaneLayout.focusRingWidth;
  self.layer.cornerRadius = BrowserSplitPaneLayout.focusRingCornerRadius;
  self.layer.borderColor = BrowserSplitPaneLayout.focusRingColor.CGColor;
  [self setAccessibilityElement:NO];
  return self;
}

- (NSView *)hitTest:(NSPoint)point {
  return nil;
}

- (BOOL)wantsUpdateLayer {
  return YES;
}

- (void)updateLayer {
  self.layer.borderColor = BrowserSplitPaneLayout.focusRingColor.CGColor;
}

@end

namespace {
void WatchClickModifiers();
}  // namespace

namespace {

class BrowserNavigationEntryCollector : public CefNavigationEntryVisitor {
 public:
  explicit BrowserNavigationEntryCollector(
      void (^completion)(NSArray<NSDictionary<NSString *, NSString *> *> *, NSInteger))
      : completion_([completion copy]), entries_([NSMutableArray array]) {}

  ~BrowserNavigationEntryCollector() override { completion_(entries_, current_); }

  bool Visit(CefRefPtr<CefNavigationEntry> entry, bool current, int index, int) override {
    if (current) {
      current_ = index;
    }
    [entries_ addObject:@{
      @"url" : ToNSString(entry->GetDisplayURL().ToString()),
      @"title" : ToNSString(entry->GetTitle().ToString()),
    }];
    return true;
  }

 private:
  void (^completion_)(NSArray<NSDictionary<NSString *, NSString *> *> *, NSInteger);
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries_;
  NSInteger current_ = 0;
  IMPLEMENT_REFCOUNTING(BrowserNavigationEntryCollector);
};

}  // namespace

namespace {

// The engine has no per-tab level, so a page's own elements carry it. A later
// element or one the page resets gets it again when it starts to play.
std::string BrowserMediaVolumeScript(double volume) {
  const std::string level = std::to_string(volume);
  return "(()=>{globalThis.__openarcMediaVolume=" + level +
         ";for(const m of document.querySelectorAll('audio,video'))m.volume=" + level +
         ";if(!globalThis.__openarcMediaVolumeListens){globalThis.__openarcMediaVolumeListens=true;"
         "document.addEventListener('play',e=>{if(e.target&&'volume' in e.target)"
         "e.target.volume=globalThis.__openarcMediaVolume},true);"
         "document.addEventListener('volumechange',e=>{const t=e.target;"
         "if(t&&t.volume>globalThis.__openarcMediaVolume)t.volume=globalThis.__openarcMediaVolume},true)}})();";
}

}  // namespace

@implementation BrowserTabController {
  NSMutableDictionary<NSString *, NSNumber *> *_mediaVolumes;
  __weak BrowserTabHostView *_hostView;
  std::map<std::string, TabRecord> _tabRecords;
  CefRefPtr<CefRequestContext> _requestContext;
  std::map<std::string, CefRefPtr<CefRequestContext>> _spaceProfileContexts;
  NSTimer *_smallWindowSweepTimer;
  NSString *_activeTabID;
  NSArray<NSString *> *_visibleLayoutTabIDs;
  BOOL _visibleLayoutVertical;
  NSArray<NSNumber *> *_visibleLayoutFractions;
  BrowserSplitFocusRingView *_splitFocusRing;
  NSMutableArray<BrowserSplitDividerView *> *_splitDividers;
  BOOL _splitDividerMoved;
  NSArray<NSString *> *_reportedSplitPaneTabIDs;
  NSArray<NSValue *> *_reportedSplitPaneFrames;
  NSMutableDictionary<NSNumber *, BrowserPeekSession *> *_peekSessions;
  NSMutableDictionary<NSString *, BrowserJavaScriptDialog *> *_pageDialogs;
  NSMutableDictionary<NSString *, BrowserAuthDialog *> *_authDialogs;
  NSMutableDictionary<NSString *, BrowserScreenSharePicker *> *_screenSharePickers;
  NSString *_lastExtensionTabsJSON;
  NSSet<NSString *> *_warmTabIDs;
  BOOL _lastExtensionTabsFocused;
  int _nextPeekSessionID;
  int _peekCardSessionID;
  NSDictionary<NSString *, NSString *> *_reportedPeekPages;
  std::map<int, PendingSitePermission> _sitePermissions;
  int _nextSitePermissionID;
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
  WatchClickModifiers();

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
  record.requestContext = [self requestContextForNewTab];
  record.latestURL = ToStdString(resolvedURLString);
  record.navigationPending = true;
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

  [self startBrowserCreationForTabID:tabID URLString:resolvedURLString];
  return tabID;
}

- (BOOL)retryTabCreationWithID:(NSString *)tabID urlString:(NSString *)urlString {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || it->second.isClosing ||
      it->second.creationState != BrowserTabEngineCreationStateFailed) {
    return NO;
  }

  // A synchronous refusal never created a browser. Retain the logical ID and
  // selection, and admit exactly one new attempt from that terminal state.
  it->second.creationState = BrowserTabEngineCreationStateCreating;
  it->second.creationTimedOut = false;
  it->second.client = new BrowserTabClient(self, ToStdString(tabID));
  it->second.requestContext = [self requestContextForNewTab];
  NSString *resolvedURLString =
      urlString.length > 0 ? [urlString copy] : @"about:blank";
  it->second.latestURL = ToStdString(resolvedURLString);
  it->second.navigationPending = true;
  it->second.initialNavigationEnabled = false;
  it->second.hasIssuedNavigation = false;
  [self startBrowserCreationForTabID:tabID URLString:resolvedURLString];
  return YES;
}

- (void)startBrowserCreationForTabID:(NSString *)tabID
                         URLString:(NSString *)urlString {
  std::string tabKey = ToStdString(tabID);
  auto it = _tabRecords.find(tabKey);
  if (it == _tabRecords.end() || it->second.isClosing ||
      it->second.creationState != BrowserTabEngineCreationStateCreating) {
    return;
  }
  CefRefPtr<CefClient> client = it->second.client;
  CefRefPtr<CefRequestContext> requestContext = it->second.requestContext;
  [self.delegate browserTabController:self
       didChangeCreationStateForTabWithID:tabID
                                   state:BrowserTabEngineCreationStateCreating];

  std::string resolvedURL = ToStdString(urlString);
  CefWindowInfo windowInfo;
  windowInfo.SetAsChild((__bridge CefWindowHandle)_hostView,
                        CefRectFromBounds(_hostView.bounds));
  if (ShouldUseEmbeddedChromeRuntimeForURL(resolvedURL)) {
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  } else if (shared::IsAlloyStyleEnabled()) {
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  }

  CefBrowserSettings browserSettings;
  if (_autoResizesPages) {
    // A popup's page has no window behind it to show through.
    browserSettings.background_color = CefColorSetARGB(255, 255, 255, 255);
  }

  // CEF's initial URL is loaded after OnAfterCreated. Bootstrap without one so
  // that a newer queued target cannot be overwritten by that original load.
  const bool accepted = CefBrowserHost::CreateBrowser(
      windowInfo, client, CefString(), browserSettings, nullptr,
      requestContext);
  if (accepted) {
    [self watchBrowserCreationForTabID:tabID];
  } else {
    auto failed = _tabRecords.find(tabKey);
    if (failed != _tabRecords.end() &&
        failed->second.creationState == BrowserTabEngineCreationStateCreating) {
      failed->second.creationState = BrowserTabEngineCreationStateFailed;
      [self.delegate browserTabController:self
           didChangeCreationStateForTabWithID:tabID
                                       state:BrowserTabEngineCreationStateFailed];
    }
  }
  [self updateBrowserVisibilityFocusingActiveTab:[_activeTabID isEqualToString:tabID]];
}

/// CEF may accept a creation and never report the page. After a generous wait
/// the tab shows the failure with Retry; a page that still arrives attaches.
- (void)watchBrowserCreationForTabID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end()) {
    return;
  }
  const int attempt = ++it->second.creationAttempt;
  it->second.creationTimedOut = false;
  __weak BrowserTabController *weakSelf = self;
  NSString *watchedTabID = [tabID copy];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBrowserCreationTimeoutSeconds * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [weakSelf failStalledBrowserCreationForTabID:watchedTabID attempt:attempt];
                 });
}

- (void)failStalledBrowserCreationForTabID:(NSString *)tabID attempt:(int)attempt {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || it->second.isClosing || it->second.creationAttempt != attempt ||
      it->second.creationState != BrowserTabEngineCreationStateCreating) {
    return;
  }
  it->second.creationState = BrowserTabEngineCreationStateFailed;
  it->second.creationTimedOut = true;
  [self.delegate browserTabController:self
       didChangeCreationStateForTabWithID:tabID
                                   state:BrowserTabEngineCreationStateFailed];
}

- (void)acknowledgeTabReadyWithID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() ||
      (it->second.isClosing && it->second.closeRequestID.empty()) ||
      it->second.creationState != BrowserTabEngineCreationStateReady) {
    return;
  }

  // Preserve the ready handshake during a cancelable close; navigation itself
  // stays suspended until cancellation clears isClosing.
  it->second.initialNavigationEnabled = true;
  [self scheduleNavigationForTabID:tabID];
}

- (void)selectTabWithID:(NSString *)tabID {
  _activeTabID = [tabID copy];
  [self updateBrowserVisibility];
}

- (void)setVisibleTabLayoutWithTabIDs:(NSArray<NSString *> *)tabIDs
                             vertical:(BOOL)vertical
                            fractions:(NSArray<NSNumber *> *)fractions {
  NSArray<NSString *> *nextTabIDs = tabIDs.count >= 2 ? [tabIDs copy] : nil;
  NSArray<NSNumber *> *nextFractions =
      fractions.count == nextTabIDs.count ? [fractions copy] : nil;
  if ((_visibleLayoutTabIDs == nextTabIDs ||
       [_visibleLayoutTabIDs isEqualToArray:nextTabIDs]) &&
      _visibleLayoutVertical == vertical &&
      (_visibleLayoutFractions == nextFractions ||
       [_visibleLayoutFractions isEqualToArray:nextFractions])) {
    return;
  }
  _visibleLayoutTabIDs = nextTabIDs;
  _visibleLayoutVertical = vertical;
  _visibleLayoutFractions = nextFractions;
  // Layout changes never move keyboard focus; selection does that.
  [self updateBrowserVisibilityFocusingActiveTab:NO];
}

// Tabs shown in this window, in pane order. Outside a split, or when fewer
// than two panes have a live engine, only the active tab is shown.
- (std::vector<std::string>)visiblePaneKeys {
  std::vector<std::string> keys;
  if (_activeTabID == nil) {
    return keys;
  }
  if ([_visibleLayoutTabIDs containsObject:_activeTabID]) {
    for (NSString *tabID in _visibleLayoutTabIDs) {
      auto it = _tabRecords.find(ToStdString(tabID));
      if (it != _tabRecords.end() && !it->second.isClosing &&
          BrowserViewForBrowser(it->second.browser) != nil) {
        keys.push_back(it->first);
      }
    }
  }
  if (keys.size() < 2) {
    keys.assign(1, ToStdString(_activeTabID));
  }
  return keys;
}

- (BOOL)isVisiblePaneTabID:(NSString *)tabID {
  const std::string key = ToStdString(tabID);
  for (const auto &visible : [self visiblePaneKeys]) {
    if (visible == key) {
      return YES;
    }
  }
  return NO;
}

- (void)layoutVisiblePanes:(const std::vector<std::string> &)keys {
  BrowserTabHostView *hostView = _hostView;
  if (hostView == nil || keys.size() < 2) {
    _splitFocusRing.hidden = YES;
    [self hideSplitDividersFromIndex:0];
    [self reportSplitPaneTabIDs:@[] frames:@[]];
  }
  if (hostView == nil || keys.empty()) {
    return;
  }
  if (keys.size() == 1) {
    auto it = _tabRecords.find(keys.front());
    if (it != _tabRecords.end()) {
      SyncBrowserViewFrame(hostView, it->second.browser);
    }
    return;
  }
  NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
  if (_visibleLayoutFractions.count == _visibleLayoutTabIDs.count) {
    for (NSUInteger index = 0; index < _visibleLayoutTabIDs.count; index++) {
      if (std::find(keys.begin(), keys.end(),
                    ToStdString(_visibleLayoutTabIDs[index])) != keys.end()) {
        [fractions addObject:_visibleLayoutFractions[index]];
      }
    }
  }
  NSArray<NSValue *> *frames =
      [BrowserSplitPaneLayout paneFramesInBounds:hostView.bounds
                                           count:(NSInteger)keys.size()
                                        vertical:_visibleLayoutVertical
                                       fractions:fractions
                                         flipped:hostView.isFlipped];
  [self layoutSplitDividersInHostView:hostView
                          paneFrames:frames
                                keys:keys];
  const std::string activeKey = ToStdString(_activeTabID);
  BOOL showsFocusRing = NO;
  NSMutableArray<NSString *> *paneTabIDs = [NSMutableArray array];
  for (size_t index = 0; index < keys.size() && index < frames.count; index++) {
    [paneTabIDs addObject:ToNSString(keys[index])];
    auto it = _tabRecords.find(keys[index]);
    if (it != _tabRecords.end()) {
      SyncBrowserViewPaneFrame(
          it->second.browser,
          [BrowserSplitPaneLayout webContentFrameForPaneFrame:frames[index].rectValue
                                                      flipped:hostView.isFlipped]);
    }
    if (keys[index] == activeKey) {
      [self showSplitFocusRingInHostView:hostView frame:frames[index].rectValue];
      showsFocusRing = YES;
    }
  }
  if (!showsFocusRing) {
    _splitFocusRing.hidden = YES;
  }
  [self reportSplitPaneTabIDs:paneTabIDs frames:frames];
}

// The pane bars follow every layout, including a live divider drag, so the
// delegate hears frames synchronously and only when they change.
- (void)reportSplitPaneTabIDs:(NSArray<NSString *> *)tabIDs
                       frames:(NSArray<NSValue *> *)frames {
  if ([_reportedSplitPaneTabIDs isEqualToArray:tabIDs] &&
      [_reportedSplitPaneFrames isEqualToArray:frames]) {
    return;
  }
  _reportedSplitPaneTabIDs = [tabIDs copy];
  _reportedSplitPaneFrames = [frames copy];
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:didLayoutSplitPanesWithTabIDs:frames:)]) {
    [delegate browserTabController:self didLayoutSplitPanesWithTabIDs:tabIDs frames:frames];
  }
}

// Dividers sit in the gaps above the pane views. They only resize when every
// pane of the split has a live engine, because the fractions name all panes.
- (void)layoutSplitDividersInHostView:(BrowserTabHostView *)hostView
                           paneFrames:(NSArray<NSValue *> *)paneFrames
                                 keys:(const std::vector<std::string> &)keys {
  if (keys.size() != _visibleLayoutTabIDs.count) {
    [self hideSplitDividersFromIndex:0];
    return;
  }
  NSArray<NSValue *> *frames =
      [BrowserSplitPaneLayout dividerFramesBetweenPaneFrames:paneFrames
                                                    vertical:_visibleLayoutVertical];
  if (_splitDividers == nil) {
    _splitDividers = [NSMutableArray array];
  }
  NSInteger topPaneIndex = -1;
  for (const auto &key : keys) {
    auto it = _tabRecords.find(key);
    NSView *paneView =
        it == _tabRecords.end() ? nil : BrowserViewForBrowser(it->second.browser);
    NSUInteger index = paneView == nil ? NSNotFound
                                       : [hostView.subviews indexOfObjectIdenticalTo:paneView];
    if (index != NSNotFound) {
      topPaneIndex = MAX(topPaneIndex, (NSInteger)index);
    }
  }
  __weak BrowserTabController *weakSelf = self;
  for (NSUInteger index = 0; index < frames.count; index++) {
    if (index >= _splitDividers.count) {
      BrowserSplitDividerView *divider =
          [[BrowserSplitDividerView alloc] initWithFrame:NSZeroRect];
      __weak BrowserSplitDividerView *weakDivider = divider;
      divider.onDrag = ^(NSPoint point) {
        [weakSelf dragSplitDividerAtIndex:weakDivider.index toPoint:point];
      };
      divider.onDragEnd = ^{
        [weakSelf finishSplitDividerDrag];
      };
      divider.onReset = ^{
        [weakSelf equalizeSplitPanesAroundDividerAtIndex:weakDivider.index];
      };
      [_splitDividers addObject:divider];
    }
    BrowserSplitDividerView *divider = _splitDividers[index];
    divider.index = (NSInteger)index;
    divider.isVerticalSplit = _visibleLayoutVertical;
    // Browser views created later are added above, so keep dividers on top.
    NSUInteger currentIndex = divider.superview == hostView
                                  ? [hostView.subviews indexOfObjectIdenticalTo:divider]
                                  : NSNotFound;
    if (currentIndex == NSNotFound || (NSInteger)currentIndex < topPaneIndex) {
      [hostView addSubview:divider positioned:NSWindowAbove relativeTo:nil];
    }
    if (!NSEqualRects(divider.frame, frames[index].rectValue)) {
      divider.frame = frames[index].rectValue;
    }
    divider.hidden = NO;
  }
  [self hideSplitDividersFromIndex:frames.count];
}

- (void)hideSplitDividersFromIndex:(NSUInteger)start {
  for (NSUInteger index = start; index < _splitDividers.count; index++) {
    _splitDividers[index].hidden = YES;
  }
}

// Live resize keeps the new sizes local until the drag ends, so the model and
// session store see one change per drag.
- (void)dragSplitDividerAtIndex:(NSInteger)index toPoint:(NSPoint)point {
  BrowserTabHostView *hostView = _hostView;
  if (hostView == nil || _visibleLayoutTabIDs.count < 2) {
    return;
  }
  NSArray<NSNumber *> *fractions =
      [BrowserSplitPaneLayout fractionsMovingDivider:index
                                             toPoint:point
                                            inBounds:hostView.bounds
                                               count:(NSInteger)_visibleLayoutTabIDs.count
                                            vertical:_visibleLayoutVertical
                                             flipped:hostView.isFlipped
                                           fractions:_visibleLayoutFractions ?: @[]];
  if (fractions == nil || [fractions isEqualToArray:_visibleLayoutFractions]) {
    return;
  }
  _visibleLayoutFractions = fractions;
  _splitDividerMoved = YES;
  [self layoutVisiblePanes:[self visiblePaneKeys]];
}

- (void)finishSplitDividerDrag {
  if (!_splitDividerMoved) {
    return;
  }
  _splitDividerMoved = NO;
  [self reportSplitPaneSizes];
}

// A double click makes the divider's two neighbors equal.
- (void)equalizeSplitPanesAroundDividerAtIndex:(NSInteger)index {
  NSArray<NSNumber *> *fractions = [BrowserSplitPaneLayout
      fractionsEqualizingNeighborsOfDivider:index
                                      count:(NSInteger)_visibleLayoutTabIDs.count
                                  fractions:_visibleLayoutFractions ?: @[]];
  if (fractions == nil) {
    return;
  }
  _visibleLayoutFractions = fractions;
  [self layoutVisiblePanes:[self visiblePaneKeys]];
  [self reportSplitPaneSizes];
}

- (void)reportSplitPaneSizes {
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if (_visibleLayoutTabIDs.count < 2 || _visibleLayoutFractions.count != _visibleLayoutTabIDs.count ||
      ![delegate respondsToSelector:@selector(browserTabController:didResizeSplitWithTabIDs:fractions:)]) {
    return;
  }
  [delegate browserTabController:self
        didResizeSplitWithTabIDs:_visibleLayoutTabIDs
                       fractions:_visibleLayoutFractions];
}

- (void)showSplitFocusRingInHostView:(BrowserTabHostView *)hostView
                               frame:(NSRect)frame {
  if (_splitFocusRing == nil) {
    _splitFocusRing = [[BrowserSplitFocusRingView alloc] initWithFrame:frame];
  }
  // Browser views created later are added above it, so keep it on top.
  if (_splitFocusRing.superview != hostView ||
      hostView.subviews.lastObject != _splitFocusRing) {
    [hostView addSubview:_splitFocusRing
              positioned:NSWindowAbove
              relativeTo:nil];
  }
  if (!NSEqualRects(_splitFocusRing.frame, frame)) {
    _splitFocusRing.frame = frame;
  }
  _splitFocusRing.hidden = NO;
}

- (void)handleFocusForTabID:(NSString *)tabID {
  if (tabID == nil || [_activeTabID isEqualToString:tabID] ||
      ![self isVisiblePaneTabID:tabID]) {
    return;
  }
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:
                                                 didFocusTabWithID:)]) {
    [delegate browserTabController:self didFocusTabWithID:tabID];
  }
}

- (void)deselectActiveTab {
  _activeTabID = nil;
  [self updateBrowserVisibility];
}

- (BOOL)navigateTabWithID:(NSString *)tabID toURLString:(NSString *)urlString {
  if (tabID.length == 0 || urlString.length == 0) {
    return NO;
  }

  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || it->second.isClosing) {
    return NO;
  }

  it->second.latestURL = ToStdString(urlString);
  it->second.navigationPending = true;
  [self scheduleNavigationForTabID:tabID];
  return YES;
}

- (void)navigateActiveTabToURLString:(NSString *)urlString {
  if (_activeTabID != nil) {
    [self navigateTabWithID:_activeTabID toURLString:urlString];
  }
}

- (void)scheduleNavigationForTabID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || it->second.isClosing ||
      it->second.creationState != BrowserTabEngineCreationStateReady ||
      !it->second.initialNavigationEnabled ||
      !it->second.browser || !it->second.navigationPending ||
      it->second.navigationDrainScheduled) {
    return;
  }

  it->second.navigationDrainScheduled = true;
  if (!CefPostTask(TID_UI, new BrowserTabNavigationTask(self, it->first))) {
    it->second.navigationDrainScheduled = false;
  }
}

- (void)drainNavigationForTabID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end()) {
    return;
  }
  it->second.navigationDrainScheduled = false;
  if (it->second.isClosing || !it->second.navigationPending ||
      !it->second.initialNavigationEnabled ||
      it->second.creationState != BrowserTabEngineCreationStateReady ||
      !it->second.browser) {
    return;
  }

  const std::string target = it->second.latestURL;
  it->second.navigationPending = false;
  it->second.hasIssuedNavigation = true;
  NavigateBrowserOnUI(it->second.browser, target);
}

- (BOOL)shouldBlockNavigationFocusForTabID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  return it == _tabRecords.end() || it->second.isClosing ||
         ![_activeTabID isEqualToString:tabID];
}

- (void)visitNavigationEntriesForActiveTab:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *,
                                                     NSInteger))completion {
  auto it = _tabRecords.find(ToStdString(_activeTabID));
  if (it == _tabRecords.end() || !it->second.browser) {
    completion(@[], 0);
    return;
  }
  CefRefPtr<CefNavigationEntryVisitor> visitor = new BrowserNavigationEntryCollector(completion);
  it->second.browser->GetHost()->GetNavigationEntries(visitor, false);
}

- (void)setMediaVolume:(double)volume forTabWithID:(NSString *)tabID {
  if (_mediaVolumes == nil) {
    _mediaVolumes = [NSMutableDictionary dictionary];
  }
  _mediaVolumes[tabID] = @(volume);
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || !it->second.browser) {
    return;
  }
  std::vector<CefString> identifiers;
  it->second.browser->GetFrameIdentifiers(identifiers);
  const std::string script = BrowserMediaVolumeScript(volume);
  for (const CefString &identifier : identifiers) {
    CefRefPtr<CefFrame> frame = it->second.browser->GetFrameByIdentifier(identifier);
    if (frame) {
      frame->ExecuteJavaScript(script, frame->GetURL(), 0);
    }
  }
}

- (void)applyMediaVolumeForTabID:(NSString *)tabID toFrame:(CefRefPtr<CefFrame>)frame {
  NSNumber *volume = _mediaVolumes[tabID];
  if (volume != nil && frame) {
    frame->ExecuteJavaScript(BrowserMediaVolumeScript(volume.doubleValue), frame->GetURL(), 0);
  }
}

- (void)handlePasswordFormInFrame:(CefRefPtr<CefFrame>)frame forTabID:(NSString *)tabID {
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:didFindPasswordFormInTabWithID:frameID:urlString:)]) {
    [delegate browserTabController:self
        didFindPasswordFormInTabWithID:tabID
                               frameID:ToNSString(frame->GetIdentifier().ToString())
                             urlString:ToNSString(frame->GetURL().ToString())];
  }
}

- (void)handlePasswordSubmittedInFrame:(CefRefPtr<CefFrame>)frame
                              username:(NSString *)username
                              password:(NSString *)password
                              forTabID:(NSString *)tabID {
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:didSubmitPasswordInTabWithID:urlString:username:password:)]) {
    [delegate browserTabController:self
        didSubmitPasswordInTabWithID:tabID
                           urlString:ToNSString(frame->GetURL().ToString())
                            username:username
                            password:password];
  }
}

- (void)handleAddressFormInFrame:(CefRefPtr<CefFrame>)frame forTabID:(NSString *)tabID {
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:didFindAddressFormInTabWithID:frameID:urlString:)]) {
    [delegate browserTabController:self
        didFindAddressFormInTabWithID:tabID
                              frameID:ToNSString(frame->GetIdentifier().ToString())
                            urlString:ToNSString(frame->GetURL().ToString())];
  }
}

- (void)handleCardFormInFrame:(CefRefPtr<CefFrame>)frame forTabID:(NSString *)tabID {
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:didFindCardFormInTabWithID:frameID:urlString:)]) {
    [delegate browserTabController:self
        didFindCardFormInTabWithID:tabID
                           frameID:ToNSString(frame->GetIdentifier().ToString())
                         urlString:ToNSString(frame->GetURL().ToString())];
  }
}

- (void)handleAddressSubmittedInFrame:(CefRefPtr<CefFrame>)frame
                                 json:(NSString *)json
                             forTabID:(NSString *)tabID {
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:didSubmitAddressInTabWithID:urlString:json:)]) {
    [delegate browserTabController:self
        didSubmitAddressInTabWithID:tabID
                          urlString:ToNSString(frame->GetURL().ToString())
                               json:json];
  }
}

- (CefRefPtr<CefBrowser>)browserForCredentialTabID:(NSString *)tabID {
  if ([tabID hasPrefix:@"peek-"]) {
    BrowserPeekSession *session = _peekSessions[@([tabID substringFromIndex:5].intValue)];
    return session.closing ? nullptr : session->_browser;
  }
  auto it = _tabRecords.find(ToStdString(tabID));
  return it == _tabRecords.end() ? nullptr : it->second.browser;
}

- (void)fillAddressJSON:(NSString *)json
                frameID:(NSString *)frameID
              urlPrefix:(NSString *)urlPrefix
           forTabWithID:(NSString *)tabID {
  CefRefPtr<CefBrowser> browser = [self browserForCredentialTabID:tabID];
  CefRefPtr<CefFrame> frame = browser ? browser->GetFrameByIdentifier(ToStdString(frameID)) : nullptr;
  const std::string url = frame ? frame->GetURL().ToString() : std::string();
  const std::string prefix = ToStdString(urlPrefix);
  if (!frame || url.rfind(prefix, 0) != 0 ||
      (url.size() > prefix.size() && url[prefix.size()] != '/' && url[prefix.size()] != ':')) {
    return;
  }
  CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(shared::kAddressFillMessage);
  message->GetArgumentList()->SetString(0, ToStdString(json));
  frame->SendProcessMessage(PID_RENDERER, message);
}

- (void)fillPasswordWithUsername:(NSString *)username
                        password:(NSString *)password
                         frameID:(NSString *)frameID
                       urlPrefix:(NSString *)urlPrefix
                    forTabWithID:(NSString *)tabID {
  CefRefPtr<CefBrowser> browser = [self browserForCredentialTabID:tabID];
  CefRefPtr<CefFrame> frame = browser ? browser->GetFrameByIdentifier(ToStdString(frameID)) : nullptr;
  // The frame may have gone somewhere else since the question: it gets nothing then.
  const std::string url = frame ? frame->GetURL().ToString() : std::string();
  const std::string prefix = ToStdString(urlPrefix);
  if (!frame || url.rfind(prefix, 0) != 0 ||
      (url.size() > prefix.size() && url[prefix.size()] != '/' && url[prefix.size()] != ':')) {
    return;
  }
  CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(shared::kPasswordFillMessage);
  message->GetArgumentList()->SetString(0, ToStdString(username));
  message->GetArgumentList()->SetString(1, ToStdString(password));
  frame->SendProcessMessage(PID_RENDERER, message);
}

- (void)goToHistoryOffsetInActiveTab:(NSInteger)offset {
  auto it = _tabRecords.find(ToStdString(_activeTabID));
  if (it == _tabRecords.end() || !it->second.closeRequestID.empty() || !it->second.browser) {
    return;
  }
  it->second.navigationPending = false;
  CefRefPtr<CefFrame> frame = it->second.browser->GetMainFrame();
  if (frame) {
    std::string script = "history.go(" + std::to_string(offset) + ");";
    frame->ExecuteJavaScript(script, frame->GetURL(), 0);
  }
}

- (void)fetchText:(NSString *)urlString
    firstPartyURLString:(NSString *)firstPartyURLString
            inTabWithID:(NSString *)tabID
             completion:(void (^)(NSString *))completion {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || !it->second.browser) {
    completion(nil);
    return;
  }
  CefRefPtr<CefRequest> request = CefRequest::Create();
  request->SetURL(ToStdString(urlString));
  request->SetMethod("GET");
  request->SetFirstPartyForCookies(ToStdString(firstPartyURLString));
  request->SetFlags(UR_FLAG_ALLOW_STORED_CREDENTIALS | UR_FLAG_SKIP_CACHE);
  CefRefPtr<BrowserTextRequestClient> client = new BrowserTextRequestClient(completion);
  client->Start(request, it->second.browser->GetHost()->GetRequestContext());
}

- (NSInteger)importCookies:(NSArray<NSDictionary<NSString *, id> *> *)cookies {
  CefRefPtr<CefCookieManager> manager = CefCookieManager::GetGlobalManager(nullptr);
  if (!_tabRecords.empty()) {
    for (const auto &entry : _tabRecords) {
      if (entry.second.browser) {
        manager = entry.second.browser->GetHost()->GetRequestContext()->GetCookieManager(nullptr);
        break;
      }
    }
  }
  if (!manager) {
    return 0;
  }
  NSInteger count = 0;
  for (NSDictionary<NSString *, id> *item in cookies) {
    CefCookie cookie;
    CefString(&cookie.name) = ToStdString(item[@"name"]);
    CefString(&cookie.value) = ToStdString(item[@"value"]);
    CefString(&cookie.domain) = ToStdString(item[@"host"]);
    CefString(&cookie.path) = ToStdString(item[@"path"]);
    cookie.secure = [item[@"secure"] boolValue] ? 1 : 0;
    cookie.httponly = [item[@"httpOnly"] boolValue] ? 1 : 0;
    cookie.has_expires = 1;
    cookie.expires.val = [item[@"expires"] longLongValue];
    switch ([item[@"sameSite"] integerValue]) {
      case 0:
        cookie.same_site = CEF_COOKIE_SAME_SITE_NO_RESTRICTION;
        break;
      case 1:
        cookie.same_site = CEF_COOKIE_SAME_SITE_LAX_MODE;
        break;
      case 2:
        cookie.same_site = CEF_COOKIE_SAME_SITE_STRICT_MODE;
        break;
      default:
        cookie.same_site = CEF_COOKIE_SAME_SITE_UNSPECIFIED;
        break;
    }
    if (manager->SetCookie(ToStdString(item[@"url"]), cookie, nullptr)) {
      count += 1;
    }
  }
  return count;
}

- (void)executeDevToolsMethod:(NSString *)method
                       params:(NSString *)paramsJSON
                  inTabWithID:(NSString *)tabID
                   completion:(void (^)(NSString *))completion {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || !it->second.browser) {
    completion(nil);
    return;
  }
  CefRefPtr<DevToolsMethodObserver> observer =
      new DevToolsMethodObserver(method.UTF8String, paramsJSON.UTF8String, completion);
  observer->Start(it->second.browser->GetHost());
}

- (BOOL)fillPasswordInMainFrameWithUsername:(NSString *)username
                                   password:(NSString *)password
                                  urlPrefix:(NSString *)urlPrefix
                               forTabWithID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  CefRefPtr<CefFrame> frame =
      it != _tabRecords.end() && it->second.browser ? it->second.browser->GetMainFrame() : nullptr;
  if (!frame) {
    return NO;
  }
  [self fillPasswordWithUsername:username
                        password:password
                         frameID:ToNSString(frame->GetIdentifier().ToString())
                       urlPrefix:urlPrefix
                    forTabWithID:tabID];
  return YES;
}

- (void)evaluateJavaScript:(NSString *)code
              inTabWithID:(NSString *)tabID
               completion:(void (^)(NSString *))completion {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || !it->second.browser) {
    completion(nil);
    return;
  }
  CefRefPtr<RuntimeEvaluateObserver> observer =
      new RuntimeEvaluateObserver(code.UTF8String, completion);
  observer->Start(it->second.browser->GetHost());
}

- (void)goBackActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end() || !it->second.closeRequestID.empty()) {
    return;
  }

  if (it->second.browser && it->second.browser->CanGoBack()) {
    it->second.navigationPending = false;
    GoBackBrowserOnUI(it->second.browser);
  }
}

- (void)goForwardActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end() || !it->second.closeRequestID.empty()) {
    return;
  }

  if (it->second.browser && it->second.browser->CanGoForward()) {
    it->second.navigationPending = false;
    GoForwardBrowserOnUI(it->second.browser);
  }
}

- (void)reloadActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end() || !it->second.closeRequestID.empty()) {
    return;
  }

  ReloadBrowserOnUI(it->second.browser, false);
}

- (void)reloadActiveTabIgnoringCache {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end() || !it->second.closeRequestID.empty()) {
    return;
  }

  ReloadBrowserOnUI(it->second.browser, true);
}

- (void)clearCacheAndReloadActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end() || !it->second.closeRequestID.empty()) {
    return;
  }

  CefRefPtr<CefRequestContext> requestContext = [self activeTabRequestContext];
  ClearHttpCacheAndReloadBrowserOnUI(it->second.browser, requestContext);
}

- (void)clearCookiesAndReloadActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end() || !it->second.closeRequestID.empty()) {
    return;
  }

  CefRefPtr<CefRequestContext> requestContext = [self activeTabRequestContext];
  ClearCookiesAndReloadBrowserOnUI(it->second.browser, requestContext);
}

- (void)stopLoadingActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  if (it->second.browser) {
    it->second.navigationPending = false;
    StopLoadingBrowserOnUI(it->second.browser);
  }
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

- (BOOL)sendActionToActivePage:(SEL)action {
  auto it = _tabRecords.find(ToStdString(_activeTabID));
  if (it == _tabRecords.end() || !it->second.browser) {
    return NO;
  }
  NSView *page = PageViewHandlingAction(BrowserViewForBrowser(it->second.browser), action);
  return page != nil && [NSApp sendAction:action to:page from:nil];
}

- (void)focusActivePage {
  auto it = _tabRecords.find(ToStdString(_activeTabID));
  if (it != _tabRecords.end() && it->second.browser) {
    it->second.browser->GetHost()->SetFocus(true);
  }
}

- (void)captureActiveTabRegionToPasteboard:(CGRect)fraction {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end() || !it->second.browser) {
    return;
  }

  CefRefPtr<CefBrowserHost> host = it->second.browser->GetHost();
  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
                          [](CefRefPtr<CefBrowserHost> host, CGRect fraction) {
                            CefRefPtr<RegionScreenshotObserver> observer =
                                new RegionScreenshotObserver(fraction);
                            observer->Start(host);
                          },
                          host, fraction)));
}

- (void)captureActiveTabPictureWithCompletion:(void (^)(NSData *))completion {
  auto it = _tabRecords.find(ToStdString(_activeTabID));
  if (it == _tabRecords.end() || !it->second.browser) {
    completion(nil);
    return;
  }
  CefRefPtr<RegionScreenshotObserver> observer =
      new RegionScreenshotObserver(CGRectMake(0, 0, 1, 1));
  observer->completion_ = [completion copy];
  observer->Start(it->second.browser->GetHost());
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

- (void)setPictureInPicture:(BOOL)active forTabWithID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || !it->second.closeRequestID.empty()) {
    return;
  }

  // A hidden page has no surface to show, and the request would never settle, so
  // the page stays visible under the next tab until it has moved to the window.
  const std::string tabKey = ToStdString(tabID);
  it->second.keptVisibleForPictureInPicture = active;
  __weak BrowserTabController *weakSelf = self;
  __block BOOL finished = NO;
  void (^done)(void) = ^{
    if (finished) {
      return;
    }
    finished = YES;
    [weakSelf finishPictureInPictureAttemptForTabKey:tabKey];
  };
  CefRefPtr<CefBrowser> browser = it->second.browser;
  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(^(CefRefPtr<CefBrowser> target) {
    SetPictureInPicture(target, active, done);
  }, browser)));
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), done);
}

- (void)togglePictureInPictureInActiveTab {
  auto it = _tabRecords.find(ToStdString(_activeTabID));
  if (it != _tabRecords.end() && it->second.browser) {
    EvaluateInPage(it->second.browser, kTogglePictureInPictureScript, true);
  }
}

- (void)finishPictureInPictureAttemptForTabKey:(const std::string &)tabKey {
  auto it = _tabRecords.find(tabKey);
  if (it == _tabRecords.end() || !it->second.keptVisibleForPictureInPicture) {
    return;
  }
  it->second.keptVisibleForPictureInPicture = false;
  [self updateBrowserVisibilityFocusingActiveTab:NO];
}

- (void)showPeekWithURLString:(NSString *)urlString {
  [self presentPeekWithURLString:urlString standalone:NO];
}

- (void)showLittleWindowWithURLString:(NSString *)urlString {
  [self presentPeekWithURLString:urlString standalone:YES];
}

- (void)showNewLittleWindow {
  [self presentPeekWithURLString:@"about:blank" standalone:YES];
  [_peekSessions[@(_nextPeekSessionID)].panel focusAddressField];
}

/// Closes small windows that have not been in front for the chosen time.
- (void)startSmallWindowSweep {
  if (_smallWindowSweepTimer != nil) {
    return;
  }
  __weak BrowserTabController *weakSelf = self;
  _smallWindowSweepTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                            repeats:YES
                                                              block:^(NSTimer *) {
                                                                [weakSelf sweepSmallWindows];
                                                              }];
}

- (void)sweepSmallWindows {
  const NSTimeInterval lifetime = BrowserPeekSettings.smallWindowLifetime;
  NSDate *now = NSDate.date;
  for (NSNumber *sessionID in _peekSessions.allKeys) {
    BrowserPeekSession *session = _peekSessions[sessionID];
    if (!session.standalone || session.closing) {
      continue;
    }
    if (session.panel.isKeyWindow) {
      session.lastUsed = now;
    } else if (lifetime > 0 && [now timeIntervalSinceDate:session.lastUsed] >= lifetime) {
      [self closePeekSession:sessionID.intValue];
    }
  }
}

- (void)navigatePeekSession:(int)sessionID toURLString:(NSString *)urlString {
  BrowserPeekSession *session = _peekSessions[@(sessionID)];
  if (session == nil || session.closing || urlString.length == 0) {
    return;
  }
  session.urlString = urlString;
  [self reportPeekPages];
  [session.panel updateWithURLString:urlString];
  if (session->_browser && session->_browser->GetMainFrame()) {
    session->_browser->GetMainFrame()->LoadURL(ToStdString(urlString));
  }
}

- (BOOL)shouldPeekNavigationFromTabID:(NSString *)tabID toURLString:(NSString *)urlString {
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if (_hostView.window == nil ||
      ![delegate respondsToSelector:@selector(browserTabController:shouldPeekNavigationFromTabWithID:toURLString:)]) {
    return NO;
  }
  return [delegate browserTabController:self shouldPeekNavigationFromTabWithID:tabID toURLString:urlString];
}

/// A window has one Peek card; each link from another app gets its own
/// small window.
- (void)presentPeekWithURLString:(NSString *)urlString standalone:(BOOL)standalone {
  NSString *resolved = urlString.length > 0 ? [urlString copy] : @"about:blank";
  NSWindow *window = _hostView.window;
  if (!standalone) {
    if (window == nil) {
      [self createTabWithURLString:resolved makeActive:YES];
      return;
    }
    BrowserPeekSession *card = _peekSessions[@(_peekCardSessionID)];
    if (card != nil && !card.closing && card->_browser && card->_browser->GetMainFrame()) {
      // Another Shift-click replaces the page in the open card.
      card.urlString = resolved;
      [card.panel updateWithURLString:resolved];
      card->_browser->GetMainFrame()->LoadURL(ToStdString(resolved));
      return;
    }
    if (card != nil) {
      [self closePeekSession:_peekCardSessionID];
    }
  }

  if (_peekSessions == nil) {
    _peekSessions = [NSMutableDictionary dictionary];
  }
  const int sessionID = ++_nextPeekSessionID;
  BrowserPeekSession *session = [[BrowserPeekSession alloc] init];
  session.urlString = resolved;
  session.initialURLString = resolved;
  session.standalone = standalone;
  session.lastUsed = NSDate.date;
  session.ownerTabID = standalone ? nil : _activeTabID;
  session.panel = standalone ? [BrowserPeekPanel presentStandalone] : [BrowserPeekPanel presentOverWindow:window page:_hostView];
  [session.panel updateWithURLString:resolved];
  _peekSessions[@(sessionID)] = session;
  if (!standalone) {
    _peekCardSessionID = sessionID;
    [self reportPeekPages];
  } else {
    [self startSmallWindowSweep];
  }
  __weak BrowserTabController *weakSelf = self;
  session.panel.onClose = ^{
    [weakSelf closePeekSessionByUser:sessionID];
  };
  session.panel.onNavigate = ^(NSString *target) {
    [weakSelf navigatePeekSession:sessionID toURLString:target];
  };
  session.panel.spacesProvider = ^NSArray<BrowserPeekSpace *> * {
    BrowserTabController *strongSelf = weakSelf;
    id<BrowserTabControllerDelegate> delegate = strongSelf.delegate;
    if (![delegate respondsToSelector:@selector(peekSpacesForBrowserTabController:)]) {
      return @[];
    }
    return [delegate peekSpacesForBrowserTabController:strongSelf];
  };
  session.panel.onOpenInSplitView = ^{
    BrowserTabController *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    id<BrowserTabControllerDelegate> delegate = strongSelf.delegate;
    NSString *current = strongSelf->_peekSessions[@(sessionID)].urlString;
    if (current.length == 0 || [current isEqualToString:@"about:blank"] ||
        ![delegate respondsToSelector:@selector(browserTabController:openPeekURLStringInSplitView:)]) {
      return;
    }
    [strongSelf closePeekSession:sessionID];
    [delegate browserTabController:strongSelf openPeekURLStringInSplitView:current];
  };
  session.panel.onOpenInSpace = ^(NSString *spaceID) {
    BrowserTabController *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    id<BrowserTabControllerDelegate> delegate = strongSelf.delegate;
    NSString *current = strongSelf->_peekSessions[@(sessionID)].urlString;
    if (current.length == 0 || [current isEqualToString:@"about:blank"] ||
        ![delegate respondsToSelector:@selector(browserTabController:openPeekURLString:inSpaceWithID:)]) {
      return;
    }
    [strongSelf closePeekSession:sessionID];
    [delegate browserTabController:strongSelf openPeekURLString:current inSpaceWithID:spaceID];
  };
  session.panel.onFocusPage = ^{
    BrowserTabController *strongSelf = weakSelf;
    BrowserPeekSession *focused = strongSelf != nil ? strongSelf->_peekSessions[@(sessionID)] : nil;
    if (focused != nil && focused->_browser) {
      focused->_browser->GetHost()->SetFocus(true);
    }
  };
  session.panel.onOpenInTab = ^{
    BrowserTabController *strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    NSString *current = strongSelf->_peekSessions[@(sessionID)].urlString;
    [strongSelf closePeekSession:sessionID];
    // An empty small window has nothing to keep.
    if (current.length > 0 && ![current isEqualToString:@"about:blank"]) {
      [strongSelf createTabWithURLString:current makeActive:YES];
    }
  };

  NSView *hostView = session.panel.hostView;
  CefWindowInfo windowInfo;
  windowInfo.SetAsChild((__bridge CefWindowHandle)hostView, CefRectFromBounds(hostView.bounds));
  if (shared::IsAlloyStyleEnabled()) {
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  }
  const bool accepted = CefBrowserHost::CreateBrowser(
      windowInfo, new BrowserPeekClient(self, sessionID), ToStdString(resolved), CefBrowserSettings(), nullptr,
      [self activeTabRequestContext]);
  if (!accepted) {
    [session.panel dismiss];
    [_peekSessions removeObjectForKey:@(sessionID)];
    if (_peekCardSessionID == sessionID) {
      _peekCardSessionID = 0;
    }
    [self createTabWithURLString:resolved makeActive:YES];
  }
}

/// Hides the card or window at once and closes its page without a
/// beforeunload prompt; a page still being created closes when it arrives.
/// The session, and with it the panel, goes away in OnBeforeClose.
- (void)closePeekSession:(int)sessionID {
  BrowserPeekSession *session = _peekSessions[@(sessionID)];
  if (session == nil || session.closing) {
    return;
  }
  session.closing = YES;
  if (_peekCardSessionID == sessionID) {
    _peekCardSessionID = 0;
  }
  [self reportPeekPages];
  // The page stays in the card until the card has closed around it.
  __weak BrowserTabController *weakSelf = self;
  [session.panel dismissWithCompletion:^{
    [weakSelf closePeekBrowserForSession:session];
  }];
}

- (void)closePeekBrowserForSession:(BrowserPeekSession *)session {
  if (session->_browser) {
    session->_browser->GetHost()->CloseBrowser(true);
  }
}

/// Close, Escape, Command-W or a click behind: the window can reopen it.
- (void)closePeekSessionByUser:(int)sessionID {
  BrowserPeekSession *session = _peekSessions[@(sessionID)];
  if (session == nil || session.closing) {
    return;
  }
  NSString *urlString = session.urlString;
  const BOOL standalone = session.panel.isStandalone;
  [self closePeekSession:sessionID];
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:didClosePeekWithURLString:standalone:)]) {
    [delegate browserTabController:self didClosePeekWithURLString:urlString standalone:standalone];
  }
}

/// Everything is going away, so nothing waits for an animation.
- (void)closeAllPeeks {
  for (NSNumber *sessionID in _peekSessions.allKeys) {
    BrowserPeekSession *session = _peekSessions[sessionID];
    if (session == nil || session.closing) {
      continue;
    }
    session.closing = YES;
    [session.panel dismiss];
    if (_peekCardSessionID == sessionID.intValue) {
      _peekCardSessionID = 0;
    }
    [self closePeekBrowserForSession:session];
  }
}

- (void)handlePeekCreated:(CefRefPtr<CefBrowser>)browser session:(int)sessionID {
  BrowserPeekSession *session = _peekSessions[@(sessionID)];
  if (session == nil || session.closing) {
    browser->GetHost()->CloseBrowser(true);
    return;
  }
  session->_browser = browser;
  // The small window resizes; the page follows its host view.
  NSView *browserView = BrowserViewForBrowser(browser);
  browserView.frame = session.panel.hostView.bounds;
  browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (![session.urlString isEqualToString:session.initialURLString] && browser->GetMainFrame()) {
    browser->GetMainFrame()->LoadURL(ToStdString(session.urlString));
  }
}

/// Also reached when the page closes itself or its renderer is gone.
- (void)handlePeekClosed:(CefRefPtr<CefBrowser>)browser session:(int)sessionID {
  BrowserPeekSession *session = _peekSessions[@(sessionID)];
  if (session == nil) {
    return;
  }
  [self cancelSitePermissionsForTabID:PeekSitePermissionTabID(sessionID)];
  [session.panel dismiss];
  session->_browser = nullptr;
  [_peekSessions removeObjectForKey:@(sessionID)];
  if (_peekCardSessionID == sessionID) {
    _peekCardSessionID = 0;
  }
  [self reportPeekPages];
}

- (BrowserPeekPanel *)peekPanelForSessionID:(NSInteger)sessionID {
  BrowserPeekSession *session = _peekSessions[@(sessionID)];
  return session.closing ? nil : session.panel;
}

- (BOOL)isPeekSessionStandalone:(int)sessionID {
  return _peekSessions[@(sessionID)].panel.isStandalone;
}

- (BOOL)isPeekSessionEditingAddress:(int)sessionID {
  return _peekSessions[@(sessionID)].panel.isEditingAddress;
}

- (void)handlePeekAddressChange:(NSString *)urlString session:(int)sessionID {
  BrowserPeekSession *session = _peekSessions[@(sessionID)];
  if (session == nil || session.closing || urlString.length == 0) {
    return;
  }
  session.urlString = urlString;
  [self reportPeekPages];
  [session.panel updateWithURLString:urlString];
}

- (void)showDevToolsForActiveTab {
  auto it = _tabRecords.find(ToStdString(_activeTabID));
  if (it == _tabRecords.end() || !it->second.closeRequestID.empty()) {
    return;
  }

  ShowBrowserDevToolsOnUI(it->second.browser);
}

/// The next page's data store: its Space's profile, or the window's own.
- (CefRefPtr<CefRequestContext>)requestContextForNewTab {
  if (self.profileCachePathForNewTabs.length == 0) {
    return _requestContext;
  }
  const std::string path = ToStdString(self.profileCachePathForNewTabs);
  auto found = _spaceProfileContexts.find(path);
  if (found != _spaceProfileContexts.end()) {
    return found->second;
  }
  CefRequestContextSettings settings;
  CefString(&settings.cache_path) = path;
  CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(settings, nullptr);
  _spaceProfileContexts[path] = context;
  return context;
}

- (void)inspectElementsInActiveTab {
  auto it = _tabRecords.find(ToStdString(_activeTabID));
  if (it == _tabRecords.end() || !it->second.closeRequestID.empty()) {
    return;
  }
  CefRefPtr<CefBrowser> browser = it->second.browser;
  ShowBrowserDevToolsOnUI(browser);
  CefRefPtr<CefBrowserHost> host = browser ? browser->GetHost() : nullptr;
  if (!host) {
    return;
  }
  // Turns on the picker that the Elements panel's own button starts.
  host->ExecuteDevToolsMethod(0, "DOM.enable", nullptr);
  host->ExecuteDevToolsMethod(0, "Overlay.enable", nullptr);
  CefRefPtr<CefDictionaryValue> highlight = CefDictionaryValue::Create();
  highlight->SetBool("showInfo", true);
  CefRefPtr<CefDictionaryValue> content = CefDictionaryValue::Create();
  content->SetInt("r", 111);
  content->SetInt("g", 168);
  content->SetInt("b", 220);
  content->SetDouble("a", 0.66);
  highlight->SetDictionary("contentColor", content);
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("mode", "searchForNode");
  params->SetDictionary("highlightConfig", highlight);
  host->ExecuteDevToolsMethod(0, "Overlay.setInspectMode", params);
}

- (void)showJavaScriptConsoleForActiveTab {
  [self showDevToolsForActiveTabOnPanel:"\"console\""];
}

- (void)showNetworkInspectorForActiveTab {
  [self showDevToolsForActiveTabOnPanel:"\"network\""];
}

- (void)showDevToolsForActiveTabOnPanel:(const char*)panel {
  auto it = _tabRecords.find(ToStdString(_activeTabID));
  if (it == _tabRecords.end() || !it->second.closeRequestID.empty()) {
    return;
  }
  CefRefPtr<CefBrowser> browser = it->second.browser;
  CefRefPtr<CefBrowserHost> host = browser ? browser->GetHost() : nullptr;
  if (!host) {
    return;
  }
  // Developer Tools open on the panel saved in this preference.
  CefRefPtr<CefRequestContext> context = host->GetRequestContext();
  if (context) {
    CefRefPtr<CefDictionaryValue> preferences = CefDictionaryValue::Create();
    preferences->SetString("panel-selected-tab", panel);
    CefRefPtr<CefValue> value = CefValue::Create();
    value->SetDictionary(preferences);
    CefString error;
    context->SetPreference("devtools.preferences", value, error);
  }
  ShowBrowserDevToolsOnUI(browser);
}

- (void)castActiveTab {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  CastBrowserOnUI(it->second.browser);
}

- (void)requestActiveTabWebAppManifestWithCompletion:
    (void (^)(NSString *payloadJSON))completion {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end() || !it->second.browser) {
    completion(nil);
    return;
  }

  CefRefPtr<CefBrowserHost> host = it->second.browser->GetHost();
  CefRefPtr<RuntimeEvaluateObserver> observer =
      new RuntimeEvaluateObserver(kWebAppManifestExpression, completion);
  observer->Start(host);
}

- (void)requestActiveTabSelectedTextWithCompletion:(void (^)(NSString *))completion {
  auto it = _tabRecords.find(ToStdString(_activeTabID));
  if (it == _tabRecords.end() || !it->second.browser) {
    completion(nil);
    return;
  }
  CefRefPtr<RuntimeEvaluateObserver> observer =
      new RuntimeEvaluateObserver(kSelectedTextExpression, completion);
  observer->Start(it->second.browser->GetHost());
}

/// Combines the frames' reports: the tab plays when a frame does and is
/// paused when one can resume. The controls reach the frame with sound, else
/// a playing one, else the frame that last had sound, else any.
- (void)handleMediaState:(const MediaFrameState &)state
                 frameID:(const std::string &)frameID
                forTabID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end()) {
    return;
  }
  TabRecord &record = it->second;
  if (state.playing || state.paused) {
    record.mediaFrames[frameID] = state;
  } else {
    record.mediaFrames.erase(frameID);
  }
  if (state.audible && state.playing) {
    record.lastAudibleMediaFrameID = frameID;
  }
  [self combineMediaForTabID:tabID record:record];
}

- (void)forgetMediaFrame:(const std::string &)frameID forTabID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || it->second.mediaFrames.erase(frameID) == 0) {
    return;
  }
  [self combineMediaForTabID:tabID record:it->second];
}

- (void)combineMediaForTabID:(NSString *)tabID record:(TabRecord &)record {
  // Frames that are gone without a word, such as crashed embeds, drop out.
  if (record.browser) {
    for (auto entry = record.mediaFrames.begin(); entry != record.mediaFrames.end();) {
      CefRefPtr<CefFrame> frame = record.browser->GetFrameByIdentifier(entry->first);
      entry = frame && frame->IsValid() ? std::next(entry) : record.mediaFrames.erase(entry);
    }
  }
  auto rank = [&record](const std::string &id, const MediaFrameState &state) {
    return state.audible && state.playing ? 3 : state.playing ? 2 : id == record.lastAudibleMediaFrameID ? 1 : 0;
  };
  MediaFrameState combined;
  int best = -1;
  record.mediaControlFrameID.clear();
  for (const auto &entry : record.mediaFrames) {
    const int score = rank(entry.first, entry.second);
    if (score > best) {
      best = score;
      record.mediaControlFrameID = entry.first;
      combined.hasPreviousTrack = entry.second.hasPreviousTrack;
      combined.hasNextTrack = entry.second.hasNextTrack;
      combined.title = entry.second.title;
    }
    combined.audible = combined.audible || entry.second.audible;
    combined.playing = combined.playing || entry.second.playing;
    combined.video = combined.video || entry.second.video;
    combined.pictureInPicture = combined.pictureInPicture || entry.second.pictureInPicture;
  }
  combined.paused = !combined.playing && !record.mediaFrames.empty();
  [self reportMedia:combined forTabID:tabID record:record];
}

- (void)resetMediaForTabID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end()) {
    return;
  }
  it->second.mediaFrames.clear();
  it->second.mediaControlFrameID.clear();
  it->second.lastAudibleMediaFrameID.clear();
  [self reportMedia:MediaFrameState() forTabID:tabID record:it->second];
}

- (void)reportMedia:(const MediaFrameState &)state forTabID:(NSString *)tabID record:(TabRecord &)record {
  if (state == record.reportedMedia) {
    return;
  }
  record.reportedMedia = state;
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  SEL selector = @selector(browserTabController:
                     didChangeMediaStateForTabWithID:audible:playing:paused:video:hasPreviousTrack:hasNextTrack:pictureInPicture:title:);
  if ([delegate respondsToSelector:selector]) {
    [delegate browserTabController:self
        didChangeMediaStateForTabWithID:tabID
                                audible:state.audible
                                playing:state.playing
                                 paused:state.paused
                                  video:state.video
                       hasPreviousTrack:state.hasPreviousTrack
                           hasNextTrack:state.hasNextTrack
                       pictureInPicture:state.pictureInPicture
                                  title:ToNSString(state.title)];
  }
}

- (void)handleRenderProcessTerminatedForTabID:(NSString *)tabID errorCode:(int)errorCode {
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:renderProcessTerminatedForTabWithID:errorCode:)]) {
    [delegate browserTabController:self renderProcessTerminatedForTabWithID:tabID errorCode:errorCode];
  }
}

- (void)controlMediaInTabWithID:(NSString *)tabID action:(NSString *)action {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || !it->second.browser || it->second.mediaControlFrameID.empty() ||
      !CefCurrentlyOn(TID_UI)) {
    return;
  }
  CefRefPtr<CefFrame> frame = it->second.browser->GetFrameByIdentifier(it->second.mediaControlFrameID);
  if (!frame) {
    return;
  }
  CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(shared::kMediaControlMessage);
  message->GetArgumentList()->SetString(0, ToStdString(action));
  frame->SendProcessMessage(PID_RENDERER, message);
}

- (void)setAudioMuted:(BOOL)muted forTabWithID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end()) {
    return;
  }

  it->second.audioMuted = muted;
  SetBrowserAudioMutedOnUI(it->second.browser, muted);
}

- (void)requestSitePermissionForTabID:(NSString *)tabID
                               origin:(NSString *)origin
                                kinds:(NSArray<NSString *> *)kinds
                              pending:(PendingSitePermission)pending {
  const int requestID = ++_nextSitePermissionID;
  const BOOL mediaAccess = pending.mediaCallback != nullptr;
  pending.tabID = ToStdString(tabID);
  _sitePermissions[requestID] = pending;
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  SEL selector = @selector(browserTabController:didRequestSitePermission:forTabWithID:origin:kinds:mediaAccess:);
  if (![delegate respondsToSelector:selector]) {
    [self resolveSitePermissionRequest:requestID allowed:nil];
    return;
  }
  [delegate browserTabController:self
        didRequestSitePermission:requestID
                    forTabWithID:tabID
                          origin:origin
                           kinds:kinds
                     mediaAccess:mediaAccess];
}

- (void)resolveSitePermissionRequest:(NSInteger)requestID allowed:(NSNumber *)allowed {
  auto it = _sitePermissions.find(static_cast<int>(requestID));
  if (it == _sitePermissions.end()) {
    return;
  }
  PendingSitePermission pending = it->second;
  _sitePermissions.erase(it);
  if (pending.mediaCallback) {
    // getUserMedia takes the devices it asked for or nothing.
    if (allowed.boolValue) {
      pending.mediaCallback->Continue(pending.mediaPermissions);
    } else {
      pending.mediaCallback->Cancel();
    }
  } else if (pending.promptCallback) {
    ContinuePermissionRequestOnUI(pending.promptCallback,
                                  allowed == nil      ? CEF_PERMISSION_RESULT_IGNORE
                                  : allowed.boolValue ? CEF_PERMISSION_RESULT_ACCEPT
                                                      : CEF_PERMISSION_RESULT_DENY);
  }
}

- (CefRefPtr<CefRequestContext>)siteSettingsContext {
  return [self activeTabRequestContext];
}

/// The data store of the page on screen, which its Space's profile decides.
- (CefRefPtr<CefRequestContext>)activeTabRequestContext {
  auto it = _tabRecords.find(ToStdString(_activeTabID));
  if (it != _tabRecords.end() && it->second.requestContext) {
    return it->second.requestContext;
  }
  return _requestContext ? _requestContext : CefRequestContext::GetGlobalContext();
}

- (NSDictionary<NSString *, NSString *> *)siteSettingsForURLString:(NSString *)urlString {
  CefRefPtr<CefRequestContext> context = [self siteSettingsContext];
  if (!context || !CefCurrentlyOn(TID_UI) || urlString.length == 0) {
    return @{};
  }
  const std::string url = ToStdString(urlString);
  NSMutableDictionary<NSString *, NSString *> *settings = [NSMutableDictionary dictionary];
  for (const auto &entry : SiteSettingTypes()) {
    const cef_content_setting_values_t value = context->GetContentSetting(url, url, entry.second);
    const cef_content_setting_values_t fallback = context->GetContentSetting(CefString(), CefString(), entry.second);
    NSString *name = SiteSettingValueName(value);
    if (value != fallback && name != nil) {
      settings[entry.first] = name;
    }
  }
  return settings;
}

- (void)setSiteSetting:(NSString *)kind value:(NSString *)value forURLString:(NSString *)urlString {
  CefRefPtr<CefRequestContext> context = [self siteSettingsContext];
  if (!context || !CefCurrentlyOn(TID_UI) || urlString.length == 0) {
    return;
  }
  for (const auto &entry : SiteSettingTypes()) {
    if ([entry.first isEqualToString:kind]) {
      const std::string url = ToStdString(urlString);
      // The profile default's own value is stored as the default, so the site
      // follows later changes to it instead of keeping a hidden copy.
      cef_content_setting_values_t setting = SiteSettingValue(value);
      if (setting == context->GetContentSetting(CefString(), CefString(), entry.second)) {
        setting = CEF_CONTENT_SETTING_VALUE_DEFAULT;
      }
      context->SetContentSetting(url, url, entry.second, setting);
      return;
    }
  }
}

- (void)dismissSitePermissionPromptWithID:(uint64_t)promptID {
  for (auto it = _sitePermissions.begin(); it != _sitePermissions.end(); ++it) {
    if (it->second.promptCallback && it->second.promptID == promptID) {
      const NSInteger requestID = it->first;
      _sitePermissions.erase(it);
      [self notifySitePermissionDismissed:requestID];
      return;
    }
  }
}

/// A closing page withdraws its requests.
- (void)cancelSitePermissionsForTabID:(NSString *)tabID {
  [self cancelSitePermissionsForTabID:tabID mediaOnly:NO];
}

/// A new document or a crashed renderer leaves the old page's camera and
/// microphone requests without a page to answer. Chromium withdraws its own
/// prompts; same-document navigations keep both.
- (void)cancelMediaSitePermissionsForTabID:(NSString *)tabID {
  [self cancelSitePermissionsForTabID:tabID mediaOnly:YES];
}

- (void)cancelSitePermissionsForTabID:(NSString *)tabID mediaOnly:(BOOL)mediaOnly {
  const std::string tabKey = ToStdString(tabID);
  std::vector<int> requestIDs;
  for (const auto &entry : _sitePermissions) {
    if (entry.second.tabID == tabKey && (!mediaOnly || entry.second.mediaCallback)) {
      requestIDs.push_back(entry.first);
    }
  }
  for (int requestID : requestIDs) {
    [self resolveSitePermissionRequest:requestID allowed:nil];
    [self notifySitePermissionDismissed:requestID];
  }
}

- (void)notifySitePermissionDismissed:(NSInteger)requestID {
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:didDismissSitePermissionRequest:)]) {
    [delegate browserTabController:self didDismissSitePermissionRequest:requestID];
  }
}

- (double)zoomLevelForTabWithID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || !it->second.browser || !CefCurrentlyOn(TID_UI)) {
    return NAN;
  }

  CefRefPtr<CefBrowserHost> host = it->second.browser->GetHost();
  return host ? host->GetZoomLevel() : NAN;
}

- (void)setActiveTabZoomLevel:(double)zoomLevel {
  std::string activeKey = ToStdString(_activeTabID);
  auto it = _tabRecords.find(activeKey);
  if (it == _tabRecords.end()) {
    return;
  }

  SetBrowserZoomLevelOnUI(it->second.browser, zoomLevel);
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

- (BOOL)requestCloseTabWithID:(NSString *)tabID requestID:(NSString *)requestID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (requestID.length == 0 || it == _tabRecords.end() ||
      it->second.isClosing || !it->second.closeRequestID.empty()) {
    return NO;
  }

  it->second.closeRequestID = ToStdString(requestID);
  it->second.isClosing = true;
  // Retain the latest pending navigation. Cancel must not drop an address
  // accepted before this close, including the initial deferred engine load.
  if (it->second.browser) {
    it->second.browser->GetHost()->CloseBrowser(false);
  } else {
    const BOOL wasActive = [_activeTabID isEqualToString:tabID];
    _tabRecords.erase(it);
    [self notifyCloseRequestForTabID:tabID requestID:requestID
                            outcome:BrowserTabCloseRequestOutcomeClosed];
    [self.delegate browserTabController:self didCloseTabWithID:tabID];
    [self updateBrowserVisibilityFocusingActiveTab:wasActive];
  }
  return YES;
}

- (void)notifyCloseRequestForTabID:(NSString *)tabID
                       requestID:(NSString *)requestID
                         outcome:(BrowserTabCloseRequestOutcome)outcome {
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if (requestID.length > 0 &&
      [delegate respondsToSelector:@selector(browserTabController:didFinishCloseRequestForTabWithID:requestID:outcome:)]) {
    [delegate browserTabController:self didFinishCloseRequestForTabWithID:tabID
                         requestID:requestID outcome:outcome];
  }
}

- (BOOL)handleBeforeUnloadForTabID:(NSString *)tabID
                         browser:(CefRefPtr<CefBrowser>)browser
                        callback:(CefRefPtr<CefJSDialogCallback>)callback {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || !it->second.browser ||
      !it->second.browser->IsSame(browser) || it->second.closeRequestID.empty()) {
    return NO;
  }
  // CEF admits one beforeunload continuation. Do not replace its owner.
  if (it->second.closeDialogCallback) {
    callback->Continue(false, CefString());
    return YES;
  }
  it->second.closeDialogCallback = callback;
  NSString *requestID = ToNSString(it->second.closeRequestID);
  __weak BrowserTabController *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    BrowserTabController *controller = weakSelf;
    if (!controller) return;
    auto current = controller->_tabRecords.find(ToStdString(tabID));
    if (current == controller->_tabRecords.end() ||
        current->second.closeRequestID != ToStdString(requestID) ||
        !current->second.closeDialogCallback || !current->second.browser ||
        !current->second.browser->IsSame(browser)) return;

    BrowserBeforeUnloadConfirmation *confirmation =
        [[BrowserBeforeUnloadConfirmation alloc]
            initWithWindow:controller->_hostView.window
                completion:^(BOOL confirmed) {
                  BrowserTabController *owner = weakSelf;
                  if (!owner) return;
                  CefPostTask(TID_UI, new BrowserTabCloseReplyTask(
                      owner, ToStdString(tabID), ToStdString(requestID),
                      browser, confirmed));
                }];
    current->second.closeConfirmation = confirmation;
    id<BrowserTabControllerDelegate> delegate = controller.delegate;
    if ([delegate respondsToSelector:@selector(browserTabController:willConfirmCloseForTabWithID:)]) {
      [delegate browserTabController:controller willConfirmCloseForTabWithID:tabID];
    }
    [confirmation present];
  });
  return YES;
}

- (void)finishCloseDialogForTabID:(NSString *)tabID
                      requestID:(NSString *)requestID
                        browser:(CefRefPtr<CefBrowser>)browser
                      confirmed:(BOOL)confirmed {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() ||
      it->second.closeRequestID != ToStdString(requestID) ||
      !it->second.browser || !it->second.browser->IsSame(browser) ||
      !it->second.closeDialogCallback) return;

  CefRefPtr<CefJSDialogCallback> callback = it->second.closeDialogCallback;
  BrowserBeforeUnloadConfirmation *confirmation = it->second.closeConfirmation;
  it->second.closeDialogCallback = nullptr;
  it->second.closeConfirmation = nil;
  // Continue can synchronously reset dialog state or close the browser. Clear
  // the continuation first and never retain an iterator across this call.
  callback->Continue(confirmed, CefString());
  [confirmation cancel];
  if (confirmed) return;  // Confirmation is not OnBeforeClose.

  auto current = _tabRecords.find(ToStdString(tabID));
  if (current == _tabRecords.end() ||
      current->second.closeRequestID != ToStdString(requestID)) return;
  current->second.closeRequestID.clear();
  current->second.isClosing = false;
  [self notifyCloseRequestForTabID:tabID requestID:requestID
                          outcome:BrowserTabCloseRequestOutcomeCancelled];
  [self scheduleNavigationForTabID:tabID];
}

/// A tab's window, or a Peek's own panel for its `peek-N` id.
- (NSWindow *)dialogWindowForTabID:(NSString *)tabID {
  if ([tabID hasPrefix:@"peek-"]) {
    BrowserPeekSession *session = _peekSessions[@([tabID substringFromIndex:5].intValue)];
    return session.closing ? nil : session.panel;
  }
  return _hostView.window;
}

- (void)presentPageDialogForTabID:(NSString *)tabID
                             kind:(NSInteger)kind
                           origin:(NSString *)origin
                          message:(NSString *)message
                      defaultText:(NSString *)defaultText
                         callback:(CefRefPtr<CefJSDialogCallback>)callback {
  if (_pageDialogs == nil) {
    _pageDialogs = [NSMutableDictionary dictionary];
  }
  if (_pageDialogs[tabID] != nil) {
    callback->Continue(false, CefString());
    return;
  }
  __weak BrowserTabController *weakSelf = self;
  BrowserJavaScriptDialog *dialog = [[BrowserJavaScriptDialog alloc]
      initWithWindow:[self dialogWindowForTabID:tabID]
                kind:kind
              origin:origin
             message:message
         defaultText:defaultText
          completion:^(BOOL accepted, NSString *text) {
            BrowserTabController *owner = weakSelf;
            if (owner) {
              [owner->_pageDialogs removeObjectForKey:tabID];
            }
            callback->Continue(accepted, ToStdString(text));
          }];
  _pageDialogs[tabID] = dialog;
  if ([self isDialogTabVisible:tabID]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [dialog present];
    });
  }
}

// A sheet covers the whole window, so a background page's dialog waits until
// its tab is on screen. The page itself stays blocked meanwhile, as in Chrome.
- (BOOL)isDialogTabVisible:(NSString *)tabID {
  return [tabID hasPrefix:@"peek-"] || [_activeTabID isEqualToString:tabID] ||
         [_visibleLayoutTabIDs containsObject:tabID];
}

- (void)presentWaitingDialogs {
  for (NSString *tabID in _pageDialogs.allKeys) {
    if ([self isDialogTabVisible:tabID] && [self dialogWindowForTabID:tabID].attachedSheet == nil) {
      [_pageDialogs[tabID] present];
    }
  }
  for (NSString *tabID in _authDialogs.allKeys) {
    if ([self isDialogTabVisible:tabID] && [self dialogWindowForTabID:tabID].attachedSheet == nil) {
      [_authDialogs[tabID] present];
    }
  }
}

- (void)cancelPageDialogForTabID:(NSString *)tabID {
  [_pageDialogs[tabID] cancel];
}

- (void)setWarmTabIDs:(NSArray<NSString *> *)tabIDs {
  NSSet<NSString *> *next = [NSSet setWithArray:tabIDs];
  if ([_warmTabIDs isEqualToSet:next]) {
    return;
  }
  _warmTabIDs = next;
  [self updateBrowserVisibilityFocusingActiveTab:NO];
}

- (void)reportExtensionTabsForWindowKey:(NSString *)windowKey
                                focused:(BOOL)focused
                                   tabs:(NSArray<NSDictionary<NSString *, id> *> *)tabs {
  NSMutableArray<NSDictionary<NSString *, id> *> *entries = [NSMutableArray array];
  for (NSDictionary<NSString *, id> *tab in tabs) {
    auto it = _tabRecords.find(ToStdString(tab[@"tabID"]));
    if (it == _tabRecords.end() || !it->second.browser) {
      continue;
    }
    [entries addObject:@{
      @"browserId" : @(it->second.browser->GetIdentifier()),
      @"index" : tab[@"index"],
      @"active" : tab[@"active"],
      @"pinned" : tab[@"pinned"],
    }];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:entries
                                                 options:NSJSONWritingSortedKeys
                                                   error:nil];
  NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  if (!json) {
    return;
  }
  if (_lastExtensionTabsFocused == focused && [_lastExtensionTabsJSON isEqualToString:json]) {
    return;
  }
  _lastExtensionTabsFocused = focused;
  _lastExtensionTabsJSON = json;
  BrowserSetExtensionTabs(windowKey, focused, json);
}

- (nullable NSString *)tabIDForBrowserIdentifier:(int)browserIdentifier {
  for (const auto &entry : _tabRecords) {
    if (entry.second.browser && entry.second.browser->GetIdentifier() == browserIdentifier) {
      return ToNSString(entry.first);
    }
  }
  return nil;
}

- (NSInteger)translateTabWithID:(NSString *)tabID toLanguage:(NSString *)language {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || !it->second.browser) {
    return 0;
  }
  return BrowserTranslatePage(it->second.browser->GetIdentifier(), language);
}

- (void)revertTranslationForTabWithID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it != _tabRecords.end() && it->second.browser) {
    BrowserRevertTranslation(it->second.browser->GetIdentifier());
  }
}

- (NSInteger)translationStateForTabWithID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || !it->second.browser) {
    return 0;
  }
  return BrowserTranslationState(it->second.browser->GetIdentifier());
}

- (NSDictionary<NSString *, NSNumber *> *)rendererProcessIDsByTabID {
  NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
  for (const auto &entry : _tabRecords) {
    if (entry.second.rendererProcessID > 0) {
      result[ToNSString(entry.first)] = @(entry.second.rendererProcessID);
    }
  }
  return result;
}

- (void)noteRendererProcessID:(int)processID forTabID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it != _tabRecords.end()) {
    it->second.rendererProcessID = processID;
  }
}

- (void)presentAuthDialogForTabID:(NSString *)tabID
                             host:(NSString *)host
                           origin:(NSString *)origin
                         callback:(CefRefPtr<CefAuthCallback>)callback {
  if (_authDialogs == nil) {
    _authDialogs = [NSMutableDictionary dictionary];
  }
  if (_authDialogs[tabID] != nil) {
    callback->Cancel();
    return;
  }
  __weak BrowserTabController *weakSelf = self;
  BrowserAuthDialog *dialog = [[BrowserAuthDialog alloc]
      initWithWindow:[self dialogWindowForTabID:tabID]
                host:host
              origin:origin
          completion:^(BOOL accepted, NSString *username, NSString *password) {
            BrowserTabController *owner = weakSelf;
            if (owner) {
              [owner->_authDialogs removeObjectForKey:tabID];
            }
            if (accepted) {
              callback->Continue(ToStdString(username), ToStdString(password));
            } else {
              callback->Cancel();
            }
          }];
  _authDialogs[tabID] = dialog;
  if ([self isDialogTabVisible:tabID]) {
    [dialog present];
  }
}

- (void)cancelDialogsForTabID:(NSString *)tabID {
  [_pageDialogs[tabID] cancel];
  [_authDialogs[tabID] cancel];
  [_screenSharePickers[tabID] cancel];
}

- (void)presentScreenSharePickerForTabID:(NSString *)tabID
                                  origin:(NSString *)origin
                                callback:(CefRefPtr<CefMediaAccessCallback>)callback {
  if (_screenSharePickers == nil) {
    _screenSharePickers = [NSMutableDictionary dictionary];
  }
  if (_screenSharePickers[tabID] != nil) {
    callback->Cancel();
    return;
  }
  __weak BrowserTabController *weakSelf = self;
  BrowserScreenSharePicker *picker = [[BrowserScreenSharePicker alloc]
      initWithWindow:[self dialogWindowForTabID:tabID]
              origin:origin
          completion:^(NSString *mediaID) {
            BrowserTabController *owner = weakSelf;
            if (owner) {
              [owner->_screenSharePickers removeObjectForKey:tabID];
            }
            if (mediaID) {
              BrowserSetNextDesktopMediaID(mediaID);
              callback->Continue(CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE);
            } else {
              callback->Cancel();
            }
          }];
  _screenSharePickers[tabID] = picker;
  [picker present];
}

- (void)resetCloseDialogForTabID:(NSString *)tabID browser:(CefRefPtr<CefBrowser>)browser {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() || !it->second.closeDialogCallback ||
      !it->second.browser || !it->second.browser->IsSame(browser)) return;
  [self finishCloseDialogForTabID:tabID
                       requestID:ToNSString(it->second.closeRequestID)
                         browser:browser confirmed:NO];
}

- (void)invalidateCloseRequestForTabID:(NSString *)tabID {
  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end()) return;
  CefRefPtr<CefJSDialogCallback> callback = it->second.closeDialogCallback;
  BrowserBeforeUnloadConfirmation *confirmation = it->second.closeConfirmation;
  it->second.closeRequestID.clear();
  it->second.closeDialogCallback = nullptr;
  it->second.closeConfirmation = nil;
  // Structural/forced closure supersedes the manual request. Late UI replies
  // carry its old nonce and cannot create a manual-close outcome.
  [confirmation cancel];
  if (callback) callback->Continue(true, CefString());
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

  it->second.isClosing = true;
  it->second.navigationPending = false;
  CefRefPtr<CefBrowser> browser = it->second.browser;
  [self invalidateCloseRequestForTabID:tabID];
  if (browser) {
    if (browser->IsValid()) browser->GetHost()->CloseBrowser(forceClose);
    return;
  }

  const BOOL wasActive = [_activeTabID isEqualToString:tabID];
  _tabRecords.erase(tabKey);
  [self.delegate browserTabController:self didCloseTabWithID:tabID];
  [self updateBrowserVisibilityFocusingActiveTab:wasActive];
}

- (void)closeAllTabs {
  std::vector<std::string> tabIDs;
  tabIDs.reserve(_tabRecords.size());
  for (const auto &entry : _tabRecords) {
    tabIDs.push_back(entry.first);
  }

  for (const auto &tabID : tabIDs) {
    [self closeTabWithID:ToNSString(tabID)];
  }
}

- (void)prepareForCefShutdown {
  self.delegate = nil;
  [_splitFocusRing removeFromSuperview];
  _splitFocusRing = nil;
  [self closeAllPeeks];
  for (BrowserSplitDividerView *divider in _splitDividers) {
    [divider removeFromSuperview];
  }
  _splitDividers = nil;
  _hostView.controller = nil;
  _hostView = nil;
  _activeTabID = nil;
  std::vector<std::string> tabIDs;
  for (const auto &entry : _tabRecords) {
    tabIDs.push_back(entry.first);
    // DevTools browsers have no client of ours; close them before CEF shuts down.
    if (entry.second.browser && entry.second.browser->GetHost()) {
      entry.second.browser->GetHost()->CloseDevTools();
    }
  }
  for (const auto &tabID : tabIDs) {
    [self invalidateCloseRequestForTabID:ToNSString(tabID)];
  }
  _tabRecords.clear();
  [_smallWindowSweepTimer invalidate];
  _smallWindowSweepTimer = nil;
  _requestContext = nullptr;
  _spaceProfileContexts.clear();
}

- (void)hostViewDidLayout {
  [self syncBrowserFrames];
}

- (void)syncBrowserFrames {
  [self layoutVisiblePanes:[self visiblePaneKeys]];
}

- (void)handleBrowserCreated:(CefRefPtr<CefBrowser>)browser
                     forTabID:(NSString *)tabID {
  std::string tabKey = ToStdString(tabID);
  auto it = _tabRecords.find(tabKey);
  // A page the watchdog gave up on still attaches if nothing replaced it.
  const bool lateAfterTimeout = it != _tabRecords.end() &&
                                it->second.creationState == BrowserTabEngineCreationStateFailed &&
                                it->second.creationTimedOut;
  if (it == _tabRecords.end() || it->second.isClosing ||
      (it->second.creationState != BrowserTabEngineCreationStateCreating && !lateAfterTimeout)) {
    browser->GetHost()->CloseBrowser(false);
    return;
  }

  if (lateAfterTimeout) {
    // Like a Retry that succeeded: the model only leaves Failed through Creating.
    [self.delegate browserTabController:self
         didChangeCreationStateForTabWithID:tabID
                                     state:BrowserTabEngineCreationStateCreating];
  }
  it->second.browser = browser;
  it->second.creationState = BrowserTabEngineCreationStateReady;
  it->second.creationTimedOut = false;
  if (it->second.audioMuted) {
    SetBrowserAudioMutedOnUI(browser, true);
  }
  SyncBrowserViewFrame(_hostView, browser);
  [self.delegate browserTabController:self
       didChangeCreationStateForTabWithID:tabID
                                   state:BrowserTabEngineCreationStateReady];
  [self handleNavigationStateChangeForTabID:tabID
                                  canGoBack:browser->CanGoBack()
                               canGoForward:browser->CanGoForward()];

  [self updateBrowserVisibilityFocusingActiveTab:[_activeTabID isEqualToString:tabID]];
  // The Swift delegate enables the first posted navigation only after its
  // model has processed ready. CEF and DispatchQueue.main use separate queues.
}

- (void)handleBrowserClosed:(CefRefPtr<CefBrowser>)browser forTabID:(NSString *)tabID {
  std::string tabKey = ToStdString(tabID);
  auto it = _tabRecords.find(tabKey);
  // A cancelled allocation or an obsolete browser cannot close a new record.
  if (it == _tabRecords.end() || !it->second.browser ||
      !it->second.browser->IsSame(browser)) return;
  NSString *requestID = ToNSString(it->second.closeRequestID);
  BrowserBeforeUnloadConfirmation *confirmation = it->second.closeConfirmation;
  const BOOL wasActive = [_activeTabID isEqualToString:tabID];
  _tabRecords.erase(it);
  [confirmation cancel];
  [self cancelSitePermissionsForTabID:tabID];
  [self closePeekSessionsOwnedByTabID:tabID];

  if (wasActive) {
    if (_tabRecords.empty()) {
      _activeTabID = nil;
    } else {
      _activeTabID = ToNSString(_tabRecords.begin()->first);
    }
  }

  [self notifyCloseRequestForTabID:tabID requestID:requestID
                          outcome:BrowserTabCloseRequestOutcomeClosed];
  [self.delegate browserTabController:self didCloseTabWithID:tabID];
  [self updateBrowserVisibilityFocusingActiveTab:wasActive];
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

  auto it = _tabRecords.find(ToStdString(tabID));
  if (it == _tabRecords.end() ||
      (it->second.isClosing && it->second.closeRequestID.empty()) ||
      !it->second.hasIssuedNavigation) {
    return;
  }

  // Before the first app load, CEF may report its empty bootstrap document.
  // After that load starts, forward every address, including redirects/back.
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

      [self navigateTabWithID:sourceTabID toURLString:resolvedURLString];
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
  [self updateBrowserVisibilityFocusingActiveTab:YES];
}

/// Puts away the card of a tab that is no longer shown and brings back the
/// one of the tab that now is.
- (void)syncPeekCardsWithActiveTab {
  BrowserPeekSession *visible = _peekSessions[@(_peekCardSessionID)];
  if (visible != nil && !visible.closing && visible.ownerTabID != nil &&
      ![visible.ownerTabID isEqualToString:_activeTabID]) {
    visible.hiddenWithTab = YES;
    [visible.panel hideForOtherTab];
    _peekCardSessionID = 0;
  }
  NSWindow *window = _hostView.window;
  if (_peekCardSessionID == 0 && _activeTabID != nil && window != nil) {
    for (NSNumber *sessionID in _peekSessions) {
      BrowserPeekSession *session = _peekSessions[sessionID];
      if (session.standalone || session.closing || !session.hiddenWithTab ||
          ![session.ownerTabID isEqualToString:_activeTabID]) {
        continue;
      }
      session.hiddenWithTab = NO;
      _peekCardSessionID = sessionID.intValue;
      [session.panel showAgainOverWindow:window page:_hostView];
      break;
    }
  }
  [self reportPeekPages];
}

/// Tabs with a card, open or put away, and the address in it, for the sidebar.
- (void)reportPeekPages {
  NSMutableDictionary<NSString *, NSString *> *pages = [NSMutableDictionary dictionary];
  for (NSNumber *sessionID in _peekSessions) {
    BrowserPeekSession *session = _peekSessions[sessionID];
    if (!session.standalone && !session.closing && session.ownerTabID != nil) {
      pages[session.ownerTabID] = session.urlString ?: @"";
    }
  }
  if ([pages isEqualToDictionary:_reportedPeekPages ?: @{}]) {
    return;
  }
  _reportedPeekPages = [pages copy];
  id<BrowserTabControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:didChangePeekPagesByTabID:)]) {
    [delegate browserTabController:self didChangePeekPagesByTabID:_reportedPeekPages];
  }
}

/// A tab's cards go with it.
- (void)closePeekSessionsOwnedByTabID:(NSString *)tabID {
  for (NSNumber *sessionID in _peekSessions.allKeys) {
    BrowserPeekSession *session = _peekSessions[sessionID];
    if ([session.ownerTabID isEqualToString:tabID]) {
      [self closePeekSession:sessionID.intValue];
    }
  }
}

- (void)updateBrowserVisibilityFocusingActiveTab:(BOOL)focusActive {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self presentWaitingDialogs];
  });
  [self syncPeekCardsWithActiveTab];
  const std::string activeKey = ToStdString(_activeTabID);
  const std::vector<std::string> visibleKeys = [self visiblePaneKeys];
  for (auto &entry : _tabRecords) {
    if (std::find(visibleKeys.begin(), visibleKeys.end(), entry.first) !=
        visibleKeys.end()) {
      continue;
    }

    NSView *browserView = BrowserViewForBrowser(entry.second.browser);
    if (browserView != nil) {
      const bool keptVisible = entry.second.keptVisibleForPictureInPicture;
      // The shown tab of another Space stays drawn below the page on screen, so
      // switching to it shows its page at once instead of a blank pane. Chromium
      // stops drawing into a hidden or transparent view. Split View leaves gaps
      // between panes that would show it, so only a single page keeps it.
      const bool warm = !keptVisible && visibleKeys.size() == 1 &&
                        [_warmTabIDs containsObject:ToNSString(entry.first)];
      browserView.hidden = !keptVisible && !warm;
      if (keptVisible || warm) {
        [browserView.superview addSubview:browserView positioned:NSWindowBelow relativeTo:nil];
      }
      if (warm && _hostView != nil) {
        SyncBrowserViewFrame(_hostView, entry.second.browser);
      }
    }
  }

  for (const auto &key : visibleKeys) {
    auto it = _tabRecords.find(key);
    if (it == _tabRecords.end()) {
      continue;
    }
    NSView *browserView = BrowserViewForBrowser(it->second.browser);
    if (browserView != nil) {
      browserView.hidden = NO;
    }
  }
  [self layoutVisiblePanes:visibleKeys];

  auto activeIt = _tabRecords.find(activeKey);
  if (activeIt == _tabRecords.end()) {
    return;
  }

  if (focusActive && activeIt->second.browser) {
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

void BrowserTabClient::OnStatusMessage(CefRefPtr<CefBrowser>,
                                       const CefString &value) {
  CEF_REQUIRE_UI_THREAD();
  BrowserTabController *controller = controller_;
  id<BrowserTabControllerDelegate> delegate = controller.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:didChangeStatus:forTabWithID:)]) {
    [delegate browserTabController:controller
                   didChangeStatus:ToNSString(value.ToString())
                      forTabWithID:ToNSString(tab_id_)];
  }
}

// Camera, microphone or screen capture started or stopped; screen and
// window capture count as video.
void BrowserTabClient::OnMediaAccessChange(CefRefPtr<CefBrowser>,
                                           bool has_video_access,
                                           bool has_audio_access) {
  CEF_REQUIRE_UI_THREAD();
  BrowserTabController *controller = controller_;
  id<BrowserTabControllerDelegate> delegate = controller.delegate;
  if ([delegate respondsToSelector:@selector(browserTabController:didChangeCaptureForTabWithID:video:audio:)]) {
    [delegate browserTabController:controller
        didChangeCaptureForTabWithID:ToNSString(tab_id_)
                               video:has_video_access
                               audio:has_audio_access];
  }
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

NSEventModifierFlags gLastClickModifierFlags = 0;
NSTimeInterval gLastClickUptime = -1;

/// Records the keys held at each click in the app's windows.
void WatchClickModifiers() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskOtherMouseUp
                                          handler:^NSEvent *(NSEvent *event) {
                                            gLastClickModifierFlags = event.modifierFlags;
                                            gLastClickUptime = event.timestamp;
                                            return event;
                                          }];
  });
}

/// Option-Command-click into the small window, when turned on. Chromium reports
/// the click as a Command-click, so the held keys decide.
bool IsOptionCommandClick(cef_window_open_disposition_t disposition, bool user_gesture) {
  if (!user_gesture ||
      (disposition != CEF_WOD_NEW_BACKGROUND_TAB && disposition != CEF_WOD_NEW_FOREGROUND_TAB) ||
      !BrowserPeekSettings.opensOptionCommandClicksInLittleWindow) {
    return false;
  }
  // The keys held at the click, which the page may act on later; a link opened
  // from the keyboard uses the keys held now.
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  const NSEventModifierFlags flags =
      now - gLastClickUptime < 1 ? gLastClickModifierFlags : NSEvent.modifierFlags;
  return (flags & NSEventModifierFlagOption) != 0 && (flags & NSEventModifierFlagCommand) != 0;
}

/// Shared by tabs and Peek: saves into the download folder and reports to the
/// window's download list.
bool HandleBeforeDownload(BrowserTabController *controller,
                          CefRefPtr<CefDownloadItem> download_item,
                          const CefString &suggested_name,
                          CefRefPtr<CefBeforeDownloadCallback> callback) {
  if (!download_item || !download_item->IsValid() || !callback) {
    return false;
  }

  NSString *fileName = SuggestedDownloadFileName(download_item, suggested_name);
  NSString *downloadPath = UniqueDownloadPathForFileName(fileName);
  callback->Continue(ToStdString(downloadPath), false);

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

void HandleDownloadUpdated(BrowserTabController *controller, CefRefPtr<CefDownloadItem> download_item) {
  if (!download_item || !download_item->IsValid() || controller == nil) {
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

bool BrowserTabClient::OnBeforeDownload(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    const CefString &suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();

  return HandleBeforeDownload(controller_, download_item, suggested_name, callback);
}

void BrowserTabClient::OnDownloadUpdated(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    CefRefPtr<CefDownloadItemCallback> callback) {
  CEF_REQUIRE_UI_THREAD();

  HandleDownloadUpdated(controller_, download_item);
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

bool BrowserTabClient::OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                                            CefRefPtr<CefFrame>,
                                            CefRefPtr<CefContextMenuParams> params,
                                            int command_id,
                                            EventFlags) {
  CEF_REQUIRE_UI_THREAD();
  if (RunBasicPageContextCommand(browser, params, command_id)) {
    return true;
  }
  BrowserTabController *controller = controller_;
  if (controller == nil) {
    return false;
  }
  id<BrowserTabControllerDelegate> delegate = controller.delegate;
  if (![delegate respondsToSelector:@selector(browserTabController:performPageContextCommand:argument:)]) {
    delegate = nil;
  }
  NSString *link = ToNSString(params->GetLinkUrl().ToString());
  switch (command_id) {
    case kContextOpenLinkInNewTab:
      [controller createTabWithURLString:link makeActive:NO];
      return true;
    case kContextOpenLinkInSplitView:
      [delegate browserTabController:controller performPageContextCommand:@"openInSplitView" argument:link];
      return true;
    case kContextOpenLinkInLittleWindow:
      [controller showLittleWindowWithURLString:link];
      return true;
    case kContextOpenLinkInIncognito:
      [delegate browserTabController:controller performPageContextCommand:@"openInIncognito" argument:link];
      return true;
    case kContextOpenMediaInNewTab:
      [controller createTabWithURLString:ToNSString(params->GetSourceUrl().ToString()) makeActive:NO];
      return true;
    case kContextCopyLinkToHighlight:
      [delegate browserTabController:controller performPageContextCommand:@"copyLinkToHighlight" argument:@""];
      return true;
    case kContextSearchForSelection:
      [delegate browserTabController:controller
           performPageContextCommand:@"searchForSelection"
                            argument:ToNSString(params->GetSelectionText().ToString())];
      return true;
    case kContextSavePage:
      [delegate browserTabController:controller performPageContextCommand:@"savePage" argument:@""];
      return true;
    case kContextViewSource:
      [delegate browserTabController:controller performPageContextCommand:@"viewSource" argument:@""];
      return true;
    default:
      return false;
  }
}

static NSString *g_page_start_script = nil;


/// The Web Store names Chrome on its buttons and asks every other browser to switch to it.
static const char kWebStoreScript[] = R"JS((function(){
if(window.__openArcWebStore)return;window.__openArcWebStore=true;
var names=[[/Add to Chrome/g,'Add to OpenArc'],[/Remove from Chrome/g,'Remove from OpenArc']];
function hide(element){
  while(element.parentElement&&element.parentElement!==document.body&&element.parentElement.textContent.length<140)element=element.parentElement;
  element.style.setProperty('display','none','important');
}
function fix(root){
  var walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT),node;
  while(node=walker.nextNode()){
    var text=node.nodeValue;
    if(text.indexOf('Chrome')<0)continue;
    if(text.indexOf('Switch to Chrome')>=0){hide(node.parentElement);continue;}
    for(var i=0;i<names.length;i++)text=text.replace(names[i][0],names[i][1]);
    if(text!==node.nodeValue)node.nodeValue=text;
  }
}
function start(){
  fix(document.documentElement);
  new MutationObserver(function(list){
    for(var i=0;i<list.length;i++){
      var m=list[i];
      if(m.type==='characterData'){fix(m.target.parentNode||document.documentElement);}
      else for(var j=0;j<m.addedNodes.length;j++){
        var n=m.addedNodes[j];
        fix(n.nodeType===1?n:(n.parentNode||document.documentElement));
      }
    }
  }).observe(document,{childList:true,subtree:true,characterData:true});
}
if(document.documentElement)start();else document.addEventListener('readystatechange',start,{once:true});
})();)JS";

/// Runs the shared start script in a new document.
static void RunPageStartScripts(CefRefPtr<CefFrame> frame) {
  NSString *start = BrowserPageScripts.pageStartScript;
  if (start) {
    frame->ExecuteJavaScript(start.UTF8String, frame->GetURL(), 0);
  }
  NSString *url = ToNSString(frame->GetURL().ToString());
  if ([[NSURLComponents componentsWithString:url].host isEqualToString:@"chromewebstore.google.com"]) {
    frame->ExecuteJavaScript(kWebStoreScript, frame->GetURL(), 0);
  }
}

void BrowserTabClient::OnLoadStart(CefRefPtr<CefBrowser>,
                                   CefRefPtr<CefFrame> frame,
                                   TransitionType) {
  CEF_REQUIRE_UI_THREAD();
  if (frame && frame->IsMain()) {
    [controller_ applyMediaVolumeForTabID:ToNSString(tab_id_) toFrame:frame];
    NSString *loadStart = controller_.pageLoadStartScript;
    if (loadStart.length > 0) {
      frame->ExecuteJavaScript(loadStart.UTF8String, frame->GetURL(), 0);
    }
    [controller_ cancelMediaSitePermissionsForTabID:ToNSString(tab_id_)];
    [controller_ resetMediaForTabID:ToNSString(tab_id_)];
    RunPageStartScripts(frame);
  }
}

void BrowserTabClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser>,
                                                 TerminationStatus,
                                                 int error_code,
                                                 const CefString &) {
  CEF_REQUIRE_UI_THREAD();
  [controller_ cancelMediaSitePermissionsForTabID:ToNSString(tab_id_)];
  [controller_ resetMediaForTabID:ToNSString(tab_id_)];
  [controller_ handleRenderProcessTerminatedForTabID:ToNSString(tab_id_) errorCode:error_code];
}

/// A detached frame, such as an embed whose own process crashed, stops playing.
void BrowserTabClient::OnFrameDetached(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame) {
  CEF_REQUIRE_UI_THREAD();
  if (frame) {
    [controller_ forgetMediaFrame:frame->GetIdentifier().ToString() forTabID:ToNSString(tab_id_)];
  }
}

namespace {

/// Passwords, addresses and cards reported by a page in a tab or a Peek.
bool HandleCredentialMessage(BrowserTabController *controller,
                             NSString *tabID,
                             CefRefPtr<CefFrame> frame,
                             CefProcessId source_process,
                             CefRefPtr<CefProcessMessage> message) {
  if (source_process != PID_RENDERER || !frame) {
    return false;
  }
  const std::string name = message->GetName().ToString();
  if (name == shared::kPasswordFormMessage) {
    [controller handlePasswordFormInFrame:frame forTabID:tabID];
    return true;
  }
  if (name == shared::kAddressFormMessage) {
    [controller handleAddressFormInFrame:frame forTabID:tabID];
    return true;
  }
  if (name == shared::kCardFormMessage) {
    [controller handleCardFormInFrame:frame forTabID:tabID];
    return true;
  }
  if (name == shared::kAddressSubmittedMessage) {
    [controller handleAddressSubmittedInFrame:frame
                                         json:ToNSString(message->GetArgumentList()->GetString(0).ToString())
                                     forTabID:tabID];
    return true;
  }
  if (name == shared::kPasswordSubmittedMessage) {
    CefRefPtr<CefListValue> values = message->GetArgumentList();
    // The frame's own address decides whose password this is, never the page's word.
    [controller handlePasswordSubmittedInFrame:frame
                                      username:ToNSString(values->GetString(0).ToString())
                                      password:ToNSString(values->GetString(1).ToString())
                                      forTabID:tabID];
    return true;
  }
  return false;
}

}  // namespace

bool BrowserPeekClient::OnProcessMessageReceived(CefRefPtr<CefBrowser>,
                                                 CefRefPtr<CefFrame> frame,
                                                 CefProcessId source_process,
                                                 CefRefPtr<CefProcessMessage> message) {
  CEF_REQUIRE_UI_THREAD();
  // A Peek has no tab for the model to compare a frame with, so only its page counts.
  if (!frame || !frame->IsMain()) {
    return false;
  }
  return HandleCredentialMessage(controller_,
                                 [NSString stringWithFormat:@"peek-%d", session_id_],
                                 frame,
                                 source_process,
                                 message);
}

bool BrowserTabClient::OnProcessMessageReceived(CefRefPtr<CefBrowser>,
                                                CefRefPtr<CefFrame> frame,
                                                CefProcessId source_process,
                                                CefRefPtr<CefProcessMessage> message) {
  CEF_REQUIRE_UI_THREAD();
  if (HandleCredentialMessage(controller_, ToNSString(tab_id_), frame, source_process, message)) {
    return true;
  }
  if (source_process == PID_RENDERER && frame && frame->IsMain() &&
      message->GetName() == shared::kRendererProcessMessage) {
    [controller_ noteRendererProcessID:message->GetArgumentList()->GetInt(0) forTabID:ToNSString(tab_id_)];
    return true;
  }
  if (source_process != PID_RENDERER || !frame || message->GetName() != shared::kMediaStateMessage) {
    return false;
  }
  CefRefPtr<CefListValue> values = message->GetArgumentList();
  if (values->GetSize() != static_cast<size_t>(shared::kMediaStateArgumentCount)) {
    return true;
  }
  MediaFrameState state;
  state.audible = values->GetBool(0);
  state.playing = values->GetBool(1);
  state.paused = values->GetBool(2);
  state.video = values->GetBool(3);
  state.hasPreviousTrack = values->GetBool(4);
  state.hasNextTrack = values->GetBool(5);
  state.pictureInPicture = values->GetBool(6);
  state.title = values->GetString(7).ToString();
  [controller_ handleMediaState:state frameID:frame->GetIdentifier().ToString() forTabID:ToNSString(tab_id_)];
  return true;
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
      OpenArcURLForChromiumInternalURL(request->GetURL());
  if (!redirectURL.empty()) {
    frame->LoadURL(redirectURL);
    return true;
  }

  if (IsOpenArcInternalWindowURL(request->GetURL())) {
    std::string chromiumInternalURL =
        ChromiumInternalWindowURLForOpenArcURL(request->GetURL());
    if (chromiumInternalURL.empty()) {
      if (IsOpenArcExtensionsURL(request->GetURL())) {
        chromiumInternalURL = shared::kChromiumExtensionsURL;
      } else if (IsOpenArcHistoryURL(request->GetURL())) {
        chromiumInternalURL = shared::kChromiumHistoryURL;
      } else if (IsOpenArcPasswordManagerURL(request->GetURL())) {
        chromiumInternalURL = shared::kChromiumPasswordManagerURL;
      } else if (IsOpenArcBookmarksURL(request->GetURL())) {
        chromiumInternalURL = shared::kChromiumBookmarksURL;
      } else {
        chromiumInternalURL = shared::kChromiumSettingsURL;
      }
    }
    allow_next_chromium_internal_navigation_ = true;
    frame->LoadURL(chromiumInternalURL);
    return true;
  }

  // A clicked link or its server redirect, such as a site's outbound link
  // page; not typed, restored, scripted or a form post.
  const int transition = request->GetTransitionType();
  const int qualifiers = TT_FORWARD_BACK_FLAG | TT_DIRECT_LOAD_FLAG | TT_CLIENT_REDIRECT_FLAG;
  if (user_gesture && (transition & TT_SOURCE_MASK) == TT_LINK && (transition & qualifiers) == 0 &&
      request->GetMethod() == "GET") {
    BrowserTabController *controller = controller_;
    NSString *urlString = ToNSString(request->GetURL().ToString());
    if (controller != nil && [controller shouldPeekNavigationFromTabID:ToNSString(tab_id_) toURLString:urlString]) {
      // After the engine has cancelled this navigation.
      __weak BrowserTabController *weakController = controller;
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakController showPeekWithURLString:urlString];
      });
      return true;
    }
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
  // Shift-click asks for a new window; it opens in Peek.
  if (target_disposition == CEF_WOD_NEW_WINDOW && user_gesture && BrowserPeekSettings.isEnabled) {
    [controller showPeekWithURLString:urlString];
    return true;
  }
  if (IsOptionCommandClick(target_disposition, user_gesture)) {
    [controller showLittleWindowWithURLString:urlString];
    return true;
  }
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

// Command-Left and Command-Right go back and forward when the page leaves them
// alone; a text field keeps them for moving the caret, since it handles them first.
bool BrowserTabClient::OnKeyEvent(CefRefPtr<CefBrowser> browser,
                                  const CefKeyEvent &event,
                                  CefEventHandle) {
  CEF_REQUIRE_UI_THREAD();
  constexpr int kLeftArrowKeyCode = 123;
  constexpr int kRightArrowKeyCode = 124;
  const uint32_t modifiers =
      event.modifiers & (EVENTFLAG_COMMAND_DOWN | EVENTFLAG_SHIFT_DOWN |
                         EVENTFLAG_CONTROL_DOWN | EVENTFLAG_ALT_DOWN);
  if (!browser || event.type != KEYEVENT_RAWKEYDOWN ||
      modifiers != EVENTFLAG_COMMAND_DOWN) {
    return false;
  }
  if (event.native_key_code == kLeftArrowKeyCode && browser->CanGoBack()) {
    browser->GoBack();
    return true;
  }
  if (event.native_key_code == kRightArrowKeyCode && browser->CanGoForward()) {
    browser->GoForward();
    return true;
  }
  return false;
}

bool BrowserTabClient::OnSetFocus(CefRefPtr<CefBrowser>, FocusSource source) {
  CEF_REQUIRE_UI_THREAD();
  if (source != FOCUS_SOURCE_NAVIGATION) {
    return false;
  }

  BrowserTabController *controller = controller_;
  return controller == nil ||
         [controller shouldBlockNavigationFocusForTabID:ToNSString(tab_id_)];
}

void BrowserTabClient::OnGotFocus(CefRefPtr<CefBrowser>) {
  CEF_REQUIRE_UI_THREAD();
  // A click into another visible Split View pane makes it the active tab.
  BrowserTabController *controller = controller_;
  [controller handleFocusForTabID:ToNSString(tab_id_)];
}

bool BrowserTabClient::OnBeforeUnloadDialog(
    CefRefPtr<CefBrowser> browser, const CefString &, bool is_reload,
    CefRefPtr<CefJSDialogCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  // Navigation/reload and clients without a manual request keep CEF's default
  // behavior. Only a tokenized manual close receives our native confirmation.
  if (is_reload) return false;
  BrowserTabController *controller = controller_;
  return controller && [controller handleBeforeUnloadForTabID:ToNSString(tab_id_)
                                                     browser:browser callback:callback];
}

namespace {

/// Called off the main thread: the sheet waits for the main one.
bool RequestAuthDialog(BrowserTabController *controller,
                       NSString *tabID,
                       const CefString &origin_url,
                       const CefString &host,
                       CefRefPtr<CefAuthCallback> callback) {
  if (!controller) return false;
  NSString *origin = ToNSString(origin_url.ToString());
  NSString *hostName = ToNSString(host.ToString());
  dispatch_async(dispatch_get_main_queue(), ^{
    [controller presentAuthDialogForTabID:tabID host:hostName origin:origin callback:callback];
  });
  return true;
}

}  // namespace

bool BrowserTabClient::GetAuthCredentials(CefRefPtr<CefBrowser>,
                                          const CefString &origin_url,
                                          bool,
                                          const CefString &host,
                                          int,
                                          const CefString &,
                                          const CefString &,
                                          CefRefPtr<CefAuthCallback> callback) {
  return RequestAuthDialog(controller_, ToNSString(tab_id_), origin_url, host, callback);
}

bool BrowserPeekClient::GetAuthCredentials(CefRefPtr<CefBrowser>,
                                           const CefString &origin_url,
                                           bool,
                                           const CefString &host,
                                           int,
                                           const CefString &,
                                           const CefString &,
                                           CefRefPtr<CefAuthCallback> callback) {
  return RequestAuthDialog(controller_, [NSString stringWithFormat:@"peek-%d", session_id_], origin_url, host, callback);
}

bool BrowserPeekClient::OnJSDialog(CefRefPtr<CefBrowser>,
                                   const CefString &origin_url,
                                   JSDialogType dialog_type,
                                   const CefString &message_text,
                                   const CefString &default_prompt_text,
                                   CefRefPtr<CefJSDialogCallback> callback,
                                   bool &) {
  CEF_REQUIRE_UI_THREAD();
  BrowserTabController *controller = controller_;
  if (!controller) return false;
  [controller presentPageDialogForTabID:[NSString stringWithFormat:@"peek-%d", session_id_]
                                   kind:static_cast<NSInteger>(dialog_type)
                                 origin:ToNSString(origin_url.ToString())
                                message:ToNSString(message_text.ToString())
                            defaultText:ToNSString(default_prompt_text.ToString())
                               callback:callback];
  return true;
}

void BrowserPeekClient::OnResetDialogState(CefRefPtr<CefBrowser>) {
  CEF_REQUIRE_UI_THREAD();
  [controller_ cancelPageDialogForTabID:[NSString stringWithFormat:@"peek-%d", session_id_]];
}

bool BrowserTabClient::OnJSDialog(CefRefPtr<CefBrowser>,
                                  const CefString &origin_url,
                                  JSDialogType dialog_type,
                                  const CefString &message_text,
                                  const CefString &default_prompt_text,
                                  CefRefPtr<CefJSDialogCallback> callback,
                                  bool &) {
  CEF_REQUIRE_UI_THREAD();
  BrowserTabController *controller = controller_;
  if (!controller) return false;
  [controller presentPageDialogForTabID:ToNSString(tab_id_)
                                   kind:static_cast<NSInteger>(dialog_type)
                                 origin:ToNSString(origin_url.ToString())
                                message:ToNSString(message_text.ToString())
                            defaultText:ToNSString(default_prompt_text.ToString())
                               callback:callback];
  return true;
}

void BrowserTabClient::OnResetDialogState(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  BrowserTabController *controller = controller_;
  [controller cancelPageDialogForTabID:ToNSString(tab_id_)];
  [controller resetCloseDialogForTabID:ToNSString(tab_id_) browser:browser];
}

void BrowserTabClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();

  shared::ClientManager::GetInstance()->OnAfterCreated(browser);

  BrowserTabController *controller = controller_;
  if (controller == nil) {
    browser->GetHost()->CloseBrowser(false);
    return;
  }

  if (controller.autoResizesPages) {
    browser->GetHost()->SetAutoResizeEnabled(true, CefSize(25, 25), CefSize(800, 600));
  }
  [controller handleBrowserCreated:browser forTabID:ToNSString(tab_id_)];
}

bool BrowserTabClient::OnAutoResize(CefRefPtr<CefBrowser> browser,
                                    const CefSize& new_size) {
  CEF_REQUIRE_UI_THREAD();
  BrowserTabController *controller = controller_;
  if (controller.onPageContentSizeChange != nil) {
    controller.onPageContentSizeChange(NSMakeSize(new_size.width, new_size.height));
  }
  return true;
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

  [controller cancelDialogsForTabID:ToNSString(tab_id_)];
  [controller handleBrowserClosed:browser forTabID:ToNSString(tab_id_)];
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
  if (target_disposition == CEF_WOD_NEW_WINDOW && user_gesture && BrowserPeekSettings.isEnabled) {
    [controller showPeekWithURLString:urlString];
    return true;
  }
  if (IsOptionCommandClick(target_disposition, user_gesture)) {
    [controller showLittleWindowWithURLString:urlString];
    return true;
  }
  return [controller openURLFromTabWithURLString:urlString
                                    sourceTabID:ToNSString(tab_id_)
                              targetDisposition:target_disposition];
}

/// Chromium's permission prompts (location, notifications, clipboard and
/// others) go to the page's prompt; Chromium remembers the answer.
bool RequestSitePermissionPrompt(BrowserTabController *controller,
                                 NSString *tabID,
                                 uint64_t prompt_id,
                                 const CefString &requesting_origin,
                                 uint32_t requested_permissions,
                                 CefRefPtr<CefPermissionPromptCallback> callback) {
  NSArray<NSString *> *kinds = SitePermissionKindsForPrompt(requested_permissions);
  if (controller == nil || kinds.count == 0) {
    return false;
  }
  PendingSitePermission pending;
  pending.promptCallback = callback;
  pending.promptID = prompt_id;
  [controller requestSitePermissionForTabID:tabID
                                     origin:ToNSString(requesting_origin.ToString())
                                      kinds:kinds
                                    pending:pending];
  return true;
}

/// Camera and microphone from getUserMedia. Alloy-style CEF denies them by
/// default, so they go to the page's prompt. Screen sharing needs a source
/// picker OpenArc does not have and keeps the default denial.
bool RequestSiteMediaAccess(BrowserTabController *controller,
                            NSString *tabID,
                            const CefString &requesting_origin,
                            uint32_t requested_permissions,
                            CefRefPtr<CefMediaAccessCallback> callback) {
  if (controller != nil && (requested_permissions & CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE)) {
    [controller presentScreenSharePickerForTabID:tabID
                                          origin:ToNSString(requesting_origin.ToString())
                                        callback:callback];
    return true;
  }
  if (controller == nil || requested_permissions == 0 ||
      (requested_permissions & ~kDeviceMediaPermissions) != 0) {
    return false;
  }
  PendingSitePermission pending;
  pending.mediaCallback = callback;
  pending.mediaPermissions = requested_permissions;
  [controller requestSitePermissionForTabID:tabID
                                     origin:ToNSString(requesting_origin.ToString())
                                      kinds:SitePermissionKindsForMedia(requested_permissions)
                                    pending:pending];
  return true;
}

bool BrowserTabClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser>,
    uint64_t prompt_id,
    const CefString &requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  return RequestSitePermissionPrompt(controller_, ToNSString(tab_id_), prompt_id, requesting_origin,
                                     requested_permissions, callback);
}

void BrowserTabClient::OnDismissPermissionPrompt(CefRefPtr<CefBrowser>,
                                                 uint64_t prompt_id,
                                                 cef_permission_request_result_t) {
  CEF_REQUIRE_UI_THREAD();
  [controller_ dismissSitePermissionPromptWithID:prompt_id];
}

bool BrowserTabClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser>,
    CefRefPtr<CefFrame>,
    const CefString &requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  return RequestSiteMediaAccess(controller_, ToNSString(tab_id_), requesting_origin, requested_permissions,
                                callback);
}

/// Peek cards and small windows ask like tabs; their prompt shows in
/// the card.
void BrowserPeekClient::OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, TransitionType) {
  CEF_REQUIRE_UI_THREAD();
  if (frame && frame->IsMain()) {
    [controller_ cancelMediaSitePermissionsForTabID:PeekSitePermissionTabID(session_id_)];
    RunPageStartScripts(frame);
    [[controller_ peekPanelForSessionID:session_id_] revealPage];
  }
}

bool BrowserPeekClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser>,
    uint64_t prompt_id,
    const CefString &requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  return RequestSitePermissionPrompt(controller_, PeekSitePermissionTabID(session_id_), prompt_id,
                                     requesting_origin, requested_permissions, callback);
}

void BrowserPeekClient::OnDismissPermissionPrompt(CefRefPtr<CefBrowser>,
                                                  uint64_t prompt_id,
                                                  cef_permission_request_result_t) {
  CEF_REQUIRE_UI_THREAD();
  [controller_ dismissSitePermissionPromptWithID:prompt_id];
}

bool BrowserPeekClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser>,
    CefRefPtr<CefFrame>,
    const CefString &requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  return RequestSiteMediaAccess(controller_, PeekSitePermissionTabID(session_id_), requesting_origin,
                                requested_permissions, callback);
}

bool BrowserPeekClient::OnSetFocus(CefRefPtr<CefBrowser>, FocusSource source) {
  CEF_REQUIRE_UI_THREAD();
  // A loading page must not take the keys from the small window's address field.
  return source == FOCUS_SOURCE_NAVIGATION && [controller_ isPeekSessionEditingAddress:session_id_];
}

void BrowserPeekClient::OnAddressChange(CefRefPtr<CefBrowser>,
                                        CefRefPtr<CefFrame> frame,
                                        const CefString &url) {
  CEF_REQUIRE_UI_THREAD();
  if (frame && frame->IsMain()) {
    [controller_ handlePeekAddressChange:ToNSString(url.ToString()) session:session_id_];
  }
}

bool BrowserPeekClient::OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefDownloadItem> download_item,
                                         const CefString &suggested_name,
                                         CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  return HandleBeforeDownload(controller_, download_item, suggested_name, callback);
}

void BrowserPeekClient::OnDownloadUpdated(CefRefPtr<CefBrowser>,
                                          CefRefPtr<CefDownloadItem> download_item,
                                          CefRefPtr<CefDownloadItemCallback>) {
  CEF_REQUIRE_UI_THREAD();
  HandleDownloadUpdated(controller_, download_item);
}

bool BrowserPeekClient::OnPreKeyEvent(CefRefPtr<CefBrowser>,
                                      const CefKeyEvent &event,
                                      CefEventHandle,
                                      bool *) {
  CEF_REQUIRE_UI_THREAD();
  // Escape closes a Peek card; the small window leaves it to the page.
  BrowserTabController *controller = controller_;
  if (event.type == KEYEVENT_RAWKEYDOWN && event.windows_key_code == 0x1B && controller != nil &&
      ![controller isPeekSessionStandalone:session_id_]) {
    // Close after this key event returns, not inside the engine callback.
    __weak BrowserTabController *weakController = controller;
    const int sessionID = session_id_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakController closePeekSessionByUser:sessionID];
    });
    return true;
  }
  return false;
}

void BrowserPeekClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  shared::ClientManager::GetInstance()->OnAfterCreated(browser);
  BrowserTabController *controller = controller_;
  if (controller == nil) {
    browser->GetHost()->CloseBrowser(true);
    return;
  }
  [controller handlePeekCreated:browser session:session_id_];
}

bool BrowserPeekClient::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  shared::ClientManager::GetInstance()->DoClose(browser);
  // The page is an embedded child view, like a tab: tear the view down here
  // instead of letting CEF close the parent window.
  NSView *browserView = BrowserViewForBrowser(browser);
  if (browserView != nil) {
    [browserView removeFromSuperview];
    return true;
  }
  return false;
}

void BrowserPeekClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  shared::ClientManager::GetInstance()->OnBeforeClose(browser);
  [controller_ cancelDialogsForTabID:[NSString stringWithFormat:@"peek-%d", session_id_]];
  [controller_ handlePeekClosed:browser session:session_id_];
}

void BrowserPeekClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser>,
                                                  TerminationStatus,
                                                  int,
                                                  const CefString &) {
  CEF_REQUIRE_UI_THREAD();
  // A crashed page would leave an empty card.
  __weak BrowserTabController *controller = controller_;
  const int sessionID = session_id_;
  dispatch_async(dispatch_get_main_queue(), ^{
    [controller closePeekSession:sessionID];
  });
}

bool BrowserPeekClient::OnOpenURLFromTab(CefRefPtr<CefBrowser>,
                                         CefRefPtr<CefFrame>,
                                         const CefString &target_url,
                                         WindowOpenDisposition target_disposition,
                                         bool) {
  CEF_REQUIRE_UI_THREAD();
  if (target_disposition == CEF_WOD_CURRENT_TAB) {
    return false;
  }
  BrowserTabController *controller = controller_;
  [controller openURLFromTabWithURLString:ToNSString(target_url.ToString())
                              sourceTabID:@""
                        targetDisposition:CEF_WOD_NEW_FOREGROUND_TAB];
  return true;
}

bool BrowserPeekClient::OnBeforePopup(CefRefPtr<CefBrowser>,
                                      CefRefPtr<CefFrame>,
                                      int,
                                      const CefString &target_url,
                                      const CefString &,
                                      WindowOpenDisposition,
                                      bool,
                                      const CefPopupFeatures &,
                                      CefWindowInfo &,
                                      CefRefPtr<CefClient> &,
                                      CefBrowserSettings &,
                                      CefRefPtr<CefDictionaryValue> &,
                                      bool *) {
  CEF_REQUIRE_UI_THREAD();
  // A link that opens a new window from the card becomes a tab.
  BrowserTabController *controller = controller_;
  [controller openURLFromTabWithURLString:ToNSString(target_url.ToString())
                              sourceTabID:@""
                        targetDisposition:CEF_WOD_NEW_FOREGROUND_TAB];
  return true;
}

}  // namespace

@implementation BrowserPageScripts

+ (NSString *)pageStartScript {
  return g_page_start_script;
}

+ (void)setPageStartScript:(NSString *)pageStartScript {
  g_page_start_script = [pageStartScript copy];
}

@end
