import BrowserMobileTestHost
import Foundation
import Testing
import UIKit

// MARK: - BrowserMobileSyncSessionTests

@MainActor @Suite(.serialized) struct BrowserMobileSyncSessionTests {
    @Test func cachedCredentialsWaitForForegroundAndTwoScenesShareOneTransport() async throws {
        let f = try MobileSyncRuntimeFixture(cached: true, bound: true)
        defer { f.cleanup() }
        #expect(f.document.syncSession === f.runtime)
        #expect(f.runtime.account.isAuthenticated)
        await f.drain()
        #expect(f.remote.pulls.isEmpty && f.remote.pushes.isEmpty)
        f.runtime.setSceneActive(true, sceneID: "one")
        await f.drain()
        #expect(!f.remote.pulls.isEmpty)
        #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
        f.runtime.setSceneActive(true, sceneID: "two")
        f.runtime.setSceneActive(false, sceneID: "one")
        #expect(f.runtime.isForeground)
        let before = f.remote.pushes.count
        #expect(f.document.renameTab(id: "tab", title: "Other scene stays active"))
        await f.drain()
        #expect(f.remote.pushes.count == before + 1)
        f.runtime.setSceneActive(false, sceneID: "two")
        let pulls = f.remote.pulls.count, pushes = f.remote.pushes.count
        let credentials = f.auth.session
        #expect(f.document.renameTab(id: "tab", title: "Background edit"))
        await f.drain()
        #expect(!f.runtime.isForeground)
        #expect(f.remote.pulls.count == pulls && f.remote.pushes.count == pushes)
        #expect(f.auth.session == credentials)
        #expect(try !f.store.isSyncPaused(for: f.owner))
        #expect(try f.store.pendingSyncQueue(for: f.owner).count == 1)
        f.runtime.setSceneActive(true, sceneID: "one")
        await f.drain()
        #expect(f.remote.pulls.count > pulls && f.remote.pushes.count == pushes + 1)
        #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
        #expect(f.document.snapshot.tabs.first?.userTitleOverride == "Background edit")
    }

    @Test func explicitConfigurationValidatesOriginAndKeepsDurableOwner() throws {
        for raw in [
            "https://sync.example.com",
            " HTTPS://SYNC.EXAMPLE.COM/ ",
            "http://localhost:1234",
            "http://127.0.0.1:1234",
            "http://[::1]:1234",
        ] {
            #expect(BrowserMobileSyncSession.configuration(raw) != nil)
        }
        for raw in [
            "",
            "http://sync.example.com",
            "ftp://sync.example.com",
            "https://user:secret@sync.example.com",
            "https://sync.example.com/path",
            "https://sync.example.com?query=1",
            "https://sync.example.com#fragment",
        ] {
            #expect(BrowserMobileSyncSession.configuration(raw) == nil)
        }
        let f = try MobileSyncRuntimeFixture(bound: true, configured: false)
        defer { f.cleanup() }
        #expect(!f.runtime.account.isConfigured && f.runtime.serverURL == nil)
        #expect(throws: BrowserSyncAccountError.self) { try f.runtime.configureServer("https://different.example.com") }
        #expect(f.runtime.serverURL == nil)
        #expect(try f.store.syncOwner() == f.owner)
        try f.runtime.configureServer(f.remote.baseURL.absoluteString)
        #expect(f.runtime.account.isConfigured)
        #expect(f.runtime.serverURL == f.remote.baseURL)
        #expect(f.remote.pulls.isEmpty && f.remote.pushes.isEmpty)
    }

    @Test func runtimeSignInRequiresConsentThenPauseResumeAndSignOutKeepLocalData() async throws {
        let f = try MobileSyncRuntimeFixture()
        defer { f.cleanup() }
        let host = try MobileSyncRuntimeWindow()
        defer { host.close() }
        f.runtime.setSceneActive(true, sceneID: "active")
        await f.runtime.signIn(from: host.window)
        await f.drain()
        #expect(f.runtime.account.isAuthenticated)
        #expect(f.runtime.account.bindingState == .needsConsent)
        #expect(try f.store.syncOwner() == nil)
        #expect(f.remote.pulls.isEmpty && f.remote.pushes.isEmpty)
        #expect(f.remote.identityTokens == ["test-only-identity"])
        #expect(f.remote.identities.first?.platform == (UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"))
        #expect(throws: BrowserMobileSyncConfigurationError.self) {
            try f.runtime.configureServer("https://different.example.com")
        }
        f.runtime.enableSync()
        await f.drain()
        #expect(f.runtime.account.bindingState == .enabled)
        #expect(try f.store.syncOwner() == f.owner)
        #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
        f.runtime.pauseSync()
        #expect(f.runtime.account.bindingState == .paused)
        #expect(try f.store.isSyncPaused(for: f.owner))
        let pushes = f.remote.pushes.count
        #expect(f.document.renameTab(id: "tab", title: "Paused edit"))
        await f.drain()
        #expect(f.remote.pushes.count == pushes)
        #expect(try f.store.pendingSyncQueue(for: f.owner).count == 1)
        f.runtime.resumeSync()
        await f.drain()
        #expect(f.remote.pushes.count == pushes + 1)
        #expect(f.runtime.account.bindingState == .enabled)
        let snapshot = f.document.snapshot
        f.runtime.signOut()
        #expect(!f.runtime.account.isAuthenticated && f.auth.session == nil)
        #expect(try f.store.isSyncPaused(for: f.owner))
        #expect(f.document.snapshot == snapshot)
        #expect(try f.store.loadSnapshotStrict() == snapshot)
    }

    @Test func runtimeReportsAndRetriesTransportErrorWithoutDroppingLocalQueue() async throws {
        let f = try MobileSyncRuntimeFixture(cached: true, bound: true)
        defer { f.cleanup() }
        f.remote.pullFails = true
        f.runtime.setSceneActive(true, sceneID: "active")
        await f.drain()
        #expect(f.runtime.lastSyncError != nil)
        let queue = try f.store.pendingSyncQueue(for: f.owner)
        try #require(!queue.isEmpty)
        f.runtime.retrySync()
        await f.drain()
        #expect(f.runtime.lastSyncError != nil)
        #expect(try f.store.pendingSyncQueue(for: f.owner) == queue)
        f.remote.pullFails = false
        f.runtime.retrySync()
        await f.drain()
        #expect(f.runtime.lastSyncError == nil)
        #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
        #expect(f.document.snapshot.tabs.contains { $0.id == "tab" })
    }

    @Test func callerSceneCancelsHeldHTTPDespiteAnotherActiveSceneAndOldCompletionKeepsNewLease() async throws {
        let f = try MobileSyncRuntimeFixture()
        defer { f.cleanup() }
        let host = try MobileSyncRuntimeWindow()
        defer { host.close() }
        let scene = try #require(host.window.windowScene)
        f.runtime.setSceneActive(true, sceneID: scene.session.persistentIdentifier)
        f.runtime.setSceneActive(true, sceneID: "other-scene")
        let firstGate = MobileSyncRuntimeGate(), secondGate = MobileSyncRuntimeGate()
        f.remote.authenticationGates = [firstGate, secondGate]
        let first = Task { await f.runtime.signIn(from: host.window) }
        await f.remote.waitForAuthentication(count: 1)
        #expect(f.runtime.account.isSigningIn)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        f.runtime.setSceneActive(false, sceneID: scene.session.persistentIdentifier)
        #expect(f.runtime.isForeground && !f.runtime.account.isSigningIn)
        #expect(f.auth.session == nil)
        // The test notification does not change UIKit's real scene state. A
        // second request models that same caller after becoming active again.
        f.runtime.setSceneActive(true, sceneID: scene.session.persistentIdentifier)
        let second = Task { await f.runtime.signIn(from: host.window) }
        await f.remote.waitForAuthentication(count: 2)
        firstGate.open()
        await first.value
        #expect(f.runtime.account.isSigningIn && f.auth.session == nil)
        NotificationCenter.default.post(name: UIScene.didDisconnectNotification, object: scene)
        #expect(!f.runtime.account.isSigningIn && f.runtime.isForeground)
        secondGate.open()
        await second.value
        #expect(f.auth.session == nil && !f.runtime.account.isAuthenticated)
        #expect(try f.store.syncOwner() == nil)
        #expect(f.remote.pulls.isEmpty && f.remote.pushes.isEmpty)
    }

    @Test func runtimeRejectsHiddenCallerBeforeRequestingIdentity() async throws {
        let f = try MobileSyncRuntimeFixture()
        defer { f.cleanup() }
        let host = try MobileSyncRuntimeWindow()
        defer { host.close() }
        host.window.isHidden = true
        await f.runtime.signIn(from: host.window)
        #expect(f.runtime.lastSyncError != nil)
        #expect(f.identity.requests == 0 && f.remote.identityTokens.isEmpty)
    }

    @Test func staleAccountSheetDismissalCannotCancelNewerRequestInSameWindow() async throws {
        let f = try MobileSyncRuntimeFixture()
        defer { f.cleanup() }
        let host = try MobileSyncRuntimeWindow()
        defer { host.close() }
        let container = try #require(host.window.rootViewController)
        let firstSheet = BrowserMobileAccountViewController(session: f.runtime)
        let secondSheet = BrowserMobileAccountViewController(session: f.runtime)
        for sheet in [firstSheet, secondSheet] {
            container.addChild(sheet)
            container.view.addSubview(sheet.view)
            sheet.view.frame = container.view.bounds
            sheet.didMove(toParent: container)
        }
        let firstGate = MobileSyncRuntimeGate(), secondGate = MobileSyncRuntimeGate()
        f.remote.authenticationGates = [firstGate, secondGate]
        let firstButton = try #require(firstSheet.view.runtimeAccountControl("account.signIn"))
        firstButton.sendActions(for: .touchUpInside)
        await f.remote.waitForAuthentication(count: 1)
        f.runtime.cancelSignIn()
        // Both sheet views still belong to exactly the same caller window.
        #expect(firstSheet.view.window === host.window && secondSheet.view.window === host.window)
        try await Task.sleep(for: .milliseconds(20))
        let secondButton = try #require(secondSheet.view.runtimeAccountControl("account.signIn"))
        try #require(secondButton.isEnabled)
        secondButton.sendActions(for: .touchUpInside)
        await f.remote.waitForAuthentication(count: 2)
        firstSheet.presentationControllerDidDismiss(UIPresentationController(
            presentedViewController: firstSheet,
            presenting: container
        ))
        #expect(f.runtime.account.isSigningIn)
        firstGate.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(f.runtime.account.isSigningIn && f.auth.session == nil)
        secondGate.open()
        for _ in 0..<100 where f.runtime.account.isSigningIn {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(f.runtime.account.isAuthenticated)
        #expect(f.auth.session == f.remote.session)
        #expect(f.runtime.account.bindingState == .needsConsent)
    }
}

@MainActor private extension UIView {
    func runtimeAccountControl(_ id: String) -> UIControl? {
        if accessibilityIdentifier == id {
            return self as? UIControl
        }
        return subviews.lazy.compactMap { $0.runtimeAccountControl(id) }.first
    }
}

// MARK: - MobileSyncRuntimeFixture

@MainActor private final class MobileSyncRuntimeFixture {
    // MARK: Lifecycle

    init(cached: Bool = false, bound: Bool = false, configured: Bool = true) throws {
        self.directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("MobileSyncRuntime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.preferencesName = "MobileSyncRuntime.\(UUID().uuidString)"
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Browser.sqlite"))
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [.init(id: "space", title: "Space", systemImageName: "globe", selectedTabIndex: 0)],
            tabs: [.init(id: "tab", urlString: "https://example.com", placement: .temporary, spaceID: "space")]
        )
        store.saveSnapshot(snapshot)
        self.document = try BrowserMobileProfileDocument(store: store, initialSnapshot: store.loadSnapshotStrict())
        self.owner = BrowserSyncOwner(baseURL: remote.baseURL, userID: "user")
        if bound {
            try store.bindSyncOwner(owner)
        }
        if cached {
            auth.session = remote.session
        }
        self.runtime = BrowserMobileSyncSession(
            store: store, document: document, preferences: preferences, authSessionStore: auth,
            identityProvider: identity,
            environment: configured ? ["THEBROWSER_SYNC_BASE_URL": remote.baseURL.absoluteString] : [:],
            packagedServerURL: nil, clientFactory: { [remote] _ in remote },
            pushDebounce: .zero, pollInterval: nil, retryDelay: nil
        )
    }

    // MARK: Internal

    let directory: URL
    let preferencesName: String
    let preferences: UserDefaults
    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument
    let owner: BrowserSyncOwner
    let remote = MobileSyncRuntimeRemote()
    let auth = MobileSyncRuntimeAuthStorage()
    let identity = MobileSyncRuntimeIdentity()
    let runtime: BrowserMobileSyncSession

    func drain() async { await runtime.syncService?.waitForPendingOperations() }
    func cleanup() {
        runtime.cancelSignIn()
        runtime.syncService?.setRuntimeActive(false)
        preferences.removePersistentDomain(forName: preferencesName)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - MobileSyncRuntimeRemote

@MainActor private final class MobileSyncRuntimeRemote: BrowserMobileSyncRemoteServing {
    // MARK: Internal

    let baseURL = URL(string: "https://sync.example.com")!
    var identityTokens = [String]()
    var identities = [BrowserSyncDeviceIdentity]()
    var pulls = [Int]()
    var pushes = [BrowserSyncMutation]()
    var events = [BrowserSyncEvent]()
    var pullFails = false
    var authenticationGates = [MobileSyncRuntimeGate]()

    var session: BrowserAuthSession {
        .init(
            accessToken: "test-only-token",
            userID: "user",
            userEmail: "user@example.com",
            deviceID: "device",
            serverURL: baseURL
        )
    }

    func authenticateWithApple(
        identityToken: String,
        deviceName: String,
        devicePlatform: String
    ) async -> BrowserAuthSession {
        let index = identityTokens.count
        identityTokens.append(identityToken)
        identities.append(.init(name: deviceName, platform: devicePlatform))
        let ready = authWaiters.filter { $0.0 <= identityTokens.count }
        authWaiters.removeAll { $0.0 <= identityTokens.count }
        ready.forEach { $0.1.resume() }
        if authenticationGates.indices.contains(index) {
            await authenticationGates[index].wait()
        }
        return session
    }

    func waitForAuthentication(count: Int) async {
        if identityTokens.count >= count {
            return
        }
        await withCheckedContinuation { authWaiters.append((count, $0)) }
    }

    func pull(cursor: Int, authSession _: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        pulls.append(cursor)
        if pullFails {
            throw URLError(.cannotConnectToHost)
        }
        let page = events.filter { $0.serverSeq > cursor }
        return .init(cursor: page.last?.serverSeq ?? cursor, events: page, supportedPushVersions: [2])
    }

    func push(mutation: BrowserSyncMutation, authSession _: BrowserAuthSession) throws -> BrowserSyncPushResponse {
        pushes.append(mutation)
        let start = events.count
        for change in mutation.changes {
            try events.append(event(change, sequence: events.count + 1))
        }
        return .init(cursor: events.count, events: Array(events.dropFirst(start)), mutationID: mutation.id)
    }

    // MARK: Private

    private var authWaiters = [(Int, CheckedContinuation<Void, Never>)]()

    private func event(_ change: BrowserSyncChange, sequence: Int) throws -> BrowserSyncEvent {
        let data: BrowserSyncEventData
        if change.op == .delete {
            data = .deleted(id: change.entityID)
        } else if let space = change.spaceData {
            data = .space(.init(
                id: change.entityID,
                title: space.title,
                systemImageName: space.systemImageName,
                rank: space.rank,
                isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                selectedTabID: space.selectedTabID
            ))
        } else if let tab = change.tabData {
            data = .tab(.init(
                id: change.entityID,
                spaceID: tab.spaceID,
                placement: tab.placement,
                rank: tab.rank,
                urlString: tab.urlString,
                pinnedURLString: tab.pinnedURLString,
                title: tab.title,
                userTitleOverride: tab.userTitleOverride,
                faviconURLString: tab.faviconURLString,
                lastActivityAt: tab.lastActivityAt
            ))
        } else {
            throw BrowserRemoteSyncError.invalidMutationReceipt
        }
        return .init(
            serverSeq: sequence,
            deviceID: "device",
            entityType: change.entityType.rawValue,
            entityID: change.entityID,
            op: change.op.rawValue,
            data: data,
            createdAt: "2026-10-03T00:00:00Z"
        )
    }
}

// MARK: - MobileSyncRuntimeAuthStorage

@MainActor private final class MobileSyncRuntimeAuthStorage: BrowserSyncAuthSessionStoring {
    var session: BrowserAuthSession?

    func loadSession() -> BrowserAuthSession? { session }
    func saveSession(_ session: BrowserAuthSession) { self.session = session }
    func clearSession() { session = nil }
}

// MARK: - MobileSyncRuntimeIdentity

@MainActor private final class MobileSyncRuntimeIdentity: BrowserAppleIdentityProviding {
    var requests = 0

    func requestIdentityToken() -> String {
        requests += 1
        return "test-only-identity"
    }
}

// MARK: - MobileSyncRuntimeGate

@MainActor private final class MobileSyncRuntimeGate {
    // MARK: Internal

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }

    // MARK: Private

    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
}

// MARK: - MobileSyncRuntimeWindow

@MainActor private final class MobileSyncRuntimeWindow {
    // MARK: Lifecycle

    init() throws {
        let scene = try #require(BrowserMobileTestScene.windowScene)
        try #require(scene.activationState == .foregroundActive)
        self.window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    // MARK: Internal

    let window: UIWindow

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
