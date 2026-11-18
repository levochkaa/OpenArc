// BrowserSyncExpiryQueueHTTPIntegrationTests.swift

import Foundation
import GRDB
import Testing

extension BrowserSyncHTTPIntegrationTests {
    @Test func queuedExpiryResponseLimitPreservesLargeCanonicalTabAndArchivesSmallPeer() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("expiry-response-limit")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let configuration = try #require(BrowserSyncConfiguration(baseURL: fixture.baseURL))
        let remote = BrowserRemoteSyncClient(configuration: configuration, session: session)
        let auth = account.devices.map { device in
            BrowserAuthSession(
                accessToken: device.accessToken, userID: device.userID, userEmail: nil,
                deviceID: device.deviceID, serverURL: fixture.baseURL,
            )
        }
        // Larger than the bounded recovery response, but smaller than the
        // production request limit even after gzip inflation. This is real
        // canonical metadata, not a manufactured database row or response.
        let largeTitle = String(repeating: "L", count: 4 * 1024 * 1024 + 65536)
        let seed = BrowserSyncFolderMutation(id: UUID().uuidString, operations: [
            .createSpace(id: "source", data: .init(title: "Response budget", systemImageName: "globe")),
            .createTab(id: "large", data: .init(
                spaceID: "source", placement: .temporary, urlString: "https://expiry-limit.example/large",
                title: largeTitle, lastActivityAt: "2000-01-01T00:00:00.000000Z",
            )),
            .createTab(id: "small", data: .init(
                spaceID: "source", placement: .temporary, urlString: "https://expiry-limit.example/small",
                title: "Small page", lastActivityAt: "2000-01-01T00:00:00.000000Z",
            )),
        ])
        let seeded = try await remote.push(mutation: seed, authSession: auth[0])
        let largeSource = try #require(seeded.events.last { $0.entityID == "large" && $0.op == "upsert" })
        let smallSource = try #require(seeded.events.last { $0.entityID == "small" && $0.op == "upsert" })
        await first.activate()
        #expect(try first.store.syncPullProtocolVersion(for: first.owner) == 6)
        #expect(first.store.loadSnapshot()?.tabs.compactMap(\.id) == ["large", "small"])
        let before = try await fixture.inspect(account)
        let mutationID = try #require(try first.service.enqueueExpiry(operations: [
            .init(id: "large", expectedServerSeq: largeSource.serverSeq, inactiveForSeconds: 43200),
            .init(id: "small", expectedServerSeq: smallSource.serverSeq, inactiveForSeconds: 43200),
        ]))
        let queue = try first.store.pendingSyncQueue(for: first.owner)
        try #require(queue.count == 1)
        guard case .expiry(let mutation) = queue[0] else {
            Issue.record("The bounded response test must upload a production queued v5 batch")
            return
        }
        #expect(mutation.id == mutationID)
        #expect(first.store.loadSnapshot()?.tabs.compactMap(\.id) == ["large", "small"])
        await first.service.waitForPendingOperations()
        #expect(
            try first.store.pendingSyncQueue(for: first.owner).isEmpty,
            "A terminal response_limit outcome must not trap the immutable queue head",
        )
        #expect(first.store.loadSnapshot()?.tabs.compactMap(\.id) == ["large"])
        let archive = try first.store.loadArchivePage().entries
        try #require(archive.count == 1)
        #expect(archive[0].tab.id == "small" && archive[0].title == "Small page")
        let committed = try await fixture.inspect(account)
        #expect(committed.eventCount == before.eventCount + 1 && committed.receiptCount == before.receiptCount + 1)
        #expect(committed.tabs.first { $0.id == "large" }?.deleted == false)
        #expect(committed.tabs.first { $0.id == "large" }?.tombstoned == false)
        #expect(committed.tabs.first { $0.id == "small" }?.tombstoned == true)

        let receipt = try await remote.push(mutation: mutation, authSession: auth[0])
        #expect(receipt.outcomes == [
            .init(operationIndex: 0, status: .rejected, reason: .responseLimit),
            .init(operationIndex: 1, status: .applied, reason: nil),
        ])
        #expect(receipt.events.map(\.entityID) == ["small"], "Oversized recovery is omitted whole, never truncated")
        let replay = try await remote.push(mutation: mutation, authSession: auth[1])
        #expect(replay == receipt)
        let secondPull = try await remote.pull(cursor: 0, protocolVersion: 5, authSession: auth[1])
        let largeEvent = try #require(secondPull.events.last { $0.entityID == "large" })
        guard case .tab(let largeData) = largeEvent.data else {
            Issue.record("Rejected expiry must retain the full canonical live tab")
            return
        }
        let titlePreserved = largeData.title == largeTitle
        #expect(titlePreserved)
        #expect(largeEvent.serverSeq == largeSource.serverSeq && largeEvent.op == "upsert")
        let smallEvent = try #require(secondPull.events.last { $0.entityID == "small" })
        #expect(smallEvent == receipt.events.first)
        let afterReplay = try await fixture.inspect(account)
        #expect(afterReplay.eventCount == committed.eventCount && afterReplay.receiptCount == committed.receiptCount)
        #expect(try first.store.loadArchivePage().entries == archive)
        await first.disconnect()
        let reopened = try BrowserSQLiteSessionStore(databaseURL: directory
            .appendingPathComponent(account.devices[0].deviceID + ".sqlite"))
        #expect(try reopened.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(reopened.loadSnapshot()?.tabs.compactMap(\.id) == ["large"])
        #expect(try reopened.loadArchivePage().entries == archive)
        try await fixture.complete(account)
    }

    @Test func conditionalExpiryQueueKeepsIntentThroughRejectionLostACKDowngradeAndDeviceRotation() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("expiry-queue")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let configuration = try #require(BrowserSyncConfiguration(baseURL: fixture.baseURL))
        let remote = BrowserRemoteSyncClient(configuration: configuration, session: session)
        func auth(_ device: SyncHTTPFixture.Device) -> BrowserAuthSession {
            BrowserAuthSession(
                accessToken: device.accessToken, userID: device.userID, userEmail: nil,
                deviceID: device.deviceID, serverURL: fixture.baseURL,
            )
        }
        let databaseURL = directory.appendingPathComponent(account.devices[0].deviceID + ".sqlite")
        let database = try DatabaseQueue(path: databaseURL.path)
        func queueBytes() throws -> [Data] {
            try database
                .read { try Data.fetchAll($0, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position") }
        }

        await first.activate()
        await first.saveAndSend(expiryQueueHTTPSnapshot())
        await second.activate()
        for profile in [first, second] {
            #expect(try profile.store.syncPullProtocolVersion(for: profile.owner) == 6)
            #expect(try profile.store.pendingSyncQueue(for: profile.owner).isEmpty)
        }
        let initial = try await remote.pull(cursor: 0, protocolVersion: 5, authSession: auth(account.devices[0]))
        let staleSource = try #require(initial.events.last { $0.entityID == "stale" && $0.op == "upsert" })
        let acceptedSource = try #require(initial.events.last { $0.entityID == "accepted" && $0.op == "upsert" })

        // Another device changes canonical content after A observed the old
        // version. An expiry decision must not turn that stale observation into a delete.
        await second.saveAndSend(expiryQueueHTTPSnapshot(remoteEdit: true))
        let beforeRejection = try await fixture.inspect(account)
        let beforeEnqueue = try #require(first.store.loadSnapshot())
        let rejectedID = try #require(try first.service.enqueueExpiry(operations: [.init(
            id: "stale", expectedServerSeq: staleSource.serverSeq, inactiveForSeconds: 43200,
        )]))
        let rejectedQueue = try first.store.pendingSyncQueue(for: first.owner)
        try #require(rejectedQueue.count == 1)
        guard case .expiry(let rejectedMutation) = rejectedQueue[0] else {
            Issue.record("Conditional expiry must have its own immutable v5 queue row")
            return
        }
        #expect(rejectedMutation.id == rejectedID)
        #expect(first.store.loadSnapshot() == beforeEnqueue, "Enqueue cannot optimistically hide the candidate")
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        await first.service.waitForPendingOperations()
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(first.store.loadSnapshot()?.tabs.first { $0.id == "stale" }?.urlString == expiryQueueHTTPRemoteURL)
        #expect(first.store.loadSnapshot()?.tabs.first { $0.id == "stale" }?.userTitleOverride == "Remote title")
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        let rejectedReceipt = try await remote.push(mutation: rejectedMutation, authSession: auth(account.devices[0]))
        #expect(rejectedReceipt.protocolVersion == 5 && rejectedReceipt.mutationID == rejectedID)
        #expect(rejectedReceipt.outcomes == [.init(operationIndex: 0, status: .rejected, reason: .stateChanged)])
        let authoritative = try #require(rejectedReceipt.events.first)
        guard case .tab(let authoritativeTab) = authoritative.data else {
            Issue.record("A stale expiry must echo the authoritative live row")
            return
        }
        #expect(authoritative.entityID == "stale" && authoritative.serverSeq > staleSource.serverSeq)
        #expect(authoritativeTab.urlString == expiryQueueHTTPRemoteURL && authoritativeTab
            .userTitleOverride == "Remote title")
        let afterRejection = try await fixture.inspect(account)
        #expect(afterRejection.eventCount == beforeRejection.eventCount)
        #expect(afterRejection.receiptCount == beforeRejection.receiptCount + 1)
        #expect(afterRejection.tabs.first { $0.id == "stale" }?.deleted == false)

        // Write a local content edit behind the conditional intent before the
        // worker can run. Acceptance archives server content and preserves this
        // unsent content separately when its immutable queue is replayed.
        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        let acceptedID = try #require(try first.service.enqueueExpiry(operations: [.init(
            id: "accepted", expectedServerSeq: acceptedSource.serverSeq, inactiveForSeconds: 43200,
        )]))
        #expect(first.store.loadSnapshot()?.tabs.contains { $0.id == "accepted" } == true)
        try first.store.writeSessionBatch([.init(
            snapshot: expiryQueueHTTPSnapshot(remoteEdit: true, localEdit: true), origin: .local(syncMove: nil),
        )])
        let frozen = try first.store.pendingSyncQueue(for: first.owner)
        try #require(frozen.count == 2)
        guard case .expiry(let acceptedMutation) = frozen[0], case .folders(let laterEdit) = frozen[1] else {
            Issue.record("Expiry and the later edit must retain the exact v5/v4 FIFO order")
            return
        }
        #expect(acceptedMutation.id == acceptedID)
        #expect(laterEdit.operations == [.patchTab(
            id: "accepted", fields: .init(urlString: expiryQueueHTTPLocalURL, userTitleOverride: .set("Offline title")),
        )])
        let frozenBytes = try queueBytes()
        #expect(first.store.loadSnapshot()?.tabs.first { $0.id == "accepted" }?.urlString == expiryQueueHTTPLocalURL)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        await first.service.waitForPendingOperations()
        let lost = try await fixture.inspect(account)
        let originalAttempt = try #require(lost.attempts.last { $0.mutationID == acceptedID })
        #expect(originalAttempt.protocolVersion == 5 && originalAttempt.status == 201)
        #expect(lost.eventCount == afterRejection.eventCount + 1)
        #expect(lost.tabs.first { $0.id == "accepted" }?.deleted == true)
        #expect(lost.tabs.first { $0.id == "accepted" }?.tombstoned == true)
        #expect(!lost.attempts.contains { $0.mutationID == laterEdit.id }, "The lost head ACK must block the later row")
        #expect(try first.store.pendingSyncQueue(for: first.owner) == frozen)
        #expect(try queueBytes() == frozenBytes)
        #expect(first.store.loadSnapshot()?.tabs.first { $0.id == "accepted" }?.urlString == expiryQueueHTTPLocalURL)
        #expect(
            try first.store.loadArchivePage().entries.isEmpty,
            "A lost response cannot create an unconfirmed local archive",
        )
        await second.pull()
        let remoteArchive = try second.store.loadArchivePage().entries
        try #require(remoteArchive.count == 1)
        #expect(remoteArchive[0].tab.urlString == expiryQueueHTTPCanonicalURL)
        #expect(remoteArchive[0].tab.userTitleOverride == "Canonical title")
        await first.disconnect()
        try await fixture.command("release", deviceID: account.devices[0].deviceID)

        // A capability downgrade must not reinterpret or skip the frozen v5
        // head. This is a response shim over the same production server.
        try await fixture.setCapabilities([2, 3, 4], account: account)
        let downgraded = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let beforeDowngrade = try await fixture.inspect(account)
        await downgraded.activate()
        let afterDowngrade = try await fixture.inspect(account)
        #expect(afterDowngrade.attempts.count == beforeDowngrade.attempts.count)
        #expect(try downgraded.store.pendingSyncQueue(for: downgraded.owner) == frozen)
        #expect(try queueBytes() == frozenBytes)
        #expect(downgraded.store
            .loadSnapshot()?
            .tabs
            .first { $0.id == "accepted" }?
            .urlString == expiryQueueHTTPLocalURL)
        #expect(throws: (any Error).self) {
            try downgraded.service.enqueueExpiry(operations: [.init(
                id: "stale", expectedServerSeq: authoritative.serverSeq, inactiveForSeconds: 43200,
            )])
        }
        #expect(try downgraded.store.pendingSyncQueue(for: downgraded.owner) == frozen)
        await downgraded.disconnect()

        try await fixture.setCapabilities([2, 3, 4, 5], account: account)
        let rotatedDevice = try await fixture.rotateDevice(account)
        let rotated = try SyncHTTPProfile(
            fixture: fixture, device: rotatedDevice, directory: directory, databaseID: account.devices[0].deviceID,
        )
        #expect(try rotated.store.pendingSyncQueue(for: rotated.owner) == frozen)
        #expect(try queueBytes() == frozenBytes)
        let beforeRotation = try await fixture.inspect(account)
        await rotated.activate()
        await second.pull()
        let afterRotation = try await fixture.inspect(account)
        #expect(afterRotation.observedPulls.contains {
            $0.deviceID == rotatedDevice.deviceID && (5...6).contains($0.protocolVersion) && $0.cursor > 0 && $0
                .status == 409
        })
        #expect(afterRotation.observedPulls.contains {
            $0.deviceID == rotatedDevice.deviceID && (5...6).contains($0.protocolVersion) && $0.cursor == 0 && $0
                .status == 201
        })
        let attempts = afterRotation.attempts.filter { $0.mutationID == acceptedID }
        #expect(attempts.count >= 2 && Set(attempts.map(\.digest)) == [originalAttempt.digest])
        #expect(attempts
            .contains { $0.deviceID == rotatedDevice.deviceID && $0.protocolVersion == 5 && $0.status == 201 })
        #expect(afterRotation.attempts
            .contains { $0.mutationID == laterEdit.id && $0.protocolVersion == 4 && $0.status == 201 })
        #expect(afterRotation.eventCount == beforeRotation.eventCount)
        #expect(
            afterRotation.receiptCount == beforeRotation.receiptCount + 1,
            "Only the later v4 edit needs a new receipt",
        )
        for profile in [rotated, second] {
            #expect(try profile.store.pendingSyncQueue(for: profile.owner).isEmpty)
            #expect(profile.store.loadSnapshot()?.tabs.compactMap(\.id) == ["stale", "anchor"])
            #expect(profile.store
                .loadSnapshot()?
                .tabs
                .first { $0.id == "stale" }?
                .urlString == expiryQueueHTTPRemoteURL)
        }
        let archive = try rotated.store.loadArchivePage().entries
        #expect(archive.count == 2)
        #expect(archive.contains { $0.id == remoteArchive[0].id && $0.tab.urlString == expiryQueueHTTPCanonicalURL })
        #expect(archive
            .contains { $0.tab.urlString == expiryQueueHTTPLocalURL && $0.tab.userTitleOverride == "Offline title" })

        // Typed transport validates the accepted receipt independently of the
        // coordinator; rotation never changes its immutable event or outcome.
        let acceptedReceipt = try await remote.push(mutation: acceptedMutation, authSession: auth(rotatedDevice))
        let replay = try await remote.push(mutation: acceptedMutation, authSession: auth(account.devices[0]))
        #expect(replay == acceptedReceipt)
        #expect(acceptedReceipt.outcomes == [.init(operationIndex: 0, status: .applied, reason: nil)])
        let acceptedEvent = try #require(acceptedReceipt.events.first)
        guard case .deleted(let deletedID, let recovery?) = acceptedEvent.data else {
            Issue.record("Accepted expiry requires canonical recovery on the typed receipt")
            return
        }
        #expect(deletedID == "accepted" && recovery.sourceServerSeq == acceptedSource.serverSeq)
        #expect(recovery.tab.urlString == expiryQueueHTTPCanonicalURL && recovery.tab
            .userTitleOverride == "Canonical title")
        let afterReplay = try await fixture.inspect(account)
        #expect(afterReplay.eventCount == afterRotation.eventCount && afterReplay.receiptCount == afterRotation
            .receiptCount)
        #expect(try rotated.store.loadArchivePage().entries == archive)
        await rotated.disconnect()
        await second.disconnect()
        let reopenedStore = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(try reopenedStore.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(try reopenedStore.loadArchivePage().entries == archive)
        #expect(reopenedStore.loadSnapshot()?.tabs.compactMap(\.id) == ["stale", "anchor"])
        try await fixture.complete(account)
    }
}

private let expiryQueueHTTPCanonicalURL = "https://expiry-queue.example/canonical"
private let expiryQueueHTTPLocalURL = "https://expiry-queue.example/offline"
private let expiryQueueHTTPRemoteURL = "https://expiry-queue.example/newer-remote"

private func expiryQueueHTTPSnapshot(remoteEdit: Bool = false, localEdit: Bool = false) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [.init(id: "source", title: "Conditional expiry", systemImageName: "globe")],
        tabs: [
            .init(
                id: "stale",
                urlString: remoteEdit ? expiryQueueHTTPRemoteURL : "https://expiry-queue.example/stale",
                userTitleOverride: remoteEdit ? "Remote title" : nil,
                spaceID: "source",
                lastActivityTimestamp: 946_684_800,
            ),
            .init(
                id: "accepted",
                urlString: localEdit ? expiryQueueHTTPLocalURL : expiryQueueHTTPCanonicalURL,
                userTitleOverride: localEdit ? "Offline title" : "Canonical title",
                spaceID: "source",
                lastActivityTimestamp: 946_684_800,
            ),
            .init(
                id: "anchor",
                urlString: "https://expiry-queue.example/anchor",
                spaceID: "source",
                lastActivityTimestamp: 1_900_000_000,
            ),
        ],
    )
}
