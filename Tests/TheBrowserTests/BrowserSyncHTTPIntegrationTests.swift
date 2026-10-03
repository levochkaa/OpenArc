import Foundation
import GRDB
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

    @Test(arguments: [false, true])
    func coordinatorsMergeIndependentSemanticRenameAndCrossSpaceMove(patchFirst: Bool) async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account(patchFirst ? "coordinator-patch-first" : "coordinator-move-first")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        // Discover v3 before local capture; both profiles then prepare intent from
        // the same committed baseline without seeing the other profile's edits.
        await first.activate()
        let initial = syncHTTPSemanticSnapshot()
        await first.saveAndSend(initial)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        #expect(second.store.loadSnapshot()?.tabs == initial.tabs)
        let title = "independently renamed"
        first.store.saveSnapshot(syncHTTPSemanticSnapshot(title: title))
        second.store.saveSnapshot(syncHTTPSemanticSnapshot(moved: true))
        let firstQueue = try first.store.pendingSyncQueue(for: first.owner)
        let secondQueue = try second.store.pendingSyncQueue(for: second.owner)
        try #require(firstQueue.count == 1 && secondQueue.count == 1)
        let patch = try #require(firstQueue.first)
        let move = try #require(secondQueue.first)
        #expect(patch.protocolVersion == 3 && move.protocolVersion == 3)
        if case .semantic(let mutation) = patch {
            #expect(mutation.operations == [.patchTab(id: "moving", fields: .init(userTitleOverride: .set(title)))])
        } else {
            Issue.record("A negotiated profile must capture a semantic patch")
        }
        if case .semantic(let mutation) = move {
            #expect(mutation.operations.contains { operation in
                if case .moveTabs(let ids, let destination, _, _) = operation {
                    return ids == ["moving"] && destination.spaceID == "target" && destination.placement == .temporary
                }
                return false
            })
            #expect(!mutation.operations.contains { operation in
                if case .patchTab = operation {
                    return true
                }
                return false
            })
        } else {
            Issue.record("A negotiated profile must capture a semantic move")
        }

        if patchFirst {
            try await first.sendSavedChanges()
            try await second.sendSavedChanges()
        } else {
            try await second.sendSavedChanges()
            try await first.sendSavedChanges()
        }
        await first.pull()
        await second.pull()
        let expected = syncHTTPSemanticSnapshot(title: title, moved: true)
        #expect(first.store.loadSnapshot()?.tabs == expected.tabs)
        #expect(second.store.loadSnapshot()?.tabs == expected.tabs)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(try second.store.pendingSyncQueue(for: second.owner).isEmpty)
        let state = try await fixture.inspect(account)
        #expect(state.tabs.first { $0.id == "moving" }?.title == title)
        #expect(state.tabs.filter { !$0.deleted && $0.spaceID == "target" }.map(\.id) == ["moving", "anchor"])
        #expect(state.tabs.filter { !$0.deleted && $0.spaceID == "source" }.map(\.id) == ["source-sentinel"])
        let delivered = state.attempts.filter { $0.mutationID == patch.id || $0.mutationID == move.id }
        #expect(delivered.map(\.mutationID) == (patchFirst ? [patch.id, move.id] : [move.id, patch.id]))
        #expect(delivered.allSatisfy { $0.protocolVersion == 3 && $0.status == 201 })
        await first.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }

    @Test func semanticCoordinatorReopensLostAcknowledgementWithoutRollingBackLaterRemoteState() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("coordinator-lost-ack")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: SyncHTTPProfile? = try SyncHTTPProfile(
            fixture: fixture, device: account.devices[0], directory: directory
        )
        let owner = try #require(first?.owner)
        await first?.activate()
        await first?.saveAndSend(syncHTTPSemanticSnapshot())
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        let oldEdit = syncHTTPSemanticSnapshot(title: String(repeating: "semantic-lost-ack-", count: 160))
        first?.store.saveSnapshot(oldEdit)
        let pending = try #require(try first?.store.pendingSyncQueue(for: owner))
        try #require(pending.count == 1 && pending[0].protocolVersion == 3)
        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        try await first?.sendSavedChanges()
        let afterDrop = try await fixture.inspect(account)
        let committed = try #require(afterDrop.attempts.last { $0.mutationID == pending[0].id })
        #expect(committed.protocolVersion == 3 && committed.status == 201 && committed.compressed)
        #expect(try first?.store.pendingSyncQueue(for: owner) == pending)
        await first?.disconnect()
        first = nil

        await second.pull()
        let newer = syncHTTPSemanticSnapshot(title: "newer title after lost semantic ACK", moved: true)
        await second.saveAndSend(newer)
        let beforeRetry = try await fixture.inspect(account)
        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        #expect(try first?.store.pendingSyncQueue(for: owner) == pending, "Reopen must retain the exact v3 row")
        #expect(first?.store.loadSnapshot()?.tabs == oldEdit.tabs)
        await first?.activate()
        await first?.pull()
        await second.pull()
        let afterRetry = try await fixture.inspect(account)
        let retries = afterRetry.attempts.filter { $0.mutationID == committed.mutationID }
        let earlierAttempts = beforeRetry.attempts.filter { $0.mutationID == committed.mutationID }.count
        #expect(retries.count > earlierAttempts, "Reopened coordinator must send the persisted mutation again")
        #expect(Set(retries.map(\.digest)) == [committed.digest])
        #expect(retries.allSatisfy { $0.protocolVersion == 3 && $0.status == 201 })
        #expect(afterRetry.eventCount == beforeRetry.eventCount)
        #expect(afterRetry.receiptCount == beforeRetry.receiptCount)
        #expect(first?.store.loadSnapshot()?.tabs == newer.tabs)
        #expect(second.store.loadSnapshot()?.tabs == newer.tabs)
        #expect(try first?.store.pendingSyncQueue(for: owner).isEmpty == true)
        #expect(try second.store.pendingSyncQueue(for: second.owner).isEmpty)
        #expect(afterRetry.tabs.first { $0.id == "moving" }?.title == "newer title after lost semantic ACK")
        #expect(afterRetry.tabs.filter { !$0.deleted && $0.spaceID == "target" }.map(\.id) == ["moving", "anchor"])
        await first?.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }

    @Test func semanticCoordinatorDrainsOfflinePatchAndMoveAfterRemoteDeletion() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("coordinator-delete-pending")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        await first.activate()
        await first.saveAndSend(syncHTTPSemanticSnapshot())
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        await second.suspend()
        second.store.saveSnapshot(syncHTTPSemanticSnapshot(title: "offline patch"))
        let optimistic = syncHTTPSemanticSnapshot(title: "offline patch", moved: true)
        second.store.saveSnapshot(optimistic)
        let pending = try second.store.pendingSyncQueue(for: second.owner)
        try #require(pending.count == 2 && pending.allSatisfy { $0.protocolVersion == 3 })
        #expect(second.store.loadSnapshot()?.tabs == optimistic.tabs)
        let expected = syncHTTPSemanticSnapshot(deleted: true)
        await first.saveAndSend(expected)
        let beforeReconnect = try await fixture.inspect(account)
        #expect(beforeReconnect.tabs.first { $0.id == "moving" }?.tombstoned == true)

        await second.activate()
        await first.pull()
        #expect(first.store.loadSnapshot()?.tabs == expected.tabs)
        #expect(second.store.loadSnapshot()?.tabs == expected.tabs)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(try second.store.pendingSyncQueue(for: second.owner).isEmpty)
        let finalState = try await fixture.inspect(account)
        let deleted = try #require(finalState.tabs.first { $0.id == "moving" })
        #expect(deleted.deleted && deleted.tombstoned)
        #expect(
            finalState.eventCount == beforeReconnect.eventCount,
            "Stale patch and move must only echo the tombstone"
        )
        for mutation in pending {
            #expect(finalState.attempts.contains {
                $0.mutationID == mutation.id && $0.protocolVersion == 3 && $0.status == 201
            })
        }
        #expect(finalState.tabs.filter { !$0.deleted && $0.spaceID == "source" }.map(\.id) == ["source-sentinel"])
        #expect(finalState.tabs.filter { !$0.deleted && $0.spaceID == "target" }.map(\.id) == ["anchor"])
        await first.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }

    @Test func semanticSpaceDeletionPreservesTabMovedAwayBeforeDeleteCommits() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("coordinator-space-delete-move")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        await first.activate()
        let initial = syncHTTPSemanticSnapshot()
        await first.saveAndSend(initial)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        await first.suspend()
        // The offline UI removes the Space and both children. Only the Space
        // deletion is user intent; its cascade must inspect canonical membership.
        let locallyDeleted = BrowserTabSessionSnapshot(
            spaces: initial.spaces?.filter { $0.id != "source" },
            tabs: initial.tabs.filter { $0.spaceID != "source" }
        )
        first.store.saveSnapshot(locallyDeleted)
        let pending = try first.store.pendingSyncQueue(for: first.owner)
        try #require(pending.count == 1 && pending[0].protocolVersion == 3)
        if case .semantic(let mutation) = pending[0] {
            #expect(mutation.operations == [.deleteSpace(id: "source")])
        } else {
            Issue.record("Space deletion must be captured as semantic intent")
        }
        await second.saveAndSend(syncHTTPSemanticSnapshot(moved: true))
        let beforeReconnect = try await fixture.inspect(account)
        let moved = try #require(beforeReconnect.tabs.first { $0.id == "moving" })
        #expect(moved.spaceID == "target" && !moved.deleted && !moved.tombstoned)
        #expect(!beforeReconnect.attempts.contains { $0.mutationID == pending[0].id })

        await first.activate()
        await second.pull()
        let expected = syncHTTPSemanticSnapshot(moved: true).tabs.filter { $0.spaceID == "target" }
        #expect(first.store.loadSnapshot()?.tabs == expected)
        #expect(second.store.loadSnapshot()?.tabs == expected)
        #expect(first.store.loadSnapshot()?.spaces?.map(\.id) == ["target"])
        #expect(second.store.loadSnapshot()?.spaces?.map(\.id) == ["target"])
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(try second.store.pendingSyncQueue(for: second.owner).isEmpty)
        let finalState = try await fixture.inspect(account)
        let survivor = try #require(finalState.tabs.first { $0.id == "moving" })
        let deletedChild = try #require(finalState.tabs.first { $0.id == "source-sentinel" })
        #expect(survivor.spaceID == "target" && !survivor.deleted && !survivor.tombstoned)
        #expect(deletedChild.deleted && deletedChild.tombstoned)
        #expect(finalState.tabs.filter { !$0.deleted }.map(\.id) == ["moving", "anchor"])
        #expect(finalState.attempts.contains {
            $0.mutationID == pending[0].id && $0.protocolVersion == 3 && $0.status == 201
        })
        await first.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }

    @Test func deletingSpaceBeforeRemoteCreateCallbacksKeepsOnlyGlobalFavoriteOnBothClients() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("pending-parent-delete")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        await first.activate()
        let initial = syncHTTPExplicitSnapshot(source: [], target: ["anchor"])
        await first.saveAndSend(initial)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()

        let suite = "BrowserSyncHTTPPendingParent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let driver = FakeBrowserTabDriver()
        let model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: first.store, sessionPreferencesStore: first.store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: first.service,
            dateProvider: { syncHTTPModelDate }, windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
        defer {
            first.service.setSnapshotApplier(nil)
            model.discardUnsavedSessionForClosure()
            model.prepareForTermination()
        }
        model.handleContextReady()
        // Restored identities exist before the fake engine delivers callbacks.
        let restoredAnchor = try #require(model.tabs.first { $0.syncID == "anchor" })
        driver.flushPendingCreateEvents()
        #expect(model.tabs.map(\.syncID) == ["anchor"])
        #expect(model.tabs.first?.id == restoredAnchor.id)
        first.service.setSnapshotApplier(model)
        await first.service.waitForPendingOperations()

        let ordinary = syncHTTPExplicitSnapshot(
            source: ["child"], target: ["anchor"], titles: ["child": "Remote child"]
        )
        let favorite = BrowserTabSessionSnapshotTab(
            id: "favorite", urlString: "https://favorite.example", userTitleOverride: "Global Favorite",
            placement: .app, spaceID: "source", lastActivityTimestamp: syncHTTPModelDate.timeIntervalSince1970
        )
        await second.saveAndSend(BrowserTabSessionSnapshot(
            spaces: ordinary.spaces, tabs: [favorite] + ordinary.tabs
        ))
        await first.pull()
        let childRequest = try #require(driver.createdTabRequests.last { $0.urlString == "https://child.example" })
        let favoriteRequest = try #require(driver.createdTabRequests.last {
            $0.urlString == "https://favorite.example"
        })
        #expect(model.tabs.map(\.syncID) == ["anchor"], "Keep the new engine callbacks pending")
        let beforeDeletion = try await fixture.inspect(account)
        try #require(first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(model.deleteSpace(id: "source"))
        #expect(driver.closedTabRequests.contains { $0.id == childRequest.id && $0.forceClose })
        #expect(!driver.closedTabRequests.contains { $0.id == favoriteRequest.id })
        let queue = try first.store.pendingSyncQueue(for: first.owner)
        try #require(queue.count == 1)
        let deletion = try syncHTTPSemanticMutation(queue[0])
        #expect(deletion.operations == [.deleteSpace(id: "source")])
        #expect(Set(first.store.loadSnapshot()?.tabs.compactMap(\.id) ?? []) == ["favorite", "anchor"])

        driver.flushPendingCreateEvents()
        #expect(model.tabs.map(\.syncID) == ["favorite", "anchor"])
        #expect(!model.tabs.contains { $0.id == childRequest.id || $0.syncID == "child" })
        #expect(model.appTabs.first?.id == favoriteRequest.id)
        #expect(model.appTabs.first?.userTitleOverride == "Global Favorite")
        #expect(model.appTabs.first?.spaceID == "target")
        #expect(try first.store.pendingSyncQueue(for: first.owner) == queue)
        await first.service.waitForPendingOperations()
        await second.pull()
        await first.pull()
        for profile in [first, second] {
            let saved = try #require(profile.store.loadSnapshot())
            #expect(saved.spaces?.map(\.id) == ["target"])
            #expect(saved.tabs.compactMap(\.id) == ["favorite", "anchor"])
            #expect(saved.tabs.first { $0.id == "favorite" }?.placement == .app)
            #expect(saved.tabs.first { $0.id == "favorite" }?.userTitleOverride == "Global Favorite")
            #expect(try profile.store.pendingSyncQueue(for: profile.owner).isEmpty)
        }
        let final = try await fixture.inspect(account)
        #expect(Set(final.tabs.filter { !$0.deleted }.map(\.id)) == ["favorite", "anchor"])
        #expect(final.tabs.filter { !$0.deleted && $0.placement == "app" }.map(\.id) == ["favorite"])
        #expect(final.tabs
            .filter {
                !$0.deleted && $0.spaceID == "target" && $0.placement == "temporary"
            }
            .map(\.id) == ["anchor"])
        #expect(final.tabs.first { $0.id == "child" }?.tombstoned == true)
        #expect(final.tabs.first { $0.id == "favorite" }?.tombstoned == false)
        #expect(final.receiptCount == beforeDeletion.receiptCount + 1)
        let deletionAttempts = final.attempts.dropFirst(beforeDeletion.attempts.count)
        #expect(deletionAttempts.count == 1)
        #expect(deletionAttempts.first?.mutationID == deletion.id && deletionAttempts.first?.status == 201)
        await first.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }

    @Test func pendingRemoteURLTracksLatestAddressWithoutEchoOrDeletedTabResurrection() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("pending-navigation")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        let firstURL = "https://pending.example/first"
        let remoteURL = "https://pending.example/remote"
        let localURL = "https://example.com/pending-navigation/local"
        func snapshot(url: String?, includesChild: Bool = false) -> BrowserTabSessionSnapshot {
            let layout = syncHTTPExplicitSnapshot(
                source: url == nil ? [] : includesChild ? ["pending", "child"] : ["pending"], target: ["anchor"]
            )
            return BrowserTabSessionSnapshot(spaces: layout.spaces, tabs: layout.tabs.map { tab in
                guard tab.id == "pending", let url else { return tab }
                return .init(
                    id: "pending", urlString: url, spaceID: "source",
                    lastActivityTimestamp: syncHTTPModelDate.timeIntervalSince1970
                )
            })
        }
        await first.activate()
        await first.saveAndSend(snapshot(url: nil))
        await second.activate()

        let suite = "BrowserSyncHTTPPendingNavigation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BrowserUserPreferencesStore(userDefaults: defaults)
        preferences.restoreWindowsOnLaunch = true
        let driver = FakeBrowserTabDriver()
        let model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: first.store, sessionPreferencesStore: first.store,
            commandBarSuggestionProvider: FakeSuggestionProvider(), userPreferencesStore: preferences,
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: first.service,
            dateProvider: { syncHTTPModelDate }, windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
        defer {
            first.service.setSnapshotApplier(nil)
            model.discardUnsavedSessionForClosure()
            model.prepareForTermination()
        }
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        let anchor = try #require(model.tabs.first { $0.syncID == "anchor" })
        model.selectTab(id: anchor.id)
        driver.emitTabCreationState(id: anchor.id, state: .ready)
        first.service.setSnapshotApplier(model)
        await first.service.waitForPendingOperations()
        try #require(model.selectedTabID == anchor.id)
        try #require(first.store.pendingSyncQueue(for: first.owner).isEmpty)

        await second.saveAndSend(snapshot(url: firstURL))
        await first.pull()
        driver.flushPendingCreateEvents()
        let pending = try #require(model.tabs.first { $0.syncID == "pending" })
        #expect(pending.creationState == .creating && pending.urlString == firstURL)
        #expect(model.selectedTabID == anchor.id)

        // Keep the allocated tab without a ready browser. A later pull must
        // replace its initial target and SQLite projection without a local echo.
        await second.saveAndSend(snapshot(url: remoteURL, includesChild: true))
        let beforeRemoteApply = try await fixture.inspect(account)
        let selectionsBefore = driver.selectedTabIDs
        await first.pull()
        let child = try #require(driver.createdTabRequests.last { $0.urlString == "https://child.example" })
        let updated = try #require(model.tabs.first { $0.syncID == "pending" })
        #expect(updated.id == pending.id && updated.creationState == .creating)
        #expect(updated.urlString == remoteURL)
        #expect(first.store.loadSnapshot()?.tabs.first { $0.id == "pending" }?.urlString == remoteURL)
        #expect(driver.targetedNavigationRequests.contains { $0.id == pending.id && $0.urlString == remoteURL })
        #expect(model.selectedTabID == anchor.id && driver.selectedTabIDs == selectionsBefore)
        #expect(!model.tabs.contains { $0.syncID == "child" }, "Hold this logical-created callback until deletion")
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        let afterRemoteApply = try await fixture.inspect(account)
        #expect(afterRemoteApply.eventCount == beforeRemoteApply.eventCount)
        #expect(afterRemoteApply.receiptCount == beforeRemoteApply.receiptCount)
        #expect(afterRemoteApply.attempts.count == beforeRemoteApply.attempts.count)

        await second.saveAndSend(snapshot(url: remoteURL))
        let beforeDeletedCallback = try await fixture.inspect(account)
        await first.pull()
        #expect(driver.closedTabRequests.contains { $0.id == child.id && $0.forceClose })
        driver.flushPendingCreateEvents()
        #expect(!model.tabs.contains { $0.id == child.id || $0.syncID == "child" })
        let afterDeletionSnapshot = try #require(first.store.loadSnapshot())
        #expect(!afterDeletionSnapshot.tabs.contains { $0.id == "child" })
        #expect(model.selectedTabID == anchor.id)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        let afterDeletedCallback = try await fixture.inspect(account)
        #expect(afterDeletedCallback.eventCount == beforeDeletedCallback.eventCount)
        #expect(afterDeletedCallback.receiptCount == beforeDeletedCallback.receiptCount)
        #expect(afterDeletedCallback.attempts.count == beforeDeletedCallback.attempts.count)
        #expect(afterDeletedCallback.tabs.first { $0.id == "child" }?.tombstoned == true)

        model.selectTab(id: pending.id)
        model.presentCurrentPageCommandBar()
        model.currentPageCommandBarModel.query = localURL
        await model.currentPageCommandBarModel.waitForPendingSuggestionLoad()
        try #require(model.currentPageCommandBarModel.selectedSuggestion?.kind == .url)
        model.currentPageCommandBarModel.submitSelection()
        // Inspect the atomic local capture before yielding to the sender.
        #expect(model.tabs.first { $0.syncID == "pending" }?.urlString == localURL)
        #expect(model.selectedTabCreationState == .creating)
        #expect(first.store.loadSnapshot()?.tabs.first { $0.id == "pending" }?.urlString == localURL)
        let navigationQueue = try first.store.pendingSyncQueue(for: first.owner)
        try #require(navigationQueue.count == 1)
        let navigation = try syncHTTPSemanticMutation(navigationQueue[0])
        #expect(navigation.operations == [.patchTab(id: "pending", fields: .init(urlString: localURL))])
        #expect(driver.targetedNavigationRequests.last == .init(id: pending.id, urlString: localURL))
        model.setUserTitleOverride("Locally renamed", forTabID: pending.id)
        let queue = try first.store.pendingSyncQueue(for: first.owner)
        try #require(queue.count == 2)
        let rename = try syncHTTPSemanticMutation(queue[1])
        #expect(rename.operations == [.patchTab(
            id: "pending",
            fields: .init(userTitleOverride: .set("Locally renamed"))
        )])
        driver.emitCreatedTab(id: pending.id, urlString: firstURL, isActive: false)
        driver.emitTabCreationState(id: pending.id, state: .ready)
        #expect(model.tabs.first { $0.syncID == "pending" }?.urlString == localURL)
        #expect(try first.store.pendingSyncQueue(for: first.owner) == queue)
        try await first.sendSavedChanges()
        await second.pull()
        await first.pull()
        for profile in [first, second] {
            let saved = try #require(profile.store.loadSnapshot())
            #expect(Set(saved.tabs.compactMap(\.id)) == ["anchor", "pending"])
            #expect(saved.tabs.first { $0.id == "pending" }?.urlString == localURL)
            #expect(saved.tabs.first { $0.id == "pending" }?.userTitleOverride == "Locally renamed")
            #expect(try profile.store.pendingSyncQueue(for: profile.owner).isEmpty)
        }
        let final = try await fixture.inspect(account)
        #expect(final.tabs.first { $0.id == "pending" }?.urlString == localURL)
        #expect(final.tabs.first { $0.id == "pending" }?.title == "Locally renamed")
        #expect(final.tabs.first { $0.id == "child" }?.deleted == true)
        #expect(final.tabs.first { $0.id == "child" }?.tombstoned == true)
        #expect(final.receiptCount == afterDeletedCallback.receiptCount + 2)
        let sent = final.attempts.dropFirst(afterDeletedCallback.attempts.count)
        #expect(sent.map(\.mutationID) == [navigation.id, rename.id])
        #expect(sent
            .allSatisfy { $0.deviceID == account.devices[0].deviceID && $0.protocolVersion == 3 && $0.status == 201 })
        #expect(model.tabs.first { $0.syncID == "pending" }?.id == pending.id)
        #expect(model.selectedTabID == pending.id)
        await first.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }

    @Test func failedModelMoveBuffersLaterEditsAndRetriesExactIntentBeforeConverging() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("persistence-retry")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        await first.activate()
        let initial = syncHTTPExplicitSnapshot(source: ["a", "b", "c"], target: ["anchor"])
        await first.saveAndSend(initial)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        await second.suspend()

        let suite = "BrowserSyncHTTPPersistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let driver = FakeBrowserTabDriver()
        let model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: first.store, sessionPreferencesStore: first.store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: first.service,
            dateProvider: { syncHTTPModelDate }, windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
        defer {
            first.service.setSnapshotApplier(nil)
            model.discardUnsavedSessionForClosure()
            model.prepareForTermination()
        }
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        first.service.setSnapshotApplier(model)
        await first.service.waitForPendingOperations()
        let durableBefore = try #require(first.store.loadSnapshot())
        let cursorBefore = try first.store.syncCursor(for: first.owner)
        let serverBefore = try await fixture.inspect(account)
        try #require(first.store.pendingSyncQueue(for: first.owner).isEmpty)
        let databaseURL = directory.appendingPathComponent("\(account.devices[0].deviceID).sqlite")
        let database = try DatabaseQueue(path: databaseURL.path)
        func payloads() throws -> [Data] {
            try database.read { db in
                try Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
            }
        }
        try await database.write { db in
            try db.execute(sql: """
            CREATE TRIGGER fail_http_session_write BEFORE INSERT ON browser_spaces
            BEGIN SELECT RAISE(ABORT, 'injected HTTP profile write failure'); END
            """)
        }
        let a = try #require(model.tabs.first { $0.syncID == "a" })
        let c = try #require(model.tabs.first { $0.syncID == "c" })
        let selectedBefore = model.selectedTabID
        #expect(model.commitSidebarDrop(
            payload: BrowserSidebarDragPayload(primary: .tab(a.id), tabIDs: [a.id]),
            destination: BrowserSidebarDropDestination(container: .temporary("source"), beforeItem: .tab(c.id))
        ))
        #expect(model.sessionPersistenceFailure?.isRetryable == true)
        model.setUserTitleOverride("renamed while blocked", forTabID: a.id)
        #expect(model.closeTab(id: c.id, registersUndo: false))
        #expect(model.hasUncommittedSessionWrites && model.sessionPersistenceFailure?.isRetryable == true)
        #expect(model.selectedTabID == selectedBefore)
        #expect(model.tabs.map(\.syncID) == ["b", "a", "anchor"])
        // Explicit wakeups cannot bypass the failed-write guard or advance the
        // durable baseline while the model owns unsaved local actions.
        await first.pull()
        try await first.sendSavedChanges()
        let blocked = try await fixture.inspect(account)
        #expect(blocked.eventCount == serverBefore.eventCount)
        #expect(blocked.receiptCount == serverBefore.receiptCount)
        #expect(blocked.attempts.count == serverBefore.attempts.count)
        // Inspector ordering is global (rank, id); ranks are only meaningful
        // within each Space/placement list, so compare those lists separately.
        #expect(Set(blocked.tabs.filter { !$0.deleted }.map(\.id)) == Set(initial.tabs.compactMap(\.id)))
        #expect(blocked.tabs
            .filter {
                !$0.deleted && $0.spaceID == "source" && $0.placement == "temporary"
            }
            .map(\.id) == ["a", "b", "c"])
        #expect(blocked.tabs
            .filter {
                !$0.deleted && $0.spaceID == "target" && $0.placement == "temporary"
            }
            .map(\.id) == ["anchor"])
        #expect(first.store.loadSnapshot() == durableBefore)
        #expect(try first.store.syncCursor(for: first.owner) == cursorBefore)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)

        // The offline peer edits the soon-to-be-deleted identity. Its later
        // replay must receive the tombstone instead of bringing that tab back.
        second.store.saveSnapshot(syncHTTPExplicitSnapshot(
            source: ["a", "b", "c"], target: ["anchor"], titles: ["c": "stale offline rename"]
        ))
        let staleQueue = try second.store.pendingSyncQueue(for: second.owner)
        try #require(staleQueue.count == 1)
        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        try await database.write { db in try db.execute(sql: "DROP TRIGGER fail_http_session_write") }
        #expect(model.retrySessionPersistence())
        #expect(!model.hasUncommittedSessionWrites && model.sessionPersistenceFailure == nil)
        // No await separates retry from this inspection: all three actions
        // have committed atomically, before the production sender can run.
        let queue = try first.store.pendingSyncQueue(for: first.owner)
        try #require(queue.count == 3)
        let moves = try syncHTTPSemanticMutation(queue[0])
        let rename = try syncHTTPSemanticMutation(queue[1])
        let deletion = try syncHTTPSemanticMutation(queue[2])
        #expect(moves.operations == [.moveTabs(
            ids: ["a"], destination: .init(spaceID: "source", placement: .temporary), beforeID: "c", afterID: "b"
        )])
        #expect(rename.operations == [.patchTab(
            id: "a",
            fields: .init(userTitleOverride: .set("renamed while blocked"))
        )])
        #expect(deletion.operations == [.deleteTab(id: "c")])
        let frozenPayloads = try payloads()
        await first.service.waitForPendingOperations()
        let afterDrop = try await fixture.inspect(account)
        let committedMove = try #require(afterDrop.attempts.last { $0.mutationID == moves.id })
        #expect(committedMove.protocolVersion == 3 && committedMove.status == 201)
        #expect(try first.store.pendingSyncQueue(for: first.owner) == queue)
        #expect(try payloads() == frozenPayloads)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(try reopened.pendingSyncQueue(for: first.owner) == queue)

        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        try await first.sendSavedChanges()
        await second.activate()
        await first.pull()
        await second.pull()
        driver.flushPendingCreateEvents()
        let expected = syncHTTPExplicitSnapshot(
            source: ["b", "a"], target: ["anchor"], titles: ["a": "renamed while blocked"]
        )
        #expect(first.store.loadSnapshot()?.tabs == expected.tabs)
        #expect(second.store.loadSnapshot()?.tabs == expected.tabs)
        #expect(model.tabs.map(\.syncID) == expected.tabs.compactMap(\.id))
        #expect(model.tabs.first { $0.syncID == "a" }?.userTitleOverride == "renamed while blocked")
        #expect(!model.hasUncommittedSessionWrites)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(try second.store.pendingSyncQueue(for: second.owner).isEmpty)
        let final = try await fixture.inspect(account)
        let retriedMove = final.attempts.filter { $0.mutationID == moves.id }
        #expect(retriedMove.count >= 2 && Set(retriedMove.map(\.digest)) == [committedMove.digest])
        #expect(Set(final.tabs.filter { !$0.deleted }.map(\.id)) == Set(expected.tabs.compactMap(\.id)))
        #expect(final.tabs
            .filter {
                !$0.deleted && $0.spaceID == "source" && $0.placement == "temporary"
            }
            .map(\.id) == ["b", "a"])
        #expect(final.tabs
            .filter {
                !$0.deleted && $0.spaceID == "target" && $0.placement == "temporary"
            }
            .map(\.id) == ["anchor"])
        #expect(final.tabs.first { $0.id == "c" }?.tombstoned == true)
        #expect(final.attempts.contains { $0.mutationID == staleQueue[0].id && $0.status == 201 })
        await first.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }

    @Test(arguments: [false, true])
    func actualModelDropPreservesMovedIdentityAgainstConflictingRemoteMove(localFirst: Bool) async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account(localFirst ? "explicit-local-first" : "explicit-remote-first")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        await first.activate()
        let initial = syncHTTPExplicitSnapshot(source: ["a", "b", "c"], target: ["anchor"])
        await first.saveAndSend(initial)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        await first.suspend()
        await second.suspend()
        // Restore the real model using a fake browser engine, then invoke its
        // production drop entry point. The resulting SQLite row uses stable IDs.
        try syncHTTPCaptureActualModelDrop(profile: first, movedID: "a", beforeID: "c")
        let localQueue = try first.store.pendingSyncQueue(for: first.owner)
        try #require(localQueue.count == 1)
        let localMutation = try syncHTTPSemanticMutation(localQueue[0])
        #expect(localMutation.operations == [
            .moveTabs(
                ids: ["a"],
                destination: .init(spaceID: "source", placement: .temporary),
                beforeID: "c",
                afterID: "b"
            ),
        ])
        #expect(first.store.loadSnapshot()?.tabs.compactMap(\.id) == ["b", "a", "c", "anchor"])

        let remotelyMoved = syncHTTPExplicitSnapshot(
            source: ["b", "c"], target: ["a", "anchor"], titles: ["a": "remote metadata survives"]
        )
        second.store.saveSnapshot(remotelyMoved, syncMove: BrowserSyncMoveIntent(tabIDs: ["a"]))
        let remoteQueue = try second.store.pendingSyncQueue(for: second.owner)
        try #require(remoteQueue.count == 1 && remoteQueue[0].protocolVersion == 3)
        if localFirst {
            await first.activate()
            await second.activate()
        } else {
            await second.activate()
            await first.activate()
        }
        await first.pull()
        await second.pull()
        let expected = localFirst
            ? remotelyMoved
            : syncHTTPExplicitSnapshot(
                source: ["b", "a", "c"], target: ["anchor"], titles: ["a": "remote metadata survives"]
            )
        #expect(first.store.loadSnapshot()?.tabs == expected.tabs)
        #expect(second.store.loadSnapshot()?.tabs == expected.tabs)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(try second.store.pendingSyncQueue(for: second.owner).isEmpty)
        let state = try await fixture.inspect(account)
        let a = try #require(state.tabs.first { $0.id == "a" })
        #expect(a.spaceID == (localFirst ? "target" : "source"))
        #expect(a.title == "remote metadata survives" && !a.deleted && !a.tombstoned)
        let delivered = state.attempts
            .filter { $0.mutationID == localMutation.id || $0.mutationID == remoteQueue[0].id }
        #expect(delivered.map(\.mutationID) == (localFirst
                ? [localMutation.id, remoteQueue[0].id]
                : [remoteQueue[0].id, localMutation.id]))
        #expect(delivered.allSatisfy { $0.protocolVersion == 3 && $0.status == 201 })
        await first.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }

    @Test func explicitGroupMoveKeepsFrozenIDsAcrossRemoteDeletesLostACKAndReopen() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("explicit-group-replay")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: SyncHTTPProfile? = try SyncHTTPProfile(
            fixture: fixture, device: account.devices[0], directory: directory
        )
        let owner = try #require(first?.owner)
        await first?.activate()
        let initial = syncHTTPExplicitSnapshot(source: ["g1", "g2", "g3"], target: ["left", "anchor", "tail"])
        await first?.saveAndSend(initial)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        await first?.suspend()
        let optimistic = syncHTTPExplicitSnapshot(source: [], target: ["left", "g1", "g2", "g3", "anchor", "tail"])
        first?.store.saveSnapshot(optimistic, syncMove: BrowserSyncMoveIntent(tabIDs: ["g1", "g2", "g3"]))
        let storedQueue = try first?.store.pendingSyncQueue(for: owner)
        let pending = try #require(storedQueue)
        try #require(pending.count == 1)
        let group = try syncHTTPSemanticMutation(pending[0])
        #expect(group.operations == [
            .moveTabs(
                ids: ["g1", "g2", "g3"],
                destination: .init(spaceID: "target", placement: .temporary),
                beforeID: "anchor",
                afterID: "left"
            ),
        ])
        // The canonical member and preferred anchor disappear before replay.
        // The surviving group must use its captured after-anchor and metadata.
        let remoteDeletion = syncHTTPExplicitSnapshot(
            source: ["g1", "g3"], target: ["left", "tail"], titles: ["g3": "remote survivor title"]
        )
        await second.saveAndSend(remoteDeletion)
        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        await first?.activate()
        let afterDrop = try await fixture.inspect(account)
        let committed = try #require(afterDrop.attempts.last { $0.mutationID == group.id })
        #expect(committed.protocolVersion == 3 && committed.status == 201)
        #expect(afterDrop.tabs.filter { !$0.deleted && $0.spaceID == "target" }.map(\.id) == [
            "left",
            "g1",
            "g3",
            "tail",
        ])
        #expect(afterDrop.tabs.first { $0.id == "g2" }?.tombstoned == true)
        #expect(afterDrop.tabs.first { $0.id == "anchor" }?.tombstoned == true)
        #expect(try first?.store.pendingSyncQueue(for: owner) == pending)
        await first?.disconnect()
        first = nil

        await second.pull()
        // Make an older receipt observably stale: a surviving member moves again.
        let latest = syncHTTPExplicitSnapshot(
            source: ["g3"], target: ["left", "g1", "tail"], titles: ["g3": "newer after committed group"]
        )
        second.store.saveSnapshot(latest, syncMove: BrowserSyncMoveIntent(tabIDs: ["g3"]))
        try await second.sendSavedChanges()
        let beforeRetry = try await fixture.inspect(account)
        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        #expect(
            try first?.store.pendingSyncQueue(for: owner) == pending,
            "Deleted IDs remain frozen in the durable row"
        )
        await first?.activate()
        await first?.pull()
        await second.pull()
        let afterRetry = try await fixture.inspect(account)
        let retries = afterRetry.attempts.filter { $0.mutationID == group.id }
        #expect(retries.count > beforeRetry.attempts.filter { $0.mutationID == group.id }.count)
        #expect(Set(retries.map(\.digest)) == [committed.digest])
        #expect(retries.allSatisfy { $0.protocolVersion == 3 && $0.status == 201 })
        #expect(afterRetry.eventCount == beforeRetry.eventCount && afterRetry.receiptCount == beforeRetry.receiptCount)
        #expect(first?.store.loadSnapshot()?.tabs == latest.tabs)
        #expect(second.store.loadSnapshot()?.tabs == latest.tabs)
        #expect(try first?.store.pendingSyncQueue(for: owner).isEmpty == true)
        #expect(try second.store.pendingSyncQueue(for: second.owner).isEmpty)
        #expect(afterRetry.tabs.first { $0.id == "g2" }?.tombstoned == true)
        #expect(afterRetry.tabs.first { $0.id == "anchor" }?.tombstoned == true)
        #expect(afterRetry.tabs.first { $0.id == "g3" }?.spaceID == "source")
        #expect(afterRetry.tabs.first { $0.id == "g3" }?.title == "newer after committed group")
        await first?.disconnect()
        await second.disconnect()
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
            let urlString: String
            let title: String?
            let pinnedFolderID: String?
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

        struct Folder: Decodable {
            let id: String
            let spaceID: String
            let parentFolderID: String?
            let title: String
            let systemImageName: String?
            let rank: Double
            let deleted: Bool
        }

        let eventCount: Int
        let receiptCount: Int
        let tabs: [Tab]
        let folders: [Folder]
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
        let owner = BrowserSyncOwner(baseURL: fixture.baseURL, userID: device.userID)
        try store.bindSyncOwner(owner)
        self.owner = owner
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
    let owner: BrowserSyncOwner

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

    func sendSavedChanges() async throws {
        try service.schedulePush(snapshot: #require(store.loadSnapshot()))
        await service.waitForPendingOperations()
    }

    func suspend() async {
        service.accountSessionDidChange(nil)
        await service.waitForPendingOperations()
    }

    func disconnect() async {
        await suspend()
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
    case expectedSemanticMutation
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

private func syncHTTPSemanticSnapshot(
    title: String? = nil,
    moved: Bool = false,
    deleted: Bool = false
) -> BrowserTabSessionSnapshot {
    let moving = BrowserTabSessionSnapshotTab(
        id: "moving", urlString: "https://moving.example", userTitleOverride: title,
        spaceID: moved ? "target" : "source"
    )
    let sentinel = BrowserTabSessionSnapshotTab(
        id: "source-sentinel", urlString: "https://source.example", spaceID: "source"
    )
    let anchor = BrowserTabSessionSnapshotTab(id: "anchor", urlString: "https://anchor.example", spaceID: "target")
    return BrowserTabSessionSnapshot(
        spaces: [
            BrowserSpaceSessionSnapshot(id: "source", title: "Source", systemImageName: "globe"),
            BrowserSpaceSessionSnapshot(id: "target", title: "Target", systemImageName: "star"),
        ],
        tabs: deleted ? [sentinel, anchor] : (moved ? [sentinel, moving, anchor] : [moving, sentinel, anchor])
    )
}

private let syncHTTPModelDate = Date(timeIntervalSince1970: 1_800_000_000)

private func syncHTTPExplicitSnapshot(
    source: [String], target: [String], titles: [String: String] = [:]
) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [
            BrowserSpaceSessionSnapshot(
                id: "source",
                title: "Source",
                systemImageName: "globe",
                selectedTabIndex: source.isEmpty
                    ? nil
                    : 0
            ),
            BrowserSpaceSessionSnapshot(
                id: "target",
                title: "Target",
                systemImageName: "star",
                selectedTabIndex: target.isEmpty
                    ? nil
                    : 0
            ),
        ],
        tabs: [("source", source), ("target", target)].flatMap { space, ids in
            ids.map { id in BrowserTabSessionSnapshotTab(
                id: id, urlString: "https://\(id).example", userTitleOverride: titles[id], spaceID: space,
                lastActivityTimestamp: syncHTTPModelDate.timeIntervalSince1970
            ) }
        }
    )
}

private func syncHTTPSemanticMutation(_ queued: BrowserSyncQueuedMutation) throws -> BrowserSyncSemanticMutation {
    guard case .semantic(let mutation) = queued else {
        Issue.record("Expected durable semantic mutation")
        throw SyncHTTPError.expectedSemanticMutation
    }
    return mutation
}

@MainActor private func syncHTTPCaptureActualModelDrop(
    profile: SyncHTTPProfile, movedID: String, beforeID: String
) throws {
    let suite = "BrowserSyncHTTPModel.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let driver = FakeBrowserTabDriver()
    let model = BrowserChromeModel(
        tabDriver: driver, sessionSnapshotStore: profile.store, sessionPreferencesStore: profile.store,
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults),
        extensionManager: FakeBrowserExtensionManager(), syncCoordinator: profile.service,
        dateProvider: { syncHTTPModelDate }, windowTitleHandler: { _ in }, allTabsClosedHandler: {}
    )
    defer { model.prepareForTermination() }
    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let moved = try #require(model.tabs.first { $0.syncID == movedID })
    let anchor = try #require(model.tabs.first { $0.syncID == beforeID })
    let selectedBefore = model.tabs.first { $0.id == model.selectedTabID }?.syncID
    #expect(model.commitSidebarDrop(
        payload: BrowserSidebarDragPayload(primary: .tab(moved.id), tabIDs: [moved.id]),
        destination: BrowserSidebarDropDestination(container: .temporary("source"), beforeItem: .tab(anchor.id))
    ))
    #expect(
        model.tabs.first { $0.id == model.selectedTabID }?.syncID == selectedBefore,
        "The real model retains selection across a local drop"
    )
    #expect(model.tabs.filter { $0.spaceID == "source" }.map(\.syncID) == ["b", "a", "c"])
}

extension BrowserSyncHTTPIntegrationTests {
    @Test func foldersCreatedByModelSyncWithEmptySiblingOrderAndSurviveRestart() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("folder-roundtrip")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        await first.activate()
        #expect(try first.store.syncPullProtocolVersion(for: first.owner) == 4)
        await first.saveAndSend(syncHTTPFolderSeed())
        await first.suspend()
        var rootID = "", nestedID = "", emptyID = ""
        try syncHTTPWithModel(first) { model in
            @MainActor func id(_ stable: String) throws
            -> String { try #require(model.tabs.first { $0.syncID == stable }?.id) }
            rootID = try #require(model.createPinnedTabFolder(containingTabIDs: [id("b"), id("c")]))
            nestedID = try #require(model.createPinnedTabFolder(containingTabIDs: [id("c")]))
            model.movePinnedTabFolder(withID: nestedID, toRootSectionIndex: 1, targetParentFolderID: rootID)
            emptyID = try #require(model.createPinnedTabFolder(containingTabIDs: [id("d")]))
            let d = try id("d")
            #expect(model.commitSidebarDrop(
                payload: .init(primary: .tab(d), tabIDs: [d]), destination: .init(container: .pinned("source"))
            ))
            #expect(try model.commitSidebarDrop(
                payload: .init(primary: .folder(emptyID), tabIDs: []),
                destination: .init(container: .pinned("source"), beforeItem: .tab(id("a")))
            ))
            model.setTitle("Research", forPinnedTabFolderID: rootID)
            model.setIcon("book", forPinnedTabFolderID: rootID)
            let tree = BrowserSidebarTabTree(snapshot: model.sidebarSnapshot)
            #expect(tree.items(in: .pinned("source")).first == .folder(emptyID))
            #expect(tree.folders[nestedID]?.parentFolderID == rootID)
        }
        let frozen = try first.store.pendingSyncQueue(for: first.owner)
        #expect(!frozen.isEmpty && frozen.allSatisfy { $0.protocolVersion == 4 })
        await first.activate()
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        let firstSaved = try #require(first.store.loadSnapshot())
        #expect(try syncHTTPFolderRecords(#require(second.store.loadSnapshot())) == syncHTTPFolderRecords(firstSaved))
        #expect(second.store.loadSnapshot()?.pinnedTabFolders?.count == 3)
        let state = try await fixture.inspect(account)
        #expect(state.folders.first { $0.id == rootID }?.title == "Research")
        #expect(state.folders.first { $0.id == rootID }?.systemImageName == "book")
        #expect(state.folders.first { $0.id == nestedID }?.parentFolderID == rootID)
        #expect(state.tabs.first { $0.id == "b" }?.pinnedFolderID == rootID)
        #expect(state.tabs.first { $0.id == "c" }?.pinnedFolderID == nestedID)
        await second.disconnect()
        let reopened = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        try syncHTTPWithModel(reopened) { model in
            let tree = BrowserSidebarTabTree(snapshot: model.sidebarSnapshot)
            #expect(tree.items(in: .pinned("source")).first == .folder(emptyID))
            #expect(tree.items(in: .pinned("source", folderID: emptyID)).isEmpty)
            #expect(tree.folders[nestedID]?.parentFolderID == rootID)
        }
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner).isEmpty)
        await reopened.activate()
        #expect(try syncHTTPFolderRecords(#require(reopened.store.loadSnapshot())) == syncHTTPFolderRecords(firstSaved))
        let afterRestart = try await fixture.inspect(account)
        #expect(afterRestart.eventCount == state.eventCount && afterRestart.receiptCount == state.receiptCount)
        await first.disconnect()
        await reopened.disconnect()
        try await fixture.complete(account)
    }

    @Test func offlineFolderMoveCarriesCurrentSubtreeAndDeletePreservesEscapedChild() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("folder-race")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        await first.activate()
        await first.saveAndSend(syncHTTPFolderSeed(folder: true))
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        await first.suspend()
        try syncHTTPWithModel(first) { model in
            model.movePinnedTabFolder(withID: "root", toRootSectionIndex: 0, targetSpaceID: "target")
        }
        let queued = try first.store.pendingSyncQueue(for: first.owner)
        let move = try syncHTTPFolderMutation(#require(queued.first))
        #expect(move.operations.contains {
            if case .move(let items, _, _, _) = $0 {
                return items == [.init(entityType: .folder, entityID: "root")]
            }
            return false
        })
        #expect(!move.operations.contains {
            if case .move(let items, _, _, _) = $0 {
                return items.contains { $0.entityType == .tab }
            }
            return false
        })
        await second.suspend()
        try syncHTTPWithModel(second) { model in
            let escaped = try #require(model.tabs.first { $0.syncID == "b" }?.id)
            #expect(model.commitSidebarDrop(
                payload: .init(primary: .tab(escaped), tabIDs: [escaped]),
                destination: .init(container: .pinned("source"))
            ))
        }
        await second.activate()
        await first.activate()
        await second.pull()
        let moved = try await fixture.inspect(account)
        #expect(moved.folders.first { $0.id == "root" }?.spaceID == "target")
        #expect(moved.tabs.first { $0.id == "b" }?.spaceID == "source")
        #expect(moved.tabs.first { $0.id == "b" }?.pinnedFolderID == nil)
        #expect(moved.tabs.first { $0.id == "c" }?.spaceID == "target")
        await first.suspend()
        try syncHTTPWithModel(first) { #expect($0.deletePinnedTabFolder(id: "root")) }
        await first.activate()
        await second.pull()
        let deleted = try await fixture.inspect(account)
        #expect(deleted.folders.first { $0.id == "root" }?.deleted == true)
        #expect(deleted.tabs.first { $0.id == "c" }?.tombstoned == true)
        #expect(deleted.tabs.first { $0.id == "b" }?.deleted == false)
        #expect(deleted.tabs.first { $0.id == "favorite" }?.deleted == false)
        #expect(try syncHTTPFolderRecords(#require(first.store.loadSnapshot()))
            == syncHTTPFolderRecords(#require(second.store.loadSnapshot())))
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(try second.store.pendingSyncQueue(for: second.owner).isEmpty)
        await first.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }

    @Test func folderLostAcknowledgementRetriesSamePayloadAfterClientRestart() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("folder-lost-ack")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        await first.activate()
        await first.saveAndSend(syncHTTPFolderSeed(folder: true))
        await first.suspend()
        try syncHTTPWithModel(first) { $0.setTitle("Durable rename", forPinnedTabFolderID: "root") }
        let frozen = try first.store.pendingSyncQueue(for: first.owner)
        try #require(frozen.count == 1)
        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        await first.activate()
        #expect(try first.store.pendingSyncQueue(for: first.owner) == frozen)
        let committed = try await fixture.inspect(account)
        #expect(committed.folders.first { $0.id == "root" }?.title == "Durable rename")
        await first.disconnect()
        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        let reopened = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner) == frozen)
        await reopened.activate()
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner).isEmpty)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        let final = try await fixture.inspect(account)
        #expect(final.eventCount == committed.eventCount && final.receiptCount == committed.receiptCount)
        let attempts = final.attempts.filter { $0.mutationID == frozen[0].id }
        #expect(attempts.count >= 2 && Set(attempts.map(\.digest)).count == 1)
        #expect(try syncHTTPFolderRecords(#require(reopened.store.loadSnapshot()))
            == syncHTTPFolderRecords(#require(second.store.loadSnapshot())))
        await reopened.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }
}

private func syncHTTPFolderSeed(folder: Bool = false) -> BrowserTabSessionSnapshot {
    let urls = ["a", "b", "c", "d"].map { (id: String) in
        BrowserTabSessionSnapshotTab(
            id: id, urlString: "https://\(id).example", pinnedURLString: "https://\(id).example",
            placement: .spacePinned, spaceID: "source",
            pinnedFolderID: folder && ["b", "c"].contains(id) ? "root" : nil,
            lastActivityTimestamp: syncHTTPModelDate.timeIntervalSince1970
        )
    }
    return BrowserTabSessionSnapshot(
        spaces: [
            .init(id: "source", title: "Source", systemImageName: "globe"),
            .init(id: "target", title: "Target", systemImageName: "star"),
        ],
        pinnedTabFolders: folder ? [.init(id: "root", spaceID: "source", title: "Root")] : [],
        tabs: [.init(
            id: "favorite",
            urlString: "https://favorite.example",
            placement: .app,
            spaceID: "source",
            lastActivityTimestamp: syncHTTPModelDate.timeIntervalSince1970
        )] + urls
    )
}

@MainActor private func syncHTTPWithModel(
    _ profile: SyncHTTPProfile,
    body: (BrowserChromeModel) throws -> Void
) throws {
    let suite = "BrowserSyncHTTPFolderModel.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let driver = FakeBrowserTabDriver()
    let model = BrowserChromeModel(
        tabDriver: driver, sessionSnapshotStore: profile.store, sessionPreferencesStore: profile.store,
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults), extensionManager: FakeBrowserExtensionManager(),
        syncCoordinator: profile.service, dateProvider: { syncHTTPModelDate }, windowTitleHandler: { _ in },
        allTabsClosedHandler: {}
    )
    defer { model.prepareForTermination() }
    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.selectSpace(id: "source")
    try body(model)
}

private func syncHTTPFolderMutation(_ queued: BrowserSyncQueuedMutation) throws -> BrowserSyncFolderMutation {
    guard case .folders(let mutation) = queued else { throw SyncHTTPError.expectedSemanticMutation }
    return mutation
}

private func syncHTTPFolderRecords(_ snapshot: BrowserTabSessionSnapshot) -> [BrowserSyncChange] {
    BrowserSyncFolderProjection.canonicalChanges(snapshot)
        .filter { $0.entityType != .space }
        .sorted { BrowserSyncOutboxProjection.key($0) < BrowserSyncOutboxProjection.key($1) }
}
