// BrowserSyncSemanticModels.swift

import Foundation

// MARK: - BrowserSyncPatchValue

/// Optional patch fields distinguish an omitted update from an explicit JSON null.
enum BrowserSyncPatchValue<Value: Codable & Equatable>: Codable, Equatable {
    case unchanged
    case set(Value)
    case clear

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        self = try value.decodeNil() ? .clear : .set(value.decode(Value.self))
    }

    // MARK: Internal

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .unchanged:
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unchanged patch fields must be omitted by their keyed container",
                ),
            )
        case .set(let update): try value.encode(update)
        case .clear: try value.encodeNil()
        }
    }
}

// MARK: Sendable

extension BrowserSyncPatchValue: Sendable where Value: Sendable {}

// MARK: - BrowserSyncSemanticSpaceCreate

struct BrowserSyncSemanticSpaceCreate: Codable, Equatable {
    // MARK: Internal

    let title: String
    let systemImageName: String
    let isPinnedSectionCollapsed: Bool
    let selectedTabID: String?

    init(title: String, systemImageName: String, isPinnedSectionCollapsed: Bool = false, selectedTabID: String? = nil) {
        self.title = title
        self.systemImageName = systemImageName
        self.isPinnedSectionCollapsed = isPinnedSectionCollapsed
        self.selectedTabID = selectedTabID
    }
}

// MARK: - BrowserSyncSemanticTabCreate

struct BrowserSyncSemanticTabCreate: Codable, Equatable {
    // MARK: Internal

    let spaceID: String
    let placement: BrowserTabPlacement
    let urlString: String
    let pinnedURLString: String?
    let title: String?
    let userTitleOverride: String?
    let faviconURLString: String?
    let lastActivityAt: String?

    init(
        spaceID: String,
        placement: BrowserTabPlacement,
        urlString: String,
        pinnedURLString: String? = nil,
        title: String? = nil,
        userTitleOverride: String? = nil,
        faviconURLString: String? = nil,
        lastActivityAt: String? = nil,
    ) {
        self.spaceID = spaceID
        self.placement = placement
        self.urlString = urlString
        self.pinnedURLString = pinnedURLString
        self.title = title
        self.userTitleOverride = userTitleOverride
        self.faviconURLString = faviconURLString
        self.lastActivityAt = lastActivityAt
    }
}

// MARK: - BrowserSyncSemanticSpacePatch

struct BrowserSyncSemanticSpacePatch: Codable, Equatable {
    // MARK: Private

    private enum CodingKeys: String, CodingKey { case title, systemImageName, isPinnedSectionCollapsed, selectedTabID }

    // MARK: Internal

    let title: String?
    let systemImageName: String?
    let isPinnedSectionCollapsed: Bool?
    let selectedTabID: BrowserSyncPatchValue<String>

    init(
        title: String? = nil,
        systemImageName: String? = nil,
        isPinnedSectionCollapsed: Bool? = nil,
        selectedTabID: BrowserSyncPatchValue<String> = .unchanged,
    ) {
        self.title = title
        self.systemImageName = systemImageName
        self.isPinnedSectionCollapsed = isPinnedSectionCollapsed
        self.selectedTabID = selectedTabID
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try values.decodePresent(String.self, forKey: .title)
        self.systemImageName = try values.decodePresent(String.self, forKey: .systemImageName)
        self.isPinnedSectionCollapsed = try values.decodePresent(Bool.self, forKey: .isPinnedSectionCollapsed)
        self.selectedTabID = try values.decodePatch(String.self, forKey: .selectedTabID)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(systemImageName, forKey: .systemImageName)
        try values.encodeIfPresent(isPinnedSectionCollapsed, forKey: .isPinnedSectionCollapsed)
        try values.encodePatch(selectedTabID, forKey: .selectedTabID)
    }
}

// MARK: - BrowserSyncSemanticTabPatch

struct BrowserSyncSemanticTabPatch: Codable, Equatable {
    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case urlString, pinnedURLString, title, userTitleOverride, faviconURLString, lastActivityAt
    }

    // MARK: Internal

    let urlString: String?
    let pinnedURLString: BrowserSyncPatchValue<String>
    let title: BrowserSyncPatchValue<String>
    let userTitleOverride: BrowserSyncPatchValue<String>
    let faviconURLString: BrowserSyncPatchValue<String>
    let lastActivityAt: BrowserSyncPatchValue<String>

    init(
        urlString: String? = nil,
        pinnedURLString: BrowserSyncPatchValue<String> = .unchanged,
        title: BrowserSyncPatchValue<String> = .unchanged,
        userTitleOverride: BrowserSyncPatchValue<String> = .unchanged,
        faviconURLString: BrowserSyncPatchValue<String> = .unchanged,
        lastActivityAt: BrowserSyncPatchValue<String> = .unchanged,
    ) {
        self.urlString = urlString
        self.pinnedURLString = pinnedURLString
        self.title = title
        self.userTitleOverride = userTitleOverride
        self.faviconURLString = faviconURLString
        self.lastActivityAt = lastActivityAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.urlString = try values.decodePresent(String.self, forKey: .urlString)
        self.pinnedURLString = try values.decodePatch(String.self, forKey: .pinnedURLString)
        self.title = try values.decodePatch(String.self, forKey: .title)
        self.userTitleOverride = try values.decodePatch(String.self, forKey: .userTitleOverride)
        self.faviconURLString = try values.decodePatch(String.self, forKey: .faviconURLString)
        self.lastActivityAt = try values.decodePatch(String.self, forKey: .lastActivityAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(urlString, forKey: .urlString)
        try values.encodePatch(pinnedURLString, forKey: .pinnedURLString)
        try values.encodePatch(title, forKey: .title)
        try values.encodePatch(userTitleOverride, forKey: .userTitleOverride)
        try values.encodePatch(faviconURLString, forKey: .faviconURLString)
        try values.encodePatch(lastActivityAt, forKey: .lastActivityAt)
    }
}

// MARK: - BrowserSyncSemanticTabDestination

struct BrowserSyncSemanticTabDestination: Codable, Equatable {
    let spaceID: String
    let placement: BrowserTabPlacement
}

// MARK: - BrowserSyncSemanticOperation

enum BrowserSyncSemanticOperation: Codable, Equatable {
    case createSpace(id: String, data: BrowserSyncSemanticSpaceCreate, beforeID: String? = nil, afterID: String? = nil)
    case createTab(id: String, data: BrowserSyncSemanticTabCreate, beforeID: String? = nil, afterID: String? = nil)
    case patchSpace(id: String, fields: BrowserSyncSemanticSpacePatch)
    case patchTab(id: String, fields: BrowserSyncSemanticTabPatch)
    case moveSpaces(ids: [String], beforeID: String? = nil, afterID: String? = nil)
    case moveTabs(
        ids: [String],
        destination: BrowserSyncSemanticTabDestination,
        beforeID: String? = nil,
        afterID: String? = nil,
    )
    case deleteSpace(id: String)
    case deleteTab(id: String)

    // MARK: Private

    private enum Kind: String, Codable { case create, patch, move, delete }
    private enum CodingKeys: String,
    CodingKey { case kind, entityType, entityID, entityIDs, data, fields, destination, beforeID, afterID }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        let type = try values.decode(BrowserSyncChange.EntityType.self, forKey: .entityType)
        self =
            switch (kind, type) {
            case (.create, .space):
                try .createSpace(
                    id: values.decode(String.self, forKey: .entityID),
                    data: values.decode(BrowserSyncSemanticSpaceCreate.self, forKey: .data),
                    beforeID: values.decodeIfPresent(String.self, forKey: .beforeID),
                    afterID: values.decodeIfPresent(String.self, forKey: .afterID),
                )
            case (.create, .tab):
                try .createTab(
                    id: values.decode(String.self, forKey: .entityID),
                    data: values.decode(BrowserSyncSemanticTabCreate.self, forKey: .data),
                    beforeID: values.decodeIfPresent(String.self, forKey: .beforeID),
                    afterID: values.decodeIfPresent(String.self, forKey: .afterID),
                )
            case (.patch, .space):
                try .patchSpace(
                    id: values.decode(String.self, forKey: .entityID),
                    fields: values.decode(BrowserSyncSemanticSpacePatch.self, forKey: .fields),
                )
            case (.patch, .tab):
                try .patchTab(
                    id: values.decode(String.self, forKey: .entityID),
                    fields: values.decode(BrowserSyncSemanticTabPatch.self, forKey: .fields),
                )
            case (.move, .space):
                try .moveSpaces(
                    ids: values.decode([String].self, forKey: .entityIDs),
                    beforeID: values.decodeIfPresent(String.self, forKey: .beforeID),
                    afterID: values.decodeIfPresent(String.self, forKey: .afterID),
                )
            case (.move, .tab):
                try .moveTabs(
                    ids: values.decode([String].self, forKey: .entityIDs),
                    destination: values.decode(BrowserSyncSemanticTabDestination.self, forKey: .destination),
                    beforeID: values.decodeIfPresent(String.self, forKey: .beforeID),
                    afterID: values.decodeIfPresent(String.self, forKey: .afterID),
                )
            case (.delete, .space): try .deleteSpace(id: values.decode(String.self, forKey: .entityID))
            case (.delete, .tab): try .deleteTab(id: values.decode(String.self, forKey: .entityID))
            case (_, .folder):
                throw DecodingError.dataCorruptedError(
                    forKey: .entityType, in: values,
                    debugDescription: "Protocol version 3 cannot encode folder operations",
                )
            }
    }

    // MARK: Internal

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .createSpace(let id, let data, let beforeID, let afterID):
            try values.encode(Kind.create, forKey: .kind)
            try values.encode(BrowserSyncChange.EntityType.space, forKey: .entityType)
            try values.encode(id, forKey: .entityID)
            try values.encode(data, forKey: .data)
            try values.encodeIfPresent(beforeID, forKey: .beforeID)
            try values.encodeIfPresent(afterID, forKey: .afterID)
        case .createTab(let id, let data, let beforeID, let afterID):
            try values.encode(Kind.create, forKey: .kind)
            try values.encode(BrowserSyncChange.EntityType.tab, forKey: .entityType)
            try values.encode(id, forKey: .entityID)
            try values.encode(data, forKey: .data)
            try values.encodeIfPresent(beforeID, forKey: .beforeID)
            try values.encodeIfPresent(afterID, forKey: .afterID)
        case .patchSpace(let id, let fields):
            try values.encode(Kind.patch, forKey: .kind)
            try values.encode(BrowserSyncChange.EntityType.space, forKey: .entityType)
            try values.encode(id, forKey: .entityID)
            try values.encode(fields, forKey: .fields)
        case .patchTab(let id, let fields):
            try values.encode(Kind.patch, forKey: .kind)
            try values.encode(BrowserSyncChange.EntityType.tab, forKey: .entityType)
            try values.encode(id, forKey: .entityID)
            try values.encode(fields, forKey: .fields)
        case .moveSpaces(let ids, let beforeID, let afterID):
            try values.encode(Kind.move, forKey: .kind)
            try values.encode(BrowserSyncChange.EntityType.space, forKey: .entityType)
            try values.encode(ids, forKey: .entityIDs)
            try values.encodeIfPresent(beforeID, forKey: .beforeID)
            try values.encodeIfPresent(afterID, forKey: .afterID)
        case .moveTabs(let ids, let destination, let beforeID, let afterID):
            try values.encode(Kind.move, forKey: .kind)
            try values.encode(BrowserSyncChange.EntityType.tab, forKey: .entityType)
            try values.encode(ids, forKey: .entityIDs)
            try values.encode(destination, forKey: .destination)
            try values.encodeIfPresent(beforeID, forKey: .beforeID)
            try values.encodeIfPresent(afterID, forKey: .afterID)
        case .deleteSpace(let id):
            try values.encode(Kind.delete, forKey: .kind)
            try values.encode(BrowserSyncChange.EntityType.space, forKey: .entityType)
            try values.encode(id, forKey: .entityID)
        case .deleteTab(let id):
            try values.encode(Kind.delete, forKey: .kind)
            try values.encode(BrowserSyncChange.EntityType.tab, forKey: .entityType)
            try values.encode(id, forKey: .entityID)
        }
    }
}

// MARK: - BrowserSyncSemanticMutation

struct BrowserSyncSemanticMutation: Codable, Equatable {
    let id: String
    let operations: [BrowserSyncSemanticOperation]
}

// MARK: - BrowserSyncSemanticPushRequest

struct BrowserSyncSemanticPushRequest: Codable, Equatable {
    // MARK: Private

    private enum CodingKeys: String, CodingKey { case protocolVersion, mutationID, deviceID, operations }

    // MARK: Internal

    let protocolVersion: Int
    let mutationID: String
    let deviceID: String
    let operations: [BrowserSyncSemanticOperation]

    init(mutationID: String, deviceID: String, operations: [BrowserSyncSemanticOperation]) {
        self.protocolVersion = 3
        self.mutationID = mutationID
        self.deviceID = deviceID
        self.operations = operations
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: values,
                debugDescription: "Expected semantic protocol version 3",
            )
        }
        self.mutationID = try values.decode(String.self, forKey: .mutationID)
        self.deviceID = try values.decode(String.self, forKey: .deviceID)
        self.operations = try values.decode([BrowserSyncSemanticOperation].self, forKey: .operations)
    }
}

// MARK: - BrowserSyncSemanticOutcome

struct BrowserSyncSemanticOutcome: Codable, Equatable {
    enum Status: String, Codable { case applied, deleted, rejected }

    let operationIndex: Int
    let status: Status
    let reason: String?
}

// MARK: - BrowserSyncSemanticPushResponse

struct BrowserSyncSemanticPushResponse: Codable, Equatable {
    // MARK: Private

    private enum CodingKeys: String, CodingKey { case protocolVersion, mutationID, cursor, events, outcomes }

    // MARK: Internal

    let protocolVersion: Int
    let mutationID: String
    let cursor: Int
    let events: [BrowserSyncEvent]
    let outcomes: [BrowserSyncSemanticOutcome]

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(mutationID, forKey: .mutationID)
        try values.encode(cursor, forKey: .cursor)
        try values.encode(events.map { BrowserSyncSemanticEncodedEvent(event: $0) }, forKey: .events)
        try values.encode(outcomes, forKey: .outcomes)
    }
}

// MARK: - BrowserSyncSemanticEncodedEvent

/// Receipt encoding is separate from the frozen v2 request and mutation codecs.
private struct BrowserSyncSemanticEncodedEvent: Encodable {
    // MARK: Private

    private enum CodingKeys: String, CodingKey { case serverSeq, deviceID, entityType, entityID, op, data, createdAt }
    private enum DataKeys: String, CodingKey {
        case id, title, systemImageName, rank, isPinnedSectionCollapsed, selectedTabID, autoArchive
        case spaceID, placement, urlString, pinnedURLString, userTitleOverride, faviconURLString, lastActivityAt
    }

    // MARK: Internal

    let event: BrowserSyncEvent

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(event.serverSeq, forKey: .serverSeq)
        try values.encode(event.deviceID, forKey: .deviceID)
        try values.encode(event.entityType, forKey: .entityType)
        try values.encode(event.entityID, forKey: .entityID)
        try values.encode(event.op, forKey: .op)
        try values.encode(event.createdAt, forKey: .createdAt)
        var data = values.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
        switch event.data {
        case .space(let space):
            try data.encode(space.id, forKey: .id)
            try data.encodeIfPresent(space.title, forKey: .title)
            try data.encodeIfPresent(space.systemImageName, forKey: .systemImageName)
            try data.encodeIfPresent(space.rank, forKey: .rank)
            try data.encodeIfPresent(space.isPinnedSectionCollapsed, forKey: .isPinnedSectionCollapsed)
            try data.encodeIfPresent(space.selectedTabID, forKey: .selectedTabID)
        case .tab(let tab):
            try data.encode(tab.id, forKey: .id)
            try data.encodeIfPresent(tab.spaceID, forKey: .spaceID)
            try data.encodeIfPresent(tab.placement, forKey: .placement)
            try data.encodeIfPresent(tab.rank, forKey: .rank)
            try data.encodeIfPresent(tab.urlString, forKey: .urlString)
            try data.encodeIfPresent(tab.pinnedURLString, forKey: .pinnedURLString)
            try data.encodeIfPresent(tab.title, forKey: .title)
            try data.encodeIfPresent(tab.userTitleOverride, forKey: .userTitleOverride)
            try data.encodeIfPresent(tab.faviconURLString, forKey: .faviconURLString)
            try data.encodeIfPresent(tab.lastActivityAt, forKey: .lastActivityAt)
        case .deleted(let id, let recovery):
            try data.encode(id, forKey: .id)
            try data.encodeIfPresent(recovery, forKey: .autoArchive)
        case .unknown: break
        case .folder:
            throw EncodingError.invalidValue(event, .init(
                codingPath: encoder.codingPath,
                debugDescription: "Protocol version 3 cannot encode folder events",
            ))
        }
    }
}

private extension KeyedDecodingContainer {
    func decodePresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        contains(key) ? try decode(type, forKey: key) : nil
    }

    func decodePatch<T: Codable & Equatable>(_ type: T.Type, forKey key: Key) throws -> BrowserSyncPatchValue<T> {
        guard contains(key) else { return .unchanged }
        return try decodeNil(forKey: key) ? .clear : .set(decode(type, forKey: key))
    }
}

private extension KeyedEncodingContainer {
    mutating func encodePatch(_ value: BrowserSyncPatchValue<some Codable & Equatable>, forKey key: Key) throws {
        switch value {
        case .unchanged: break
        case .set(let update): try encode(update, forKey: key)
        case .clear: try encodeNil(forKey: key)
        }
    }
}
