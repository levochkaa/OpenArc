// BrowserWebKitPage.swift

import AppKit
import CryptoKit
import WebKit

// MARK: - BrowserWebKitPageDelegate

/// What a WebKit page tells the tab controller. Every call is on the main thread.
@MainActor @objc protocol BrowserWebKitPageDelegate: AnyObject {
    func webKitPageDidChangeTitle(_ page: BrowserWebKitPage)
    func webKitPageDidChangeURL(_ page: BrowserWebKitPage)
    func webKitPageDidChangeLoading(_ page: BrowserWebKitPage)
    func webKitPageDidChangeNavigationState(_ page: BrowserWebKitPage)
    func webKitPage(_ page: BrowserWebKitPage, didChangeFaviconURLString urlString: String?)
    /// A page opened a window; the new page must use `configuration`. Nil refuses it.
    func webKitPage(
        _ page: BrowserWebKitPage,
        createPageWith configuration: WKWebViewConfiguration,
        urlString: String,
        inBackground: Bool,
    ) -> BrowserWebKitPage?
    /// A Command-click or middle click: the link opens in a new tab, in the background.
    func webKitPage(_ page: BrowserWebKitPage, openURLStringInNewTab urlString: String, inBackground: Bool)
    func webKitPageDidRequestClose(_ page: BrowserWebKitPage)
    func webKitPage(
        _ page: BrowserWebKitPage,
        didChangeMediaAudible audible: Bool,
        playing: Bool,
        paused: Bool,
        video: Bool,
        title: String,
    )
    func webKitPage(_ page: BrowserWebKitPage, didChangeFullscreen fullscreen: Bool)
    func webKitPage(_ page: BrowserWebKitPage, didChangeCaptureVideo video: Bool, audio: Bool)
    func webKitPage(_ page: BrowserWebKitPage, didFindMatch found: Bool)
    func webKitPageDidBecomeFocused(_ page: BrowserWebKitPage)
}

// MARK: - BrowserWebKitPage

/// One tab's page in WebKit, for sites that play protected video with FairPlay.
/// Each profile keeps its own persistent website data; a private window keeps none.
@MainActor @objc final class BrowserWebKitPage: NSObject {
    // MARK: Private

    private static let mediaMessageName = "openArcMedia"

    private static let ephemeralStore = WKWebsiteDataStore.nonPersistent()

    private static var dataStores = [UUID: WKWebsiteDataStore]()

    /// The version WebKit pages name in their user agent, as Safari does, so
    /// sites serve them what they serve Safari.
    private static let safariApplicationName: String = {
        let safari = Bundle(path: "/Applications/Safari.app")
        let version = safari?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? ProcessInfo.processInfo.operatingSystemVersion.majorVersion.description + ".0"
        return "Version/\(version) Safari/605.1.15"
    }()

    // MARK: Internal

    @objc weak var delegate: BrowserWebKitPageDelegate?

    private let webView: BrowserWebKitWebView
    private let mediaToken: String
    private var observations = [NSKeyValueObservation]()
    private var mediaVolume = 1.0
    private var isClosed = false

    @objc var view: NSView { webView }

    @objc var title: String { webView.title ?? "" }

    @objc var urlString: String { webView.url?.absoluteString ?? "" }

    @objc var isLoading: Bool { webView.isLoading }

    @objc var canGoBack: Bool { webView.canGoBack }

    @objc var canGoForward: Bool { webView.canGoForward }

    @objc var isFullscreen: Bool {
        webView.fullscreenState == .inFullscreen || webView.fullscreenState == .enteringFullscreen
    }

    /// Chromium's zoom level: 0 is 100 %, each step is 20 %.
    @objc var zoomLevel: Double {
        get { log(Double(webView.pageZoom)) / log(1.2) }
        set { webView.pageZoom = CGFloat(pow(1.2, newValue)) }
    }

    /// Past and next pages, oldest first, with the current page's index.
    @objc var navigationEntries: [[String: String]] {
        let list = webView.backForwardList
        let items = list.backList + [list.currentItem].compactMap(\.self) + list.forwardList
        return items.map { ["url": $0.url.absoluteString, "title": $0.title ?? ""] }
    }

    @objc var currentNavigationIndex: Int { webView.backForwardList.backList.count }

    /// The certificates of the page's connection, leaf first, as DER.
    @objc var certificateChain: [Data] {
        guard let trust = webView.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return [] }
        return chain.map { SecCertificateCopyData($0) as Data }
    }

    /// A page of its own, with the profile's data store.
    @objc convenience init(profileKey: String?, ephemeral: Bool) {
        let configuration = Self.configuration(
            dataStore: ephemeral ? Self.ephemeralStore : Self.dataStore(forProfileKey: profileKey ?? ""),
        )
        self.init(configuration: configuration)
    }

    /// A page with WebKit's configuration for a window another page opened.
    @objc init(configuration: WKWebViewConfiguration) {
        let mediaToken = "__openArcMedia" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        self.mediaToken = mediaToken
        let controller = configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllScriptMessageHandlers()
        controller.addUserScript(WKUserScript(
            source: Self.mediaObserverScript(token: mediaToken),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
        ))
        configuration.applicationNameForUserAgent = Self.safariApplicationName
        self.webView = BrowserWebKitWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(BrowserWebKitMessageProxy(page: self), name: Self.mediaMessageName)
        webView.page = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        observe()
    }

    /// A UUID made from the profile's data path, the same on every launch.
    static func storeIdentifier(forProfileKey profileKey: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("openarc.webkit.\(profileKey)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        ))
    }

    private static func dataStore(forProfileKey profileKey: String) -> WKWebsiteDataStore {
        let identifier = storeIdentifier(forProfileKey: profileKey)
        if let store = dataStores[identifier] {
            return store
        }
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        dataStores[identifier] = store
        return store
    }

    private static func configuration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        return configuration
    }

    /// Reports the page's media to the sidebar, as the Chromium pages' observer
    /// does, and answers the sidebar's controls through a property only this
    /// app knows the name of.
    private static func mediaObserverScript(token: String) -> String {
        """
        (() => {
          'use strict';
          if (window.top !== window) return;
          const post = (state) => { try { window.webkit.messageHandlers.\(
              mediaMessageName
          ).postMessage(state); } catch (e) {} };
          const proto = HTMLMediaElement.prototype;
          const nativePlay = proto.play;
          const tracked = new Set();
          let volume = 1;
          let last = '';
          let timer = 0;
          const actions = new Map();
          const session = navigator.mediaSession;
          if (session && typeof session.setActionHandler === 'function') {
            const nativeSet = session.setActionHandler;
            session.setActionHandler = function (action, handler) {
              if (handler) actions.set(action, handler); else actions.delete(action);
              return nativeSet.call(this, action, handler);
            };
          }
          function evaluate() {
            let playing = false, paused = false, audible = false, video = false;
            for (const media of tracked) {
              if (!media.isConnected && media.paused) { tracked.delete(media); continue; }
              if (!media.paused && !media.ended) {
                playing = true;
                audible = audible || (!media.muted && media.volume > 0);
                video = video || (media instanceof HTMLVideoElement && media.videoWidth > 0);
              } else if (!media.ended && media.currentTime > 0) {
                paused = true;
              }
            }
            const metadata = session && session.metadata;
            const state = [audible, playing, paused && !playing, video, metadata && metadata.title ? String(metadata.title) : ''];
            const key = JSON.stringify(state);
            if (key !== last) { last = key; post(state); }
            clearTimeout(timer);
            timer = playing ? setTimeout(evaluate, 1000) : 0;
          }
          function track(media) {
            if (!(media instanceof HTMLMediaElement)) return;
            if (!tracked.has(media)) {
              tracked.add(media);
              for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) media.addEventListener(type, () => queueMicrotask(evaluate));
              if (volume !== 1) media.volume = Math.min(1, media.volume * volume);
            }
            queueMicrotask(evaluate);
          }
          proto.play = function () { track(this); return nativePlay.apply(this, arguments); };
          addEventListener('play', (event) => track(event.target), true);
          addEventListener('playing', (event) => track(event.target), true);
          Object.defineProperty(window, '\(token)', { value: (action, argument) => {
            if (action === 'volume') {
              volume = argument;
              for (const media of tracked) media.volume = Math.min(1, argument);
              return;
            }
            const handler = actions.get(action);
            if (handler) { handler({ action }); return; }
            for (const media of tracked) {
              if (action === 'pause' && !media.paused) media.pause();
              if (action === 'play' && media.paused && media.currentTime > 0) nativePlay.call(media).catch(() => {});
            }
          } });
        })();
        """
    }

    private static func text(of value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        case nil, is NSNull: nil
        default:
            (try? JSONSerialization.data(withJSONObject: value as Any, options: [.fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    private static func jsonString(_ string: String) -> String? {
        (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    @objc func load(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }

    @objc func go(toHistoryOffset offset: Int) {
        if let item = webView.backForwardList.item(at: offset) {
            webView.go(to: item)
        }
    }

    @objc func reload(ignoringCache: Bool) {
        if ignoringCache {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    @objc func stopLoading() { webView.stopLoading() }

    @objc func focus() {
        webView.window?.makeFirstResponder(webView)
    }

    @objc func evaluate(_ script: String, completion: @escaping @MainActor (String?) -> Void) {
        webView.evaluateJavaScript(script) { value, _ in
            completion(Self.text(of: value))
        }
    }

    @objc func find(_ text: String, forward: Bool, matchCase: Bool) {
        guard !text.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = matchCase
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in
            guard let self else { return }
            delegate?.webKitPage(self, didFindMatch: result.matchFound)
        }
    }

    @objc func stopFinding() {
        webView.evaluateJavaScript("getSelection().removeAllRanges()", completionHandler: nil)
    }

    @objc func setAudioMuted(_ muted: Bool) {
        // `_setPageMuted:` takes _WKMediaMutedState, whose audio bit is 1.
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector), let method = webView.method(for: selector) else { return }
        typealias SetMuted = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(method, to: SetMuted.self)(webView, selector, muted ? 1 : 0)
    }

    @objc func setMediaVolume(_ volume: Double) {
        mediaVolume = volume
        webView.evaluateJavaScript("window.\(mediaToken)?.('volume', \(volume))", completionHandler: nil)
    }

    /// play, pause, previoustrack or nexttrack.
    @objc func controlMedia(_ action: String) {
        guard let argument = Self.jsonString(action) else { return }
        webView.evaluateJavaScript("window.\(mediaToken)?.(\(argument))", completionHandler: nil)
    }

    @objc func togglePictureInPicture() {
        webView.evaluateJavaScript(
            """
            (() => { const v = [...document.querySelectorAll('video')].find((e) => !e.paused) || document.querySelector('video');
            if (v && v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture'))
            v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture'); })()
            """,
            completionHandler: nil,
        )
    }

    @objc func exitFullscreen() {
        webView.evaluateJavaScript("document.fullscreenElement && document.exitFullscreen()", completionHandler: nil)
    }

    @objc func selectedText(completion: @escaping @MainActor (String?) -> Void) {
        evaluate("getSelection().toString()", completion: completion)
    }

    @objc func capturePicture(completion: @escaping @MainActor (Data?) -> Void) {
        webView.takeSnapshot(with: nil) { image, _ in
            completion(image.flatMap(Self.pngData))
        }
    }

    /// The part of the page in `fraction` of its view, y downward.
    @objc func capturePicture(fraction: CGRect, completion: @escaping @MainActor (Data?) -> Void) {
        let bounds = webView.bounds
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(
            x: bounds.width * fraction.minX,
            y: bounds.height * fraction.minY,
            width: bounds.width * fraction.width,
            height: bounds.height * fraction.height,
        )
        webView.takeSnapshot(with: configuration) { image, _ in
            completion(image.flatMap(Self.pngData))
        }
    }

    @objc func print() {
        guard let window = webView.window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Stops the page for good: media, scripts and pending loads.
    @objc func close() {
        guard !isClosed else { return }
        isClosed = true
        observations.removeAll()
        webView.stopLoading()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        webView.loadHTMLString("", baseURL: nil)
    }

    // MARK: Fileprivate

    fileprivate func receiveMediaMessage(_ body: Any) {
        guard let values = body as? [Any], values.count == 5 else { return }
        delegate?.webKitPage(
            self,
            didChangeMediaAudible: values[0] as? Bool ?? false,
            playing: values[1] as? Bool ?? false,
            paused: values[2] as? Bool ?? false,
            video: values[3] as? Bool ?? false,
            title: values[4] as? String ?? "",
        )
    }

    fileprivate func webViewDidBecomeFirstResponder() {
        delegate?.webKitPageDidBecomeFocused(self)
    }

    private func observe() {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self.map { $0.delegate?.webKitPageDidChangeTitle($0) } }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self.map { $0.delegate?.webKitPageDidChangeURL($0) } }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self.map { $0.delegate?.webKitPageDidChangeLoading($0) } }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self.map { $0.delegate?.webKitPageDidChangeNavigationState($0) } }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self.map { $0.delegate?.webKitPageDidChangeNavigationState($0) } }
            },
            webView.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in
                MainActor
                    .assumeIsolated { self.map { $0.delegate?.webKitPage($0, didChangeFullscreen: $0.isFullscreen) } }
            },
            webView.observe(\.cameraCaptureState, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reportCapture() }
            },
            webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reportCapture() }
            },
        ]
    }

    private func reportCapture() {
        delegate?.webKitPage(
            self,
            didChangeCaptureVideo: webView.cameraCaptureState == .active,
            audio: webView.microphoneCaptureState == .active,
        )
    }

    private func reportFavicon() {
        let script = """
        (() => { const link = [...document.querySelectorAll('link[rel~="icon" i]')].pop();
        return link ? link.href : new URL('/favicon.ico', location.href).href; })()
        """
        evaluate(script) { [weak self] urlString in
            guard let self, !isClosed else { return }
            delegate?.webKitPage(self, didChangeFaviconURLString: urlString)
        }
    }
}

// MARK: WKNavigationDelegate

extension BrowserWebKitPage: WKNavigationDelegate {
    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void,
    ) {
        decisionHandler(policy(for: navigationAction))
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void,
    ) {
        decisionHandler(navigationResponse.canShowMIMEType || !navigationResponse.isForMainFrame ? .allow : .download)
    }

    private func policy(for navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        let request = navigationAction.request
        guard let url = request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) {
            // Another app's link, such as mailto: or an app's own scheme.
            if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame?.isMainFrame != false {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false {
            let flags = navigationAction.modifierFlags
            if flags.contains(.command) || navigationAction.buttonNumber == 2 {
                delegate?.webKitPage(
                    self,
                    openURLStringInNewTab: url.absoluteString,
                    inBackground: !flags.contains(.shift),
                )
                return .cancel
            }
        }
        return navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_: WKWebView, navigationAction _: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = BrowserWebKitDownloads.shared
    }

    func webView(_: WKWebView, navigationResponse _: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = BrowserWebKitDownloads.shared
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        reportFavicon()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        webView.reload()
    }
}

// MARK: WKUIDelegate

extension BrowserWebKitPage: WKUIDelegate {
    func webView(
        _: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures,
    ) -> WKWebView? {
        let urlString = navigationAction.request.url?.absoluteString ?? ""
        let background = navigationAction.modifierFlags.contains(.command) &&
            !navigationAction.modifierFlags.contains(.shift)
        return delegate?.webKitPage(
            self,
            createPageWith: configuration,
            urlString: urlString,
            inBackground: background,
        )?.webView
    }

    func webViewDidClose(_: WKWebView) {
        delegate?.webKitPageDidRequestClose(self)
    }

    func webView(
        _: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
    ) async {
        _ = await presentDialog(message: message, frame: frame, buttons: [BrowserStrings.webKitDialogOK], field: nil)
    }

    func webView(
        _: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
    ) async -> Bool {
        let answer = await presentDialog(
            message: message,
            frame: frame,
            buttons: [BrowserStrings.webKitDialogOK, BrowserStrings.webKitDialogCancel],
            field: nil,
        )
        return answer.button == .alertFirstButtonReturn
    }

    func webView(
        _: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
    ) async -> String? {
        let answer = await presentDialog(
            message: prompt,
            frame: frame,
            buttons: [BrowserStrings.webKitDialogOK, BrowserStrings.webKitDialogCancel],
            field: defaultText ?? "",
        )
        return answer.button == .alertFirstButtonReturn ? answer.text : nil
    }

    func webView(
        _: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame _: WKFrameInfo,
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else {
            return panel.runModal() == .OK ? panel.urls : nil
        }
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }

    private func presentDialog(
        message: String,
        frame: WKFrameInfo,
        buttons: [String],
        field: String?,
    ) async -> (button: NSApplication.ModalResponse, text: String) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty
            ? BrowserStrings.webKitDialogTitle
            : frame.securityOrigin.host
        alert.informativeText = message
        for title in buttons {
            alert.addButton(withTitle: title)
        }
        var input: NSTextField?
        if let field {
            let textField = NSTextField(string: field)
            textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = textField
            input = textField
        }
        guard let window = webView.window else {
            let response = alert.runModal()
            return (response, input?.stringValue ?? "")
        }
        let response = await alert.beginSheetModal(for: window)
        return (response, input?.stringValue ?? "")
    }
}

// MARK: - BrowserWebKitWebView

/// Tells its page when it takes the keyboard, so a click in a Split View pane focuses it.
final class BrowserWebKitWebView: WKWebView {
    weak var page: BrowserWebKitPage?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            page?.webViewDidBecomeFirstResponder()
        }
        return accepted
    }
}

// MARK: - BrowserWebKitMessageProxy

/// Holds the page weakly: WebKit keeps its message handlers alive.
private final class BrowserWebKitMessageProxy: NSObject, WKScriptMessageHandler {
    // MARK: Private

    private weak var page: BrowserWebKitPage?

    init(page: BrowserWebKitPage) {
        self.page = page
    }

    // MARK: Internal

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.frameInfo.isMainFrame else { return }
            page?.receiveMediaMessage(message.body)
        }
    }
}

// MARK: - BrowserWebKitDownloads

/// Saves files WebKit pages download into the download folder, under a name not yet taken.
@MainActor final class BrowserWebKitDownloads: NSObject, WKDownloadDelegate {
    static let shared = BrowserWebKitDownloads()

    func download(
        _: WKDownload,
        decideDestinationUsing _: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void,
    ) {
        completionHandler(destination(suggestedFilename: suggestedFilename))
    }

    private func destination(suggestedFilename: String) -> URL? {
        let folder = URL(fileURLWithPath: BrowserDownloadLocation.directoryPath(), isDirectory: true)
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = pathExtension.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(pathExtension)"
            candidate = folder.appendingPathComponent(numbered)
            index += 1
        }
        return candidate
    }
}
