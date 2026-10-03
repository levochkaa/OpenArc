import Foundation

// MARK: - BrowserSyncAutoArchiveData

/// Immutable server recovery, independent from the permanently deleted identity.
struct BrowserSyncAutoArchiveData: Codable, Equatable {
    // MARK: Internal

    let archivedAt: String
    let sourceServerSeq: Int
    let tab: BrowserSyncEventTabData

    func entry(event: BrowserSyncEvent, id: String) throws -> BrowserTabArchiveEntry {
        guard event.entityType == "tab", event.op == "delete", tab.id == event.entityID,
              case .deleted(let deletedID, _) = event.data, deletedID == event.entityID,
              sourceServerSeq > 0, sourceServerSeq < event.serverSeq,
              tab.placement == .temporary, let spaceID = tab.spaceID, !spaceID.isEmpty,
              let rank = tab.rank, rank.isFinite,
              let url = tab.urlString, !url.isEmpty,
              let date = Self.timestamp(archivedAt), date.isFinite,
              let activity = tab.lastActivityAt.flatMap(Self.timestamp), activity.isFinite
        else { throw BrowserSyncOutboxError.invalidEvent }
        let entry = BrowserTabArchiveEntry(id: id, tab: .init(
            id: tab.id, urlString: url, pinnedURLString: tab.pinnedURLString,
            userTitleOverride: tab.userTitleOverride, spaceID: spaceID,
            lastActivityTimestamp: activity
        ), archivedAt: date, title: tab.title)
        try entry.validate()
        return entry
    }

    // MARK: Private

    private static func timestamp(_ value: String) -> TimeInterval? {
        ((try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value)))?.timeIntervalSince1970
    }
}

// MARK: - BrowserSyncExpiryRecovery

/// Recover content from immutable pending writes even if an older binary has
/// already hidden the tab with a tombstone. This never changes live projection.
enum BrowserSyncExpiryRecovery {
    // MARK: Internal

    static func localEntries(
        canonical: BrowserTabArchiveEntry, pending: [BrowserSyncQueuedMutation],
        local: BrowserTabSessionSnapshot?
    ) -> [BrowserTabArchiveEntry] {
        let tabID = canonical.tab.id
        let original = Content(
            url: canonical.tab.urlString,
            override: canonical.tab.userTitleOverride,
            title: canonical.title
        )
        var queued = original
        for mutation in pending {
            switch mutation {
            case .legacy(let row):
                for change in row.changes
                    where change.entityType == .tab && change.entityID == tabID && change.op == .upsert
                {
                    if let tab = change.tabData {
                        queued = Content(url: tab.urlString, override: tab.userTitleOverride, title: tab.title)
                    }
                }
            case .semantic(let row):
                for operation in row.operations {
                    switch operation {
                    case .patchTab(let id, let fields) where id == tabID: queued.apply(fields)
                    case .createTab(let id, let data, _, _) where id == tabID:
                        queued = Content(url: data.urlString, override: data.userTitleOverride, title: data.title)
                    default: break
                    }
                }
            case .folders(let row):
                for operation in row.operations {
                    switch operation {
                    case .patchTab(let id, let fields) where id == tabID: queued.apply(fields)
                    case .createTab(let id, let data, _, _) where id == tabID:
                        queued = Content(
                            url: data.base.urlString,
                            override: data.base.userTitleOverride,
                            title: data.base.title
                        )
                    default: break
                    }
                }
            case .expiry:
                // Expiry carries a condition, never newer local page content.
                break
            }
        }
        var contents = [Content]()
        if queued != original {
            contents.append(queued)
        }
        if let tab = local?.tabs.first(where: { $0.id == tabID }) {
            // Snapshot stores the user's override, but page title lives in sync
            // metadata. Avoid manufacturing a second variant from that omission.
            let current = Content(url: tab.urlString, override: tab.userTitleOverride, title: queued.title)
            if current != original, !contents.contains(current) {
                contents.append(current)
            }
        }
        return contents.enumerated().map { index, content in
            BrowserTabArchiveEntry(id: canonical.id + "-local-\(index)", tab: .init(
                id: tabID, urlString: content.url, userTitleOverride: content.override,
                spaceID: canonical.tab.spaceID, lastActivityTimestamp: canonical.tab.lastActivityTimestamp
            ), archivedAt: canonical.archivedAt, title: content.title)
        }
    }

    // MARK: Private

    private struct Content: Equatable {
        // MARK: Internal

        var url: String
        var override: String?
        var title: String?

        mutating func apply(_ patch: BrowserSyncSemanticTabPatch) {
            if let url = patch.urlString {
                self.url = url
            }
            override = Self.value(patch.userTitleOverride, previous: override)
            title = Self.value(patch.title, previous: title)
        }

        // MARK: Private

        private static func value(_ patch: BrowserSyncPatchValue<String>, previous: String?) -> String? {
            switch patch {
            case .unchanged: previous
            case .clear: nil
            case .set(let value): value
            }
        }
    }
}
