// BrowserShareFlowController.swift

import AppKit
import Foundation

// MARK: - BrowserShareFlowController

/// Share Space…, Share Folder… and adding a shared link: the questions asked
/// in the window, the server calls and what is copied.
@MainActor final class BrowserShareFlowController {
    // MARK: Private

    private let openAccountSettings: () -> Void
    private var isBusy = false

    init(openAccountSettings: @escaping () -> Void) {
        self.openAccountSettings = openAccountSettings
    }

    // MARK: Internal

    /// Publishes a Space or folder after asking, then copies its link.
    func share(
        _ kind: BrowserShareKind,
        sourceID: String,
        model: BrowserChromeModel,
        store: BrowserShareStore,
        window: NSWindow?,
    ) {
        guard !isBusy else { return }
        guard store.canPublish else {
            ask(
                BrowserStrings.shareSignInTitle,
                detail: BrowserStrings.shareSignInDetail,
                confirm: BrowserStrings.shareOpenSettings,
                in: window,
            ) { [openAccountSettings] in openAccountSettings() }
            return
        }
        let collection = kind == .folder
            ? model.shareCollection(forFolderID: sourceID)
            : model.shareCollection(forSpaceID: sourceID)
        guard let collection else {
            tell(BrowserStrings.shareNothingTitle, detail: BrowserStrings.shareNothingDetail(kind), in: window)
            return
        }
        isBusy = true
        Task { [weak self] in
            if store.loadState == .idle {
                await store.refresh()
            }
            guard let self else { return }
            isBusy = false
            let previous = store.link(forSourceID: collection.sourceID, kind: kind)
            ask(
                BrowserStrings.shareConfirmTitle(collection.title),
                detail: BrowserStrings.shareConfirmDetail(
                    kind: kind,
                    tabs: collection.tabCount,
                    sharedOn: previous?.updatedAt,
                ),
                confirm: BrowserStrings.shareConfirmAction,
                in: window,
            ) { [weak self] in
                self?.publish(
                    kind == .folder ? .folder(collection) : .space(collection),
                    store: store,
                    model: model,
                    window: window,
                )
            }
        }
    }

    /// Reads a shared Space or folder and adds it after asking.
    func addShared(id: String, model: BrowserChromeModel, store: BrowserShareStore, window: NSWindow?) {
        guard !isBusy else { return }
        guard model.canImportSidebar, model.supportsSpaces else {
            tell(BrowserStrings.shareAddUnavailable, detail: nil, in: window)
            return
        }
        isBusy = true
        Task { [weak self] in
            let content: Result<BrowserSharedContent, Error>
            do {
                content = try await .success(store.content(id: id))
            } catch {
                content = .failure(error)
            }
            guard let self else { return }
            isBusy = false
            switch content {
            case .failure(let error):
                let removed = (error as? BrowserShareError) == .notFound
                tell(
                    removed ? BrowserStrings.shareRemovedTitle : BrowserStrings.shareAddFailed,
                    detail: removed ? BrowserStrings.shareRemovedDetail : BrowserShareStore.message(for: error),
                    in: window,
                )
            case .success(let content) where content.kind == .quote || content.tabCount == 0:
                tell(BrowserStrings.shareRemovedTitle, detail: BrowserStrings.shareRemovedDetail, in: window)
            case .success(let content):
                confirmAdding(content, model: model, window: window)
            }
        }
    }

    private func publish(
        _ request: BrowserShareRequest,
        store: BrowserShareStore,
        model: BrowserChromeModel,
        window: NSWindow?,
    ) {
        isBusy = true
        Task { [weak self] in
            let result: Result<BrowserSharedLink, Error>
            do {
                result = try await .success(store.publish(request))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            isBusy = false
            switch result {
            case .failure(let error):
                tell(BrowserStrings.shareFailed, detail: BrowserShareStore.message(for: error), in: window)
            case .success(let link):
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(link.url.absoluteString, forType: .URL)
                pasteboard.setString(link.url.absoluteString, forType: .string)
                ask(
                    BrowserStrings.shareCopiedTitle(link.title),
                    detail: BrowserStrings.shareCopiedDetail(link.url.absoluteString),
                    confirm: BrowserStrings.shareDone,
                    alternate: BrowserStrings.shareOpenLink,
                    in: window,
                    onAlternate: { model.openURLInNewTab(link.url) },
                ) {}
            }
        }
    }

    private func confirmAdding(_ content: BrowserSharedContent, model: BrowserChromeModel, window: NSWindow?) {
        let title = content.title ?? BrowserStrings.pinnedTabFolderDefaultTitle
        let spaceTitle = model.spaces.first { $0.id == model.selectedSpaceID }?.title
        ask(
            BrowserStrings.shareAddTitle(title),
            detail: BrowserStrings.shareAddDetail(
                kind: content.kind,
                tabs: content.tabCount,
                folders: content.folderCount,
                into: spaceTitle,
            ),
            confirm: content.kind == .folder ? BrowserStrings.shareAddFolderAction : BrowserStrings.shareAddSpaceAction,
            in: window,
        ) { [weak self, weak model] in
            guard let model else { return }
            self?.add(content, to: model, window: window)
        }
    }

    private func add(_ content: BrowserSharedContent, to model: BrowserChromeModel, window: NSWindow?) {
        switch content.kind {
        case .folder:
            guard let spaceID = model.selectedSpaceID ?? model.spaces.first?.id,
                  model.addImportedFolder(BrowserShareConversion.importedFolder(from: content), toSpaceID: spaceID)
                  != nil
            else {
                tell(BrowserStrings.shareAddFailed, detail: nil, in: window)
                return
            }
        case .quote,
             .space:
            let before = Set(model.spaces.map(\.id))
            let result = model.importSidebar(BrowserImportedSidebar(
                spaces: [BrowserShareConversion.importedSpace(from: content)],
                favorites: [],
            ))
            guard result.spaceCount > 0, let added = model.spaces.first(where: { !before.contains($0.id) }) else {
                tell(BrowserStrings.shareAlreadyAdded, detail: nil, in: window)
                return
            }
            model.selectSpace(id: added.id)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    private func tell(_ message: String, detail: String?, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail ?? ""
        present(alert, in: window) { _ in }
    }

    private func ask(
        _ message: String,
        detail: String,
        confirm: String,
        alternate: String? = nil,
        in window: NSWindow?,
        onAlternate: @escaping () -> Void = {},
        onConfirm: @escaping () -> Void,
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: alternate ?? BrowserStrings.shareCancel)
        present(alert, in: window) { response in
            switch response {
            case .alertFirstButtonReturn: onConfirm()
            case .alertSecondButtonReturn where alternate != nil: onAlternate()
            default: break
            }
        }
    }

    private func present(
        _ alert: NSAlert,
        in window: NSWindow?,
        completion: @escaping (NSApplication.ModalResponse) -> Void,
    ) {
        if let window, window.attachedSheet == nil {
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
