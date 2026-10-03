/// Stable identities of the roots acted on, in their final sidebar order.
/// Persistence resolves destination and anchors from the accompanying snapshot.
struct BrowserSyncMoveIntent: Equatable {
    // MARK: Lifecycle

    init(items: [BrowserSyncEntityReference]) { self.items = items }

    init(tabIDs: [String]) {
        self.items = tabIDs.map { .init(entityType: .tab, entityID: $0) }
    }

    // MARK: Internal

    let items: [BrowserSyncEntityReference]

    var tabIDs: [String] { items.filter { $0.entityType == .tab }.map(\.entityID) }
}
