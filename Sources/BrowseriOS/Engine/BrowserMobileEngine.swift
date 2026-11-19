// BrowserMobileEngine.swift

import Foundation
import UIKit

// MARK: - BrowserMobilePageState

struct BrowserMobilePageState: Equatable {
    var url: URL?
    var title = ""
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var error: String?
    /// The color the page asks the browser's chrome to take (`theme-color`).
    var themeColor: UIColor?
    /// The page's own background color, which decides whether the bar
    /// around it is light or dark.
    var backgroundColor: UIColor?
    /// The loaded page reads like an article, so Reader Mode can show it.
    var canRead = false
    /// Reader Mode shows the page's article in place of the page.
    var isReading = false
    /// The page's text shows translated.
    var isTranslated = false
}

// MARK: - BrowserMobilePageText

/// The page's text for translation, one string per text node.
struct BrowserMobilePageText: Equatable {
    var texts: [String]
    /// The document's declared language, if any.
    var language: String
}

// MARK: - BrowserMobileEngineEvent

enum BrowserMobileEngineEvent {
    case state(id: String, BrowserMobilePageState)
    case closed(id: String)
    case javaScriptDialogRequested(BrowserMobileJavaScriptDialog)
    case javaScriptDialogFinished(id: UUID)
    case httpAuthenticationRequested(BrowserMobileHTTPAuthentication)
    case httpAuthenticationFinished(id: UUID)
    /// The link menu or an extension asked for a link in another tab.
    case openInNewTab(URL, inBackground: Bool)
    /// An extension asked to show this page's tab.
    case activateRequested(id: String)
}

// MARK: - BrowserMobileEngine

/// Runtime IDs belong to one scene's engine. The workspace owns stable tab IDs.
/// Creation and navigation may synchronously emit events; callers register the
/// logical identity first. A closed runtime ID cannot be reused.
@MainActor protocol BrowserMobileEngine: AnyObject {
    var hostView: UIView { get }
    var onEvent: ((BrowserMobileEngineEvent) -> Void)? { get set }
    /// The engine has registered a popup using WebKit's supplied configuration.
    /// Adopt its runtime ID before further delegate events are delivered.
    var onPopupCreated: ((String, URL?) -> Void)? { get set }
    func setDownloads(_ downloads: BrowserMobileDownloads?)
    func createTab(id: String, url: URL)
    func selectTab(id: String?)
    func navigate(id: String, url: URL)
    func goBack(id: String)
    func goForward(id: String)
    func reload(id: String)
    func stop(id: String)
    func closeTab(id: String)
    func canFindInPage(id: String) -> Bool
    @discardableResult func presentFindInPage(id: String) -> Bool
    func dismissFindInPage()
    /// Whether the system's find bar is up over the selected page.
    var isFindInPageVisible: Bool { get }
    func setJavaScriptDialogPresentationActive(_ active: Bool)
    func resolveJavaScriptDialog(id: UUID, response: BrowserMobileJavaScriptDialogResponse)
    func resolveHTTPAuthentication(id: UUID, response: BrowserMobileHTTPAuthenticationResponse)
    func shutdown()
    /// A picture of the page as it last drew, `width` points wide; nil for a
    /// tab without a view. `rect` limits it to part of the view.
    func snapshot(id: String, rect: CGRect?, width: CGFloat, completion: @escaping @MainActor (UIImage?) -> Void)
    /// The scroll view of the tab's page, while it has a view.
    func scrollView(id: String) -> UIScrollView?
    /// The icons the loaded page declares, best first.
    func iconURLs(id: String, completion: @escaping @MainActor ([URL]) -> Void)
    /// Room the browser's own bars cover at the page's edges.
    func setObscuredInsets(_ insets: UIEdgeInsets)
    /// Text and layout scale of the tab's page; 1 is the site's own size.
    func pageZoom(id: String) -> CGFloat
    func setPageZoom(id: String, _ zoom: CGFloat)
    /// Whether the tab asks sites for their desktop layout.
    func prefersDesktopSite(id: String) -> Bool
    /// Switches the layout the tab asks for and reloads the page.
    func setPrefersDesktopSite(id: String, _ prefersDesktop: Bool)
    /// Shows the page's article in place of the page, or the page again.
    func setReading(id: String, _ reading: Bool)
    /// The page's text to translate; nil when the page has none.
    func pageText(id: String, completion: @escaping @MainActor (BrowserMobilePageText?) -> Void)
    /// Puts translated strings in place of the text `pageText` returned, from `start` on.
    func applyTranslatedText(id: String, start: Int, texts: [String])
    /// Puts the page's own text back.
    func restoreOriginalText(id: String)
}

extension BrowserMobileEngine {
    func setDownloads(_: BrowserMobileDownloads?) {}
    func resolveHTTPAuthentication(id _: UUID, response _: BrowserMobileHTTPAuthenticationResponse) {}
    func canFindInPage(id _: String) -> Bool { false }
    @discardableResult func presentFindInPage(id _: String) -> Bool { false }
    func dismissFindInPage() {}
    var isFindInPageVisible: Bool { false }
    func snapshot(
        id _: String, rect _: CGRect?, width _: CGFloat, completion: @escaping @MainActor (UIImage?) -> Void,
    ) {
        completion(nil)
    }

    func scrollView(id _: String) -> UIScrollView? { nil }
    func iconURLs(id _: String, completion: @escaping @MainActor ([URL]) -> Void) { completion([]) }
    func setObscuredInsets(_: UIEdgeInsets) {}
    func pageZoom(id _: String) -> CGFloat { 1 }
    func setPageZoom(id _: String, _: CGFloat) {}
    func prefersDesktopSite(id _: String) -> Bool { false }
    func setPrefersDesktopSite(id _: String, _: Bool) {}
    func setReading(id _: String, _: Bool) {}
    func pageText(id _: String, completion: @escaping @MainActor (BrowserMobilePageText?) -> Void) { completion(nil) }
    func applyTranslatedText(id _: String, start _: Int, texts _: [String]) {}
    func restoreOriginalText(id _: String) {}
}
