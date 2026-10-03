import Foundation
import GRDB
import Testing

extension BrowserSyncHTTPIntegrationTests {
    @Test func expiryRecoveryReplaysKnownTombstoneAndRetainsOfflineContentThroughLostACK() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("expiry-recovery")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let configuration = try #require(BrowserSyncConfiguration(baseURL: fixture.baseURL))
        let remote = BrowserRemoteSyncClient(configuration: configuration, session: session)
        let auth = account.devices.map { device in
            BrowserAuthSession(
                accessToken: device.accessToken, userID: device.userID, userEmail: nil,
                deviceID: device.deviceID, serverURL: fixture.baseURL
            )
        }
        let database = try DatabaseQueue(path: directory.appendingPathComponent(account.devices[0].deviceID + ".sqlite")
            .path)
        func frozenRows() throws -> [Data] {
            try database
                .read { try Data.fetchAll($0, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position") }
        }

        await first.activate()
        await first.saveAndSend(expiryHTTPSnapshot())
        await second.activate()
        #expect(try first.store.syncPullProtocolVersion(for: first.owner) == 4)
        #expect(try second.store.syncPullProtocolVersion(for: second.owner) == 4)
        await first.suspend()
        await second.suspend()
        let seeded = try await remote.pull(cursor: 0, protocolVersion: 4, authSession: auth[0])
        let legacySource = try #require(seeded.events.last { $0.entityID == "old-binary" && $0.op == "upsert" })
        let offlineSource = try #require(seeded.events.last { $0.entityID == "offline-edit" && $0.op == "upsert" })

        let oldExpiry = try await fixture.expire(account, device: account.devices[1], source: legacySource)
        try #require(oldExpiry.status == 201 && oldExpiry.response.outcomes.first?.status == .applied)
        let originalDelete = try #require(oldExpiry.response.events.first)
        let strippedDelete = BrowserSyncEvent(
            serverSeq: originalDelete.serverSeq, deviceID: originalDelete.deviceID,
            entityType: originalDelete.entityType, entityID: originalDelete.entityID,
            op: originalDelete.op, data: .deleted(id: originalDelete.entityID), createdAt: originalDelete.createdAt
        )
        // Simulate a prior v4 binary that advanced its cursor but discarded the
        // additive recovery field. No current HTTP decoder is deliberately weakened.
        _ = try first.store.applyRemoteSyncEvents([strippedDelete], cursor: oldExpiry.response.cursor, for: first.owner)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        #expect(first.store.loadSnapshot()?.tabs.contains { $0.id == "old-binary" } == false)
        try first.store.writeSessionBatch([.init(
            snapshot: expiryHTTPSnapshot(includeOldBinary: false, offlineEdit: true), origin: .local(syncMove: nil)
        )])
        let pending = try first.store.pendingSyncQueue(for: first.owner)
        try #require(pending.count == 1)
        guard case .folders(let pendingMutation) = pending[0] else {
            Issue.record("The immutable offline edit must retain its v4 codec")
            return
        }
        #expect(pendingMutation.operations == [.patchTab(
            id: "offline-edit", fields: .init(urlString: expiryHTTPOfflineURL, userTitleOverride: .set("Offline title"))
        )])
        let bytes = try frozenRows()
        let offlineExpiry = try await fixture.expire(account, device: account.devices[1], source: offlineSource)
        try #require(offlineExpiry.status == 201 && offlineExpiry.response.outcomes.first?.status == .applied)
        let offlineDelete = try #require(offlineExpiry.response.events.first)
        guard case .deleted(_, let recovery?) = offlineDelete.data else {
            Issue.record("The real expiry receipt must carry its canonical recovery payload")
            return
        }
        #expect(recovery.tab.urlString == expiryHTTPCanonicalURL)
        #expect(recovery.tab.userTitleOverride == "Canonical title")
        #expect(recovery.sourceServerSeq == offlineSource.serverSeq)

        try await fixture.setCapabilities([2, 3, 4, 5], account: account)
        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        let notification = ExpiryHTTPArchiveObserver()
        first.service.setSnapshotApplier(notification)
        await first.activate()
        await second.activate()
        for profile in [first, second] {
            #expect(try profile.store.syncPullProtocolVersion(for: profile.owner) == 5)
            #expect(profile.store.loadSnapshot()?.tabs.compactMap(\.id) == ["anchor"])
        }
        #expect(notification.archiveChanges > 0)
        let firstArchive = try first.store.loadArchivePage().entries
        let secondArchive = try second.store.loadArchivePage().entries
        #expect(firstArchive.count == 3 && secondArchive.count == 2)
        #expect(
            firstArchive.filter { $0.tab.id == "old-binary" }.count == 1,
            "Known tombstones still import previously discarded recovery"
        )
        let canonical = try #require(firstArchive
            .first { $0.tab.id == "offline-edit" && $0.tab.urlString == expiryHTTPCanonicalURL })
        let divergent = try #require(firstArchive
            .first { $0.tab.id == "offline-edit" && $0.tab.urlString == expiryHTTPOfflineURL })
        #expect(canonical.tab.userTitleOverride == "Canonical title")
        #expect(divergent.tab.userTitleOverride == "Offline title")
        #expect(Set(secondArchive.map(\.id)).isSubset(of: Set(firstArchive.map(\.id))))
        #expect(try first.store.pendingSyncQueue(for: first.owner) == pending)
        #expect(try frozenRows() == bytes)
        let lost = try await fixture.inspect(account)
        let lostAttempt = try #require(lost.attempts.last { $0.mutationID == pendingMutation.id })
        #expect(lostAttempt.status == 201 && lostAttempt.protocolVersion == 4)
        #expect(lost.tabs.filter { $0.id != "anchor" }.allSatisfy { $0.deleted && $0.tombstoned })
        let expiryReplay = try await fixture.expire(
            account, device: account.devices[1], source: offlineSource, mutationID: offlineExpiry.response.mutationID
        )
        #expect(expiryReplay == offlineExpiry)
        await first.disconnect()

        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        let reopened = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner) == pending)
        #expect(try frozenRows() == bytes)
        #expect(try reopened.store.loadArchivePage().entries == firstArchive)
        let beforeRetry = try await fixture.inspect(account)
        await reopened.activate()
        let afterRetry = try await fixture.inspect(account)
        let retries = afterRetry.attempts.filter { $0.mutationID == pendingMutation.id }
        #expect(retries.count >= 2 && Set(retries.map(\.digest)) == [lostAttempt.digest])
        #expect(retries.allSatisfy { $0.status == 201 && $0.protocolVersion == 4 })
        #expect(afterRetry.eventCount == beforeRetry.eventCount && afterRetry.receiptCount == beforeRetry.receiptCount)
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner).isEmpty)
        #expect(try reopened.store.loadArchivePage().entries == firstArchive)

        // Restore consumes one local recovery record and creates a fresh sync
        // identity; replaying the server deletion cannot remove that new tab.
        let restoredID = UUID().uuidString
        let current = try #require(reopened.store.loadSnapshot())
        let restored = BrowserTabSessionSnapshotTab(
            id: restoredID, urlString: divergent.tab.urlString, userTitleOverride: divergent.tab.userTitleOverride,
            spaceID: "source", lastActivityTimestamp: 1_900_000_000
        )
        let restore = BrowserSessionWrite(
            snapshot: BrowserTabSessionSnapshot(spaces: current.spaces, tabs: current.tabs + [restored]),
            origin: .local(syncMove: nil), archiveAction: .restore(archiveID: divergent.id, tabID: restoredID)
        )
        try reopened.store.writeSessionBatch([restore])
        try reopened.store.writeSessionBatch([restore]) // Same receipt cannot create a second tab or queue row.
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner).count == 1)
        try await reopened.sendSavedChanges()
        await second.pull()
        for profile in [reopened, second] {
            #expect(profile.store.loadSnapshot()?.tabs.first { $0.id == restoredID }?.urlString == expiryHTTPOfflineURL)
            #expect(profile.store
                .loadSnapshot()?
                .tabs
                .first { $0.id == restoredID }?
                .userTitleOverride == "Offline title")
            #expect(profile.store
                .loadSnapshot()?
                .tabs
                .contains { ["old-binary", "offline-edit"].contains($0.id ?? "") } == false)
        }
        let boundary = try await reopened.store.archiveClearBoundary()
        #expect(try await reopened.store.clearArchive(through: boundary) == 2)
        let beforeFullReplay = try await fixture.inspect(account)
        let fullReplay = try await remote.pull(cursor: 0, protocolVersion: 5, authSession: auth[0])
        _ = try reopened.store.completeExpirySyncBootstrap(
            events: fullReplay.events,
            cursor: fullReplay.cursor,
            for: reopened.owner
        )
        #expect(
            try reopened.store.loadArchivePage().entries.isEmpty,
            "Restored and explicitly cleared recovery records must not return on full bootstrap"
        )
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner).isEmpty)
        #expect(reopened.store.loadSnapshot()?.tabs.filter { $0.id == restoredID }.count == 1)
        let afterFullReplay = try await fixture.inspect(account)
        #expect(afterFullReplay.eventCount == beforeFullReplay.eventCount)
        #expect(afterFullReplay.receiptCount == beforeFullReplay.receiptCount)
        await reopened.disconnect()
        let finalStore = try BrowserSQLiteSessionStore(databaseURL: directory
            .appendingPathComponent(account.devices[0].deviceID + ".sqlite"))
        #expect(try finalStore.syncPullProtocolVersion(for: first.owner) == 5)
        #expect(try finalStore.loadArchivePage().entries.isEmpty)
        #expect(finalStore.loadSnapshot()?.tabs.filter { $0.id == restoredID }.count == 1)
        await second.disconnect()
        try await fixture.complete(account)
    }
}

private let expiryHTTPCanonicalURL = "https://canonical.example/expired"
private let expiryHTTPOfflineURL = "https://offline.example/unsent"

private func expiryHTTPSnapshot(includeOldBinary: Bool = true, offlineEdit: Bool = false) -> BrowserTabSessionSnapshot {
    let old = BrowserTabSessionSnapshotTab(
        id: "old-binary", urlString: "https://canonical.example/old-binary", spaceID: "source",
        lastActivityTimestamp: 946_684_800
    )
    return BrowserTabSessionSnapshot(
        spaces: [.init(id: "source", title: "Expiry recovery", systemImageName: "globe")],
        tabs: (includeOldBinary ? [old] : []) + [
            .init(
                id: "offline-edit",
                urlString: offlineEdit ? expiryHTTPOfflineURL : expiryHTTPCanonicalURL,
                userTitleOverride: offlineEdit ? "Offline title" : "Canonical title",
                spaceID: "source",
                lastActivityTimestamp: 946_684_800
            ),
            .init(
                id: "anchor",
                urlString: "https://canonical.example/anchor",
                spaceID: "source",
                lastActivityTimestamp: 1_900_000_000
            ),
        ]
    )
}

// MARK: - ExpiryHTTPResult

private struct ExpiryHTTPResult: Decodable, Equatable {
    struct Receipt: Decodable, Equatable {
        let protocolVersion: Int
        let mutationID: String
        let cursor: Int
        let events: [BrowserSyncEvent]
        let outcomes: [BrowserSyncSemanticOutcome]
    }

    let status: Int
    let response: Receipt
}

private extension SyncHTTPFixture {
    func expire(
        _ account: Account,
        device: Device,
        source: BrowserSyncEvent,
        mutationID: String = UUID().uuidString
    ) async throws -> ExpiryHTTPResult {
        struct Command: Encodable {
            let action = "expire"
            let userID: String
            let deviceID: String
            let mutationID: String
            let tabID: String
            let expectedServerSeq: Int
            let inactiveForSeconds = 43200
        }
        let data = try await send(Command(
            userID: account.userID, deviceID: device.deviceID, mutationID: mutationID,
            tabID: source.entityID, expectedServerSeq: source.serverSeq
        ))
        let result = try JSONDecoder().decode(ExpiryHTTPResult.self, from: data)
        #expect(result.response.protocolVersion == 5)
        return result
    }
}

// MARK: - ExpiryHTTPArchiveObserver

@MainActor private final class ExpiryHTTPArchiveObserver: BrowserSyncSnapshotApplying {
    private(set) var archiveChanges = 0

    func applyRemoteSyncSnapshot(_: BrowserTabSessionSnapshot) {}
    func syncArchiveDidChange() { archiveChanges += 1 }
}
