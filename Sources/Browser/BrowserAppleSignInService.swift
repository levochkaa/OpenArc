import AppKit
import AuthenticationServices
import Foundation

// MARK: - BrowserAppleSignInService

@MainActor final class BrowserAppleSignInService: NSObject {
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
        syncClient: BrowserRemoteSyncClient?,
        authSessionStore: BrowserAuthSessionStore,
        appleSignInService: BrowserAppleSignInService? = nil
    ) {
        self.syncClient = syncClient
        self.authSessionStore = authSessionStore
        self.appleSignInService = appleSignInService ?? BrowserAppleSignInService()
        self.session = authSessionStore.loadSession()
    }

    // MARK: Internal

    @Published private(set) var session: BrowserAuthSession?
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastError: String?

    var isConfigured: Bool {
        syncClient != nil
    }

    var isAuthenticated: Bool {
        session != nil
    }

    func signInWithApple() async {
        guard let syncClient else {
            lastError = BrowserStrings.syncAccountServerNotConfigured
            return
        }

        isSigningIn = true
        lastError = nil

        do {
            let identityToken = try await appleSignInService.requestIdentityToken()
            let session = try await syncClient.authenticateWithApple(identityToken: identityToken)
            try authSessionStore.saveSession(session)
            self.session = session
        } catch {
            lastError = error.localizedDescription
        }

        isSigningIn = false
    }

    func signOut() {
        authSessionStore.clearSession()
        session = nil
        lastError = nil
    }

    // MARK: Private

    private let syncClient: BrowserRemoteSyncClient?
    private let authSessionStore: BrowserAuthSessionStore
    private let appleSignInService: BrowserAppleSignInService
}
