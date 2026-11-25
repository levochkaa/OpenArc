// BrowserAccountDeletionTests.swift

import AppKit
import Foundation
import GRDB
import Synchronization
import Testing

// MARK: - BrowserAccountDeletionTests

/// Account deletion through the production HTTP client, sync service and
/// profile database, against a fake server.
@MainActor @Suite(.serialized) struct BrowserAccountDeletionTests {
    @Test func clientSendsAnAuthenticatedDeleteAndMapsTheServersAnswers() async throws {
        let f = try DeletionFixture()
        defer { f.close() }
        DeletionURLProtocol.respond(204)
        try await f.client.deleteAccount(authSession: f.session)
        let request = try #require(DeletionURLProtocol.requests.last)
        #expect(request.method == "DELETE" && request.path == "/v1/account")
        #expect(request.authorization == "Bearer fixture-token")

        let failures: [(Int, String, BrowserAccountDeletionError)] = [
            (401, #"{"error":"unauthorized"}"#, .signInRequired),
            (429, #"{"statusCode":429,"message":"Too many requests; try again later"}"#, .tooManyRequests),
            (
                500,
                #"{"statusCode":500,"message":"Internal server error"}"#,
                .server(statusCode: 500, message: "Internal server error"),
            ),
        ]
        for (status, body, expected) in failures {
            DeletionURLProtocol.respond(status, body)
            await #expect(throws: expected) { try await f.client.deleteAccount(authSession: f.session) }
        }

        let other = BrowserAuthSession(
            accessToken: "t", userID: "u", userEmail: nil, deviceID: "d",
            serverURL: f.otherServerURL,
        )
        let before = DeletionURLProtocol.requests.count
        await #expect(throws: BrowserSyncAccountError.serverChanged) {
            try await f.client.deleteAccount(authSession: other)
        }
        #expect(DeletionURLProtocol.requests.count == before, "a session from another server never leaves the app")

        #expect(BrowserAccountDeletionError.from(URLError(.notConnectedToInternet)) == .offline)
        #expect(BrowserAccountDeletionError.from(URLError(.timedOut)) == .offline)
    }

    @Test func nativeAppleSignInSendsTheAuthorizationCode() async throws {
        let f = try DeletionFixture()
        defer { f.close() }
        DeletionURLProtocol.respond(201, """
        {"accessToken":"token","tokenType":"Bearer","expiresIn":2592000,
         "user":{"id":"user","email":null},
         "device":{"id":"device","name":"iPhone","platform":"iOS","lastSeenAt":"2026-11-19T12:00:00.123Z"}}
        """)
        _ = try await f.client.authenticateWithApple(
            identityToken: "identity", authorizationCode: "code", deviceName: "iPhone", devicePlatform: "iOS",
        )
        let body = try #require(DeletionURLProtocol.requests.last?.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["identityToken"] == "identity" && json["authorizationCode"] == "code")
    }

    @Test func deletingSignsOutAndUnbindsTheProfileButKeepsItsSpacesAndTabs() async throws {
        let f = try DeletionFixture()
        defer { f.close() }
        let account = f.account()
        #expect(account.session == f.session && account.bindingState == .enabled)
        let snapshot = try f.store.loadSnapshotStrict()
        #expect(try !f.store.pendingSyncQueue(for: f.owner).isEmpty)

        DeletionURLProtocol.respond(204)
        #expect(await account.deleteAccount())
        #expect(DeletionURLProtocol.requests.map(\.path) == ["/v1/account"])
        #expect(account.session == nil && account.bindingState == nil && account.lastError == nil)
        #expect(!account.isDeletingAccount)
        #expect(f.credentials.session == nil)
        #expect(try f.store.syncOwner() == nil)
        #expect(try !f.store.requiresSyncSignIn(), "nothing is left to quarantine")
        #expect(try f.count("browser_sync_outbox") == 0 && f.count("browser_sync_baseline") == 0)
        #expect(try f.store.loadSnapshotStrict() == snapshot, "local Spaces and tabs stay")

        // The next launch is signed out without an error, and a new account
        // adopts the profile instead of finding it bound to another one.
        let reopened = f.account()
        #expect(reopened.session == nil && reopened.lastError == nil)
        let newAccount = BrowserAuthSession(
            accessToken: "new-token", userID: "new-account", userEmail: nil, deviceID: "new-device",
            serverURL: f.baseURL,
        )
        f.credentials.saveSession(newAccount)
        #expect(try f.service.bindingState(for: newAccount) == .needsConsent)
        try f.service.enableSync(for: newAccount)
        #expect(try f.store.syncOwner()?.userID == "new-account")
        #expect(
            try !f.store
                .pendingSyncQueue(for: BrowserSyncOwner(baseURL: f.baseURL, userID: "new-account"))
                .isEmpty,
            "the new account receives the local Spaces and tabs",
        )
    }

    /// The generated client wraps transport failures in `ClientError`, whose
    /// description is a dump of the operation and the `NSError`.
    @Test func aLostConnectionReadsAsAnUnreachableServer() async throws {
        let f = try DeletionFixture()
        defer { f.close() }
        let account = f.account()
        DeletionURLProtocol.fail(URLError(.networkConnectionLost))
        await account.loadProviders()
        #expect(account.providers == nil)
        #expect(account.lastError == BrowserStrings.syncServerUnreachable)
    }

    @Test func aFailedDeletionKeepsTheAccountSignedInAndSaysWhy() async throws {
        let f = try DeletionFixture()
        defer { f.close() }
        let account = f.account()
        let queue = try f.store.pendingSyncQueue(for: f.owner)

        DeletionURLProtocol.respond(500, #"{"statusCode":500,"message":"Internal server error"}"#)
        #expect(await !account.deleteAccount())
        #expect(account.session == f.session && account.bindingState == .enabled)
        #expect(account.lastError == "Internal server error")
        #expect(try f.credentials.session == f.session && (f.store.syncOwner()) == f.owner)
        #expect(try f.store.pendingSyncQueue(for: f.owner) == queue)

        DeletionURLProtocol.fail(URLError(.notConnectedToInternet))
        await #expect(throws: BrowserAccountDeletionError.offline) {
            try await f.client.deleteAccount(authSession: f.session)
        }
        #expect(await !account.deleteAccount())
        #expect(account.lastError == BrowserStrings.syncServerUnreachable)
        #expect(account.session == f.session)

        DeletionURLProtocol.respond(401, #"{"error":"unauthorized"}"#)
        #expect(await !account.deleteAccount())
        #expect(account.lastError == BrowserStrings.syncAccountDeleteSignInAgain)

        // A retry after a lost reply finds the account gone and succeeds.
        DeletionURLProtocol.respond(204)
        #expect(await account.deleteAccount())
        #expect(account.session == nil && account.lastError == nil)
    }

    @Test func settingsOfferDeletionOnlyWhileSignedInAndAskWithCancelAsTheDefault() async throws {
        let f = try DeletionFixture()
        defer { f.close() }
        let account = f.account()
        let settings = try DeletionSettings(account: account)
        defer { settings.cleanup() }
        let delete = try #require(deletionView("browser.settings.account.delete", in: settings.controller.view)
            as? BrowserActionButton)
        #expect(delete.isEnabled && delete.title == BrowserStrings.syncAccountDelete)

        let (alert, clearBrowsingData) = BrowserSettingsViewController.accountDeletionAlert()
        #expect(alert.alertStyle == .warning)
        #expect(alert.buttons.map(\.title) == [
            BrowserStrings.syncAccountDeleteConfirm, BrowserStrings.syncAccountDeleteCancel,
        ])
        #expect(alert.buttons[0].hasDestructiveAction && alert.buttons[0].keyEquivalent.isEmpty)
        #expect(alert.buttons[1].keyEquivalent == "\r", "Return keeps the account")
        #expect(clearBrowsingData.state == .off, "browsing data stays unless the user asks")

        DeletionURLProtocol.respond(204)
        #expect(await account.deleteAccount())
        try await deletionEventually {
            deletionView("browser.settings.account.delete", in: settings.controller.view) == nil
        }
    }

    @Test func aKeychainFailureAfterDeletionStillSignsOutAndRequiresSignIn() async throws {
        let f = try DeletionFixture()
        defer { f.close() }
        let account = f.account()
        f.credentials.clearError = DeletionTestError.keychain
        DeletionURLProtocol.respond(204)
        #expect(await account.deleteAccount())
        #expect(account.session == nil && account.lastError != nil)
        #expect(try f.store.requiresSyncSignIn(), "a token left in the Keychain cannot sign back in")
        #expect(try f.store.syncOwner() == nil)
        let reopened = f.account()
        #expect(reopened.session == nil)
    }
}

// MARK: - DeletionFixture

@MainActor private final class DeletionFixture {
    // MARK: Internal

    let baseURL = URL(string: "https://deletion.example")!
    let otherServerURL = URL(string: "https://other.example")!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccountDeletion-\(UUID())")
    let urlSession: URLSession
    let client: BrowserRemoteSyncClient
    let store: BrowserSQLiteSessionStore
    let service: BrowserSyncService
    let credentials = DeletionCredentials()

    var owner: BrowserSyncOwner { .init(baseURL: baseURL, userID: "account") }
    var session: BrowserAuthSession {
        .init(
            accessToken: "fixture-token", userID: "account", userEmail: "me@example.test",
            deviceID: "device", serverURL: baseURL,
        )
    }

    init() throws {
        DeletionURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeletionURLProtocol.self]
        self.urlSession = URLSession(configuration: configuration)
        self.client = try BrowserRemoteSyncClient(configuration: #require(.init(baseURL: baseURL)), session: urlSession)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        try store.writeSessionBatch([.init(snapshot: .init(
            spaces: [.init(id: "space", title: "Space", systemImageName: "globe")],
            tabs: [.init(id: "tab", urlString: "https://page.example", spaceID: "space")],
        ), origin: .local(syncMove: nil))])
        // Without runtime activity nothing but the deletion reaches the server.
        self.service = BrowserSyncService(
            localStore: store, remoteClient: client, authSessionStore: credentials,
            pushDebounce: .zero, pollInterval: nil, retryDelay: nil, runtimeActive: false,
        )
        credentials.session = session
        try service.enableSync(for: session)
        DeletionURLProtocol.reset()
    }

    func account() -> BrowserAccountStore {
        BrowserAccountStore(
            syncClient: client, authSessionStore: credentials, syncCoordinator: service,
            deviceIdentity: .init(name: "Fixture", platform: "macOS"),
        )
    }

    func count(_ table: String) throws -> Int {
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Profile.sqlite").path)
        return try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    func close() {
        service.accountSessionDidChange(nil)
        urlSession.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - DeletionSettings

/// Settings › Accounts for the fixture's account, laid out without a window.
@MainActor private struct DeletionSettings {
    let suite = BrowserTestDefaults.suiteName("OpenArcAccountDeletionSettings")
    let root: URL
    let controller: BrowserSettingsViewController

    init(account: BrowserAccountStore) throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = BrowserChromeModel(
            tabDriver: FakeBrowserTabDriver(),
            sessionSnapshotStore: InMemorySessionSnapshotStore(),
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        self.controller = BrowserSettingsViewController(
            model: model,
            profileStore: BrowserProfileStore(rootCacheURL: root),
            currentProfileID: BrowserProfile.defaultProfile.id,
            accountStore: account,
            pane: .accounts,
            openProfile: { _ in },
            openURL: { _ in },
        )
        controller.view.layoutSubtreeIfNeeded()
    }

    func cleanup() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private func deletionView(_ id: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == id {
        return view
    }
    for subview in view.subviews {
        if let match = deletionView(id, in: subview) {
            return match
        }
    }
    return nil
}

@MainActor private func deletionEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}

// MARK: - DeletionCredentials

@MainActor private final class DeletionCredentials: BrowserSyncAuthSessionStoring {
    var session: BrowserAuthSession?
    var clearError: Error?

    func loadSession() -> BrowserAuthSession? { session }
    func saveSession(_ session: BrowserAuthSession) { self.session = session }
    func clearSession() throws {
        if let clearError {
            throw clearError
        }
        session = nil
    }
}

// MARK: - DeletionTestError

private enum DeletionTestError: Error { case keychain }

// MARK: - DeletionURLProtocol

/// The fake server: answers every request with the configured status and
/// body, or fails it like a lost connection.
private final class DeletionURLProtocol: URLProtocol, @unchecked Sendable {
    // MARK: Internal

    struct Recorded {
        let method: String?
        let path: String?
        let authorization: String?
        let body: Data?
    }

    // MARK: Private

    private struct State {
        var statusCode = 204
        var body = Data()
        var failure: URLError?
        var requests = [Recorded]()
    }

    private static let state = Mutex(State())

    // MARK: Internal

    static var requests: [Recorded] { state.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "deletion.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(
            method: request.httpMethod,
            path: request.url?.path,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: request.httpBody ?? request.httpBodyStream.map(Self.read),
        )
        let (statusCode, body, failure) = Self.state.withLock { state in
            state.requests.append(recorded)
            return (state.statusCode, state.body, state.failure)
        }
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
            headerFields: body.isEmpty ? [:] : ["Content-Type": "application/json"],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() { state.withLock { $0 = State() } }

    static func respond(_ statusCode: Int, _ body: String = "") {
        state.withLock { state in
            state.statusCode = statusCode
            state.body = Data(body.utf8)
            state.failure = nil
        }
    }

    static func fail(_ error: URLError) { state.withLock { $0.failure = error } }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Reads to the end: the client writes the body on its own thread, so hasBytesAvailable can still be false
        // here, and closing the stream before the last chunk crashes OpenAPIURLSession's body bridge.
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
