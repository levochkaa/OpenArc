// BrowserMobileSyncArchiveObservationTests.swift

import Foundation
import Testing
import UIKit

@Test @MainActor func expiryRecoveryOnlyPullNotifiesBothMobileScenesWithoutChangingTheLiveSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileArchiveObservation-\(UUID())")
    let suiteName = "MobileArchiveObservation.\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer {
        preferences.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
    try await runMobileArchiveObservation(directory: directory, preferences: preferences)
}

@MainActor private func runMobileArchiveObservation(directory: URL, preferences: UserDefaults) async throws {
    let databaseURL = directory.appendingPathComponent("Profile.sqlite")
    let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
    let remote = MobileArchiveObservationRemote()
    let auth = MobileArchiveObservationAuth()
    let owner = BrowserSyncOwner(baseURL: remote.baseURL, userID: auth.session.userID)
    try store.bindSyncOwner(owner)
    // This profile already processed the terminal delete with a pre-recovery
    // client. The v5 bootstrap must add Archive content without changing tabs.
    let knownDelete = BrowserSyncEvent(
        serverSeq: 20, deviceID: "remote", entityType: "tab", entityID: "expired", op: "delete",
        data: .deleted(id: "expired"), createdAt: "2026-10-03T12:00:00Z",
    )
    _ = try store.completeFolderSyncBootstrap(events: remote.seed + [knownDelete], cursor: 20, for: owner)
    // Each window shows the phone's own tabs; the pull only feeds the Archive.
    try store.saveMobileTabs(["mobile-a", "mobile-b"].map {
        .init(id: $0, record: .init(urlString: "https://example.com/" + $0, createdAt: Date(timeIntervalSince1970: 0)))
    })
    let document = try BrowserMobileProfileDocument(store: store, loadSnapshot: { try store.loadSnapshotStrict() })
    let firstEngine = MobileArchiveObservationEngine()
    let secondEngine = MobileArchiveObservationEngine()
    let first = BrowserMobileWorkspace(
        engine: firstEngine, sceneID: "first", profileLoader: { document }, preferences: preferences,
    )
    let second = BrowserMobileWorkspace(
        engine: secondEngine, sceneID: "second", profileLoader: { document }, preferences: preferences,
    )
    await first.restore()
    await second.restore()
    first.setSceneAttached(true)
    second.setSceneAttached(true)
    first.selectTab(id: "mobile-a")
    second.selectTab(id: "mobile-b")
    let before = document.snapshot
    let firstTabs = first.tabs
    let secondTabs = second.tabs
    let firstCreated = firstEngine.created
    let secondCreated = secondEngine.created
    let firstNavigated = firstEngine.navigated
    let secondNavigated = secondEngine.navigated
    let firstClosed = firstEngine.closed
    let secondClosed = secondEngine.closed
    #expect(first.selectedTabID == "mobile-a" && second.selectedTabID == "mobile-b")
    #expect(Set(firstTabs.map(\.runtimeID)).isDisjoint(with: secondTabs.map(\.runtimeID)))
    #expect(try store.loadArchivePage().entries.isEmpty)

    var firstRevisions = [Int]()
    var secondRevisions = [Int]()
    first.onChange = { [weak first] in firstRevisions.append(first?.archiveRevision ?? -1) }
    second.onChange = { [weak second] in secondRevisions.append(second?.archiveRevision ?? -1) }
    var observedSnapshots = [BrowserTabSessionSnapshot]()
    let observer = document.observe { observedSnapshots.append($0) }
    defer { document.removeObserver(observer) }
    var failures = [BrowserSyncFailurePhase]()
    let service = BrowserSyncService(
        localStore: store, remoteClient: remote, authSessionStore: auth,
        pushDebounce: .zero, pollInterval: nil, retryDelay: nil, runtimeActive: false,
        errorReporter: { _, phase in failures.append(phase) },
    )
    defer {
        service.setSnapshotApplier(nil)
        service.accountSessionDidChange(nil)
    }
    document.attachSyncService(service)
    service.accountSessionDidChange(auth.session)
    service.setRuntimeActive(true)
    await service.waitForPendingOperations()

    #expect(failures.isEmpty && remote.pushes == 0)
    #expect(remote.requests == [.init(version: 4, cursor: 20), .init(version: 5, cursor: 0)])
    #expect(document.snapshot == before)
    #expect(observedSnapshots == [before, before], "The second notification is caused only by imported Archive content")
    #expect(document.archiveRevision == 1)
    #expect(firstRevisions == [1] && secondRevisions == [1])
    #expect(first.tabs == firstTabs && second.tabs == secondTabs)
    #expect(first.selectedTabID == "mobile-a" && second.selectedTabID == "mobile-b")
    #expect(firstEngine.created == firstCreated && secondEngine.created == secondCreated)
    #expect(firstEngine.navigated == firstNavigated && secondEngine.navigated == secondNavigated)
    #expect(firstEngine.closed == firstClosed && secondEngine.closed == secondClosed)
    let archive = try first.archivePage()
    let entry = try #require(archive.entries.first)
    #expect(archive.entries.count == 1 && entry.tab.id == "expired")
    #expect(entry.tab.urlString == "https://example.com/recovery")
    #expect(entry.tab.userTitleOverride == "Recoverable name")
    #expect(try second.archivePage() == archive)
    #expect(try store.pendingSyncQueue(for: owner).isEmpty)
    #expect(try store.syncPullProtocolVersion(for: owner) == 5)
    #expect(try store.syncArchiveRevision(for: owner) == 1)

    let boundary = try await first.archiveClearBoundary()
    let cleared = await first.clearArchive(through: boundary)
    #expect(cleared)
    #expect(try first.archivePage().entries.isEmpty)
    #expect(try second.archivePage().entries.isEmpty)
    let clearedRevision = document.archiveRevision
    #expect(clearedRevision == 2)
    #expect(firstRevisions.last == clearedRevision && secondRevisions.last == clearedRevision)
    let counts = (firstRevisions.count, secondRevisions.count, observedSnapshots.count)

    // Device re-registration can require the same cursor-zero recovery history.
    // Import receipts must prevent a cleared entry and redundant UI notification.
    remote.requiresBootstrap = true
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(failures.isEmpty && remote.pushes == 0)
    #expect(Array(remote.requests.suffix(2)) == [.init(version: 5, cursor: 20), .init(version: 5, cursor: 0)])
    #expect(document.archiveRevision == clearedRevision)
    #expect(firstRevisions.count == counts.0 && secondRevisions.count == counts.1)
    #expect(observedSnapshots.count == counts.2)
    #expect(document.snapshot == before && first.tabs == firstTabs && second.tabs == secondTabs)
    #expect(firstEngine.created == firstCreated && secondEngine.created == secondCreated)
    #expect(firstEngine.navigated == firstNavigated && secondEngine.navigated == secondNavigated)
    #expect(firstEngine.closed == firstClosed && secondEngine.closed == secondClosed)
    #expect(try store.syncArchiveRevision(for: owner) == 1)
    #expect(try store.pendingSyncQueue(for: owner).isEmpty)
    #expect(try first.archivePage().entries.isEmpty)
    let reopened = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
    #expect(try reopened.loadSnapshotStrict() == before)
    #expect(try reopened.loadArchivePage().entries.isEmpty)

    service.setSnapshotApplier(nil)
    service.setRuntimeActive(false)
    let firstStopped = await first.shutdown()
    let secondStopped = await second.shutdown()
    #expect(firstStopped && secondStopped)
}

// MARK: - MobileArchiveObservationRemote

@MainActor private final class MobileArchiveObservationRemote: BrowserSyncRemoteServing {
    // MARK: Internal

    struct Request: Equatable { let version: Int
        let cursor: Int
    }

    enum UnexpectedPush: Error { case request }

    let baseURL = URL(string: "https://mobile-archive-observation.example")!
    var requests = [Request]()
    var requiresBootstrap = false
    var pushes = 0

    var recoveryTab: BrowserSyncEventTabData {
        .init(
            id: "expired", spaceID: "work", placement: .temporary, rank: 0,
            urlString: "https://example.com/recovery", pinnedURLString: nil, title: "Loaded recovery title",
            userTitleOverride: "Recoverable name", faviconURLString: nil,
            lastActivityAt: "2000-01-01T00:00:00.123456Z", pinnedFolderID: nil,
        )
    }

    var seed: [BrowserSyncEvent] {
        [
            event(sequence: 1, type: "space", id: "work", data: .space(.init(
                id: "work", title: "Work", systemImageName: "globe", rank: 0,
                isPinnedSectionCollapsed: false, selectedTabID: nil,
            ))),
            event(sequence: 2, type: "tab", id: "expired", data: .tab(recoveryTab)),
        ] + ["live-a", "live-b"].enumerated().map { index, id in
            event(sequence: index + 3, type: "tab", id: id, data: .tab(.init(
                id: id, spaceID: "work", placement: .temporary, rank: Double(index + 1),
                urlString: "https://example.com/\(id)", pinnedURLString: nil, title: id,
                userTitleOverride: nil, faviconURLString: nil, lastActivityAt: "2026-10-03T11:00:00Z",
            )))
        }
    }

    func pull(cursor: Int, authSession: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        try pull(cursor: cursor, protocolVersion: 2, authSession: authSession)
    }

    func pull(cursor: Int, protocolVersion: Int, authSession _: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        requests.append(.init(version: protocolVersion, cursor: cursor))
        if requiresBootstrap {
            requiresBootstrap = false
            throw BrowserRemoteSyncError.expiryBootstrapRequired
        }
        let expiry = BrowserSyncEvent(
            serverSeq: 20, deviceID: "remote", entityType: "tab", entityID: "expired", op: "delete",
            data: .deleted(id: "expired", autoArchive: .init(
                archivedAt: "2026-10-03T12:00:00.654321Z", sourceServerSeq: 2, tab: recoveryTab,
            )), createdAt: "2026-10-03T12:00:00Z",
        )
        return .init(
            cursor: 20, events: (seed + [expiry]).filter { $0.serverSeq > cursor },
            protocolVersion: protocolVersion, supportedPushVersions: [2, 3, 4, 5],
        )
    }

    func push(mutation _: BrowserSyncMutation, authSession _: BrowserAuthSession) throws -> BrowserSyncPushResponse {
        pushes += 1
        throw UnexpectedPush.request
    }

    func push(
        mutation _: BrowserSyncSemanticMutation,
        authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncSemanticPushResponse {
        pushes += 1
        throw UnexpectedPush.request
    }

    func push(
        mutation _: BrowserSyncFolderMutation,
        authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncFolderPushResponse {
        pushes += 1
        throw UnexpectedPush.request
    }

    // MARK: Private

    private func event(sequence: Int, type: String, id: String, data: BrowserSyncEventData) -> BrowserSyncEvent {
        .init(
            serverSeq: sequence,
            deviceID: "remote",
            entityType: type,
            entityID: id,
            op: "upsert",
            data: data,
            createdAt: "2026-10-03T11:00:00Z",
        )
    }
}

// MARK: - MobileArchiveObservationAuth

@MainActor private final class MobileArchiveObservationAuth: BrowserSyncAuthSessionReading {
    let session = BrowserAuthSession(
        accessToken: "fixture-only", userID: "owner", userEmail: nil, deviceID: "mobile",
        serverURL: URL(string: "https://mobile-archive-observation.example")!,
    )

    func loadSession() -> BrowserAuthSession? { session }
}

// MARK: - MobileArchiveObservationEngine

@MainActor private final class MobileArchiveObservationEngine: BrowserMobileEngine {
    let hostView = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    var created = [String]()
    var navigated = [String]()
    var closed = [String]()

    func createTab(id: String, url _: URL) { created.append(id) }
    func selectTab(id _: String?) {}
    func navigate(id: String, url _: URL) { navigated.append(id) }
    func closeTab(id: String) { closed.append(id) }
    func goBack(id _: String) {}
    func goForward(id _: String) {}
    func reload(id _: String) {}
    func stop(id _: String) {}
    func setJavaScriptDialogPresentationActive(_: Bool) {}
    func resolveJavaScriptDialog(id _: UUID, response _: BrowserMobileJavaScriptDialogResponse) {}
    func shutdown() {}
}
