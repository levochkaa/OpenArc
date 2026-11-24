// BrowserWebKitInternalPages.swift

import Foundation
import WebKit

// MARK: - BrowserWebKitInternalPages

/// Serves `openarc://` and `chrome://` addresses to WebKit pages when the app runs on WebKit alone, as
/// `BrowserSchemeHandlers.mm` does for CEF: an empty page under an Easel or a note, which the window draws
/// over, and the credits. Chromium's own pages (settings, history, extensions, bookmarks) have no WebKit
/// counterpart; a short page says so. The passwords page points at OpenArc's own, in Settings, which it opens.
@MainActor final class BrowserWebKitInternalPages: NSObject, WKURLSchemeHandler {
    struct Response: Equatable {
        let statusCode: Int
        let mimeType: String
        let body: Data
    }

    // MARK: Internal

    /// Posted when the passwords page's Open Settings link is followed: OpenArc keeps saved sign-ins in Settings.
    @objc static let openPasswordSettings = Notification.Name("BrowserOpenPasswordSettings")

    /// The passwords page's link to Settings, which the app takes rather than a page.
    static let passwordSettingsURLString = "openarc://\(BrowserInternalURLNormalizer.passwordManagerHost)/open-settings"

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
        case BrowserInternalURLNormalizer.passwordManagerHost:
            return html(unavailablePage(
                title: BrowserStrings.settingsPasswords,
                message: BrowserStrings.passwordsInSettingsMessage,
                link: (BrowserStrings.shareOpenSettings, passwordSettingsURLString),
            ))
        case BrowserInternalURLNormalizer.bookmarksHost, BrowserInternalURLNormalizer.extensionsHost,
             BrowserInternalURLNormalizer.historyHost, BrowserInternalURLNormalizer.settingsHost:
            return html(unavailablePage(
                title: BrowserStrings.webKitEngineInternalPageTitle,
                message: BrowserStrings.webKitEngineInternalPageMessage,
            ))
        default:
            return notFound
        }
    }

    /// The page for an internal address on Ladybird, which shows its own settings, history and bookmarks and
    /// takes the rest from here: the Easel's and the note's empty pages, the credits, and a short page for
    /// Chromium's pages Ladybird has no counterpart for (extensions). The passwords page opens OpenArc's own, in
    /// Settings. Its status code goes to `statusCode`.
    @objc(ladybirdPageHTMLForURLString:statusCode:)
    static func ladybirdPageHTML(forURLString urlString: String, statusCode: UnsafeMutablePointer<Int>) -> String {
        guard let url = URL(string: urlString) else {
            statusCode.pointee = notFound.statusCode
            return String(decoding: notFound.body, as: UTF8.self)
        }
        switch url.host?.lowercased() ?? "" {
        case BrowserInternalURLNormalizer.extensionsHost:
            statusCode.pointee = 200
            return unavailablePage(
                title: BrowserStrings.ladybirdEngineInternalPageTitle,
                message: BrowserStrings.ladybirdEngineInternalPageMessage,
            )
        default:
            let page = response(for: url)
            statusCode.pointee = page.statusCode
            return String(decoding: page.body, as: UTF8.self)
        }
    }

    /// Takes an address the app handles instead of a page (the passwords page's Open Settings link): true when it
    /// did, and the navigation should stop.
    @objc static func takeAppAddress(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), isPasswordSettingsAddress(url) else { return false }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: openPasswordSettings, object: nil)
        }
        return true
    }

    private static func isPasswordSettingsAddress(_ url: URL) -> Bool {
        url.host?.lowercased() == BrowserInternalURLNormalizer.passwordManagerHost && url.path == "/open-settings"
    }

    private static func html(_ source: String) -> Response {
        Response(statusCode: 200, mimeType: "text/html", body: Data(source.utf8))
    }

    private static func unavailablePage(title: String, message: String, link: (String, String)? = nil) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let linkHTML = link.map { #"<p><a href="\#(escaped($0.1))">\#(escaped($0.0))</a></p>"# } ?? ""
        return """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark">\
        <title>\(escaped(title))</title>\
        <style>body{font:15px -apple-system,sans-serif;display:grid;place-content:center;height:90vh;margin:0}\
        p{max-width:28em;text-align:center;opacity:.7}</style><p>\(escaped(message))</p>\(linkHTML)
        """
    }

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        // A link the app takes leaves the page where it was: no content.
        if Self.takeAppAddress(url.absoluteString) {
            if let response = HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: [:]) {
                task.didReceive(response)
            }
            task.didFinish()
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
