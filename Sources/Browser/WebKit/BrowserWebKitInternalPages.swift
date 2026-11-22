// BrowserWebKitInternalPages.swift

import Foundation
import WebKit

// MARK: - BrowserWebKitInternalPages

/// Serves `openarc://` and `chrome://` addresses to WebKit pages when the app runs on WebKit alone, as
/// `BrowserSchemeHandlers.mm` does for CEF: an empty page under an Easel or a note, which the window draws
/// over, and the credits. Chromium's own pages (settings, history, passwords, extensions, bookmarks) have no
/// WebKit counterpart; a short page says so.
@MainActor final class BrowserWebKitInternalPages: NSObject, WKURLSchemeHandler {
    // MARK: Internal

    struct Response: Equatable {
        let statusCode: Int
        let mimeType: String
        let body: Data
    }

    static let shared = BrowserWebKitInternalPages()

    static let schemes = [BrowserInternalURLNormalizer.canonicalScheme, BrowserInternalURLNormalizer.chromiumScheme]

    // MARK: Private

    private static let notFound = Response(
        statusCode: 404,
        mimeType: "text/html",
        body: Data("<!doctype html><title>Not Found</title><h1>Not Found</h1>".utf8),
    )

    /// The page for an internal address; `bundle` holds the credits.
    static func response(for url: URL, bundle: Bundle = .main) -> Response {
        let host = url.host?.lowercased() ?? ""
        switch host {
        case BrowserInternalURLNormalizer.easelHost:
            return html(
                #"<!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>Easel</title>"#,
            )
        case BrowserInternalURLNormalizer.notesHost:
            return html(#"<!doctype html><meta name="color-scheme" content="light dark">"#)
        case BrowserInternalURLNormalizer.creditsHost where url.path.isEmpty || url.path == "/":
            for name in ["CEFCredits", "Credits"] {
                if let file = bundle.url(forResource: name, withExtension: "html"),
                   let data = try? Data(contentsOf: file)
                {
                    return Response(statusCode: 200, mimeType: "text/html", body: data)
                }
            }
            return notFound
        case BrowserInternalURLNormalizer.bookmarksHost, BrowserInternalURLNormalizer.extensionsHost,
             BrowserInternalURLNormalizer.historyHost, BrowserInternalURLNormalizer.passwordManagerHost,
             BrowserInternalURLNormalizer.settingsHost:
            return html(unavailablePage(
                title: BrowserStrings.webKitEngineInternalPageTitle,
                message: BrowserStrings.webKitEngineInternalPageMessage,
            ))
        default:
            return notFound
        }
    }

    private static func html(_ source: String) -> Response {
        Response(statusCode: 200, mimeType: "text/html", body: Data(source.utf8))
    }

    private static func unavailablePage(title: String, message: String) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        return """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark">\
        <title>\(escaped(title))</title>\
        <style>body{font:15px -apple-system,sans-serif;display:grid;place-items:center;height:90vh;margin:0}\
        p{max-width:28em;text-align:center;opacity:.7}</style><p>\(escaped(message))</p>
        """
    }

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let page = Self.response(for: url)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: page.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "\(page.mimeType); charset=utf-8",
                "Content-Length": String(page.body.count),
            ],
        ) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(page.body)
        task.didFinish()
    }

    func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}
}
