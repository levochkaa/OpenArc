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
}

// MARK: - BrowserMobileEngineEvent

enum BrowserMobileEngineEvent {
    case state(id: String, BrowserMobilePageState)
    case closed(id: String)
    case javaScriptDialogRequested(BrowserMobileJavaScriptDialog)
    case javaScriptDialogFinished(id: UUID)
    case httpAuthenticationRequested(BrowserMobileHTTPAuthentication)
    case httpAuthenticationFinished(id: UUID)
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
    func setJavaScriptDialogPresentationActive(_ active: Bool)
    func resolveJavaScriptDialog(id: UUID, response: BrowserMobileJavaScriptDialogResponse)
    func resolveHTTPAuthentication(id: UUID, response: BrowserMobileHTTPAuthenticationResponse)
    func shutdown()
}

extension BrowserMobileEngine {
    func setDownloads(_: BrowserMobileDownloads?) {}
    func resolveHTTPAuthentication(id _: UUID, response _: BrowserMobileHTTPAuthenticationResponse) {}
    func canFindInPage(id _: String) -> Bool { false }
    @discardableResult func presentFindInPage(id _: String) -> Bool { false }
    func dismissFindInPage() {}
}
