import Foundation

// MARK: - BrowserMobileProfileDocument

/// One logical profile shared by scene adapters. Scenes submit stable-ID actions;
/// their independently selected tabs and WebKit runtimes never replace this tree.
@MainActor final class BrowserMobileProfileDocument: BrowserSyncSnapshotApplying {
    // MARK: Lifecycle

    init(
        store: any BrowserTabSessionSnapshotStoring,
        initialSnapshot: BrowserTabSessionSnapshot?,
        syncCoordinator: (any BrowserSyncCoordinating)? = nil,
        idProvider: @escaping () -> String = { UUID().uuidString },
        dateProvider: @escaping () -> Date = Date.init,
        maximumBufferedWrites: Int = 32,
        maximumBufferedBytes: Int = 32 * 1024 * 1024
    ) throws {
        let initial = initialSnapshot ?? .init(tabs: [])
        try Self.validate(initial)
        self.store = store
        self.snapshot = initial
        self.syncCoordinator = syncCoordinator
        self.idProvider = idProvider
        self.dateProvider = dateProvider
        self.writeBuffer = .init(maximumCount: maximumBufferedWrites, maximumBytes: maximumBufferedBytes)
    }

    convenience init(
        store: any BrowserTabSessionSnapshotStoring,
        loadSnapshot: () throws -> BrowserTabSessionSnapshot?,
        syncCoordinator: (any BrowserSyncCoordinating)? = nil
    ) throws {
        try self.init(store: store, initialSnapshot: loadSnapshot(), syncCoordinator: syncCoordinator)
    }

    // MARK: Internal

    typealias ObserverToken = UUID

    private(set) var snapshot: BrowserTabSessionSnapshot

    var persistenceFailure: BrowserSessionPersistenceFailure? { writeBuffer.failure }
    var hasUncommittedWrites: Bool { !writeBuffer.writes.isEmpty || writeBuffer.isTerminal }
    var canEdit: Bool { !writeBuffer.isTerminal }

    func observe(_ observer: @escaping (BrowserTabSessionSnapshot) -> Void) -> ObserverToken {
        let token = UUID()
        observers[token] = observer
        observer(snapshot)
        return token
    }

    func removeObserver(_ token: ObserverToken) { observers.removeValue(forKey: token) }

    func attachSyncService(_ service: BrowserSyncService) {
        if let previous = syncCoordinator as? BrowserSyncService, previous !== service {
            previous.setSnapshotApplier(nil)
            previous.setLocalPersistenceBlocked(true)
        }
        syncCoordinator = service
        service.setSnapshotApplier(self)
        service.setLocalPersistenceBlocked(hasUncommittedWrites)
    }

    /// The coordinator has already committed this canonical projection and cursor.
    /// A blocked document never retains a response to replay over recovered edits.
    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        guard !hasUncommittedWrites, (try? Self.validate(snapshot)) != nil else { return }
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        notify()
    }

    @discardableResult func retryPersistence() -> Bool {
        guard !writeBuffer.isTerminal else { return false }
        guard !writeBuffer.writes.isEmpty else { return true }
        let succeeded = flush(writeBuffer.writes)
        notify()
        return succeeded
    }

    @discardableResult func createSpace(title: String, systemImageName: String = "globe") -> String? {
        guard let title = Self.nonempty(title), let id = newID(type: .space) else { return nil }
        return apply([.createSpace(id: id, data: .init(title: title, systemImageName: systemImageName))]) ? id : nil
    }

    @discardableResult func renameSpace(id: String, title: String) -> Bool {
        guard let title = Self.nonempty(title) else { return false }
        return apply([.patchSpace(id: id, fields: .init(title: title))])
    }

    @discardableResult func createTab(
        urlString: String = "about:blank", spaceID: String,
        placement: BrowserTabPlacement = .temporary, pinnedFolderID: String? = nil
    ) -> String? {
        guard Self.nonempty(urlString) != nil, let id = newID(type: .tab) else { return nil }
        let date = ISO8601DateFormatter().string(from: dateProvider())
        return apply([.createTab(id: id, data: .init(
            spaceID: spaceID, placement: placement, pinnedFolderID: pinnedFolderID,
            urlString: urlString, lastActivityAt: date
        ))]) ? id : nil
    }

    @discardableResult func updateURL(tabID: String, urlString: String) -> Bool {
        guard Self.nonempty(urlString) != nil, let tab = snapshot.tabs.first(where: { $0.id == tabID }),
              tab.urlString != urlString else { return false }
        return apply([.patchTab(id: tabID, fields: .init(
            urlString: urlString, lastActivityAt: .set(ISO8601DateFormatter().string(from: dateProvider()))
        ))])
    }

    @discardableResult func renameTab(id: String, title: String?) -> Bool {
        apply([.patchTab(
            id: id,
            fields: .init(userTitleOverride: Self.nonempty(title).map(BrowserSyncPatchValue.set) ?? .clear)
        )])
    }

    @discardableResult func setPlacement(
        tabID: String, placement: BrowserTabPlacement, spaceID: String? = nil, pinnedFolderID: String? = nil
    ) -> Bool {
        guard let tab = snapshot.tabs.first(where: { $0.id == tabID }),
              let destinationSpace = spaceID ?? tab.spaceID
        else {
            return false
        }
        return move(items: [.init(entityType: .tab, entityID: tabID)], destination: .tabs(
            spaceID: destinationSpace, placement: placement, pinnedFolderID: pinnedFolderID
        ))
    }

    @discardableResult func setTabPinned(id: String, isPinned: Bool) -> Bool {
        setPlacement(tabID: id, placement: isPinned ? .spacePinned : .temporary)
    }

    @discardableResult func createFolder(
        spaceID: String, parentFolderID: String? = nil, title: String, systemImageName: String? = nil
    ) -> String? {
        guard let title = Self.nonempty(title), let id = newID(type: .folder) else { return nil }
        return apply([.createFolder(id: id, data: .init(
            spaceID: spaceID, parentFolderID: parentFolderID, title: title, systemImageName: systemImageName
        ))]) ? id : nil
    }

    @discardableResult func renameFolder(id: String, title: String) -> Bool {
        guard let title = Self.nonempty(title) else { return false }
        return apply([.patchFolder(id: id, fields: .init(title: title))])
    }

    @discardableResult func setFolderExpanded(id: String, isExpanded: Bool) -> Bool {
        guard let folder = snapshot.pinnedTabFolders?.first(where: { $0.id == id }),
              folder.isExpanded != isExpanded
        else {
            return false
        }
        let folders = snapshot.pinnedTabFolders?.map { value in
            value.id == id
                ? BrowserPinnedTabFolderSessionSnapshot(
                    id: value.id, spaceID: value.spaceID, parentFolderID: value.parentFolderID, title: value.title,
                    systemImageName: value.systemImageName, isExpanded: isExpanded,
                    pinnedSiblingRank: value.pinnedSiblingRank
                )
                : value
        }
        return commit(.init(spaces: snapshot.spaces, pinnedTabFolders: folders, tabs: snapshot.tabs), moveIntent: nil)
    }

    @discardableResult func move(
        items: [BrowserSyncEntityReference], destination: BrowserSyncFolderDestination,
        before: BrowserSyncEntityReference? = nil, after: BrowserSyncEntityReference? = nil
    ) -> Bool {
        guard !items.isEmpty, Set(items).count == items.count,
              before.map({ !items.contains($0) }) ?? true,
              after.map({ !items.contains($0) }) ?? true else { return false }
        return apply(
            [.move(items: items, destination: destination, before: before, after: after)],
            moveIntent: .init(items: items)
        )
    }

    @discardableResult func removeTab(id: String) -> Bool { delete(entity: .init(entityType: .tab, entityID: id)) }

    @discardableResult func delete(entity: BrowserSyncEntityReference) -> Bool {
        let operation: BrowserSyncFolderOperation =
            switch entity.entityType {
            case .space: .deleteSpace(id: entity.entityID)
            case .tab: .deleteTab(id: entity.entityID)
            case .folder: .deleteFolder(id: entity.entityID)
            }
        return apply([operation])
    }

    // MARK: Private

    private let store: any BrowserTabSessionSnapshotStoring
    private var syncCoordinator: (any BrowserSyncCoordinating)?
    private let idProvider: () -> String
    private let dateProvider: () -> Date
    private var writeBuffer: BrowserSessionWriteBuffer
    private var observers = [ObserverToken: (BrowserTabSessionSnapshot) -> Void]()
    private var isNotifying = false
    private var needsNotification = false

    private static func nonempty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func validate(_ snapshot: BrowserTabSessionSnapshot) throws {
        guard (1...BrowserTabSessionSnapshot.currentVersion).contains(snapshot.version) else {
            throw BrowserMobileProfileDocumentError.invalidSnapshot
        }
        let tabs = snapshot.tabs.compactMap(\.id), spaces = (snapshot.spaces ?? []).map(\.id)
        let folders = snapshot.pinnedTabFolders ?? []
        guard tabs.count == snapshot.tabs.count, tabs.allSatisfy({ !$0.isEmpty }), Set(tabs).count == tabs.count,
              spaces.allSatisfy({ !$0.isEmpty }), Set(spaces).count == spaces.count,
              folders.allSatisfy({ !$0.id.isEmpty }), Set(folders.map(\.id)).count == folders.count
        else {
            throw BrowserMobileProfileDocumentError.invalidSnapshot
        }
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) }), spaceIDs = Set(spaces)
        for folder in folders {
            guard spaceIDs.contains(folder.spaceID) else { throw BrowserMobileProfileDocumentError.invalidSnapshot }
            var parent = folder.parentFolderID, visited: Set<String> = [folder.id]
            while let id = parent {
                guard visited.insert(id).inserted, let value = byID[id], value.spaceID == folder.spaceID else {
                    throw BrowserMobileProfileDocumentError.invalidSnapshot
                }
                parent = value.parentFolderID
            }
        }
        for tab in snapshot.tabs {
            guard !tab.urlString.isEmpty,
                  tab.placement == .app || tab.spaceID.map(spaceIDs.contains) == true,
                  tab.pinnedFolderID.map({ tab.placement == .spacePinned && byID[$0]?.spaceID == tab.spaceID }) ?? true
            else {
                throw BrowserMobileProfileDocumentError.invalidSnapshot
            }
        }
    }

    private func apply(_ operations: [BrowserSyncFolderOperation], moveIntent: BrowserSyncMoveIntent? = nil) -> Bool {
        guard canEdit else { return false }
        var values = Dictionary(uniqueKeysWithValues: BrowserSyncFolderProjection.canonicalChanges(snapshot).map {
            (BrowserSyncOutboxProjection.key($0), $0)
        })
        let previousValues = values
        var deleted = Set<String>()
        BrowserSyncFolderProjection.apply(operations, to: &values, deleted: &deleted)
        values = values.filter { $0.value.op == .upsert && !deleted.contains($0.key) }
        guard values != previousValues else { return false }
        let next = BrowserSyncFolderProjection.snapshot(values: values, local: snapshot)
        guard next != snapshot, (try? Self.validate(next)) != nil else { return false }
        return commit(next, moveIntent: moveIntent)
    }

    /// Returns whether the user action was admitted, including a bounded failed
    /// write retained for Retry. A rejected tail never replaces the visible tree.
    private func commit(_ next: BrowserTabSessionSnapshot, moveIntent: BrowserSyncMoveIntent?) -> Bool {
        guard canEdit else { return false }
        let write = BrowserSessionWrite(snapshot: next, origin: .local(syncMove: moveIntent))
        if hasUncommittedWrites {
            guard writeBuffer.append(write) else { blockAndNotify()
                return false
            }
            snapshot = next
            _ = flush(writeBuffer.writes)
        } else {
            do {
                try store.writeSessionBatch([write])
                snapshot = next
                syncCoordinator?.schedulePush(snapshot: next)
            } catch {
                guard writeBuffer.append(write) else { blockAndNotify()
                    return false
                }
                writeBuffer.recordFailure(error)
                snapshot = next
                syncCoordinator?.setLocalPersistenceBlocked(true)
            }
        }
        notify()
        return true
    }

    private func flush(_ writes: [BrowserSessionWrite]) -> Bool {
        do {
            try store.writeSessionBatch(writes)
            writeBuffer.clearAfterSuccess()
            syncCoordinator?.setLocalPersistenceBlocked(false)
            syncCoordinator?.schedulePull()
            syncCoordinator?.schedulePush(snapshot: snapshot)
            return true
        } catch {
            writeBuffer.recordFailure(error)
            syncCoordinator?.setLocalPersistenceBlocked(true)
            return false
        }
    }

    private func blockAndNotify() {
        syncCoordinator?.setLocalPersistenceBlocked(true)
        notify()
    }

    private func newID(type: BrowserSyncChange.EntityType) -> String? {
        let id = idProvider()
        guard !id.isEmpty else { return nil }
        let exists =
            switch type {
            case .space: snapshot.spaces?.contains { $0.id == id } ?? false
            case .tab: snapshot.tabs.contains { $0.id == id }
            case .folder: snapshot.pinnedTabFolders?.contains { $0.id == id } ?? false
            }
        return exists ? nil : id
    }

    private func notify() {
        needsNotification = true
        guard !isNotifying else { return }
        isNotifying = true
        defer { isNotifying = false }
        while needsNotification {
            needsNotification = false
            for token in Array(observers.keys) {
                observers[token]?(snapshot)
            }
        }
    }
}

// MARK: - BrowserMobileProfileDocumentError

enum BrowserMobileProfileDocumentError: Error, Equatable {
    case invalidSnapshot
}
