// BrowserWebKitExtensionTabs.swift

import UIKit
import WebKit

// MARK: - BrowserWebKitExtensionWindow

/// A scene's engine, as extensions see a window: its pages are the tabs, the
/// selected page is the active tab.
@MainActor final class BrowserWebKitExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var engine: BrowserWebKitEngine?

    init(engine: BrowserWebKitEngine) {
        self.engine = engine
    }

    func tabs(for _: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        engine?.extensionTabs ?? []
    }

    func activeTab(for _: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        engine?.selectedExtensionTab
    }

    func windowType(for _: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for _: WKWebExtensionContext) -> WKWebExtension.WindowState {
        engine?.hostView.window?.windowScene?.activationState == .background ? .minimized : .normal
    }

    func isPrivate(for _: WKWebExtensionContext) -> Bool {
        engine?.isEphemeral ?? false
    }

    func screenFrame(for _: WKWebExtensionContext) -> CGRect {
        engine?.hostView.window?.windowScene?.screen.bounds ?? .zero
    }

    func frame(for _: WKWebExtensionContext) -> CGRect {
        engine?.hostView.window?.frame ?? .zero
    }

    func focus(for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let engine {
            BrowserMobileExtensions.shared.focus(engine)
        }
        completionHandler(nil)
    }
}

// MARK: - BrowserWebKitExtensionTab

/// One engine page, as extensions see a tab.
@MainActor final class BrowserWebKitExtensionTab: NSObject, WKWebExtensionTab {
    weak var engine: BrowserWebKitEngine?
    let runtimeID: String

    private var state: BrowserMobilePageState? { engine?.extensionPageState(id: runtimeID) }

    init(engine: BrowserWebKitEngine, runtimeID: String) {
        self.engine = engine
        self.runtimeID = runtimeID
    }

    func window(for _: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { engine?.extensionWindow }

    func indexInWindow(for _: WKWebExtensionContext) -> Int {
        engine?.extensionTabs.firstIndex { $0 === self } ?? 0
    }

    func webView(for _: WKWebExtensionContext) -> WKWebView? { engine?.webView(for: runtimeID) }

    func title(for _: WKWebExtensionContext) -> String? { state?.title }

    func url(for _: WKWebExtensionContext) -> URL? { state?.url }

    func isLoadingComplete(for _: WKWebExtensionContext) -> Bool { state?.isLoading != true }

    func isSelected(for _: WKWebExtensionContext) -> Bool { engine?.selectedExtensionTab === self }

    func isReaderModeAvailable(for _: WKWebExtensionContext) -> Bool { state?.canRead == true }

    func isReaderModeActive(for _: WKWebExtensionContext) -> Bool { state?.isReading == true }

    func setReaderModeActive(
        _ active: Bool, for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void,
    ) {
        engine?.setReading(id: runtimeID, active)
        completionHandler(nil)
    }

    func size(for _: WKWebExtensionContext) -> CGSize {
        engine?.webView(for: runtimeID)?.bounds.size ?? engine?.hostView.bounds.size ?? .zero
    }

    func zoomFactor(for _: WKWebExtensionContext) -> Double {
        Double(engine?.pageZoom(id: runtimeID) ?? 1)
    }

    func setZoomFactor(
        _ zoomFactor: Double, for _: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void,
    ) {
        engine?.setPageZoom(id: runtimeID, CGFloat(zoomFactor))
        completionHandler(nil)
    }

    func loadURL(
        _ url: URL, for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void,
    ) {
        engine?.navigate(id: runtimeID, url: url)
        completionHandler(nil)
    }

    func reload(
        fromOrigin _: Bool, for _: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void,
    ) {
        engine?.reload(id: runtimeID)
        completionHandler(nil)
    }

    func goBack(for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        engine?.goBack(id: runtimeID)
        completionHandler(nil)
    }

    func goForward(for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        engine?.goForward(id: runtimeID)
        completionHandler(nil)
    }

    func activate(for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        engine?.requestExtensionActivation(id: runtimeID)
        completionHandler(nil)
    }

    func setSelected(
        _ selected: Bool, for _: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void,
    ) {
        // One page shows at a time: selecting it activates it.
        if selected {
            engine?.requestExtensionActivation(id: runtimeID)
        }
        completionHandler(nil)
    }

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration, for _: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void,
    ) {
        let tab = engine?.openExtensionTab(url: state?.url, active: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func close(for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        engine?.closeTab(id: runtimeID)
        completionHandler(nil)
    }

    func takeSnapshot(
        using configuration: WKSnapshotConfiguration, for _: WKWebExtensionContext,
        completionHandler: @escaping (UIImage?, (any Error)?) -> Void,
    ) {
        guard let webView = engine?.webView(for: runtimeID) else {
            completionHandler(nil, nil)
            return
        }
        webView.takeSnapshot(with: configuration) { image, error in
            MainActor.assumeIsolated { completionHandler(image, error) }
        }
    }

    /// Clicks in a page count as consent for `activeTab`, as in other browsers.
    func shouldGrantPermissionsOnUserGesture(for _: WKWebExtensionContext) -> Bool { true }
}
