// BrowserSyncCoreBridge.swift

import Foundation

// The sync projections run in the Rust core (`Core/openarc-core/src/sync`, docs/rust-core.md). The app
// keeps its own types for storage and the wire; these conversions carry them across.

// MARK: - Session

extension BrowserTabPlacement {
    init(_ core: CoreTabPlacement) {
        self =
            switch core {
            case .temporary: .temporary
            case .spacePinned: .spacePinned
            case .app: .app
            }
    }

    var core: CoreTabPlacement {
        switch self {
        case .temporary: .temporary
        case .spacePinned: .spacePinned
        case .app: .app
        }
    }
}

extension BrowserSpaceSessionSnapshot {
    init(_ core: CoreSpaceSnapshot) {
        self.init(
            id: core.id, title: core.title, systemImageName: core.systemImageName,
            isPinnedSectionCollapsed: core.isPinnedSectionCollapsed,
            selectedTabIndex: core.selectedTabIndex.map(Int.init),
            colorName: core.colorName, profileDirectory: core.profileDirectory,
        )
    }

    var core: CoreSpaceSnapshot {
        .init(
            id: id, title: title, systemImageName: systemImageName, isPinnedSectionCollapsed: isPinnedSectionCollapsed,
            selectedTabIndex: selectedTabIndex.map(Int64.init), colorName: colorName,
            profileDirectory: profileDirectory,
        )
    }
}

extension BrowserPinnedTabFolderSessionSnapshot {
    init(_ core: CoreFolderSnapshot) {
        self.init(
            id: core.id, spaceID: core.spaceId, parentFolderID: core.parentFolderId, title: core.title,
            systemImageName: core.systemImageName, isExpanded: core.isExpanded,
            pinnedSiblingRank: core.pinnedSiblingRank,
        )
    }

    var core: CoreFolderSnapshot {
        .init(
            id: id, spaceId: spaceID, parentFolderId: parentFolderID, title: title, systemImageName: systemImageName,
            isExpanded: isExpanded, pinnedSiblingRank: pinnedSiblingRank,
        )
    }
}

extension BrowserTabSessionSnapshotTab {
    init(_ core: CoreTabSnapshot) {
        self.init(
            id: core.id, urlString: core.urlString, pinnedURLString: core.pinnedUrlString,
            userTitleOverride: core.userTitleOverride, placement: .init(core.placement), spaceID: core.spaceId,
            pinnedFolderID: core.pinnedFolderId, lastActivityTimestamp: core.lastActivityTimestamp,
            pinnedSiblingRank: core.pinnedSiblingRank, pageTitle: core.pageTitle, systemImageName: core.systemImageName,
        )
    }

    var core: CoreTabSnapshot {
        .init(
            id: id, urlString: urlString, pinnedUrlString: pinnedURLString, userTitleOverride: userTitleOverride,
            placement: placement.core, spaceId: spaceID, pinnedFolderId: pinnedFolderID,
            pinnedSiblingRank: pinnedSiblingRank, lastActivityTimestamp: lastActivityTimestamp, pageTitle: pageTitle,
            systemImageName: systemImageName,
        )
    }
}

extension BrowserTabSessionSnapshot {
    /// A projected session: the current version, and no split state of its own.
    init(_ core: CoreSessionSnapshot, splitGroups: [BrowserTabSplitGroupSessionSnapshot]? = nil) {
        self.init(
            spaces: core.spaces?.map(BrowserSpaceSessionSnapshot.init),
            pinnedTabFolders: core.pinnedTabFolders?.map(BrowserPinnedTabFolderSessionSnapshot.init),
            tabs: core.tabs.map(BrowserTabSessionSnapshotTab.init),
            splitGroups: splitGroups,
        )
    }

    var core: CoreSessionSnapshot {
        .init(spaces: spaces?.map(\.core), pinnedTabFolders: pinnedTabFolders?.map(\.core), tabs: tabs.map(\.core))
    }
}

// MARK: - Canonical entities

extension BrowserSyncChange.EntityType {
    init(_ core: CoreSyncEntityType) {
        self =
            switch core {
            case .space: .space
            case .tab: .tab
            case .folder: .folder
            }
    }

    var core: CoreSyncEntityType {
        switch self {
        case .space: .space
        case .tab: .tab
        case .folder: .folder
        }
    }
}

extension BrowserSyncSpacePayload {
    init(_ core: CoreSyncSpacePayload) {
        self.init(
            title: core.title, systemImageName: core.systemImageName, rank: core.rank,
            isPinnedSectionCollapsed: core.isPinnedSectionCollapsed, selectedTabID: core.selectedTabId,
        )
    }

    var core: CoreSyncSpacePayload {
        .init(
            title: title, systemImageName: systemImageName, rank: rank,
            isPinnedSectionCollapsed: isPinnedSectionCollapsed, selectedTabId: selectedTabID,
        )
    }
}

extension BrowserSyncTabPayload {
    init(_ core: CoreSyncTabPayload) {
        self.init(
            spaceID: core.spaceId, placement: .init(core.placement), rank: core.rank, urlString: core.urlString,
            pinnedURLString: core.pinnedUrlString, title: core.title, userTitleOverride: core.userTitleOverride,
            faviconURLString: core.faviconUrlString, lastActivityAt: core.lastActivityAt,
            pinnedFolderID: core.pinnedFolderId,
        )
    }

    var core: CoreSyncTabPayload {
        .init(
            spaceId: spaceID, placement: placement.core, rank: rank, urlString: urlString,
            pinnedUrlString: pinnedURLString, title: title, userTitleOverride: userTitleOverride,
            faviconUrlString: faviconURLString, lastActivityAt: lastActivityAt, pinnedFolderId: pinnedFolderID,
        )
    }
}

extension BrowserSyncFolderPayload {
    init(_ core: CoreSyncFolderPayload) {
        self.init(
            spaceID: core.spaceId, parentFolderID: core.parentFolderId, title: core.title,
            systemImageName: core.systemImageName, rank: core.rank,
        )
    }

    var core: CoreSyncFolderPayload {
        .init(
            spaceId: spaceID, parentFolderId: parentFolderID, title: title, systemImageName: systemImageName,
            rank: rank,
        )
    }
}

extension BrowserSyncChange {
    init(_ core: CoreSyncChange) {
        self.init(
            entityType: .init(core.entityType), entityID: core.entityId, op: core.op == .upsert ? .upsert : .delete,
            spaceData: core.spaceData.map(BrowserSyncSpacePayload.init),
            tabData: core.tabData.map(BrowserSyncTabPayload.init),
            folderData: core.folderData.map(BrowserSyncFolderPayload.init),
        )
    }

    var core: CoreSyncChange {
        .init(
            entityType: entityType.core, entityId: entityID, op: op == .upsert ? .upsert : .delete,
            spaceData: spaceData?.core, tabData: tabData?.core, folderData: folderData?.core,
        )
    }
}

extension BrowserSyncEntityReference {
    init(_ core: CoreSyncEntityRef) {
        self.init(entityType: .init(core.entityType), entityID: core.entityId)
    }

    var core: CoreSyncEntityRef { .init(entityType: entityType.core, entityId: entityID) }
}

// MARK: - Operations

extension BrowserSyncPatchValue<String> {
    init(_ core: CorePatch) {
        self =
            switch core {
            case .unchanged: .unchanged
            case .set(let value): .set(value)
            case .clear: .clear
            }
    }

    var core: CorePatch {
        switch self {
        case .unchanged: .unchanged
        case .set(let value): .set(value: value)
        case .clear: .clear
        }
    }
}

extension BrowserSyncSemanticSpaceCreate {
    init(_ core: CoreSyncSpaceCreate) {
        self.init(
            title: core.title, systemImageName: core.systemImageName,
            isPinnedSectionCollapsed: core.isPinnedSectionCollapsed, selectedTabID: core.selectedTabId,
        )
    }

    var core: CoreSyncSpaceCreate {
        .init(
            title: title, systemImageName: systemImageName, isPinnedSectionCollapsed: isPinnedSectionCollapsed,
            selectedTabId: selectedTabID,
        )
    }
}

extension BrowserSyncSemanticTabCreate {
    init(_ core: CoreSyncTabCreate) {
        self.init(
            spaceID: core.spaceId, placement: .init(core.placement), urlString: core.urlString,
            pinnedURLString: core.pinnedUrlString, title: core.title, userTitleOverride: core.userTitleOverride,
            faviconURLString: core.faviconUrlString, lastActivityAt: core.lastActivityAt,
        )
    }

    var core: CoreSyncTabCreate {
        .init(
            spaceId: spaceID, placement: placement.core, urlString: urlString, pinnedUrlString: pinnedURLString,
            title: title, userTitleOverride: userTitleOverride, faviconUrlString: faviconURLString,
            lastActivityAt: lastActivityAt,
        )
    }
}

extension BrowserSyncSemanticSpacePatch {
    init(_ core: CoreSyncSpacePatch) {
        self.init(
            title: core.title, systemImageName: core.systemImageName,
            isPinnedSectionCollapsed: core.isPinnedSectionCollapsed, selectedTabID: .init(core.selectedTabId),
        )
    }

    var core: CoreSyncSpacePatch {
        .init(
            title: title, systemImageName: systemImageName, isPinnedSectionCollapsed: isPinnedSectionCollapsed,
            selectedTabId: selectedTabID.core,
        )
    }
}

extension BrowserSyncSemanticTabPatch {
    init(_ core: CoreSyncTabPatch) {
        self.init(
            urlString: core.urlString, pinnedURLString: .init(core.pinnedUrlString), title: .init(core.title),
            userTitleOverride: .init(core.userTitleOverride), faviconURLString: .init(core.faviconUrlString),
            lastActivityAt: .init(core.lastActivityAt),
        )
    }

    var core: CoreSyncTabPatch {
        .init(
            urlString: urlString, pinnedUrlString: pinnedURLString.core, title: title.core,
            userTitleOverride: userTitleOverride.core, faviconUrlString: faviconURLString.core,
            lastActivityAt: lastActivityAt.core,
        )
    }
}

extension BrowserSyncSemanticTabDestination {
    init(_ core: CoreSyncTabDestination) { self.init(spaceID: core.spaceId, placement: .init(core.placement)) }

    var core: CoreSyncTabDestination { .init(spaceId: spaceID, placement: placement.core) }
}

extension BrowserSyncSemanticOperation {
    init(_ core: CoreSemanticOperation) {
        self =
            switch core {
            case .createSpace(let id, let data, let beforeID, let afterID):
                .createSpace(id: id, data: .init(data), beforeID: beforeID, afterID: afterID)
            case .createTab(let id, let data, let beforeID, let afterID):
                .createTab(id: id, data: .init(data), beforeID: beforeID, afterID: afterID)
            case .patchSpace(let id, let fields): .patchSpace(id: id, fields: .init(fields))
            case .patchTab(let id, let fields): .patchTab(id: id, fields: .init(fields))
            case .moveSpaces(let ids, let beforeID, let afterID):
                .moveSpaces(ids: ids, beforeID: beforeID, afterID: afterID)
            case .moveTabs(let ids, let destination, let beforeID, let afterID):
                .moveTabs(ids: ids, destination: .init(destination), beforeID: beforeID, afterID: afterID)
            case .deleteSpace(let id): .deleteSpace(id: id)
            case .deleteTab(let id): .deleteTab(id: id)
            }
    }

    var core: CoreSemanticOperation {
        switch self {
        case .createSpace(let id, let data, let beforeID, let afterID):
            .createSpace(id: id, data: data.core, beforeId: beforeID, afterId: afterID)
        case .createTab(let id, let data, let beforeID, let afterID):
            .createTab(id: id, data: data.core, beforeId: beforeID, afterId: afterID)
        case .patchSpace(let id, let fields): .patchSpace(id: id, fields: fields.core)
        case .patchTab(let id, let fields): .patchTab(id: id, fields: fields.core)
        case .moveSpaces(let ids, let beforeID, let afterID): .moveSpaces(
                ids: ids,
                beforeId: beforeID,
                afterId: afterID,
            )
        case .moveTabs(let ids, let destination, let beforeID, let afterID):
            .moveTabs(ids: ids, destination: destination.core, beforeId: beforeID, afterId: afterID)
        case .deleteSpace(let id): .deleteSpace(id: id)
        case .deleteTab(let id): .deleteTab(id: id)
        }
    }
}

extension BrowserSyncFolderTabCreate {
    init(_ core: CoreSyncFolderTabCreate) {
        let base = core.base
        self.init(
            spaceID: base.spaceId, placement: .init(base.placement), pinnedFolderID: core.pinnedFolderId,
            urlString: base.urlString, pinnedURLString: base.pinnedUrlString, title: base.title,
            userTitleOverride: base.userTitleOverride, faviconURLString: base.faviconUrlString,
            lastActivityAt: base.lastActivityAt,
        )
    }

    var core: CoreSyncFolderTabCreate { .init(base: base.core, pinnedFolderId: pinnedFolderID) }
}

extension BrowserSyncFolderCreate {
    init(_ core: CoreSyncFolderCreate) {
        self.init(
            spaceID: core.spaceId, parentFolderID: core.parentFolderId, title: core.title,
            systemImageName: core.systemImageName,
        )
    }

    var core: CoreSyncFolderCreate {
        .init(spaceId: spaceID, parentFolderId: parentFolderID, title: title, systemImageName: systemImageName)
    }
}

extension BrowserSyncFolderPatch {
    init(_ core: CoreSyncFolderPatch) { self.init(title: core.title, systemImageName: .init(core.systemImageName)) }

    var core: CoreSyncFolderPatch { .init(title: title, systemImageName: systemImageName.core) }
}

extension BrowserSyncFolderDestination {
    init(_ core: CoreSyncFolderDestination) {
        self =
            switch core {
            case .spaces: .spaces
            case .tabs(let spaceID, let placement, let folder):
                .tabs(spaceID: spaceID, placement: .init(placement), pinnedFolderID: folder)
            }
    }

    var core: CoreSyncFolderDestination {
        switch self {
        case .spaces: .spaces
        case .tabs(let spaceID, let placement, let folder):
            .tabs(spaceId: spaceID, placement: placement.core, pinnedFolderId: folder)
        }
    }
}

extension BrowserSyncFolderOperation {
    init(_ core: CoreFolderOperation) {
        let reference = { (core: CoreSyncEntityRef?) in core.map(BrowserSyncEntityReference.init) }
        self =
            switch core {
            case .createSpace(let id, let data, let before, let after):
                .createSpace(id: id, data: .init(data), before: reference(before), after: reference(after))
            case .createTab(let id, let data, let before, let after):
                .createTab(id: id, data: .init(data), before: reference(before), after: reference(after))
            case .createFolder(let id, let data, let before, let after):
                .createFolder(id: id, data: .init(data), before: reference(before), after: reference(after))
            case .patchSpace(let id, let fields): .patchSpace(id: id, fields: .init(fields))
            case .patchTab(let id, let fields): .patchTab(id: id, fields: .init(fields))
            case .patchFolder(let id, let fields): .patchFolder(id: id, fields: .init(fields))
            case .move(let items, let destination, let before, let after):
                .move(
                    items: items.map(BrowserSyncEntityReference.init), destination: .init(destination),
                    before: reference(before), after: reference(after),
                )
            case .deleteSpace(let id): .deleteSpace(id: id)
            case .deleteTab(let id): .deleteTab(id: id)
            case .deleteFolder(let id): .deleteFolder(id: id)
            }
    }

    var core: CoreFolderOperation {
        switch self {
        case .createSpace(let id, let data, let before, let after):
            .createSpace(id: id, data: data.core, before: before?.core, after: after?.core)
        case .createTab(let id, let data, let before, let after):
            .createTab(id: id, data: data.core, before: before?.core, after: after?.core)
        case .createFolder(let id, let data, let before, let after):
            .createFolder(id: id, data: data.core, before: before?.core, after: after?.core)
        case .patchSpace(let id, let fields): .patchSpace(id: id, fields: fields.core)
        case .patchTab(let id, let fields): .patchTab(id: id, fields: fields.core)
        case .patchFolder(let id, let fields): .patchFolder(id: id, fields: fields.core)
        case .move(let items, let destination, let before, let after):
            .move(items: items.map(\.core), destination: destination.core, before: before?.core, after: after?.core)
        case .deleteSpace(let id): .deleteSpace(id: id)
        case .deleteTab(let id): .deleteTab(id: id)
        case .deleteFolder(let id): .deleteFolder(id: id)
        }
    }
}

extension BrowserSyncQueuedMutation {
    var core: CoreQueuedMutation {
        switch self {
        case .legacy(let row): .legacy(changes: row.changes.map(\.core))
        case .semantic(let row): .semantic(operations: row.operations.map(\.core))
        case .folders(let row): .folders(operations: row.operations.map(\.core))
        // Expiry rows wait for the server; boosts and mobile tabs project outside the Spaces.
        case .boosts,
             .expiry,
             .mobileTabs: .other
        }
    }
}

// MARK: - Baseline and replay

extension BrowserSyncOutboxBaseline.Entity {
    init(_ core: CoreSyncBaselineEntity) { self.init(serverSeq: Int(core.serverSeq), change: .init(core.change)) }

    var core: CoreSyncBaselineEntity { .init(serverSeq: Int64(serverSeq), change: change.core) }
}

extension BrowserSyncOutboxBaseline {
    var core: CoreSyncBaseline {
        .init(
            entities: entities.mapValues(\.core),
            deletedKeys: Array(deletedKeys),
        )
    }
}

extension BrowserSyncEvent {
    var core: CoreSyncEvent {
        let payload: CoreSyncEventData =
            switch data {
            case .space(let space): .space(data: .init(
                    title: space.title, systemImageName: space.systemImageName, rank: space.rank,
                    isPinnedSectionCollapsed: space.isPinnedSectionCollapsed, selectedTabId: space.selectedTabID,
                ))
            case .tab(let tab): .tab(data: .init(
                    spaceId: tab.spaceID, placement: tab.placement?.core, rank: tab.rank, urlString: tab.urlString,
                    pinnedUrlString: tab.pinnedURLString, title: tab.title, userTitleOverride: tab.userTitleOverride,
                    faviconUrlString: tab.faviconURLString, lastActivityAt: tab.lastActivityAt,
                    pinnedFolderId: tab.pinnedFolderID,
                ))
            case .folder(let folder): .folder(data: .init(
                    spaceId: folder.spaceID, parentFolderId: folder.parentFolderID, title: folder.title,
                    systemImageName: folder.systemImageName, rank: folder.rank,
                ))
            case .boost,
                 .deleted,
                 .mobileTab,
                 .unknown: .other
            }
        return .init(serverSeq: Int64(serverSeq), entityType: entityType, entityId: entityID, op: op, data: payload)
    }
}

extension BrowserSyncQueuedRowIdentity {
    var core: CoreSyncQueuedRowIdentity { .init(protocolVersion: Int64(protocolVersion), payload: payload) }
}

extension BrowserSyncOutboxReplayState {
    init(_ core: CoreSyncReplayState) {
        self.init(values: core.values.mapValues(BrowserSyncChange.init), deleted: Set(core.deleted))
    }

    var core: CoreSyncReplayState { .init(values: values.mapValues(\.core), deleted: Array(deleted)) }
}
