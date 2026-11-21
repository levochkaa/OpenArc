#include "Browser/BrowserSchemeHandlers.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <string>
#include <utility>

#include "Shared/BrowserSchemes.h"

#include "include/cef_parser.h"
#include "include/cef_pack_resources.h"
#include "include/cef_request.h"
#include "include/cef_resource_handler.h"
#include "include/cef_resource_bundle.h"
#include "include/cef_response.h"
#include "include/cef_scheme.h"
#include "include/wrapper/cef_helpers.h"

namespace browser {

namespace {

std::string ToStdString(NSString* value) {
  if (value.length == 0) {
    return std::string();
  }
  return std::string(value.UTF8String);
}

std::string URLPartToString(const cef_string_t& value) {
  return CefString(&value).ToString();
}

std::string LowercaseASCII(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char character) {
                   return static_cast<char>(std::tolower(character));
                 });
  return value;
}

class StringResourceHandler : public CefResourceHandler {
 public:
  StringResourceHandler(int status_code,
                        std::string status_text,
                        std::string mime_type,
                        std::string contents)
      : status_code_(status_code),
        status_text_(std::move(status_text)),
        mime_type_(std::move(mime_type)),
        contents_(std::move(contents)) {}

  bool Open(CefRefPtr<CefRequest> request,
            bool& handle_request,
            CefRefPtr<CefCallback> callback) override {
    handle_request = true;
    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length,
                          CefString& redirectUrl) override {
    response->SetStatus(status_code_);
    response->SetStatusText(status_text_);
    response->SetMimeType(mime_type_);
    response->SetCharset("utf-8");
    response_length = contents_.length();
  }

  bool Read(void* data_out,
            int bytes_to_read,
            int& bytes_read,
            CefRefPtr<CefResourceReadCallback> callback) override {
    bytes_read = 0;
    if (offset_ >= contents_.length()) {
      return false;
    }

    int transfer_size =
        std::min(bytes_to_read, static_cast<int>(contents_.length() - offset_));
    memcpy(data_out, contents_.c_str() + offset_, transfer_size);
    offset_ += transfer_size;
    bytes_read = transfer_size;
    return true;
  }

  void Cancel() override {}

 private:
  const int status_code_;
  const std::string status_text_;
  const std::string mime_type_;
  const std::string contents_;
  size_t offset_ = 0;

  IMPLEMENT_REFCOUNTING(StringResourceHandler);
  DISALLOW_COPY_AND_ASSIGN(StringResourceHandler);
};

CefRefPtr<CefResourceHandler> CreatePageHandler(const std::string& host) {
  int status_code = 200;
  std::string html = OpenArcSchemePageHTML(host, &status_code);
  return new StringResourceHandler(status_code,
                                   status_code == 200 ? "OK" : "Not Found",
                                   "text/html", std::move(html));
}

CefRefPtr<CefResourceHandler> CreateNotFoundHandler() {
  return CreatePageHandler(std::string());
}

std::string RequestHost(CefRefPtr<CefRequest> request) {
  CefURLParts parts;
  if (!CefParseURL(request->GetURL(), parts)) {
    return std::string();
  }

  return LowercaseASCII(URLPartToString(parts.host));
}

std::string RequestPath(CefRefPtr<CefRequest> request) {
  CefURLParts parts;
  if (!CefParseURL(request->GetURL(), parts)) {
    return std::string();
  }

  return URLPartToString(parts.path);
}

bool IsCreditsRootPath(const std::string& path) {
  return path.empty() || path == "/";
}

std::string BundledCefCreditsPath() {
  NSURL* url = [[NSBundle mainBundle] URLForResource:@"CEFCredits"
                                      withExtension:@"html"];
  if (url == nil || url.path.length == 0) {
    return std::string();
  }

  return ToStdString(url.path);
}

std::string ReadFileContents(const std::string& path) {
  NSString* path_string = [NSString stringWithUTF8String:path.c_str()];
  NSData* data = [NSData dataWithContentsOfFile:path_string];
  if (data == nil || data.length == 0) {
    return std::string();
  }

  return std::string(static_cast<const char*>(data.bytes), data.length);
}

void ReplaceAll(std::string& value,
                const std::string& needle,
                const std::string& replacement) {
  size_t position = 0;
  while ((position = value.find(needle, position)) != std::string::npos) {
    value.replace(position, needle.length(), replacement);
    position += replacement.length();
  }
}

std::string RewriteCreditsHTML(std::string html) {
  ReplaceAll(html, "chrome://credits/credits.css",
             "openarc://credits/credits.css");
  ReplaceAll(html, "chrome://resources/css/text_defaults.css",
             "openarc://credits/text_defaults.css");
  ReplaceAll(html, "chrome://resources/css/text_defaults_md.css",
             "openarc://credits/text_defaults_md.css");
  return html;
}

CefRefPtr<CefResourceHandler> CreateCreditsHTMLHandler(
    const std::string& credits_path) {
  std::string html = ReadFileContents(credits_path);
  if (html.empty()) {
    return nullptr;
  }

  return new StringResourceHandler(200, "OK", "text/html",
                                   RewriteCreditsHTML(std::move(html)));
}

CefRefPtr<CefResourceHandler> CreateBundledResourceHandler(
    int resource_id,
    const char* mime_type) {
  CefRefPtr<CefResourceBundle> bundle = CefResourceBundle::GetGlobal();
  if (!bundle) {
    return nullptr;
  }

  CefRefPtr<CefBinaryValue> resource = bundle->GetDataResource(resource_id);
  if (!resource || !resource->IsValid()) {
    return nullptr;
  }

  std::string contents(static_cast<const char*>(resource->GetRawData()),
                       resource->GetSize());
  return new StringResourceHandler(200, "OK", mime_type, std::move(contents));
}

class OpenArcSchemeHandlerFactory
    : public CefSchemeHandlerFactory {
 public:
  explicit OpenArcSchemeHandlerFactory(std::string credits_path)
      : credits_path_(std::move(credits_path)) {}

  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       const CefString& scheme_name,
                                       CefRefPtr<CefRequest> request) override {
    CEF_REQUIRE_IO_THREAD();

    const std::string host = RequestHost(request);
    if (host != shared::kOpenArcCreditsHost) {
      return CreatePageHandler(host);
    }

    std::string path = RequestPath(request);
    CefRefPtr<CefResourceHandler> handler;
    if (IsCreditsRootPath(path) && !credits_path_.empty()) {
      handler = CreateCreditsHTMLHandler(credits_path_);
    } else if (path == "/credits.css") {
      handler =
          CreateBundledResourceHandler(IDR_ABOUT_UI_CREDITS_CSS, "text/css");
    } else if (path == "/text_defaults.css") {
      handler =
          CreateBundledResourceHandler(IDR_WEBUI_CSS_TEXT_DEFAULTS_CSS,
                                       "text/css");
    } else if (path == "/text_defaults_md.css") {
      handler =
          CreateBundledResourceHandler(IDR_WEBUI_CSS_TEXT_DEFAULTS_MD_CSS,
                                       "text/css");
    }

    return handler ? handler : CreateNotFoundHandler();
  }

 private:
  const std::string credits_path_;

  IMPLEMENT_REFCOUNTING(OpenArcSchemeHandlerFactory);
  DISALLOW_COPY_AND_ASSIGN(OpenArcSchemeHandlerFactory);
};

}  // namespace

std::string OpenArcSchemePageHTML(const std::string& host, int* status_code) {
  *status_code = 200;
  // An Easel's tab shows an empty page; the window draws the canvas over it.
  if (host == shared::kOpenArcEaselHost) {
    return "<!doctype html><meta charset=\"utf-8\"><meta name=\"color-scheme\" "
           "content=\"light dark\"><title>Easel</title>";
  }
  // A note's tab too; the window draws the note over it.
  if (host == shared::kOpenArcNotesHost) {
    return "<!doctype html><meta name=\"color-scheme\" content=\"light dark\">";
  }
  *status_code = 404;
  return "<!doctype html><title>Not Found</title><h1>Not Found</h1>";
}

void RegisterBrowserSchemeHandlers() {
  CefRegisterSchemeHandlerFactory(
      shared::kOpenArcScheme, "",
      new OpenArcSchemeHandlerFactory(BundledCefCreditsPath()));
}

}  // namespace browser
