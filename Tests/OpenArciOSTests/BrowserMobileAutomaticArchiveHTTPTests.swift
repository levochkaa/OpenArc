// BrowserMobileAutomaticArchiveHTTPTests.swift

import Foundation
import Testing
import WebKit

extension BrowserMobileSyncHTTPIntegrationTests {
    @Test func mobileSchedulerWaitsForHydrationAndRestoresAcceptedExpiryAsAMobileTab() async throws {
        let fixture = try await MobileHTTPFixture.load()
        let account = try fixture.account("mobile-v5-automatic-archive")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = MobileAutomaticHTTPState()
        let initialActivity = state.now.timeIntervalSince1970 - 2 * 86400
        let pageURL = fixture.baseURL.appendingPathComponent("mobile-test-page")
        let first = try MobileHTTPProfile(
            fixture: fixture, device: account.devices[0], directory: directory,
            initial: mobileAutomaticHTTPSeed(
                pageURL: pageURL, activity: initialActivity, recent: state.now.timeIntervalSince1970,
            ),
            dateProvider: { state.now },
            pollInterval: .milliseconds(100), expirySweepInterval: 0.2, expiryActivityRefreshInterval: 300,
            automaticArchivalCheckInterval: nil,
        )
        let second = try MobileHTTPProfile(
            fixture: fixture, device: account.devices[1], directory: directory, dateProvider: { state.now },
            automaticArchivalCheckInterval: nil,
        )
        defer { first.cleanup()
            second.cleanup()
        }
        first.workspace.setExpiryHydrationCheck { state.hydrationReady }
        first.workspace.setSceneAttached(true)
        try await first.start(expectedPullProtocolVersion: 7)
        first.workspace.setActivityActive(true)
        // The window shows its own tab, which the sweep never takes.
        first.workspace.submit(pageURL.absoluteString)
        try #require(await mobileHTTPEventually {
            first.workspace.selectedTab?.title == "Mobile sync fixture"
                && first.workspace.selectedTab?.state.isLoading == false
        })
        let windowTabID = try #require(first.workspace.selectedTabID)
        let selectedRuntime = try #require(first.workspace.selectedTab?.runtimeID)
        let selectedWebView = try #require(first.engine.webView(for: selectedRuntime))
        try #require(first.document.renameTab(id: "fresh", title: "Kept fresh"))
        first.document.flushMobileTabSync()
        try await first.pull()
        #expect(first.document.protectedTabIDs.isEmpty, "Phones hold no Space tab back from the Archive")

        try await second.start(expectedPullProtocolVersion: 7)
        try await second.drain()
        let configuration = try #require(BrowserSyncConfiguration(baseURL: fixture.baseURL))
        let transportSession = URLSession(configuration: .ephemeral)
        defer { transportSession.invalidateAndCancel() }
        let remote = BrowserRemoteSyncClient(configuration: configuration, session: transportSession)
        let credentials = BrowserAuthSession(
            accessToken: account.devices[0].accessToken, userID: account.userID, userEmail: nil,
            deviceID: account.devices[0].deviceID, serverURL: fixture.baseURL,
        )
        let initial = try await remote.pull(cursor: 0, protocolVersion: 5, authSession: credentials)
        let expiredSource = try #require(initial.events.last { $0.entityID == "expired" && $0.op == "upsert" })

        // The backend receives another device's activity before that device
        // receives its ACK. A fresh scheduler pull must honor canonical activity.
        try await fixture.command("hold", deviceID: account.devices[1].deviceID)
        try #require(second.document.recordActivity(tabIDs: ["recently-used"]))
        let activityQueue = try second.store.pendingSyncQueue(for: second.owner)
        try #require(activityQueue.count == 1 && activityQueue[0].protocolVersion == 4)
        let activityID = activityQueue[0].id
        let activityBytes = try second.outboxBytes()
        try await mobileAutomaticHTTPWaitForCommitted(fixture, account: account, mutationID: activityID)
        #expect(try second.store.pendingSyncQueue(for: second.owner) == activityQueue)
        #expect(try second.outboxBytes() == activityBytes)
        #expect(!first.document.automaticTabArchivalEnabled)
        try #require(first.document.setAutomaticTabArchival(lifetime: .twelveHours))
        try await first.drain()
        let unhydrated = try await fixture.inspect(account)
        #expect(
            !unhydrated.attempts.contains { $0.protocolVersion == 5 },
            "Incomplete scene hydration must block scheduled destructive intent",
        )
        #expect(Set(first.document.snapshot.tabs.compactMap(\.id)) == mobileAutomaticHTTPOriginalIDs)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        #expect(first.document.snapshot.tabs.first { $0.id == "recently-used" }?.lastActivityTimestamp == state.now
            .timeIntervalSince1970)

        // No manual expiry enqueue or sweep request follows this change. The
        // real polling loop retries the previously blocked scheduling pass.
        state.hydrationReady = true
        state.now = state.now.addingTimeInterval(1)
        try #require(await mobileHTTPEventually {
            !first.document.snapshot.tabs.contains { $0.id == "expired" }
                && (try? first.store.loadArchivePage().entries.count) == 1
        })
        try #require(first.document.setAutomaticTabArchival(lifetime: nil))
        try await first.drain()
        let accepted = try await fixture.inspect(account)
        let expiryAttempt = try #require(accepted.attempts.first { $0.protocolVersion == 5 && $0.status == 201 })
        #expect(Set(first.document.snapshot.tabs.compactMap(\.id)) == mobileAutomaticHTTPOriginalIDs
            .subtracting(["expired"]))
        #expect(accepted.tabs.filter(\.deleted).map(\.id) == ["expired"])
        #expect(accepted.tabs.first { $0.id == "expired" }?.tombstoned == true)
        #expect(first.workspace.selectedTabID == windowTabID && first.workspace.selectedTab?
            .runtimeID == selectedRuntime)
        #expect(first.engine.webView(for: selectedRuntime) === selectedWebView)
        let archived = try #require(try first.store.loadArchivePage().entries.first)
        #expect(archived.tab.id == "expired" && archived.tab.userTitleOverride == "Expired tab")
        #expect(archived.tab.urlString == pageURL.absoluteString && archived.tab
            .lastActivityTimestamp == initialActivity)

        try await fixture.command("release", deviceID: account.devices[1].deviceID)
        try await second.drain()
        try await second.pull()
        #expect(!second.document.snapshot.tabs.contains { $0.id == "expired" })
        #expect(try second.store.loadArchivePage().entries.first?.id == archived.id)
        #expect(second.document.snapshot.tabs.first { $0.id == "recently-used" }?.lastActivityTimestamp == state.now
            .addingTimeInterval(-1)
            .timeIntervalSince1970)
        // On a phone the archived Space tab comes back as a mobile tab, which
        // the other phone receives over v7.
        let restoredID = try #require(first.workspace.restoreArchivedTab(id: archived.id))
        #expect(restoredID != "expired" && first.document.mobileTab(id: restoredID) != nil)
        first.document.flushMobileTabSync()
        try await first.pull()
        try await second.pull()
        #expect(second.document.mobileTab(id: restoredID)?.record.urlString == pageURL.absoluteString)
        for document in [first.document, second.document] {
            #expect(!document.snapshot.tabs.contains { $0.id == "expired" || $0.id == restoredID })
        }
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        #expect(first.workspace.restoreArchivedTab(id: archived.id) == nil)

        // Replay the scheduler's actual request identity through the production
        // typed transport. Its original tombstone cannot consume anything new.
        let scheduled = BrowserSyncExpiryMutation(id: expiryAttempt.mutationID, operations: [.init(
            id: "expired", expectedServerSeq: expiredSource.serverSeq, inactiveForSeconds: 43200,
        )])
        let beforeReplay = try await fixture.inspect(account)
        let receipt = try await remote.push(mutation: scheduled, authSession: credentials)
        let replay = try await remote.push(mutation: scheduled, authSession: credentials)
        #expect(receipt == replay)
        #expect(receipt.outcomes == [.init(operationIndex: 0, status: .applied, reason: nil)])
        try await first.pull()
        try await second.pull()
        let afterReplay = try await fixture.inspect(account)
        #expect(afterReplay.eventCount == beforeReplay.eventCount && afterReplay.receiptCount == beforeReplay
            .receiptCount)
        #expect(afterReplay.tabs.first { $0.id == "expired" }?.tombstoned == true)
        #expect(second.document.mobileTab(id: restoredID) != nil)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        try await first.stop()
        try await second.stop()
        let reopened = try MobileHTTPProfile(
            fixture: fixture, device: account.devices[0], directory: directory, dateProvider: { state.now },
            automaticArchivalCheckInterval: nil,
        )
        defer { reopened.cleanup() }
        #expect(!reopened.document.automaticTabArchivalEnabled)
        #expect(reopened.document.temporaryTabLifetime == .twelveHours)
        try await reopened.start(expectedPullProtocolVersion: 7)
        #expect(reopened.document.mobileTab(id: restoredID) != nil)
        #expect(!reopened.document.snapshot.tabs.contains { $0.id == "expired" })
        #expect(try reopened.store.loadArchivePage().entries.isEmpty)
        try await fixture.complete(account)
    }
}

private let mobileAutomaticHTTPOriginalIDs: Set = ["fresh", "recently-used", "expired"]

// MARK: - MobileAutomaticHTTPState

@MainActor private final class MobileAutomaticHTTPState {
    var now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    var hydrationReady = false
}

private func mobileAutomaticHTTPSeed(
    pageURL: URL, activity: TimeInterval, recent: TimeInterval,
) -> BrowserTabSessionSnapshot {
    .init(spaces: [.init(id: "source", title: "Automatic Archive", systemImageName: "globe")], tabs: [
        .init(id: "fresh", urlString: "about:blank", spaceID: "source", lastActivityTimestamp: recent),
        .init(id: "recently-used", urlString: "about:blank", spaceID: "source", lastActivityTimestamp: activity),
        .init(
            id: "expired",
            urlString: pageURL.absoluteString,
            userTitleOverride: "Expired tab",
            spaceID: "source",
            lastActivityTimestamp: activity,
        ),
    ])
}

@MainActor private func mobileAutomaticHTTPWaitForCommitted(
    _ fixture: MobileHTTPFixture, account: MobileHTTPFixture.Account, mutationID: String,
) async throws {
    for _ in 0..<100 {
        if try await fixture.inspect(account)
            .attempts
            .contains(where: { $0.mutationID == mutationID && $0.status == 201 })
        {
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("The held activity request did not reach the production server")
    throw MobileAutomaticHTTPError.activityNotCommitted
}

// MARK: - MobileAutomaticHTTPError

private enum MobileAutomaticHTTPError: Error { case activityNotCommitted }
