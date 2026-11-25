// BrowserMobileSyncSession.swift

import Combine
import Foundation
import UIKit
import WebKit

// MARK: - BrowserMobileSyncSession

/// Profile-owned account and transport. UIKit scenes contribute activity; none
/// owns the coordinator's snapshot applier or the durable account binding.
@MainActor final class BrowserMobileSyncSession: NSObject, ObservableObject {
    // MARK: Private

    private static let configurationKey = "mobile.sync.serverURL"

    private static var deviceIdentity: BrowserSyncDeviceIdentity {
        .init(name: UIDevice.current.name, platform: UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS")
    }

    // MARK: Internal

    @Published private(set) var account: BrowserAccountStore
    @Published private(set) var serverURL: URL?
    @Published private(set) var lastSyncError: String?
    private(set) var syncService: BrowserSyncService?

    private let store: BrowserSQLiteSessionStore
    private let document: BrowserMobileProfileDocument
    private let preferences: UserDefaults
    private let authSessionStore: any BrowserSyncAuthSessionStoring
    private let identityProvider: any BrowserAppleIdentityProviding
    private let webSignInService: any BrowserWebSignInPresenting
    private let clientFactory: (BrowserSyncConfiguration) -> any BrowserMobileSyncRemoteServing
    private let pushDebounce: Duration
    private let pollInterval: Duration?
    private let retryDelay: Duration?
    private let expirySweepInterval: TimeInterval
    private let expiryActivityRefreshInterval: TimeInterval
    private let dateProvider: @MainActor () -> Date
    private let eraseWebsiteData: @MainActor () async -> Void
    private var activeScenes = Set<String>()
    private var generation: UInt64 = 0
    private var signInAttempt: UUID?
    private weak var signInWindow: UIWindow?
    private var lastErrorPhase: BrowserSyncFailurePhase?
    private var accountObservation: AnyCancellable?

    var isForeground: Bool { !activeScenes.isEmpty }

    init(
        store: BrowserSQLiteSessionStore,
        document: BrowserMobileProfileDocument,
        preferences: UserDefaults = .standard,
        authSessionStore: any BrowserSyncAuthSessionStoring = BrowserAuthSessionStore(namespace: .profile("mobile")),
        identityProvider: any BrowserAppleIdentityProviding = BrowserMobileAppleSignInService(),
        webSignInService: any BrowserWebSignInPresenting = BrowserMobileWebSignInService(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        packagedServerURL: String? = Bundle.main.object(forInfoDictionaryKey: "OpenArcSyncBaseURL") as? String,
        clientFactory: @escaping (BrowserSyncConfiguration) -> any BrowserMobileSyncRemoteServing = {
            BrowserRemoteSyncClient(configuration: $0)
        },
        pushDebounce: Duration = .milliseconds(750), pollInterval: Duration? = .seconds(15),
        retryDelay: Duration? = .seconds(2),
        expirySweepInterval: TimeInterval = 60, expiryActivityRefreshInterval: TimeInterval = 300,
        dateProvider: @escaping @MainActor () -> Date = Date.init,
        eraseWebsiteData: @escaping @MainActor () async -> Void = BrowserMobileSyncSession.eraseWebsiteData,
    ) {
        self.store = store
        self.document = document
        self.preferences = preferences
        self.authSessionStore = authSessionStore
        self.identityProvider = identityProvider
        self.webSignInService = webSignInService
        self.clientFactory = clientFactory
        self.pushDebounce = pushDebounce
        self.pollInterval = pollInterval
        self.retryDelay = retryDelay
        self.expirySweepInterval = expirySweepInterval
        self.expiryActivityRefreshInterval = expiryActivityRefreshInterval
        self.dateProvider = dateProvider
        self.eraseWebsiteData = eraseWebsiteData
        self.account = BrowserAccountStore(
            syncClient: nil, authSessionStore: authSessionStore, syncCoordinator: nil,
            appleSignInService: identityProvider, webSignInService: webSignInService,
            deviceIdentity: Self.deviceIdentity,
        )
        super.init()
        document.syncSession = self
        for name in [UIScene.willDeactivateNotification, UIScene.didDisconnectNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneDeactivated(_:)),
                name: name,
                object: nil,
            )
        }
        observeAccount()
        let initial = environment["OPENARC_SYNC_BASE_URL"]
            ?? preferences.string(forKey: Self.configurationKey) ?? packagedServerURL
        if let initial, !initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !initial.contains("$(")
        {
            do {
                try configureServer(initial)
            } catch {
                self.lastSyncError = error.localizedDescription
            }
        }
    }

    static func configuration(_ raw: String) -> BrowserSyncConfiguration? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let configuration = BrowserSyncConfiguration(baseURL: url),
              let host = configuration.baseURL.host?.lowercased(), configuration.baseURL.scheme == "https"
              || (configuration.baseURL.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { return nil }
        return configuration
    }

    /// Every kind of data the pages' shared WebKit store keeps.
    static func eraseWebsiteData() async {
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast,
        )
    }

    func configureServer(_ raw: String) throws {
        guard !account.isSigningIn, !account.isAuthenticated else { throw BrowserMobileSyncConfigurationError.signedIn }
        guard let configuration = Self.configuration(raw) else { throw BrowserMobileSyncConfigurationError.invalidURL }
        if let owner = try store.syncOwner(), owner.baseURL != configuration.baseURL {
            throw BrowserSyncAccountError.serverChanged
        }
        generation &+= 1
        let currentGeneration = generation
        syncService?.setRuntimeActive(false)
        cancelSignIn()
        let client = clientFactory(configuration)
        let service = BrowserSyncService(
            localStore: store, remoteClient: client, authSessionStore: authSessionStore,
            pushDebounce: pushDebounce, pollInterval: pollInterval, retryDelay: retryDelay,
            runtimeActive: false,
            expirySweepInterval: expirySweepInterval, expiryActivityRefreshInterval: expiryActivityRefreshInterval,
            dateProvider: dateProvider,
            errorReporter: { [weak self] error, phase in
                guard let self, generation == currentGeneration else { return }
                lastErrorPhase = phase
                lastSyncError = BrowserSyncErrorMessage.describe(error)
            },
            operationDidSucceed: { [weak self] phase in
                guard let self, generation == currentGeneration, lastErrorPhase == phase else { return }
                lastErrorPhase = nil
                lastSyncError = nil
            },
        )
        document.attachSyncService(service)
        syncService = service
        serverURL = configuration.baseURL
        preferences.set(configuration.baseURL.absoluteString, forKey: Self.configurationKey)
        lastSyncError = nil
        lastErrorPhase = nil
        // Cached credentials cannot start a request before the sole document
        // applier is attached and the aggregate scene gate is known.
        account = BrowserAccountStore(
            syncClient: client, authSessionStore: authSessionStore, syncCoordinator: service,
            appleSignInService: identityProvider, webSignInService: webSignInService,
            deviceIdentity: Self.deviceIdentity,
        )
        observeAccount()
        service.setRuntimeActive(isForeground)
    }

    func setSceneActive(_ active: Bool, sceneID: String) {
        if active {
            activeScenes.insert(sceneID)
        } else {
            activeScenes.remove(sceneID)
        }
        syncService?.setRuntimeActive(isForeground)
        if !isForeground || (!active && signInWindow?.windowScene?.session.persistentIdentifier == sceneID) {
            cancelSignIn()
        }
    }

    /// Native Sign in with Apple.
    func signIn(from window: UIWindow, attemptID: UUID = UUID()) async {
        await runSignIn(from: window, attemptID: attemptID) { await $0.signInWithApple() }
    }

    /// A provider's sign-in page, presented over `window`.
    func signIn(with provider: BrowserAccountProvider, from window: UIWindow, attemptID: UUID = UUID()) async {
        await runSignIn(from: window, attemptID: attemptID) { await $0.signIn(with: provider) }
    }

    func requestEmailCode(_ email: String, from window: UIWindow, attemptID: UUID = UUID()) async {
        await runSignIn(from: window, attemptID: attemptID) { await $0.requestEmailCode(email: email) }
    }

    func signIn(email: String, code: String, from window: UIWindow, attemptID: UUID = UUID()) async {
        await runSignIn(from: window, attemptID: attemptID) { await $0.signIn(email: email, code: code) }
    }

    func loadProviders() async { await account.loadProviders() }

    /// Back to entering an email; a running request belongs to its caller.
    func cancelEmailSignIn() {
        guard !account.isSigningIn else { return }
        account.cancelEmailSignIn()
    }

    func cancelSignIn() {
        signInAttempt = nil
        signInWindow = nil
        account.cancelSignIn()
        (identityProvider as? BrowserMobileAppleSignInService)?.cancel()
        setPresentationWindow(nil)
    }

    func cancelSignIn(attemptID: UUID) {
        guard signInAttempt == attemptID else { return }
        cancelSignIn()
    }

    func enableSync() { account.enableSync() }
    func pauseSync() { account.pauseSync() }
    func resumeSync() { account.resumeSync() }
    func signOut() {
        cancelSignIn()
        account.signOut()
        lastSyncError = nil
        lastErrorPhase = nil
    }

    /// Deletes the account on the server, then signs out and unbinds this
    /// profile; its Spaces and tabs stay. With `erasingWebsiteData`, cookies,
    /// caches and site storage on this device go too, once the account is gone.
    @discardableResult func deleteAccount(erasingWebsiteData: Bool) async -> Bool {
        cancelSignIn()
        guard await account.deleteAccount() else { return false }
        lastSyncError = nil
        lastErrorPhase = nil
        if erasingWebsiteData {
            await eraseWebsiteData()
        }
        return true
    }

    func retrySync() {
        guard !document.hasUncommittedWrites || document.retryPersistence() else { return }
        lastSyncError = nil
        lastErrorPhase = nil
        syncService?.schedulePull()
        syncService?.schedulePush(snapshot: document.snapshot)
    }

    /// Every sign-in method follows the caller window: it must be in the
    /// foreground to start, and its scene leaving ends the attempt. Only the
    /// current attempt clears the shared state when it finishes.
    private func runSignIn(
        from window: UIWindow,
        attemptID: UUID,
        _ body: (BrowserAccountStore) async -> Void,
    ) async {
        guard !Task.isCancelled, !account.isSigningIn else { return }
        guard !window.isHidden, window.windowScene?.activationState == .foregroundActive else {
            lastSyncError = BrowserMobileAppleSignInError.inactiveWindow.localizedDescription
            return
        }
        signInAttempt = attemptID
        signInWindow = window
        setPresentationWindow(window)
        await body(account)
        guard signInAttempt == attemptID else { return }
        signInAttempt = nil
        signInWindow = nil
        setPresentationWindow(nil)
    }

    private func setPresentationWindow(_ window: UIWindow?) {
        (identityProvider as? any BrowserMobileSignInWindowAnchoring)?.setPresentationWindow(window)
        (webSignInService as? any BrowserMobileSignInWindowAnchoring)?.setPresentationWindow(window)
    }

    private func observeAccount() {
        accountObservation = account.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    @objc private func sceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === signInWindow?.windowScene else { return }
        cancelSignIn()
    }
}

// MARK: - BrowserMobileSyncRemoteServing

@MainActor protocol BrowserMobileSyncRemoteServing: BrowserSyncRemoteServing, BrowserAccountAuthenticating {}

// MARK: - BrowserRemoteSyncClient + BrowserMobileSyncRemoteServing

extension BrowserRemoteSyncClient: BrowserMobileSyncRemoteServing {}

// MARK: - BrowserMobileSyncConfigurationError

enum BrowserMobileSyncConfigurationError: Error, LocalizedError {
    case invalidURL
    case signedIn

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an HTTPS server address without a path. HTTP is available only for localhost testing."
        case .signedIn: "Sign out before changing the server."
        }
    }
}
