// BrowserSyncModels.swift

import Foundation

// MARK: - BrowserSyncConfiguration

struct BrowserSyncConfiguration {
    // MARK: Internal

    let baseURL: URL

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

    /// The server the build ships with, unless `OPENARC_SYNC_BASE_URL`
    /// names another; an empty value turns sync off. An instance started with
    /// `--runtime-suffix` has a profile of its own but shares the account's
    /// sign-in, so it syncs only with `OPENARC_SYNC_BASE_URL` set.
    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        packagedBaseURL: String? = Bundle.main.object(forInfoDictionaryKey: "OpenArcSyncBaseURL") as? String,
    ) -> BrowserSyncConfiguration? {
        let packagedBaseURL = BrowserRuntimeIdentity.suffix(arguments: arguments) == nil ? packagedBaseURL : nil
        guard
            let rawBaseURL = environment["OPENARC_SYNC_BASE_URL"] ?? packagedBaseURL,
            let baseURL = URL(string: rawBaseURL)
        else {
            return nil
        }

        return BrowserSyncConfiguration(baseURL: baseURL)
    }
}

// MARK: - BrowserAuthSession

struct BrowserAuthSession: Codable, Equatable {
    // MARK: Internal

    let accessToken: String
    let userID: String
    let userEmail: String?
    let deviceID: String
    /// Legacy credentials have no issuer provenance and require a fresh sign-in.
    let serverURL: URL?

    init(accessToken: String, userID: String, userEmail: String?, deviceID: String, serverURL: URL? = nil) {
        self.accessToken = accessToken
        self.userID = userID
        self.userEmail = userEmail
        self.deviceID = deviceID
        self.serverURL = serverURL
    }

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
    // MARK: Internal

    let spaceID: String
    let placement: BrowserTabPlacement
    let rank: Double
    let urlString: String
    let pinnedURLString: String?
    let title: String?
    let userTitleOverride: String?
    let faviconURLString: String?
    let lastActivityAt: String?
    let pinnedFolderID: String?

    init(
        spaceID: String, placement: BrowserTabPlacement, rank: Double, urlString: String,
        pinnedURLString: String?, title: String?, userTitleOverride: String?,
        faviconURLString: String?, lastActivityAt: String?, pinnedFolderID: String? = nil,
    ) {
        self.spaceID = spaceID
        self.placement = placement
        self.rank = rank
        self.urlString = urlString
        self.pinnedURLString = pinnedURLString
        self.title = title
        self.userTitleOverride = userTitleOverride
        self.faviconURLString = faviconURLString
        self.lastActivityAt = lastActivityAt
        self.pinnedFolderID = pinnedFolderID
    }
}

// MARK: - BrowserSyncChange

struct BrowserSyncChange: Codable, Equatable {
    // MARK: Internal

    enum EntityType: String, Codable, Hashable {
        case space
        case tab
        case folder
    }

    enum Operation: String, Codable {
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
    let folderData: BrowserSyncFolderPayload?

    init(
        entityType: EntityType,
        entityID: String,
        op: Operation,
        spaceData: BrowserSyncSpacePayload?,
        tabData: BrowserSyncTabPayload?,
        folderData: BrowserSyncFolderPayload? = nil,
    ) {
        self.entityType = entityType
        self.entityID = entityID
        self.op = op
        self.spaceData = spaceData
        self.tabData = tabData
        self.folderData = folderData
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.entityType = try values.decode(EntityType.self, forKey: .entityType)
        self.entityID = try values.decode(String.self, forKey: .entityID)
        self.op = try values.decode(Operation.self, forKey: .op)
        switch entityType {
        case .space:
            self.spaceData = try values.decodeIfPresent(BrowserSyncSpacePayload.self, forKey: .data)
            self.tabData = nil
            self.folderData = nil
        case .tab:
            self.tabData = try values.decodeIfPresent(BrowserSyncTabPayload.self, forKey: .data)
            self.spaceData = nil
            self.folderData = nil
        case .folder:
            self.folderData = try values.decodeIfPresent(BrowserSyncFolderPayload.self, forKey: .data)
            self.spaceData = nil
            self.tabData = nil
        }
    }

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
        case .folder:
            try container.encodeIfPresent(folderData, forKey: .data)
        }
    }
}

// MARK: - BrowserSyncMutation

struct BrowserSyncMutation: Codable, Equatable {
    let id: String
    let changes: [BrowserSyncChange]
}

// MARK: - BrowserSyncEvent

struct BrowserSyncEvent: Codable, Equatable {
    // MARK: Internal

    let serverSeq: Int
    let deviceID: String?
    let entityType: String
    let entityID: String
    let op: String
    let data: BrowserSyncEventData
    let createdAt: String

    init(
        serverSeq: Int, deviceID: String?, entityType: String, entityID: String,
        op: String, data: BrowserSyncEventData, createdAt: String,
    ) {
        self.serverSeq = serverSeq
        self.deviceID = deviceID
        self.entityType = entityType
        self.entityID = entityID
        self.op = op
        self.data = data
        self.createdAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.serverSeq = try values.decode(Int.self, forKey: .serverSeq)
        self.deviceID = try values.decodeIfPresent(String.self, forKey: .deviceID)
        self.entityType = try values.decode(String.self, forKey: .entityType)
        self.entityID = try values.decode(String.self, forKey: .entityID)
        self.op = try values.decode(String.self, forKey: .op)
        self.createdAt = try values.decode(String.self, forKey: .createdAt)
        self.data =
            if op == "delete" {
                try Self.deletedData(values.decode(BrowserSyncDeletedData.self, forKey: .data))
            } else {
                // Folder and tab metadata can both contain a title. The envelope,
                // never the presence of a metadata field, determines the payload.
                switch entityType {
                case "space": try .space(values.decode(BrowserSyncEventSpaceData.self, forKey: .data))
                case "tab": try .tab(values.decode(BrowserSyncEventTabData.self, forKey: .data))
                case "folder": try .folder(values.decode(BrowserSyncEventFolderData.self, forKey: .data))
                case "boost": try .boost(values.decode(BrowserSyncEventBoostData.self, forKey: .data))
                case BrowserSyncMobileTabOperation.entityType:
                    try .mobileTab(values.decode(BrowserSyncEventMobileTabData.self, forKey: .data))
                default: .unknown
                }
            }
    }

    /// Spaces, tabs and folders; boosts and mobile tabs keep baselines of their own.
    var belongsToSpaces: Bool {
        entityType != "boost" && entityType != BrowserSyncMobileTabOperation.entityType
    }

    // MARK: Private

    private static func deletedData(_ data: BrowserSyncDeletedData) -> BrowserSyncEventData {
        .deleted(id: data.id, autoArchive: data.autoArchive)
    }
}

// MARK: - BrowserSyncEventData

enum BrowserSyncEventData: Codable, Equatable {
    case space(BrowserSyncEventSpaceData)
    case tab(BrowserSyncEventTabData)
    case folder(BrowserSyncEventFolderData)
    case boost(BrowserSyncEventBoostData)
    case mobileTab(BrowserSyncEventMobileTabData)
    case deleted(id: String, autoArchive: BrowserSyncAutoArchiveData? = nil)
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // A mobile tab has a URL like a tab, but a creation date and no placement.
        if let tab = try? container.decode(BrowserSyncEventMobileTabData.self), tab.urlString != nil,
           tab.createdAt != nil, (try? container.decode(BrowserSyncEventTabData.self))?.placement == nil
        {
            self = .mobileTab(tab)
            return
        }
        if let tab = try? container.decode(BrowserSyncEventTabData.self), tab.urlString != nil {
            self = .tab(tab)
            return
        }
        if let folder = try? container.decode(BrowserSyncEventFolderData.self), folder.spaceID != nil,
           folder.title != nil
        {
            self = .folder(folder)
            return
        }
        if let boost = try? container.decode(BrowserSyncEventBoostData.self), boost.host != nil, boost.css != nil {
            self = .boost(boost)
            return
        }
        if let space = try? container.decode(BrowserSyncEventSpaceData.self), space.title != nil {
            self = .space(space)
            return
        }

        if let deleted = try? container.decode(BrowserSyncDeletedData.self) {
            self = .deleted(id: deleted.id, autoArchive: deleted.autoArchive)
            return
        }

        self = .unknown
    }

    // MARK: Internal

    func encode(to encoder: any Encoder) throws {
        var values = encoder.singleValueContainer()
        switch self {
        case .space(let data): try values.encode(data)
        case .tab(let data): try values.encode(data)
        case .folder(let data): try values.encode(data)
        case .boost(let data): try values.encode(data)
        case .mobileTab(let data): try values.encode(data)
        case .deleted(let id, let autoArchive): try values.encode(BrowserSyncDeletedData(
                id: id,
                autoArchive: autoArchive,
            ))
        case .unknown: try values.encode([String: String]())
        }
    }
}

// MARK: - BrowserSyncEventSpaceData

struct BrowserSyncEventSpaceData: Codable, Equatable {
    let id: String
    let title: String?
    let systemImageName: String?
    let rank: Double?
    let isPinnedSectionCollapsed: Bool?
    let selectedTabID: String?
}

// MARK: - BrowserSyncEventTabData

struct BrowserSyncEventTabData: Codable, Equatable {
    // MARK: Internal

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
    let pinnedFolderID: String?

    init(
        id: String, spaceID: String?, placement: BrowserTabPlacement?, rank: Double?,
        urlString: String?, pinnedURLString: String?, title: String?, userTitleOverride: String?,
        faviconURLString: String?, lastActivityAt: String?, pinnedFolderID: String? = nil,
    ) {
        self.id = id
        self.spaceID = spaceID
        self.placement = placement
        self.rank = rank
        self.urlString = urlString
        self.pinnedURLString = pinnedURLString
        self.title = title
        self.userTitleOverride = userTitleOverride
        self.faviconURLString = faviconURLString
        self.lastActivityAt = lastActivityAt
        self.pinnedFolderID = pinnedFolderID
    }
}

// MARK: - BrowserSyncEventFolderData

struct BrowserSyncEventFolderData: Codable, Equatable {
    let id: String
    let spaceID: String?
    let parentFolderID: String?
    let title: String?
    let systemImageName: String?
    let rank: Double?
}

// MARK: - BrowserSyncDeletedData

private struct BrowserSyncDeletedData: Codable {
    let id: String
    let autoArchive: BrowserSyncAutoArchiveData?
}

// MARK: - BrowserSyncPushRequest

struct BrowserSyncPushRequest: Encodable {
    let protocolVersion = 2
    let mutationID: String
    let deviceID: String
    let changes: [BrowserSyncChange]
}

// MARK: - BrowserSyncPushResponse

struct BrowserSyncPushResponse: Decodable {
    // MARK: Internal

    let protocolVersion: Int?
    let mutationID: String?
    let cursor: Int
    let events: [BrowserSyncEvent]

    init(cursor: Int, events: [BrowserSyncEvent], protocolVersion: Int? = 2, mutationID: String? = nil) {
        self.cursor = cursor
        self.events = events
        self.protocolVersion = protocolVersion
        self.mutationID = mutationID
    }
}

// MARK: - BrowserSyncPullRequest

struct BrowserSyncPullRequest: Encodable {
    // MARK: Internal

    let deviceID: String
    let cursor: Int
    let limit: Int
    let protocolVersion: Int?

    init(deviceID: String, cursor: Int, limit: Int, protocolVersion: Int? = nil) {
        self.deviceID = deviceID
        self.cursor = cursor
        self.limit = limit
        self.protocolVersion = protocolVersion
    }
}

// MARK: - BrowserSyncPullResponse

struct BrowserSyncPullResponse: Decodable {
    // MARK: Internal

    let protocolVersion: Int?
    let supportedPushVersions: [Int]?
    let cursor: Int
    let events: [BrowserSyncEvent]

    init(cursor: Int, events: [BrowserSyncEvent], protocolVersion: Int? = 2, supportedPushVersions: [Int]? = nil) {
        self.cursor = cursor
        self.events = events
        self.protocolVersion = protocolVersion
        self.supportedPushVersions = supportedPushVersions
    }
}

// MARK: - BrowserSyncCoordinating

@MainActor protocol BrowserSyncCoordinating: AnyObject {
    func schedulePush(snapshot: BrowserTabSessionSnapshot)
    func schedulePull()
    func setLocalPersistenceBlocked(_ blocked: Bool)
    func setRuntimeActive(_ active: Bool)
    func requestExpirySweep()
    func setExpiryScheduler(_ scheduler: (any BrowserSyncExpiryScheduling)?)
}

extension BrowserSyncCoordinating {
    func setLocalPersistenceBlocked(_: Bool) {}
    func setRuntimeActive(_: Bool) {}
    func requestExpirySweep() {}
    func setExpiryScheduler(_: (any BrowserSyncExpiryScheduling)?) {}
}

// MARK: - BrowserSyncOwnershipReading

protocol BrowserSyncOwnershipReading {
    func syncOwner() throws -> BrowserSyncOwner?
}

// MARK: - BrowserSyncSnapshotApplying

@MainActor protocol BrowserSyncSnapshotApplying: AnyObject {
    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot)
    func syncArchiveDidChange()
}

extension BrowserSyncSnapshotApplying {
    func syncArchiveDidChange() {}
}
