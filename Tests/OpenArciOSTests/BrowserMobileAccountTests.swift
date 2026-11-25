// BrowserMobileAccountTests.swift

import AuthenticationServices
import BrowserMobileTestHost
import Combine
import Testing
import UIKit

// MARK: - BrowserMobileAccountTests

@MainActor @Suite(.serialized) struct BrowserMobileAccountTests {
    @Test func identityProviderRejectsMissingOrHiddenCallerWindow() async throws {
        var requests = 0
        let service = BrowserMobileAppleSignInService { _ in
            requests += 1
            return MobileAccountAuthorizationRequest()
        }
        await #expect(throws: BrowserMobileAppleSignInError.self) { try await service.requestIdentityToken() }
        let host = try MobileAccountHost(controller: UIViewController())
        defer { host.close() }
        service.setPresentationWindow(host.window)
        host.window.isHidden = true
        await #expect(throws: BrowserMobileAppleSignInError.self) { try await service.requestIdentityToken() }
        #expect(requests == 0)
    }

    @Test func identityProviderUsesExactCallerAndIgnoresLateDuplicateReplies() async throws {
        let host = try MobileAccountHost(controller: UIViewController())
        defer { host.close() }
        try #require(host.window.windowScene?.activationState == .foregroundActive)
        let first = MobileAccountAuthorizationRequest()
        let second = MobileAccountAuthorizationRequest()
        var anchors = [UIWindow]()
        let service = BrowserMobileAppleSignInService { window in
            anchors.append(window)
            return anchors.count == 1 ? first : second
        }
        service.setPresentationWindow(host.window)
        let old = Task { try await service.requestIdentityToken() }
        await first.waitUntilStarted()
        await #expect(throws: BrowserMobileAppleSignInError.self) { try await service.requestIdentityToken() }
        service.cancel()
        service.cancel()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(first.cancellations == 1)
        let fresh = Task { try await service.requestCredential() }
        await second.waitUntilStarted()
        first.complete(.success(.init(identityToken: "stale-token")))
        first.complete(.failure(MobileAccountTestError.failure))
        second.complete(.success(.init(identityToken: "current-token", authorizationCode: "current-code")))
        second.complete(.success(.init(identityToken: "duplicate-token")))
        #expect(try await fresh.value == .init(identityToken: "current-token", authorizationCode: "current-code"))
        #expect(anchors.count == 2 && anchors.allSatisfy { $0 === host.window })
    }

    @Test func identityProviderSurvivesTheSystemSheetAndCancelsWhenTheCallerSceneLeaves() async throws {
        let host = try MobileAccountHost(controller: UIViewController())
        defer { host.close() }
        try #require(host.window.windowScene?.activationState == .foregroundActive)
        let requests = [MobileAccountAuthorizationRequest(), MobileAccountAuthorizationRequest()]
        var index = 0
        let service = BrowserMobileAppleSignInService { _ in
            defer { index += 1 }
            return requests[index]
        }
        service.setPresentationWindow(host.window)
        let first = Task { try await service.requestIdentityToken() }
        await requests[0].waitUntilStarted()
        // The Sign in with Apple sheet deactivates the caller scene.
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: host.window.windowScene)
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: NSObject())
        #expect(requests[0].cancellations == 0)
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: host.window.windowScene)
        await #expect(throws: CancellationError.self) { try await first.value }
        let second = Task { try await service.requestIdentityToken() }
        await requests[1].waitUntilStarted()
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(requests.map(\.cancellations) == [1, 1])
    }

    @Test func accountSheetRequiresExplicitServerAndPreservesUnsubmittedDraft() async throws {
        let session = MobileAccountSession(configured: false)
        let controller = BrowserMobileAccountViewController(session: session)
        let host = try MobileAccountHost(controller: UINavigationController(rootViewController: controller))
        defer { host.close() }
        let field = try #require(controller.view.accountView("account.server") as? UITextField)
        let signIn = try #require(controller.view.accountView("account.signIn") as? ASAuthorizationAppleIDButton)
        #expect(!signIn.isEnabled)
        field.text = "https://sync.example.com"
        try host.press("account.saveServer", in: controller)
        #expect(session.configuredValues == ["https://sync.example.com"])
        #expect(signIn.isEnabled)
        field.text = "https://another.example.com"
        session.change.send()
        await host.drainUI()
        #expect(field.text == "https://another.example.com")
        session.configurationFails = true
        try host.press("account.saveServer", in: controller)
        #expect(controller.view.accountView("account.error")?.isHidden == false)
        #expect(session.serverURL?.absoluteString == "https://sync.example.com")
        for size in [CGSize(width: 320, height: 568), CGSize(width: 700, height: 600)] {
            host.window.frame.size = size
            host.window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            #expect(field.bounds.height >= 44)
            #expect(signIn.bounds.height >= 50)
            #expect(field.bounds.width > 0)
            #expect(!controller.view.hasAmbiguousLayout)
        }
    }

    @Test func accountSheetConsentPauseResumeRetryAndSignOutUseSharedAccountState() async throws {
        let session = MobileAccountSession(binding: .needsConsent, authenticated: true)
        let controller = BrowserMobileAccountViewController(session: session)
        let host = try MobileAccountHost(controller: UINavigationController(rootViewController: controller))
        defer { host.close() }
        #expect(controller.view.accountView("account.enable")?.isHidden == false)
        #expect(controller.view.accountView("account.pause")?.isHidden == true)
        try host.press("account.enable", in: controller)
        #expect(session.sync.enables == 1)
        #expect(session.account.bindingState == .enabled)
        #expect(controller.view.accountView("account.pause")?.isHidden == false)
        try host.press("account.pause", in: controller)
        #expect(session.account.bindingState == .paused)
        #expect(controller.view.accountView("account.resume")?.isHidden == false)
        try host.press("account.resume", in: controller)
        #expect(session.account.bindingState == .enabled)
        session.lastSyncError = "The server is unavailable."
        session.change.send()
        await host.drainUI()
        #expect(controller.view.accountView("account.retry")?.isHidden == false)
        try host.press("account.retry", in: controller)
        #expect(session.retries == 1)
        try host.press("account.signOut", in: controller)
        #expect(!session.account.isAuthenticated)
        #expect(session.storage.session == nil)
        #expect(controller.view.accountView("account.signIn")?.isHidden == false)
    }

    @Test func accountSheetAsksBeforeDeletingAndOffersToEraseWebsiteData() async throws {
        let session = MobileAccountSession(binding: .enabled, authenticated: true)
        let controller = BrowserMobileAccountViewController(session: session)
        let host = try MobileAccountHost(controller: UINavigationController(rootViewController: controller))
        defer { host.close() }
        try host.press("account.delete", in: controller)
        await host.drainUI()
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        #expect(alert.title == "Delete your OpenArc account?")
        #expect(alert.message?.contains("cookies, site logins and other website data") == true)
        #expect(alert.actions.map(\.title) == ["Delete Account", "Delete Account and Website Data", "Cancel"])
        #expect(alert.actions.map(\.style) == [.destructive, .destructive, .cancel])
        #expect(session.websiteDataErasures.isEmpty, "nothing is deleted before a choice")
        #expect(session.account.isAuthenticated)
        alert.dismiss(animated: false)
        await host.drainUI()

        session.account.signOut()
        await host.drainUI()
        #expect(controller.view.accountView("account.delete")?.isHidden == true)
    }

    @Test func accountSheetOwnsSignInWindowAndDismissalCancelsPendingAttempt() async throws {
        let session = MobileAccountSession()
        session.identity.holds = true
        let controller = BrowserMobileAccountViewController(session: session)
        let navigation = UINavigationController(rootViewController: controller)
        let host = try MobileAccountHost(controller: navigation)
        defer { host.close() }
        let signIn = try #require(controller.view.accountView("account.signIn") as? UIControl)
        signIn.sendActions(for: .touchUpInside)
        await session.identity.waitUntilStarted()
        await host.drainUI()
        #expect(session.signInWindow === host.window)
        #expect(session.account.isSigningIn)
        #expect(controller.view.accountView("account.cancelSignIn")?.isHidden == false)
        controller.presentationControllerDidDismiss(UIPresentationController(
            presentedViewController: navigation,
            presenting: nil,
        ))
        await host.drainUI()
        #expect(session.cancellations == 1)
        #expect(!session.account.isSigningIn)
        #expect(!session.account.isAuthenticated)
        #expect(session.remote.requests == 0)
    }
}

// MARK: - MobileAccountAuthorizationRequest

@MainActor private final class MobileAccountAuthorizationRequest: BrowserMobileAppleAuthorizationRequest {
    // MARK: Internal

    var cancellations = 0

    // MARK: Private

    private var completion: (@MainActor (Result<BrowserAppleCredential, Error>) -> Void)?
    private var started: CheckedContinuation<Void, Never>?

    func start(completion: @escaping @MainActor (Result<BrowserAppleCredential, Error>) -> Void) {
        self.completion = completion
        started?.resume()
        started = nil
    }

    func cancel() { cancellations += 1 }
    func complete(_ result: Result<BrowserAppleCredential, Error>) { completion?(result) }
    func waitUntilStarted() async {
        guard completion == nil else { return }
        await withCheckedContinuation { started = $0 }
    }
}

// MARK: - MobileAccountHost

@MainActor private final class MobileAccountHost {
    // MARK: Internal

    let window: UIWindow

    init(controller: UIViewController) throws {
        let scene = try #require(BrowserMobileTestScene.windowScene)
        self.window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()
    }

    func press(_ id: String, in controller: UIViewController) throws {
        let button = try #require(controller.view.accountView(id) as? UIButton)
        try #require(!button.isHidden && button.isEnabled)
        button.sendActions(for: .touchUpInside)
    }

    func drainUI() async { try? await Task.sleep(for: .milliseconds(20)) }
    func close() {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor private extension UIView {
    func accountView(_ id: String) -> UIView? {
        if accessibilityIdentifier == id {
            return self
        }
        return subviews.lazy.compactMap { $0.accountView(id) }.first
    }
}

// MARK: - MobileAccountSession

@MainActor private final class MobileAccountSession: BrowserMobileAccountSessionPresenting {
    // MARK: Internal

    var account: BrowserAccountStore
    var serverURL: URL?
    var lastSyncError: String?
    let change = PassthroughSubject<Void, Never>()
    let identity = MobileAccountIdentity()
    let storage = MobileAccountAuthStorage()
    let remote = MobileAccountAuthenticator()
    let sync = MobileAccountSyncController()
    var configurationFails = false
    var configuredValues = [String]()
    var signInWindow: UIWindow?
    var signInAttempt: UUID?
    var cancellations = 0
    var retries = 0
    var websiteDataErasures = [Bool]()

    var changePublisher: AnyPublisher<Void, Never> {
        Publishers.Merge(change, account.objectWillChange).eraseToAnyPublisher()
    }

    init(configured: Bool = true, binding: BrowserSyncBindingState = .needsConsent, authenticated: Bool = false) {
        sync.state = binding
        if authenticated {
            storage.session = remote.session
        }
        self.serverURL = configured ? remote.baseURL : nil
        self.account = BrowserAccountStore(
            syncClient: configured ? remote : nil, authSessionStore: storage, syncCoordinator: configured ? sync : nil,
            appleSignInService: identity, deviceIdentity: .init(name: "Test iPad", platform: "iPadOS"),
        )
    }

    func configureServer(_ raw: String) throws {
        if configurationFails {
            throw MobileAccountTestError.failure
        }
        configuredValues.append(raw)
        serverURL = URL(string: raw)
        account = BrowserAccountStore(
            syncClient: remote, authSessionStore: storage, syncCoordinator: sync,
            appleSignInService: identity, deviceIdentity: .init(name: "Test iPad", platform: "iPadOS"),
        )
        change.send()
    }

    func signIn(from window: UIWindow, attemptID: UUID) async {
        signInAttempt = attemptID
        signInWindow = window
        await account.signInWithApple()
        if signInAttempt == attemptID {
            signInAttempt = nil
        }
    }

    func signIn(with provider: BrowserAccountProvider, from _: UIWindow, attemptID: UUID) async {
        signInAttempt = attemptID
        await account.signIn(with: provider)
    }

    func requestEmailCode(_ email: String, from _: UIWindow, attemptID: UUID) async {
        signInAttempt = attemptID
        await account.requestEmailCode(email: email)
    }

    func signIn(email: String, code: String, from _: UIWindow, attemptID: UUID) async {
        signInAttempt = attemptID
        await account.signIn(email: email, code: code)
    }

    func loadProviders() async { await account.loadProviders() }
    func cancelEmailSignIn() { account.cancelEmailSignIn() }

    func cancelSignIn(attemptID: UUID) {
        guard signInAttempt == attemptID else { return }
        signInAttempt = nil
        cancellations += 1
        account.cancelSignIn()
        identity.cancel()
    }

    func enableSync() { account.enableSync() }
    func pauseSync() { account.pauseSync() }
    func resumeSync() { account.resumeSync() }
    func signOut() { account.signOut() }
    func deleteAccount(erasingWebsiteData: Bool) async -> Bool {
        websiteDataErasures.append(erasingWebsiteData)
        return await account.deleteAccount()
    }

    func retrySync() {
        retries += 1
        lastSyncError = nil
        change.send()
    }
}

// MARK: - MobileAccountIdentity

@MainActor private final class MobileAccountIdentity: BrowserAppleIdentityProviding {
    // MARK: Internal

    var holds = false

    // MARK: Private

    private var token: CheckedContinuation<String, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    func requestIdentityToken() async throws -> String {
        didStart = true
        started?.resume()
        started = nil
        if !holds {
            return "test-only-apple-token"
        }
        return try await withCheckedThrowingContinuation { token = $0 }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { started = $0 }
    }

    func cancel() {
        token?.resume(throwing: CancellationError())
        token = nil
    }
}

// MARK: - MobileAccountAuthenticator

@MainActor private final class MobileAccountAuthenticator: BrowserAccountAuthenticating {
    let baseURL = URL(string: "https://sync.example.com")!
    var requests = 0

    var session: BrowserAuthSession {
        .init(
            accessToken: "test-only-session",
            userID: "test-user",
            userEmail: "user@example.com",
            deviceID: "test-device",
            serverURL: baseURL,
        )
    }

    func authenticateWithApple(
        identityToken _: String,
        deviceName _: String,
        devicePlatform _: String,
    ) -> BrowserAuthSession {
        requests += 1
        return session
    }

    func deleteAccount(authSession _: BrowserAuthSession) {}
}

// MARK: - MobileAccountAuthStorage

@MainActor private final class MobileAccountAuthStorage: BrowserSyncAuthSessionStoring {
    var session: BrowserAuthSession?

    func loadSession() -> BrowserAuthSession? { session }
    func saveSession(_ session: BrowserAuthSession) { self.session = session }
    func clearSession() { session = nil }
}

// MARK: - MobileAccountSyncController

@MainActor private final class MobileAccountSyncController: BrowserAccountSyncControlling {
    var state = BrowserSyncBindingState.needsConsent
    var enables = 0
    var signInRequired = false

    func requiresSignIn() -> Bool { signInRequired }
    func completeAuthentication(for _: BrowserAuthSession) throws {
        guard state != .differentAccount else { throw BrowserSyncAccountError.differentAccount }
        signInRequired = false
        if state == .paused {
            state = .enabled
        }
    }

    func signOut() {
        signInRequired = true
        if state == .enabled {
            state = .paused
        }
    }

    func forgetAccount(removingCredentials: () throws -> Void) throws {
        state = .needsConsent
        try removingCredentials()
    }

    func bindingState(for _: BrowserAuthSession) -> BrowserSyncBindingState { state }
    func enableSync(for _: BrowserAuthSession) throws {
        guard !signInRequired else { throw BrowserSyncAccountError.unavailable }
        enables += 1
        state = .enabled
    }

    func resumeSync(for _: BrowserAuthSession) throws {
        guard !signInRequired else { throw BrowserSyncAccountError.unavailable }
        state = .enabled
    }

    func suspendSync() { state = .paused }
    func accountSessionDidChange(_: BrowserAuthSession?) {}
}

// MARK: - MobileAccountTestError

private enum MobileAccountTestError: Error { case failure }
