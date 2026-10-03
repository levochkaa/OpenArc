import Foundation
import GRDB
import Testing
import UIKit
import WebKit

// MARK: - BrowserMobileSyncHTTPIntegrationTests

@Suite(
    .serialized,
    .enabled(if: MobileHTTPFixture.isConfigured, "Run ./script/test_mobile_sync.sh for localhost integration")
)
@MainActor struct BrowserMobileSyncHTTPIntegrationTests {
    @Test func mobileV4RoundtripPreservesLoadedPageAndSharedFolderTree() async throws {
        let fixture = try await MobileHTTPFixture.load()
        let account = try fixture.account("mobile-v4-roundtrip")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try MobileHTTPProfile(
            fixture: fixture,
            device: account.devices[0],
            directory: directory,
            initial: mobileHTTPSeed(includeUnsupportedURL: true)
        )
        let second = try MobileHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        defer { first.cleanup()
            second.cleanup()
        }
        try await first.start()
        let unsupportedRuntime = try #require(first.workspace.tabs.first { $0.id == "unsupported" }?.runtimeID)
        #expect(first.engine.webView(for: unsupportedRuntime) == nil)
        #expect(first.workspace.tabs.first { $0.id == "unsupported" }?.state.error != nil)
        #expect(first.document.snapshot.tabs.first { $0.id == "unsupported" }?.urlString == "tb://settings")
        first.workspace.selectTab(id: "browsing")
        let page = BrowserMobilePageViewController(workspace: first.workspace, contentView: first.engine.hostView)
        first.workspace.onChange = { [weak page] in page?.render() }
        page.loadViewIfNeeded()
        let url = fixture.baseURL.appendingPathComponent("mobile-test-page")
        page.addressField.text = url.absoluteString
        #expect(page.textFieldShouldReturn(page.addressField))
        try #require(await mobileHTTPEventually {
            first.workspace.selectedTab?.title == "Mobile sync fixture"
                && first.workspace.selectedTab?.state.isLoading == false
        })
        let runtimeID = try #require(first.workspace.selectedTab?.runtimeID)
        let live = try #require(first.engine.webView(for: runtimeID))
        let secondURL = fixture.baseURL.appendingPathComponent("mobile-test-second")
        _ = try await live.evaluateJavaScript("document.getElementById('next').click()")
        try #require(await mobileHTTPEventually {
            first.workspace.selectedTab?.title == "Mobile sync second"
                && first.workspace.selectedTab?.state.isLoading == false
        })
        first.workspace.goBack()
        try #require(await mobileHTTPEventually {
            first.workspace.selectedTab?.title == "Mobile sync fixture"
                && first.workspace.selectedTab?.state.isLoading == false
        })
        first.workspace.goForward()
        try #require(await mobileHTTPEventually {
            first.workspace.selectedTab?.title == "Mobile sync second"
                && first.workspace.selectedTab?.state.isLoading == false
        })
        let history = live.backForwardList.backList.map(\.url)
        try #require(history.contains(url))
        try #require(first.document.renameTab(id: "browsing", title: "Shared named tab"))
        try #require(first.document.setTabPinned(id: "browsing", isPinned: true))
        let folder = try #require(first.document.createFolder(spaceID: "source", title: "Mobile folder"))
        let nested = try #require(first.document.createFolder(
            spaceID: "source",
            parentFolderID: folder,
            title: "Nested"
        ))
        try #require(first.document.setPlacement(tabID: "browsing", placement: .spacePinned, pinnedFolderID: nested))
        try #require(first.document.createFolder(spaceID: "source", title: "Empty") != nil)
        try #require(try first.store.pendingSyncQueue(for: first.owner).allSatisfy { $0.protocolVersion == 4 })
        try await first.drain()

        let otherSceneEngine = BrowserWebKitEngine(dataStore: .nonPersistent())
        let scenePreferencesName = "MobileHTTPSiblingScene." + UUID().uuidString
        let scenePreferences = try #require(UserDefaults(suiteName: scenePreferencesName))
        let sharedDocument = first.document
        let otherScene = BrowserMobileWorkspace(
            engine: otherSceneEngine, sceneID: "second-window", profileLoader: { sharedDocument },
            preferences: scenePreferences
        )
        defer {
            otherScene.setSyncActive(false)
            otherSceneEngine.shutdown()
            scenePreferences.removePersistentDomain(forName: scenePreferencesName)
        }
        await otherScene.restore()
        otherScene.setSyncActive(true)
        try #require(otherScene.profileDocument === first.document)
        otherScene.selectTab(id: "retained")
        #expect(otherScene.selectedTabID == "retained" && first.workspace.selectedTabID == "browsing")
        otherScene.selectTab(id: "browsing")
        try #require(await mobileHTTPEventually {
            otherScene.selectedTab?.title == "Mobile sync second" && otherScene.selectedTab?.state.isLoading == false
        })
        let otherRuntime = try #require(otherScene.selectedTab?.runtimeID)
        let otherLive = try #require(otherSceneEngine.webView(for: otherRuntime))
        #expect(otherRuntime != runtimeID && otherLive !== live)
        try await second.start()
        #expect(second.document.snapshot.tabs == first.document.snapshot.tabs)
        #expect(second.document.snapshot.pinnedTabFolders == first.document.snapshot.pinnedTabFolders)
        second.workspace.selectTab(id: "browsing")
        try #require(await mobileHTTPEventually {
            second.workspace.selectedTab?.title == "Mobile sync second"
                && second.workspace.selectedTab?.state.isLoading == false
        })
        let secondRuntime = try #require(second.workspace.selectedTab?.runtimeID)
        #expect(secondRuntime != runtimeID)
        #expect(second.engine.webView(for: secondRuntime) !== live)

        try #require(second.document.move(
            items: [.init(entityType: .folder, entityID: folder)],
            destination: .tabs(spaceID: "target", placement: .spacePinned, pinnedFolderID: nil)
        ))
        try #require(second.document.renameFolder(id: nested, title: "Renamed on second device"))
        try await second.drain()
        try await first.pull()
        first.workspace.selectTab(id: "browsing")
        #expect(first.workspace.selectedSpaceID == "target")
        #expect(first.workspace.selectedTab?.userTitleOverride == "Shared named tab")
        #expect(first.workspace.selectedTab?.runtimeID == runtimeID)
        #expect(first.engine.webView(for: runtimeID) === live)
        #expect(live.url == secondURL && live.backForwardList.backList.map(\.url) == history)
        #expect(otherSceneEngine.webView(for: otherRuntime) === otherLive)
        #expect(otherScene.tabs.first { $0.id == "browsing" }?.spaceID == "target")
        #expect(first.document.snapshot.tabs == second.document.snapshot.tabs)
        #expect(first.document.snapshot.pinnedTabFolders == second.document.snapshot.pinnedTabFolders)
        let server = try await fixture.inspect(account)
        #expect(server.tabs.first { $0.id == "browsing" }?.pinnedFolderID == nested)
        #expect(server.folders.first { $0.id == folder }?.spaceID == "target")
        #expect(server.folders.first { $0.id == nested }?.title == "Renamed on second device")

        try #require(second.document.delete(entity: .init(entityType: .folder, entityID: folder)))
        try await second.drain()
        try await first.pull()
        #expect(first.engine.webView(for: runtimeID) == nil)
        #expect(otherSceneEngine.webView(for: otherRuntime) == nil)
        #expect(second.engine.webView(for: secondRuntime) == nil)
        #expect(live.navigationDelegate == nil && otherLive.navigationDelegate == nil)
        #expect(Set(first.document.snapshot.tabs.compactMap(\.id)) == ["retained", "unsupported"])
        #expect(Set(otherScene.tabs.map(\.id)) == ["retained", "unsupported"])
        #expect(first.document.snapshot.pinnedTabFolders?.contains { $0.id == folder || $0.id == nested } == false)
        #expect(first.document.snapshot.tabs.first { $0.id == "unsupported" }?.urlString == "tb://settings")
        #expect(first.engine.webView(for: unsupportedRuntime) == nil)
        let afterDeletion = try await fixture.inspect(account)
        #expect(afterDeletion.tabs.first { $0.id == "browsing" }?.tombstoned == true)
        #expect(afterDeletion.tabs.first { $0.id == "unsupported" }?.deleted == false)
        let saved = first.document.snapshot
        try #require(await otherScene.shutdown())
        try await first.stop()
        let reopened = try MobileHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        defer { reopened.cleanup() }
        #expect(reopened.document.snapshot == saved)
        try await reopened.start()
        #expect(reopened.workspace.tabs.map(\.id) == saved.tabs.compactMap(\.id))
        #expect(reopened.document.snapshot.pinnedTabFolders == saved.pinnedTabFolders)
        try await reopened.stop()
        try await second.stop()
        try await fixture.complete(account)
    }

    @Test func mobileV4LostAcknowledgementReopensImmutableQueueAndDeletionDefeatsStaleEdits() async throws {
        let fixture = try await MobileHTTPFixture.load()
        let account = try fixture.account("mobile-v4-recovery")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try MobileHTTPProfile(
            fixture: fixture,
            device: account.devices[0],
            directory: directory,
            initial: mobileHTTPSeed()
        )
        let second = try MobileHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        defer { first.cleanup()
            second.cleanup()
        }
        try await first.start()
        try await second.start()
        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        try #require(first.document.renameTab(id: "browsing", title: String(repeating: "lost-mobile-ack-", count: 200)))
        let pending = try first.store.pendingSyncQueue(for: first.owner)
        try #require(pending.count == 1 && pending[0].protocolVersion == 4)
        let bytes = try first.outboxBytes()
        await first.service.waitForPendingOperations()
        #expect(first.runtime.lastSyncError != nil)
        #expect(try first.store.pendingSyncQueue(for: first.owner) == pending)
        #expect(try first.outboxBytes() == bytes)
        let committed = try await fixture.inspect(account)
        let original = try #require(committed.attempts.last { $0.mutationID == pending[0].id })
        try #require(original.status == 201 && original.protocolVersion == 4 && original.compressed)
        try await first.stop()

        try await second.pull()
        let folder = try #require(second.document.createFolder(spaceID: "target", title: "Remote destination"))
        try #require(second.document.renameTab(id: "browsing", title: "Newer remote title"))
        try #require(second.document.setPlacement(
            tabID: "browsing",
            placement: .spacePinned,
            spaceID: "target",
            pinnedFolderID: folder
        ))
        try await second.drain()
        let beforeReplay = try await fixture.inspect(account)
        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        let reopened = try MobileHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        defer { reopened.cleanup() }
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner) == pending)
        #expect(try reopened.outboxBytes() == bytes)
        try await reopened.start()
        try await second.pull()
        let afterReplay = try await fixture.inspect(account)
        let attempts = afterReplay.attempts.filter { $0.mutationID == original.mutationID }
        #expect(attempts.count > beforeReplay.attempts.filter { $0.mutationID == original.mutationID }.count)
        #expect(Set(attempts.map(\.digest)) == [original.digest])
        #expect(attempts.allSatisfy { $0.protocolVersion == 4 && $0.status == 201 })
        #expect(afterReplay.eventCount == beforeReplay.eventCount && afterReplay.receiptCount == beforeReplay
            .receiptCount)
        #expect(reopened.document
            .snapshot
            .tabs
            .first { $0.id == "browsing" }?
            .userTitleOverride == "Newer remote title")
        #expect(reopened.document.snapshot.tabs == second.document.snapshot.tabs)

        second.workspace.setSyncActive(false)
        try #require(second.document.renameTab(id: "browsing", title: "Stale offline rename"))
        try #require(second.document.setPlacement(tabID: "browsing", placement: .temporary, spaceID: "source"))
        let stale = try second.store.pendingSyncQueue(for: second.owner)
        try #require(stale.count == 2 && stale.allSatisfy { $0.protocolVersion == 4 })
        try #require(reopened.document.removeTab(id: "browsing"))
        try await reopened.drain()
        second.workspace.setSyncActive(true)
        try await second.drain()
        try await reopened.pull()
        let deleted = try await fixture.inspect(account)
        let tab = try #require(deleted.tabs.first { $0.id == "browsing" })
        #expect(tab.deleted && tab.tombstoned)
        #expect(!second.document.snapshot.tabs.contains { $0.id == "browsing" })
        #expect(!reopened.document.snapshot.tabs.contains { $0.id == "browsing" })
        #expect(second.document.snapshot.tabs.map(\.id) == ["retained"])
        #expect(stale.allSatisfy { mutation in
            deleted.attempts.contains { $0.mutationID == mutation.id && $0.status == 201 }
        })
        try await reopened.stop()
        try await second.stop()
        try await fixture.complete(account)
    }
}

// MARK: - MobileHTTPFixture

private struct MobileHTTPFixture: Decodable {
    // MARK: Internal

    struct Device: Decodable { let deviceID: String
        let userID: String
        let accessToken: String
    }

    struct Account: Decodable { let scenario: String
        let userID: String
        let devices: [Device]
    }

    struct Inspection: Decodable {
        struct Tab: Decodable {
            let id: String
            let pinnedFolderID: String?
            let deleted: Bool
            let tombstoned: Bool
        }

        struct Folder: Decodable { let id: String
            let spaceID: String
            let title: String
        }

        struct Attempt: Decodable {
            let mutationID: String
            let digest: String
            let compressed: Bool
            let protocolVersion: Int
            let status: Int
        }

        let eventCount: Int
        let receiptCount: Int
        let tabs: [Tab]
        let folders: [Folder]
        let attempts: [Attempt]
    }

    static var isConfigured: Bool { controlAddress != nil && controlCredential != nil }

    let baseURL: URL
    let controlURL: URL
    let controlToken: String
    let accounts: [Account]

    static func load() async throws -> Self {
        let address = try #require(controlAddress)
        let url = try #require(URL(string: address))
        let token = try #require(controlCredential)
        try #require(url.scheme == "http" && url.host == "127.0.0.1")
        let data = try await send(["action": "fixture"], to: url, token: token)
        let fixture = try JSONDecoder().decode(Self.self, from: data)
        try #require(fixture.baseURL.scheme == "http" && fixture.baseURL.host == "127.0.0.1")
        try #require(fixture.controlURL == url)
        return fixture
    }

    func account(_ scenario: String) throws -> Account {
        let account = try #require(accounts.first { $0.scenario == scenario })
        try #require(account.devices.count == 2)
        return account
    }

    func inspect(_ account: Account) async throws -> Inspection {
        try await JSONDecoder().decode(Inspection.self, from: Self.send(
            ["action": "inspect", "userID": account.userID], to: controlURL, token: controlToken
        ))
    }

    func command(_ action: String, deviceID: String) async throws {
        _ = try await Self.send(["action": action, "deviceID": deviceID], to: controlURL, token: controlToken)
    }

    func complete(_ account: Account) async throws {
        _ = try await Self.send(
            ["action": "complete", "scenario": account.scenario],
            to: controlURL,
            token: controlToken
        )
    }

    // MARK: Private

    private static var controlAddress: String? {
        ProcessInfo.processInfo.environment["THEBROWSER_MOBILE_SYNC_CONTROL_URL"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_THEBROWSER_MOBILE_SYNC_CONTROL_URL"]
    }

    private static var controlCredential: String? {
        ProcessInfo.processInfo.environment["THEBROWSER_MOBILE_SYNC_CONTROL_TOKEN"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_THEBROWSER_MOBILE_SYNC_CONTROL_TOKEN"]
    }

    private static func send(_ command: [String: String], to url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(command)
        let (data, response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        return data
    }
}

// MARK: - MobileHTTPProfile

@MainActor private final class MobileHTTPProfile {
    // MARK: Lifecycle

    init(
        fixture: MobileHTTPFixture,
        device: MobileHTTPFixture.Device,
        directory: URL,
        initial: BrowserTabSessionSnapshot? = nil
    ) throws {
        self.databaseURL = directory.appendingPathComponent(device.deviceID + ".sqlite")
        let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        self.store = store
        if try store.loadSnapshotStrict() == nil, let initial {
            try store.writeSessionBatch([.init(snapshot: initial, origin: .local(syncMove: nil))])
        }
        let document = try BrowserMobileProfileDocument(store: store, loadSnapshot: { try store.loadSnapshotStrict() })
        self.document = document
        self.owner = BrowserSyncOwner(baseURL: fixture.baseURL, userID: device.userID)
        self.preferencesName = "MobileHTTPProfile." + UUID().uuidString
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        self.session = session
        let credentials = BrowserAuthSession(
            accessToken: device.accessToken, userID: device.userID, userEmail: nil,
            deviceID: device.deviceID, serverURL: fixture.baseURL
        )
        self.runtime = BrowserMobileSyncSession(
            store: store, document: document, preferences: preferences,
            authSessionStore: MobileHTTPAuthStore(), identityProvider: MobileHTTPIdentity(),
            environment: ["THEBROWSER_SYNC_BASE_URL": fixture.baseURL.absoluteString], packagedServerURL: nil,
            clientFactory: { configuration in
                MobileHTTPRemote(
                    client: BrowserRemoteSyncClient(configuration: configuration, session: session),
                    credentials: credentials
                )
            },
            pushDebounce: .zero, pollInterval: nil, retryDelay: nil
        )
        self.workspace = BrowserMobileWorkspace(
            engine: engine,
            sceneID: "http-scene",
            profileLoader: { document },
            preferences: preferences
        )
    }

    // MARK: Internal

    let databaseURL: URL
    let store: BrowserSQLiteSessionStore
    let owner: BrowserSyncOwner
    let document: BrowserMobileProfileDocument
    let runtime: BrowserMobileSyncSession
    let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
    let workspace: BrowserMobileWorkspace

    var service: BrowserSyncService { runtime.syncService! }

    func start() async throws {
        await workspace.restore()
        try #require(workspace.isReady)
        workspace.setSyncActive(true)
        await runtime.account.signInWithApple()
        try #require(runtime.account.isAuthenticated)
        if runtime.account.bindingState == .needsConsent {
            runtime.enableSync()
        }
        try await drain()
        try #require(try store.syncPullProtocolVersion(for: owner) == 4)
    }

    func drain() async throws {
        await service.waitForPendingOperations()
        try #require(try store.pendingSyncQueue(for: owner).isEmpty)
        try #require(runtime.lastSyncError == nil)
    }

    func pull() async throws { runtime.retrySync()
        try await drain()
    }

    func stop() async throws {
        workspace.setSyncActive(false)
        await service.waitForPendingOperations()
        try #require(await workspace.shutdown())
        session.invalidateAndCancel()
    }

    func outboxBytes() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
        }
    }

    func cleanup() {
        workspace.setSyncActive(false)
        engine.shutdown()
        session.invalidateAndCancel()
        preferences.removePersistentDomain(forName: preferencesName)
    }

    // MARK: Private

    private let session: URLSession
    private let preferences: UserDefaults
    private let preferencesName: String
}

// MARK: - MobileHTTPAuthStore

@MainActor private final class MobileHTTPAuthStore: BrowserSyncAuthSessionStoring {
    // MARK: Internal

    func loadSession() -> BrowserAuthSession? { session }
    func saveSession(_ session: BrowserAuthSession) { self.session = session }
    func clearSession() { session = nil }

    // MARK: Private

    private var session: BrowserAuthSession?
}

// MARK: - MobileHTTPIdentity

@MainActor private final class MobileHTTPIdentity: BrowserAppleIdentityProviding {
    func requestIdentityToken() -> String { "fixture-identity" }
}

// MARK: - MobileHTTPRemote

/// Apple authentication alone uses pre-provisioned localhost fixture credentials.
/// Every push/pull uses the production URLSession/OpenAPI transport and backend.
@MainActor private final class MobileHTTPRemote: BrowserMobileSyncRemoteServing {
    // MARK: Lifecycle

    init(client: BrowserRemoteSyncClient, credentials: BrowserAuthSession) { self.client = client
        self.credentials = credentials
    }

    // MARK: Internal

    let client: BrowserRemoteSyncClient
    let credentials: BrowserAuthSession

    var baseURL: URL { client.baseURL }

    func authenticateWithApple(
        identityToken _: String,
        deviceName _: String,
        devicePlatform _: String
    ) -> BrowserAuthSession { credentials }
    func pull(cursor: Int, authSession: BrowserAuthSession) async throws -> BrowserSyncPullResponse {
        try await client.pull(cursor: cursor, authSession: authSession)
    }

    func pull(
        cursor: Int,
        protocolVersion: Int,
        authSession: BrowserAuthSession
    ) async throws -> BrowserSyncPullResponse {
        try await client.pull(cursor: cursor, protocolVersion: protocolVersion, authSession: authSession)
    }

    func push(mutation: BrowserSyncMutation, authSession: BrowserAuthSession) async throws -> BrowserSyncPushResponse {
        try await client.push(mutation: mutation, authSession: authSession)
    }

    func push(
        mutation: BrowserSyncSemanticMutation,
        authSession: BrowserAuthSession
    ) async throws -> BrowserSyncSemanticPushResponse {
        try await client.push(mutation: mutation, authSession: authSession)
    }

    func push(
        mutation: BrowserSyncFolderMutation,
        authSession: BrowserAuthSession
    ) async throws -> BrowserSyncFolderPushResponse {
        try await client.push(mutation: mutation, authSession: authSession)
    }
}

private func mobileHTTPSeed(includeUnsupportedURL: Bool = false) -> BrowserTabSessionSnapshot {
    var tabs: [BrowserTabSessionSnapshotTab] = [
        .init(id: "browsing", urlString: "about:blank", spaceID: "source"),
        .init(id: "retained", urlString: "about:blank", spaceID: "source"),
    ]
    if includeUnsupportedURL {
        tabs.append(.init(id: "unsupported", urlString: "tb://settings", spaceID: "source"))
    }
    return .init(spaces: [
        .init(id: "source", title: "Source", systemImageName: "globe"),
        .init(id: "target", title: "Target", systemImageName: "folder"),
    ], tabs: tabs)
}

@MainActor private func mobileHTTPEventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
