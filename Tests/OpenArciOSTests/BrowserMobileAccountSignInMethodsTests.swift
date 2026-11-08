// BrowserMobileAccountSignInMethodsTests.swift

import BrowserMobileTestHost
import Foundation
import Testing
import UIKit

// MARK: - BrowserMobileAccountSignInMethodsTests

@MainActor @Suite(.serialized) struct BrowserMobileAccountSignInMethodsTests {
    @Test func accountScreenRendersTheServerProvidersAndReloadsThemForANewServer() async throws {
        let f = try SignInMethodsFixture()
        defer { f.cleanup() }
        f.remote.providers = [.google, .email]
        let sheet = try SignInMethodsSheet(session: f.runtime)
        defer { sheet.close() }
        await until { f.runtime.account.providers != nil }
        await sheet.drain()
        #expect(f.runtime.account.providers == [.google, .email])
        #expect(sheet.isVisible("account.signIn"))
        #expect(sheet.isVisible("account.continue.google"))
        #expect(!sheet.isVisible("account.continue.github"))
        #expect(sheet.isVisible("account.email") && sheet.isVisible("account.sendCode"))
        #expect(!sheet.isVisible("account.code") && !sheet.isVisible("account.signInWithCode"))
        #expect(!sheet.isVisible("account.loadProviders"))

        f.remote.providers = [.github]
        try f.runtime.configureServer(f.remote.baseURL.absoluteString)
        await until { f.runtime.account.providers == [.github] }
        await sheet.drain()
        #expect(f.remote.providerRequests == 2)
        #expect(sheet.isVisible("account.signIn"))
        #expect(!sheet.isVisible("account.continue.google"))
        #expect(sheet.isVisible("account.continue.github"))
        #expect(!sheet.isVisible("account.email") && !sheet.isVisible("account.sendCode"))
    }

    @Test func providerSignInRunsThroughTheWebPresenterOverTheCallerWindow() async throws {
        let f = try SignInMethodsFixture()
        defer { f.cleanup() }
        let sheet = try SignInMethodsSheet(session: f.runtime)
        defer { sheet.close() }
        f.runtime.setSceneActive(true, sceneID: sheet.sceneID)
        await until { f.runtime.account.providers != nil }
        await sheet.drain()
        try sheet.press("account.continue.google")
        await until { f.web.requests.count == 1 }
        let request = try #require(f.web.requests.first)
        #expect(request.window === sheet.window)
        #expect(request.callbackScheme == BrowserAccountStore.webSignInCallbackScheme)
        #expect(request.url.path() == "/v1/auth/web/google/start")
        let challenge = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "code_challenge" }?
            .value
        #expect(challenge?.isEmpty == false)
        await sheet.drain()
        #expect(f.runtime.account.isSigningIn)
        #expect(sheet.isVisible("account.cancelSignIn"))
        #expect(sheet.control("account.continue.github")?.isEnabled == false)

        try f.web.complete(#require(URL(string: "openarc-auth://callback?code=web-code")))
        await until { f.runtime.account.isAuthenticated }
        await sheet.drain()
        #expect(f.remote.exchanges.map(\.code) == ["web-code"])
        #expect(f.remote.exchanges.first?.verifier.isEmpty == false)
        #expect(f.auth.session == f.remote.session)
        #expect(f.runtime.account.bindingState == .needsConsent)
        #expect(f.web.anchor == nil)
        for id in [
            "account.signIn", "account.continue.google", "account.continue.github", "account.email",
            "account.sendCode", "account.code", "account.signInWithCode", "account.cancelSignIn",
        ] {
            #expect(!sheet.isVisible(id), "\(id) stays hidden once signed in")
        }
        #expect(sheet.isVisible("account.enable"))
    }

    @Test func emailCodeRequestThenVerificationSignsIn() async throws {
        let f = try SignInMethodsFixture()
        defer { f.cleanup() }
        f.remote.providers = [.email]
        let sheet = try SignInMethodsSheet(session: f.runtime)
        defer { sheet.close() }
        f.runtime.setSceneActive(true, sceneID: sheet.sceneID)
        await until { f.runtime.account.providers != nil }
        await sheet.drain()
        let email = try #require(sheet.view("account.email") as? UITextField)
        email.text = " first@example.com "
        try sheet.press("account.sendCode")
        await until { f.runtime.account.emailSignIn != nil }
        await sheet.drain()
        #expect(f.remote.emailRequests == ["first@example.com"])
        #expect(!sheet.isVisible("account.email") && !sheet.isVisible("account.sendCode"))
        #expect(sheet.isVisible("account.code") && sheet.isVisible("account.signInWithCode"))
        #expect((sheet.view("account.codeSent") as? UILabel)?.text?.contains("first@example.com") == true)
        #expect(sheet.isVisible("account.sendAgain") && sheet.control("account.sendAgain")?.isEnabled == false)

        try sheet.press("account.differentEmail")
        await sheet.drain()
        #expect(f.runtime.account.emailSignIn == nil)
        #expect(sheet.isVisible("account.email") && !sheet.isVisible("account.code"))

        f.remote.resendIn = 0
        email.text = "user@example.com"
        try sheet.press("account.sendCode")
        await until { f.runtime.account.emailSignIn?.email == "user@example.com" }
        await sheet.drain()
        #expect(sheet.control("account.sendAgain")?.isEnabled == true)
        let code = try #require(sheet.view("account.code") as? UITextField)
        code.text = "123 456"
        try sheet.press("account.signInWithCode")
        await until { f.runtime.account.isAuthenticated }
        await sheet.drain()
        #expect(f.remote.verifications.map(\.email) == ["user@example.com"])
        #expect(f.remote.verifications.map(\.code) == ["123456"])
        #expect(f.auth.session == f.remote.session)
        #expect(f.runtime.account.emailSignIn == nil)
        #expect(!sheet.isVisible("account.code") && !sheet.isVisible("account.email"))
    }

    @Test func dismissalCancelsTheSheetsOwnEmailRequest() async throws {
        let f = try SignInMethodsFixture()
        defer { f.cleanup() }
        f.remote.providers = [.email]
        let gate = SignInMethodsGate()
        f.remote.emailGates = [gate]
        let sheet = try SignInMethodsSheet(session: f.runtime)
        defer { sheet.close() }
        f.runtime.setSceneActive(true, sceneID: sheet.sceneID)
        await until { f.runtime.account.providers != nil }
        await sheet.drain()
        (sheet.view("account.email") as? UITextField)?.text = "user@example.com"
        try sheet.press("account.sendCode")
        await until { f.remote.emailRequests.count == 1 }
        #expect(f.runtime.account.isSigningIn)
        sheet.dismiss()
        #expect(!f.runtime.account.isSigningIn)
        gate.open()
        await sheet.drain()
        #expect(f.runtime.account.emailSignIn == nil)
        #expect(f.runtime.lastSyncError == nil && f.runtime.account.lastError == nil)
    }

    @Test func staleSheetDismissalCannotCancelANewerProviderSignIn() async throws {
        let f = try SignInMethodsFixture()
        defer { f.cleanup() }
        let host = try SignInMethodsWindow()
        defer { host.close() }
        f.runtime.setSceneActive(true, sceneID: host.sceneID)
        let container = try #require(host.window.rootViewController)
        let firstSheet = BrowserMobileAccountViewController(session: f.runtime)
        let secondSheet = BrowserMobileAccountViewController(session: f.runtime)
        for sheet in [firstSheet, secondSheet] {
            container.addChild(sheet)
            container.view.addSubview(sheet.view)
            sheet.view.frame = container.view.bounds
            sheet.didMove(toParent: container)
        }
        await until { f.runtime.account.providers != nil }
        try await Task.sleep(for: .milliseconds(20))
        let firstGate = SignInMethodsGate()
        let secondGate = SignInMethodsGate()
        f.remote.exchangeGates = [firstGate, secondGate]
        f.web.callbackCode = "first-code"
        try #require(firstSheet.view.signInMethodsView("account.continue.google") as? UIControl)
            .sendActions(for: .touchUpInside)
        await until { f.remote.exchanges.count == 1 }
        f.runtime.cancelSignIn()
        try await Task.sleep(for: .milliseconds(20))
        f.web.callbackCode = "second-code"
        let secondButton = try #require(secondSheet.view.signInMethodsView("account.continue.github") as? UIControl)
        try #require(secondButton.isEnabled)
        secondButton.sendActions(for: .touchUpInside)
        await until { f.remote.exchanges.count == 2 }
        firstSheet.presentationControllerDidDismiss(UIPresentationController(
            presentedViewController: firstSheet,
            presenting: container,
        ))
        #expect(f.runtime.account.isSigningIn)
        firstGate.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(f.runtime.account.isSigningIn && f.auth.session == nil)
        secondGate.open()
        await until { !f.runtime.account.isSigningIn }
        #expect(f.remote.exchanges.map(\.code) == ["first-code", "second-code"])
        #expect(f.runtime.account.isAuthenticated)
        #expect(f.auth.session == f.remote.session)
    }

    @Test func webPresenterAnchorsTheCallerWindowAndEndsOnItsSceneLeaving() async throws {
        let host = try SignInMethodsWindow()
        defer { host.close() }
        let requests = [SignInMethodsWebRequest(), SignInMethodsWebRequest()]
        var anchors = [UIWindow]()
        let service = BrowserMobileWebSignInService { _, _, window in
            anchors.append(window)
            return requests[anchors.count - 1]
        }
        let url = try #require(URL(string: "https://sync.example.com/v1/auth/web/google/start"))
        await #expect(throws: BrowserMobileAppleSignInError.self) {
            try await service.signIn(at: url, callbackScheme: "openarc-auth")
        }
        service.setPresentationWindow(host.window)
        let first = Task { try await service.signIn(at: url, callbackScheme: "openarc-auth") }
        await requests[0].waitUntilStarted()
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: NSObject())
        #expect(requests[0].cancellations == 0)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: host.window.windowScene)
        await #expect(throws: BrowserWebSignInError.cancelled) { try await first.value }
        let second = Task { try await service.signIn(at: url, callbackScheme: "openarc-auth") }
        await requests[1].waitUntilStarted()
        try requests[0].complete(.success(#require(URL(string: "openarc-auth://callback?code=stale"))))
        try requests[1].complete(.success(#require(URL(string: "openarc-auth://callback?code=current"))))
        #expect(try await second.value.absoluteString == "openarc-auth://callback?code=current")
        #expect(anchors.count == 2 && anchors.allSatisfy { $0 === host.window })
        #expect(requests.map(\.cancellations) == [1, 0])
    }
}

/// Polls main-actor state that an async sign-in step changes.
@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor private extension UIView {
    func signInMethodsView(_ id: String) -> UIView? {
        if accessibilityIdentifier == id {
            return self
        }
        return subviews.lazy.compactMap { $0.signInMethodsView(id) }.first
    }
}

// MARK: - SignInMethodsWindow

@MainActor private final class SignInMethodsWindow {
    // MARK: Internal

    let window: UIWindow

    var sceneID: String { window.windowScene?.session.persistentIdentifier ?? "" }

    init(rootViewController: UIViewController = UIViewController()) throws {
        let scene = try #require(BrowserMobileTestScene.windowScene)
        try #require(scene.activationState == .foregroundActive)
        self.window = UIWindow(windowScene: scene)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func close() {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }
}

// MARK: - SignInMethodsSheet

@MainActor private final class SignInMethodsSheet {
    // MARK: Internal

    let controller: BrowserMobileAccountViewController
    let navigation: UINavigationController
    let host: SignInMethodsWindow

    var window: UIWindow { host.window }
    var sceneID: String { host.sceneID }

    init(session: BrowserMobileSyncSession) throws {
        self.controller = BrowserMobileAccountViewController(session: session)
        self.navigation = UINavigationController(rootViewController: controller)
        self.host = try SignInMethodsWindow(rootViewController: navigation)
        controller.loadViewIfNeeded()
    }

    func view(_ id: String) -> UIView? { controller.view.signInMethodsView(id) }
    func control(_ id: String) -> UIControl? { view(id) as? UIControl }

    /// Whether the view and every container up to the screen show.
    func isVisible(_ id: String) -> Bool {
        var current = view(id)
        while let view = current, view !== controller.view {
            if view.isHidden {
                return false
            }
            current = view.superview
        }
        return current != nil
    }

    func press(_ id: String) throws {
        let button = try #require(control(id))
        try #require(isVisible(id) && button.isEnabled)
        button.sendActions(for: .touchUpInside)
    }

    func dismiss() {
        controller.presentationControllerDidDismiss(UIPresentationController(
            presentedViewController: navigation,
            presenting: nil,
        ))
    }

    func drain() async { try? await Task.sleep(for: .milliseconds(20)) }
    func close() { host.close() }
}

// MARK: - SignInMethodsFixture

@MainActor private final class SignInMethodsFixture {
    // MARK: Internal

    let directory: URL
    let preferencesName: String
    let preferences: UserDefaults
    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument
    let remote = SignInMethodsRemote()
    let auth = SignInMethodsAuthStorage()
    let identity = SignInMethodsIdentity()
    let web = SignInMethodsWebPresenter()
    let runtime: BrowserMobileSyncSession

    init() throws {
        self.directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("MobileSignInMethods-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.preferencesName = "MobileSignInMethods.\(UUID().uuidString)"
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Browser.sqlite"))
        store.saveSnapshot(BrowserTabSessionSnapshot(
            spaces: [.init(id: "space", title: "Space", systemImageName: "globe", selectedTabIndex: 0)],
            tabs: [.init(id: "tab", urlString: "https://example.com", placement: .temporary, spaceID: "space")],
        ))
        self.document = try BrowserMobileProfileDocument(store: store, initialSnapshot: store.loadSnapshotStrict())
        self.runtime = BrowserMobileSyncSession(
            store: store, document: document, preferences: preferences, authSessionStore: auth,
            identityProvider: identity, webSignInService: web,
            environment: ["OPENARC_SYNC_BASE_URL": remote.baseURL.absoluteString],
            packagedServerURL: nil, clientFactory: { [remote] _ in remote },
            pushDebounce: .zero, pollInterval: nil, retryDelay: nil,
        )
    }

    func cleanup() {
        runtime.cancelSignIn()
        runtime.syncService?.setRuntimeActive(false)
        preferences.removePersistentDomain(forName: preferencesName)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - SignInMethodsRemote

@MainActor private final class SignInMethodsRemote: BrowserMobileSyncRemoteServing {
    let baseURL = URL(string: "https://sync.example.com")!
    var providers: [BrowserAccountProvider] = [.apple, .google, .github, .email]
    var providerRequests = 0
    var exchanges = [(code: String, verifier: String)]()
    var emailRequests = [String]()
    var verifications = [(email: String, code: String)]()
    var resendIn = 30
    var exchangeGates = [SignInMethodsGate]()
    var emailGates = [SignInMethodsGate]()

    var session: BrowserAuthSession {
        .init(
            accessToken: "test-only-token",
            userID: "user",
            userEmail: "user@example.com",
            deviceID: "device",
            serverURL: baseURL,
        )
    }

    func authenticateWithApple(identityToken _: String, deviceName _: String, devicePlatform _: String)
        -> BrowserAuthSession
    {
        session
    }

    func signInProviders() -> [BrowserAccountProvider] {
        providerRequests += 1
        return providers
    }

    func exchangeWebSignIn(
        code: String,
        codeVerifier: String,
        deviceName _: String,
        devicePlatform _: String,
    ) async -> BrowserAuthSession {
        let index = exchanges.count
        exchanges.append((code, codeVerifier))
        if exchangeGates.indices.contains(index) {
            await exchangeGates[index].wait()
        }
        return session
    }

    func startEmailSignIn(email: String) async -> BrowserEmailSignInCode {
        let index = emailRequests.count
        emailRequests.append(email)
        if emailGates.indices.contains(index) {
            await emailGates[index].wait()
        }
        return .init(expiresIn: 600, resendIn: resendIn)
    }

    func verifyEmailSignIn(
        email: String,
        code: String,
        deviceName _: String,
        devicePlatform _: String,
    ) -> BrowserAuthSession {
        verifications.append((email, code))
        return session
    }

    func pull(cursor: Int, authSession _: BrowserAuthSession) -> BrowserSyncPullResponse {
        .init(cursor: cursor, events: [], supportedPushVersions: [2])
    }

    func push(mutation: BrowserSyncMutation, authSession _: BrowserAuthSession) -> BrowserSyncPushResponse {
        .init(cursor: 0, events: [], mutationID: mutation.id)
    }
}

// MARK: - SignInMethodsWebPresenter

@MainActor private final class SignInMethodsWebPresenter: BrowserWebSignInPresenting,
    BrowserMobileSignInWindowAnchoring
{
    // MARK: Internal

    struct Request {
        let url: URL
        let callbackScheme: String
        weak var window: UIWindow?
    }

    weak var anchor: UIWindow?
    var requests = [Request]()
    var cancellations = 0
    /// Completes every page at once with this code instead of waiting.
    var callbackCode: String?

    // MARK: Private

    private var pending: CheckedContinuation<URL, Error>?

    func setPresentationWindow(_ window: UIWindow?) { anchor = window }

    func signIn(at url: URL, callbackScheme: String) async throws -> URL {
        requests.append(.init(url: url, callbackScheme: callbackScheme, window: anchor))
        if let callbackCode {
            return URL(string: "\(callbackScheme)://callback?code=\(callbackCode)")!
        }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func complete(_ url: URL) {
        pending?.resume(returning: url)
        pending = nil
    }

    func cancel() {
        cancellations += 1
        pending?.resume(throwing: BrowserWebSignInError.cancelled)
        pending = nil
    }
}

// MARK: - SignInMethodsWebRequest

@MainActor private final class SignInMethodsWebRequest: BrowserMobileWebAuthenticationRequest {
    // MARK: Internal

    var cancellations = 0

    // MARK: Private

    private var completion: (@MainActor (Result<URL, Error>) -> Void)?
    private var started: CheckedContinuation<Void, Never>?

    func start(completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        self.completion = completion
        started?.resume()
        started = nil
    }

    func cancel() { cancellations += 1 }
    func complete(_ result: Result<URL, Error>) { completion?(result) }
    func waitUntilStarted() async {
        guard completion == nil else { return }
        await withCheckedContinuation { started = $0 }
    }
}

// MARK: - SignInMethodsAuthStorage

@MainActor private final class SignInMethodsAuthStorage: BrowserSyncAuthSessionStoring {
    var session: BrowserAuthSession?

    func loadSession() -> BrowserAuthSession? { session }
    func saveSession(_ session: BrowserAuthSession) { self.session = session }
    func clearSession() { session = nil }
}

// MARK: - SignInMethodsIdentity

@MainActor private final class SignInMethodsIdentity: BrowserAppleIdentityProviding {
    func requestIdentityToken() -> String { "test-only-identity" }
}

// MARK: - SignInMethodsGate

@MainActor private final class SignInMethodsGate {
    // MARK: Private

    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

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
}
