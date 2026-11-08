// BrowserAccountStore.swift

import Combine
import CryptoKit
import Foundation
import Security

// MARK: - BrowserAppleIdentityProviding

/// Native Sign in with Apple, which only apps from the App Store can use.
@MainActor protocol BrowserAppleIdentityProviding: AnyObject {
    func requestIdentityToken() async throws -> String
}

// MARK: - BrowserWebSignInPresenting

/// Runs a provider's sign-in page and returns the URL it ends at, for
/// example an ASWebAuthenticationSession.
@MainActor protocol BrowserWebSignInPresenting: AnyObject {
    /// Throws `BrowserWebSignInError.cancelled` when the user closes it.
    func signIn(at url: URL, callbackScheme: String) async throws -> URL
    func cancel()
}

// MARK: - BrowserSyncSuccessRelay

/// Carries a sync round trip's success from the sync service to the account
/// store, which is made after it.
@MainActor final class BrowserSyncSuccessRelay {
    weak var accountStore: BrowserAccountStore?
}

// MARK: - BrowserWebSignInError

enum BrowserWebSignInError: Error, Equatable {
    case cancelled
}

// MARK: - BrowserAccountAuthenticating

@MainActor protocol BrowserAccountAuthenticating: AnyObject {
    var baseURL: URL { get }
    func authenticateWithApple(
        identityToken: String, deviceName: String, devicePlatform: String,
    ) async throws -> BrowserAuthSession
    func signInProviders() async throws -> [BrowserAccountProvider]
    func exchangeWebSignIn(
        code: String, codeVerifier: String, deviceName: String, devicePlatform: String,
    ) async throws -> BrowserAuthSession
    func startEmailSignIn(email: String) async throws -> BrowserEmailSignInCode
    func verifyEmailSignIn(
        email: String, code: String, deviceName: String, devicePlatform: String,
    ) async throws -> BrowserAuthSession
}

/// Clients that only offer native Sign in with Apple, like test doubles.
extension BrowserAccountAuthenticating {
    func signInProviders() -> [BrowserAccountProvider] { [.apple] }

    func exchangeWebSignIn(
        code _: String, codeVerifier _: String, deviceName _: String, devicePlatform _: String,
    ) throws -> BrowserAuthSession {
        throw BrowserAccountSignInError.notConfigured
    }

    func startEmailSignIn(email _: String) throws -> BrowserEmailSignInCode {
        throw BrowserAccountSignInError.notConfigured
    }

    func verifyEmailSignIn(
        email _: String, code _: String, deviceName _: String, devicePlatform _: String,
    ) throws -> BrowserAuthSession {
        throw BrowserAccountSignInError.notConfigured
    }
}

// MARK: - BrowserRemoteSyncClient + BrowserAccountAuthenticating

extension BrowserRemoteSyncClient: BrowserAccountAuthenticating {}

// MARK: - BrowserAccountProvider

/// A sign-in method the server offers.
enum BrowserAccountProvider: String, CaseIterable {
    case apple
    case google
    case github
    case email

    // MARK: Internal

    /// Signs in through the provider's web page rather than a code by email.
    var isWeb: Bool { self != .email }
}

// MARK: - BrowserEmailSignInCode

/// A code the server emailed, in seconds from when it answered.
struct BrowserEmailSignInCode: Equatable {
    let expiresIn: Int
    let resendIn: Int
}

// MARK: - BrowserEmailSignInRequest

/// The email a code was sent to, while the user types it.
struct BrowserEmailSignInRequest: Equatable {
    let email: String
    let resendAt: Date
}

// MARK: - BrowserSignInChallenge

/// PKCE (RFC 7636): only the app that started a web sign-in, which keeps the
/// verifier, can exchange the code the browser comes back with.
struct BrowserSignInChallenge: Equatable {
    // MARK: Internal

    let verifier: String

    /// Base64url SHA-256 of the verifier, without padding.
    var challenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 random bytes, which encode to 43 characters.
    static func random() -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No random bytes for a sign-in challenge")
        return Self(verifier: base64URL(Data(bytes)))
    }

    // MARK: Private

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - BrowserAccountSignInError

enum BrowserAccountSignInError: LocalizedError, Equatable {
    case notConfigured
    case tooManyRequests
    case invalidEmail
    case invalidCode
    case signInExpired
    case providerFailed
    case server(statusCode: Int, message: String?)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .notConfigured: BrowserStrings.syncAccountMethodUnavailable
        case .tooManyRequests: BrowserStrings.syncAccountTooManyRequests
        case .invalidEmail: BrowserStrings.syncAccountInvalidEmail
        case .invalidCode: BrowserStrings.syncAccountInvalidCode
        case .signInExpired: BrowserStrings.syncAccountSignInExpired
        case .providerFailed: BrowserStrings.syncAccountProviderFailed
        case .server(_, let message): message ?? BrowserStrings.syncAccountProviderFailed
        }
    }
}

// MARK: - BrowserAppleSignInError

enum BrowserAppleSignInError: Error {
    case missingIdentityToken
}

// MARK: - BrowserAccountStore

@MainActor final class BrowserAccountStore: ObservableObject {
    // MARK: Private

    /// One sign-in, superseded when another starts or the user cancels.
    private struct SignInAttempt {
        let generation: UInt64
        let client: any BrowserAccountAuthenticating
        let coordinator: any BrowserAccountSyncControlling
    }

    // MARK: Internal

    /// The scheme a web sign-in ends at: `openarc-auth://callback?code=…`.
    static let webSignInCallbackScheme = "openarc-auth"

    /// The provider's sign-in page, which starts a web sign-in.
    static let officialAPIHost = "api.openarc.su"
    static let officialSignInHost = "openarc.su"

    @Published private(set) var session: BrowserAuthSession?
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastError: String?
    @Published private(set) var bindingState: BrowserSyncBindingState?
    /// The sign-in methods the server offers, once loaded.
    @Published private(set) var providers: [BrowserAccountProvider]?
    /// The email a code was sent to, while the user types the code.
    @Published private(set) var emailSignIn: BrowserEmailSignInRequest?
    /// Whether the server will send another code to `emailSignIn`.
    @Published private(set) var canResendEmailCode = false
    /// When this run last finished a sync round trip with the server.
    @Published private(set) var lastSyncDate: Date?

    private let syncClient: (any BrowserAccountAuthenticating)?
    private let authSessionStore: any BrowserSyncAuthSessionStoring
    private let syncCoordinator: (any BrowserAccountSyncControlling)?
    private let appleSignInService: (any BrowserAppleIdentityProviding)?
    private let webSignInService: (any BrowserWebSignInPresenting)?
    private let deviceIdentity: BrowserSyncDeviceIdentity
    /// Signing in turns sync on for the profile without asking.
    private let enablesSyncOnSignIn: Bool
    private var signInGeneration: UInt64 = 0
    private var resendTask: Task<Void, Never>?

    var isConfigured: Bool { syncClient != nil && syncCoordinator != nil }
    var isAuthenticated: Bool { session != nil }
    var unavailableMessage: String {
        syncClient == nil ? BrowserStrings.syncAccountServerNotConfigured : BrowserStrings.syncAccountUnavailable
    }

    init(
        syncClient: (any BrowserAccountAuthenticating)?,
        authSessionStore: any BrowserSyncAuthSessionStoring,
        syncCoordinator: (any BrowserAccountSyncControlling)?,
        appleSignInService: (any BrowserAppleIdentityProviding)? = nil,
        webSignInService: (any BrowserWebSignInPresenting)? = nil,
        deviceIdentity: BrowserSyncDeviceIdentity,
        enablesSyncOnSignIn: Bool = false,
    ) {
        self.enablesSyncOnSignIn = enablesSyncOnSignIn
        self.syncClient = syncClient
        self.authSessionStore = authSessionStore
        self.syncCoordinator = syncCoordinator
        self.appleSignInService = appleSignInService
        self.webSignInService = webSignInService
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
            var state = try syncCoordinator.bindingState(for: cached)
            if enablesSyncOnSignIn, state == .needsConsent {
                try syncCoordinator.enableSync(for: cached)
                state = try syncCoordinator.bindingState(for: cached)
            }
            self.session = cached
            self.bindingState = state
            if state != .paused {
                syncCoordinator.accountSessionDidChange(cached)
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    static func webSignInURL(
        baseURL: URL,
        provider: BrowserAccountProvider,
        challenge: BrowserSignInChallenge,
    ) -> URL? {
        // The system asks before opening a sign-in page and names its host:
        // OpenArc's own server starts at openarc.su, which sends it on to the API.
        let start = baseURL.host == officialAPIHost
            ? URL(string: "https://\(officialSignInHost)/signin/\(provider.rawValue)")
            : baseURL.appending(path: "v1/auth/web/\(provider.rawValue)/start")
        guard let start else { return nil }
        var components = URLComponents(url: start, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "code_challenge", value: challenge.challenge)]
        return components?.url
    }

    /// The one-time code from `openarc-auth://callback?code=…`. A refusal on
    /// the provider's page ends the sign-in like closing it.
    static func code(fromWebSignInCallback url: URL) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return code
        }
        switch items.first(where: { $0.name == "error" })?.value {
        case "access_denied": throw BrowserWebSignInError.cancelled
        case "expired": throw BrowserAccountSignInError.signInExpired
        default: throw BrowserAccountSignInError.providerFailed
        }
    }

    func loadProviders() async {
        guard let syncClient else { return }
        do {
            providers = try await syncClient.signInProviders()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Native Sign in with Apple, on iPhone and iPad.
    func signInWithApple() async {
        guard let attempt = beginSignIn() else { return }
        defer { endSignIn(attempt) }
        do {
            guard let appleSignInService else { throw BrowserAccountSignInError.notConfigured }
            let identityToken = try await appleSignInService.requestIdentityToken()
            guard isCurrent(attempt) else { return }
            let session = try await attempt.client.authenticateWithApple(
                identityToken: identityToken,
                deviceName: deviceIdentity.name,
                devicePlatform: deviceIdentity.platform,
            )
            guard isCurrent(attempt) else { return }
            try completeSignIn(with: session, attempt: attempt)
        } catch {
            fail(error, attempt: attempt)
        }
    }

    /// Signs in on the provider's web page, then exchanges the code it ends
    /// with for a session.
    func signIn(with provider: BrowserAccountProvider) async {
        guard provider.isWeb, let attempt = beginSignIn() else { return }
        defer { endSignIn(attempt) }
        do {
            let challenge = BrowserSignInChallenge.random()
            guard let webSignInService,
                  let url = Self.webSignInURL(baseURL: attempt.client.baseURL, provider: provider, challenge: challenge)
            else { throw BrowserAccountSignInError.notConfigured }
            let callback = try await webSignInService.signIn(at: url, callbackScheme: Self.webSignInCallbackScheme)
            guard isCurrent(attempt) else { return }
            let session = try await attempt.client.exchangeWebSignIn(
                code: Self.code(fromWebSignInCallback: callback),
                codeVerifier: challenge.verifier,
                deviceName: deviceIdentity.name,
                devicePlatform: deviceIdentity.platform,
            )
            guard isCurrent(attempt) else { return }
            try completeSignIn(with: session, attempt: attempt)
        } catch {
            fail(error, attempt: attempt)
        }
    }

    /// Asks the server to email a sign-in code, then waits for it.
    func requestEmailCode(email: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@") else {
            lastError = BrowserStrings.syncAccountInvalidEmail
            return
        }
        guard let attempt = beginSignIn() else { return }
        defer { endSignIn(attempt) }
        do {
            let code = try await attempt.client.startEmailSignIn(email: email)
            guard isCurrent(attempt) else { return }
            showEmailCodeEntry(email: email, resendIn: code.resendIn)
        } catch {
            fail(error, attempt: attempt)
        }
    }

    func signIn(email: String, code: String) async {
        // Codes pasted from the email may carry spaces.
        let code = code.filter { $0.isASCII && $0.isNumber }
        guard code.count == 6 else {
            lastError = BrowserStrings.syncAccountInvalidCode
            return
        }
        guard let attempt = beginSignIn() else { return }
        defer { endSignIn(attempt) }
        do {
            let session = try await attempt.client.verifyEmailSignIn(
                email: email,
                code: code,
                deviceName: deviceIdentity.name,
                devicePlatform: deviceIdentity.platform,
            )
            guard isCurrent(attempt) else { return }
            try completeSignIn(with: session, attempt: attempt)
        } catch {
            fail(error, attempt: attempt)
        }
    }

    /// Back to entering an email.
    func cancelEmailSignIn() {
        cancelSignIn()
        clearEmailSignIn()
        lastError = nil
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

    /// Invalidates the sign-in request and a dispatched server exchange. The
    /// platform provider owns dismissing its authorization presentation.
    func cancelSignIn() {
        signInGeneration &+= 1
        isSigningIn = false
        webSignInService?.cancel()
    }

    /// The Sync switch: on adopts or resumes the profile, off pauses it.
    func setSyncEnabled(_ enabled: Bool) {
        switch (enabled, bindingState) {
        case (true, .needsConsent): enableSync()
        case (true, .paused): resumeSync()
        case (false, .enabled): pauseSync()
        default: break
        }
    }

    func syncDidSucceed(at date: Date = Date()) {
        lastSyncDate = date
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
        clearEmailSignIn()
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

    /// Nil while another sign-in runs or sync is unavailable.
    private func beginSignIn() -> SignInAttempt? {
        guard !isSigningIn else { return nil }
        guard let syncClient, let syncCoordinator else {
            lastError = unavailableMessage
            return nil
        }
        isSigningIn = true
        lastError = nil
        signInGeneration &+= 1
        return SignInAttempt(generation: signInGeneration, client: syncClient, coordinator: syncCoordinator)
    }

    private func isCurrent(_ attempt: SignInAttempt) -> Bool {
        attempt.generation == signInGeneration
    }

    private func endSignIn(_ attempt: SignInAttempt) {
        if isCurrent(attempt) {
            isSigningIn = false
        }
    }

    /// What every sign-in method does with the session the server issued.
    private func completeSignIn(with session: BrowserAuthSession, attempt: SignInAttempt) throws {
        guard session.belongs(to: attempt.client.baseURL) else { throw BrowserSyncAccountError.serverChanged }
        let state = try attempt.coordinator.bindingState(for: session)
        guard state != .differentAccount else { throw BrowserSyncAccountError.differentAccount }
        try authSessionStore.saveSession(session)
        try attempt.coordinator.completeAuthentication(for: session)
        self.session = session
        bindingState = try attempt.coordinator.bindingState(for: session)
        if enablesSyncOnSignIn, bindingState == .needsConsent {
            // Signing in is the consent; a profile that cannot start syncing
            // still signs in and offers Enable.
            do {
                try attempt.coordinator.enableSync(for: session)
                bindingState = try attempt.coordinator.bindingState(for: session)
            } catch {
                lastError = error.localizedDescription
            }
        }
        attempt.coordinator.accountSessionDidChange(session)
        clearEmailSignIn()
    }

    /// Closing the sign-in page is not an error.
    private func fail(_ error: Error, attempt: SignInAttempt) {
        guard isCurrent(attempt), error as? BrowserWebSignInError != .cancelled else { return }
        lastError = error.localizedDescription
    }

    private func showEmailCodeEntry(email: String, resendIn: Int) {
        emailSignIn = BrowserEmailSignInRequest(
            email: email,
            resendAt: Date().addingTimeInterval(TimeInterval(max(resendIn, 0))),
        )
        resendTask?.cancel()
        canResendEmailCode = resendIn <= 0
        guard resendIn > 0 else { return }
        resendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(resendIn))
            guard !Task.isCancelled else { return }
            self?.canResendEmailCode = true
        }
    }

    private func clearEmailSignIn() {
        resendTask?.cancel()
        resendTask = nil
        emailSignIn = nil
        canResendEmailCode = false
    }
}
