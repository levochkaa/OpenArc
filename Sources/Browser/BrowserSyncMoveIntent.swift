/// Stable identities of the tabs acted on, in their final sidebar order.
/// Persistence resolves destination and anchors from the accompanying snapshot.
struct BrowserSyncMoveIntent: Equatable {
    let tabIDs: [String]
}
