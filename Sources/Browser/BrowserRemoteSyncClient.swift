// BrowserRemoteSyncClient.swift

import Foundation
import Gzip
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import OSLog
import Security

// MARK: - BrowserRemoteSyncClient

final class BrowserRemoteSyncClient: @unchecked Sendable {
    // MARK: Private

    private struct SyncServerError: Decodable { let message: String }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let gzipRequestThreshold = 1024

    private let configuration: BrowserSyncConfiguration
    private let session: URLSession
    private let openAPITransport: URLSessionTransport

    // MARK: Internal

    var baseURL: URL { configuration.baseURL }

    init(configuration: BrowserSyncConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.openAPITransport = URLSessionTransport(configuration: .init(session: session))
    }

    static func changes(
        from previousSnapshot: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot,
    ) -> [BrowserSyncChange] {
        BrowserSyncOutboxProjection.changes(from: previousSnapshot, to: snapshot)
    }

    private static func iso8601String(from timeInterval: TimeInterval) -> String {
        iso8601String(from: Date(timeIntervalSince1970: timeInterval))
    }

    private static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func authResponse(
        from output: Operations.authenticateWithApple.Output,
    ) throws -> BrowserAppleAuthResponse {
        switch output {
        case .ok(let response):
            switch response.body {
            case .json(let body):
                return BrowserAppleAuthResponse(
                    accessToken: body.accessToken,
                    expiresIn: body.expiresIn,
                    user: BrowserAppleAuthResponse.User(
                        id: body.user.id,
                        email: body.user.email,
                    ),
                    device: BrowserSyncDevice(
                        id: body.device.id,
                        name: body.device.name,
                        platform: body.device.platform,
                        lastSeenAt: body.device.lastSeenAt.map { Self.iso8601String(from: $0) },
                    ),
                )
            }
        default:
            throw BrowserRemoteSyncError.unexpectedOpenAPIResponse
        }
    }

    func authenticateWithApple(
        identityToken: String,
        deviceName: String,
        devicePlatform: String,
    ) async throws -> BrowserAuthSession {
        let request = BrowserAppleAuthRequest(
            identityToken: identityToken,
            deviceName: deviceName,
            devicePlatform: devicePlatform,
        )
        let response = try await Self.authResponse(
            from: openAPIClient(accessToken: nil).authenticateWithApple(
                .init(
                    body: .json(
                        Components.Schemas.AuthAppleRequest(
                            identityToken: request.identityToken,
                            deviceName: request.deviceName,
                            devicePlatform: request.devicePlatform,
                        ),
                    ),
                ),
            ),
        )
        return BrowserAuthSession(
            accessToken: response.accessToken,
            userID: response.user.id,
            userEmail: response.user.email,
            deviceID: response.device.id,
            serverURL: configuration.baseURL,
        )
    }

    func push(
        mutation: BrowserSyncMutation,
        authSession: BrowserAuthSession,
    ) async throws -> BrowserSyncPushResponse {
        guard authSession.belongs(to: baseURL) else { throw BrowserSyncAccountError.serverChanged }
        let request = BrowserSyncPushRequest(
            mutationID: mutation.id,
            deviceID: authSession.deviceID,
            changes: mutation.changes,
        )
        return try await send(
            path: "/v1/sync/push",
            method: "POST",
            body: request,
            accessToken: authSession.accessToken,
        )
    }

    func pull(cursor: Int, authSession: BrowserAuthSession) async throws -> BrowserSyncPullResponse {
        try await pull(cursor: cursor, protocolVersion: 2, authSession: authSession)
    }

    func pull(
        cursor: Int,
        protocolVersion: Int,
        authSession: BrowserAuthSession,
    ) async throws -> BrowserSyncPullResponse {
        guard authSession.belongs(to: baseURL) else { throw BrowserSyncAccountError.serverChanged }
        guard [2, 4, 5].contains(protocolVersion) else { throw BrowserRemoteSyncError.unsupportedSyncProtocol }
        return try await send(
            path: "/v1/sync/pull",
            method: "POST",
            body: BrowserSyncPullRequest(
                deviceID: authSession.deviceID, cursor: cursor, limit: 500,
                protocolVersion: protocolVersion == 2 ? nil : protocolVersion,
            ),
            accessToken: authSession.accessToken,
        )
    }

    func push(
        mutation: BrowserSyncSemanticMutation,
        authSession: BrowserAuthSession,
    ) async throws -> BrowserSyncSemanticPushResponse {
        guard authSession.belongs(to: baseURL) else { throw BrowserSyncAccountError.serverChanged }
        let response: BrowserSyncSemanticPushResponse = try await send(
            path: "/v1/sync/push", method: "POST",
            body: BrowserSyncSemanticPushRequest(
                mutationID: mutation.id, deviceID: authSession.deviceID, operations: mutation.operations,
            ), accessToken: authSession.accessToken,
        )
        guard response.protocolVersion == 3, response.mutationID == mutation.id,
              response.cursor >= 0, response.outcomes.count == mutation.operations.count,
              Set(response.outcomes.map(\.operationIndex)) == Set(mutation.operations.indices)
        else { throw BrowserRemoteSyncError.invalidMutationReceipt }
        return response
    }

    func push(
        mutation: BrowserSyncFolderMutation,
        authSession: BrowserAuthSession,
    ) async throws -> BrowserSyncFolderPushResponse {
        guard authSession.belongs(to: baseURL) else { throw BrowserSyncAccountError.serverChanged }
        let response: BrowserSyncFolderPushResponse = try await send(
            path: "/v1/sync/push", method: "POST",
            body: BrowserSyncFolderPushRequest(
                mutationID: mutation.id, deviceID: authSession.deviceID, operations: mutation.operations,
            ), accessToken: authSession.accessToken,
        )
        guard response.protocolVersion == 4, response.mutationID == mutation.id,
              response.cursor >= 0, response.outcomes.count == mutation.operations.count,
              Set(response.outcomes.map(\.operationIndex)) == Set(mutation.operations.indices)
        else { throw BrowserRemoteSyncError.invalidMutationReceipt }
        return response
    }

    func push(
        mutation: BrowserSyncExpiryMutation,
        authSession: BrowserAuthSession,
    ) async throws -> BrowserSyncExpiryPushResponse {
        guard authSession.belongs(to: baseURL) else { throw BrowserSyncAccountError.serverChanged }
        try mutation.validate()
        let response: BrowserSyncExpiryPushResponse = try await send(
            path: "/v1/sync/push", method: "POST",
            body: BrowserSyncExpiryPushRequest(
                mutationID: mutation.id, deviceID: authSession.deviceID, operations: mutation.operations,
            ), accessToken: authSession.accessToken,
        )
        try response.validate(for: mutation)
        return response
    }

    private func openAPIClient(accessToken: String?) -> Client {
        Client(
            serverURL: configuration.baseURL,
            transport: openAPITransport,
            middlewares: [
                BrowserOpenAPIRequestMiddleware(accessToken: accessToken),
            ],
        )
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: some Encodable,
        accessToken: String?,
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw BrowserRemoteSyncError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let encodedBody = try Self.encoder.encode(body)
        if encodedBody.count >= Self.gzipRequestThreshold {
            request.httpBody = try encodedBody.gzipped()
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        } else {
            request.httpBody = encodedBody
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            if path == "/v1/sync/pull", (response as? HTTPURLResponse)?.statusCode == 409,
               let error = try? Self.decoder.decode(SyncServerError.self, from: data),
               ["Protocol 4 bootstrap requires cursor 0", "Protocol 5 bootstrap requires cursor 0"]
                .contains(error.message)
            {
                throw error.message.hasPrefix("Protocol 5")
                    ? BrowserRemoteSyncError.expiryBootstrapRequired
                    : BrowserRemoteSyncError.folderBootstrapRequired
            }
            throw BrowserRemoteSyncError.unexpectedResponse(data)
        }

        return try Self.decoder.decode(Response.self, from: data)
    }
}

// MARK: - BrowserRemoteSyncError

enum BrowserRemoteSyncError: Error {
    case invalidURL
    case unexpectedResponse(Data)
    case unexpectedOpenAPIResponse
    case invalidPullCursor
    case unsupportedSyncProtocol
    case invalidMutationReceipt
    case folderBootstrapRequired
    case expiryBootstrapRequired

    // MARK: Internal

    var isFolderBootstrapRequired: Bool {
        if case .folderBootstrapRequired = self {
            return true
        }
        return false
    }

    var isExpiryBootstrapRequired: Bool {
        if case .expiryBootstrapRequired = self {
            return true
        }
        return false
    }
}

// MARK: - BrowserOpenAPIRequestMiddleware

private struct BrowserOpenAPIRequestMiddleware: ClientMiddleware {
    let accessToken: String?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID _: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?),
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.acceptEncoding] = "gzip"
        if let accessToken {
            request.headerFields[.authorization] = "Bearer \(accessToken)"
        }
        return try await next(request, body, baseURL)
    }
}

// MARK: - BrowserAuthSessionStore

final class BrowserAuthSessionStore {
    // MARK: Private

    private let service: String
    private let sessionAccount: String

    init(
        service: String = Bundle.main.bundleIdentifier ?? "com.levochkaa.OpenArc",
        namespace: BrowserAuthSessionNamespace = .defaultProfile,
    ) {
        self.service = "\(service).sync"
        self.sessionAccount = namespace.keychainAccount
    }

    // MARK: Internal

    func loadSession() -> BrowserAuthSession? {
        guard
            let data = keychainData(account: sessionAccount),
            let session = try? JSONDecoder().decode(BrowserAuthSession.self, from: data)
        else {
            return nil
        }

        return session
    }

    func saveSession(_ session: BrowserAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        try setKeychainData(data, account: sessionAccount)
    }

    func clearSession() throws {
        let status = SecItemDelete(keychainQuery(account: sessionAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BrowserAuthSessionStoreError.keychain(status)
        }
    }

    private func keychainData(account: String) -> Data? {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    private func setKeychainData(_ data: Data, account: String) throws {
        let query = keychainQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BrowserAuthSessionStoreError.keychain(addStatus)
        }
    }

    private func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

// MARK: - BrowserAuthSessionStoreError

enum BrowserAuthSessionStoreError: Error {
    case keychain(OSStatus)
}

// MARK: - BrowserSyncRemoteServing

@MainActor protocol BrowserSyncRemoteServing: AnyObject {
    var baseURL: URL { get }
    func push(
        mutation: BrowserSyncMutation,
        authSession: BrowserAuthSession,
    ) async throws -> BrowserSyncPushResponse

    func push(
        mutation: BrowserSyncSemanticMutation,
        authSession: BrowserAuthSession,
    ) async throws -> BrowserSyncSemanticPushResponse

    func pull(cursor: Int, authSession: BrowserAuthSession) async throws -> BrowserSyncPullResponse
    func pull(cursor: Int, protocolVersion: Int, authSession: BrowserAuthSession) async throws
        -> BrowserSyncPullResponse
    func push(
        mutation: BrowserSyncFolderMutation,
        authSession: BrowserAuthSession,
    ) async throws -> BrowserSyncFolderPushResponse

    func push(
        mutation: BrowserSyncExpiryMutation,
        authSession: BrowserAuthSession,
    ) async throws -> BrowserSyncExpiryPushResponse
}

extension BrowserSyncRemoteServing {
    func push(
        mutation _: BrowserSyncExpiryMutation,
        authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncExpiryPushResponse {
        throw BrowserRemoteSyncError.unsupportedSyncProtocol
    }

    func pull(
        cursor: Int,
        protocolVersion: Int,
        authSession: BrowserAuthSession,
    ) async throws -> BrowserSyncPullResponse {
        guard protocolVersion == 2 else { throw BrowserRemoteSyncError.unsupportedSyncProtocol }
        return try await pull(cursor: cursor, authSession: authSession)
    }

    func push(
        mutation _: BrowserSyncFolderMutation,
        authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncFolderPushResponse {
        throw BrowserRemoteSyncError.unsupportedSyncProtocol
    }

    func push(
        mutation _: BrowserSyncSemanticMutation,
        authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncSemanticPushResponse {
        throw BrowserRemoteSyncError.unsupportedSyncProtocol
    }
}

// MARK: - BrowserRemoteSyncClient + BrowserSyncRemoteServing

extension BrowserRemoteSyncClient: BrowserSyncRemoteServing {}

// MARK: - BrowserSyncAuthSessionReading

@MainActor protocol BrowserSyncAuthSessionReading: AnyObject {
    func loadSession() -> BrowserAuthSession?
}

// MARK: - BrowserAuthSessionStore + BrowserSyncAuthSessionReading

extension BrowserAuthSessionStore: BrowserSyncAuthSessionReading {}

// MARK: - BrowserSyncAuthSessionStoring

@MainActor protocol BrowserSyncAuthSessionStoring: BrowserSyncAuthSessionReading {
    func saveSession(_ session: BrowserAuthSession) throws
    func clearSession() throws
}

// MARK: - BrowserAuthSessionStore + BrowserSyncAuthSessionStoring

extension BrowserAuthSessionStore: BrowserSyncAuthSessionStoring {}

// MARK: - BrowserSyncBindingState

enum BrowserSyncBindingState: Equatable {
    case needsConsent, enabled, paused, differentAccount
}

// MARK: - BrowserSyncAccountError

enum BrowserSyncAccountError: LocalizedError, Equatable {
    case serverChanged, differentAccount, unavailable, signInRequired, localPersistenceBlocked

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .serverChanged: BrowserStrings.syncAccountSignInAgain
        case .differentAccount: BrowserStrings.syncAccountDifferentOwner
        case .unavailable: BrowserStrings.syncAccountUnavailable
        case .signInRequired: BrowserStrings.syncAccountSignInAgain
        case .localPersistenceBlocked: BrowserStrings.sessionRecoveryRetryMessage
        }
    }
}

// MARK: - BrowserAccountSyncControlling

@MainActor protocol BrowserAccountSyncControlling: AnyObject {
    func requiresSignIn() throws -> Bool
    func bindingState(for session: BrowserAuthSession) throws -> BrowserSyncBindingState
    func completeAuthentication(for session: BrowserAuthSession) throws
    func enableSync(for session: BrowserAuthSession) throws
    func resumeSync(for session: BrowserAuthSession) throws
    func suspendSync() throws
    func signOut() throws
    func accountSessionDidChange(_ session: BrowserAuthSession?)
}

// MARK: - BrowserSyncService

@MainActor final class BrowserSyncService: BrowserSyncCoordinating, BrowserAccountSyncControlling {
    // MARK: Private

    private struct RequestContext {
        let session: BrowserAuthSession
        let owner: BrowserSyncOwner
        let generation: UInt64
    }

    private struct EntityKey: Hashable {
        let type: String
        let id: String
    }

    private struct ExpiryResponseLimit {
        let failures: Int
        var recordedAt: Date
        var retryAt: Date

        var delay: TimeInterval { min(3600, 60 * pow(2, Double(failures - 1))) }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.levochkaa.OpenArc", category: "Sync",
    )

    private let localStore: BrowserSQLiteSessionStore
    private let remoteClient: any BrowserSyncRemoteServing
    private let authSessionStore: any BrowserSyncAuthSessionReading
    private let pushDebounce: Duration
    private let pollInterval: Duration?
    private let retryDelay: Duration?
    private let expirySweepInterval: TimeInterval
    private let expiryActivityRefreshInterval: TimeInterval
    private let dateProvider: @MainActor () -> Date
    private weak var expiryScheduler: (any BrowserSyncExpiryScheduling)?
    private var lastExpirySweep: Date?
    private var lastExpiryActivityRefresh: Date?
    private var expiryCandidateCursor: BrowserSyncExpiryCandidateCursor?
    private var expiryResponseLimits = [BrowserSyncExpiryCandidateCursor: ExpiryResponseLimit]()
    private var activeSession: BrowserAuthSession?
    private var isRuntimeActive: Bool
    private var isLocalPersistenceBlocked = false
    private var generation: UInt64 = 0
    private let errorReporter: BrowserSyncErrorReporter
    private let operationDidSucceed: @MainActor (BrowserSyncFailurePhase) -> Void
    private var supportedPushVersions = Set<Int>()
    private var pendingPushTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var pendingPushContext: RequestContext?
    private var pendingPullContext: RequestContext?
    private weak var snapshotApplier: (any BrowserSyncSnapshotApplying)?

    init(
        localStore: BrowserSQLiteSessionStore,
        remoteClient: any BrowserSyncRemoteServing,
        authSessionStore: any BrowserSyncAuthSessionReading,
        pushDebounce: Duration = .milliseconds(750),
        pollInterval: Duration? = .seconds(15),
        retryDelay: Duration? = .seconds(2),
        runtimeActive: Bool = true,
        expirySweepInterval: TimeInterval = 60,
        expiryActivityRefreshInterval: TimeInterval = 300,
        dateProvider: @escaping @MainActor () -> Date = Date.init,
        errorReporter: @escaping BrowserSyncErrorReporter = { _, _ in },
        operationDidSucceed: @escaping @MainActor (BrowserSyncFailurePhase) -> Void = { _ in },
    ) {
        self.localStore = localStore
        self.remoteClient = remoteClient
        self.authSessionStore = authSessionStore
        self.pushDebounce = pushDebounce
        self.pollInterval = pollInterval
        self.retryDelay = retryDelay
        self.isRuntimeActive = runtimeActive
        self.expirySweepInterval = max(0, expirySweepInterval)
        self.expiryActivityRefreshInterval = max(0, expiryActivityRefreshInterval)
        self.dateProvider = dateProvider
        self.errorReporter = errorReporter
        self.operationDidSucceed = operationDidSucceed
    }

    deinit {
        pendingPushTask?.cancel()
        processingTask?.cancel()
        pollTask?.cancel()
        retryTask?.cancel()
    }

    // MARK: Internal

    func requiresSignIn() throws -> Bool { try localStore.requiresSyncSignIn() }

    func bindingState(for session: BrowserAuthSession) throws -> BrowserSyncBindingState {
        guard session.belongs(to: remoteClient.baseURL) else { throw BrowserSyncAccountError.serverChanged }
        let owner = owner(for: session)
        guard let storedOwner = try localStore.syncOwner() else { return .needsConsent }
        guard owner == storedOwner else { return .differentAccount }
        return try localStore.isSyncPaused(for: owner) ? .paused : .enabled
    }

    func enableSync(for session: BrowserAuthSession) throws {
        guard try !requiresSignIn() else { throw BrowserSyncAccountError.signInRequired }
        guard authSessionStore.loadSession() == session else { throw BrowserSyncAccountError.unavailable }
        let state = try bindingState(for: session)
        guard state != .differentAccount else {
            throw BrowserSyncAccountError.differentAccount
        }
        // First adoption seeds the durable snapshot into the sync outbox. A
        // failed local write must recover before that snapshot acquires an owner;
        // otherwise its later Retry could become an unconditional remote delete.
        guard state != .needsConsent || !isLocalPersistenceBlocked else {
            throw BrowserSyncAccountError.localPersistenceBlocked
        }
        try localStore.bindSyncOwner(owner(for: session))
        try localStore.resumeSync(for: owner(for: session))
    }

    func resumeSync(for session: BrowserAuthSession) throws {
        guard try !requiresSignIn() else { throw BrowserSyncAccountError.signInRequired }
        guard session.belongs(to: remoteClient.baseURL), authSessionStore.loadSession() == session else {
            throw BrowserSyncAccountError.serverChanged
        }
        try localStore.resumeSync(for: owner(for: session))
    }

    func completeAuthentication(for session: BrowserAuthSession) throws {
        guard session.belongs(to: remoteClient.baseURL), authSessionStore.loadSession() == session else {
            throw BrowserSyncAccountError.serverChanged
        }
        guard try bindingState(for: session) != .differentAccount else {
            throw BrowserSyncAccountError.differentAccount
        }
        try localStore.completeSyncAuthentication(for: owner(for: session))
    }

    func suspendSync() throws {
        accountSessionDidChange(nil)
        try localStore.pauseSync()
    }

    func signOut() throws {
        accountSessionDidChange(nil)
        try localStore.requireSyncSignIn()
    }

    func accountSessionDidChange(_ session: BrowserAuthSession?) {
        activeSession = session
        invalidatePendingRequests()
        if session != nil {
            schedulePull()
            startPolling()
        }
    }

    /// Foreground activity controls transport only. Credentials, owner, durable
    /// Pause, and the immutable queue survive the last scene becoming inactive.
    func setRuntimeActive(_ active: Bool) {
        guard isRuntimeActive != active else { return }
        isRuntimeActive = active
        invalidatePendingRequests()
        if active {
            schedulePull()
            startPolling()
        }
    }

    func setLocalPersistenceBlocked(_ blocked: Bool) {
        guard isLocalPersistenceBlocked != blocked else { return }
        isLocalPersistenceBlocked = blocked
        // A response from before a failed write stays stale even if the write
        // recovers before that response arrives. The durable queue is untouched.
        invalidatePendingRequests()
        if !blocked {
            schedulePull()
            startPolling()
        }
    }

    /// Local persistence has already committed the snapshot and immutable outbox
    /// in one transaction. Debounce only wakes the sender; it owns no user data.
    func schedulePush(snapshot _: BrowserTabSessionSnapshot) {
        guard !supportedPushVersions.isEmpty else {
            schedulePull()
            return
        }
        pendingPushTask?.cancel()
        pendingPushTask = nil
        guard let context = currentContext() else { return }
        let debounce = pushDebounce
        pendingPushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self else { return }
            pendingPushTask = nil
            guard isCurrent(context) else { return }
            pendingPushContext = context
            startProcessing()
        }
    }

    func schedulePull() {
        guard let context = currentContext() else { return }
        pendingPullContext = context
        startProcessing()
    }

    /// A future profile scheduler supplies captured canonical sequences. This
    /// entry point persists only conditional intent; live tabs remain untouched.
    /// Capabilities are learned from the current session's completed pull and
    /// cleared during every pull, sign-out, pause and runtime generation change.
    @discardableResult func enqueueExpiry(operations: [BrowserSyncExpiryOperation]) throws -> String? {
        guard !operations.isEmpty else { return nil }
        guard let context = currentContext(), supportedPushVersions.isSuperset(of: [4, 5]),
              try localStore.syncPullProtocolVersion(for: context.owner) == 5
        else { throw BrowserRemoteSyncError.unsupportedSyncProtocol }
        let mutation = BrowserSyncExpiryMutation(id: UUID().uuidString, operations: operations)
        try localStore.enqueueSyncExpiry(mutation, for: context.owner)
        pendingPushContext = context
        startProcessing()
        return mutation.id
    }

    func setExpiryScheduler(_ scheduler: (any BrowserSyncExpiryScheduling)?) {
        expiryScheduler = scheduler
        lastExpirySweep = nil
        lastExpiryActivityRefresh = nil
        expiryCandidateCursor = nil
        expiryResponseLimits.removeAll()
    }

    /// Explicit settings or lifecycle wake. Periodic polling does not reset the
    /// cadence, so a terminal rejection cannot cause an immediate expiry loop.
    func requestExpirySweep() {
        lastExpirySweep = nil
        schedulePull()
    }

    func setSnapshotApplier(_ snapshotApplier: (any BrowserSyncSnapshotApplying)?) {
        self.snapshotApplier = snapshotApplier
    }

    /// Future polling/backoff timers are deliberately excluded from this drain.
    func waitForPendingOperations() async {
        while pendingPushTask != nil || processingTask != nil {
            await pendingPushTask?.value
            await processingTask?.value
        }
    }

    private func invalidatePendingRequests() {
        generation &+= 1
        pendingPushTask?.cancel()
        pendingPushTask = nil
        // Keep the worker handle until it returns. A transport may deliver a
        // response after cancellation; starting a second worker would overlap it.
        processingTask?.cancel()
        pollTask?.cancel()
        pollTask = nil
        clearRetry()
        pendingPushContext = nil
        pendingPullContext = nil
        supportedPushVersions = []
        lastExpirySweep = nil
        lastExpiryActivityRefresh = nil
        expiryCandidateCursor = nil
        expiryResponseLimits.removeAll()
    }

    private func owner(for session: BrowserAuthSession) -> BrowserSyncOwner {
        BrowserSyncOwner(baseURL: remoteClient.baseURL, userID: session.userID)
    }

    private func currentContext() -> RequestContext? {
        guard isRuntimeActive, !isLocalPersistenceBlocked,
              let session = activeSession, session == authSessionStore.loadSession()
        else { return nil }
        do {
            guard try !requiresSignIn(), try bindingState(for: session) == .enabled else { return nil }
            return RequestContext(session: session, owner: owner(for: session), generation: generation)
        } catch {
            Self.logger.error("Sync authorization failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func isCurrent(_ context: RequestContext) -> Bool {
        guard let current = currentContext() else { return false }
        return context.generation == current.generation && context.session == current.session && context
            .owner == current.owner
    }

    private func startPolling() {
        guard pollTask == nil, let interval = pollInterval, let context = currentContext() else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard let self, isCurrent(context) else { return }
                guard retryTask == nil else { continue }
                schedulePull()
            }
        }
    }

    private func scheduleRetry(context: RequestContext) {
        guard retryTask == nil, let retryDelay, isCurrent(context) else { return }
        let delay = retryDelay * (1 << min(retryAttempt, 5))
        retryAttempt = min(retryAttempt + 1, 5)
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self else { return }
            retryTask = nil
            guard isCurrent(context) else { return }
            schedulePull()
        }
    }

    private func clearRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
    }

    private func startProcessing() {
        guard processingTask == nil else { return }
        let workerGeneration = generation
        processingTask = Task { [weak self] in
            guard let self else { return }
            while workerGeneration == generation, !Task.isCancelled {
                if let context = pendingPullContext {
                    pendingPullContext = nil
                    await pull(context: context)
                } else if let context = pendingPushContext {
                    pendingPushContext = nil
                    await pushPending(context: context)
                } else {
                    break
                }
            }
            processingTask = nil
            if pendingPushContext != nil || pendingPullContext != nil {
                startProcessing()
            }
        }
    }

    private func pushPending(context: RequestContext) async {
        guard isCurrent(context), !Task.isCancelled, !supportedPushVersions.isEmpty else { return }
        do {
            var acknowledgedAny = false
            while isCurrent(context), !Task.isCancelled,
                  let mutation = try localStore.pendingSyncQueue(for: context.owner, limit: 1).first
            {
                guard supportedPushVersions.contains(mutation.protocolVersion) else {
                    // Never rewrite or bypass an immutable row after a server downgrade.
                    throw BrowserRemoteSyncError.unsupportedSyncProtocol
                }
                let events: [BrowserSyncEvent]
                var expiryResponse: BrowserSyncExpiryPushResponse?
                switch mutation {
                case .legacy(let payload):
                    let response = try await remoteClient.push(mutation: payload, authSession: context.session)
                    guard isCurrent(context), !Task.isCancelled else { return }
                    guard response.protocolVersion == 2, response.mutationID == payload.id, response.cursor >= 0 else {
                        throw BrowserRemoteSyncError.invalidMutationReceipt
                    }
                    events = response.events
                case .semantic(let payload):
                    let response = try await remoteClient.push(mutation: payload, authSession: context.session)
                    guard isCurrent(context), !Task.isCancelled else { return }
                    guard response.protocolVersion == 3, response.mutationID == payload.id, response.cursor >= 0,
                          response.outcomes.count == payload.operations.count,
                          Set(response.outcomes.map(\.operationIndex)) == Set(payload.operations.indices)
                    else { throw BrowserRemoteSyncError.invalidMutationReceipt }
                    events = response.events
                case .folders(let payload):
                    let response = try await remoteClient.push(mutation: payload, authSession: context.session)
                    guard isCurrent(context), !Task.isCancelled else { return }
                    guard response.protocolVersion == 4, response.mutationID == payload.id, response.cursor >= 0,
                          response.outcomes.count == payload.operations.count,
                          Set(response.outcomes.map(\.operationIndex)) == Set(payload.operations.indices)
                    else { throw BrowserRemoteSyncError.invalidMutationReceipt }
                    events = response.events
                case .expiry(let payload):
                    if try localStore.automaticExpiryNeedsValidation(id: payload.id, for: context.owner) {
                        var baseline: Data?
                        if let state = expiryScheduler?.expirySchedulingState(), state.inactiveForSeconds != nil {
                            let candidates = try await localStore.syncExpiryCandidates(
                                for: context.owner, state: state, now: dateProvider(), ignoringMutationID: payload.id,
                                validatingEntityIDs: Set(payload.operations.map(\.entityID)),
                            )
                            guard isCurrent(context), !Task.isCancelled else { return }
                            if let current = expiryScheduler?.expirySchedulingState(),
                               current.inactiveForSeconds == state.inactiveForSeconds,
                               payload.operations.allSatisfy({
                                   candidates.operations.contains($0) && !current.protectedTabIDs.contains($0.entityID)
                               })
                            {
                                baseline = candidates.baseline
                            }
                        }
                        guard isCurrent(context), !Task.isCancelled else { return }
                        if try !localStore.prepareAutomaticExpiry(
                            id: payload.id,
                            baseline: baseline,
                            for: context.owner,
                        ) {
                            // No network attempt occurred. Its inert overlay needs
                            // no projection; later ordinary rows may now drain.
                            continue
                        }
                    }
                    guard try localStore.syncPullProtocolVersion(for: context.owner) == 5 else {
                        throw BrowserRemoteSyncError.unsupportedSyncProtocol
                    }
                    let response = try await remoteClient.push(mutation: payload, authSession: context.session)
                    guard isCurrent(context), !Task.isCancelled else { return }
                    try response.validate(for: payload)
                    events = response.events
                    expiryResponse = response
                }
                guard isCurrent(context), !Task.isCancelled else { return }
                let previous = try localStore.loadSnapshotForSync(for: context.owner)
                let archiveRevision = try localStore.syncArchiveRevision(for: context.owner)
                let projected = try localStore.acknowledgeSyncMutation(
                    id: mutation.id,
                    protocolVersion: mutation.protocolVersion,
                    events: events,
                    for: context.owner,
                )
                if case .expiry(let payload) = mutation, let expiryResponse {
                    recordExpiryResponseLimits(expiryResponse, mutation: payload)
                }
                if previous != projected {
                    snapshotApplier?.applyRemoteSyncSnapshot(projected)
                }
                guard isCurrent(context), !Task.isCancelled else { return }
                if try archiveRevision != localStore.syncArchiveRevision(for: context.owner) {
                    snapshotApplier?.syncArchiveDidChange()
                }
                // Model projection can itself fail to persist and synchronously
                // block sync. Do not restore work from the invalidated generation.
                guard isCurrent(context), !Task.isCancelled else { return }
                acknowledgedAny = true
                if pendingPullContext != nil {
                    pendingPushContext = context
                    break
                }
            }
            guard isCurrent(context), !Task.isCancelled else { return }
            clearRetry()
            if acknowledgedAny {
                operationDidSucceed(.push)
                guard isCurrent(context), !Task.isCancelled else { return }
                pendingPullContext = context
            }
        } catch {
            guard isCurrent(context), !Task.isCancelled else { return }
            // The failed row and its exact payload remain on disk. Avoid an
            // immediate loop when local writes queued another wake during I/O.
            pendingPushContext = nil
            Self.logger.error("Sync push failed: \(error.localizedDescription, privacy: .public)")
            errorReporter(error, .push)
            scheduleRetry(context: context)
        }
    }

    private func scheduleAutomaticExpiry(context: RequestContext) async throws {
        guard isCurrent(context), !Task.isCancelled, supportedPushVersions.isSuperset(of: [4, 5]),
              try localStore.syncPullProtocolVersion(for: context.owner) == 5,
              let scheduler = expiryScheduler, scheduler.expirySchedulingState() != nil else { return }
        let now = dateProvider()
        guard now.timeIntervalSince1970.isFinite else { return }
        // Refresh active pages even when this device's automatic archival is Off:
        // another device may use a shorter timing. Persist before expiry capture.
        if lastExpiryActivityRefresh
            .map({ now.timeIntervalSince($0) >= expiryActivityRefreshInterval || now < $0 }) ?? true
        {
            guard scheduler.refreshExpiryActivity(), isCurrent(context), !Task.isCancelled else { return }
            lastExpiryActivityRefresh = now
        }
        guard try localStore.pendingSyncQueue(for: context.owner, limit: 1).isEmpty else {
            pendingPushContext = context
            return
        }
        guard let state = scheduler.expirySchedulingState(), state.inactiveForSeconds != nil,
              lastExpirySweep.map({ now.timeIntervalSince($0) >= expirySweepInterval || now < $0 }) ?? true
        else { return }
        lastExpirySweep = now
        let excluded = excludedExpiryCandidates(at: now)
        let batch = try await localStore.syncExpiryCandidates(
            for: context.owner, state: state, now: now, after: expiryCandidateCursor, excluding: excluded,
        )
        guard isCurrent(context), !Task.isCancelled,
              let current = scheduler.expirySchedulingState(), current.inactiveForSeconds == state.inactiveForSeconds
        else { return }
        let operations = batch.operations.filter { !current.protectedTabIDs.contains($0.entityID) }
        guard !operations.isEmpty else { return }
        do {
            try localStore.enqueueSyncExpiry(
                .init(id: UUID().uuidString, operations: operations), for: context.owner,
                automaticBaseline: batch.baseline,
            )
            if let last = operations.last {
                expiryCandidateCursor = .init(serverSeq: last.expectedServerSeq, entityID: last.entityID)
            }
            pendingPushContext = context
        } catch BrowserSyncExpiryError.candidatesChanged {
            // Local edits arrived during the background scan. Their scheduled
            // sender/poll will establish a new canonical baseline first.
        }
    }

    private func recordExpiryResponseLimits(
        _ response: BrowserSyncExpiryPushResponse, mutation: BrowserSyncExpiryMutation,
    ) {
        let now = dateProvider()
        guard now.timeIntervalSince1970.isFinite else { return }
        for outcome in response.outcomes {
            let operation = mutation.operations[outcome.operationIndex]
            let key = BrowserSyncExpiryCandidateCursor(
                serverSeq: operation.expectedServerSeq,
                entityID: operation.entityID,
            )
            guard outcome.reason == .responseLimit else {
                expiryResponseLimits.removeValue(forKey: key)
                continue
            }
            let failures = min(7, (expiryResponseLimits[key]?.failures ?? 0) + 1)
            var entry = ExpiryResponseLimit(failures: failures, recordedAt: now, retryAt: now)
            entry.retryAt = now.addingTimeInterval(entry.delay)
            expiryResponseLimits[key] = entry
        }
        // This is a runtime optimization, not durable suppression. Account or
        // generation changes clear it, and changed server sequences remain eligible.
        if expiryResponseLimits.count > 1000 {
            let oldest = expiryResponseLimits.sorted {
                if $0.value.recordedAt != $1.value.recordedAt {
                    return $0.value.recordedAt < $1.value.recordedAt
                }
                if $0.key.serverSeq != $1.key.serverSeq {
                    return $0.key.serverSeq < $1.key.serverSeq
                }
                return $0.key.entityID < $1.key.entityID
            }
            .prefix(expiryResponseLimits.count - 1000)
            for (key, _) in oldest {
                expiryResponseLimits.removeValue(forKey: key)
            }
        }
    }

    private func excludedExpiryCandidates(at now: Date) -> Set<BrowserSyncExpiryCandidateCursor> {
        var excluded = Set<BrowserSyncExpiryCandidateCursor>()
        for (key, var entry) in expiryResponseLimits {
            if now < entry.recordedAt {
                // A clock rollback cannot trigger a retry storm or postpone a
                // candidate until an arbitrarily distant former wall clock.
                entry.recordedAt = now
                entry.retryAt = now.addingTimeInterval(entry.delay)
                expiryResponseLimits[key] = entry
            }
            if now < entry.retryAt {
                excluded.insert(key)
            }
        }
        return excluded
    }

    private func pull(context: RequestContext) async {
        guard isCurrent(context), !Task.isCancelled else { return }
        supportedPushVersions = []
        do {
            let initialVersion = try localStore.syncPullProtocolVersion(for: context.owner)
            var protocolVersion = initialVersion
            var bootstrap = false
            var cursor = try localStore.syncCursor(for: context.owner)
            var latestEvents = [EntityKey: BrowserSyncEvent]()
            var advertisedVersions: Set<Int>?
            while true {
                let response: BrowserSyncPullResponse
                do {
                    response = try await remoteClient.pull(
                        cursor: cursor, protocolVersion: protocolVersion, authSession: context.session,
                    )
                } catch let error as BrowserRemoteSyncError where !bootstrap &&
                    ((protocolVersion == 4 && error.isFolderBootstrapRequired) ||
                        (protocolVersion == 5 && error.isExpiryBootstrapRequired))
                {
                    // A freshly registered device has no v4 read fence yet, even
                    // when this profile already has an adopted v4 baseline.
                    guard isCurrent(context), !Task.isCancelled else { return }
                    cursor = 0
                    bootstrap = true
                    latestEvents.removeAll()
                    advertisedVersions = nil
                    continue
                }
                guard isCurrent(context), !Task.isCancelled else { return }
                guard response.protocolVersion == protocolVersion else {
                    throw BrowserRemoteSyncError.unsupportedSyncProtocol
                }
                let pageVersions = Set(response.supportedPushVersions ?? [2]).intersection([2, 3, 4, 5])
                guard protocolVersion == 2 || pageVersions.contains(4),
                      protocolVersion != 5 || pageVersions.contains(5)
                else {
                    throw BrowserRemoteSyncError.unsupportedSyncProtocol
                }
                advertisedVersions = advertisedVersions.map { $0.intersection(pageVersions) } ?? pageVersions
                guard response.cursor >= cursor,
                      response.events.isEmpty || response.cursor > cursor
                else { throw BrowserRemoteSyncError.invalidPullCursor }
                // Only the newest authoritative state per identity is needed;
                // memory follows entity count rather than the entire event log.
                for event in response.events {
                    let key = EntityKey(type: event.entityType, id: event.entityID)
                    if event.serverSeq > (latestEvents[key]?.serverSeq ?? -1) {
                        latestEvents[key] = event
                    }
                }
                cursor = response.cursor
                if response.events.count < 500 {
                    // Drain every immutable legacy row before adoption. If a
                    // local edit arrives while the zero-based v4 pull is in
                    // flight, the storage transaction refuses the upgrade and
                    // the next cycle drains that row first.
                    if protocolVersion == 2, advertisedVersions?.contains(4) == true,
                       try localStore.pendingSyncQueue(for: context.owner, limit: 1).isEmpty
                    {
                        protocolVersion = 4
                        bootstrap = true
                        cursor = 0
                        latestEvents.removeAll()
                        advertisedVersions = nil
                        continue
                    }
                    if protocolVersion == 4, advertisedVersions?.contains(5) == true {
                        protocolVersion = 5
                        bootstrap = true
                        cursor = 0
                        latestEvents.removeAll()
                        advertisedVersions = nil
                        continue
                    }
                    break
                }
            }
            let previous = try localStore.loadSnapshotForSync(for: context.owner)
            let versions = advertisedVersions ?? []
            let events = latestEvents.values.sorted { $0.serverSeq < $1.serverSeq }
            let archiveRevision = try localStore.syncArchiveRevision(for: context.owner)
            let projected: BrowserTabSessionSnapshot =
                if bootstrap {
                    try protocolVersion == 5
                        ? localStore.completeExpirySyncBootstrap(events: events, cursor: cursor, for: context.owner)
                        : localStore.completeFolderSyncBootstrap(events: events, cursor: cursor, for: context.owner)
                } else {
                    try localStore.applyRemoteSyncEvents(
                        events, cursor: cursor, for: context.owner, enableSemanticMutations: versions.contains(3),
                    )
                }
            if previous != projected {
                snapshotApplier?.applyRemoteSyncSnapshot(projected)
            }
            guard isCurrent(context), !Task.isCancelled else { return }
            if try archiveRevision != localStore.syncArchiveRevision(for: context.owner) {
                snapshotApplier?.syncArchiveDidChange()
            }
            guard isCurrent(context), !Task.isCancelled else { return }
            supportedPushVersions = versions
            if try !localStore.pendingSyncQueue(for: context.owner, limit: 1).isEmpty {
                pendingPushContext = context
            } else {
                clearRetry()
            }
            operationDidSucceed(.pull)
            guard isCurrent(context), !Task.isCancelled else { return }
            try await scheduleAutomaticExpiry(context: context)
        } catch {
            guard isCurrent(context), !Task.isCancelled else { return }
            pendingPushContext = nil
            Self.logger.error("Sync pull failed: \(error.localizedDescription, privacy: .public)")
            errorReporter(error, .pull)
            scheduleRetry(context: context)
        }
    }
}

// MARK: - BrowserSyncSnapshotMerger

enum BrowserSyncSnapshotMerger {
    // MARK: Private

    private struct SpaceRecord {
        let id: String
        var title: String
        var systemImageName: String
        var rank: Double
        var isPinnedSectionCollapsed: Bool
        var selectedTabID: String?
    }

    private struct TabRecord {
        let id: String
        var spaceID: String
        var placement: BrowserTabPlacement
        var pinnedFolderID: String?
        var rank: Double
        var urlString: String
        var pinnedURLString: String?
        var userTitleOverride: String?
        var lastActivityTimestamp: TimeInterval?
    }

    // MARK: Internal

    static func snapshot(
        removing events: [BrowserSyncEvent],
        from snapshot: BrowserTabSessionSnapshot,
    ) -> BrowserTabSessionSnapshot {
        let deletedSpaceIDs = Set(events.filter { $0.entityType == "space" && $0.op == "delete" }.map(\.entityID))
        let deletedTabIDs = Set(events.filter { $0.entityType == "tab" && $0.op == "delete" }.map(\.entityID))
        guard !deletedSpaceIDs.isEmpty || !deletedTabIDs.isEmpty else { return snapshot }

        let tabs = snapshot.tabs.filter { tab in
            (tab.placement == .app || !deletedSpaceIDs.contains(tab.spaceID ?? BrowserSessionDefaults.defaultSpaceID))
                && !(tab.id.map(deletedTabIDs.contains) ?? false)
        }
        let spaces = snapshot.spaces?.filter { !deletedSpaceIDs.contains($0.id) }.map { space in
            let previousTabs = snapshot.tabs
                .filter { ($0.spaceID ?? BrowserSessionDefaults.defaultSpaceID) == space.id }
            let currentTabs = tabs.filter { ($0.spaceID ?? BrowserSessionDefaults.defaultSpaceID) == space.id }
            guard currentTabs != previousTabs else { return space }
            let selectedTabID = space.selectedTabIndex.flatMap { index in
                previousTabs.indices.contains(index) ? previousTabs[index].id : nil
            }
            return BrowserSpaceSessionSnapshot(
                id: space.id,
                title: space.title,
                systemImageName: space.systemImageName,
                isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                selectedTabIndex: selectedTabID.flatMap { selectedID in
                    currentTabs.firstIndex { $0.id == selectedID }
                },
            )
        }
        return BrowserTabSessionSnapshot(
            spaces: spaces,
            pinnedTabFolders: snapshot.pinnedTabFolders?.filter { !deletedSpaceIDs.contains($0.spaceID) },
            tabs: tabs,
        )
    }

    static func snapshot(
        applying events: [BrowserSyncEvent],
        to snapshot: BrowserTabSessionSnapshot?,
    ) -> BrowserTabSessionSnapshot {
        var spaces = [String: SpaceRecord]()
        var tabs = [String: TabRecord]()
        let activityDates = BrowserSyncActivityDates()

        let currentTabs = snapshot?.tabs ?? []
        let tabsBySpaceID = Dictionary(grouping: currentTabs) { tab in
            tab.spaceID ?? BrowserSessionDefaults.defaultSpaceID
        }

        for (index, space) in (snapshot?.spaces ?? []).enumerated() {
            let visibleTabs = tabsBySpaceID[space.id] ?? []
            let selectedTabID = space.selectedTabIndex.flatMap { selectedIndex in
                visibleTabs.indices.contains(selectedIndex) ? visibleTabs[selectedIndex].id : nil
            } ?? nil
            spaces[space.id] = SpaceRecord(
                id: space.id,
                title: space.title,
                systemImageName: space.systemImageName,
                rank: Double(index),
                isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                selectedTabID: selectedTabID,
            )
        }

        for (index, tab) in currentTabs.enumerated() {
            guard let id = tab.id else {
                continue
            }

            tabs[id] = TabRecord(
                id: id,
                spaceID: tab.spaceID ?? BrowserSessionDefaults.defaultSpaceID,
                placement: tab.placement,
                pinnedFolderID: tab.pinnedFolderID,
                rank: Double(index),
                urlString: tab.urlString,
                pinnedURLString: tab.placement == .spacePinned ? tab.pinnedURLString : nil,
                userTitleOverride: tab.userTitleOverride,
                lastActivityTimestamp: tab.lastActivityTimestamp,
            )
        }

        for event in events {
            switch (event.entityType, event.op, event.data) {
            case ("space", "delete", _):
                spaces.removeValue(forKey: event.entityID)
                tabs = tabs.filter { $0.value.placement == .app || $0.value.spaceID != event.entityID }
            case ("space", "upsert", .space(let data)):
                let existing = spaces[event.entityID]
                spaces[event.entityID] = SpaceRecord(
                    id: event.entityID,
                    title: sanitizedRequiredString(data.title) ?? existing?.title ?? "Space",
                    systemImageName: sanitizedRequiredString(data.systemImageName) ?? existing?
                        .systemImageName ?? BrowserSessionDefaults.defaultSpaceIconName,
                    rank: data.rank ?? existing?.rank ?? Double(spaces.count),
                    isPinnedSectionCollapsed: data.isPinnedSectionCollapsed ?? existing?
                        .isPinnedSectionCollapsed ?? false,
                    selectedTabID: data.selectedTabID ?? existing?.selectedTabID,
                )
            case ("tab", "delete", _):
                tabs.removeValue(forKey: event.entityID)
            case ("tab", "upsert", .tab(let data)):
                let existing = tabs[event.entityID]
                guard let urlString = sanitizedRequiredString(data.urlString) ?? existing?.urlString else {
                    continue
                }

                let placement = data.placement ?? existing?.placement ?? .temporary
                let pinnedURLString = placement == .spacePinned
                    ? data.pinnedURLString ?? existing?.pinnedURLString ?? urlString
                    : nil

                tabs[event.entityID] = TabRecord(
                    id: event.entityID,
                    spaceID: sanitizedRequiredString(data.spaceID) ?? existing?.spaceID ?? BrowserSessionDefaults
                        .defaultSpaceID,
                    placement: placement,
                    pinnedFolderID: existing?.pinnedFolderID,
                    rank: data.rank ?? existing?.rank ?? Double(tabs.count),
                    urlString: urlString,
                    pinnedURLString: pinnedURLString,
                    userTitleOverride: data.userTitleOverride ?? existing?.userTitleOverride,
                    lastActivityTimestamp: activityDates.projectedTimestamp(
                        data.lastActivityAt, local: existing?.lastActivityTimestamp,
                    ),
                )
            default:
                continue
            }
        }

        if spaces.isEmpty, tabs.values.contains(where: { $0.placement != .app }) {
            spaces[BrowserSessionDefaults.defaultSpaceID] = SpaceRecord(
                id: BrowserSessionDefaults.defaultSpaceID,
                title: "Space",
                systemImageName: BrowserSessionDefaults.defaultSpaceIconName,
                rank: 0,
                isPinnedSectionCollapsed: false,
                selectedTabID: nil,
            )
        }

        let sortedTabs = tabs.values.sorted {
            if $0.rank == $1.rank {
                return $0.id < $1.id
            }

            return $0.rank < $1.rank
        }
        let knownSpaceIDs = Set(spaces.keys)

        let tabSnapshots = sortedTabs.map { tab in
            BrowserTabSessionSnapshotTab(
                id: tab.id,
                urlString: tab.urlString,
                pinnedURLString: tab.placement == .spacePinned ? tab.pinnedURLString : nil,
                userTitleOverride: tab.userTitleOverride,
                placement: tab.placement,
                spaceID: tab.placement == .app || knownSpaceIDs.contains(tab.spaceID)
                    ? tab.spaceID
                    : BrowserSessionDefaults.defaultSpaceID,
                pinnedFolderID: tab.pinnedFolderID,
                lastActivityTimestamp: tab.lastActivityTimestamp,
            )
        }
        let tabIDsByPinnedFolderID = Dictionary(grouping: tabSnapshots.compactMap { tab -> (String, String)? in
            guard let pinnedFolderID = tab.pinnedFolderID, tab.placement == .spacePinned else {
                return nil
            }

            return (pinnedFolderID, tab.spaceID ?? BrowserSessionDefaults.defaultSpaceID)
        }) { item in
            item.0
        }
        let pinnedTabFolderSnapshots = (snapshot?.pinnedTabFolders ?? []).filter { folder in
            knownSpaceIDs.contains(folder.spaceID)
                && tabIDsByPinnedFolderID[folder.id]?.contains(where: { $0.1 == folder.spaceID }) == true
        }

        let tabsByResolvedSpaceID = Dictionary(grouping: tabSnapshots) { tab in
            tab.spaceID ?? BrowserSessionDefaults.defaultSpaceID
        }
        let spaceSnapshots = spaces.values
            .sorted {
                if $0.rank == $1.rank {
                    return $0.id < $1.id
                }

                return $0.rank < $1.rank
            }
            .map { space in
                let visibleTabs = tabsByResolvedSpaceID[space.id] ?? []
                let selectedTabIndex = space.selectedTabID.flatMap { selectedTabID in
                    visibleTabs.firstIndex { $0.id == selectedTabID }
                }
                return BrowserSpaceSessionSnapshot(
                    id: space.id,
                    title: space.title,
                    systemImageName: space.systemImageName,
                    isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                    selectedTabIndex: selectedTabIndex,
                )
            }

        return BrowserTabSessionSnapshot(
            spaces: spaceSnapshots.isEmpty ? nil : spaceSnapshots,
            pinnedTabFolders: pinnedTabFolderSnapshots.isEmpty ? nil : pinnedTabFolderSnapshots,
            tabs: tabSnapshots,
        )
    }

    private static func sanitizedRequiredString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
