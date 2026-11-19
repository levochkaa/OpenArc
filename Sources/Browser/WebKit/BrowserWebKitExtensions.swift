// BrowserWebKitExtensions.swift

import AppKit
import WebKit

// MARK: - BrowserWebKitExtensionHost

/// One profile's extensions for its WebKit pages: the ones Chromium installed
/// in the profile, loaded from their unpacked folders and kept on or off as
/// Chromium keeps them, and Firefox add-ons the user added for WebKit pages.
///
/// The profile's WebKit pages are the tabs of two extension windows, one for
/// normal pages and one for private ones.
@MainActor final class BrowserWebKitExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    // MARK: Private

    private final class WeakPage {
        weak var page: BrowserWebKitPage?
        let tab: BrowserWebKitExtensionPageTab

        init(page: BrowserWebKitPage, tab: BrowserWebKitExtensionPageTab) {
            self.page = page
            self.tab = tab
        }
    }

    private static var hosts = [String: BrowserWebKitExtensionHost]()

    private static var unsupported: NSError {
        NSError(
            domain: "OpenArcExtensions", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "WebKit pages do not support this yet."],
        )
    }

    // MARK: Internal

    let library: BrowserWebExtensionLibrary

    private let profileKey: String
    private lazy var normalWindow = BrowserWebKitExtensionPageWindow(host: self, isPrivate: false)
    private lazy var privateWindow = BrowserWebKitExtensionPageWindow(host: self, isPrivate: true)
    private var pages = [WeakPage]()
    private weak var focusedPage: BrowserWebKitPage?
    private var observation: (any NSObjectProtocol)?

    var controller: WKWebExtensionController { library.controller }

    /// The Firefox add-ons for WebKit pages, for View › Add-ons in WebKit Pages.
    var addons: [BrowserWebExtensionRecord] { library.records.filter { $0.source == .firefoxAddons } }

    private init(profileKey: String) {
        self.profileKey = profileKey
        let root = URL(fileURLWithPath: profileKey, isDirectory: true)
            .appendingPathComponent("WebKit Extensions", isDirectory: true)
        self.library = BrowserWebExtensionLibrary(
            rootURL: root,
            controllerIdentifier: BrowserWebKitPage.storeIdentifier(forProfileKey: "extensions." + profileKey),
        )
        super.init()
        library.controller.delegate = self
        controller.didOpenWindow(normalWindow)
        controller.didOpenWindow(privateWindow)
        self.observation = NotificationCenter.default.addObserver(
            forName: .browserChromiumExtensionsDidChange, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.syncChromiumExtensions() }
            }
        }
        Task {
            await library.loadAll()
            await syncChromiumExtensions()
            await library.checkForUpdates()
        }
    }

    /// The host whose controller a page's configuration carries.
    static func host(for controller: WKWebExtensionController?) -> BrowserWebKitExtensionHost? {
        guard let controller else { return nil }
        return hosts.values.first { $0.controller === controller }
    }

    /// The profile's host, made on first use. `profileKey` is the profile's
    /// Chromium data path.
    static func host(forProfileKey profileKey: String) -> BrowserWebKitExtensionHost {
        if let host = hosts[profileKey] {
            return host
        }
        let host = BrowserWebKitExtensionHost(profileKey: profileKey)
        hosts[profileKey] = host
        return host
    }

    private static func run(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    /// Loads, unloads and switches Chromium's extensions to match its profile.
    func syncChromiumExtensions() async {
        let directories = BrowserChromiumProfileDirectoryResolver.profileDirectoryCandidates(
            profileDirectoryURL: URL(fileURLWithPath: profileKey, isDirectory: true),
        )
        let files = BrowserExtensionProfileSnapshotStore.installedExtensionFiles(profileDirectories: directories)
        await library.syncExternal(files.map {
            (
                id: $0.id, name: $0.name, version: $0.version, directory: $0.directory, isEnabled: $0.isEnabled,
                allowsPrivateBrowsing: $0.allowsIncognito,
            )
        })
        for (id, error) in library.loadErrors {
            webExtensionLog.notice("WebKit pages skip \(id, privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: Pages

    func register(_ page: BrowserWebKitPage) {
        pages.removeAll { $0.page == nil || $0.page === page }
        let tab = BrowserWebKitExtensionPageTab(page: page, host: self)
        pages.append(WeakPage(page: page, tab: tab))
        controller.didOpenTab(tab)
    }

    func unregister(_ page: BrowserWebKitPage) {
        guard let index = pages.firstIndex(where: { $0.page === page }) else { return }
        let entry = pages.remove(at: index)
        controller.didCloseTab(entry.tab)
        pages.removeAll { $0.page == nil }
    }

    func focus(_ page: BrowserWebKitPage) {
        guard let tab = tab(for: page), focusedPage !== page else { return }
        let previous = focusedPage.flatMap { self.tab(for: $0) }
        focusedPage = page
        controller.didActivateTab(tab, previousActiveTab: previous)
        controller.didFocusWindow(window(isPrivate: page.isEphemeral))
    }

    func pageChanged(_ page: BrowserWebKitPage, _ properties: WKWebExtension.TabChangedProperties) {
        guard let tab = tab(for: page) else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }

    func tabs(isPrivate: Bool) -> [BrowserWebKitExtensionPageTab] {
        pages.compactMap { entry in
            guard let page = entry.page, page.isEphemeral == isPrivate else { return nil }
            return entry.tab
        }
    }

    func activeTab(isPrivate: Bool) -> BrowserWebKitExtensionPageTab? {
        if let focusedPage, focusedPage.isEphemeral == isPrivate {
            return tab(for: focusedPage)
        }
        return tabs(isPrivate: isPrivate).last
    }

    func window(isPrivate: Bool) -> BrowserWebKitExtensionPageWindow {
        isPrivate ? privateWindow : normalWindow
    }

    // MARK: Firefox add-ons

    /// Downloads an AMO add-on, asks for its permissions in an alert, and
    /// installs it for this profile's WebKit pages.
    func installAddon(_ item: BrowserWebExtensionStoreItem, window: NSWindow?) async {
        do {
            let pending = try await library.prepareInstall(item)
            let alert = NSAlert()
            alert.messageText = String(format: BrowserStrings.webKitAddonPromptTitle, pending.name)
            var lines = [BrowserStrings.webKitAddonPartiallyCompatible]
            lines += pending.permissionLines.map { "• " + $0 }
            if !pending.unsupportedFeatures.isEmpty {
                lines += ["", BrowserStrings.webKitAddonUnsupported]
                lines += pending.unsupportedFeatures.map { "• " + $0 }
            }
            alert.informativeText = lines.joined(separator: "\n")
            alert.icon = pending.webExtension.icon(for: CGSize(width: 64, height: 64))
            alert.addButton(withTitle: BrowserStrings.webKitAddonAdd)
            alert.addButton(withTitle: BrowserStrings.cancelAction)
            if await Self.run(alert, window: window) == .alertFirstButtonReturn {
                try await library.commit(pending)
            } else {
                library.discard(pending)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = BrowserStrings.webKitAddonFailed
            alert.informativeText = error.localizedDescription
            _ = await Self.run(alert, window: window)
        }
    }

    /// Asks before removing an add-on.
    func confirmRemoval(id: String, window: NSWindow?) async {
        guard let record = library.record(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = String(format: BrowserStrings.webKitAddonRemoveTitle, record.name)
        alert.addButton(withTitle: BrowserStrings.webKitAddonRemove)
        alert.addButton(withTitle: BrowserStrings.cancelAction)
        if await Self.run(alert, window: window) == .alertFirstButtonReturn {
            library.remove(id: id)
        }
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(
        _: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext,
    ) -> [any WKWebExtensionWindow] {
        context.hasAccessToPrivateData ? [normalWindow, privateWindow] : [normalWindow]
    }

    func webExtensionController(
        _: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext,
    ) -> (any WKWebExtensionWindow)? {
        let isPrivate = focusedPage?.isEphemeral ?? false
        return isPrivate && !context.hasAccessToPrivateData ? nil : window(isPrivate: isPrivate)
    }

    func webExtensionController(
        _: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for _: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void,
    ) {
        // A new tab opens through the page that is showing; it stays a web page.
        guard let url = configuration.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let page = focusedPage ?? pages.last?.page
        else {
            completionHandler(nil, Self.unsupported)
            return
        }
        page.openInNewTab(url: url, inBackground: !configuration.shouldBeActive)
        completionHandler(nil, nil)
    }

    func webExtensionController(
        _: WKWebExtensionController,
        promptForPermissions _: Set<WKWebExtension.Permission>,
        in _: (any WKWebExtensionTab)?,
        for _: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void,
    ) {
        // Chromium's prompt granted what the extension has; WebKit pages add nothing.
        completionHandler([], nil)
    }

    func webExtensionController(
        _: WKWebExtensionController,
        promptForPermissionMatchPatterns _: Set<WKWebExtension.MatchPattern>,
        in _: (any WKWebExtensionTab)?,
        for _: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void,
    ) {
        completionHandler([], nil)
    }

    private func tab(for page: BrowserWebKitPage) -> BrowserWebKitExtensionPageTab? {
        pages.first { $0.page === page }?.tab
    }
}

// MARK: - BrowserWebKitExtensionPageWindow

/// A profile's WebKit pages, normal or private, as one extension window.
@MainActor final class BrowserWebKitExtensionPageWindow: NSObject, WKWebExtensionWindow {
    private weak var host: BrowserWebKitExtensionHost?
    private let isPrivateWindow: Bool

    init(host: BrowserWebKitExtensionHost, isPrivate: Bool) {
        self.host = host
        self.isPrivateWindow = isPrivate
    }

    func tabs(for _: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        host?.tabs(isPrivate: isPrivateWindow) ?? []
    }

    func activeTab(for _: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        host?.activeTab(isPrivate: isPrivateWindow)
    }

    func windowType(for _: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for _: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }

    func isPrivate(for _: WKWebExtensionContext) -> Bool { isPrivateWindow }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        (activeTab(for: context) as? BrowserWebKitExtensionPageTab)?.page?.view.window?.frame ?? .zero
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (activeTab(for: context) as? BrowserWebKitExtensionPageTab)?.page?.view.window?.screen?.frame ?? .zero
    }
}

// MARK: - BrowserWebKitExtensionPageTab

/// One WebKit page, as extensions see a tab.
@MainActor final class BrowserWebKitExtensionPageTab: NSObject, WKWebExtensionTab {
    weak var page: BrowserWebKitPage?

    private weak var host: BrowserWebKitExtensionHost?

    init(page: BrowserWebKitPage, host: BrowserWebKitExtensionHost) {
        self.page = page
        self.host = host
    }

    func window(for _: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let page else { return nil }
        return host?.window(isPrivate: page.isEphemeral)
    }

    func indexInWindow(for _: WKWebExtensionContext) -> Int {
        guard let page else { return 0 }
        return host?.tabs(isPrivate: page.isEphemeral).firstIndex { $0 === self } ?? 0
    }

    func webView(for _: WKWebExtensionContext) -> WKWebView? { page?.extensionWebView }

    func title(for _: WKWebExtensionContext) -> String? { page?.title }

    func url(for _: WKWebExtensionContext) -> URL? { page.flatMap { URL(string: $0.urlString) } }

    func isLoadingComplete(for _: WKWebExtensionContext) -> Bool { page?.isLoading != true }

    func isSelected(for _: WKWebExtensionContext) -> Bool {
        guard let page else { return false }
        return host?.activeTab(isPrivate: page.isEphemeral) === self
    }

    func loadURL(_ url: URL, for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        page?.load(urlString: url.absoluteString)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        page?.reload(ignoringCache: fromOrigin)
        completionHandler(nil)
    }

    func goBack(for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        page?.goBack()
        completionHandler(nil)
    }

    func goForward(for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        page?.goForward()
        completionHandler(nil)
    }

    func close(for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        page?.requestCloseForExtension()
        completionHandler(nil)
    }

    func takeSnapshot(
        using configuration: WKSnapshotConfiguration, for _: WKWebExtensionContext,
        completionHandler: @escaping (NSImage?, (any Error)?) -> Void,
    ) {
        guard let webView = page?.extensionWebView else {
            completionHandler(nil, nil)
            return
        }
        webView.takeSnapshot(with: configuration) { image, error in completionHandler(image, error) }
    }

    func shouldGrantPermissionsOnUserGesture(for _: WKWebExtensionContext) -> Bool { true }
}
