import Foundation
import Gzip
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import OSLog
import Security

// MARK: - BrowserRemoteSyncClient

final class BrowserRemoteSyncClient: @unchecked Sendable {
    // MARK: Lifecycle

    init(configuration: BrowserSyncConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.openAPITransport = URLSessionTransport(configuration: .init(session: session))
    }

    // MARK: Internal

    static func changes(
        from previousSnapshot: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot
    ) -> [BrowserSyncChange] {
        var changes = [BrowserSyncChange]()
        let previousSpaceIDs = Set(previousSnapshot?.spaces?.map(\.id) ?? [])
        let currentSpaceIDs = Set(snapshot.spaces?.map(\.id) ?? [])
        let previousTabIDs = Set(previousSnapshot?.tabs.compactMap(\.id) ?? [])
        let currentTabIDs = Set(snapshot.tabs.compactMap(\.id))

        for (index, space) in (snapshot.spaces ?? []).enumerated() {
            changes.append(
                BrowserSyncChange(
                    entityType: .space,
                    entityID: space.id,
                    op: .upsert,
                    spaceData: BrowserSyncSpacePayload(
                        title: space.title,
                        systemImageName: space.systemImageName,
                        rank: Double(index),
                        isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                        selectedTabID: nil
                    ),
                    tabData: nil
                )
            )
        }

        for deletedSpaceID in previousSpaceIDs.subtracting(currentSpaceIDs) {
            changes.append(
                BrowserSyncChange(
                    entityType: .space,
                    entityID: deletedSpaceID,
                    op: .delete,
                    spaceData: nil,
                    tabData: nil
                )
            )
        }

        for (index, tab) in snapshot.tabs.enumerated() {
            guard let tabID = tab.id else {
                continue
            }

            changes.append(
                BrowserSyncChange(
                    entityType: .tab,
                    entityID: tabID,
                    op: .upsert,
                    spaceData: nil,
                    tabData: BrowserSyncTabPayload(
                        spaceID: tab.spaceID ?? BrowserChromeModel.defaultSpaceID,
                        placement: tab.placement,
                        rank: Double(index),
                        urlString: tab.urlString,
                        pinnedURLString: tab.pinnedURLString,
                        title: nil,
                        userTitleOverride: tab.userTitleOverride,
                        faviconURLString: nil,
                        lastActivityAt: tab.lastActivityTimestamp.map { Self.iso8601String(from: $0) }
                    )
                )
            )
        }

        for deletedTabID in previousTabIDs.subtracting(currentTabIDs) {
            changes.append(
                BrowserSyncChange(
                    entityType: .tab,
                    entityID: deletedTabID,
                    op: .delete,
                    spaceData: nil,
                    tabData: nil
                )
            )
        }

        return changes
    }

    func authenticateWithApple(
        identityToken: String,
        deviceName: String = Host.current().localizedName ?? "Mac",
        devicePlatform: String = "macOS"
    ) async throws -> BrowserAuthSession {
        let request = BrowserAppleAuthRequest(
            identityToken: identityToken,
            deviceName: deviceName,
            devicePlatform: devicePlatform
        )
        let response = try await Self.authResponse(
            from: openAPIClient(accessToken: nil).authenticateWithApple(
                .init(
                    body: .json(
                        Components.Schemas.AuthAppleRequest(
                            identityToken: request.identityToken,
                            deviceName: request.deviceName,
                            devicePlatform: request.devicePlatform
                        )
                    )
                )
            )
        )
        return BrowserAuthSession(
            accessToken: response.accessToken,
            userID: response.user.id,
            userEmail: response.user.email,
            deviceID: response.device.id
        )
    }

    func push(
        snapshot: BrowserTabSessionSnapshot,
        previousSnapshot: BrowserTabSessionSnapshot?,
        authSession: BrowserAuthSession
    ) async throws -> BrowserSyncPushResponse {
        let request = BrowserSyncPushRequest(
            deviceID: authSession.deviceID,
            changes: Self.changes(from: previousSnapshot, to: snapshot)
        )
        return try await send(
            path: "/v1/sync/push",
            method: "POST",
            body: request,
            accessToken: authSession.accessToken
        )
    }

    func pull(cursor: Int, authSession: BrowserAuthSession) async throws -> BrowserSyncPullResponse {
        try await send(
            path: "/v1/sync/pull",
            method: "POST",
            body: BrowserSyncPullRequest(deviceID: authSession.deviceID, cursor: cursor, limit: 500),
            accessToken: authSession.accessToken
        )
    }

    // MARK: Private

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let gzipRequestThreshold = 1024

    private let configuration: BrowserSyncConfiguration
    private let session: URLSession
    private let openAPITransport: URLSessionTransport

    private static func iso8601String(from timeInterval: TimeInterval) -> String {
        iso8601String(from: Date(timeIntervalSince1970: timeInterval))
    }

    private static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func authResponse(
        from output: Operations.authenticateWithApple.Output
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
                        email: body.user.email
                    ),
                    device: BrowserSyncDevice(
                        id: body.device.id,
                        name: body.device.name,
                        platform: body.device.platform,
                        lastSeenAt: body.device.lastSeenAt.map { Self.iso8601String(from: $0) }
                    )
                )
            }
        default:
            throw BrowserRemoteSyncError.unexpectedOpenAPIResponse
        }
    }

    private func openAPIClient(accessToken: String?) -> Client {
        Client(
            serverURL: configuration.baseURL,
            transport: openAPITransport,
            middlewares: [
                BrowserOpenAPIRequestMiddleware(accessToken: accessToken),
            ]
        )
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: some Encodable,
        accessToken: String?
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
}

// MARK: - BrowserOpenAPIRequestMiddleware

private struct BrowserOpenAPIRequestMiddleware: ClientMiddleware {
    let accessToken: String?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID _: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
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
    // MARK: Lifecycle

    init(
        service: String = Bundle.main.bundleIdentifier ?? "com.levochkaa.TheBrowser",
        profileID: String? = nil
    ) {
        self.service = "\(service).sync"
        self.sessionAccount =
            if
                let profileID,
                profileID != BrowserProfile.defaultDirectoryName
            {
                "\(Key.session).\(profileID)"
            } else {
                Key.session
            }
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

    func clearSession() {
        deleteKeychainData(account: sessionAccount)
    }

    // MARK: Private

    private enum Key {
        static let session = "auth-session"
    }

    private let service: String
    private let sessionAccount: String

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

    private func deleteKeychainData(account: String) {
        SecItemDelete(keychainQuery(account: account) as CFDictionary)
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
    func push(
        snapshot: BrowserTabSessionSnapshot,
        previousSnapshot: BrowserTabSessionSnapshot?,
        authSession: BrowserAuthSession
    ) async throws -> BrowserSyncPushResponse

    func pull(cursor: Int, authSession: BrowserAuthSession) async throws -> BrowserSyncPullResponse
}

// MARK: - BrowserRemoteSyncClient + BrowserSyncRemoteServing

extension BrowserRemoteSyncClient: BrowserSyncRemoteServing {}

// MARK: - BrowserSyncAuthSessionReading

@MainActor protocol BrowserSyncAuthSessionReading: AnyObject {
    func loadSession() -> BrowserAuthSession?
}

// MARK: - BrowserAuthSessionStore + BrowserSyncAuthSessionReading

extension BrowserAuthSessionStore: BrowserSyncAuthSessionReading {}

// MARK: - BrowserSyncService

@MainActor final class BrowserSyncService: BrowserSyncCoordinating {
    // MARK: Lifecycle

    init(
        localStore: BrowserSQLiteSessionStore,
        remoteClient: any BrowserSyncRemoteServing,
        authSessionStore: any BrowserSyncAuthSessionReading,
        pushDebounce: Duration = .milliseconds(750)
    ) {
        self.localStore = localStore
        self.remoteClient = remoteClient
        self.authSessionStore = authSessionStore
        self.pushDebounce = pushDebounce
    }

    // MARK: Internal

    func schedulePush(snapshot: BrowserTabSessionSnapshot) {
        pendingPushTask?.cancel()
        pendingPush = nil
        guard let authSession = authSessionStore.loadSession() else {
            pendingPushTask = nil
            return
        }

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
            guard authSessionStore.loadSession() == authSession else { return }
            pendingPush = PendingPush(snapshot: snapshot, authSession: authSession)
            startProcessing()
        }
    }

    func schedulePull() {
        guard let authSession = authSessionStore.loadSession() else { return }
        pendingPullSession = authSession
        startProcessing()
    }

    func setSnapshotApplier(_ snapshotApplier: (any BrowserSyncSnapshotApplying)?) {
        self.snapshotApplier = snapshotApplier
    }

    func waitForPendingOperations() async {
        while pendingPushTask != nil || processingTask != nil {
            await pendingPushTask?.value
            await processingTask?.value
        }
    }

    // MARK: Private

    private struct PendingPush {
        let snapshot: BrowserTabSessionSnapshot
        let authSession: BrowserAuthSession
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.levochkaa.TheBrowser",
        category: "Sync"
    )

    private let localStore: BrowserSQLiteSessionStore
    private let remoteClient: any BrowserSyncRemoteServing
    private let authSessionStore: any BrowserSyncAuthSessionReading
    private let pushDebounce: Duration
    private var previousPushedSnapshot: BrowserTabSessionSnapshot?
    private var previousPushedSession: BrowserAuthSession?
    private var pendingPushTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var pendingPush: PendingPush?
    private var pendingPullSession: BrowserAuthSession?

    private weak var snapshotApplier: (any BrowserSyncSnapshotApplying)?

    private func startProcessing() {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            while pendingPush != nil || pendingPullSession != nil {
                if let push = pendingPush {
                    pendingPush = nil
                    await self.push(snapshot: push.snapshot, authSession: push.authSession)
                } else if let authSession = pendingPullSession {
                    pendingPullSession = nil
                    await pull(authSession: authSession)
                }
            }
            processingTask = nil
        }
    }

    private func push(snapshot: BrowserTabSessionSnapshot, authSession: BrowserAuthSession) async {
        guard authSessionStore.loadSession() == authSession else { return }

        do {
            let response = try await remoteClient.push(
                snapshot: snapshot,
                previousSnapshot: previousPushedSession == authSession ? previousPushedSnapshot : nil,
                authSession: authSession
            )
            guard authSessionStore.loadSession() == authSession else { return }
            // A push receipt covers only this client's writes, not the unread pull stream.
            // Permanent identity tombstones also correct stale upserts, even when
            // their original delete event is older than the saved pull cursor.
            let deletes = response.events.filter { $0.op == "delete" }
            if !deletes.isEmpty, let latestSnapshot = localStore.loadSnapshot() {
                let correctedSnapshot = BrowserSyncSnapshotMerger.snapshot(removing: deletes, from: latestSnapshot)
                if correctedSnapshot != latestSnapshot {
                    localStore.saveSnapshot(correctedSnapshot)
                    snapshotApplier?.applyRemoteSyncSnapshot(correctedSnapshot)
                }
            }
            // Echoed upserts describe the sent snapshot and must not overwrite
            // local edits made while this request was in flight.
            previousPushedSnapshot = BrowserSyncSnapshotMerger.snapshot(removing: deletes, from: snapshot)
            previousPushedSession = authSession
        } catch {
            Self.logger.error("Sync push failed: \(error.localizedDescription, privacy: .public)")
            BrowserTelemetry.captureError(error, event: .syncPushFailed)
        }
    }

    private func pull(authSession: BrowserAuthSession) async {
        guard authSessionStore.loadSession() == authSession else { return }

        do {
            let response = try await remoteClient.pull(cursor: localStore.syncCursor(), authSession: authSession)
            guard authSessionStore.loadSession() == authSession else { return }
            if !response.events.isEmpty {
                let snapshot = BrowserSyncSnapshotMerger.snapshot(
                    applying: response.events,
                    to: localStore.loadSnapshot()
                )
                localStore.saveSnapshot(snapshot)
                previousPushedSnapshot = snapshot
                previousPushedSession = authSession
                snapshotApplier?.applyRemoteSyncSnapshot(snapshot)
            }
            localStore.saveSyncCursor(max(localStore.syncCursor(), response.cursor))
        } catch {
            Self.logger.error("Sync pull failed: \(error.localizedDescription, privacy: .public)")
            BrowserTelemetry.captureError(error, event: .syncPullFailed)
        }
    }
}

// MARK: - BrowserSyncSnapshotMerger

enum BrowserSyncSnapshotMerger {
    // MARK: Internal

    static func snapshot(
        removing events: [BrowserSyncEvent],
        from snapshot: BrowserTabSessionSnapshot
    ) -> BrowserTabSessionSnapshot {
        let deletedSpaceIDs = Set(events.filter { $0.entityType == "space" && $0.op == "delete" }.map(\.entityID))
        let deletedTabIDs = Set(events.filter { $0.entityType == "tab" && $0.op == "delete" }.map(\.entityID))
        guard !deletedSpaceIDs.isEmpty || !deletedTabIDs.isEmpty else { return snapshot }

        let tabs = snapshot.tabs.filter { tab in
            !deletedSpaceIDs.contains(tab.spaceID ?? BrowserChromeModel.defaultSpaceID)
                && !(tab.id.map(deletedTabIDs.contains) ?? false)
        }
        let spaces = snapshot.spaces?.filter { !deletedSpaceIDs.contains($0.id) }.map { space in
            let previousTabs = snapshot.tabs.filter { ($0.spaceID ?? BrowserChromeModel.defaultSpaceID) == space.id }
            let currentTabs = tabs.filter { ($0.spaceID ?? BrowserChromeModel.defaultSpaceID) == space.id }
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
                }
            )
        }
        return BrowserTabSessionSnapshot(
            spaces: spaces,
            pinnedTabFolders: snapshot.pinnedTabFolders?.filter { !deletedSpaceIDs.contains($0.spaceID) },
            tabs: tabs
        )
    }

    static func snapshot(
        applying events: [BrowserSyncEvent],
        to snapshot: BrowserTabSessionSnapshot?
    ) -> BrowserTabSessionSnapshot {
        var spaces = [String: SpaceRecord]()
        var tabs = [String: TabRecord]()

        let currentTabs = snapshot?.tabs ?? []
        let tabsBySpaceID = Dictionary(grouping: currentTabs) { tab in
            tab.spaceID ?? BrowserChromeModel.defaultSpaceID
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
                selectedTabID: selectedTabID
            )
        }

        for (index, tab) in currentTabs.enumerated() {
            guard let id = tab.id else {
                continue
            }

            tabs[id] = TabRecord(
                id: id,
                spaceID: tab.spaceID ?? BrowserChromeModel.defaultSpaceID,
                placement: tab.placement,
                pinnedFolderID: tab.pinnedFolderID,
                rank: Double(index),
                urlString: tab.urlString,
                pinnedURLString: tab.placement == .spacePinned ? tab.pinnedURLString : nil,
                userTitleOverride: tab.userTitleOverride,
                lastActivityTimestamp: tab.lastActivityTimestamp
            )
        }

        for event in events {
            switch (event.entityType, event.op, event.data) {
            case ("space", "delete", _):
                spaces.removeValue(forKey: event.entityID)
                tabs = tabs.filter { $0.value.spaceID != event.entityID }
            case ("space", "upsert", .space(let data)):
                let existing = spaces[event.entityID]
                spaces[event.entityID] = SpaceRecord(
                    id: event.entityID,
                    title: sanitizedRequiredString(data.title) ?? existing?.title ?? "Space",
                    systemImageName: sanitizedRequiredString(data.systemImageName) ?? existing?
                        .systemImageName ?? BrowserChromeModel.defaultSpaceIconName,
                    rank: data.rank ?? existing?.rank ?? Double(spaces.count),
                    isPinnedSectionCollapsed: data.isPinnedSectionCollapsed ?? existing?
                        .isPinnedSectionCollapsed ?? false,
                    selectedTabID: data.selectedTabID ?? existing?.selectedTabID
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
                    spaceID: sanitizedRequiredString(data.spaceID) ?? existing?.spaceID ?? BrowserChromeModel
                        .defaultSpaceID,
                    placement: placement,
                    pinnedFolderID: existing?.pinnedFolderID,
                    rank: data.rank ?? existing?.rank ?? Double(tabs.count),
                    urlString: urlString,
                    pinnedURLString: pinnedURLString,
                    userTitleOverride: data.userTitleOverride ?? existing?.userTitleOverride,
                    lastActivityTimestamp: data.lastActivityAt.flatMap(lastActivityTimestamp)
                        ?? existing?.lastActivityTimestamp
                )
            default:
                continue
            }
        }

        if spaces.isEmpty, !tabs.isEmpty {
            spaces[BrowserChromeModel.defaultSpaceID] = SpaceRecord(
                id: BrowserChromeModel.defaultSpaceID,
                title: "Space",
                systemImageName: BrowserChromeModel.defaultSpaceIconName,
                rank: 0,
                isPinnedSectionCollapsed: false,
                selectedTabID: nil
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
                spaceID: knownSpaceIDs.contains(tab.spaceID) ? tab.spaceID : BrowserChromeModel.defaultSpaceID,
                pinnedFolderID: tab.pinnedFolderID,
                lastActivityTimestamp: tab.lastActivityTimestamp
            )
        }
        let tabIDsByPinnedFolderID = Dictionary(grouping: tabSnapshots.compactMap { tab -> (String, String)? in
            guard let pinnedFolderID = tab.pinnedFolderID, tab.placement == .spacePinned else {
                return nil
            }

            return (pinnedFolderID, tab.spaceID ?? BrowserChromeModel.defaultSpaceID)
        }) { item in
            item.0
        }
        let pinnedTabFolderSnapshots = (snapshot?.pinnedTabFolders ?? []).filter { folder in
            knownSpaceIDs.contains(folder.spaceID)
                && tabIDsByPinnedFolderID[folder.id]?.contains(where: { $0.1 == folder.spaceID }) == true
        }

        let tabsByResolvedSpaceID = Dictionary(grouping: tabSnapshots) { tab in
            tab.spaceID ?? BrowserChromeModel.defaultSpaceID
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
                    selectedTabIndex: selectedTabIndex
                )
            }

        return BrowserTabSessionSnapshot(
            spaces: spaceSnapshots.isEmpty ? nil : spaceSnapshots,
            pinnedTabFolders: pinnedTabFolderSnapshots.isEmpty ? nil : pinnedTabFolderSnapshots,
            tabs: tabSnapshots
        )
    }

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

    private static func sanitizedRequiredString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func lastActivityTimestamp(from value: String) -> TimeInterval? {
        ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970
    }
}
