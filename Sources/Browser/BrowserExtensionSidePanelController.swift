// BrowserExtensionSidePanelController.swift

import AppKit
import Foundation

// MARK: - BrowserExtensionSidePanelController

@MainActor final class BrowserExtensionSidePanelController: NSObject, BrowserExtensionSidePanelDriving {
    // MARK: Internal

    var onPanelClosed: ((String) -> Void)?

    // MARK: Private

    private let browserHostView: BrowserTabHostView
    private let controller: BrowserTabController
    private var activePanelID: String?

    var hostView: NSView {
        browserHostView
    }

    init(profileCachePath: String? = nil) {
        self.browserHostView = BrowserTabHostView(frame: .zero)
        self.controller = BrowserTabController(
            hostView: browserHostView,
            usesEphemeralRequestContext: false,
            profileCachePath: profileCachePath,
        )
        super.init()
        controller.delegate = self
    }

    func openPanel(urlString: String) -> String {
        if let activePanelID {
            controller.selectTab(withID: activePanelID)
            controller.navigateActiveTab(toURLString: urlString)
            return activePanelID
        }

        let panelID = controller.createTab(withURLString: urlString, makeActive: true)
        activePanelID = panelID
        return panelID
    }

    func closePanel(id: String) {
        guard activePanelID == id else {
            return
        }

        activePanelID = nil
        controller.closeTab(withID: id, forceClose: false)
    }

    func closeAllPanels() {
        activePanelID = nil
        controller.closeAllTabs()
    }
}

// MARK: - BrowserExtensionActionPopupController

@MainActor final class BrowserExtensionActionPopupController: NSObject, BrowserExtensionActionPopupDriving {
    // MARK: Internal

    var onContentSizeChange: ((NSSize) -> Void)?

    // MARK: Private

    private let browserHostView: BrowserTabHostView
    private let controller: BrowserTabController
    private var activePopupID: String?

    // MARK: Internal

    var hostView: NSView {
        browserHostView
    }

    init(profileCachePath: String? = nil, autoResizesPages: Bool = true) {
        self.browserHostView = BrowserTabHostView(frame: .zero)
        self.controller = BrowserTabController(
            hostView: browserHostView,
            usesEphemeralRequestContext: false,
            profileCachePath: profileCachePath,
        )
        super.init()
        controller.delegate = self
        controller.autoResizesPages = autoResizesPages
        controller.onPageContentSizeChange = { [weak self] size in
            MainActor.assumeIsolated { self?.onContentSizeChange?(size) }
        }
    }

    func openPopup(urlString: String, activeTab: BrowserExtensionPopupPage?) -> String {
        controller.pageLoadStartScript = activeTab?.script
        if let activePopupID {
            controller.selectTab(withID: activePopupID)
            controller.navigateActiveTab(toURLString: urlString)
            return activePopupID
        }

        let popupID = controller.createTab(withURLString: urlString, makeActive: true)
        activePopupID = popupID
        return popupID
    }

    func closePopup(id: String) {
        guard activePopupID == id else {
            return
        }

        activePopupID = nil
        controller.closeTab(withID: id, forceClose: false)
    }

    func evaluate(_ code: String, inPopupWithID id: String, completion: @escaping @MainActor (String?) -> Void) {
        controller.evaluateJavaScript(code, inTabWithID: id) { value in
            MainActor.assumeIsolated { completion(value) }
        }
    }

    func fetchText(
        urlString: String,
        firstPartyURLString: String,
        inPopupWithID id: String,
        completion: @escaping @MainActor (String?) -> Void,
    ) {
        controller.fetchText(urlString, firstPartyURLString: firstPartyURLString, inTabWithID: id) { value in
            MainActor.assumeIsolated { completion(value) }
        }
    }

    func closeAllPopups() {
        activePopupID = nil
        controller.closeAllTabs()
    }
}

// MARK: BrowserTabControllerDelegate

extension BrowserExtensionActionPopupController: BrowserTabControllerDelegate {
    /// Tab recovery belongs to the browser content surface. Extension popups
    /// retain their existing presentation and dismissal behavior.
    nonisolated func browserTabController(
        _: BrowserTabController,
        didChangeCreationStateForTabWithID tabID: String,
        state: BrowserTabEngineCreationState,
    ) {
        guard state == .ready else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, activePopupID == tabID else { return }
            controller.acknowledgeTabReady(withID: tabID)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didCreateTabWithID _: String,
        title _: String,
        urlString _: String,
        isActive _: Bool,
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateTabWithID _: String,
        title _: String?,
        urlString _: String?,
        faviconURLString _: String?,
    ) {}

    nonisolated func browserTabController(_: BrowserTabController, didCloseTabWithID tabID: String) {
        Task { @MainActor [weak self] in
            if self?.activePopupID == tabID {
                self?.activePopupID = nil
            }
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateNavigationStateForTabWithID _: String,
        canGoBack _: Bool,
        canGoForward _: Bool,
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateLoadingStateForTabWithID _: String,
        isLoading _: Bool,
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateFindResultForTabWithID _: String,
        matchCount _: Int,
        activeMatchOrdinal _: Int,
        finalUpdate _: Bool,
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateDownloadWithID _: String,
        fileName _: String,
        urlString _: String,
        fullPath _: String?,
        receivedBytes _: Int64,
        totalBytes _: Int64,
        currentSpeedBytesPerSecond _: Int64,
        stateRawValue _: String,
    ) {}
}

// MARK: - BrowserExtensionSidePanelController + BrowserTabControllerDelegate

extension BrowserExtensionSidePanelController: BrowserTabControllerDelegate {
    /// Extension panels do not expose the browser tab recovery controls.
    nonisolated func browserTabController(
        _: BrowserTabController,
        didChangeCreationStateForTabWithID tabID: String,
        state: BrowserTabEngineCreationState,
    ) {
        guard state == .ready else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, activePanelID == tabID else { return }
            controller.acknowledgeTabReady(withID: tabID)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didCreateTabWithID _: String,
        title _: String,
        urlString _: String,
        isActive _: Bool,
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateTabWithID _: String,
        title _: String?,
        urlString _: String?,
        faviconURLString _: String?,
    ) {}

    nonisolated func browserTabController(_: BrowserTabController, didCloseTabWithID tabID: String) {
        Task { @MainActor [weak self] in
            if self?.activePanelID == tabID {
                self?.activePanelID = nil
            }
            self?.onPanelClosed?(tabID)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateNavigationStateForTabWithID _: String,
        canGoBack _: Bool,
        canGoForward _: Bool,
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateLoadingStateForTabWithID _: String,
        isLoading _: Bool,
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateFindResultForTabWithID _: String,
        matchCount _: Int,
        activeMatchOrdinal _: Int,
        finalUpdate _: Bool,
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateDownloadWithID _: String,
        fileName _: String,
        urlString _: String,
        fullPath _: String?,
        receivedBytes _: Int64,
        totalBytes _: Int64,
        currentSpeedBytesPerSecond _: Int64,
        stateRawValue _: String,
    ) {}
}

// MARK: - BrowserHiddenPageBrowser

/// Pages that load in a window that is never shown.
@MainActor final class BrowserHiddenPageBrowser: BrowserMailFeedBrowsing {
    // MARK: Private

    private let browser: BrowserExtensionActionPopupController
    private let hostWindow: NSWindow

    // MARK: Internal

    init(profileCachePath: String?) {
        self.browser = BrowserExtensionActionPopupController(
            profileCachePath: profileCachePath,
            autoResizesPages: false,
        )
        self.hostWindow = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = browser.hostView
    }

    func openPage(urlString: String) -> String {
        browser.openPopup(urlString: urlString, activeTab: nil)
    }

    func closePage(id: String) {
        browser.closePopup(id: id)
    }

    func fetchText(
        urlString: String,
        firstPartyURLString: String,
        inPageWithID id: String,
        completion: @escaping @MainActor (String?) -> Void,
    ) {
        browser.fetchText(
            urlString: urlString,
            firstPartyURLString: firstPartyURLString,
            inPopupWithID: id,
            completion: completion,
        )
    }

    func evaluate(_ code: String, inPageWithID id: String, completion: @escaping @MainActor (String?) -> Void) {
        browser.evaluate(code, inPopupWithID: id, completion: completion)
    }
}
