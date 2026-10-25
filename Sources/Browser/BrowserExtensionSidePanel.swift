// BrowserExtensionSidePanel.swift

import AppKit
import Foundation

// MARK: - BrowserExtensionSidePanel

struct BrowserExtensionSidePanel: Equatable {
    let panelID: String
    let extensionID: String
    let title: String
    let urlString: String
    let iconData: Data?

    var iconImage: NSImage? {
        guard let iconData else {
            return nil
        }

        return BrowserImageThumbnailer.image(
            data: iconData,
            maximumPixelSize: BrowserImageThumbnailer.chromeIconMaximumPixelSize,
        )
    }
}

// MARK: - BrowserExtensionSidePanelDriving

@MainActor protocol BrowserExtensionSidePanelDriving: AnyObject {
    var hostView: NSView { get }
    var onPanelClosed: ((String) -> Void)? { get set }

    func openPanel(urlString: String) -> String
    func closePanel(id: String)
    func closeAllPanels()
}

// MARK: - BrowserExtensionActionPopup

@MainActor final class BrowserExtensionActionPopup: Identifiable {
    // MARK: Internal

    let id: String
    let extensionID: String
    let title: String
    let hostView: NSView

    // MARK: Private

    private let closeHandler: () -> Void

    init(
        id: String,
        extensionID: String,
        title: String,
        hostView: NSView,
        closeHandler: @escaping () -> Void,
    ) {
        self.id = id
        self.extensionID = extensionID
        self.title = title
        self.hostView = hostView
        self.closeHandler = closeHandler
    }

    func close() {
        closeHandler()
    }
}

// MARK: - BrowserExtensionActionPopupDriving

@MainActor protocol BrowserExtensionActionPopupDriving: AnyObject {
    var hostView: NSView { get }

    func openPopup(urlString: String) -> String
    func closePopup(id: String)
    func closeAllPopups()
}
