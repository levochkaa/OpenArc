// BrowserMobileExtensions.swift

import Combine
import UIKit
import WebKit

// MARK: - BrowserMobileExtensions

/// The app's extensions: one WebKit controller for every window's pages, the
/// installed extensions behind it, and the prompts and popups they show.
///
/// Each scene's `BrowserWebKitEngine` is an extension window; its pages are
/// the window's tabs.
@MainActor final class BrowserMobileExtensions: NSObject, WKWebExtensionControllerDelegate {
    // MARK: Private

    private final class WeakEngine {
        weak var engine: BrowserWebKitEngine?

        init(_ engine: BrowserWebKitEngine) { self.engine = engine }
    }

    // MARK: Internal

    static let shared: BrowserMobileExtensions = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BrowserMobileExtensions(
            library: BrowserWebExtensionLibrary(
                rootURL: support.appendingPathComponent("WebExtensions", isDirectory: true),
                controllerIdentifier: BrowserWebExtensionLibrary.controllerIdentifier(
                    key: "BrowserMobileExtensions.controllerIdentifier",
                ),
                // Extensions tell browsers apart by `Safari/` in the user agent;
                // WKWebView's own has none.
                applicationName: "Version/\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0 "
                    + "Mobile/15E148 Safari/604.1",
            ),
        )
    }()

    let library: BrowserWebExtensionLibrary

    private let actionChanges = PassthroughSubject<Void, Never>()
    private var engines = [WeakEngine]()
    private weak var focusedEngine: BrowserWebKitEngine?
    private weak var popupSourceView: UIView?
    private var hasStarted = false
    private var installsInFlight = Set<String>()

    var controller: WKWebExtensionController { library.controller }

    /// Fires when extensions, their actions or their badges change.
    var changes: AnyPublisher<Void, Never> { library.changes.merge(with: actionChanges).eraseToAnyPublisher() }

    init(library: BrowserWebExtensionLibrary) {
        self.library = library
        super.init()
        library.controller.delegate = self
        library.adaptsBackgroundsForIOS = true
    }

    static func presenter(for view: UIView?) -> UIViewController? {
        guard var controller = view?.window?.rootViewController else { return nil }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }

    static func showError(_ error: Error, title: String, on presenter: UIViewController) {
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK", table: "Mobile"), style: .default))
        presenter.present(alert, animated: true)
    }

    private static func unsupported(_ message: String) -> NSError {
        NSError(domain: "OpenArcExtensions", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Loads the installed extensions, then checks for updates if a day has passed.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            await library.loadAll()
            await library.checkForUpdates()
        }
    }

    // MARK: Windows

    func register(_ engine: BrowserWebKitEngine) {
        engines.removeAll { $0.engine == nil || $0.engine === engine }
        engines.append(WeakEngine(engine))
        if focusedEngine == nil { focusedEngine = engine }
        if let window = engine.extensionWindow {
            controller.didOpenWindow(window)
        }
    }

    func unregister(_ engine: BrowserWebKitEngine) {
        engines.removeAll { $0.engine == nil || $0.engine === engine }
        if let window = engine.extensionWindow {
            controller.didCloseWindow(window)
        }
        if focusedEngine === engine {
            focusedEngine = engines.compactMap(\.engine).last
            controller.didFocusWindow(focusedEngine?.extensionWindow)
        }
    }

    func focus(_ engine: BrowserWebKitEngine) {
        guard focusedEngine !== engine else { return }
        focusedEngine = engine
        controller.didFocusWindow(engine.extensionWindow)
    }

    // MARK: Store pages

    /// The store item a page shows, unless it is installed already.
    func installableItem(for url: URL?) -> BrowserWebExtensionStoreItem? {
        guard let url, let item = BrowserWebExtensionStoreItem(pageURL: url) else { return nil }
        let installed = library.records.contains {
            $0.source == item.source && ($0.storeIdentifier == item.identifier || $0.id == item.identifier)
        }
        return installed || installsInFlight.contains(item.identifier) ? nil : item
    }

    /// Downloads the store page's extension, asks for its permissions and installs it.
    func install(_ item: BrowserWebExtensionStoreItem, from view: UIView, completion: @escaping () -> Void = {}) {
        guard let presenter = Self.presenter(for: view), installsInFlight.insert(item.identifier).inserted else {
            return
        }
        actionChanges.send()
        let progress = UIAlertController(
            title: String(localized: "Downloading Extension…", table: "Mobile"), message: nil, preferredStyle: .alert,
        )
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let pending = try await library.prepareInstall(item)
                await progress.dismissAsync()
                let approved = await BrowserMobileExtensionInstallViewController.ask(pending, presenter: presenter)
                if approved {
                    try await library.commit(pending)
                } else {
                    library.discard(pending)
                }
            } catch is CancellationError {
                await progress.dismissAsync()
            } catch {
                await progress.dismissAsync()
                Self.showError(error, title: String(localized: "Extension Not Added", table: "Mobile"), on: presenter)
            }
            installsInFlight.remove(item.identifier)
            actionChanges.send()
            completion()
        }
        progress.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel) { _ in
            task.cancel()
        })
        presenter.present(progress, animated: true)
    }

    /// Each running extension's action for a window's selected tab.
    func actions(in engine: BrowserWebKitEngine) -> [(
        record: BrowserWebExtensionRecord,
        action: WKWebExtension.Action,
    )] {
        let tab = engine.selectedExtensionTab
        return library.loadedContexts.compactMap { entry in
            guard tab == nil || !engine.isEphemeral || entry.context.hasAccessToPrivateData,
                  let action = entry.context.action(for: tab) else { return nil }
            return (entry.record, action)
        }
    }

    /// Runs an extension's action on the window's selected tab; a popup opens
    /// from `sourceView`.
    func performAction(id: String, in engine: BrowserWebKitEngine, from sourceView: UIView) {
        guard let context = library.context(id: id) else { return }
        popupSourceView = sourceView
        focus(engine)
        context.performAction(for: engine.selectedExtensionTab)
    }

    /// Opens an extension's options page in a sheet.
    func showOptions(id: String, from presenter: UIViewController) {
        guard let context = library.context(id: id), let url = context.optionsPageURL,
              let configuration = context.webViewConfiguration else { return }
        let page = BrowserMobileExtensionPageViewController(
            url: url, configuration: configuration, title: library.record(id: id)?.name,
        )
        presenter.present(UINavigationController(rootViewController: page), animated: true)
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(
        _: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext,
    ) -> [any WKWebExtensionWindow] {
        let windows = engines.compactMap(\.engine).filter { !$0.isEphemeral || context.hasAccessToPrivateData }
        let ordered = windows.sorted { first, _ in first === focusedEngine }
        return ordered.compactMap(\.extensionWindow)
    }

    func webExtensionController(
        _: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext,
    ) -> (any WKWebExtensionWindow)? {
        guard let engine = focusedEngine, !engine.isEphemeral || context.hasAccessToPrivateData else { return nil }
        return engine.extensionWindow
    }

    func webExtensionController(
        _: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void,
    ) {
        let engine = (configuration.window as? BrowserWebKitExtensionWindow)?.engine ?? focusedEngine
        guard let engine else {
            completionHandler(nil, Self.unsupported("No window is open."))
            return
        }
        guard let url = configuration.url else {
            completionHandler(engine.openExtensionTab(url: nil, active: configuration.shouldBeActive), nil)
            return
        }
        if url.scheme == context.baseURL.scheme, let configuration = context.webViewConfiguration {
            // Tabs hold web pages; an extension's own pages open in a sheet.
            let page = BrowserMobileExtensionPageViewController(
                url: url, configuration: configuration, title: context.webExtension.displayName,
            )
            Self.presenter(for: engine.hostView)?.present(
                UINavigationController(rootViewController: page), animated: true,
            )
            completionHandler(nil, nil)
            return
        }
        completionHandler(engine.openExtensionTab(url: url, active: configuration.shouldBeActive), nil)
    }

    func webExtensionController(
        _: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for _: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void,
    ) {
        // One window per scene: a new window's tabs open in the focused one.
        guard let engine = focusedEngine else {
            completionHandler(nil, Self.unsupported("No window is open."))
            return
        }
        for (index, url) in configuration.tabURLs.enumerated() {
            _ = engine.openExtensionTab(url: url, active: index == 0)
        }
        completionHandler(engine.extensionWindow, nil)
    }

    func webExtensionController(
        _: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void,
    ) {
        guard let record = library.record(for: context),
              let presenter = Self.presenter(for: focusedEngine?.hostView)
        else {
            completionHandler(Self.unsupported("No window is open."))
            return
        }
        showOptions(id: record.id, from: presenter)
        completionHandler(nil)
    }

    func webExtensionController(
        _: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in _: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void,
    ) {
        let lines = BrowserWebExtensionPermissionText.lines(
            permissions: Set(permissions.map(\.rawValue)), matchPatterns: [],
        )
        ask(context: context, lines: lines.isEmpty ? permissions.map(\.rawValue).sorted() : lines) { [weak self] in
            guard $0 else { return completionHandler([], nil) }
            if let id = self?.library.record(for: context)?.id {
                self?.library.grant(id: id, permissions: permissions.map(\.rawValue))
            }
            completionHandler(permissions, nil)
        }
    }

    func webExtensionController(
        _: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in _: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void,
    ) {
        let hosts = urls.compactMap { $0.host() }.sorted()
        let line = BrowserWebExtensionPermissionText.sitesLine(hosts.map { "*://\($0)/*" })
        ask(context: context, lines: line.map { [$0] } ?? hosts) { [weak self] in
            guard $0 else { return completionHandler([], nil) }
            if let id = self?.library.record(for: context)?.id {
                self?.library.grant(id: id, matchPatterns: hosts.map { "*://\($0)/*" })
            }
            completionHandler(urls, nil)
        }
    }

    func webExtensionController(
        _: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in _: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void,
    ) {
        let strings = matchPatterns.map(\.string).sorted()
        let line = BrowserWebExtensionPermissionText.sitesLine(strings)
        ask(context: context, lines: line.map { [$0] } ?? strings) { [weak self] in
            guard $0 else { return completionHandler([], nil) }
            if let id = self?.library.record(for: context)?.id {
                self?.library.grant(id: id, matchPatterns: strings)
            }
            completionHandler(matchPatterns, nil)
        }
    }

    func webExtensionController(
        _: WKWebExtensionController, didUpdate _: WKWebExtension.Action, forExtensionContext _: WKWebExtensionContext,
    ) {
        actionChanges.send()
    }

    func webExtensionController(
        _: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
        for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void,
    ) {
        let source = popupSourceView ?? focusedEngine?.hostView
        popupSourceView = nil
        guard let popup = action.popupViewController, let presenter = Self.presenter(for: source) else {
            completionHandler(Self.unsupported("The popup has no window to open in."))
            return
        }
        if presenter.traitCollection.horizontalSizeClass == .regular, let source {
            popup.modalPresentationStyle = .popover
            popup.popoverPresentationController?.sourceView = source
            popup.popoverPresentationController?.sourceRect = source.bounds
            if popup.preferredContentSize == .zero {
                popup.preferredContentSize = CGSize(width: 360, height: 520)
            }
        } else {
            popup.modalPresentationStyle = .pageSheet
            popup.sheetPresentationController?.detents = [.medium(), .large()]
            popup.sheetPresentationController?.prefersGrabberVisible = true
        }
        presenter.present(popup, animated: true)
        completionHandler(nil)
    }

    func webExtensionController(
        _: WKWebExtensionController, sendMessage _: Any, toApplicationWithIdentifier _: String?,
        for _: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void,
    ) {
        replyHandler(nil, Self.unsupported("OpenArc has no native app for this extension."))
    }

    func webExtensionController(
        _: WKWebExtensionController, connectUsing _: WKWebExtension.MessagePort, for _: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void,
    ) {
        completionHandler(Self.unsupported("OpenArc has no native app for this extension."))
    }

    private func ask(context: WKWebExtensionContext, lines: [String], completion: @escaping (Bool) -> Void) {
        guard let presenter = Self.presenter(for: focusedEngine?.hostView) else { return completion(false) }
        let name = library.record(for: context)?.name ?? context.webExtension.displayName ?? ""
        let alert = UIAlertController(
            title: String(localized: "Allow “\(name)” to:", table: "Mobile"),
            message: lines.map { "• " + $0 }.joined(separator: "\n"),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "Don’t Allow", table: "Mobile"), style: .cancel) { _ in
            completion(false)
        })
        alert.addAction(UIAlertAction(title: String(localized: "Allow", table: "Mobile"), style: .default) { _ in
            completion(true)
        })
        presenter.present(alert, animated: true)
    }
}

// MARK: - UIViewController

@MainActor extension UIViewController {
    /// Dismisses this controller if it is presented, waiting for the animation.
    func dismissAsync() async {
        guard presentingViewController != nil else { return }
        await withCheckedContinuation { continuation in
            dismiss(animated: true) { continuation.resume() }
        }
    }
}
