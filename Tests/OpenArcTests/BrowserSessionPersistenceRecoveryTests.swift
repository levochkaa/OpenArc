// BrowserSessionPersistenceRecoveryTests.swift

import Foundation
import Testing

// MARK: - BrowserSessionPersistenceRecoveryTests

@Suite(.serialized)
@MainActor struct BrowserSessionPersistenceRecoveryTests {
    @Test func failedDragThenRenameRetainsFIFOIntentAcrossRepeatedFailureAndRestart() throws {
        let f = SessionRecoveryFixture()
        let savedCount = f.store.savedSnapshots.count
        let preferenceCount = f.preferences.savedSelectedTabIndices.count
        f.sync.reset()
        f.store.sessionWriteError = SessionRecoveryTestError.unavailable
        #expect(f.model.commitSidebarDrop(
            payload: .init(primary: .tab(f.id("a")), tabIDs: [f.id("a")]),
            destination: .init(container: .temporary("s")),
        ))
        f.model.setUserTitleOverride("Renamed", forTabID: f.id("a"))
        #expect(f.model.hasUncommittedSessionWrites)
        #expect(f.model.sessionPersistenceFailure?.reason == .writeFailed)
        #expect(f.model.sessionPersistenceFailure?.isRetryable == true)
        #expect(f.store.savedSnapshots.count == savedCount)
        #expect(f.preferences.savedSelectedTabIndices.count == preferenceCount)
        #expect(f.sync.pushes.isEmpty)
        #expect(f.sync.blocked.last == true)
        let failed = try #require(f.store.attemptedSessionWriteBatches.last)
        #expect(failed.count == 2)
        #expect(failed[0].origin == .local(syncMove: .init(tabIDs: ["a"])))
        #expect(failed[0].snapshot.tabs.map(\.id) == ["b", "a"])
        #expect(failed[0].snapshot.tabs.last?.userTitleOverride == "A")
        #expect(failed[1].origin == .local(syncMove: nil))
        #expect(failed[1].snapshot.tabs.last?.userTitleOverride == "Renamed")
        #expect(!f.model.retrySessionPersistence())
        #expect(f.store.attemptedSessionWriteBatches.last == failed)
        f.store.sessionWriteError = nil
        #expect(f.model.retrySessionPersistence())
        #expect(f.store.savedSessionWriteBatches.last == failed)
        #expect(!f.model.hasUncommittedSessionWrites)
        #expect(f.model.sessionPersistenceFailure == nil)
        #expect(f.sync.blocked.last == false)
        #expect(f.sync.pulls == 1)
        #expect(f.sync.pushes.count == 1)
        let restored = try SessionRecoveryFixture(snapshot: #require(f.store.savedSnapshots.last))
        #expect(restored.model.tabs.map(\.syncID) == ["b", "a"])
        #expect(restored.model.tabs.last?.userTitleOverride == "Renamed")
        #expect(restored.store.savedSyncMoves.isEmpty)
    }

    @Test func successfulNextActionCommitsWholeFailedPrefixBeforeUnblocking() throws {
        let f = SessionRecoveryFixture()
        f.store.sessionWriteError = SessionRecoveryTestError.unavailable
        f.model.moveTab(withID: f.id("a"), toPlacement: .spacePinned, atSectionIndex: 0)
        let first = try #require(f.store.attemptedSessionWriteBatches.last?.first)
        f.store.sessionWriteError = nil
        f.model.setUserTitleOverride("Later", forTabID: f.id("a"))
        let saved = try #require(f.store.savedSessionWriteBatches.last)
        #expect(saved.count == 2)
        #expect(saved.first == first)
        #expect(saved.last?.snapshot.tabs.first?.userTitleOverride == "Later")
        #expect(!f.model.hasUncommittedSessionWrites)
        #expect(f.sync.blocked.last == false)
    }

    @Test func failedProjectionRetainsItsOriginAndRetryDoesNotNotifyLocalPush() throws {
        let f = SessionRecoveryFixture()
        f.sync.reset()
        f.store.sessionWriteError = SessionRecoveryTestError.unavailable
        let remote = recoverySnapshot(ids: ["b", "a"], title: "Remote")
        f.model.applyRemoteSyncSnapshot(remote)
        #expect(f.model.tabs.map(\.syncID) == ["b", "a"])
        let failed = try #require(f.store.attemptedSessionWriteBatches.last)
        #expect(failed.count == 1)
        #expect(failed[0].origin == .remoteProjection)
        let attempts = f.store.attemptedSessionWriteBatches.count
        let savedCount = f.store.savedSnapshots.count
        f.store.sessionWriteError = nil
        #expect(f.model.retrySessionPersistence())
        #expect(f.store.savedSessionWriteBatches.last == failed)
        #expect(f.store.attemptedSessionWriteBatches.count == attempts + 1)
        #expect(f.store.savedSnapshots.count == savedCount + 1)
        #expect(f.store.savedSnapshots.last == failed[0].snapshot)
        #expect(f.sync.pushes.isEmpty)
        #expect(f.sync.pulls == 1)
        #expect(!f.model.hasUncommittedSessionWrites)
    }

    @Test func failedWriteRejectsDirectRemoteApplyAndNeverReplaysStaleProjectionAfterRetry() {
        let f = SessionRecoveryFixture()
        f.store.sessionWriteError = SessionRecoveryTestError.unavailable
        f.model.setUserTitleOverride("Local", forTabID: f.id("a"))
        let before = f.model.sessionRecoverySnapshot()
        let closedCount = f.driver.closedTabRequests.count
        f.model.applyRemoteSyncSnapshot(recoverySnapshot(ids: ["b"], title: "Stale remote"))
        #expect(f.model.sessionRecoverySnapshot() == before)
        #expect(f.driver.closedTabRequests.count == closedCount)
        f.store.sessionWriteError = nil
        #expect(f.model.retrySessionPersistence())
        #expect(f.model.tabs.map(\.syncID) == ["a", "b"])
        #expect(f.model.tabs.first?.userTitleOverride == "Local")
        #expect(f.model.spaces.first?.title == "Space")
    }

    @Test func localFailureDuringPendingRemoteCreationKeepsMoveAndProjectionModesInOrder() throws {
        let f = SessionRecoveryFixture()
        f.sync.reset()
        f.store.sessionWriteError = SessionRecoveryTestError.unavailable
        f.model.applyRemoteSyncSnapshot(recoverySnapshot(ids: ["a", "b", "c"]))
        #expect(f.model.commitSidebarDrop(
            payload: .init(primary: .tab(f.id("a")), tabIDs: [f.id("a")]),
            destination: .init(container: .temporary("s")),
        ))
        #expect(f.model.sessionRecoverySnapshot().tabs.contains { $0.id == "c" })
        f.driver.flushPendingCreateEvents()
        let failed = try #require(f.store.attemptedSessionWriteBatches.last)
        #expect(failed.count == 2)
        #expect(failed.first?.origin == .local(syncMove: .init(tabIDs: ["a"])))
        #expect(failed.last?.origin == .remoteProjection)
        #expect(Set(failed.last?.snapshot.tabs.compactMap(\.id) ?? []) == ["a", "b", "c"])
        f.store.sessionWriteError = nil
        #expect(f.model.retrySessionPersistence())
        #expect(f.store.savedSessionWriteBatches.last == failed)
        #expect(!f.model.hasUncommittedSessionWrites)
        #expect(f.sync.pushes.count == 1)
    }

    @Test func bufferCountOverflowIsTerminalAndCannotImplicitlyDiscardFailedMoves() {
        let f = SessionRecoveryFixture()
        f.store.sessionWriteError = SessionRecoveryTestError.unavailable
        for index in 0..<33 {
            f.model.setUserTitleOverride("Rename \(index)", forTabID: f.id("a"))
        }
        #expect(f.model.sessionPersistenceFailure?.reason == .bufferLimitExceeded)
        #expect(f.model.sessionPersistenceFailure?.isRetryable == false)
        #expect(f.store.attemptedSessionWriteBatches.last?.count == 32)
        let attempts = f.store.attemptedSessionWriteBatches.count
        f.store.sessionWriteError = nil
        f.model.setUserTitleOverride("Live unsaved tail", forTabID: f.id("a"))
        #expect(!f.model.retrySessionPersistence())
        #expect(!f.model.prepareSessionForClosure())
        #expect(f.model.hasUncommittedSessionWrites)
        #expect(f.store.attemptedSessionWriteBatches.count == attempts)
        #expect(f.model.sessionRecoverySnapshot().tabs.first?.userTitleOverride == "Live unsaved tail")
        #expect(f.model.sessionPersistenceFailure?.reason == .bufferLimitExceeded)
    }

    @Test func deterministicErrorsRemainTerminalAfterStorageRecovers() {
        let cases: [(Error, BrowserSessionPersistenceFailure.Reason)] = [
            (BrowserSyncQueueError.mutationTooLarge, .mutationTooLarge),
            (BrowserSessionWriteError.duplicateMoveIDs, .invalidMoveIntent),
        ]
        for (error, reason) in cases {
            let f = SessionRecoveryFixture()
            f.store.sessionWriteError = error
            f.model.setUserTitleOverride("Rejected", forTabID: f.id("a"))
            #expect(f.model.sessionPersistenceFailure?.reason == reason)
            let attempts = f.store.attemptedSessionWriteBatches.count
            f.store.sessionWriteError = nil
            f.model.setUserTitleOverride("Smaller later value", forTabID: f.id("a"))
            #expect(!f.model.retrySessionPersistence())
            #expect(!f.model.prepareSessionForClosure())
            #expect(f.store.attemptedSessionWriteBatches.count == attempts)
            #expect(f.model.sessionPersistenceFailure?.reason == reason)
        }
    }

    @Test func byteLimitRetainsEarlierFIFOEntryAndNeverClearsTerminalFailure() throws {
        let first = BrowserSessionWrite(
            snapshot: recoverySnapshot(ids: ["a"]),
            origin: .local(syncMove: .init(tabIDs: ["a"])),
        )
        let second = BrowserSessionWrite(snapshot: recoverySnapshot(ids: ["b"]), origin: .remoteProjection)
        let bytes = try JSONEncoder().encode(first.snapshot).count
        var buffer = BrowserSessionWriteBuffer(maximumCount: 8, maximumBytes: bytes)
        let appendedFirst = buffer.append(first)
        #expect(appendedFirst)
        buffer.recordFailure(SessionRecoveryTestError.unavailable)
        let appendedSecond = buffer.append(second)
        #expect(!appendedSecond)
        #expect(buffer.failure?.reason == .bufferLimitExceeded)
        #expect(buffer.writes == [first])
        #expect(buffer.encodedBytes == bytes)
        buffer.clearAfterSuccess()
        #expect(buffer.writes == [first])
        let appendedAfterTerminalFailure = buffer.append(first)
        #expect(!appendedAfterTerminalFailure)
        #expect(buffer.failure?.reason == .bufferLimitExceeded)
    }

    @Test func closureFailureDoesNotTearDownAndExplicitDiscardPreventsLastSave() {
        let f = SessionRecoveryFixture()
        f.store.sessionWriteError = SessionRecoveryTestError.unavailable
        f.model.setUserTitleOverride("Unsaved", forTabID: f.id("a"))
        #expect(!f.model.prepareSessionForClosure())
        #expect(!f.model.isShuttingDown)
        #expect(f.driver.prepareForCefShutdownCount == 0)
        let attempts = f.store.attemptedSessionWriteBatches.count
        f.model.discardUnsavedSessionForClosure()
        #expect(f.model.prepareSessionForClosure())
        #expect(!f.model.retrySessionPersistence())
        f.model.prepareForTermination()
        #expect(f.model.isShuttingDown)
        #expect(f.store.attemptedSessionWriteBatches.count == attempts)
        #expect(f.sync.blocked.last == true)
    }

    @Test func successfulClosurePreflightAvoidsSecondWriteButCancelledClosureRemainsWritable() {
        let f = SessionRecoveryFixture()
        #expect(f.model.prepareSessionForClosure())
        let attempts = f.store.attemptedSessionWriteBatches.count
        f.store.sessionWriteError = SessionRecoveryTestError.unavailable
        f.model.prepareForTermination()
        #expect(f.model.isShuttingDown)
        #expect(f.store.attemptedSessionWriteBatches.count == attempts)
        #expect(f.model.sessionPersistenceFailure == nil)

        let canceled = SessionRecoveryFixture()
        #expect(canceled.model.prepareSessionForClosure())
        canceled.model.setUserTitleOverride("Still editable", forTabID: canceled.id("a"))
        #expect(canceled.store.savedSnapshots.last?.tabs.first?.userTitleOverride == "Still editable")
        #expect(!canceled.model.isShuttingDown)
        canceled.store.sessionWriteError = SessionRecoveryTestError.unavailable
        #expect(!canceled.model.prepareSessionForClosure())
        #expect(canceled.model.hasUncommittedSessionWrites)
    }

    @Test func directTerminationFailurePreservesModelUntilExplicitRecovery() {
        let f = SessionRecoveryFixture()
        f.store.sessionWriteError = SessionRecoveryTestError.unavailable
        f.model.prepareForTermination()
        #expect(!f.model.isShuttingDown)
        #expect(f.model.hasUncommittedSessionWrites)
        #expect(f.driver.prepareForCefShutdownCount == 0)
        f.store.sessionWriteError = nil
        f.model.setUserTitleOverride("Still editable", forTabID: f.id("a"))
        #expect(f.store.savedSnapshots.last?.tabs.first?.userTitleOverride == "Still editable")
        #expect(f.model.prepareSessionForClosure())
        f.model.prepareForTermination()
        #expect(f.model.isShuttingDown)
    }

    @Test func cancelMultiwindowClosureKeepsEveryModelWritableWithoutTeardown() {
        let healthy = SessionRecoveryFixture()
        let failed = SessionRecoveryFixture()
        failed.store.sessionWriteError = SessionRecoveryTestError.unavailable
        failed.model.setUserTitleOverride("Pending", forTabID: failed.id("a"))
        let allowed = BrowserSessionClosureGuard.prepare(models: { [healthy.model, failed.model] }) { failures in
            #expect(failures.count == 1)
            #expect(failures.first === failed.model)
            return .cancel
        }
        #expect(!allowed)
        #expect(!healthy.model.isShuttingDown)
        #expect(!failed.model.isShuttingDown)
        #expect(healthy.driver.prepareForCefShutdownCount == 0)
        #expect(failed.driver.prepareForCefShutdownCount == 0)
        healthy.model.setUserTitleOverride("Healthy still editable", forTabID: healthy.id("a"))
        #expect(healthy.store.savedSnapshots.last?.tabs.first?.userTitleOverride == "Healthy still editable")
        failed.store.sessionWriteError = nil
        failed.model.setUserTitleOverride("Recovered still editable", forTabID: failed.id("a"))
        #expect(failed.store.savedSnapshots.last?.tabs.first?.userTitleOverride == "Recovered still editable")
        #expect(!failed.model.hasUncommittedSessionWrites)
    }

    @Test func retryMultiwindowClosureCommitsPendingPrefixBeforeAllowingTeardown() {
        let healthy = SessionRecoveryFixture()
        let failed = SessionRecoveryFixture()
        failed.store.sessionWriteError = SessionRecoveryTestError.unavailable
        failed.model.moveTab(withID: failed.id("a"), toPlacement: .spacePinned, atSectionIndex: 0)
        var confirmations = 0
        let allowed = BrowserSessionClosureGuard.prepare(models: { [healthy.model, failed.model] }) { failures in
            confirmations += 1
            #expect(failures.count == 1)
            failed.store.sessionWriteError = nil
            return .retry
        }
        #expect(allowed)
        #expect(confirmations == 1)
        #expect(!failed.model.hasUncommittedSessionWrites)
        #expect(failed.store.savedSyncMoves.last == .init(tabIDs: ["a"]))
        let healthyAttempts = healthy.store.attemptedSessionWriteBatches.count
        let failedAttempts = failed.store.attemptedSessionWriteBatches.count
        healthy.store.sessionWriteError = SessionRecoveryTestError.unavailable
        failed.store.sessionWriteError = SessionRecoveryTestError.unavailable
        healthy.model.prepareForTermination()
        failed.model.prepareForTermination()
        #expect(healthy.store.attemptedSessionWriteBatches.count == healthyAttempts)
        #expect(failed.store.attemptedSessionWriteBatches.count == failedAttempts)
    }

    @Test func discardRechecksModelsMutatedDuringConfirmationAndOnlyDisablesStillFailedProfiles() {
        let failed = SessionRecoveryFixture()
        let newlyFailed = SessionRecoveryFixture()
        let healthy = SessionRecoveryFixture()
        failed.store.sessionWriteError = SessionRecoveryTestError.unavailable
        failed.model.setUserTitleOverride("Earlier failure", forTabID: failed.id("a"))
        let allowed = BrowserSessionClosureGuard
            .prepare(models: { [failed.model, newlyFailed.model, healthy.model] }) { failures in
                #expect(failures.count == 1)
                newlyFailed.store.sessionWriteError = SessionRecoveryTestError.unavailable
                newlyFailed.model.setUserTitleOverride("Changed while modal", forTabID: newlyFailed.id("a"))
                return .discardUnsaved
            }
        #expect(allowed)
        #expect(!failed.model.retrySessionPersistence())
        #expect(!newlyFailed.model.retrySessionPersistence())
        #expect(failed.sync.blocked.last == true)
        #expect(newlyFailed.sync.blocked.last == true)
        #expect(failed.model.prepareSessionForClosure())
        #expect(newlyFailed.model.prepareSessionForClosure())
        healthy.model.setUserTitleOverride("Not discarded", forTabID: healthy.id("a"))
        #expect(healthy.store.savedSnapshots.last?.tabs.first?.userTitleOverride == "Not discarded")
        #expect(!healthy.model.isShuttingDown)
        #expect(failed.model.sessionRecoverySnapshot().tabs.first?.userTitleOverride == "Earlier failure")
        #expect(newlyFailed.model.sessionRecoverySnapshot().tabs.first?.userTitleOverride == "Changed while modal")
    }
}

// MARK: - SessionRecoveryTestError

private enum SessionRecoveryTestError: Error { case unavailable }

// MARK: - SessionRecoveryFixture

@MainActor private final class SessionRecoveryFixture {
    // MARK: Internal

    let driver = FakeBrowserTabDriver()
    let store: InMemorySessionSnapshotStore
    let preferences = InMemorySessionPreferencesStore()
    let sync = SessionRecoverySyncRecorder()
    let model: BrowserChromeModel

    init(snapshot: BrowserTabSessionSnapshot = recoverySnapshot(ids: ["a", "b"])) {
        self.store = InMemorySessionSnapshotStore(loadedSnapshot: snapshot)
        let defaults = UserDefaults(suiteName: BrowserTestDefaults.suiteName("SessionRecoveryFixture"))!
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: preferences,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: sync,
            windowTitleHandler: { _ in }, allTabsClosedHandler: {},
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
    }

    func id(_ syncID: String) -> String { model.tabs.first { $0.syncID == syncID }!.id }
}

// MARK: - SessionRecoverySyncRecorder

@MainActor private final class SessionRecoverySyncRecorder: BrowserSyncCoordinating {
    var pushes = [BrowserTabSessionSnapshot]()
    var pulls = 0
    var blocked = [Bool]()

    func schedulePush(snapshot: BrowserTabSessionSnapshot) { pushes.append(snapshot) }
    func schedulePull() { pulls += 1 }
    func setLocalPersistenceBlocked(_ blocked: Bool) { self.blocked.append(blocked) }
    func reset() { pushes.removeAll()
        pulls = 0
        blocked.removeAll()
    }
}

private func recoverySnapshot(ids: [String], title: String = "Space") -> BrowserTabSessionSnapshot {
    .init(spaces: [.init(id: "s", title: title, systemImageName: "circle")], tabs: ids.map {
        .init(id: $0, urlString: "https://\($0).example/", userTitleOverride: $0.uppercased(), spaceID: "s")
    })
}
