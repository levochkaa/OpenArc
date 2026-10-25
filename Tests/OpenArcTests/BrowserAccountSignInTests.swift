// BrowserAccountSignInTests.swift

import CryptoKit
import Foundation
import Synchronization
import Testing

// MARK: - BrowserAccountSignInTests

@MainActor struct BrowserAccountSignInTests {
    @Test func challengeIsTheRFC7636VectorAndRandomVerifiersAreURLSafe() {
        let challenge = BrowserSignInChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(challenge.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

        let random = BrowserSignInChallenge.random()
        #expect(random.verifier.count == 43)
        #expect(random.verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) })
        #expect(BrowserSignInChallenge.random() != random)
    }

    @Test func webSignInStartsAtTheProvidersPageAndReadsItsCallback() throws {
        let challenge = BrowserSignInChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = try #require(BrowserAccountStore.webSignInURL(
            baseURL: signInTestURL("https://sync.example/"),
            provider: .github,
            challenge: challenge,
        ))
        #expect(url.absoluteString
            ==
            "https://sync.example/v1/auth/web/github/start?code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

        #expect(try BrowserAccountStore.code(fromWebSignInCallback: signInTestURL("openarc-auth://callback?code=abc"))
            == "abc")
        #expect(throws: BrowserWebSignInError.cancelled) {
            try BrowserAccountStore
                .code(fromWebSignInCallback: signInTestURL("openarc-auth://callback?error=access_denied"))
        }
        #expect(throws: BrowserAccountSignInError.signInExpired) {
            try BrowserAccountStore.code(fromWebSignInCallback: signInTestURL("openarc-auth://callback?error=expired"))
        }
        #expect(throws: BrowserAccountSignInError.providerFailed) {
            try BrowserAccountStore
                .code(fromWebSignInCallback: signInTestURL("openarc-auth://callback?error=provider_error"))
        }
    }

    @Test func providersComeFromTheServerAndWebOnesGetButtons() async {
        let f = SignInFixture()
        f.client.providers = [.google, .email, .apple]
        #expect(f.store.providers == nil)
        await f.store.loadProviders()
        #expect(f.store.providers == [.google, .email, .apple])
        #expect(f.store.providers?.filter(\.isWeb) == [.google, .apple])
    }

    @Test func webSignInExchangesTheCodeWithTheVerifierOfItsChallenge() async throws {
        let f = SignInFixture()
        f.web.callback = signInTestURL("openarc-auth://callback?code=one-time")
        await f.store.signIn(with: .google)

        let opened = try #require(f.web.opened.first)
        #expect(opened.scheme == "openarc-auth")
        #expect(opened.url.path == "/v1/auth/web/google/start")
        let exchange = try #require(f.client.exchanges.first)
        #expect(exchange.code == "one-time")
        let challenge = URLComponents(url: opened.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "code_challenge" }?
            .value
        #expect(challenge == BrowserSignInChallenge(verifier: exchange.verifier).challenge)
        #expect(exchange.device == .init(name: "Test Mac", platform: "macOS"))
        #expect(f.store.session == f.client.session)
        #expect(f.auth.saved == [f.client.session])
        #expect(f.sync.sessionChanges.last == f.client.session)
        #expect(!f.store.isSigningIn && f.store.lastError == nil)
    }

    @Test func webSignInErrorsShowAMessageButClosingThePageDoesNot() async {
        let f = SignInFixture()
        f.web.callback = signInTestURL("openarc-auth://callback?error=provider_error")
        await f.store.signIn(with: .github)
        #expect(f.store.lastError == BrowserAccountSignInError.providerFailed.errorDescription)
        #expect(f.client.exchanges.isEmpty)

        f.web.callback = nil
        await f.store.signIn(with: .apple)
        #expect(f.store.lastError == nil)
        #expect(!f.store.isSigningIn && f.store.session == nil)

        f.web.callback = signInTestURL("openarc-auth://callback?error=access_denied")
        await f.store.signIn(with: .google)
        #expect(f.store.lastError == nil && f.client.exchanges.isEmpty)
    }

    @Test func emailCodeSignInWaitsForTheCodeAndKeepsTheEmailOnAWrongOne() async {
        let f = SignInFixture()
        await f.store.requestEmailCode(email: " me@example.test ")
        #expect(f.client.codeRequests == ["me@example.test"])
        #expect(f.store.emailSignIn?.email == "me@example.test")
        #expect(!f.store.canResendEmailCode)

        f.client.startError = .tooManyRequests
        await f.store.requestEmailCode(email: "me@example.test")
        #expect(f.store.lastError == BrowserAccountSignInError.tooManyRequests.errorDescription)
        #expect(f.store.emailSignIn?.email == "me@example.test")

        f.client.verifyError = .invalidCode
        await f.store.signIn(email: "me@example.test", code: "000 000")
        #expect(f.client.verifications.last == "000000")
        #expect(f.store.lastError == BrowserAccountSignInError.invalidCode.errorDescription)
        #expect(f.store.emailSignIn != nil && f.store.session == nil)

        f.client.verifyError = nil
        await f.store.signIn(email: "me@example.test", code: "123456")
        #expect(f.store.session == f.client.session)
        #expect(f.store.emailSignIn == nil && f.store.lastError == nil)
    }

    @Test func malformedEmailsAndCodesNeverReachTheServer() async {
        let f = SignInFixture()
        await f.store.requestEmailCode(email: "not an email")
        await f.store.signIn(email: "me@example.test", code: "12345")
        #expect(f.client.codeRequests.isEmpty && f.client.verifications.isEmpty)
        #expect(f.store.lastError == BrowserAccountSignInError.invalidCode.errorDescription)
    }

    @Test func clientReadsCreatedSessionsAndMapsSignInErrors() async throws {
        let baseURL = signInTestURL("https://sign-in.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SignInURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try BrowserRemoteSyncClient(configuration: #require(.init(baseURL: baseURL)), session: session)
        let sessionJSON = """
        {"accessToken":"token","tokenType":"Bearer","expiresIn":2592000,
         "user":{"id":"user","email":null},
         "device":{"id":"device","name":"Mac","platform":"macOS","lastSeenAt":"2026-10-25T12:00:00.123Z"}}
        """
        SignInURLProtocol.respond(201, sessionJSON)
        let apple = try await client.authenticateWithApple(
            identityToken: "t",
            deviceName: "Mac",
            devicePlatform: "macOS",
        )
        #expect(apple == BrowserAuthSession(
            accessToken: "token", userID: "user", userEmail: nil, deviceID: "device", serverURL: baseURL,
        ))

        SignInURLProtocol.respond(201, sessionJSON)
        let web = try await client.exchangeWebSignIn(
            code: "c", codeVerifier: String(repeating: "v", count: 43), deviceName: "Mac", devicePlatform: "macOS",
        )
        #expect(web.deviceID == "device")
        let request = try #require(SignInURLProtocol.lastRequest)
        #expect(request.url?.path == "/v1/auth/web/exchange" && request.httpMethod == "POST")

        SignInURLProtocol.respond(200, #"{"providers":["github","email"]}"#)
        #expect(try await client.signInProviders() == [.github, .email])

        SignInURLProtocol.respond(202, #"{"expiresIn":600,"resendIn":30}"#)
        #expect(try await client.startEmailSignIn(email: "me@example.test") == .init(expiresIn: 600, resendIn: 30))

        SignInURLProtocol.respond(429, #"{"statusCode":429,"message":"Slow down"}"#)
        await #expect(throws: BrowserAccountSignInError.tooManyRequests) {
            try await client.startEmailSignIn(email: "me@example.test")
        }
        SignInURLProtocol.respond(401, #"{"statusCode":401,"message":"Invalid code"}"#)
        await #expect(throws: BrowserAccountSignInError.invalidCode) {
            try await client.verifyEmailSignIn(
                email: "me@example.test", code: "123456", deviceName: "Mac", devicePlatform: "macOS",
            )
        }
        SignInURLProtocol.respond(404, #"{"statusCode":404,"message":"Not configured"}"#)
        await #expect(throws: BrowserAccountSignInError.notConfigured) {
            try await client.exchangeWebSignIn(
                code: "c", codeVerifier: String(repeating: "v", count: 43), deviceName: "Mac", devicePlatform: "macOS",
            )
        }
    }
}

// MARK: - SignInFixture

@MainActor private final class SignInFixture {
    // MARK: Internal

    let client = SignInTestClient()
    let web = SignInTestWebPresenter()
    let auth = SignInTestAuthStorage()
    let sync = SignInTestSyncController()
    let store: BrowserAccountStore

    init() {
        self.store = BrowserAccountStore(
            syncClient: client,
            authSessionStore: auth,
            syncCoordinator: sync,
            webSignInService: web,
            deviceIdentity: .init(name: "Test Mac", platform: "macOS"),
        )
    }
}

// MARK: - SignInTestClient

@MainActor private final class SignInTestClient: BrowserAccountAuthenticating {
    struct Exchange {
        let code: String
        let verifier: String
        let device: BrowserSyncDeviceIdentity
    }

    let baseURL = signInTestURL("https://sync.example")
    lazy var session = BrowserAuthSession(
        accessToken: "token", userID: "user", userEmail: "me@example.test", deviceID: "device", serverURL: baseURL,
    )
    var providers = [BrowserAccountProvider]()
    var exchanges = [Exchange]()
    var codeRequests = [String]()
    var verifications = [String]()
    var startError: BrowserAccountSignInError?
    var verifyError: BrowserAccountSignInError?

    func authenticateWithApple(
        identityToken _: String, deviceName _: String, devicePlatform _: String,
    ) -> BrowserAuthSession {
        session
    }

    func signInProviders() -> [BrowserAccountProvider] { providers }

    func exchangeWebSignIn(
        code: String, codeVerifier: String, deviceName: String, devicePlatform: String,
    ) -> BrowserAuthSession {
        exchanges.append(.init(
            code: code,
            verifier: codeVerifier,
            device: .init(name: deviceName, platform: devicePlatform),
        ))
        return session
    }

    func startEmailSignIn(email: String) throws -> BrowserEmailSignInCode {
        if let startError {
            throw startError
        }
        codeRequests.append(email)
        return .init(expiresIn: 600, resendIn: 30)
    }

    func verifyEmailSignIn(
        email _: String, code: String, deviceName _: String, devicePlatform _: String,
    ) throws -> BrowserAuthSession {
        verifications.append(code)
        if let verifyError {
            throw verifyError
        }
        return session
    }
}

// MARK: - SignInTestWebPresenter

@MainActor private final class SignInTestWebPresenter: BrowserWebSignInPresenting {
    /// Nil closes the page.
    var callback: URL?
    var opened = [(url: URL, scheme: String)]()
    var cancellations = 0

    func signIn(at url: URL, callbackScheme: String) throws -> URL {
        opened.append((url, callbackScheme))
        guard let callback else { throw BrowserWebSignInError.cancelled }
        return callback
    }

    func cancel() { cancellations += 1 }
}

// MARK: - SignInTestAuthStorage

@MainActor private final class SignInTestAuthStorage: BrowserSyncAuthSessionStoring {
    var saved = [BrowserAuthSession]()

    func loadSession() -> BrowserAuthSession? { saved.last }
    func saveSession(_ session: BrowserAuthSession) { saved.append(session) }
    func clearSession() { saved.removeAll() }
}

// MARK: - SignInTestSyncController

@MainActor private final class SignInTestSyncController: BrowserAccountSyncControlling {
    var sessionChanges = [BrowserAuthSession?]()

    func requiresSignIn() -> Bool { false }
    func completeAuthentication(for _: BrowserAuthSession) {}
    func signOut() {}
    func bindingState(for _: BrowserAuthSession) -> BrowserSyncBindingState { .needsConsent }
    func enableSync(for _: BrowserAuthSession) {}
    func resumeSync(for _: BrowserAuthSession) {}
    func suspendSync() {}
    func accountSessionDidChange(_ session: BrowserAuthSession?) { sessionChanges.append(session) }
}

// MARK: - SignInURLProtocol

private final class SignInURLProtocol: URLProtocol, @unchecked Sendable {
    // MARK: Private

    private struct State {
        var statusCode = 200
        var body = Data()
        var request: URLRequest?
    }

    private static let state = Mutex(State())

    // MARK: Internal

    static var lastRequest: URLRequest? { state.withLock { $0.request } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sign-in.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (statusCode, body) = Self.state.withLock { state in
            state.request = request
            return (state.statusCode, state.body)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
            ],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func respond(_ statusCode: Int, _ body: String) {
        state.withLock { $0 = .init(statusCode: statusCode, body: Data(body.utf8)) }
    }
}

private func signInTestURL(_ string: String) -> URL {
    URL(string: string)!
}
