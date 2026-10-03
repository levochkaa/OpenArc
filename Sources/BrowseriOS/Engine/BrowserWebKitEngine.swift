import Foundation
import UIKit
import WebKit

// MARK: - BrowserWebKitEngine

/// Each scene owns its engine and views; persistent tab IDs belong to the model.
@MainActor final class BrowserWebKitEngine: NSObject, BrowserMobileEngine {
    // MARK: Lifecycle

    init(dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
        super.init()
    }

    // MARK: Internal

    let hostView = UIView(frame: .zero)
    var onPopupCreated: ((String, URL?) -> Void)?

    var onEvent: ((BrowserMobileEngineEvent) -> Void)? {
        didSet {
            if onEvent == nil {
                cancelJavaScriptDialog()
            }
        }
    }

    func createTab(id: String, url: URL) {
        guard !isShutDown, records[id] == nil else { return }
        // Restoring a workspace must not launch a WebKit page for every saved
        // tab. A selected tab or an explicit navigation creates its view.
        let record = Record(id: id, url: url)
        records[id] = record
        emit(record)
    }

    func selectTab(id: String?) {
        guard !isShutDown else { return }
        let record = id.flatMap { records[$0] }
        if selectedRuntimeID != record?.id {
            selectedRuntimeID = record?.id
            cancelJavaScriptDialog()
        }
        let startsInitialLoad = record?.webView == nil
        let next = record.map { ensureWebView($0) }
        guard mountedWebView !== next else { return }
        mountedWebView?.removeFromSuperview()
        mountedWebView = next
        guard let next else { return }
        next.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(next)
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            next.topAnchor.constraint(equalTo: hostView.topAnchor),
            next.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])
        if startsInitialLoad, let record, let url = record.state.url {
            navigate(record: record, url: url)
        }
    }

    func navigate(id: String, url: URL) {
        guard let record = records[id] else { return }
        navigate(record: record, url: url)
    }

    func goBack(id: String) {
        guard let record = records[id], let webView = record.webView,
              let item = webView.backForwardList.backItem else { return }
        begin(record, url: item.url) { webView.goBack() }
    }

    func goForward(id: String) {
        guard let record = records[id], let webView = record.webView,
              let item = webView.backForwardList.forwardItem else { return }
        begin(record, url: item.url) { webView.goForward() }
    }

    func reload(id: String) {
        guard let record = records[id] else { return }
        if record.state.error != nil {
            switch record.retryLoad {
            case .url(let url): navigate(record: record, url: url)
            case .html(let html, let baseURL): loadHTMLString(html, baseURL: baseURL, id: id)
            }
        } else {
            if let webView = record.webView {
                begin(record, url: record.state.url) { webView.reload() }
            } else if let url = record.state.url {
                navigate(record: record, url: url)
            }
        }
    }

    func stop(id: String) {
        guard let record = records[id] else { return }
        record.generation += 1
        record.isReplacingDialogDocument = false
        cancelJavaScriptDialog(runtimeID: id)
        record.allowsPageMetadata = false
        record.hasStartedCurrentNavigation = false
        record.webView?.stopLoading()
        record.state.isLoading = false
        emit(record)
    }

    func closeTab(id: String) {
        guard let record = records.removeValue(forKey: id) else { return }
        if selectedRuntimeID == id {
            selectedRuntimeID = nil
        }
        cancelJavaScriptDialog(runtimeID: id)
        if let webView = record.webView {
            idsByWebView.removeValue(forKey: ObjectIdentifier(webView))
        }
        record.observations.forEach { $0.invalidate() }
        record.observations.removeAll()
        record.webView?.navigationDelegate = nil
        record.webView?.uiDelegate = nil
        record.webView?.stopLoading()
        record.webView?.removeFromSuperview()
        if mountedWebView === record.webView {
            mountedWebView = nil
        }
        onEvent?(.closed(id: id))
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        isDialogPresentationActive = false
        selectedRuntimeID = nil
        cancelJavaScriptDialog()
        onEvent = nil
        onPopupCreated = nil
        for id in Array(records.keys) {
            closeTab(id: id)
        }
    }

    func setJavaScriptDialogPresentationActive(_ active: Bool) {
        isDialogPresentationActive = active && !isShutDown
        if !isDialogPresentationActive {
            cancelJavaScriptDialog()
        }
    }

    func resolveJavaScriptDialog(id: UUID, response: BrowserMobileJavaScriptDialogResponse) {
        guard let pending = pendingDialog, pending.request.id == id else { return }
        let isCurrent = !isShutDown && isDialogPresentationActive
            && selectedRuntimeID == pending.request.runtimeID
            && records[pending.request.runtimeID]?.generation == pending.generation
        finishJavaScriptDialog(pending, response: isCurrent ? response : .cancel)
    }

    /// The delegate and tests share this admission/completion boundary. There is
    /// no waiting queue: a hidden, busy or detached scene responds neutrally.
    func requestJavaScriptDialog(
        in webView: WKWebView,
        kind: BrowserMobileJavaScriptDialog.Kind,
        message: String,
        origin: String,
        completion: @escaping @MainActor (BrowserMobileJavaScriptDialogResponse) -> Void
    ) {
        guard !isShutDown, !isFinishingDialog, isDialogPresentationActive, let record = record(for: webView),
              record.hasCommittedDialogDocument, !record.isReplacingDialogDocument,
              selectedRuntimeID == record.id, pendingDialog == nil, onEvent != nil
        else { completion(.cancel)
            return
        }
        let request = BrowserMobileJavaScriptDialog(
            id: UUID(), runtimeID: record.id, origin: origin, message: message, kind: kind
        )
        pendingDialog = PendingDialog(request: request, generation: record.generation, completion: completion)
        onEvent?(.javaScriptDialogRequested(request))
    }

    /// Local-document seam for integration tests; production addresses use navigate.
    @discardableResult func loadHTMLString(_ html: String, baseURL: URL?, id: String) -> WKNavigation? {
        guard let record = records[id] else { return nil }
        let webView = ensureWebView(record)
        record.retryLoad = .html(html, baseURL)
        return begin(record, url: baseURL ?? URL(string: "about:blank")) {
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(for id: String) -> WKWebView? { records[id]?.webView }

    /// Shared by WKUIDelegate and tests. WebKit performs the popup load itself.
    func adoptPopup(configuration: WKWebViewConfiguration, url: URL?) -> WKWebView? {
        guard !isShutDown, let onPopupCreated, url.map(Self.isAllowed) ?? true else { return nil }
        let id = UUID().uuidString
        let record = Record(id: id, url: url)
        records[id] = record
        let webView = ensureWebView(record, configuration: configuration)
        onPopupCreated(id, url)
        // Adoption can synchronously close the popup or shut down this scene.
        guard records[id] === record else { return nil }
        return webView
    }

    // MARK: Private

    private enum RetryLoad {
        case url(URL)
        case html(String, URL?)
    }

    private struct PendingDialog {
        let request: BrowserMobileJavaScriptDialog
        let generation: Int
        let completion: @MainActor (BrowserMobileJavaScriptDialogResponse) -> Void
    }

    private final class Record {
        // MARK: Lifecycle

        init(id: String, url: URL?) {
            self.id = id
            self.state = BrowserMobilePageState(url: url)
            self.retryLoad = .url(url ?? URL(string: "about:blank")!)
        }

        // MARK: Internal

        let id: String
        var webView: WKWebView?
        var state: BrowserMobilePageState
        var lastEmitted: BrowserMobilePageState?
        var observations = [NSKeyValueObservation]()
        var retryLoad: RetryLoad
        var generation = 0
        var currentNavigation: WKNavigation?
        // Weak keys retain generation information while WebKit can deliver that
        // navigation, without an ever-growing set of canceled navigation IDs.
        let navigationGenerations = NSMapTable<WKNavigation, NSNumber>.weakToStrongObjects()
        var allowsPageMetadata = false
        var hasStartedCurrentNavigation = false
        var hasCommittedDialogDocument = false
        var isReplacingDialogDocument = false
        // Keep the accepted document URL independently of WKWebView.url and
        // WKFrameInfo, which can already report a fragment target before policy.
        var dialogDocumentURL: URL?
    }

    private let dataStore: WKWebsiteDataStore
    private var records = [String: Record]()
    private var idsByWebView = [ObjectIdentifier: String]()
    private weak var mountedWebView: WKWebView?
    private var isShutDown = false
    private var selectedRuntimeID: String?
    private var isDialogPresentationActive = false
    private var pendingDialog: PendingDialog?
    private var isFinishingDialog = false

    private static func dialogOrigin(_ frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        guard !origin.host.isEmpty, !origin.protocol.isEmpty else {
            return String(localized: "Unknown origin", table: "Mobile")
        }
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port > 0,
           !(origin.protocol == "https" && origin.port == 443),
           !(origin.protocol == "http" && origin.port == 80)
        {
            components.port = origin.port
        }
        return components.string ?? origin.host
    }

    private static func isFragmentNavigation(from previous: URL?, to next: URL?) -> Bool {
        guard let previous, let next, previous != next,
              var previousParts = URLComponents(url: previous, resolvingAgainstBaseURL: false),
              var nextParts = URLComponents(url: next, resolvingAgainstBaseURL: false)
        else { return false }
        previousParts.fragment = nil
        nextParts.fragment = nil
        return previousParts == nextParts
    }

    private static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": url.host?.isEmpty == false
        case "about": url.absoluteString.lowercased().split(separator: "#").first == "about:blank"
        default: false
        }
    }

    private static func isAllowed(_ action: WKNavigationAction) -> Bool {
        guard let url = action.request.url else { return false }
        if Self.isAllowed(url) {
            return true
        }
        // srcdoc is an embedded HTML document, not an address the browser can
        // open as a top-level page or external application.
        return action.targetFrame?.isMainFrame == false
            && url.absoluteString.lowercased().split(separator: "#").first == "about:srcdoc"
    }

    private func cancelJavaScriptDialog(runtimeID: String? = nil) {
        guard let pending = pendingDialog,
              runtimeID == nil || runtimeID == pending.request.runtimeID else { return }
        finishJavaScriptDialog(pending, response: .cancel)
    }

    private func finishJavaScriptDialog(
        _ pending: PendingDialog, response: BrowserMobileJavaScriptDialogResponse
    ) {
        guard pendingDialog?.request.id == pending.request.id else { return }
        // Remove ownership before either callback can reenter or answer twice.
        pendingDialog = nil
        isFinishingDialog = true
        defer { isFinishingDialog = false }
        onEvent?(.javaScriptDialogFinished(id: pending.request.id))
        pending.completion(response)
    }

    private func ensureWebView(
        _ record: Record,
        configuration suppliedConfiguration: WKWebViewConfiguration? = nil
    ) -> WKWebView {
        if let webView = record.webView {
            return webView
        }
        let configuration: WKWebViewConfiguration
        if let suppliedConfiguration {
            configuration = suppliedConfiguration
        } else {
            configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = dataStore
            configuration.allowsInlineMediaPlayback = true
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        record.webView = webView
        let id = record.id
        idsByWebView[ObjectIdentifier(webView)] = id
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        record.observations = [
            observe(\.title, webView: webView, id: id),
            observe(\.url, webView: webView, id: id),
            observe(\.isLoading, webView: webView, id: id),
            observe(\.estimatedProgress, webView: webView, id: id),
            observe(\.canGoBack, webView: webView, id: id),
            observe(\.canGoForward, webView: webView, id: id),
        ]
        return webView
    }

    private func observe(
        _ keyPath: KeyPath<WKWebView, some Any>, webView: WKWebView, id: String
    ) -> NSKeyValueObservation {
        webView.observe(keyPath, options: [.new]) { [weak self, weak webView] _, _ in
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, let record = records[id], record.webView === webView else { return }
                // Read current properties, never a value captured by an older KVO delivery.
                refresh(record)
            }
        }
    }

    private func navigate(record: Record, url: URL) {
        guard Self.isAllowed(url) else {
            record.state.error = NSLocalizedString(
                "This address is not supported. Enter an http or https address.", comment: "Unsupported mobile URL."
            )
            emit(record)
            return
        }
        record.retryLoad = .url(url)
        let webView = ensureWebView(record)
        begin(record, url: url) { webView.load(URLRequest(url: url)) }
    }

    @discardableResult private func begin(_ record: Record, url: URL?, load: () -> WKNavigation?) -> WKNavigation? {
        // A canceled modal can resume the old document while its replacement
        // is still provisional. Only commit admits the new document's scripts.
        record.isReplacingDialogDocument = !Self.isFragmentNavigation(from: record.dialogDocumentURL, to: url)
        record.generation += 1
        cancelJavaScriptDialog(runtimeID: record.id)
        record.allowsPageMetadata = false
        record.hasStartedCurrentNavigation = false
        record.state.url = url
        record.state.title = ""
        record.state.error = nil
        record.state.isLoading = true
        record.state.progress = 0
        let navigation = load()
        record.currentNavigation = navigation
        if let navigation {
            record.navigationGenerations.setObject(NSNumber(value: record.generation), forKey: navigation)
        } else {
            record.state.isLoading = false
        }
        emit(record)
        return navigation
    }

    private func record(for webView: WKWebView) -> Record? {
        guard let id = idsByWebView[ObjectIdentifier(webView)],
              let record = records[id], record.webView === webView
        else { return nil }
        return record
    }

    private func currentRecord(for webView: WKWebView, navigation: WKNavigation?) -> Record? {
        guard let record = record(for: webView), let navigation,
              record.navigationGenerations.object(forKey: navigation)?.intValue == record.generation
        else { return nil }
        return record
    }

    private func refresh(_ record: Record) {
        guard let webView = record.webView else { return }
        if record.allowsPageMetadata {
            record.state.url = webView.url ?? record.state.url
            record.state.title = webView.title ?? ""
        }
        if record.state.isLoading, record.hasStartedCurrentNavigation {
            record.state.progress = max(record.state.progress, webView.estimatedProgress)
        }
        record.state.canGoBack = webView.canGoBack
        record.state.canGoForward = webView.canGoForward
        emit(record)
    }

    private func emit(_ record: Record) {
        guard records[record.id] === record, record.lastEmitted != record.state else { return }
        record.lastEmitted = record.state
        onEvent?(.state(id: record.id, record.state))
    }

    private func fail(_ error: Error, webView: WKWebView, navigation: WKNavigation?) {
        guard let record = currentRecord(for: webView, navigation: navigation) else { return }
        record.state.isLoading = false
        // A failed provisional load leaves the previous committed document.
        record.isReplacingDialogDocument = false
        let nsError = error as NSError
        if !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            record.state.error = nsError.localizedDescription
            if let failedURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
               Self.isAllowed(failedURL)
            {
                record.state.url = failedURL
                record.retryLoad = .url(failedURL)
            }
        }
        refresh(record)
    }
}

// MARK: WKNavigationDelegate

extension BrowserWebKitEngine: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard record(for: webView) != nil, Self.isAllowed(navigationAction)
        else {
            if let record = record(for: webView), navigationAction.targetFrame?.isMainFrame != false {
                record.state.error = NSLocalizedString(
                    "This link requires an unsupported app or browser page. Open another web address.",
                    comment: "Unsupported mobile navigation."
                )
                emit(record)
            }
            decisionHandler(.cancel)
            return
        }
        if let frame = navigationAction.targetFrame, frame.isMainFrame,
           let record = record(for: webView)
        {
            record.isReplacingDialogDocument = !Self.isFragmentNavigation(
                from: record.dialogDocumentURL, to: navigationAction.request.url
            )
            if !record.isReplacingDialogDocument {
                record.dialogDocumentURL = navigationAction.request.url
            }
            cancelJavaScriptDialog(runtimeID: record.id)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        guard let record = record(for: webView), let navigation else { return }
        if let generation = record.navigationGenerations.object(forKey: navigation) {
            guard generation.intValue == record.generation else { return }
        } else {
            // Links/forms and WebKit-created popups have no load() return value.
            record.generation += 1
            record.navigationGenerations.setObject(NSNumber(value: record.generation), forKey: navigation)
            record.currentNavigation = navigation
        }
        cancelJavaScriptDialog(runtimeID: record.id)
        record.allowsPageMetadata = false
        record.hasStartedCurrentNavigation = true
        record.state.isLoading = true
        record.state.error = nil
        record.state.progress = 0
        refresh(record)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation?) {
        guard let record = currentRecord(for: webView, navigation: navigation) else { return }
        // Preserve the requested URL until this navigation commits.
        refresh(record)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        guard let record = currentRecord(for: webView, navigation: navigation) else { return }
        record.hasCommittedDialogDocument = true
        record.isReplacingDialogDocument = false
        record.dialogDocumentURL = webView.url
        record.allowsPageMetadata = true
        if case .url = record.retryLoad, let url = webView.url {
            record.retryLoad = .url(url)
        }
        refresh(record)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard let record = currentRecord(for: webView, navigation: navigation) else { return }
        record.allowsPageMetadata = true
        record.state.isLoading = false
        record.state.progress = 1
        refresh(record)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        fail(error, webView: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        fail(error, webView: webView, navigation: navigation)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let record = record(for: webView) else { return }
        record.generation += 1
        record.hasCommittedDialogDocument = false
        record.isReplacingDialogDocument = false
        record.dialogDocumentURL = nil
        cancelJavaScriptDialog(runtimeID: record.id)
        record.allowsPageMetadata = false
        record.hasStartedCurrentNavigation = false
        record.state.isLoading = false
        record.state.error = NSLocalizedString(
            "The page stopped responding. Tap Reload to try again.", comment: "WebKit process recovery."
        )
        emit(record)
    }
}

// MARK: WKUIDelegate

extension BrowserWebKitEngine: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        requestJavaScriptDialog(in: webView, kind: .alert, message: message, origin: Self.dialogOrigin(frame)) { _ in
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        requestJavaScriptDialog(in: webView, kind: .confirm, message: message, origin: Self.dialogOrigin(frame)) {
            response in
            if case .accept = response {
                completionHandler(true)
            } else {
                completionHandler(false)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        requestJavaScriptDialog(
            in: webView, kind: .prompt(defaultText: defaultText), message: prompt, origin: Self.dialogOrigin(frame)
        ) { response in
            switch response {
            case .accept(let text): completionHandler(text ?? "")
            case .cancel: completionHandler(nil)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        guard record(for: webView) != nil, navigationAction.targetFrame == nil else { return nil }
        return adoptPopup(configuration: configuration, url: navigationAction.request.url)
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let record = record(for: webView) else { return }
        closeTab(id: record.id)
    }
}
