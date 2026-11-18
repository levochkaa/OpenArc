// BrowserChromeModel+Easels.swift

import AppKit
import Foundation

// MARK: - BrowserEaselCaptureSource

/// Where an area capture came from, so the picture can join an Easel and refresh.
struct BrowserEaselCaptureSource: Equatable {
    let tabID: String
    let tabSyncID: String
    let urlString: String
    let title: String
    let region: CGRect
}

// MARK: - BrowserChromeModel + Easels

extension BrowserChromeModel {
    /// How often a live capture asks its page for a new picture while its Easel is on screen.
    static let easelLiveCaptureInterval: TimeInterval = 5

    var easelStore: BrowserEaselStore {
        easelStoreOverride ?? .shared
    }

    /// Easels belong to normal windows; incognito, blank and web-app windows have none.
    var canCreateEasel: Bool {
        windowMode == .normal && canCreateTab
    }

    func easelID(forTabID tabID: String?) -> String? {
        guard let tabID, let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
        return BrowserEaselURL.easelID(from: tab.urlString)
    }

    /// The Easels shown in the window now: the selected tab and its split panes.
    var visibleEaselTabIDs: [String] {
        guard windowMode == .normal, let selectedTabID else { return [] }
        return splitPaneTabIDs(forTabID: selectedTabID).filter { easelID(forTabID: $0) != nil }
    }

    /// New Easel: a pinned tab at the end of the current Space's pinned tabs,
    /// selected, with its title ready to type. Returns the tab.
    @discardableResult func createEasel(_ document: BrowserEaselDocument? = nil) -> String? {
        guard canCreateEasel else { return nil }
        let document = document ?? .new()
        easelStore.save(document)
        return openEaselTab(document)
    }

    /// Selects the Easel's tab, or pins a new one for it in the current Space.
    @discardableResult func openEasel(id: String) -> Bool {
        guard canCreateEasel, let document = easelStore.document(id: id) else { return false }
        closeLibrary()
        let urlString = BrowserEaselURL.urlString(forEaselID: id)
        if let tab = tabs.first(where: { $0.urlString == urlString || $0.pinnedURLString == urlString }) {
            selectTab(id: tab.id)
            return true
        }
        return openEaselTab(document) != nil
    }

    /// Delete Easel: the drawing and every tab that shows it.
    func deleteEasel(id: String) {
        let urlString = BrowserEaselURL.urlString(forEaselID: id)
        for tab in tabs where tab.urlString == urlString || tab.pinnedURLString == urlString {
            closeTab(id: tab.id, forceClose: true, registersUndo: false, reason: .structuralRemoval)
        }
        easelStore.delete(id: id)
        objectWillChange.send()
    }

    /// The Library's Easels.
    @discardableResult func viewEasels() -> Bool {
        guard librarySections.contains(.easels) else { return false }
        openLibrary(section: .easels)
        return true
    }

    /// The sidebar row follows the Easel's title, and the title follows a rename
    /// of the row: whichever changed since the last sync wins.
    func syncEaselTitle(tabID: String, editor: BrowserEaselEditor) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let title = editor.document.title
        let override = tab.userTitleOverride
        if let override, override != title, override != editor.syncedTitle,
           let titleID = editor.document.titleObject?.id
        {
            editor.syncedTitle = override
            editor.setText(override, of: titleID)
            return
        }
        editor.syncedTitle = title
        if override != title {
            setUserTitleOverride(title, forTabID: tabID)
        }
    }

    // MARK: Captures

    /// The capture button: outline part of the page beside the Easel in a split
    /// and the picture joins the Easel. Without a page beside it, a split opens
    /// with the command bar to pick one.
    @discardableResult func beginEaselCapture(easelID: String) -> Bool {
        guard canCreateEasel else { return false }
        easelCaptureTargetID = easelID
        let easelURL = BrowserEaselURL.urlString(forEaselID: easelID)
        let panes = selectedTabID.map { splitPaneTabIDs(forTabID: $0) } ?? []
        if let page = panes.first(where: { id in tabs.first { $0.id == id }?.urlString != easelURL }) {
            selectTab(id: page)
            if beginAreaCapture() { return true }
        }
        presentSplitViewCommandBar(insertion: .after, orientation: .horizontal)
        return true
    }

    /// Called as an area capture is taken; the picture comes later with `didCopyAreaCapture`.
    func noteAreaCapture(fraction: CGRect, tabID: String) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        lastAreaCaptureSource = BrowserEaselCaptureSource(
            tabID: tab.id,
            tabSyncID: tab.syncID,
            urlString: tab.urlString,
            title: tab.displayTitle,
            region: fraction,
        )
    }

    /// The copied picture of the latest capture: it joins the Easel that asked for it.
    func didCopyAreaCapture(png: Data) {
        guard let target = easelCaptureTargetID else { return }
        easelCaptureTargetID = nil
        // Only while the Easel that asked is on screen beside the page.
        guard let source = lastAreaCaptureSource,
              visibleEaselTabIDs.contains(where: { easelID(forTabID: $0) == target })
        else { return }
        addCapture(png: png, source: source, toEaselID: target)
    }

    /// Send To → New Easel for the latest capture.
    @discardableResult func sendCaptureToNewEasel(png: Data) -> String? {
        guard canCreateEasel else { return nil }
        let document = BrowserEaselDocument.new()
        easelStore.save(document)
        addCapture(png: png, source: lastAreaCaptureSource, toEaselID: document.id)
        return openEaselTab(easelStore.document(id: document.id) ?? document)
    }

    func addCapture(png: Data, source: BrowserEaselCaptureSource?, toEaselID id: String) {
        guard var document = easelStore.document(id: id) else { return }
        let size = NSImage(data: png).map { image -> CGSize in
            let rep = image.representations.first
            return CGSize(width: CGFloat(rep?.pixelsWide ?? 0) / 2, height: CGFloat(rep?.pixelsHigh ?? 0) / 2)
        } ?? .zero
        let fileName = easelStore.addImage(png, toEaselID: id)
        let fitted = BrowserEaselEditor.fitted(size, maxWidth: 500)
        let top = max(document.contentBottom + 30, BrowserEaselDocument.titleFrame.maxY + 30)
        let object = BrowserEaselObject(
            frame: CGRect(x: (BrowserEaselDocument.width - fitted.width) / 2, y: top, width: fitted.width, height: fitted.height),
            content: source.map {
                .capture(BrowserEaselCapture(
                    fileName: fileName,
                    urlString: $0.urlString,
                    title: $0.title,
                    region: $0.region,
                    capturedAt: Date(),
                ))
            } ?? .image(BrowserEaselImage(fileName: fileName)),
        )
        document.objects.append(object)
        document.modifiedAt = Date()
        easelStore.save(document)
    }

    /// Asks the capture's page for a new picture, when that page is open in this window.
    func refreshLiveCapture(_ capture: BrowserEaselCapture, completion: @escaping @MainActor (Data?) -> Void) {
        guard let tab = tabs.first(where: { $0.urlString == capture.urlString && !hasNoPage($0.id) }) else {
            completion(nil)
            return
        }
        captureTabRegion(tabID: tab.id, fraction: capture.region, completion: completion)
    }

    /// Opens the page a capture came from in a new tab.
    func openCapturedPage(_ capture: BrowserEaselCapture) {
        guard let url = URL(string: capture.urlString), url.scheme?.hasPrefix("http") == true else { return }
        if openURLInSplitView(url) { return }
        openURLInNewTab(url)
    }

    // MARK: Private

    private func openEaselTab(_ document: BrowserEaselDocument) -> String? {
        guard let url = URL(string: BrowserEaselURL.urlString(forEaselID: document.id)) else { return nil }
        closeLibrary()
        return withArrangementUndo(BrowserStrings.menuNewEasel) { () -> String? in
            openURLInNewTab(url)
            guard let tabID = selectedTabID, easelID(forTabID: tabID) == document.id else { return nil }
            // The end of the Space's pinned tabs: after its top-level rows.
            let space = tabs.first { $0.id == tabID }?.spaceID
            let rootRows = tabs.count { $0.spaceID == space && $0.placement == .spacePinned && $0.pinnedFolderID == nil }
                + pinnedTabFolders.count { $0.spaceID == space && $0.parentFolderID == nil }
            moveTab(withID: tabID, toPlacement: .spacePinned, atSectionIndex: rootRows)
            setUserTitleOverride(document.title, forTabID: tabID)
            return tabID
        }
    }
}
