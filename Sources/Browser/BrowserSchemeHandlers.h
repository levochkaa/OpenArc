#ifndef OPENARC_BROWSER_SCHEME_HANDLERS_H_
#define OPENARC_BROWSER_SCHEME_HANDLERS_H_

#include <string>

namespace browser {

void RegisterBrowserSchemeHandlers();

/// The page OpenArc shows at its own openarc://<host> address on either engine: an Easel's and a note's tab show an
/// empty page the window draws over, any other host is not found. Sets `status_code`. openarc://credits is CEF's
/// credits page on CEF and Chrome's own chrome://credits on the Chrome engine.
std::string OpenArcSchemePageHTML(const std::string& host, int* status_code);

}  // namespace browser

#endif  // OPENARC_BROWSER_SCHEME_HANDLERS_H_
