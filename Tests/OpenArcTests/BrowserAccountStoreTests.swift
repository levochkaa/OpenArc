// BrowserAccountStoreTests.swift

import Foundation
import Testing

// MARK: - BrowserAccountStoreTests

@Suite(.serialized)
@MainActor struct BrowserAccountStoreTests {
    @Test(arguments: [false, true])
    func cancellingOldSignInDoesNotFinishOrPublishOverTheNextAttempt(serverDispatched: Bool) async {
        let f = AccountStoreFixture()
        let oldGate = AccountTestGate()
        let newGate = AccountTestGate()
        if serverDispatched {
            f.remote.release = oldGate
        } else {
            f.identity.release = oldGate
        }
        defer { oldGate.open()
            newGate.open()
        }
        let old = Task { await f.store.signInWithApple() }
        if serverDispatched {
            await f.remote.started.wait()
        } else {
            await f.identity.started.wait()
        }
        f.store.cancelSignIn()
        #expect(!f.store.isSigningIn && f.store.session == nil)

        f.identity.started = AccountTestGate()
        f.identity.release = newGate
        let next = Task { await f.store.signInWithApple() }
        await f.identity.started.wait()
        oldGate.open()
        await old.value
        #expect(f.store.isSigningIn)
        #expect(f.auth.saved.isEmpty && f.store.session == nil)
        await f.store.signInWithApple()
        #expect(f.identity.requests == 2)
        f.remote.release = nil
        newGate.open()
        await next.value
        #expect(!f.store.isSigningIn)
        #expect(f.auth.saved == [f.remote.response])
        #expect(f.store.session == f.remote.response)
    }

    @Test func pauseAndResumeKeepCredentialsAndRequireNoAppleRequest() {
        let session = accountSession()
        let f = AccountStoreFixture(binding: .enabled, cachedSession: session)
        f.store.pauseSync()
        #expect(f.store.session == session && f.auth.session == session)
        #expect(f.store.bindingState == .paused)
        #expect(f.sync.suspensions == 1 && f.identity.requests == 0)
        f.store.resumeSync()
        #expect(f.store.bindingState == .enabled && f.store.session == session)
        #expect(f.sync.resumedSessions == [session])
        #expect(f.sync.sessionChanges.last == .some(session))
        #expect(f.auth.saved.isEmpty && f.identity.requests == 0)
        f.sync.suspendError = AccountTestError.failure
        f.store.pauseSync()
        #expect(f.store.bindingState == .enabled && f.store.lastError != nil)
        #expect(f.store.session == session && f.auth.session == session)
    }

    @Test func authenticationUsesTheInjectedPlatformIdentity() async {
        for identity in [
            BrowserSyncDeviceIdentity(name: "Personal Mac", platform: "macOS"),
            BrowserSyncDeviceIdentity(name: "Travel iPad", platform: "iPadOS"),
        ] {
            let f = AccountStoreFixture(deviceIdentity: identity)
            await f.store.signInWithApple()
            #expect(f.remote.deviceIdentities == [identity])
        }
    }

    @Test func explicitKeychainNamespacesKeepDesktopAccountNames() {
        #expect(BrowserAuthSessionNamespace.defaultProfile.keychainAccount == "auth-session")
        #expect(BrowserAuthSessionNamespace.profile("Profile 2").keychainAccount == "auth-session.Profile 2")
        #expect(BrowserAuthSessionNamespace.profile("mobile-main").keychainAccount == "auth-session.mobile-main")
        #expect(BrowserChromeModel.defaultSpaceID == BrowserSessionDefaults.defaultSpaceID)
        #expect(BrowserChromeModel.defaultSpaceIconName == BrowserSessionDefaults.defaultSpaceIconName)
    }

    @Test func firstSignInRequiresExplicitAdoptionBeforeEnablingSync() async {
        let f = AccountStoreFixture()
        await f.store.signInWithApple()

        #expect(f.store.session == f.remote.response)
        #expect(f.auth.saved == [f.remote.response])
        #expect(f.store.bindingState == .needsConsent)
        #expect(f.sync.enabledSessions.isEmpty)
        #expect(f.sync.resumedSessions.isEmpty)

        f.store.enableSync()

        #expect(f.sync.enabledSessions == [f.remote.response])
        #expect(f.store.bindingState == .enabled)
    }

    @Test func explicitSignInResumesAnExistingPausedAccount() async {
        let f = AccountStoreFixture(binding: .paused)
        await f.store.signInWithApple()

        #expect(f.sync.completedAuthentications == [f.remote.response])
        #expect(f.sync.resumedSessions.isEmpty)
        #expect(f.sync.enabledSessions.isEmpty)
        #expect(f.store.bindingState == .enabled)
    }

    @Test func differentAccountCannotAdoptAnAlreadyBoundProfile() async {
        let f = AccountStoreFixture(binding: .differentAccount)
        await f.store.signInWithApple()
        f.store.enableSync()

        #expect(f.sync.enabledSessions.isEmpty)
        #expect(f.sync.resumedSessions.isEmpty)
        #expect(f.store.session == nil)
        #expect(f.store.bindingState == nil)
        #expect(f.auth.saved.isEmpty)
        #expect(f.store.lastError != nil)
    }

    @Test func repeatedSignInDoesNotReplaceTheAppleContinuation() async {
        let f = AccountStoreFixture()
        f.identity.release = AccountTestGate()
        let request = Task { await f.store.signInWithApple() }
        defer { f.identity.release?.open() }
        await f.identity.started.wait()

        await f.store.signInWithApple()
        #expect(f.identity.requests == 1)
        #expect(f.remote.tokens.isEmpty)

        f.identity.release?.open()
        await request.value
        #expect(f.remote.tokens == ["apple-token"])
        #expect(f.auth.saved.count == 1)
    }

    @Test func logoutInvalidatesAnAppleTokenRequestBeforeItCanAuthenticate() async {
        let f = AccountStoreFixture()
        f.identity.release = AccountTestGate()
        let request = Task { await f.store.signInWithApple() }
        defer { f.identity.release?.open() }
        await f.identity.started.wait()

        f.store.signOut()
        f.identity.release?.open()
        await request.value

        #expect(f.remote.tokens.isEmpty)
        #expect(f.auth.saved.isEmpty)
        #expect(f.store.session == nil)
        #expect(!f.store.isSigningIn)
    }

    @Test func logoutInvalidatesAnAlreadyDispatchedAuthenticationResponse() async {
        let f = AccountStoreFixture()
        f.remote.release = AccountTestGate()
        let request = Task { await f.store.signInWithApple() }
        defer { f.remote.release?.open() }
        await f.remote.started.wait()

        f.store.signOut()
        f.remote.release?.open()
        await request.value

        #expect(f.auth.saved.isEmpty)
        #expect(f.store.session == nil)
        #expect(f.sync.enabledSessions.isEmpty)
        #expect(f.sync.resumedSessions.isEmpty)
        #expect(!f.store.isSigningIn)
    }

    @Test func logoutMarksSignInRequiredBeforeRemovingCredentialsAndReportsRemovalFailure() async {
        let f = AccountStoreFixture(binding: .enabled)
        await f.store.signInWithApple()
        f.auth.clearError = AccountTestError.failure
        f.auth.onClear = {
            #expect(f.sync.signOuts == 1)
            #expect(f.sync.signInRequired)
            #expect(f.sync.state == .paused)
            #expect(f.sync.sessionChanges.last == .some(nil))
        }

        f.store.signOut()

        #expect(f.auth.session != nil, "The simulated Keychain failure retained credentials")
        #expect(f.store.session == nil)
        #expect(f.store.lastError != nil)
        #expect(f.sync.state == .paused)
    }

    @Test func cachedExplicitlyPausedSessionRemainsVisibleWithoutStartingSync() {
        let cached = accountSession()
        let f = AccountStoreFixture(binding: .paused, cachedSession: cached)

        #expect(f.store.session == cached)
        #expect(f.store.bindingState == .paused)
        #expect(f.sync.resumedSessions.isEmpty)
        #expect(f.sync.enabledSessions.isEmpty)
        #expect(f.sync.sessionChanges.compactMap(\.self).isEmpty)
        #expect(f.identity.requests == 0 && f.remote.tokens.isEmpty)
    }

    @Test func legacyAndForeignServerCredentialsAreQuarantinedAtStartup() {
        let sessions = [
            accountSession(serverURL: nil),
            accountSession(serverURL: accountTestURL("https://other.example")),
        ]
        for session in sessions {
            let f = AccountStoreFixture(binding: .enabled, cachedSession: session)
            #expect(f.store.session == nil)
            #expect(f.sync.enabledSessions.isEmpty)
            #expect(f.sync.resumedSessions.isEmpty)
            #expect(f.sync.sessionChanges.compactMap(\.self).isEmpty)
            #expect(f.auth.saved.isEmpty)
        }
    }

    @Test func missingDurableCoordinatorCannotAuthenticateOrEnableSync() async {
        let identity = AccountTestIdentity()
        let remote = AccountTestAuthenticator()
        let store = BrowserAccountStore(
            syncClient: remote,
            authSessionStore: AccountTestAuthStorage(),
            syncCoordinator: nil,
            appleSignInService: identity,
            deviceIdentity: .init(name: "Test Mac", platform: "macOS"),
        )

        #expect(!store.isConfigured)
        await store.signInWithApple()
        store.enableSync()
        #expect(identity.requests == 0)
        #expect(remote.tokens.isEmpty)
        #expect(store.lastError != nil)
    }

    @Test func failedCredentialSaveDoesNotEnableOrPublishTheSession() async {
        let f = AccountStoreFixture()
        f.auth.saveError = AccountTestError.failure
        await f.store.signInWithApple()

        #expect(f.store.session == nil)
        #expect(f.auth.session == nil)
        #expect(f.store.lastError != nil)
        #expect(f.sync.sessionChanges.compactMap(\.self).isEmpty)
        #expect(f.sync.enabledSessions.isEmpty)
    }

    @Test func authenticationResponseFromAnotherServerCannotBeSavedOrActivated() async {
        let f = AccountStoreFixture()
        f.remote.response = accountSession(serverURL: accountTestURL("https://other.example"))
        await f.store.signInWithApple()

        #expect(f.store.session == nil)
        #expect(f.auth.saved.isEmpty)
        #expect(f.sync.sessionChanges.compactMap(\.self).isEmpty)
        #expect(f.store.lastError != nil)
    }
}

// MARK: - AccountStoreFixture

@MainActor private final class AccountStoreFixture {
    // MARK: Internal

    let identity = AccountTestIdentity()
    let remote = AccountTestAuthenticator()
    let auth = AccountTestAuthStorage()
    let sync = AccountTestSyncController()
    let store: BrowserAccountStore

    init(
        binding: BrowserSyncBindingState = .needsConsent,
        cachedSession: BrowserAuthSession? = nil,
        deviceIdentity: BrowserSyncDeviceIdentity = .init(name: "Test Mac", platform: "macOS"),
    ) {
        auth.session = cachedSession
        sync.state = binding
        self.store = BrowserAccountStore(
            syncClient: remote,
            authSessionStore: auth,
            syncCoordinator: sync,
            appleSignInService: identity,
            deviceIdentity: deviceIdentity,
        )
    }
}

// MARK: - AccountTestIdentity

@MainActor private final class AccountTestIdentity: BrowserAppleIdentityProviding {
    var requests = 0
    var started = AccountTestGate()
    var release: AccountTestGate?

    func requestIdentityToken() async -> String {
        requests += 1
        started.open()
        await release?.wait()
        return "apple-token"
    }
}

// MARK: - AccountTestAuthenticator

@MainActor private final class AccountTestAuthenticator: BrowserAppleAuthenticating {
    let baseURL = URL(string: "https://sync.example")!
    var response = accountSession()
    var tokens = [String]()
    var deviceIdentities = [BrowserSyncDeviceIdentity]()
    let started = AccountTestGate()
    var release: AccountTestGate?

    func authenticateWithApple(
        identityToken: String,
        deviceName: String,
        devicePlatform: String,
    ) async -> BrowserAuthSession {
        tokens.append(identityToken)
        deviceIdentities.append(.init(name: deviceName, platform: devicePlatform))
        started.open()
        await release?.wait()
        return response
    }
}

// MARK: - AccountTestAuthStorage

@MainActor private final class AccountTestAuthStorage: BrowserSyncAuthSessionStoring {
    var session: BrowserAuthSession?
    var saved = [BrowserAuthSession]()
    var saveError: Error?
    var clearError: Error?
    var onClear: () -> Void = {}

    func loadSession() -> BrowserAuthSession? { session }

    func saveSession(_ session: BrowserAuthSession) throws {
        if let saveError {
            throw saveError
        }
        saved.append(session)
        self.session = session
    }

    func clearSession() throws {
        onClear()
        if let clearError {
            throw clearError
        }
        session = nil
    }
}

// MARK: - AccountTestSyncController

@MainActor private final class AccountTestSyncController: BrowserAccountSyncControlling {
    var state = BrowserSyncBindingState.needsConsent
    var enabledSessions = [BrowserAuthSession]()
    var resumedSessions = [BrowserAuthSession]()
    var sessionChanges = [BrowserAuthSession?]()
    var suspensions = 0
    var signOuts = 0
    var signInRequired = false
    var completedAuthentications = [BrowserAuthSession]()
    var suspendError: Error?

    func requiresSignIn() -> Bool { signInRequired }

    func completeAuthentication(for session: BrowserAuthSession) throws {
        guard state != .differentAccount else { throw BrowserSyncAccountError.differentAccount }
        completedAuthentications.append(session)
        signInRequired = false
        if state == .paused {
            state = .enabled
        }
    }

    func signOut() throws {
        signOuts += 1
        if let suspendError {
            throw suspendError
        }
        signInRequired = true
        if state == .enabled {
            state = .paused
        }
    }

    func bindingState(for _: BrowserAuthSession) -> BrowserSyncBindingState { state }

    func enableSync(for session: BrowserAuthSession) throws {
        guard !signInRequired else { throw BrowserSyncAccountError.unavailable }
        enabledSessions.append(session)
        state = .enabled
    }

    func resumeSync(for session: BrowserAuthSession) throws {
        guard !signInRequired else { throw BrowserSyncAccountError.unavailable }
        resumedSessions.append(session)
        state = .enabled
    }

    func suspendSync() throws {
        suspensions += 1
        if let suspendError {
            throw suspendError
        }
        state = .paused
    }

    func accountSessionDidChange(_ session: BrowserAuthSession?) { sessionChanges.append(session) }
}

// MARK: - AccountTestGate

@MainActor private final class AccountTestGate {
    // MARK: Private

    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

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
}

// MARK: - AccountTestError

private enum AccountTestError: Error { case failure }

private func accountSession(serverURL: URL? = URL(string: "https://sync.example")!) -> BrowserAuthSession {
    BrowserAuthSession(
        accessToken: "token-a",
        userID: "account-a",
        userEmail: "a@example.test",
        deviceID: "device-a",
        serverURL: serverURL,
    )
}

private func accountTestURL(_ value: String) -> URL { URL(string: value)! }
