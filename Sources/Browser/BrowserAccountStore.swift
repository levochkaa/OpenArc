// BrowserAccountStore.swift

import Combine
import Foundation

// MARK: - BrowserAppleIdentityProviding

@MainActor protocol BrowserAppleIdentityProviding: AnyObject {
    func requestIdentityToken() async throws -> String
}

// MARK: - BrowserAppleAuthenticating

@MainActor protocol BrowserAppleAuthenticating: AnyObject {
    var baseURL: URL { get }
    func authenticateWithApple(
        identityToken: String, deviceName: String, devicePlatform: String,
    ) async throws -> BrowserAuthSession
}

// MARK: - BrowserRemoteSyncClient + BrowserAppleAuthenticating

extension BrowserRemoteSyncClient: BrowserAppleAuthenticating {}

// MARK: - BrowserAppleSignInError

enum BrowserAppleSignInError: Error {
    case missingIdentityToken
}

// MARK: - BrowserAccountStore

@MainActor final class BrowserAccountStore: ObservableObject {
    // MARK: Internal

    @Published private(set) var session: BrowserAuthSession?
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastError: String?
    @Published private(set) var bindingState: BrowserSyncBindingState?

    // MARK: Private

    private let syncClient: (any BrowserAppleAuthenticating)?
    private let authSessionStore: any BrowserSyncAuthSessionStoring
    private let syncCoordinator: (any BrowserAccountSyncControlling)?
    private let appleSignInService: any BrowserAppleIdentityProviding
    private let deviceIdentity: BrowserSyncDeviceIdentity
    private var signInGeneration: UInt64 = 0

    var isConfigured: Bool { syncClient != nil && syncCoordinator != nil }
    var isAuthenticated: Bool { session != nil }
    var unavailableMessage: String {
        syncClient == nil ? BrowserStrings.syncAccountServerNotConfigured : BrowserStrings.syncAccountUnavailable
    }

    init(
        syncClient: (any BrowserAppleAuthenticating)?,
        authSessionStore: any BrowserSyncAuthSessionStoring,
        syncCoordinator: (any BrowserAccountSyncControlling)?,
        appleSignInService: any BrowserAppleIdentityProviding,
        deviceIdentity: BrowserSyncDeviceIdentity,
    ) {
        self.syncClient = syncClient
        self.authSessionStore = authSessionStore
        self.syncCoordinator = syncCoordinator
        self.appleSignInService = appleSignInService
        self.deviceIdentity = deviceIdentity
        guard let syncClient, let syncCoordinator else { return }
        do {
            // A failed Keychain removal must not silently sign back in at launch.
            guard try !syncCoordinator.requiresSignIn() else {
                self.lastError = BrowserStrings.syncAccountSignInAgain
                return
            }
            guard let cached = authSessionStore.loadSession() else { return }
            guard cached.belongs(to: syncClient.baseURL) else {
                self.lastError = BrowserStrings.syncAccountSignInAgain
                return
            }
            let state = try syncCoordinator.bindingState(for: cached)
            self.session = cached
            self.bindingState = state
            if state != .paused {
                syncCoordinator.accountSessionDidChange(cached)
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func signInWithApple() async {
        guard !isSigningIn else { return }
        guard let syncClient, let syncCoordinator else {
            lastError = unavailableMessage
            return
        }
        isSigningIn = true
        lastError = nil
        signInGeneration &+= 1
        let attempt = signInGeneration
        defer {
            if attempt == signInGeneration {
                isSigningIn = false
            }
        }
        do {
            let identityToken = try await appleSignInService.requestIdentityToken()
            guard attempt == signInGeneration else { return }
            let session = try await syncClient.authenticateWithApple(
                identityToken: identityToken,
                deviceName: deviceIdentity.name,
                devicePlatform: deviceIdentity.platform,
            )
            guard attempt == signInGeneration else { return }
            guard session.belongs(to: syncClient.baseURL) else { throw BrowserSyncAccountError.serverChanged }
            let state = try syncCoordinator.bindingState(for: session)
            guard state != .differentAccount else { throw BrowserSyncAccountError.differentAccount }
            try authSessionStore.saveSession(session)
            try syncCoordinator.completeAuthentication(for: session)
            self.session = session
            bindingState = try syncCoordinator.bindingState(for: session)
            syncCoordinator.accountSessionDidChange(session)
        } catch {
            guard attempt == signInGeneration else { return }
            lastError = error.localizedDescription
        }
    }

    func enableSync() {
        guard let session, let syncCoordinator else { return }
        do {
            try syncCoordinator.enableSync(for: session)
            bindingState = try syncCoordinator.bindingState(for: session)
            lastError = nil
            syncCoordinator.accountSessionDidChange(session)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Invalidates both the Apple request and a dispatched server exchange. The
    /// platform provider owns dismissing its authorization presentation.
    func cancelSignIn() {
        signInGeneration &+= 1
        isSigningIn = false
    }

    func pauseSync() {
        guard let session, let syncCoordinator, bindingState == .enabled else { return }
        cancelSignIn()
        do {
            try syncCoordinator.suspendSync()
            bindingState = try syncCoordinator.bindingState(for: session)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resumeSync() {
        guard let session, let syncCoordinator else { return }
        do {
            try syncCoordinator.resumeSync(for: session)
            bindingState = try syncCoordinator.bindingState(for: session)
            lastError = nil
            syncCoordinator.accountSessionDidChange(session)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        cancelSignIn()
        syncCoordinator?.accountSessionDidChange(nil)
        session = nil
        bindingState = nil
        lastError = nil
        // Require fresh authentication before removing credentials; preserve ownership and cursor.
        // Attempt both writes so either successful operation prevents auto-resume.
        var failures = [String]()
        do {
            try syncCoordinator?.signOut()
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            try authSessionStore.clearSession()
        } catch {
            failures.append(error.localizedDescription)
        }
        if !failures.isEmpty {
            lastError = failures.joined(separator: "\n")
        }
    }
}
