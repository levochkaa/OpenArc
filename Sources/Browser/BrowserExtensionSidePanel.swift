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
    var onContentSizeChange: ((NSSize) -> Void)?

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

// MARK: - BrowserExtensionPopupPage

struct BrowserExtensionPopupPage: Equatable {
    let urlString: String
    let title: String

    /// `chrome.tabs.query` finds no tabs in a popup, which leaves an extension with no
    /// site to show. An active-tab query answers with this page instead.
    var script: String? {
        let tab: [String: Any] = [
            "id": 1, "index": 0, "windowId": 1, "url": urlString, "title": title, "active": true,
            "highlighted": true, "selected": true, "pinned": false, "incognito": false,
            "status": "complete", "discarded": false, "autoDiscardable": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: tab),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return """
        (() => {
          const tab = \(json);
          const api = globalThis.chrome && chrome.tabs;
          if (!api) return;
          const query = api.query.bind(api);
          const get = api.get.bind(api);
          api.query = (info, callback) => {
            const answer = query(info).then((tabs) =>
              tabs.length === 0 && (info.active || info.currentWindow || info.lastFocusedWindow) ? [tab] : tabs);
            if (callback) { answer.then(callback); return; }
            return answer;
          };
          api.get = (id, callback) => {
            const answer = id === tab.id ? Promise.resolve(tab) : get(id);
            if (callback) { answer.then(callback); return; }
            return answer;
          };
        })();
        """
    }
}

// MARK: - BrowserExtensionActionPopupDriving

@MainActor protocol BrowserExtensionActionPopupDriving: AnyObject {
    var hostView: NSView { get }
    var onContentSizeChange: ((NSSize) -> Void)? { get set }

    /// `activeTab` is the page the popup acts on. Extensions cannot see a window's
    /// pages through `chrome.tabs`, so the popup is told which one it is.
    func openPopup(urlString: String, activeTab: BrowserExtensionPopupPage?) -> String
    func closePopup(id: String)
    func closeAllPopups()
}
