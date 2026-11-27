// BrowserMobileTabsFeed.swift

import Foundation

// MARK: - BrowserMobileTabsFeed

/// The tabs of the account's phones and tablets, as a computer lists them
/// under From iPhone. A computer only reads them: they are no Space's, and
/// opening one makes an ordinary tab here.
@MainActor final class BrowserMobileTabsFeed: BrowserSyncMobileTabApplying {
    // MARK: Internal

    static let didChange = Notification.Name("BrowserMobileTabsFeed.didChange")
    /// The default profile's feed: mobile tabs follow that profile's account, as boosts do.
    static weak var current: BrowserMobileTabsFeed?

    /// The latest used first.
    private(set) var tabs = [BrowserSyncMobileTabEntry]()

    // MARK: Private

    private let load: () throws -> BrowserSyncMobileTabState?

    init(store: BrowserSQLiteSessionStore) {
        self.load = { [weak store] in try store?.loadSyncMobileTabState() }
        reload()
    }

    init(load: @escaping () throws -> BrowserSyncMobileTabState?) {
        self.load = load
        reload()
    }

    static func ordered(_ state: BrowserSyncMobileTabState?) -> [BrowserSyncMobileTabEntry] {
        (state?.entries ?? []).sorted { lhs, rhs in
            let left = lhs.record.lastActivityAt ?? lhs.record.createdAt
            let right = rhs.record.lastActivityAt ?? rhs.record.createdAt
            return left == right ? lhs.id < rhs.id : left > right
        }
    }

    /// A computer has no mobile tabs of its own to upload.
    func localSyncMobileTabs() -> [BrowserSyncMobileTabEntry] { [] }

    func syncMobileTabsDidChange() { reload() }

    private func reload() {
        let next = Self.ordered(try? load())
        guard next != tabs else { return }
        tabs = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
