import Foundation

/// A drag captures identities and containers from the rendered tree. Planning
/// checks those tokens against the latest document; UIKit owns document/scene
/// identity and never turns a stale row index into a different target.
enum BrowserMobileSidebarDrop {
    // MARK: Internal

    enum Position: Equatable { case before, after, inside }

    struct Source: Equatable {
        // MARK: Internal

        let item: BrowserSyncEntityReference

        // MARK: Fileprivate

        fileprivate let container: Container
    }

    struct Target: Equatable {
        // MARK: Internal

        let destination: BrowserSyncFolderDestination

        // MARK: Fileprivate

        fileprivate let reference: BrowserSyncEntityReference?
        fileprivate let referenceContainer: Container?
        fileprivate let position: Position?
    }

    struct Plan: Equatable {
        let item: BrowserSyncEntityReference
        let destination: BrowserSyncFolderDestination
        let before: BrowserSyncEntityReference?
        let after: BrowserSyncEntityReference?

        var items: [BrowserSyncEntityReference] { [item] }
    }

    static func source(
        item: BrowserSyncEntityReference, in snapshot: BrowserTabSessionSnapshot
    ) -> Source? {
        guard let value = canonical(snapshot)[key(item)], let container = container(value) else { return nil }
        return Source(item: item, container: container)
    }

    static func target(
        relativeTo item: BrowserSyncEntityReference, position: Position, in snapshot: BrowserTabSessionSnapshot
    ) -> Target? {
        guard let value = canonical(snapshot)[key(item)], let container = container(value),
              let rowDestination = destination(value) else { return nil }
        let dropDestination: BrowserSyncFolderDestination
        if position == .inside {
            guard let folder = value.folderData else { return nil }
            dropDestination = .tabs(spaceID: folder.spaceID, placement: .spacePinned, pinnedFolderID: item.entityID)
        } else {
            dropDestination = rowDestination
        }
        return Target(destination: dropDestination, reference: item, referenceContainer: container, position: position)
    }

    static func rootTarget(spaceID: String, placement: BrowserTabPlacement) -> Target {
        Target(
            destination: .tabs(spaceID: spaceID, placement: placement, pinnedFolderID: nil),
            reference: nil, referenceContainer: nil, position: nil
        )
    }

    static func plan(
        source: Source, target: Target, in snapshot: BrowserTabSessionSnapshot
    ) -> Plan? {
        var values = canonical(snapshot)
        guard let moving = values[key(source.item)], container(moving) == source.container else { return nil }
        if let reference = target.reference {
            guard reference != source.item, let anchor = values[key(reference)],
                  container(anchor) == target.referenceContainer else { return nil }
        }
        let before = target.position == .before ? target.reference : nil
        let after = target.position == .after ? target.reference : nil
        let plan = Plan(item: source.item, destination: target.destination, before: before, after: after)
        let previous = orderedContainers(values)
        var deleted = Set<String>()
        // Reuse v4 validation for dead parents, cycles, folder placements and
        // current descendant membership. A folder remains one acted-on root.
        BrowserSyncFolderProjection.apply([
            .move(items: plan.items, destination: plan.destination, before: before, after: after),
        ], to: &values, deleted: &deleted)
        // Rank normalization alone is not a move. Reject semantic no-ops before
        // the document can enqueue a write, even when ranks are sparse or tied.
        guard orderedContainers(values) != previous else { return nil }
        return plan
    }

    // MARK: Fileprivate

    /// Favorites form one global list. Their historical spaceID is bookkeeping,
    /// so changing only that field does not invalidate a source or anchor.
    fileprivate enum Container: Hashable {
        case favorites
        case pinned(space: String, parent: String?)
        case today(space: String)
    }

    // MARK: Private

    private static func canonical(_ snapshot: BrowserTabSessionSnapshot) -> [String: BrowserSyncChange] {
        Dictionary(
            BrowserSyncFolderProjection.canonicalChanges(snapshot).map { (BrowserSyncOutboxProjection.key($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func key(_ item: BrowserSyncEntityReference) -> String {
        BrowserSyncOutboxProjection.key(type: item.entityType, id: item.entityID)
    }

    private static func container(_ change: BrowserSyncChange) -> Container? {
        if let folder = change.folderData {
            return .pinned(space: folder.spaceID, parent: folder.parentFolderID)
        }
        guard let tab = change.tabData else { return nil }
        switch tab.placement {
        case .app: return .favorites
        case .spacePinned: return .pinned(space: tab.spaceID, parent: tab.pinnedFolderID)
        case .temporary: return .today(space: tab.spaceID)
        }
    }

    private static func destination(_ change: BrowserSyncChange) -> BrowserSyncFolderDestination? {
        if let folder = change.folderData {
            return .tabs(spaceID: folder.spaceID, placement: .spacePinned, pinnedFolderID: folder.parentFolderID)
        }
        guard let tab = change.tabData else { return nil }
        return .tabs(spaceID: tab.spaceID, placement: tab.placement, pinnedFolderID: tab.pinnedFolderID)
    }

    private static func orderedContainers(_ values: [String: BrowserSyncChange])
    -> [Container: [BrowserSyncEntityReference]] {
        let ordered = values.values.filter { $0.op == .upsert }.sorted { lhs, rhs in
            let first = lhs.folderData?.rank ?? lhs.tabData?.rank ?? 0
            let second = rhs.folderData?.rank ?? rhs.tabData?.rank ?? 0
            return first == second
                ? BrowserSyncOutboxProjection.key(lhs)
                    .utf16
                    .lexicographicallyPrecedes(BrowserSyncOutboxProjection.key(rhs).utf16)
                : first < second
        }
        var result = [Container: [BrowserSyncEntityReference]]()
        for value in ordered {
            guard let container = container(value) else { continue }
            result[container, default: []].append(.init(entityType: value.entityType, entityID: value.entityID))
        }
        return result
    }
}
