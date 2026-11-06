// BrowserDesktopAutomaticArchiveHTTPTests.swift

import Foundation
import GRDB
import Testing

extension BrowserSyncHTTPIntegrationTests {
    @Test func desktopSettingSchedulesExpiryAndAttemptedRequestSurvivesOffAndRestart() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("desktop-auto-archive")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let remote = try BrowserRemoteSyncClient(
            configuration: #require(BrowserSyncConfiguration(baseURL: fixture.baseURL)), session: session,
        )
        let auth = account.devices.map { device in
            BrowserAuthSession(
                accessToken: device.accessToken, userID: device.userID, userEmail: nil,
                deviceID: device.deviceID, serverURL: fixture.baseURL,
            )
        }
        let seed = BrowserSyncFolderMutation(id: UUID().uuidString, operations: [
            .createSpace(id: "source", data: .init(title: "Desktop automatic Archive", systemImageName: "globe")),
            .createTab(id: "pinned", data: .init(
                spaceID: "source", placement: .spacePinned, urlString: "https://desktop-auto.example/pinned",
                pinnedURLString: "https://desktop-auto.example/home", lastActivityAt: "2000-01-01T00:00:00Z",
            )),
            .createTab(id: "selected", data: .init(
                spaceID: "source", placement: .temporary, urlString: "https://desktop-auto.example/selected",
                lastActivityAt: "2000-01-01T00:00:00Z",
            )),
            .createTab(id: "expired", data: .init(
                spaceID: "source", placement: .temporary, urlString: "https://desktop-auto.example/expired",
                title: "Old page", userTitleOverride: "Retained title", lastActivityAt: "2000-01-01T00:00:00Z",
            )),
        ])
        _ = try await remote.push(mutation: seed, authSession: auth[0])
        await first.activate()
        await second.activate()
        let live = try DesktopAutomaticHTTPModel(profile: first, now: now)
        defer { live.close() }
        let selected = try #require(live.model.tabs.first { $0.syncID == "selected" })
        let pinned = try #require(live.model.tabs.first { $0.syncID == "pinned" })
        let expired = try #require(live.model.tabs.first { $0.syncID == "expired" })
        live.model.selectTab(id: selected.id)
        live.driver.emitTabCreationState(id: selected.id, state: .ready)
        live.driver.emitTabCreationState(id: pinned.id, state: .ready)
        live.driver.emitNavigationStateChange(id: selected.id, canGoBack: true, canGoForward: false)
        await first.service.waitForPendingOperations()
        #expect(!live.model.automaticTabArchivalEnabled)

        // The native timing action uses this model API. An unresolved engine
        // allocation blocks the real scheduler even though the preference is On.
        try #require(live.model.setAutomaticTabArchival(lifetime: .twelveHours))
        await first.service.waitForPendingOperations()
        #expect(live.model.expirySchedulingState() == nil)
        let unready = try await fixture.inspect(account)
        #expect(!unready.attempts.contains { $0.protocolVersion == 5 })
        #expect(Set(live.model.tabs.map(\.syncID)) == ["pinned", "selected", "expired"])
        try #require(live.model.setAutomaticTabArchival(lifetime: nil))
        await first.service.waitForPendingOperations()
        live.driver.emitTabCreationState(id: expired.id, state: .ready)
        await first.pull()
        #expect(live.model.expirySchedulingState()?.protectedTabIDs == ["selected"])
        #expect(live.model.expirySchedulingState()?.inactiveForSeconds == nil)
        let refreshed = try #require(first.store.loadSnapshot())
        #expect(refreshed.tabs.first { $0.id == "selected" }?.lastActivityTimestamp == now.timeIntervalSince1970)
        #expect(refreshed.tabs.first { $0.id == "expired" }?.lastActivityTimestamp == 946_684_800)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        let databaseURL = directory.appendingPathComponent(account.devices[0].deviceID + ".sqlite")

        // Hold only after the production server has committed. There is no
        // direct expiry enqueue in this test: changing the model setting drives
        // the completed-pull -> candidate scan -> durable automatic queue path.
        try await fixture.command("hold", deviceID: account.devices[0].deviceID)
        let attempted: BrowserSyncExpiryMutation
        let frozen: [Data]
        let accepted: SyncHTTPFixture.Inspection
        do {
            try #require(live.model.setAutomaticTabArchival(lifetime: .twelveHours))
            try await fixture.waitForHeldAcknowledgement(account, deviceID: account.devices[0].deviceID)
            let queued = try first.store.pendingSyncQueue(for: first.owner)
            try #require(queued.count == 1)
            guard case .expiry(let mutation) = queued[0] else {
                Issue.record("Ready desktop scheduling must enqueue a conditional v5 mutation")
                throw DesktopAutomaticHTTPError.expectedAutomaticExpiry
            }
            attempted = mutation
            #expect(attempted.operations.map(\.entityID) == ["expired"])
            #expect(attempted.operations.first?.inactiveForSeconds == 43200)
            #expect(try !first.store.automaticExpiryNeedsValidation(id: attempted.id, for: first.owner))
            frozen = try desktopAutomaticHTTPOutbox(databaseURL)
            accepted = try await fixture.inspect(account)
            #expect(accepted.attempts.last?.protocolVersion == 5 && accepted.attempts.last?.status == 201)
            #expect(accepted.tabs.first { $0.id == "expired" }?.tombstoned == true)
            #expect(accepted.tabs.first { $0.id == "selected" }?.deleted == false)
            #expect(Set(live.model.tabs.map(\.syncID)) == ["pinned", "selected", "expired"])
            #expect(
                try first.store.loadArchivePage().entries.isEmpty,
                "No optimistic deletion or Archive before receipt",
            )
            #expect(live.model.selectedTabID == selected.id && live.model.canGoBack)
            #expect(live.driver.createdTabRequests.count == 3 && live.driver.closedTabRequests.isEmpty)

            try #require(live.model.setAutomaticTabArchival(lifetime: nil))
            #expect(!live.model.automaticTabArchivalEnabled)
            #expect(try first.store.pendingSyncQueue(for: first.owner) == queued)
            #expect(try desktopAutomaticHTTPOutbox(databaseURL) == frozen)
            // Cancel transport after commit while its ACK is held. Off cannot
            // discard this possibly committed immutable request during restart.
            await first.disconnect()
            live.close()
        } catch {
            try? await fixture.command("release", deviceID: account.devices[0].deviceID)
            await first.disconnect()
            throw error
        }
        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        let reopened = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner) == [.expiry(attempted)])
        #expect(try desktopAutomaticHTTPOutbox(databaseURL) == frozen)
        let restoredModel = try DesktopAutomaticHTTPModel(profile: reopened, now: now)
        defer { restoredModel.close() }
        for tab in restoredModel.model.tabs {
            restoredModel.driver.emitTabCreationState(id: tab.id, state: .ready)
        }
        #expect(!restoredModel.model.automaticTabArchivalEnabled)
        #expect(restoredModel.model.temporaryTabLifetime == .twelveHours)
        let selectedAfterRestart = try #require(restoredModel.model.tabs.first { $0.syncID == "selected" })
        #expect(restoredModel.model.selectedTabID == selectedAfterRestart.id)
        restoredModel.driver.emitNavigationStateChange(id: selectedAfterRestart.id, canGoBack: true, canGoForward: true)
        await reopened.activate()
        await second.pull()
        let afterRetry = try await fixture.inspect(account)
        let attempts = afterRetry.attempts.filter { $0.mutationID == attempted.id }
        #expect(attempts.count >= 2 && Set(attempts.map(\.digest)).count == 1)
        #expect(attempts.allSatisfy { $0.protocolVersion == 5 && $0.status == 201 })
        #expect(afterRetry.eventCount == accepted.eventCount && afterRetry.receiptCount == accepted.receiptCount)
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner).isEmpty)
        #expect(restoredModel.model.tabs.map(\.syncID) == ["pinned", "selected"])
        #expect(restoredModel.model.selectedTabID == selectedAfterRestart.id)
        #expect(restoredModel.model.canGoBack && restoredModel.model.canGoForward)
        let archive = try #require(try reopened.store.loadArchivePage().entries.first)
        #expect(archive.tab.id == "expired" && archive.tab.userTitleOverride == "Retained title")
        #expect(try second.store.loadArchivePage().entries == [archive])

        let freshID = try #require(restoredModel.model.restoreArchivedTab(id: archive.id))
        #expect(freshID != "expired")
        restoredModel.driver.flushPendingCreateEvents()
        await reopened.service.waitForPendingOperations()
        await second.pull()
        for profile in [reopened, second] {
            #expect(profile.store.loadSnapshot()?.tabs.first { $0.id == freshID }?.urlString == archive.tab.urlString)
            #expect(profile.store
                .loadSnapshot()?
                .tabs
                .first { $0.id == freshID }?
                .userTitleOverride == "Retained title")
            #expect(profile.store.loadSnapshot()?.tabs.contains { $0.id == "expired" } == false)
        }
        #expect(restoredModel.model.tabs.first { $0.syncID == "selected" }?.id == selectedAfterRestart.id)
        #expect(restoredModel.model.tabs.first { $0.syncID == "selected" }?.canGoBack == true)
        #expect(try reopened.store.loadArchivePage().entries.isEmpty)
        #expect(restoredModel.model.restoreArchivedTab(id: archive.id) == nil)
        let beforeReplay = try await fixture.inspect(account)
        let receipt = try await remote.push(mutation: attempted, authSession: auth[0])
        let replay = try await remote.push(mutation: attempted, authSession: auth[1])
        #expect(receipt == replay && receipt.outcomes == [.init(operationIndex: 0, status: .applied, reason: nil)])
        await reopened.pull()
        await second.pull()
        let final = try await fixture.inspect(account)
        #expect(final.eventCount == beforeReplay.eventCount && final.receiptCount == beforeReplay.receiptCount)
        #expect(final.tabs.first { $0.id == "expired" }?.tombstoned == true)
        #expect(Set(final.tabs.filter { !$0.deleted }.map(\.id)) == ["pinned", "selected", freshID])
        #expect(Set(final.attempts.filter { $0.protocolVersion == 5 }.map(\.mutationID)) == [attempted.id])
        await reopened.disconnect()
        await second.disconnect()
        restoredModel.close()
        let finalStore = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(try !finalStore.loadAutomaticTabArchivalSettings().enabled)
        #expect(try finalStore.loadArchivePage().entries.isEmpty)
        #expect(finalStore.loadSnapshot()?.tabs.count(where: { $0.id == freshID }) == 1)
        #expect(finalStore.loadSnapshot()?.tabs.contains { $0.id == "expired" } == false)
        try await fixture.complete(account)
    }
}

// MARK: - DesktopAutomaticHTTPModel

@MainActor private final class DesktopAutomaticHTTPModel {
    // MARK: Internal

    let model: BrowserChromeModel
    let driver = FakeBrowserTabDriver()

    // MARK: Private

    private let profile: SyncHTTPProfile
    private let defaults: UserDefaults
    private let suite = BrowserTestDefaults.suiteName("DesktopAutomaticHTTPModel")
    private var closed = false

    init(profile: SyncHTTPProfile, now: Date) throws {
        self.profile = profile
        self.defaults = try #require(UserDefaults(suiteName: suite))
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: profile.store, sessionPreferencesStore: profile.store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: profile.service,
            dateProvider: { now }, windowTitleHandler: { _ in }, allTabsClosedHandler: {},
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        profile.service.setSnapshotApplier(model)
    }

    func close() {
        guard !closed else { return }
        closed = true
        profile.service.setSnapshotApplier(nil)
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor private func desktopAutomaticHTTPOutbox(_ url: URL) throws -> [Data] {
    try DatabaseQueue(path: url.path).read {
        try Data.fetchAll($0, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
    }
}

// MARK: - DesktopAutomaticHTTPError

private enum DesktopAutomaticHTTPError: Error {
    case expectedAutomaticExpiry
}
