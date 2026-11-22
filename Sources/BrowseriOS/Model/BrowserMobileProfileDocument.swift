// BrowserMobileProfileDocument.swift

import Foundation

// MARK: - BrowserMobileProfileDocument

/// One logical profile shared by scene adapters. Scenes submit stable-ID actions;
/// their independently selected tabs and WebKit runtimes never replace this tree.
@MainActor final class BrowserMobileProfileDocument: BrowserSyncSnapshotApplying, BrowserSyncExpiryScheduling {
    // MARK: Internal

    typealias ObserverToken = UUID

    // MARK: Private

    private enum ArchiveMutation {
        case remove(String)
        case clear(BrowserTabArchiveBoundary)
    }

    private struct ExpiryLease {
        let isActive: Bool
        let isHydrated: Bool
        let hydrationCheck: @MainActor () -> Bool
    }

    let downloads: BrowserMobileDownloads?

    private(set) var snapshot: BrowserTabSessionSnapshot
    private(set) var archiveError: String?
    private(set) var archiveRevision = 0
    private(set) var isArchiveOperationInFlight = false
    private(set) var automaticTabArchivalEnabled = false
    private(set) var temporaryTabLifetime = BrowserTemporaryTabLifetime.defaultValue
    private(set) var automaticTabArchivalError: String?
    weak var syncSession: BrowserMobileSyncSession?

    private let store: any BrowserTabSessionSnapshotStoring
    private var syncCoordinator: (any BrowserSyncCoordinating)?
    private let idProvider: () -> String
    private let dateProvider: () -> Date
    private var writeBuffer: BrowserSessionWriteBuffer
    private var observers = [ObserverToken: (BrowserTabSessionSnapshot) -> Void]()
    private var selectionLeases = [UUID: String]()
    private var expiryLeases = [UUID: ExpiryLease]()
    private var automaticArchivalSettingsLoaded = false
    private let automaticArchivalCheckInterval: Duration?
    private var localArchivalTask: Task<Void, Never>?
    private var lastLocalActivityRefresh: TimeInterval?
    private var isNotifying = false
    private var needsNotification = false

    var persistenceFailure: BrowserSessionPersistenceFailure? { writeBuffer.failure }
    var hasUncommittedWrites: Bool { !writeBuffer.writes.isEmpty || writeBuffer.isTerminal }
    var canEdit: Bool { !writeBuffer.isTerminal }
    var supportsArchive: Bool { store is any BrowserTabArchiveStoring }
    var canManageArchive: Bool {
        supportsArchive && canEdit && !hasUncommittedWrites && !isArchiveOperationInFlight
    }

    var canRestoreArchivedTab: Bool { canManageArchive }
    var supportsAutomaticTabArchival: Bool { store is BrowserSQLiteSessionStore }

    /// Protection is local to attached windows, never a claim about another
    /// device. A stale lease cannot recreate or protect a deleted identity.
    var protectedTabIDs: Set<String> {
        Set(selectionLeases.values).intersection(snapshot.tabs.compactMap(\.id))
    }

    init(
        store: any BrowserTabSessionSnapshotStoring,
        initialSnapshot: BrowserTabSessionSnapshot?,
        syncCoordinator: (any BrowserSyncCoordinating)? = nil,
        downloads: BrowserMobileDownloads? = nil,
        idProvider: @escaping () -> String = { UUID().uuidString },
        dateProvider: @escaping () -> Date = Date.init,
        automaticArchivalCheckInterval: Duration? = .seconds(60),
        maximumBufferedWrites: Int = 32,
        maximumBufferedBytes: Int = 32 * 1024 * 1024,
    ) throws {
        let initial = initialSnapshot ?? .init(tabs: [])
        try Self.validate(initial)
        self.store = store
        self.snapshot = initial
        self.syncCoordinator = syncCoordinator
        self.downloads = downloads
        self.idProvider = idProvider
        self.dateProvider = dateProvider
        self.automaticArchivalCheckInterval = automaticArchivalCheckInterval
        self.writeBuffer = .init(maximumCount: maximumBufferedWrites, maximumBytes: maximumBufferedBytes)
        reloadAutomaticTabArchivalSettings()
    }

    convenience init(
        store: any BrowserTabSessionSnapshotStoring,
        loadSnapshot: () throws -> BrowserTabSessionSnapshot?,
        syncCoordinator: (any BrowserSyncCoordinating)? = nil,
        downloads: BrowserMobileDownloads? = nil,
    ) throws {
        try self.init(
            store: store, initialSnapshot: loadSnapshot(), syncCoordinator: syncCoordinator, downloads: downloads,
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func newActivity(
        tab: BrowserTabSessionSnapshotTab, now: TimeInterval, formatter: ISO8601DateFormatter,
    ) -> String? {
        guard now.isFinite else { return nil }
        let second = floor(now)
        if let previous = tab.lastActivityTimestamp, previous.isFinite, second <= previous {
            return nil
        }
        return formatter.string(from: Date(timeIntervalSince1970: second))
    }

    private static func archiveErrorMessage(_ error: Error) -> String {
        guard let error = error as? BrowserTabArchiveError else { return error.localizedDescription }
        switch error {
        case .archiveAlreadyRestored,
             .entryMissing:
            return String(localized: "This archived tab is no longer available.", table: "Mobile")
        case .unsupportedStore:
            return String(localized: "Archive is unavailable for this profile.", table: "Mobile")
        case .invalidCursor,
             .invalidLimit:
            return String(localized: "The archive could not be loaded. Try again.", table: "Mobile")
        case .invalidQuery:
            return String(localized: "Use a shorter search.", table: "Mobile")
        case .archiveIDConflict,
             .invalidBoundary,
             .invalidEntry,
             .invalidTransition,
             .requiresLocalWrite,
             .restoredTabIDNotFresh:
            return String(localized: "This archive action could not be completed. Try again.", table: "Mobile")
        }
    }

    private static func validate(_ snapshot: BrowserTabSessionSnapshot) throws {
        guard (1...BrowserTabSessionSnapshot.currentVersion).contains(snapshot.version) else {
            throw BrowserMobileProfileDocumentError.invalidSnapshot
        }
        let tabs = snapshot.tabs.compactMap(\.id)
        let spaces = (snapshot.spaces ?? []).map(\.id)
        let folders = snapshot.pinnedTabFolders ?? []
        guard tabs.count == snapshot.tabs.count, tabs.allSatisfy({ !$0.isEmpty }), Set(tabs).count == tabs.count,
              spaces.allSatisfy({ !$0.isEmpty }), Set(spaces).count == spaces.count,
              folders.allSatisfy({ !$0.id.isEmpty }), Set(folders.map(\.id)).count == folders.count
        else {
            throw BrowserMobileProfileDocumentError.invalidSnapshot
        }
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let spaceIDs = Set(spaces)
        for folder in folders {
            guard spaceIDs.contains(folder.spaceID) else { throw BrowserMobileProfileDocumentError.invalidSnapshot }
            var parent = folder.parentFolderID
            var visited: Set<String> = [folder.id]
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

    @discardableResult func setAutomaticTabArchival(lifetime: BrowserTemporaryTabLifetime?) -> Bool {
        guard canManageArchive, let sqlite = store as? BrowserSQLiteSessionStore else { return false }
        let chosen = lifetime ?? temporaryTabLifetime
        do {
            try sqlite.saveAutomaticTabArchival(enabled: lifetime != nil, lifetime: chosen)
            automaticTabArchivalEnabled = lifetime != nil
            temporaryTabLifetime = chosen
            automaticTabArchivalError = nil
            automaticArchivalSettingsLoaded = true
            notify()
            requestAutomaticArchivalCheck()
            return true
        } catch {
            automaticTabArchivalError = String(
                localized: "Auto-Archive settings could not be saved. Try again.",
                table: "Mobile",
            )
            notify()
            return false
        }
    }

    func reloadAutomaticTabArchivalSettings() {
        guard let sqlite = store as? BrowserSQLiteSessionStore else { return }
        do {
            let settings = try sqlite.loadAutomaticTabArchivalSettings()
            automaticTabArchivalEnabled = settings.enabled
            temporaryTabLifetime = settings.lifetime
            automaticArchivalSettingsLoaded = true
            automaticTabArchivalError = nil
        } catch {
            automaticArchivalSettingsLoaded = false
            automaticTabArchivalError = String(
                localized: "Auto-Archive settings could not be loaded. Try again.",
                table: "Mobile",
            )
        }
        notify()
    }

    func updateSelectionLease(owner: UUID, selectedTabID: String?) {
        selectionLeases[owner] = selectedTabID
    }

    func removeSelectionLease(owner: UUID) {
        selectionLeases.removeValue(forKey: owner)
        expiryLeases.removeValue(forKey: owner)
        updateLocalArchivalTimer()
    }

    /// The check belongs to the scene registry and includes windows whose
    /// asynchronous profile load has not yet produced a selection lease.
    func updateExpiryLease(
        owner: UUID, isActive: Bool, isHydrated: Bool,
        hydrationCheck: @escaping @MainActor () -> Bool,
    ) {
        let previous = expiryLeases[owner]
        expiryLeases[owner] = .init(isActive: isActive, isHydrated: isHydrated, hydrationCheck: hydrationCheck)
        updateLocalArchivalTimer()
        if previous?.isActive != isActive || previous?.isHydrated != isHydrated {
            (syncCoordinator as? BrowserSyncService)?.requestExpirySweep()
        }
    }

    func expirySchedulingState() -> BrowserSyncExpirySchedulingState? {
        guard canManageArchive, automaticArchivalSettingsLoaded, !expiryLeases.isEmpty,
              expiryLeases.values.contains(where: \.isActive),
              expiryLeases.values.allSatisfy({ $0.isHydrated && $0.hydrationCheck() })
        else { return nil }
        return .init(
            inactiveForSeconds: automaticTabArchivalEnabled ? Int(temporaryTabLifetime.timeInterval) : nil,
            protectedTabIDs: protectedTabIDs,
        )
    }

    func refreshExpiryActivity() -> Bool {
        guard expirySchedulingState() != nil else { return false }
        let selected = Set(expiryLeases.compactMap { owner, lease in lease.isActive ? selectionLeases[owner] : nil })
        _ = recordActivity(tabIDs: selected)
        return !hasUncommittedWrites && expirySchedulingState() != nil
    }

    /// Never use local deletion for a profile that has adopted sync, including
    /// Pause/logout/offline. The shared service owns conditional server expiry.
    func performAutomaticTabArchivalCheck() {
        guard let state = expirySchedulingState(), let sqlite = store as? BrowserSQLiteSessionStore else { return }
        do {
            guard try sqlite.syncOwner() == nil else { return }
            let now = dateProvider().timeIntervalSince1970
            guard now.isFinite else { return }
            if lastLocalActivityRefresh.map({ now < $0 || now - $0 >= 300 }) ?? true {
                guard refreshExpiryActivity() else { return }
                lastLocalActivityRefresh = now
            }
            guard let interval = state.inactiveForSeconds else { return }
            let cutoff = now - Double(interval)
            let candidates = snapshot.tabs
                .filter { tab in
                    guard tab.placement == .temporary, let id = tab.id, !state.protectedTabIDs.contains(id),
                          let activity = tab.lastActivityTimestamp, activity.isFinite, activity <= now
                    else { return false }
                    return activity <= cutoff
                }
                .prefix(100)
                .compactMap(\.id)
            for id in candidates {
                guard expirySchedulingState()?.inactiveForSeconds == interval, !protectedTabIDs.contains(id),
                      let tab = snapshot.tabs.first(where: { $0.id == id }), tab.placement == .temporary,
                      let activity = tab.lastActivityTimestamp, activity.isFinite, activity <= cutoff,
                      try sqlite.syncOwner() == nil, archiveTab(id: id), !hasUncommittedWrites else { return }
            }
        } catch {
            automaticTabArchivalError = String(
                localized: "Auto-Archive could not check this profile. Try again.",
                table: "Mobile",
            )
            notify()
        }
    }

    @discardableResult func recordActivity(tabIDs: Set<String>) -> Bool {
        guard canEdit, !tabIDs.isEmpty else { return false }
        let now = dateProvider().timeIntervalSince1970
        let formatter = ISO8601DateFormatter()
        let operations: [BrowserSyncFolderOperation] = snapshot.tabs.compactMap { tab in
            guard let id = tab.id, tabIDs.contains(id),
                  let activity = Self.newActivity(tab: tab, now: now, formatter: formatter)
            else { return nil }
            return .patchTab(id: id, fields: .init(lastActivityAt: .set(activity)))
        }
        guard !operations.isEmpty else { return false }
        return apply(operations)
    }

    func archivePage(before: BrowserTabArchiveCursor? = nil, limit: Int = 50) throws -> BrowserTabArchivePage {
        guard let archive = store as? any BrowserTabArchiveStoring
        else { throw BrowserTabArchiveError.unsupportedStore }
        return try archive.loadArchivePage(before: before, limit: limit)
    }

    func searchArchivePage(
        query: String, before: BrowserTabArchiveCursor? = nil, limit: Int = 50,
    ) async throws -> BrowserTabArchivePage {
        guard let archive = store as? any BrowserTabArchiveStoring
        else { throw BrowserTabArchiveError.unsupportedStore }
        return try await archive.searchArchivePage(query: query, before: before, limit: limit)
    }

    /// Capture before showing confirmation. Later closes must survive a clear
    /// even when their archive dates precede this boundary's entries.
    func archiveClearBoundary() async throws -> BrowserTabArchiveBoundary {
        guard let archive = store as? any BrowserTabArchiveStoring
        else { throw BrowserTabArchiveError.unsupportedStore }
        return try await archive.archiveClearBoundary()
    }

    @discardableResult func deleteArchivedTab(id: String) async -> Bool {
        await performArchiveMutation(.remove(id))
    }

    @discardableResult func clearArchive(through boundary: BrowserTabArchiveBoundary) async -> Bool {
        await performArchiveMutation(.clear(boundary))
    }

    /// Only an explicit Today close creates an archive entry. The entry uses the
    /// current shared row, never a stale sidebar or another scene's URL.
    @discardableResult func archiveTab(id: String, displayTitle: String? = nil) -> Bool {
        archiveTabEntry(id: id, displayTitle: displayTitle) != nil
    }

    /// Archives the tab and returns its archive entry's ID, to restore it by.
    @discardableResult func archiveTabEntry(id: String, displayTitle: String? = nil) -> String? {
        guard canRestoreArchivedTab,
              let tab = snapshot.tabs.first(where: { $0.id == id }), tab.placement == .temporary
        else { return nil }
        let archiveID = idProvider()
        guard !archiveID.isEmpty else { return nil }
        let entry = BrowserTabArchiveEntry(
            id: archiveID, tab: tab, archivedAt: dateProvider().timeIntervalSince1970,
            title: Self.nonempty(displayTitle),
        )
        archiveError = nil
        return apply([.deleteTab(id: id)], archiveAction: .insert(entry)) ? archiveID : nil
    }

    /// Restoring is a new logical tab. A deleted Space is never implicitly
    /// recreated, and the consumed archive identity cannot be restored twice.
    @discardableResult func restoreArchivedTab(id: String, toSpaceID: String? = nil) -> String? {
        guard canRestoreArchivedTab, let archive = store as? any BrowserTabArchiveStoring else { return nil }
        do {
            guard let entry = try archive.loadArchiveEntry(id: id) else {
                throw BrowserTabArchiveError.entryMissing
            }
            guard let destination = toSpaceID ?? entry.tab.spaceID,
                  snapshot.spaces?.contains(where: { $0.id == destination }) == true
            else {
                archiveError = String(localized: "Choose an existing Space to restore this tab.", table: "Mobile")
                notify()
                return nil
            }
            guard let tabID = newID(type: .tab), tabID != entry.tab.id else {
                throw BrowserTabArchiveError.restoredTabIDNotFresh
            }
            let restored = BrowserTabSessionSnapshotTab(
                id: tabID, urlString: entry.tab.urlString, userTitleOverride: entry.tab.userTitleOverride,
                placement: .temporary, spaceID: destination,
                lastActivityTimestamp: dateProvider().timeIntervalSince1970,
            )
            let next = BrowserTabSessionSnapshot(
                spaces: snapshot.spaces, pinnedTabFolders: snapshot.pinnedTabFolders,
                tabs: snapshot.tabs + [restored],
            )
            try Self.validate(next)
            archiveError = nil
            return commit(next, moveIntent: nil, archiveAction: .restore(archiveID: id, tabID: tabID)) ? tabID : nil
        } catch {
            archiveError = Self.archiveErrorMessage(error)
            notify()
            return nil
        }
    }

    func observe(_ observer: @escaping (BrowserTabSessionSnapshot) -> Void) -> ObserverToken {
        let token = UUID()
        observers[token] = observer
        observer(snapshot)
        return token
    }

    func removeObserver(_ token: ObserverToken) { observers.removeValue(forKey: token) }

    func attachSyncService(_ service: BrowserSyncService) {
        if let previous = syncCoordinator as? BrowserSyncService, previous !== service {
            previous.setExpiryScheduler(nil)
            previous.setSnapshotApplier(nil)
            previous.setLocalPersistenceBlocked(true)
        }
        syncCoordinator = service
        service.setSnapshotApplier(self)
        service.setExpiryScheduler(self)
        service.setLocalPersistenceBlocked(hasUncommittedWrites)
    }

    /// The coordinator has already committed this canonical projection and cursor.
    /// A blocked document never retains a response to replay over recovered edits.
    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        guard !hasUncommittedWrites, (try? Self.validate(snapshot)) != nil, self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        notify()
    }

    func syncArchiveDidChange() {
        archiveRevision &+= 1
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
        placement: BrowserTabPlacement = .temporary, pinnedFolderID: String? = nil,
    ) -> String? {
        guard Self.nonempty(urlString) != nil, let id = newID(type: .tab) else { return nil }
        let date = ISO8601DateFormatter().string(from: dateProvider())
        return apply([.createTab(id: id, data: .init(
            spaceID: spaceID, placement: placement, pinnedFolderID: pinnedFolderID,
            urlString: urlString, lastActivityAt: date,
        ))]) ? id : nil
    }

    @discardableResult func updateURL(tabID: String, urlString: String) -> Bool {
        guard Self.nonempty(urlString) != nil, let tab = snapshot.tabs.first(where: { $0.id == tabID }),
              tab.urlString != urlString else { return false }
        let activity = Self.newActivity(
            tab: tab, now: dateProvider().timeIntervalSince1970, formatter: ISO8601DateFormatter(),
        )
        return apply([.patchTab(id: tabID, fields: .init(
            urlString: urlString, lastActivityAt: activity.map(BrowserSyncPatchValue.set) ?? .unchanged,
        ))])
    }

    /// Keeps the page's title so the tab shows it while unloaded. It stays on
    /// this device: sync never sends it.
    @discardableResult func setPageTitle(tabID: String, title: String) -> Bool {
        let title = Self.nonempty(title)
        guard canEdit, let index = snapshot.tabs.firstIndex(where: { $0.id == tabID }),
              snapshot.tabs[index].pageTitle != title else { return false }
        let tab = snapshot.tabs[index]
        var tabs = snapshot.tabs
        tabs[index] = BrowserTabSessionSnapshotTab(
            id: tab.id, urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
            userTitleOverride: tab.userTitleOverride, placement: tab.placement, spaceID: tab.spaceID,
            pinnedFolderID: tab.pinnedFolderID, lastActivityTimestamp: tab.lastActivityTimestamp,
            pinnedSiblingRank: tab.pinnedSiblingRank, pageTitle: title, systemImageName: tab.systemImageName,
        )
        let next = BrowserTabSessionSnapshot(
            version: snapshot.version, spaces: snapshot.spaces, pinnedTabFolders: snapshot.pinnedTabFolders,
            tabs: tabs, splitGroups: snapshot.splitGroups,
        )
        return commit(next, moveIntent: nil)
    }

    @discardableResult func renameTab(id: String, title: String?) -> Bool {
        apply([.patchTab(
            id: id,
            fields: .init(userTitleOverride: Self.nonempty(title).map(BrowserSyncPatchValue.set) ?? .clear),
        )])
    }

    @discardableResult func setPlacement(
        tabID: String, placement: BrowserTabPlacement, spaceID: String? = nil, pinnedFolderID: String? = nil,
    ) -> Bool {
        guard let tab = snapshot.tabs.first(where: { $0.id == tabID }),
              let destinationSpace = spaceID ?? tab.spaceID
        else {
            return false
        }
        return move(items: [.init(entityType: .tab, entityID: tabID)], destination: .tabs(
            spaceID: destinationSpace, placement: placement, pinnedFolderID: pinnedFolderID,
        ))
    }

    @discardableResult func setTabPinned(id: String, isPinned: Bool) -> Bool {
        setPlacement(tabID: id, placement: isPinned ? .spacePinned : .temporary)
    }

    @discardableResult func createFolder(
        spaceID: String, parentFolderID: String? = nil, title: String, systemImageName: String? = nil,
    ) -> String? {
        guard let title = Self.nonempty(title), let id = newID(type: .folder) else { return nil }
        return apply([.createFolder(id: id, data: .init(
            spaceID: spaceID, parentFolderID: parentFolderID, title: title, systemImageName: systemImageName,
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
                    pinnedSiblingRank: value.pinnedSiblingRank,
                )
                : value
        }
        return commit(.init(spaces: snapshot.spaces, pinnedTabFolders: folders, tabs: snapshot.tabs), moveIntent: nil)
    }

    @discardableResult func move(
        items: [BrowserSyncEntityReference], destination: BrowserSyncFolderDestination,
        before: BrowserSyncEntityReference? = nil, after: BrowserSyncEntityReference? = nil,
    ) -> Bool {
        guard !items.isEmpty, Set(items).count == items.count,
              before.map({ !items.contains($0) }) ?? true,
              after.map({ !items.contains($0) }) ?? true else { return false }
        return apply(
            [.move(items: items, destination: destination, before: before, after: after)],
            moveIntent: .init(items: items), recordTodayTransitions: true,
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

    private func requestAutomaticArchivalCheck() {
        (syncCoordinator as? BrowserSyncService)?.requestExpirySweep()
        updateLocalArchivalTimer()
        if automaticArchivalCheckInterval != nil {
            Task { @MainActor [weak self] in self?.performAutomaticTabArchivalCheck() }
        }
    }

    private func updateLocalArchivalTimer() {
        guard expiryLeases.values.contains(where: \.isActive), let interval = automaticArchivalCheckInterval else {
            localArchivalTask?.cancel()
            localArchivalTask = nil
            return
        }
        guard localArchivalTask == nil else { return }
        localArchivalTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.performAutomaticTabArchivalCheck()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func performArchiveMutation(_ mutation: ArchiveMutation) async -> Bool {
        guard canManageArchive, let archive = store as? any BrowserTabArchiveStoring else { return false }
        isArchiveOperationInFlight = true
        archiveError = nil
        notify()
        defer {
            isArchiveOperationInFlight = false
            notify()
        }
        do {
            switch mutation {
            case .remove(let id): let _: Bool = try await archive.removeArchiveEntry(id: id)
            case .clear(let boundary): let _: Int = try await archive.clearArchive(through: boundary)
            }
            // Missing/previously removed entries are successful idempotent
            // actions. Refresh other windows that may still display them.
            archiveRevision &+= 1
            return true
        } catch {
            archiveError = error is BrowserTabArchiveError
                ? Self.archiveErrorMessage(error)
                : String(localized: "This archive action could not be completed. Try again.", table: "Mobile")
            return false
        }
    }

    private func apply(
        _ operations: [BrowserSyncFolderOperation], moveIntent: BrowserSyncMoveIntent? = nil,
        archiveAction: BrowserTabArchiveAction? = nil, recordTodayTransitions: Bool = false,
    ) -> Bool {
        guard canEdit else { return false }
        var values = Dictionary(uniqueKeysWithValues: BrowserSyncFolderProjection.canonicalChanges(snapshot).map {
            (BrowserSyncOutboxProjection.key($0), $0)
        })
        let previousValues = values
        var deleted = Set<String>()
        BrowserSyncFolderProjection.apply(operations, to: &values, deleted: &deleted)
        if recordTodayTransitions {
            let now = dateProvider().timeIntervalSince1970
            let formatter = ISO8601DateFormatter()
            let activity: [BrowserSyncFolderOperation] = snapshot.tabs.compactMap { tab in
                guard tab.placement != .temporary, let id = tab.id,
                      values[BrowserSyncOutboxProjection.key(type: .tab, id: id)]?.tabData?.placement == .temporary,
                      let date = Self.newActivity(tab: tab, now: now, formatter: formatter)
                else { return nil }
                return .patchTab(id: id, fields: .init(lastActivityAt: .set(date)))
            }
            BrowserSyncFolderProjection.apply(activity, to: &values, deleted: &deleted)
        }
        values = values.filter { $0.value.op == .upsert && !deleted.contains($0.key) }
        guard values != previousValues else { return false }
        let next = BrowserSyncFolderProjection.snapshot(values: values, local: snapshot)
        guard next != snapshot, (try? Self.validate(next)) != nil else { return false }
        return commit(next, moveIntent: moveIntent, archiveAction: archiveAction)
    }

    /// Returns whether the user action was admitted, including a bounded failed
    /// write retained for Retry. A rejected tail never replaces the visible tree.
    private func commit(
        _ next: BrowserTabSessionSnapshot, moveIntent: BrowserSyncMoveIntent?,
        archiveAction: BrowserTabArchiveAction? = nil,
    ) -> Bool {
        guard canEdit else { return false }
        let write = BrowserSessionWrite(
            snapshot: next,
            origin: .local(syncMove: moveIntent),
            archiveAction: archiveAction,
        )
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
                if archiveAction != nil {
                    archiveRevision &+= 1
                }
                syncCoordinator?.schedulePush(snapshot: next)
            } catch {
                if archiveAction != nil, error is BrowserTabArchiveError {
                    archiveError = Self.archiveErrorMessage(error)
                    notify()
                    return false
                }
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
            if writes.contains(where: { $0.archiveAction != nil }) {
                archiveRevision &+= 1
                archiveError = nil
            }
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
