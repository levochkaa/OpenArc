// BrowserMobileSidebarDrop.swift

import Foundation

/// A drag captures identities and containers from the rendered tree. Planning
/// checks those tokens against the latest document; UIKit owns document/scene
/// identity and never turns a stale row index into a different target.
enum BrowserMobileSidebarDrop {
    // MARK: Internal

    enum Position: Equatable { case before, after, inside }

    struct Source: Equatable {
        // MARK: Internal

        let items: [BrowserSyncEntityReference]

        // MARK: Fileprivate

        fileprivate let containers: [BrowserSyncEntityReference: Container]
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
        let items: [BrowserSyncEntityReference]
        let destination: BrowserSyncFolderDestination
        let before: BrowserSyncEntityReference?
        let after: BrowserSyncEntityReference?
    }

    // MARK: Fileprivate

    /// Favorites form one global list. Their historical spaceID is bookkeeping,
    /// so changing only that field does not invalidate a source or anchor.
    fileprivate enum Container: Hashable {
        case favorites
        case pinned(space: String, parent: String?)
        case today(space: String)
    }

    static func source(
        item: BrowserSyncEntityReference, in snapshot: BrowserTabSessionSnapshot,
    ) -> Source? {
        source(items: [item], in: snapshot)
    }

    /// Input order is the rendered sidebar order supplied by UIKit, not the
    /// sequence in which checkboxes were selected. Descendants of a selected
    /// folder travel with that root and do not become independent move items.
    static func source(
        items: [BrowserSyncEntityReference], in snapshot: BrowserTabSessionSnapshot,
    ) -> Source? {
        guard !items.isEmpty, Set(items).count == items.count else { return nil }
        let values = canonical(snapshot)
        var containers = [BrowserSyncEntityReference: Container]()
        for item in items {
            guard let value = values[key(item)], let container = container(value) else { return nil }
            containers[item] = container
        }
        let folders = Set(items.filter { $0.entityType == .folder }.map(\.entityID))
        let roots = items.filter { !hasAncestor($0, in: folders, values: values) }
        guard !roots.isEmpty, roots.count <= 1000 else { return nil }
        let rootSet = Set(roots)
        return Source(items: roots, containers: containers.filter { rootSet.contains($0.key) })
    }

    /// Adding cannot replace a native item already supplied to UIKit. Preserve
    /// all captured containers and reject any normalization that removes a root.
    static func extending(
        source: Source, adding: Source, orderedItems: [BrowserSyncEntityReference],
        in snapshot: BrowserTabSessionSnapshot,
    ) -> Source? {
        let existing = Set(source.items)
        let additions = Set(adding.items)
        let expected = existing.union(additions)
        guard !additions.isEmpty, existing.isDisjoint(with: additions), expected.count <= 1000,
              orderedItems.count == expected.count, Set(orderedItems) == expected,
              orderedItems.filter({ existing.contains($0) }) == source.items,
              orderedItems.filter({ additions.contains($0) }) == adding.items,
              let current = Self.source(items: orderedItems, in: snapshot), current.items == orderedItems
        else { return nil }
        let captured = source.containers.merging(adding.containers) { first, _ in first }
        guard current.containers == captured else { return nil }
        return Source(items: orderedItems, containers: captured)
    }

    static func target(
        relativeTo item: BrowserSyncEntityReference, position: Position, in snapshot: BrowserTabSessionSnapshot,
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
            reference: nil, referenceContainer: nil, position: nil,
        )
    }

    static func canExpandFolder(
        source: Source, target: Target, in snapshot: BrowserTabSessionSnapshot,
    ) -> Bool {
        guard target.position == .inside, target.reference?.entityType == .folder,
              let values = validatedValues(source: source, target: target, snapshot: snapshot) else { return false }
        return BrowserSyncFolderProjection.canMove(
            items: source.items,
            destination: target.destination,
            values: values,
        )
    }

    static func plan(
        source: Source, target: Target, in snapshot: BrowserTabSessionSnapshot,
    ) -> Plan? {
        guard var values = validatedValues(source: source, target: target, snapshot: snapshot) else { return nil }
        let before = target.position == .before ? target.reference : nil
        let after = target.position == .after ? target.reference : nil
        let plan = Plan(items: source.items, destination: target.destination, before: before, after: after)
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

    // MARK: Private

    private static func validatedValues(
        source: Source, target: Target, snapshot: BrowserTabSessionSnapshot,
    ) -> [String: BrowserSyncChange]? {
        let values = canonical(snapshot)
        for item in source.items {
            guard let moving = values[key(item)], container(moving) == source.containers[item] else { return nil }
        }
        if let reference = target.reference {
            let folders = Set(source.items.filter { $0.entityType == .folder }.map(\.entityID))
            guard !source.items.contains(reference), let anchor = values[key(reference)],
                  container(anchor) == target.referenceContainer,
                  !hasAncestor(reference, in: folders, values: values) else { return nil }
        }
        return values
    }

    private static func canonical(_ snapshot: BrowserTabSessionSnapshot) -> [String: BrowserSyncChange] {
        Dictionary(
            BrowserSyncFolderProjection.canonicalChanges(snapshot).map { (BrowserSyncOutboxProjection.key($0), $0) },
            uniquingKeysWith: { first, _ in first },
        )
    }

    private static func key(_ item: BrowserSyncEntityReference) -> String {
        BrowserSyncOutboxProjection.key(type: item.entityType, id: item.entityID)
    }

    private static func hasAncestor(
        _ item: BrowserSyncEntityReference,
        in selectedFolders: Set<String>,
        values: [String: BrowserSyncChange],
    ) -> Bool {
        guard let value = values[key(item)] else { return false }
        var parent = value.folderData?.parentFolderID ?? value.tabData?.pinnedFolderID
        var visited = Set<String>()
        while let id = parent, visited.insert(id).inserted {
            if selectedFolders.contains(id) {
                return true
            }
            parent = values[key(.init(entityType: .folder, entityID: id))]?.folderData?.parentFolderID
        }
        return false
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
