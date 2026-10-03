import Foundation

// MARK: - BrowserSyncEntityReference

struct BrowserSyncEntityReference: Codable, Equatable, Hashable, Sendable {
    let entityType: BrowserSyncChange.EntityType
    let entityID: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(entityType.rawValue)
        hasher.combine(entityID)
    }
}

// MARK: - BrowserSyncFolderPayload

struct BrowserSyncFolderPayload: Codable, Equatable, Sendable {
    // MARK: Internal

    let spaceID: String
    let parentFolderID: String?
    let title: String
    let systemImageName: String?
    let rank: Double

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(spaceID, forKey: .spaceID)
        try values.encode(parentFolderID, forKey: .parentFolderID)
        try values.encode(title, forKey: .title)
        try values.encode(systemImageName, forKey: .systemImageName)
        try values.encode(rank, forKey: .rank)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey { case spaceID, parentFolderID, title, systemImageName, rank }
}

// MARK: - BrowserSyncFolderCreate

struct BrowserSyncFolderCreate: Codable, Equatable, Sendable {
    // MARK: Lifecycle

    init(spaceID: String, parentFolderID: String? = nil, title: String, systemImageName: String? = nil) {
        self.spaceID = spaceID
        self.parentFolderID = parentFolderID
        self.title = title
        self.systemImageName = systemImageName
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.spaceID = try values.decode(String.self, forKey: .spaceID)
        self.parentFolderID = try values.decode(String?.self, forKey: .parentFolderID)
        self.title = try values.decode(String.self, forKey: .title)
        self.systemImageName = try values.decodeIfPresent(String.self, forKey: .systemImageName)
    }

    // MARK: Internal

    let spaceID: String
    let parentFolderID: String?
    let title: String
    let systemImageName: String?

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(spaceID, forKey: .spaceID)
        try values.encode(parentFolderID, forKey: .parentFolderID)
        try values.encode(title, forKey: .title)
        try values.encode(systemImageName, forKey: .systemImageName)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey { case spaceID, parentFolderID, title, systemImageName }
}

// MARK: - BrowserSyncFolderTabCreate

struct BrowserSyncFolderTabCreate: Codable, Equatable, Sendable {
    // MARK: Lifecycle

    init(
        spaceID: String, placement: BrowserTabPlacement, pinnedFolderID: String? = nil,
        urlString: String, pinnedURLString: String? = nil, title: String? = nil,
        userTitleOverride: String? = nil, faviconURLString: String? = nil, lastActivityAt: String? = nil
    ) {
        self.base = .init(
            spaceID: spaceID,
            placement: placement,
            urlString: urlString,
            pinnedURLString: pinnedURLString,
            title: title,
            userTitleOverride: userTitleOverride,
            faviconURLString: faviconURLString,
            lastActivityAt: lastActivityAt
        )
        self.pinnedFolderID = pinnedFolderID
    }

    init(from decoder: any Decoder) throws {
        self.base = try BrowserSyncSemanticTabCreate(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.pinnedFolderID = try values.decode(String?.self, forKey: .pinnedFolderID)
        guard base.placement == .spacePinned || pinnedFolderID == nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .pinnedFolderID,
                in: values,
                debugDescription: "Only pinned tabs can belong to folders"
            )
        }
    }

    // MARK: Internal

    let base: BrowserSyncSemanticTabCreate
    let pinnedFolderID: String?

    func encode(to encoder: any Encoder) throws {
        try base.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(pinnedFolderID, forKey: .pinnedFolderID)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey { case pinnedFolderID }
}

// MARK: - BrowserSyncFolderPatch

struct BrowserSyncFolderPatch: Codable, Equatable, Sendable {
    // MARK: Lifecycle

    init(title: String? = nil, systemImageName: BrowserSyncPatchValue<String> = .unchanged) {
        self.title = title
        self.systemImageName = systemImageName
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try values.contains(.title) ? values.decode(String.self, forKey: .title) : nil
        self.systemImageName = try values.contains(.systemImageName)
            ? values.decode(BrowserSyncPatchValue<String>.self, forKey: .systemImageName)
            : .unchanged
    }

    // MARK: Internal

    let title: String?
    let systemImageName: BrowserSyncPatchValue<String>

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(title, forKey: .title)
        if systemImageName != .unchanged {
            try values.encode(systemImageName, forKey: .systemImageName)
        }
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey { case title, systemImageName }
}

// MARK: - BrowserSyncFolderDestination

enum BrowserSyncFolderDestination: Codable, Equatable, Hashable, Sendable {
    case spaces
    case tabs(spaceID: String, placement: BrowserTabPlacement, pinnedFolderID: String?)

    // MARK: Lifecycle

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .spaces: self = .spaces
        case .tabs:
            let placement = try values.decode(BrowserTabPlacement.self, forKey: .placement)
            let folder = try values.decode(String?.self, forKey: .pinnedFolderID)
            guard placement == .spacePinned || folder == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .pinnedFolderID,
                    in: values,
                    debugDescription: "Only pinned lists can have a folder parent"
                )
            }
            self = try .tabs(
                spaceID: values.decode(String.self, forKey: .spaceID),
                placement: placement,
                pinnedFolderID: folder
            )
        }
    }

    // MARK: Internal

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .spaces: try values.encode(Kind.spaces, forKey: .kind)
        case .tabs(let spaceID, let placement, let folder):
            try values.encode(Kind.tabs, forKey: .kind)
            try values.encode(spaceID, forKey: .spaceID)
            try values.encode(placement, forKey: .placement)
            try values.encode(folder, forKey: .pinnedFolderID)
        }
    }

    // MARK: Private

    private enum Kind: String, Codable { case spaces, tabs }
    private enum CodingKeys: String, CodingKey { case kind, spaceID, placement, pinnedFolderID }
}

// MARK: - BrowserSyncFolderOperation

/// V4 is a separate codec: frozen v2/v3 operations keep their original bytes.
enum BrowserSyncFolderOperation: Codable, Equatable, Sendable {
    case createSpace(
        id: String,
        data: BrowserSyncSemanticSpaceCreate,
        before: BrowserSyncEntityReference? = nil,
        after: BrowserSyncEntityReference? = nil
    )
    case createTab(
        id: String,
        data: BrowserSyncFolderTabCreate,
        before: BrowserSyncEntityReference? = nil,
        after: BrowserSyncEntityReference? = nil
    )
    case createFolder(
        id: String,
        data: BrowserSyncFolderCreate,
        before: BrowserSyncEntityReference? = nil,
        after: BrowserSyncEntityReference? = nil
    )
    case patchSpace(id: String, fields: BrowserSyncSemanticSpacePatch)
    case patchTab(id: String, fields: BrowserSyncSemanticTabPatch)
    case patchFolder(id: String, fields: BrowserSyncFolderPatch)
    case move(
        items: [BrowserSyncEntityReference],
        destination: BrowserSyncFolderDestination,
        before: BrowserSyncEntityReference? = nil,
        after: BrowserSyncEntityReference? = nil
    )
    case deleteSpace(id: String)
    case deleteTab(id: String)
    case deleteFolder(id: String)

    // MARK: Lifecycle

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        let before = try values.decodeIfPresent(BrowserSyncEntityReference.self, forKey: .before)
        let after = try values.decodeIfPresent(BrowserSyncEntityReference.self, forKey: .after)
        if kind == .move {
            self = try .move(
                items: values.decode([BrowserSyncEntityReference].self, forKey: .items),
                destination: values.decode(BrowserSyncFolderDestination.self, forKey: .destination),
                before: before,
                after: after
            )
            return
        }
        let type = try values.decode(BrowserSyncChange.EntityType.self, forKey: .entityType)
        let id = try values.decode(String.self, forKey: .entityID)
        switch (kind, type) {
        case (.create, .space): self = try .createSpace(
                id: id,
                data: values.decode(BrowserSyncSemanticSpaceCreate.self, forKey: .data),
                before: before,
                after: after
            )
        case (.create, .tab): self = try .createTab(
                id: id,
                data: values.decode(BrowserSyncFolderTabCreate.self, forKey: .data),
                before: before,
                after: after
            )
        case (.create, .folder): self = try .createFolder(
                id: id,
                data: values.decode(BrowserSyncFolderCreate.self, forKey: .data),
                before: before,
                after: after
            )
        case (.patch, .space): self = try .patchSpace(
                id: id,
                fields: values.decode(BrowserSyncSemanticSpacePatch.self, forKey: .fields)
            )
        case (.patch, .tab): self = try .patchTab(
                id: id,
                fields: values.decode(BrowserSyncSemanticTabPatch.self, forKey: .fields)
            )
        case (.patch, .folder): self = try .patchFolder(
                id: id,
                fields: values.decode(BrowserSyncFolderPatch.self, forKey: .fields)
            )
        case (.delete, .space): self = .deleteSpace(id: id)
        case (.delete, .tab): self = .deleteTab(id: id)
        case (.delete, .folder): self = .deleteFolder(id: id)
        case (.move, _): preconditionFailure("Move decoded separately")
        }
    }

    // MARK: Internal

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        func identify(_ kind: Kind, _ type: BrowserSyncChange.EntityType, _ id: String) throws {
            try values.encode(kind, forKey: .kind)
            try values.encode(type, forKey: .entityType)
            try values.encode(id, forKey: .entityID)
        }
        func anchors(_ before: BrowserSyncEntityReference?, _ after: BrowserSyncEntityReference?) throws {
            try values.encodeIfPresent(before, forKey: .before)
            try values.encodeIfPresent(after, forKey: .after)
        }
        switch self {
        case .createSpace(let id, let data, let before, let after):
            try identify(.create, .space, id)
            try values.encode(data, forKey: .data)
            try anchors(before, after)
        case .createTab(let id, let data, let before, let after):
            try identify(.create, .tab, id)
            try values.encode(data, forKey: .data)
            try anchors(before, after)
        case .createFolder(let id, let data, let before, let after):
            try identify(.create, .folder, id)
            try values.encode(data, forKey: .data)
            try anchors(before, after)
        case .patchSpace(let id, let fields): try identify(.patch, .space, id)
            try values.encode(fields, forKey: .fields)
        case .patchTab(let id, let fields): try identify(.patch, .tab, id)
            try values.encode(fields, forKey: .fields)
        case .patchFolder(let id, let fields): try identify(.patch, .folder, id)
            try values.encode(fields, forKey: .fields)
        case .deleteSpace(let id): try identify(.delete, .space, id)
        case .deleteTab(let id): try identify(.delete, .tab, id)
        case .deleteFolder(let id): try identify(.delete, .folder, id)
        case .move(let items, let destination, let before, let after):
            try values.encode(Kind.move, forKey: .kind)
            try values.encode(items, forKey: .items)
            try values.encode(destination, forKey: .destination)
            try anchors(before, after)
        }
    }

    // MARK: Private

    private enum Kind: String, Codable { case create, patch, move, delete }
    private enum CodingKeys: String,
    CodingKey { case kind, entityType, entityID, data, fields, items, destination, before, after }
}

// MARK: - BrowserSyncFolderMutation

struct BrowserSyncFolderMutation: Codable, Equatable, Sendable {
    let id: String
    let operations: [BrowserSyncFolderOperation]
}

// MARK: - BrowserSyncFolderPushRequest

struct BrowserSyncFolderPushRequest: Codable, Equatable, Sendable {
    // MARK: Lifecycle

    init(mutationID: String, deviceID: String, operations: [BrowserSyncFolderOperation]) {
        self.protocolVersion = 4
        self.mutationID = mutationID
        self.deviceID = deviceID
        self.operations = operations
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: values,
                debugDescription: "Expected protocol version 4"
            )
        }
        self.mutationID = try values.decode(String.self, forKey: .mutationID)
        self.deviceID = try values.decode(String.self, forKey: .deviceID)
        self.operations = try values.decode([BrowserSyncFolderOperation].self, forKey: .operations)
    }

    // MARK: Internal

    let protocolVersion: Int
    let mutationID: String
    let deviceID: String
    let operations: [BrowserSyncFolderOperation]

    // MARK: Private

    private enum CodingKeys: String, CodingKey { case protocolVersion, mutationID, deviceID, operations }
}

// MARK: - BrowserSyncFolderPushResponse

struct BrowserSyncFolderPushResponse: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let mutationID: String
    let cursor: Int
    let events: [BrowserSyncEvent]
    let outcomes: [BrowserSyncSemanticOutcome]
}
