import Foundation
import Testing

// MARK: - BrowserSyncHTTPIntegrationTests

@Suite(
    .serialized,
    .enabled(if: SyncHTTPFixture.environmentPath != nil, "Run ./script/test_swift_sync.sh for localhost integration")
)
@MainActor struct BrowserSyncHTTPIntegrationTests {
    @Test(arguments: [false, true])
    func semanticRenameAndMoveCommuteAndReplayPreservesLaterState(patchFirst: Bool) async throws {
        let fixture = try SyncHTTPFixture.load()
        let scenario = patchFirst ? "semantic-patch-first" : "semantic-move-first"
        let account = try fixture.account(scenario)
        let configuration = try #require(BrowserSyncConfiguration(baseURL: fixture.baseURL))
        let firstSession = URLSession(configuration: .ephemeral)
        let secondSession = URLSession(configuration: .ephemeral)
        defer {
            firstSession.invalidateAndCancel()
            secondSession.invalidateAndCancel()
        }
        let first = BrowserRemoteSyncClient(configuration: configuration, session: firstSession)
        let second = BrowserRemoteSyncClient(configuration: configuration, session: secondSession)
        func credentials(_ device: SyncHTTPFixture.Device) -> BrowserAuthSession {
            BrowserAuthSession(
                accessToken: device.accessToken, userID: device.userID, userEmail: nil,
                deviceID: device.deviceID, serverURL: fixture.baseURL
            )
        }
        let firstAuth = credentials(account.devices[0])
        let secondAuth = credentials(account.devices[1])
        let capabilities = try await first.pull(cursor: 0, authSession: firstAuth)
        #expect(capabilities.protocolVersion == 2)
        #expect(capabilities.supportedPushVersions?.contains(3) == true)
        let seed = BrowserSyncSemanticMutation(id: UUID().uuidString, operations: [
            .createSpace(id: "source", data: .init(title: "Source", systemImageName: "globe")),
            .createSpace(id: "target", data: .init(title: "Target", systemImageName: "star")),
            .createTab(
                id: "moving",
                data: .init(spaceID: "source", placement: .temporary, urlString: "https://moving.example")
            ),
            .createTab(
                id: "source-sentinel",
                data: .init(spaceID: "source", placement: .temporary, urlString: "https://source.example")
            ),
            .createTab(
                id: "anchor",
                data: .init(spaceID: "target", placement: .temporary, urlString: "https://anchor.example")
            ),
        ])
        let seeded = try await first.push(mutation: seed, authSession: firstAuth)
        #expect(seeded.protocolVersion == 3 && seeded.mutationID == seed.id)
        // Both devices prepare independent intent from the same starting state.
        // Exercise both delivery orders through the real typed transport.
        let title = String(repeating: "semantic-title-", count: 160)
        let patch = BrowserSyncSemanticMutation(id: UUID().uuidString, operations: [
            .patchTab(id: "moving", fields: .init(userTitleOverride: .set(title))),
        ])
        let move = BrowserSyncSemanticMutation(id: UUID().uuidString, operations: [
            .moveTabs(
                ids: ["moving"],
                destination: .init(spaceID: "target", placement: .temporary),
                beforeID: "anchor",
                afterID: nil
            ),
        ])
        let moveReceipt: BrowserSyncSemanticPushResponse
        if patchFirst {
            _ = try await first.push(mutation: patch, authSession: firstAuth)
            moveReceipt = try await second.push(mutation: move, authSession: secondAuth)
        } else {
            moveReceipt = try await second.push(mutation: move, authSession: secondAuth)
            _ = try await first.push(mutation: patch, authSession: firstAuth)
        }
        let combined = try await fixture.inspect(account)
        let moving = try #require(combined.tabs.first { $0.id == "moving" })
        #expect(moving.title == title && moving.spaceID == "target" && !moving.deleted)
        #expect(combined.tabs.filter { !$0.deleted && $0.spaceID == "target" }.map(\.id) == ["moving", "anchor"])
        #expect(combined.tabs.filter { !$0.deleted && $0.spaceID == "source" }.map(\.id) == ["source-sentinel"])
        #expect(combined.attempts.contains { $0.mutationID == patch.id && $0.compressed && $0.protocolVersion == 3 })

        let later = BrowserSyncSemanticMutation(id: UUID().uuidString, operations: [
            .patchTab(id: "moving", fields: .init(userTitleOverride: .clear)),
            .moveTabs(
                ids: ["moving"],
                destination: .init(spaceID: "source", placement: .temporary),
                beforeID: "source-sentinel",
                afterID: nil
            ),
        ])
        _ = try await first.push(mutation: later, authSession: firstAuth)
        let beforeReplay = try await fixture.inspect(account)
        let replay = try await second.push(mutation: move, authSession: secondAuth)
        let afterReplay = try await fixture.inspect(account)
        #expect(replay.mutationID == move.id && replay.events == moveReceipt.events)
        #expect(afterReplay.eventCount == beforeReplay.eventCount)
        #expect(afterReplay.receiptCount == beforeReplay.receiptCount)
        let finalMoving = try #require(afterReplay.tabs.first { $0.id == "moving" })
        #expect(finalMoving.title == nil && finalMoving.spaceID == "source")
        #expect(afterReplay.tabs.filter { !$0.deleted && $0.spaceID == "source" }.map(\.id) == [
            "moving",
            "source-sentinel",
        ])
        let firstPull = try await first.pull(cursor: 0, authSession: firstAuth)
        let secondPull = try await second.pull(cursor: 0, authSession: secondAuth)
        #expect(firstPull.events == secondPull.events && firstPull.cursor == secondPull.cursor)
        try await fixture.complete(account)
    }

    @Test func offlineDeletionSurvivesSQLiteReopenAndRemoteEdits() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("offline-delete")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let initial = syncHTTPSnapshot()
        first.store.saveSnapshot(initial)
        await first.activate()
        var second: SyncHTTPProfile? = try SyncHTTPProfile(
            fixture: fixture,
            device: account.devices[1],
            directory: directory
        )
        await second?.activate()
        #expect(second?.store.loadSnapshot()?.tabs.map(\.id) == initial.tabs.map(\.id))

        await second?.disconnect()
        let deletedID = try #require(initial.tabs.first?.id)
        let survivor = try syncHTTPSnapshot(spaceID: #require(initial.spaces?.first?.id), tabs: [initial.tabs[1]])
        second?.store.saveSnapshot(survivor)
        #expect(second?.store.loadSnapshot()?.tabs.map(\.id) == survivor.tabs.map(\.id))
        second = nil

        // Another device edits the deleted identity while this SQLite profile is offline.
        let stale = try syncHTTPSnapshot(
            spaceID: #require(initial.spaces?.first?.id),
            tabs: [syncHTTPTab(copying: initial.tabs[0], title: "remote edit while offline"), initial.tabs[1]]
        )
        await first.saveAndSend(stale)
        second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        #expect(second?.store.loadSnapshot()?.tabs.map(\.id) == survivor.tabs.map(\.id))
        await second?.activate()
        await first.pull()

        #expect(first.store.loadSnapshot()?.tabs.map(\.id) == survivor.tabs.map(\.id))
        #expect(second?.store.loadSnapshot()?.tabs.map(\.id) == survivor.tabs.map(\.id))
        let state = try await fixture.inspect(account)
        #expect(state.tabs.first { $0.id == deletedID }?.deleted == true)
        #expect(state.tabs.filter { !$0.deleted }.map(\.id) == survivor.tabs.compactMap(\.id))
        await second?.disconnect()
        await first.disconnect()
        try await fixture.complete(account)
    }

    @Test func lostAcknowledgementReplaysExactMutationWithoutRollingBackOtherDevice() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("lost-ack")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: SyncHTTPProfile? = try SyncHTTPProfile(
            fixture: fixture,
            device: account.devices[0],
            directory: directory
        )
        let initial = syncHTTPSnapshot()
        first?.store.saveSnapshot(initial)
        await first?.activate()
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        let spaceID = try #require(initial.spaces?.first?.id)
        let oldEdit = syncHTTPSnapshot(
            spaceID: spaceID,
            tabs: [
                syncHTTPTab(copying: initial.tabs[0], title: String(repeating: "lost-ack-", count: 200)),
                initial.tabs[1],
            ]
        )
        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        await first?.saveAndSend(oldEdit)
        let afterDrop = try await fixture.inspect(account)
        let lostAttempt = try #require(afterDrop.attempts.last { $0.deviceID == account.devices[0].deviceID })
        #expect(lostAttempt.status == 201)
        #expect(lostAttempt.compressed, "Exercise the production gzip request path")
        await first?.disconnect()
        first = nil

        await second.pull()
        let newer = syncHTTPSnapshot(
            spaceID: spaceID,
            tabs: [initial.tabs[1], syncHTTPTab(copying: initial.tabs[0], title: "newer remote title")]
        )
        await second.saveAndSend(newer)
        let beforeRetry = try await fixture.inspect(account)
        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        await first?.activate()
        await first?.pull()
        await second.pull()
        let afterRetry = try await fixture.inspect(account)
        let retries = afterRetry.attempts.filter { $0.mutationID == lostAttempt.mutationID }
        let attemptsBeforeReopen = beforeRetry.attempts.filter { $0.mutationID == lostAttempt.mutationID }.count

        #expect(retries.count > attemptsBeforeReopen, "Reopened SQLite outbox must retry the committed mutation")
        #expect(Set(retries.map(\.digest)) == [lostAttempt.digest])
        #expect(afterRetry.eventCount == beforeRetry.eventCount, "Receipt replay must append no event")
        #expect(afterRetry.receiptCount == beforeRetry.receiptCount)
        #expect(first?.store.loadSnapshot()?.tabs == newer.tabs)
        #expect(second.store.loadSnapshot()?.tabs == newer.tabs)
        #expect(afterRetry.tabs.filter { !$0.deleted }.map(\.id) == newer.tabs.compactMap(\.id))
        #expect(afterRetry.tabs.first { $0.id == initial.tabs[0].id }?.title == "newer remote title")
        await first?.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }

    @Test func localEditWhileAcknowledgementIsHeldRemainsQueuedAndConverges() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("edit-during-ack")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let initial = syncHTTPSnapshot()
        first.store.saveSnapshot(initial)
        await first.activate()
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        let spaceID = try #require(initial.spaces?.first?.id)
        let intermediate = syncHTTPSnapshot(
            spaceID: spaceID, tabs: [syncHTTPTab(copying: initial.tabs[0], title: "in flight"), initial.tabs[1]]
        )
        let latest = syncHTTPSnapshot(
            spaceID: spaceID, tabs: [
                initial.tabs[1],
                syncHTTPTab(copying: initial.tabs[0], title: "edited while ACK held"),
            ]
        )
        try await fixture.command("hold", deviceID: account.devices[0].deviceID)
        first.store.saveSnapshot(intermediate)
        first.service.schedulePush(snapshot: intermediate)
        do {
            try await fixture.waitForHeldAcknowledgement(account, deviceID: account.devices[0].deviceID)
            first.store.saveSnapshot(latest)
            first.service.schedulePush(snapshot: latest)
            #expect(first.store.loadSnapshot()?.tabs == latest.tabs)
            try await fixture.command("release", deviceID: account.devices[0].deviceID)
        } catch {
            try? await fixture.command("release", deviceID: account.devices[0].deviceID)
            throw error
        }
        await first.service.waitForPendingOperations()
        await second.pull()
        #expect(first.store.loadSnapshot()?.tabs == latest.tabs)
        #expect(second.store.loadSnapshot()?.tabs == latest.tabs)
        let state = try await fixture.inspect(account)
        #expect(state.tabs.filter { !$0.deleted }.map(\.id) == latest.tabs.compactMap(\.id))
        #expect(state.tabs.first { $0.id == initial.tabs[0].id }?.title == "edited while ACK held")
        #expect(Set(state.attempts.filter { $0.deviceID == account.devices[0].deviceID }.map(\.mutationID)).count == 3)
        await first.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }

    @Test func globalFavoriteSurvivesHistoricalSpaceDeletionUntilExplicitTabDeletion() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("global-favorite")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let historicalSpace = BrowserSpaceSessionSnapshot(
            id: UUID().uuidString,
            title: "Historical",
            systemImageName: "clock"
        )
        let remainingSpace = BrowserSpaceSessionSnapshot(
            id: UUID().uuidString,
            title: "Remaining",
            systemImageName: "globe"
        )
        let favorite = BrowserTabSessionSnapshotTab(
            id: UUID().uuidString, urlString: "https://favorite.example", userTitleOverride: "Favorite",
            placement: .app, spaceID: historicalSpace.id
        )
        let ordinaryChild = BrowserTabSessionSnapshotTab(
            id: UUID().uuidString, urlString: "https://ordinary.example", spaceID: historicalSpace.id
        )
        let survivor = BrowserTabSessionSnapshotTab(
            id: UUID().uuidString, urlString: "https://survivor.example", spaceID: remainingSpace.id
        )
        let initial = BrowserTabSessionSnapshot(
            spaces: [historicalSpace, remainingSpace], tabs: [favorite, ordinaryChild, survivor]
        )
        first.store.saveSnapshot(initial)
        await first.activate()
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        #expect(second.store.loadSnapshot()?.tabs == initial.tabs)

        let afterSpaceDeletion = BrowserTabSessionSnapshot(spaces: [remainingSpace], tabs: [favorite, survivor])
        await first.saveAndSend(afterSpaceDeletion)
        await second.pull()
        #expect(first.store.loadSnapshot()?.tabs == afterSpaceDeletion.tabs)
        #expect(second.store.loadSnapshot()?.tabs == afterSpaceDeletion.tabs)
        #expect(second.store.loadSnapshot()?.spaces?.map(\.id) == [remainingSpace.id])
        let stateAfterSpaceDeletion = try await fixture.inspect(account)
        let favoriteRow = try #require(stateAfterSpaceDeletion.tabs.first { $0.id == favorite.id })
        #expect(!favoriteRow.deleted && !favoriteRow.tombstoned)
        #expect(stateAfterSpaceDeletion.tabs.first { $0.id == ordinaryChild.id }?.tombstoned == true)

        let remoteFavorite = try #require(second.store.loadSnapshot()?.tabs.first { $0.id == favorite.id })
        try #require(remoteFavorite.spaceID == historicalSpace.id)
        let renamedFavorite = BrowserTabSessionSnapshotTab(
            id: remoteFavorite.id, urlString: remoteFavorite.urlString, userTitleOverride: "Renamed global Favorite",
            placement: .app, spaceID: remoteFavorite.spaceID
        )
        let renamed = BrowserTabSessionSnapshot(spaces: [remainingSpace], tabs: [renamedFavorite, survivor])
        await second.saveAndSend(renamed)
        await first.pull()
        #expect(first.store.loadSnapshot()?.tabs == renamed.tabs)
        #expect(second.store.loadSnapshot()?.tabs == renamed.tabs)
        let stateAfterRename = try await fixture.inspect(account)
        #expect(stateAfterRename.tabs.first { $0.id == favorite.id }?.title == "Renamed global Favorite")
        #expect(stateAfterRename.tabs.filter { !$0.deleted }.map(\.id) == renamed.tabs.compactMap(\.id))

        let afterExplicitDeletion = BrowserTabSessionSnapshot(spaces: [remainingSpace], tabs: [survivor])
        await first.saveAndSend(afterExplicitDeletion)
        await second.pull()
        #expect(first.store.loadSnapshot()?.tabs == [survivor])
        #expect(second.store.loadSnapshot()?.tabs == [survivor])
        let finalState = try await fixture.inspect(account)
        let deletedFavorite = try #require(finalState.tabs.first { $0.id == favorite.id })
        #expect(deletedFavorite.deleted && deletedFavorite.tombstoned)
        #expect(finalState.tabs.filter { !$0.deleted }.map(\.id) == [survivor.id].compactMap { $0 })
        await first.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }
}

// MARK: - SyncHTTPFixture

private struct SyncHTTPFixture: Decodable {
    // MARK: Internal

    struct Device: Decodable {
        let deviceID: String
        let userID: String
        let accessToken: String
    }

    struct Account: Decodable {
        let scenario: String
        let userID: String
        let devices: [Device]
    }

    struct Inspection: Decodable {
        struct Tab: Decodable {
            let id: String
            let rank: Double
            let spaceID: String
            let placement: String
            let title: String?
            let deleted: Bool
            let tombstoned: Bool
        }

        struct Attempt: Decodable {
            let deviceID: String
            let mutationID: String
            let protocolVersion: Int
            let digest: String
            let compressed: Bool
            let status: Int
        }

        let eventCount: Int
        let receiptCount: Int
        let tabs: [Tab]
        let attempts: [Attempt]
        let heldDeviceIDs: [String]
    }

    static var environmentPath: String? {
        ProcessInfo.processInfo.environment["THEBROWSER_SYNC_HTTP_FIXTURE"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_THEBROWSER_SYNC_HTTP_FIXTURE"]
    }

    let baseURL: URL
    let controlURL: URL
    let controlToken: String
    let accounts: [Account]

    static func load() throws -> Self {
        let path = try #require(environmentPath)
        let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require([fixture.baseURL, fixture.controlURL].allSatisfy { $0.scheme == "http" && $0.host == "127.0.0.1" })
        return fixture
    }

    func account(_ scenario: String) throws -> Account {
        let account = try #require(accounts.first { $0.scenario == scenario })
        try #require(account.devices.count == 2)
        return account
    }

    func inspect(_ account: Account) async throws -> Inspection {
        try await JSONDecoder().decode(Inspection.self, from: send(["action": "inspect", "userID": account.userID]))
    }

    func command(_ action: String, deviceID: String) async throws {
        _ = try await send(["action": action, "deviceID": deviceID])
    }

    func complete(_ account: Account) async throws {
        _ = try await send(["action": "complete", "scenario": account.scenario])
    }

    func waitForHeldAcknowledgement(_ account: Account, deviceID: String) async throws {
        for _ in 0..<100 {
            if try await inspect(account).heldDeviceIDs.contains(deviceID) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SyncHTTPError.acknowledgementWasNotHeld
    }

    // MARK: Private

    private func send(_ command: [String: String]) async throws -> Data {
        var request = URLRequest(url: controlURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(controlToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(command)
        let (data, response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        return data
    }
}

// MARK: - SyncHTTPProfile

@MainActor private final class SyncHTTPProfile {
    // MARK: Lifecycle

    init(fixture: SyncHTTPFixture, device: SyncHTTPFixture.Device, directory: URL) throws {
        let store = try BrowserSQLiteSessionStore(
            databaseURL: directory.appendingPathComponent("\(device.deviceID).sqlite")
        )
        let configuration = try #require(BrowserSyncConfiguration(baseURL: fixture.baseURL))
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.timeoutIntervalForRequest = 15
        urlConfiguration.timeoutIntervalForResource = 20
        let urlSession = URLSession(configuration: urlConfiguration)
        let auth = SyncHTTPAuth(session: BrowserAuthSession(
            accessToken: device.accessToken, userID: device.userID, userEmail: nil,
            deviceID: device.deviceID, serverURL: fixture.baseURL
        ))
        try store.bindSyncOwner(BrowserSyncOwner(baseURL: fixture.baseURL, userID: device.userID))
        self.store = store
        self.urlSession = urlSession
        self.auth = auth
        self.service = BrowserSyncService(
            localStore: store, remoteClient: BrowserRemoteSyncClient(configuration: configuration, session: urlSession),
            authSessionStore: auth, pushDebounce: .zero, pollInterval: nil, retryDelay: nil
        )
    }

    // MARK: Internal

    let store: BrowserSQLiteSessionStore
    let service: BrowserSyncService

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrowserSyncHTTPTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func activate() async {
        service.accountSessionDidChange(auth.session)
        await service.waitForPendingOperations()
    }

    func saveAndSend(_ snapshot: BrowserTabSessionSnapshot) async {
        store.saveSnapshot(snapshot)
        service.schedulePush(snapshot: snapshot)
        await service.waitForPendingOperations()
    }

    func pull() async {
        service.schedulePull()
        await service.waitForPendingOperations()
    }

    func disconnect() async {
        service.accountSessionDidChange(nil)
        await service.waitForPendingOperations()
        urlSession.invalidateAndCancel()
    }

    // MARK: Private

    private let auth: SyncHTTPAuth
    private let urlSession: URLSession
}

// MARK: - SyncHTTPAuth

@MainActor private final class SyncHTTPAuth: BrowserSyncAuthSessionReading {
    // MARK: Lifecycle

    init(session: BrowserAuthSession) { self.session = session }

    // MARK: Internal

    let session: BrowserAuthSession

    func loadSession() -> BrowserAuthSession? { session }
}

// MARK: - SyncHTTPError

private enum SyncHTTPError: Error {
    case acknowledgementWasNotHeld
}

private func syncHTTPSnapshot(
    spaceID: String = UUID().uuidString,
    tabs: [BrowserTabSessionSnapshotTab]? = nil
) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: spaceID, title: "HTTP integration", systemImageName: "globe")],
        tabs: tabs ?? [
            BrowserTabSessionSnapshotTab(
                id: UUID().uuidString,
                urlString: "https://example.test/first",
                spaceID: spaceID
            ),
            BrowserTabSessionSnapshotTab(
                id: UUID().uuidString,
                urlString: "https://example.test/second",
                spaceID: spaceID
            ),
        ]
    )
}

private func syncHTTPTab(copying tab: BrowserTabSessionSnapshotTab, title: String) -> BrowserTabSessionSnapshotTab {
    BrowserTabSessionSnapshotTab(id: tab.id, urlString: tab.urlString, userTitleOverride: title, spaceID: tab.spaceID)
}
