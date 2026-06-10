import AppKit
import Foundation

// MARK: - BrowserExtensionSidePanelController

@MainActor final class BrowserExtensionSidePanelController: NSObject, BrowserExtensionSidePanelDriving {
    // MARK: Lifecycle

    init(profileCachePath: String? = nil) {
        self.browserHostView = BrowserTabHostView(frame: .zero)
        self.controller = BrowserTabController(
            hostView: browserHostView,
            usesEphemeralRequestContext: false,
            profileCachePath: profileCachePath
        )
        super.init()
        controller.delegate = self
    }

    // MARK: Internal

    var onPanelClosed: ((String) -> Void)?

    var hostView: NSView {
        browserHostView
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

    // MARK: Private

    private let browserHostView: BrowserTabHostView
    private let controller: BrowserTabController
    private var activePanelID: String?
}

// MARK: - BrowserExtensionActionPopupController

@MainActor final class BrowserExtensionActionPopupController: NSObject, BrowserExtensionActionPopupDriving {
    // MARK: Lifecycle

    init(profileCachePath: String? = nil) {
        self.browserHostView = BrowserTabHostView(frame: .zero)
        self.controller = BrowserTabController(
            hostView: browserHostView,
            usesEphemeralRequestContext: false,
            profileCachePath: profileCachePath
        )
        super.init()
        controller.delegate = self
    }

    // MARK: Internal

    var hostView: NSView {
        browserHostView
    }

    func openPopup(urlString: String) -> String {
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

    func closeAllPopups() {
        activePopupID = nil
        controller.closeAllTabs()
    }

    // MARK: Private

    private let browserHostView: BrowserTabHostView
    private let controller: BrowserTabController
    private var activePopupID: String?
}

// MARK: BrowserTabControllerDelegate

extension BrowserExtensionActionPopupController: BrowserTabControllerDelegate {
    nonisolated func browserTabController(
        _: BrowserTabController,
        didCreateTabWithID _: String,
        title _: String,
        urlString _: String
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateTabWithID _: String,
        title _: String?,
        urlString _: String?,
        faviconURLString _: String?
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
        canGoForward _: Bool
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateLoadingStateForTabWithID _: String,
        isLoading _: Bool
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateFindResultForTabWithID _: String,
        matchCount _: Int,
        activeMatchOrdinal _: Int,
        finalUpdate _: Bool
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
        stateRawValue _: String
    ) {}
}

// MARK: - BrowserExtensionSidePanelController + BrowserTabControllerDelegate

extension BrowserExtensionSidePanelController: BrowserTabControllerDelegate {
    nonisolated func browserTabController(
        _: BrowserTabController,
        didCreateTabWithID _: String,
        title _: String,
        urlString _: String
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateTabWithID _: String,
        title _: String?,
        urlString _: String?,
        faviconURLString _: String?
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
        canGoForward _: Bool
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateLoadingStateForTabWithID _: String,
        isLoading _: Bool
    ) {}

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateFindResultForTabWithID _: String,
        matchCount _: Int,
        activeMatchOrdinal _: Int,
        finalUpdate _: Bool
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
        stateRawValue _: String
    ) {}
}
