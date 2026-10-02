import AppKit
import AuthenticationServices
import Foundation

// MARK: - BrowserAppleIdentityProviding

@MainActor protocol BrowserAppleIdentityProviding: AnyObject {
    func requestIdentityToken() async throws -> String
}

// MARK: - BrowserAppleAuthenticating

@MainActor protocol BrowserAppleAuthenticating: AnyObject {
    var baseURL: URL { get }
    func authenticateWithApple(
        identityToken: String, deviceName: String, devicePlatform: String
    ) async throws -> BrowserAuthSession
}

// MARK: - BrowserRemoteSyncClient + BrowserAppleAuthenticating

extension BrowserRemoteSyncClient: BrowserAppleAuthenticating {}

// MARK: - BrowserAppleSignInService

@MainActor final class BrowserAppleSignInService: NSObject, BrowserAppleIdentityProviding {
    // MARK: Internal

    func requestIdentityToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.email, .fullName]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: Private

    private var continuation: CheckedContinuation<String, Error>?
}

// MARK: ASAuthorizationControllerDelegate

extension BrowserAppleSignInService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller _: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                continuation?.resume(throwing: BrowserAppleSignInError.missingIdentityToken)
                continuation = nil
                return
            }

            continuation?.resume(returning: identityToken)
            continuation = nil
        }
    }

    nonisolated func authorizationController(
        controller _: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: ASAuthorizationControllerPresentationContextProviding

extension BrowserAppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - BrowserAppleSignInError

enum BrowserAppleSignInError: Error {
    case missingIdentityToken
}

// MARK: - BrowserAccountStore

@MainActor final class BrowserAccountStore: ObservableObject {
    // MARK: Lifecycle

    init(
        syncClient: (any BrowserAppleAuthenticating)?,
        authSessionStore: any BrowserSyncAuthSessionStoring,
        syncCoordinator: (any BrowserAccountSyncControlling)?,
        appleSignInService: (any BrowserAppleIdentityProviding)? = nil
    ) {
        self.syncClient = syncClient
        self.authSessionStore = authSessionStore
        self.syncCoordinator = syncCoordinator
        self.appleSignInService = appleSignInService ?? BrowserAppleSignInService()
        guard let cached = authSessionStore.loadSession() else { return }
        guard let syncClient, let syncCoordinator else { return }
        guard cached.belongs(to: syncClient.baseURL) else {
            self.lastError = BrowserStrings.syncAccountSignInAgain
            return
        }
        do {
            let state = try syncCoordinator.bindingState(for: cached)
            // A failed Keychain removal must not silently sign back in at launch.
            guard state != .paused else {
                self.lastError = BrowserStrings.syncAccountSignInAgain
                return
            }
            self.session = cached
            self.bindingState = state
            syncCoordinator.accountSessionDidChange(cached)
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    // MARK: Internal

    @Published private(set) var session: BrowserAuthSession?
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastError: String?
    @Published private(set) var bindingState: BrowserSyncBindingState?

    var isConfigured: Bool { syncClient != nil && syncCoordinator != nil }
    var isAuthenticated: Bool { session != nil }
    var unavailableMessage: String {
        syncClient == nil ? BrowserStrings.syncAccountServerNotConfigured : BrowserStrings.syncAccountUnavailable
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
        defer { isSigningIn = false }
        do {
            let identityToken = try await appleSignInService.requestIdentityToken()
            guard attempt == signInGeneration else { return }
            let session = try await syncClient.authenticateWithApple(
                identityToken: identityToken,
                deviceName: Host.current().localizedName ?? "Mac",
                devicePlatform: "macOS"
            )
            guard attempt == signInGeneration else { return }
            guard session.belongs(to: syncClient.baseURL) else { throw BrowserSyncAccountError.serverChanged }
            let state = try syncCoordinator.bindingState(for: session)
            guard state != .differentAccount else { throw BrowserSyncAccountError.differentAccount }
            try authSessionStore.saveSession(session)
            if state == .paused {
                try syncCoordinator.resumeSync(for: session)
            }
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

    func signOut() {
        signInGeneration &+= 1
        syncCoordinator?.accountSessionDidChange(nil)
        session = nil
        bindingState = nil
        lastError = nil
        // Pause durably before removing credentials; preserve ownership and cursor.
        // Attempt both writes so either successful operation prevents auto-resume.
        var failures = [String]()
        do { try syncCoordinator?.suspendSync() }
        catch { failures.append(error.localizedDescription) }
        do { try authSessionStore.clearSession() }
        catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty {
            lastError = failures.joined(separator: "\n")
        }
    }

    // MARK: Private

    private let syncClient: (any BrowserAppleAuthenticating)?
    private let authSessionStore: any BrowserSyncAuthSessionStoring
    private let syncCoordinator: (any BrowserAccountSyncControlling)?
    private let appleSignInService: any BrowserAppleIdentityProviding
    private var signInGeneration: UInt64 = 0
}
