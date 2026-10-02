import Foundation

// MARK: - BrowserSyncConfiguration

struct BrowserSyncConfiguration {
    // MARK: Lifecycle

    init?(baseURL: URL) {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }
        self.baseURL = BrowserSyncOwner(baseURL: baseURL, userID: "").baseURL
    }

    // MARK: Internal

    let baseURL: URL

    static func current(environment: [String: String] = ProcessInfo.processInfo
        .environment) -> BrowserSyncConfiguration?
    {
        guard
            let rawBaseURL = environment["THEBROWSER_SYNC_BASE_URL"],
            let baseURL = URL(string: rawBaseURL)
        else {
            return nil
        }

        return BrowserSyncConfiguration(baseURL: baseURL)
    }
}

// MARK: - BrowserAuthSession

struct BrowserAuthSession: Codable, Equatable {
    // MARK: Lifecycle

    init(accessToken: String, userID: String, userEmail: String?, deviceID: String, serverURL: URL? = nil) {
        self.accessToken = accessToken
        self.userID = userID
        self.userEmail = userEmail
        self.deviceID = deviceID
        self.serverURL = serverURL
    }

    // MARK: Internal

    let accessToken: String
    let userID: String
    let userEmail: String?
    let deviceID: String
    /// Legacy credentials have no issuer provenance and require a fresh sign-in.
    let serverURL: URL?

    func belongs(to baseURL: URL) -> Bool {
        guard let serverURL else { return false }
        return BrowserSyncOwner(baseURL: serverURL, userID: userID)
            == BrowserSyncOwner(baseURL: baseURL, userID: userID)
    }
}

// MARK: - BrowserSyncDevice

struct BrowserSyncDevice: Codable, Equatable {
    let id: String
    let name: String
    let platform: String
    let lastSeenAt: String?
}

// MARK: - BrowserAppleAuthRequest

struct BrowserAppleAuthRequest: Encodable {
    let identityToken: String
    let deviceName: String
    let devicePlatform: String
}

// MARK: - BrowserAppleAuthResponse

struct BrowserAppleAuthResponse: Decodable {
    struct User: Decodable, Equatable {
        let id: String
        let email: String?
    }

    let accessToken: String
    let expiresIn: Int
    let user: User
    let device: BrowserSyncDevice
}

// MARK: - BrowserSyncSpacePayload

struct BrowserSyncSpacePayload: Codable, Equatable {
    let title: String
    let systemImageName: String
    let rank: Double
    let isPinnedSectionCollapsed: Bool
    let selectedTabID: String?
}

// MARK: - BrowserSyncTabPayload

struct BrowserSyncTabPayload: Codable, Equatable {
    let spaceID: String
    let placement: BrowserTabPlacement
    let rank: Double
    let urlString: String
    let pinnedURLString: String?
    let title: String?
    let userTitleOverride: String?
    let faviconURLString: String?
    let lastActivityAt: String?
}

// MARK: - BrowserSyncChange

struct BrowserSyncChange: Encodable, Equatable {
    enum EntityType: String, Encodable {
        case space
        case tab
    }

    enum Operation: String, Encodable {
        case upsert
        case delete
    }

    enum CodingKeys: String, CodingKey {
        case entityType
        case entityID
        case op
        case data
    }

    let entityType: EntityType
    let entityID: String
    let op: Operation
    let spaceData: BrowserSyncSpacePayload?
    let tabData: BrowserSyncTabPayload?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entityType, forKey: .entityType)
        try container.encode(entityID, forKey: .entityID)
        try container.encode(op, forKey: .op)

        switch entityType {
        case .space:
            try container.encodeIfPresent(spaceData, forKey: .data)
        case .tab:
            try container.encodeIfPresent(tabData, forKey: .data)
        }
    }
}

// MARK: - BrowserSyncEvent

struct BrowserSyncEvent: Decodable, Equatable {
    let serverSeq: Int
    let deviceID: String?
    let entityType: String
    let entityID: String
    let op: String
    let data: BrowserSyncEventData
    let createdAt: String
}

// MARK: - BrowserSyncEventData

enum BrowserSyncEventData: Decodable, Equatable {
    case space(BrowserSyncEventSpaceData)
    case tab(BrowserSyncEventTabData)
    case deleted(id: String)
    case unknown

    // MARK: Lifecycle

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let space = try? container.decode(BrowserSyncEventSpaceData.self), space.title != nil {
            self = .space(space)
            return
        }

        if let tab = try? container.decode(BrowserSyncEventTabData.self), tab.urlString != nil {
            self = .tab(tab)
            return
        }

        if let deleted = try? container.decode(BrowserSyncDeletedData.self) {
            self = .deleted(id: deleted.id)
            return
        }

        self = .unknown
    }
}

// MARK: - BrowserSyncEventSpaceData

struct BrowserSyncEventSpaceData: Decodable, Equatable {
    let id: String
    let title: String?
    let systemImageName: String?
    let rank: Double?
    let isPinnedSectionCollapsed: Bool?
    let selectedTabID: String?
}

// MARK: - BrowserSyncEventTabData

struct BrowserSyncEventTabData: Decodable, Equatable {
    let id: String
    let spaceID: String?
    let placement: BrowserTabPlacement?
    let rank: Double?
    let urlString: String?
    let pinnedURLString: String?
    let title: String?
    let userTitleOverride: String?
    let faviconURLString: String?
    let lastActivityAt: String?
}

// MARK: - BrowserSyncDeletedData

private struct BrowserSyncDeletedData: Decodable {
    let id: String
}

// MARK: - BrowserSyncPushRequest

struct BrowserSyncPushRequest: Encodable {
    let deviceID: String
    let changes: [BrowserSyncChange]
}

// MARK: - BrowserSyncPushResponse

struct BrowserSyncPushResponse: Decodable {
    let cursor: Int
    let events: [BrowserSyncEvent]
}

// MARK: - BrowserSyncPullRequest

struct BrowserSyncPullRequest: Encodable {
    let deviceID: String
    let cursor: Int
    let limit: Int
}

// MARK: - BrowserSyncPullResponse

struct BrowserSyncPullResponse: Decodable {
    let cursor: Int
    let events: [BrowserSyncEvent]
}

// MARK: - BrowserSyncCoordinating

@MainActor protocol BrowserSyncCoordinating: AnyObject {
    func schedulePush(snapshot: BrowserTabSessionSnapshot)
    func schedulePull()
}

// MARK: - BrowserSyncSnapshotApplying

@MainActor protocol BrowserSyncSnapshotApplying: AnyObject {
    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot)
}
