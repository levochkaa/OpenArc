// BrowserProfileWindowGroup.swift

import Foundation

// MARK: - BrowserProfileWindowGroup

/// The windows of one profile. They show the same sidebar, and each keeps its own
/// selection and pages: every saved session goes to the others, and a tab's page lives
/// in one window at a time.
@MainActor final class BrowserProfileWindowGroup {
    // MARK: Internal

    private(set) var models = [BrowserChromeModel]()

    func add(_ model: BrowserChromeModel) {
        guard !models.contains(where: { $0 === model }) else { return }
        models.append(model)
        model.windowGroup = self
    }

    /// The window that remains in charge of expiring tabs is always the oldest.
    func remove(_ model: BrowserChromeModel) {
        models.removeAll { $0 === model }
        model.windowGroup = nil
        models.first?.isAdditionalWindow = false
    }

    func sessionDidChange(_ snapshot: BrowserTabSessionSnapshot, from sender: BrowserChromeModel) {
        for model in models where model !== sender {
            model.applyPeerSnapshot(snapshot)
        }
    }

    /// Titles change without a saved session; the other windows show them at once.
    func pageTitleDidChange(_ title: String, syncID: String, from sender: BrowserChromeModel) {
        for model in models where model !== sender {
            model.applyPeerPageTitle(title, syncID: syncID)
        }
    }

    /// The tab's page title as another window shows it, for a window that joins
    /// after the title came, since a title alone does not save the session.
    func pageTitle(forSyncID syncID: String, than sender: BrowserChromeModel) -> String? {
        for model in models where model !== sender {
            if let title = model.tabs.first(where: { $0.syncID == syncID })?.title, !title.isEmpty { return title }
        }
        return nil
    }

    /// Takes the tab's page away from whichever window has it.
    func pageWillOpen(syncID: String, in sender: BrowserChromeModel) {
        for model in models where model !== sender {
            model.releasePage(forSyncID: syncID)
        }
    }

    /// Moves the tab's live page to `sender` from the window that has it; nil when none
    /// can give it.
    func takePage(syncID: String, for sender: BrowserChromeModel) -> BrowserTabPageHandoff? {
        for model in models where model !== sender {
            if let handoff = model.detachPage(forSyncID: syncID) { return handoff }
        }
        return nil
    }

    func hasPageElsewhere(syncID: String, than sender: BrowserChromeModel) -> Bool {
        models.contains { $0 !== sender && $0.hasPage(forSyncID: syncID) }
    }
}

// MARK: - BrowserAdditionalWindowRecord

/// An extra window to bring back at the next launch.
struct BrowserAdditionalWindowRecord: Codable, Equatable {
    static let defaultsKey = "browser.windows.additional"

    let profileID: String
    let frame: String
    let spaceID: String?
    let selectedTabSyncID: String?

    static func load(from defaults: UserDefaults) -> [Self] {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([Self].self, from: $0) } ?? []
    }

    static func save(_ records: [Self], to defaults: UserDefaults) {
        if records.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
