// BrowserMobileProfileRegistry.swift

import CryptoKit
import Foundation

/// One durable document per app profile, shared by every connected UIKit scene.
@MainActor final class BrowserMobileProfileRegistry {
    // MARK: Internal

    static let shared = BrowserMobileProfileRegistry()
    static let importIdentifier = "mobile-json-v1"

    private(set) var syncSession: BrowserMobileSyncSession?

    // MARK: Private

    private let directory: URL
    private let syncSessionFactory: (BrowserSQLiteSessionStore, BrowserMobileProfileDocument)
        -> BrowserMobileSyncSession?
    private var current: BrowserMobileProfileDocument?
    private var opening: Task<BrowserMobileProfileDocument, Error>?

    init(
        directory: URL = .applicationSupportDirectory,
        syncSessionFactory: @escaping (BrowserSQLiteSessionStore, BrowserMobileProfileDocument)
            -> BrowserMobileSyncSession? = {
                BrowserHostedService.isEnabled ? BrowserMobileSyncSession(store: $0, document: $1) : nil
            },
    ) {
        self.directory = directory
        self.syncSessionFactory = syncSessionFactory
    }

    static func legacySpaceID(filename: String) -> String {
        "mobile-import-" + SHA256.hash(data: Data(filename.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func importLegacySessions(
        _ imports: [(String, BrowserMobileSession)],
        into store: BrowserSQLiteSessionStore,
    ) throws {
        for (_, session) in imports {
            try session.validate()
        }
        try store.importSessionOnce(importIdentifier) { existing in
            var spaces = existing?.spaces ?? []
            var tabs = existing?.tabs ?? []
            var usedIDs = Set(tabs.compactMap(\.id))
            for (filename, session) in imports.sorted(by: { $0.0 < $1.0 }) {
                let spaceID = legacySpaceID(filename: filename)
                guard !spaces.contains(where: { $0.id == spaceID })
                else { throw BrowserMobileSessionError.invalidSession }
                spaces.append(.init(
                    id: spaceID,
                    title: "Imported Window \(spaces.count + 1)",
                    systemImageName: "globe",
                    selectedTabIndex: session.tabs.firstIndex { $0.id == session.selectedTabID },
                ))
                for tab in session.tabs {
                    // Two old independent scenes may contain the same copied ID.
                    // Preserve both pages; the allocated identity commits atomically.
                    var id = tab.id
                    while usedIDs.contains(id) {
                        id = UUID().uuidString
                    }
                    usedIDs.insert(id)
                    tabs.append(.init(
                        id: id,
                        urlString: tab.urlString,
                        // Legacy titles came from WebKit, not a user rename.
                        // Reload them from the page instead of freezing them
                        // as shared overrides across future navigations.
                        userTitleOverride: nil,
                        spaceID: spaceID,
                    ))
                }
            }
            if existing == nil, imports.isEmpty {
                let spaceID = UUID().uuidString
                spaces = [.init(id: spaceID, title: "Personal", systemImageName: "globe")]
                tabs = [.init(id: UUID().uuidString, urlString: "about:blank", spaceID: spaceID)]
            }
            return BrowserTabSessionSnapshot(spaces: spaces, pinnedTabFolders: existing?.pinnedTabFolders, tabs: tabs)
        }
    }

    private static func readLegacySessions(directory: URL) async throws -> [(String, BrowserMobileSession)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var imports = [(String, BrowserMobileSession)]()
        for url in urls {
            if let session = try await BrowserMobileFileSessionStore(fileURL: url).load() {
                imports.append((url.lastPathComponent, session))
            }
        }
        return imports
    }

    func document() async throws -> BrowserMobileProfileDocument {
        if let current {
            return current
        }
        if let opening {
            return try await opening.value
        }
        let task = Task { @MainActor in
            let downloads = BrowserMobileDownloads(directory: directory
                .appendingPathComponent("MobileProfile", isDirectory: true)
                .appendingPathComponent("Downloads", isDirectory: true))
            await downloads.load()
            let store = try BrowserSQLiteSessionStore(databaseURL: directory
                .appendingPathComponent("MobileProfile", isDirectory: true)
                .appendingPathComponent(BrowserSQLiteSessionStore.databaseFileName))
            if try !store.hasCompletedSessionImport(Self.importIdentifier) {
                let imports = try await Self
                    .readLegacySessions(directory: directory.appendingPathComponent("MobileSessions"))
                try Self.importLegacySessions(imports, into: store)
            }
            let document = try BrowserMobileProfileDocument(
                store: store,
                loadSnapshot: { try store.loadSnapshotStrict() }, downloads: downloads,
            )
            syncSession = syncSessionFactory(store, document)
            return document
        }
        opening = task
        do {
            let document = try await task.value
            current = document
            opening = nil
            return document
        } catch {
            opening = nil
            throw error
        }
    }
}
