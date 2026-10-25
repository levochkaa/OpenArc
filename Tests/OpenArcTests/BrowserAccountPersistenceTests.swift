import Foundation
import GRDB
import Testing

// MARK: - BrowserAccountPersistenceTests

@MainActor @Suite(.serialized) struct BrowserAccountPersistenceTests {
    @Test func explicitPauseReopensWithCachedAccountAndResumesImmutableQueueWithoutApple() async throws {
        try await withAccountPersistenceFixture { f in
            let first = try f.open(runtimeActive: false)
            first.account.pauseSync()
            #expect(first.account.session == f.credentials.session)
            #expect(first.account.bindingState == .paused)
            #expect(try !first.store.requiresSyncSignIn())
            let rowsBeforeEdit = try first.store.pendingSyncQueue(for: f.owner)
            let edited = BrowserTabSessionSnapshot(
                spaces: [.init(id: "space", title: "Space", systemImageName: "globe")],
                tabs: [.init(
                    id: "tab", urlString: "https://page.example",
                    userTitleOverride: "Edited while paused", spaceID: "space"
                )]
            )
            try first.store.writeSessionBatch([.init(snapshot: edited, origin: .local(syncMove: nil))])
            first.service.schedulePush(snapshot: edited)
            let rowsAfterEdit = try first.store.pendingSyncQueue(for: f.owner)
            #expect(rowsAfterEdit.count == rowsBeforeEdit.count + 1)
            #expect(Array(rowsAfterEdit.prefix(rowsBeforeEdit.count)) == rowsBeforeEdit)
            let before = try f.evidence(first.store)
            first.service.accountSessionDidChange(nil)

            let reopened = try f.open()
            #expect(reopened.account.session == f.credentials.session)
            #expect(reopened.account.bindingState == .paused)
            try reopened.service.schedulePush(snapshot: #require(before.snapshot))
            reopened.service.schedulePull()
            await reopened.service.waitForPendingOperations()
            #expect(f.remote.requestCount == 0)
            #expect(f.identity.requests == 0 && f.remote.authenticationRequests == 0)
            #expect(try f.evidence(reopened.store) == before)

            reopened.account.resumeSync()
            await reopened.service.waitForPendingOperations()
            #expect(reopened.account.bindingState == .enabled)
            #expect(reopened.account.session == f.credentials.session)
            #expect(f.identity.requests == 0 && f.remote.authenticationRequests == 0)
            #expect(!f.remote.pulls.isEmpty && f.remote.pushes.count == 1)
            let pending = try reopened.store.pendingSyncMutations(for: f.owner)
            #expect(f.remote.pushes == Array(pending.prefix(1)))
            #expect(before.snapshot?.tabs.first?.userTitleOverride == "Edited while paused")
            // The fake transport loses its receipt, so UUIDs and raw queued
            // payloads must survive Resume unchanged until an ACK arrives.
            let afterResume = try f.evidence(reopened.store)
            #expect(afterResume.outbox == before.outbox)
            #expect(afterResume.owner == before.owner && afterResume.cursor == before.cursor)
        }
    }

    @Test(arguments: [false, true])
    func logoutWithRetainedKeychainRequiresFreshSignInAcrossReopen(bound: Bool) async throws {
        try await withAccountPersistenceFixture(bound: bound) { f in
            let first = try f.open(runtimeActive: false)
            let cached = try #require(f.credentials.session)
            let before = try f.evidence(first.store)
            f.credentials.clearError = AccountPersistenceError.injected
            f.credentials.onClear = { () throws in
                let requiresSignIn = try first.store.requiresSyncSignIn()
                #expect(requiresSignIn)
                if bound {
                    let paused = try first.store.isSyncPaused(for: f.owner)
                    #expect(paused)
                }
            }
            first.account.signOut()
            #expect(f.credentials.clearAttempts == 1 && f.credentials.session == cached)
            #expect(first.account.session == nil && first.account.lastError != nil)
            #expect(try f.evidence(first.store) == before)

            let reopened = try f.open()
            #expect(reopened.account.session == nil && reopened.account.bindingState == nil)
            #expect(try reopened.store.requiresSyncSignIn())
            reopened.account.resumeSync()
            reopened.account.enableSync()
            #expect(throws: BrowserSyncAccountError.signInRequired) {
                try reopened.service.resumeSync(for: cached)
            }
            #expect(throws: BrowserSyncAccountError.signInRequired) {
                try reopened.service.enableSync(for: cached)
            }
            #expect(throws: BrowserSyncStoreError.authenticationRequired) {
                try reopened.store.bindSyncOwner(f.owner)
            }
            reopened.service.accountSessionDidChange(cached)
            reopened.service.setRuntimeActive(false)
            reopened.service.setRuntimeActive(true)
            reopened.service.schedulePull()
            try reopened.service.schedulePush(snapshot: #require(before.snapshot))
            await reopened.service.waitForPendingOperations()
            #expect(f.remote.requestCount == 0)
            #expect(try f.evidence(reopened.store) == before)
            if !bound {
                reopened.service.setRuntimeActive(false)
                f.credentials.clearError = nil
                await reopened.account.signInWithApple()
                #expect(reopened.account.session == f.remote.response)
                #expect(reopened.account.bindingState == .needsConsent)
                #expect(try !reopened.store.requiresSyncSignIn())
                #expect(try reopened.store.syncOwner() == nil)
                #expect(try f.evidence(reopened.store) == before)
                #expect(f.remote.requestCount == 0)
            }
        }
    }

    @Test(arguments: [false, true])
    func logoutTransactionFailureStillAttemptsKeychainRemoval(clearAlsoFails: Bool) async throws {
        try await withAccountPersistenceFixture { f in
            let runtime = try f.open(runtimeActive: false)
            let before = try f.evidence(runtime.store)
            try f.sql("""
            CREATE TRIGGER reject_logout_pause BEFORE UPDATE OF paused ON browser_sync_state
            WHEN NEW.paused = 1
            BEGIN SELECT RAISE(ABORT, 'injected logout transaction failure'); END
            """)
            f.credentials.clearError = clearAlsoFails ? AccountPersistenceError.injected : nil
            runtime.account.signOut()
            #expect(runtime.account.session == nil && runtime.account.lastError != nil)
            #expect(f.credentials.clearAttempts == 1)
            #expect((f.credentials.session != nil) == clearAlsoFails)
            #expect(try !runtime.store.requiresSyncSignIn())
            #expect(try !runtime.store.isSyncPaused(for: f.owner))
            #expect(try f.evidence(runtime.store) == before)
            #expect(f.remote.requestCount == 0)
            if !clearAlsoFails {
                let reopened = try f.open()
                #expect(reopened.account.session == nil)
                await reopened.service.waitForPendingOperations()
                #expect(f.remote.requestCount == 0)
            }
            // If both independent writes fail, the caller gets an error and
            // this process is signed out; no durable logout claim is possible.
        }
    }

    @Test(arguments: ["keychain", "marker"])
    func failedFreshAuthenticationStaysQuarantinedUntilValidCompletion(failingWrite: String) async throws {
        try await withAccountPersistenceFixture { f in
            let first = try f.open(runtimeActive: false)
            first.account.signOut()
            let before = try f.evidence(first.store)
            f.remote.response = accountPersistenceSession(token: "fresh-token")
            if failingWrite == "keychain" {
                f.credentials.saveError = AccountPersistenceError.injected
            } else {
                try f.sql("""
                CREATE TRIGGER reject_auth_completion BEFORE UPDATE ON browser_preferences
                WHEN OLD.key = 'browser.sync.requiresSignIn' AND NEW.value = '0'
                BEGIN SELECT RAISE(ABORT, 'injected authentication completion failure'); END
                """)
            }
            await first.account.signInWithApple()
            #expect(first.account.session == nil && first.account.lastError != nil)
            #expect(try first.store.requiresSyncSignIn())
            #expect(try first.store.isSyncPaused(for: f.owner))
            #expect(f.credentials.saveAttempts == 1)
            #expect((f.credentials.session != nil) == (failingWrite == "marker"))
            let reopened = try f.open(runtimeActive: false)
            #expect(reopened.account.session == nil)
            #expect(try f.evidence(reopened.store) == before)
            #expect(f.remote.requestCount == 0)

            f.credentials.saveError = nil
            if failingWrite == "marker" {
                try f.sql("DROP TRIGGER reject_auth_completion")
            }
            await reopened.account.signInWithApple()
            #expect(reopened.account.session == f.remote.response)
            #expect(reopened.account.bindingState == .enabled)
            #expect(try !reopened.store.requiresSyncSignIn())
            #expect(try !reopened.store.isSyncPaused(for: f.owner))
            #expect(try f.evidence(reopened.store) == before)
            #expect(f.remote.requestCount == 0)
            let final = try f.open(runtimeActive: false)
            #expect(final.account.session == f.remote.response && final.account.bindingState == .enabled)
        }
    }

    @Test(arguments: ["apple", "server"])
    func staleAuthenticationCannotClearANewerDurableLogout(stage: String) async throws {
        try await withAccountPersistenceFixture { f in
            let runtime = try f.open(runtimeActive: false)
            runtime.account.signOut()
            let before = try f.evidence(runtime.store)
            let gate = AccountPersistenceGate()
            defer { gate.open() }
            if stage == "apple" {
                f.identity.release = gate
            } else {
                f.remote.releaseAuthentication = gate
            }
            let old = Task { await runtime.account.signInWithApple() }
            try #require(await accountPersistenceEventually {
                stage == "apple" ? f.identity.requests == 1 : f.remote.authenticationRequests == 1
            })
            runtime.account.cancelSignIn()
            f.identity.release = nil
            f.remote.releaseAuthentication = nil
            f.remote.response = accountPersistenceSession(token: "new-successful-token")
            await runtime.account.signInWithApple()
            #expect(runtime.account.session == f.remote.response)
            #expect(try !runtime.store.requiresSyncSignIn())
            runtime.account.signOut()
            let savedAttempts = f.credentials.saveAttempts
            gate.open()
            await old.value
            #expect(f.credentials.saveAttempts == savedAttempts)
            #expect(runtime.account.session == nil && f.credentials.session == nil)
            #expect(try runtime.store.requiresSyncSignIn())
            #expect(try runtime.store.isSyncPaused(for: f.owner))
            let reopened = try f.open()
            #expect(reopened.account.session == nil)
            await reopened.service.waitForPendingOperations()
            #expect(f.remote.requestCount == 0)
            #expect(try f.evidence(reopened.store) == before)
        }
    }

    @Test(arguments: ["owner", "server"])
    func freshForeignIdentityCannotClearProfileLogout(mismatch: String) async throws {
        try await withAccountPersistenceFixture { f in
            let runtime = try f.open(runtimeActive: false)
            runtime.account.signOut()
            let before = try f.evidence(runtime.store)
            f.remote.response = accountPersistenceSession(
                userID: mismatch == "owner" ? "other-owner" : f.owner.userID,
                baseURL: mismatch == "server" ? URL(string: "https://other.example")! : f.owner.baseURL
            )
            await runtime.account.signInWithApple()
            #expect(runtime.account.session == nil && runtime.account.lastError != nil)
            #expect(f.credentials.saveAttempts == 0)
            #expect(try runtime.store.requiresSyncSignIn())
            #expect(try f.evidence(runtime.store) == before)
            #expect(f.remote.requestCount == 0)
        }
    }

    @Test(arguments: [false, true])
    func legacyPausedStateMigratesConservativelyOnceWithoutChangingQueue(legacyPaused: Bool) async throws {
        try await withAccountPersistenceFixture { f in
            let current = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
            let before = try f.evidence(current)
            // Recreate precisely the pre-marker schema state. Existing tables,
            // baseline and immutable outbox BLOBs are left byte-for-byte intact.
            try f.sql("""
            DELETE FROM grdb_migrations WHERE identifier = 'distinguishSyncPauseFromLogout';
            DELETE FROM browser_preferences WHERE key = 'browser.sync.requiresSignIn';
            UPDATE browser_sync_state SET paused = \(legacyPaused ? 1 : 0) WHERE id = 1;
            """)
            let migrated = try f.open(runtimeActive: false)
            #expect(try migrated.store.requiresSyncSignIn() == legacyPaused)
            #expect((migrated.account.session == nil) == legacyPaused)
            #expect(try f.evidence(migrated.store) == before)
            if legacyPaused {
                #expect(throws: BrowserSyncStoreError.authenticationRequired) {
                    try migrated.store.resumeSync(for: f.owner)
                }
                await migrated.account.signInWithApple()
            }
            migrated.account.pauseSync()
            let reopened = try f.open()
            #expect(try !reopened.store.requiresSyncSignIn())
            #expect(reopened.account.session == f.credentials.session)
            #expect(reopened.account.bindingState == .paused)
            await reopened.service.waitForPendingOperations()
            #expect(f.remote.requestCount == 0)
            #expect(try f.evidence(reopened.store) == before)
        }
    }

    @Test(arguments: [false, true])
    func invalidDurableAuthenticationStateFailsClosedWithoutRemovingLocalData(missing: Bool) async throws {
        try await withAccountPersistenceFixture { f in
            let store = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
            let before = try f.evidence(store)
            try f.sql(missing
                ? "DELETE FROM browser_preferences WHERE key = 'browser.sync.requiresSignIn'"
                : "UPDATE browser_preferences SET value = 'invalid' WHERE key = 'browser.sync.requiresSignIn'")
            let runtime = try f.open()
            #expect(runtime.account.session == nil && runtime.account.lastError != nil)
            #expect(throws: BrowserSyncStoreError.invalidAuthenticationState) { try runtime.store.requiresSyncSignIn() }
            runtime.service.accountSessionDidChange(f.credentials.session)
            runtime.service.schedulePull()
            await runtime.service.waitForPendingOperations()
            #expect(f.remote.requestCount == 0)
            #expect(try f.evidence(runtime.store) == before)
        }
    }
}

// MARK: - AccountPersistenceFixture

@MainActor private final class AccountPersistenceFixture {
    // MARK: Lifecycle

    init(directory: URL, bound: Bool) throws {
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        try store.writeSessionBatch([.init(snapshot: .init(
            spaces: [.init(id: "space", title: "Space", systemImageName: "globe")],
            tabs: [.init(id: "tab", urlString: "https://page.example", spaceID: "space")]
        ), origin: .local(syncMove: nil))])
        if bound {
            try store.bindSyncOwner(owner)
            try store.saveSyncCursor(47, for: owner)
        }
    }

    // MARK: Internal

    let databaseURL: URL
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "account")
    let credentials = AccountPersistenceCredentials()
    let identity = AccountPersistenceIdentity()
    let remote = AccountPersistenceRemote()

    func open(runtimeActive: Bool = true) throws -> AccountPersistenceRuntime {
        let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        let service = BrowserSyncService(
            localStore: store, remoteClient: remote, authSessionStore: credentials,
            pushDebounce: .zero, pollInterval: nil, retryDelay: nil,
            runtimeActive: runtimeActive, errorReporter: { _, _ in }
        )
        let account = BrowserAccountStore(
            syncClient: remote, authSessionStore: credentials, syncCoordinator: service,
            appleSignInService: identity, deviceIdentity: .init(name: "Fixture", platform: "macOS")
        )
        let runtime = AccountPersistenceRuntime(store: store, service: service, account: account)
        runtimes.append(runtime)
        return runtime
    }

    func evidence(_ store: BrowserSQLiteSessionStore) throws -> AccountPersistenceEvidence {
        let database = try DatabaseQueue(path: databaseURL.path)
        let values = try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT position, mutation_id, protocol_version, payload FROM browser_sync_outbox ORDER BY position"
            )
            return try (
                rows.map { row in
                    AccountPersistenceEvidence.OutboxRow(
                        position: row["position"], id: row["mutation_id"],
                        version: row["protocol_version"], payload: row["payload"]
                    )
                },
                Data.fetchOne(db, sql: "SELECT payload FROM browser_sync_baseline WHERE id = 1")
            )
        }
        let owner = try store.syncOwner()
        return try .init(
            snapshot: store.loadSnapshotStrict(), owner: owner,
            cursor: owner.map { try store.syncCursor(for: $0) }, outbox: values.0, baseline: values.1
        )
    }

    func sql(_ sql: String) throws {
        let database = try DatabaseQueue(path: databaseURL.path)
        try database.write { try $0.execute(sql: sql) }
    }

    func stop() async {
        credentials.onClear = nil
        for runtime in runtimes {
            runtime.service.accountSessionDidChange(nil)
        }
        for runtime in runtimes {
            await runtime.service.waitForPendingOperations()
        }
        runtimes.removeAll()
    }

    // MARK: Private

    private var runtimes = [AccountPersistenceRuntime]()
}

// MARK: - AccountPersistenceEvidence

private struct AccountPersistenceEvidence: Equatable {
    struct OutboxRow: Equatable {
        let position: Int64
        let id: String
        let version: Int
        let payload: Data
    }

    let snapshot: BrowserTabSessionSnapshot?
    let owner: BrowserSyncOwner?
    let cursor: Int?
    let outbox: [OutboxRow]
    let baseline: Data?
}

// MARK: - AccountPersistenceRuntime

@MainActor private struct AccountPersistenceRuntime {
    let store: BrowserSQLiteSessionStore
    let service: BrowserSyncService
    let account: BrowserAccountStore
}

// MARK: - AccountPersistenceCredentials

@MainActor private final class AccountPersistenceCredentials: BrowserSyncAuthSessionStoring {
    var session: BrowserAuthSession? = accountPersistenceSession()
    var saveAttempts = 0
    var clearAttempts = 0
    var saveError: Error?
    var clearError: Error?
    var onClear: (() throws -> Void)?

    func loadSession() -> BrowserAuthSession? { session }
    func saveSession(_ session: BrowserAuthSession) throws {
        saveAttempts += 1
        if let saveError {
            throw saveError
        }
        self.session = session
    }

    func clearSession() throws {
        clearAttempts += 1
        try onClear?()
        if let clearError {
            throw clearError
        }
        session = nil
    }
}

// MARK: - AccountPersistenceIdentity

@MainActor private final class AccountPersistenceIdentity: BrowserAppleIdentityProviding {
    var requests = 0
    var release: AccountPersistenceGate?

    func requestIdentityToken() async -> String {
        requests += 1
        await release?.wait()
        return "fixture-apple-token"
    }
}

// MARK: - AccountPersistenceRemote

@MainActor private final class AccountPersistenceRemote: BrowserSyncRemoteServing, BrowserAppleAuthenticating {
    let baseURL = URL(string: "https://sync.example")!
    var response = accountPersistenceSession()
    var authenticationRequests = 0
    var releaseAuthentication: AccountPersistenceGate?
    var pulls = [Int]()
    var pushes = [BrowserSyncMutation]()
    var otherPushes = 0

    var requestCount: Int { pulls.count + pushes.count + otherPushes }

    func authenticateWithApple(
        identityToken _: String,
        deviceName _: String,
        devicePlatform _: String
    ) async -> BrowserAuthSession {
        authenticationRequests += 1
        let response = response
        await releaseAuthentication?.wait()
        return response
    }

    func pull(cursor: Int, authSession _: BrowserAuthSession) -> BrowserSyncPullResponse {
        pulls.append(cursor)
        return .init(cursor: cursor, events: [], protocolVersion: 2, supportedPushVersions: [2])
    }

    func push(mutation: BrowserSyncMutation, authSession _: BrowserAuthSession) throws -> BrowserSyncPushResponse {
        pushes.append(mutation)
        throw URLError(.networkConnectionLost)
    }

    func push(
        mutation _: BrowserSyncSemanticMutation,
        authSession _: BrowserAuthSession
    ) throws -> BrowserSyncSemanticPushResponse {
        otherPushes += 1
        throw URLError(.networkConnectionLost)
    }

    func push(
        mutation _: BrowserSyncFolderMutation,
        authSession _: BrowserAuthSession
    ) throws -> BrowserSyncFolderPushResponse {
        otherPushes += 1
        throw URLError(.networkConnectionLost)
    }
}

// MARK: - AccountPersistenceGate

@MainActor private final class AccountPersistenceGate {
    // MARK: Internal

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    // MARK: Private

    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()
}

// MARK: - AccountPersistenceError

private enum AccountPersistenceError: Error { case injected }

private func accountPersistenceSession(
    token: String = "fixture-token", userID: String = "account", baseURL: URL = URL(string: "https://sync.example")!
) -> BrowserAuthSession {
    .init(
        accessToken: token,
        userID: userID,
        userEmail: "fixture@example.test",
        deviceID: "fixture-device",
        serverURL: baseURL
    )
}

@MainActor private func accountPersistenceEventually(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

@MainActor private func withAccountPersistenceFixture(
    bound: Bool = true, _ body: (AccountPersistenceFixture) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccountPersistence-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runAccountPersistenceFixture(directory: directory, bound: bound, body)
}

@MainActor private func runAccountPersistenceFixture(
    directory: URL, bound: Bool, _ body: (AccountPersistenceFixture) async throws -> Void
) async throws {
    let fixture = try AccountPersistenceFixture(directory: directory, bound: bound)
    do { try await body(fixture) }
    catch { await fixture.stop()
        throw error
    }
    await fixture.stop()
}
