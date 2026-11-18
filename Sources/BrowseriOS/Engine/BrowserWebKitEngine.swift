// BrowserWebKitEngine.swift

import Foundation
import UIKit
import WebKit

// MARK: - BrowserWebKitEngine

/// Each scene owns its engine and views; persistent tab IDs belong to the model.
@MainActor final class BrowserWebKitEngine: NSObject, BrowserMobileEngine {
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

    private struct PendingAuthentication {
        let request: BrowserMobileHTTPAuthentication
        let generation: Int
        let webViewID: ObjectIdentifier
        let completion: @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    }

    private final class DownloadHandoff {
        // MARK: Internal

        let runtimeID: String
        let generation: Int
        weak var coordinator: BrowserMobileDownloads?
        let sourceURL: URL?

        init(record: Record, coordinator: BrowserMobileDownloads, sourceURL: URL?) {
            self.runtimeID = record.id
            self.generation = record.generation
            self.coordinator = coordinator
            self.sourceURL = sourceURL
        }
    }

    private final class Record {
        // MARK: Internal

        let id: String
        var webView: WKWebView?
        var state: BrowserMobilePageState
        var lastEmitted: BrowserMobilePageState?
        var observations = [NSKeyValueObservation]()
        var retryLoad: RetryLoad
        var committedState: BrowserMobilePageState?
        var committedRetryLoad: RetryLoad?
        var isRestoringDownloadedDocument = false
        var generation = 0
        var currentNavigation: WKNavigation?
        // Weak keys retain generation information while WebKit can deliver that
        // navigation, without an ever-growing set of canceled navigation IDs.
        let navigationGenerations = NSMapTable<WKNavigation, NSNumber>.weakToStrongObjects()
        var allowsPageMetadata = false
        var prefersDesktop = false
        var textZoom: CGFloat = 1
        var hasAppliedTextZoom = false
        var hasStartedCurrentNavigation = false
        var hasCommittedDialogDocument = false
        var isReplacingDialogDocument = false
        // Keep the accepted document URL independently of WKWebView.url and
        // WKFrameInfo, which can already report a fragment target before policy.
        var dialogDocumentURL: URL?

        init(id: String, url: URL?) {
            self.id = id
            self.state = BrowserMobilePageState(url: url)
            self.retryLoad = .url(url ?? URL(string: "about:blank")!)
        }
    }

    // MARK: Internal

    let hostView = UIView(frame: .zero)
    var onPopupCreated: ((String, URL?) -> Void)?

    var onEvent: ((BrowserMobileEngineEvent) -> Void)? {
        didSet {
            if onEvent == nil {
                dismissFindInPage()
                cancelJavaScriptDialog()
                cancelHTTPAuthentication(abort: false)
            }
        }
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
    private var pendingAuthentication: PendingAuthentication?
    private var isFinishingAuthentication = false
    private var downloads: BrowserMobileDownloads?
    private var obscuredInsets = UIEdgeInsets.zero
    private let actionDownloads = NSMapTable<WKNavigationAction, DownloadHandoff>.weakToStrongObjects()
    private let responseDownloads = NSMapTable<WKNavigationResponse, DownloadHandoff>.weakToStrongObjects()

    var isFindInPageVisible: Bool {
        mountedWebView?.findInteraction?.isFindNavigatorVisible == true
    }

    init(dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
        super.init()
    }

    private static func authenticationOrigin(_ space: URLProtectionSpace) -> String? {
        let unsafeHostScalars = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/\\?#@"))
        guard space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic, !space.isProxy(),
              let scheme = space.protocol?.lowercased(), scheme == "http" || scheme == "https",
              !space.host.isEmpty, (0...65535).contains(space.port),
              !space.host.unicodeScalars.contains(where: unsafeHostScalars.contains)
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = space.host
        if space.port > 0, !(scheme == "http" && space.port == 80), !(scheme == "https" && space.port == 443) {
            components.port = space.port
        }
        guard let url = components.url, url.host?.isEmpty == false else { return nil }
        return url.absoluteString
    }

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
        case "http",
             "https": url.host?.isEmpty == false
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

    func setDownloads(_ downloads: BrowserMobileDownloads?) {
        self.downloads = isShutDown ? nil : downloads
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
            dismissFindInPage()
            selectedRuntimeID = record?.id
            cancelJavaScriptDialog()
            cancelHTTPAuthentication(abort: false)
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
        } else if let webView = record.webView {
            begin(record, url: record.state.url) { webView.reload() }
        } else if let url = record.state.url {
            navigate(record: record, url: url)
        }
    }

    func stop(id: String) {
        guard let record = records[id] else { return }
        record.generation += 1
        record.isReplacingDialogDocument = false
        cancelJavaScriptDialog(runtimeID: id)
        cancelHTTPAuthentication(runtimeID: id)
        record.allowsPageMetadata = false
        record.hasStartedCurrentNavigation = false
        record.webView?.stopLoading()
        record.state.isLoading = false
        emit(record)
    }

    func closeTab(id: String) {
        guard let record = records.removeValue(forKey: id) else { return }
        if selectedRuntimeID == id {
            dismissFindInPage()
            selectedRuntimeID = nil
        }
        cancelJavaScriptDialog(runtimeID: id)
        cancelHTTPAuthentication(runtimeID: id)
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
        dismissFindInPage()
        isShutDown = true
        isDialogPresentationActive = false
        selectedRuntimeID = nil
        cancelJavaScriptDialog()
        cancelHTTPAuthentication()
        onEvent = nil
        onPopupCreated = nil
        downloads = nil
        actionDownloads.removeAllObjects()
        responseDownloads.removeAllObjects()
        for id in Array(records.keys) {
            closeTab(id: id)
        }
    }

    func snapshot(
        id: String, rect: CGRect?, width: CGFloat, completion: @escaping @MainActor (UIImage?) -> Void,
    ) {
        guard !isShutDown, let webView = records[id]?.webView, webView.bounds.width > 0, width > 0 else {
            completion(nil)
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        if let rect { configuration.rect = rect }
        configuration.snapshotWidth = NSNumber(value: Double(min(width, rect?.width ?? webView.bounds.width)))
        webView.takeSnapshot(with: configuration) { image, _ in
            MainActor.assumeIsolated { completion(image) }
        }
    }

    func setObscuredInsets(_ insets: UIEdgeInsets) {
        obscuredInsets = insets
        for record in records.values {
            record.webView?.obscuredContentInsets = insets
        }
    }

    func pageZoom(id: String) -> CGFloat {
        records[id]?.textZoom ?? 1
    }

    /// Scales the page's text, which reflows it; page zoom would keep the
    /// mobile layout's width and push the text past the screen's edge.
    func setPageZoom(id: String, _ zoom: CGFloat) {
        guard !isShutDown, let record = records[id] else { return }
        record.textZoom = zoom
        applyTextZoom(record)
    }

    func prefersDesktopSite(id: String) -> Bool {
        records[id]?.prefersDesktop ?? false
    }

    func setPrefersDesktopSite(id: String, _ prefersDesktop: Bool) {
        guard !isShutDown, let record = records[id], record.prefersDesktop != prefersDesktop else { return }
        record.prefersDesktop = prefersDesktop
        record.webView?.reloadFromOrigin()
    }

    func scrollView(id: String) -> UIScrollView? {
        isShutDown ? nil : records[id]?.webView?.scrollView
    }

    func iconURLs(id: String, completion: @escaping @MainActor ([URL]) -> Void) {
        guard !isShutDown, let record = records[id], let webView = record.webView,
              record.hasCommittedDialogDocument, !record.state.isLoading
        else {
            completion([])
            return
        }
        // SVG icons are drawn into a canvas in the page, since UIKit cannot
        // decode SVG; a cross-origin icon that taints the canvas stays a link.
        let script = """
        const links = Array.from(document.querySelectorAll(
          'link[rel~="icon"], link[rel~="apple-touch-icon"], link[rel~="apple-touch-icon-precomposed"]'));
        const rows = links.map(l => [l.href, l.rel, (l.sizes && l.sizes.value) || '', l.type || '']);
        for (const row of rows) {
          if (!(row[3].includes('svg') || /\\.svg([?#]|$)/i.test(row[0]))) continue;
          try {
            const image = new Image();
            image.src = row[0];
            await image.decode();
            const canvas = document.createElement('canvas');
            canvas.width = 96;
            canvas.height = 96;
            canvas.getContext('2d').drawImage(image, 0, 0, 96, 96);
            row[0] = canvas.toDataURL('image/png');
            row[2] = '96x96';
            row[3] = 'image/png';
          } catch (error) {}
        }
        return rows;
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
            MainActor.assumeIsolated {
                let rows = (try? result.get()) as? [[String]] ?? []
                completion(BrowserMobileFavicons.rankedIconURLs(rows, pageURL: webView.url))
            }
        }
    }

    func setJavaScriptDialogPresentationActive(_ active: Bool) {
        isDialogPresentationActive = active && !isShutDown
        if !isDialogPresentationActive {
            dismissFindInPage()
            cancelJavaScriptDialog()
            cancelHTTPAuthentication(abort: false)
        }
    }

    func canFindInPage(id: String) -> Bool {
        guard !isShutDown, isDialogPresentationActive, selectedRuntimeID == id, let record = records[id],
              record.hasCommittedDialogDocument, !record.isReplacingDialogDocument,
              !record.state.isLoading, record.state.error == nil, pendingDialog == nil, pendingAuthentication == nil,
              let webView = record.webView, mountedWebView === webView,
              webView.superview === hostView, let window = webView.window,
              !window.isHidden, window.windowScene?.activationState == .foregroundActive
        else { return false }
        return true
    }

    @discardableResult func presentFindInPage(id: String) -> Bool {
        guard canFindInPage(id: id), let webView = records[id]?.webView else { return false }
        webView.isFindInteractionEnabled = true
        guard let interaction = webView.findInteraction else { return false }
        guard !interaction.isFindNavigatorVisible else { return true }
        interaction.presentFindNavigator(showingReplace: false)
        return true
    }

    func dismissFindInPage() {
        guard let webView = mountedWebView else { return }
        webView.findInteraction?.dismissFindNavigator()
        // Disabled outside an admitted context so WebKit's own Cmd-F cannot
        // reopen a hidden, failed or competing page behind a modal.
        webView.isFindInteractionEnabled = false
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
        completion: @escaping @MainActor (BrowserMobileJavaScriptDialogResponse) -> Void,
    ) {
        guard !isShutDown, !isFinishingDialog, !isFinishingAuthentication, isDialogPresentationActive,
              pendingAuthentication == nil, let record = record(for: webView),
              record.hasCommittedDialogDocument, !record.isReplacingDialogDocument,
              selectedRuntimeID == record.id, pendingDialog == nil, onEvent != nil
        else { completion(.cancel)
            return
        }
        let request = BrowserMobileJavaScriptDialog(
            id: UUID(), runtimeID: record.id, origin: origin, message: message, kind: kind,
        )
        dismissFindInPage()
        pendingDialog = PendingDialog(request: request, generation: record.generation, completion: completion)
        onEvent?(.javaScriptDialogRequested(request))
    }

    func resolveHTTPAuthentication(id: UUID, response: BrowserMobileHTTPAuthenticationResponse) {
        guard let pending = pendingAuthentication, pending.request.id == id else { return }
        finishHTTPAuthentication(pending, response: response)
    }

    /// Shared by the real WKNavigationDelegate and engine tests. Basic auth may
    /// precede the first commit or belong to a subresource, so no committed-page
    /// requirement or top-level-origin comparison belongs here. WebKit supplies
    /// no navigation/frame identity; generation protects admitted tokens, not a
    /// challenge that first arrives after an unrelated navigation has begun.
    func requestHTTPAuthentication(
        in webView: WKWebView,
        challenge: URLAuthenticationChallenge,
        completion: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        guard let origin = Self.authenticationOrigin(challenge.protectionSpace) else {
            // Preserve WKNavigationDelegate's default for every unsupported
            // protection space, including server trust, Digest and proxy auth.
            completion(.rejectProtectionSpace, nil)
            return
        }
        guard !isFinishingAuthentication, !isFinishingDialog,
              pendingAuthentication == nil, pendingDialog == nil,
              let record = record(for: webView), canPresentHTTPAuthentication(record)
        else {
            // Unprompted challenges keep WebKit's default: no credential is
            // sent and the server's 401 document renders, so Reload can retry.
            completion(.rejectProtectionSpace, nil)
            return
        }
        let request = BrowserMobileHTTPAuthentication(
            id: UUID(), runtimeID: record.id, origin: origin,
            realm: challenge.protectionSpace.realm, previousFailureCount: challenge.previousFailureCount,
        )
        dismissFindInPage()
        pendingAuthentication = PendingAuthentication(
            request: request, generation: record.generation, webViewID: ObjectIdentifier(webView),
            completion: completion,
        )
        onEvent?(.httpAuthenticationRequested(request))
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

    private func applyTextZoom(_ record: Record) {
        guard let webView = record.webView, record.hasCommittedDialogDocument else { return }
        // A page that never had its size changed keeps the site's own rule.
        guard record.textZoom != 1 || record.hasAppliedTextZoom else { return }
        record.hasAppliedTextZoom = record.textZoom != 1
        let value = record.textZoom == 1 ? "" : "\(Int((record.textZoom * 100).rounded()))%"
        webView.evaluateJavaScript(
            "document.documentElement.style.webkitTextSizeAdjust = '\(value)'", in: nil, in: .defaultClient,
        )
    }

    private func canPresentHTTPAuthentication(_ record: Record) -> Bool {
        guard !isShutDown, isDialogPresentationActive, onEvent != nil,
              records[record.id] === record, selectedRuntimeID == record.id, record.state.error == nil,
              let webView = record.webView, mountedWebView === webView,
              webView.superview === hostView, !hostView.isHidden, !webView.isHidden,
              let window = webView.window, !window.isHidden,
              window.windowScene?.activationState == .foregroundActive
        else { return false }
        return true
    }

    /// `abort` cancels a challenged load that is being replaced or torn down.
    /// Otherwise the load stays wanted and the protection space is declined.
    private func cancelHTTPAuthentication(runtimeID: String? = nil, abort: Bool = true) {
        guard let pending = pendingAuthentication,
              runtimeID == nil || runtimeID == pending.request.runtimeID else { return }
        finishHTTPAuthentication(pending, response: abort ? nil : .cancel)
    }

    /// A nil response aborts the challenged load. Cancel, or credentials that
    /// can no longer be released, reject the protection space instead: WebKit
    /// renders the server's 401 document at the challenged address, as
    /// Chromium does after Cancel, and Reload can prompt again.
    private func finishHTTPAuthentication(
        _ pending: PendingAuthentication, response: BrowserMobileHTTPAuthenticationResponse?,
    ) {
        guard pendingAuthentication?.request.id == pending.request.id else { return }
        pendingAuthentication = nil
        isFinishingAuthentication = true
        defer { isFinishingAuthentication = false }
        onEvent?(.httpAuthenticationFinished(id: pending.request.id))
        // The finished observer may synchronously navigate or detach the scene.
        // Recheck afterwards before releasing any supplied credentials to WK.
        guard let response, !isShutDown,
              let record = records[pending.request.runtimeID], record.generation == pending.generation,
              let webView = record.webView, ObjectIdentifier(webView) == pending.webViewID
        else {
            pending.completion(.cancelAuthenticationChallenge, nil)
            return
        }
        guard case .credentials(let username, let password) = response, canPresentHTTPAuthentication(record) else {
            pending.completion(.rejectProtectionSpace, nil)
            return
        }
        pending.completion(.useCredential, URLCredential(user: username, password: password, persistence: .none))
    }

    private func cancelJavaScriptDialog(runtimeID: String? = nil) {
        guard let pending = pendingDialog,
              runtimeID == nil || runtimeID == pending.request.runtimeID else { return }
        finishJavaScriptDialog(pending, response: .cancel)
    }

    private func finishJavaScriptDialog(
        _ pending: PendingDialog, response: BrowserMobileJavaScriptDialogResponse,
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
        configuration suppliedConfiguration: WKWebViewConfiguration? = nil,
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
        webView.isFindInteractionEnabled = false
        webView.obscuredContentInsets = obscuredInsets
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
        _ keyPath: KeyPath<WKWebView, some Any>, webView: WKWebView, id: String,
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
                "This address is not supported. Enter an http or https address.", comment: "Unsupported mobile URL.",
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
        if record.isReplacingDialogDocument, selectedRuntimeID == record.id {
            dismissFindInPage()
        }
        record.generation += 1
        record.isRestoringDownloadedDocument = false
        cancelJavaScriptDialog(runtimeID: record.id)
        cancelHTTPAuthentication(runtimeID: record.id)
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
        if record.isRestoringDownloadedDocument, !webView.isLoading,
           webView.url == record.committedState?.url
        {
            record.isRestoringDownloadedDocument = false
            record.allowsPageMetadata = true
        }
        if record.allowsPageMetadata {
            record.state.url = webView.url ?? record.state.url
            record.state.title = webView.title ?? ""
        }
        if record.state.isLoading, record.hasStartedCurrentNavigation {
            record.state.progress = max(record.state.progress, webView.estimatedProgress)
        }
        record.state.canGoBack = webView.canGoBack
        record.state.canGoForward = webView.canGoForward
        if record.allowsPageMetadata {
            record.committedState = record.state
            record.committedRetryLoad = record.retryLoad
        }
        emit(record)
    }

    /// A response becoming a download never replaces the displayed document.
    /// Invalidate only that provisional navigation so its cancellation/error
    /// callbacks cannot publish the attachment URL or a page-load error.
    private func preservePageAfterDownloadConversion(_ record: Record) {
        record.generation += 1
        cancelHTTPAuthentication(runtimeID: record.id)
        record.currentNavigation = nil
        record.allowsPageMetadata = false
        record.hasStartedCurrentNavigation = false
        record.isReplacingDialogDocument = false
        record.isRestoringDownloadedDocument = record.committedState != nil
        record.state = record.committedState ?? BrowserMobilePageState(url: URL(string: "about:blank"))
        record.state.isLoading = false
        record.state.error = nil
        record.state.progress = record.hasCommittedDialogDocument ? 1 : 0
        record.dialogDocumentURL = record.committedState?.url
        if let retryLoad = record.committedRetryLoad {
            record.retryLoad = retryLoad
        }
        emit(record)
    }

    private func adoptDownload(_ download: WKDownload, handoff: DownloadHandoff?, webView: WKWebView) {
        guard !isShutDown, let handoff, let coordinator = handoff.coordinator,
              downloads === coordinator, let record = record(for: webView),
              record.id == handoff.runtimeID, record.generation == handoff.generation
        else {
            download.cancel { _ in }
            return
        }
        // Bind the profile-owned WKDownloadDelegate before returning to WebKit;
        // this preserves the original request's cookies, body and credentials.
        coordinator.adopt(download, sourceURL: handoff.sourceURL)
    }

    private func emit(_ record: Record) {
        if record.state.error != nil, selectedRuntimeID == record.id {
            dismissFindInPage()
            cancelHTTPAuthentication(runtimeID: record.id)
        }
        guard records[record.id] === record, record.lastEmitted != record.state else { return }
        record.lastEmitted = record.state
        onEvent?(.state(id: record.id, record.state))
    }

    private func fail(_ error: Error, webView: WKWebView, navigation: WKNavigation?) {
        guard let record = currentRecord(for: webView, navigation: navigation) else { return }
        cancelHTTPAuthentication(runtimeID: record.id)
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
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        requestHTTPAuthentication(in: webView, challenge: challenge, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void,
    ) {
        let prefersDesktop = record(for: webView)?.prefersDesktop == true
        self.webView(webView, decidePolicyFor: navigationAction) { policy in
            if navigationAction.targetFrame?.isMainFrame != false {
                preferences.preferredContentMode = prefersDesktop ? .desktop : .mobile
            }
            decisionHandler(policy, preferences)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void,
    ) {
        guard let record = record(for: webView), !isShutDown else {
            decisionHandler(.cancel)
            return
        }
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        let isGeneratedDownload = scheme == "blob" || scheme == "data"
        if navigationAction.shouldPerformDownload, Self.isAllowed(navigationAction) || isGeneratedDownload {
            guard let downloads else {
                decisionHandler(.cancel)
                return
            }
            // Generated files are allowed only through WebKit's explicit
            // download intent. Never retain their payload/token in provenance.
            let sourceURL = isGeneratedDownload ? record.committedState?.url : navigationAction.request.url
            actionDownloads.setObject(
                DownloadHandoff(record: record, coordinator: downloads, sourceURL: sourceURL),
                forKey: navigationAction,
            )
            decisionHandler(.download)
            return
        }
        guard Self.isAllowed(navigationAction)
        else {
            if navigationAction.targetFrame?.isMainFrame != false {
                record.state.error = NSLocalizedString(
                    "This link requires an unsupported app or browser page. Open another web address.",
                    comment: "Unsupported mobile navigation.",
                )
                emit(record)
            }
            decisionHandler(.cancel)
            return
        }
        if let frame = navigationAction.targetFrame, frame.isMainFrame {
            record.isReplacingDialogDocument = !Self.isFragmentNavigation(
                from: record.dialogDocumentURL, to: navigationAction.request.url,
            )
            if record.isReplacingDialogDocument, selectedRuntimeID == record.id {
                dismissFindInPage()
            }
            if record.isReplacingDialogDocument {
                record.allowsPageMetadata = false
            }
            if !record.isReplacingDialogDocument {
                record.dialogDocumentURL = navigationAction.request.url
                if record.isRestoringDownloadedDocument {
                    record.isRestoringDownloadedDocument = false
                    record.allowsPageMetadata = true
                }
            }
            cancelJavaScriptDialog(runtimeID: record.id)
            cancelHTTPAuthentication(runtimeID: record.id)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void,
    ) {
        guard let record = record(for: webView), !isShutDown else {
            decisionHandler(.cancel)
            return
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard navigationResponse.isForMainFrame,
              disposition == "attachment" || !navigationResponse.canShowMIMEType
        else {
            decisionHandler(.allow)
            return
        }
        preservePageAfterDownloadConversion(record)
        guard let downloads else {
            decisionHandler(.cancel)
            return
        }
        responseDownloads.setObject(
            DownloadHandoff(record: record, coordinator: downloads, sourceURL: navigationResponse.response.url),
            forKey: navigationResponse,
        )
        decisionHandler(.download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let handoff = actionDownloads.object(forKey: navigationAction)
        actionDownloads.removeObject(forKey: navigationAction)
        adoptDownload(download, handoff: handoff, webView: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let handoff = responseDownloads.object(forKey: navigationResponse)
        responseDownloads.removeObject(forKey: navigationResponse)
        adoptDownload(download, handoff: handoff, webView: webView)
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
        cancelHTTPAuthentication(runtimeID: record.id)
        record.isRestoringDownloadedDocument = false
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
        record.hasAppliedTextZoom = false
        applyTextZoom(record)
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
        record.isRestoringDownloadedDocument = false
        record.isReplacingDialogDocument = false
        record.dialogDocumentURL = nil
        cancelJavaScriptDialog(runtimeID: record.id)
        cancelHTTPAuthentication(runtimeID: record.id)
        record.allowsPageMetadata = false
        record.hasStartedCurrentNavigation = false
        record.state.isLoading = false
        record.state.error = NSLocalizedString(
            "The page stopped responding. Tap Reload to try again.", comment: "WebKit process recovery.",
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
        completionHandler: @escaping @MainActor () -> Void,
    ) {
        requestJavaScriptDialog(in: webView, kind: .alert, message: message, origin: Self.dialogOrigin(frame)) { _ in
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void,
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
        completionHandler: @escaping @MainActor (String?) -> Void,
    ) {
        requestJavaScriptDialog(
            in: webView, kind: .prompt(defaultText: defaultText), message: prompt, origin: Self.dialogOrigin(frame),
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
        windowFeatures _: WKWindowFeatures,
    ) -> WKWebView? {
        guard record(for: webView) != nil, navigationAction.targetFrame == nil else { return nil }
        return adoptPopup(configuration: configuration, url: navigationAction.request.url)
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let record = record(for: webView) else { return }
        closeTab(id: record.id)
    }
}
