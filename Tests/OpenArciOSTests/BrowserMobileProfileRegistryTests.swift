// BrowserMobileProfileRegistryTests.swift

import Foundation
import GRDB
import Testing

@MainActor @Test func mobileRegistryImportsSceneOrderSelectionAndSourceBytesIntoSQLite() async throws {
    let fixture = MobileRegistryFixture()
    defer { fixture.cleanup() }
    let first = mobileRegistrySession(ids: ["a", "b"], selected: "b")
    let second = mobileRegistrySession(ids: ["c"], selected: "c")
    let secondBytes = try fixture.write(second, filename: "z-scene.json")
    let firstBytes = try fixture.write(first, filename: "a-scene.json")
    let document = try await BrowserMobileProfileRegistry(directory: fixture.directory).document()
    let snapshot = document.snapshot
    let spaces = try #require(snapshot.spaces)
    #expect(spaces.map(\.id) == [
        BrowserMobileProfileRegistry.legacySpaceID(filename: "a-scene.json"),
        BrowserMobileProfileRegistry.legacySpaceID(filename: "z-scene.json"),
    ])
    #expect(spaces.map(\.selectedTabIndex) == [1, 0])
    #expect(snapshot.tabs.map(\.id) == ["a", "b", "c"])
    #expect(snapshot.tabs.map(\.urlString) == (first.tabs + second.tabs).map(\.urlString))
    #expect(
        snapshot.tabs.allSatisfy { $0.userTitleOverride == nil },
        "Cached WebKit titles must not become persistent user renames after import",
    )
    #expect(snapshot.tabs.map(\.spaceID) == [spaces[0].id, spaces[0].id, spaces[1].id])
    let reopened = try fixture.store()
    #expect(try reopened.loadSnapshotStrict() == snapshot)
    #expect(try reopened.hasCompletedSessionImport(BrowserMobileProfileRegistry.importIdentifier))
    #expect(try Data(contentsOf: fixture.legacyURL("a-scene.json")) == firstBytes)
    #expect(try Data(contentsOf: fixture.legacyURL("z-scene.json")) == secondBytes)
}

@MainActor @Test func mobileRegistryImportMarkerFailureRollsBackSnapshotWithoutMarkingCompletion() throws {
    let fixture = MobileRegistryFixture()
    defer { fixture.cleanup() }
    let store = try fixture.store()
    let existing = BrowserTabSessionSnapshot(
        spaces: [.init(id: "existing", title: "Existing", systemImageName: "globe")],
        tabs: [.init(id: "saved", urlString: "https://example.com/saved", spaceID: "existing")],
    )
    try store.writeSessionBatch([.init(snapshot: existing, origin: .local(syncMove: nil))])
    let session = mobileRegistrySession(ids: ["imported"], selected: "imported")
    let bytes = try fixture.write(session, filename: "scene.json")
    let frozen = try fixture.queueBytes()
    let baseline = try fixture.baselineBytes()
    try fixture.execute("""
    CREATE TRIGGER reject_import_marker BEFORE INSERT ON browser_preferences
    WHEN NEW.key = 'session_import:mobile-json-v1'
    BEGIN SELECT RAISE(ABORT, 'injected import interruption'); END
    """)
    #expect(throws: DatabaseError.self) {
        try BrowserMobileProfileRegistry.importLegacySessions([("scene.json", session)], into: store)
    }
    let reopened = try fixture.store()
    #expect(try reopened.loadSnapshotStrict() == existing)
    #expect(try !reopened.hasCompletedSessionImport(BrowserMobileProfileRegistry.importIdentifier))
    #expect(try fixture.queueBytes() == frozen)
    #expect(try fixture.baselineBytes() == baseline)
    #expect(try Data(contentsOf: fixture.legacyURL("scene.json")) == bytes)
    try fixture.execute("DROP TRIGGER reject_import_marker")
    try BrowserMobileProfileRegistry.importLegacySessions([("scene.json", session)], into: reopened)
    #expect(try reopened.hasCompletedSessionImport(BrowserMobileProfileRegistry.importIdentifier))
    #expect(try reopened.loadSnapshotStrict()?.tabs.map(\.id) == ["saved", "imported"])
    let retried = try fixture.queueBytes()
    #expect(retried == frozen, "Import before account binding cannot synthesize sync rows")
}

@MainActor @Test func mobileRegistryCannotImportLegacyIdentityIntoAnAlreadySyncedProfile() throws {
    let fixture = MobileRegistryFixture()
    defer { fixture.cleanup() }
    let store = try fixture.store()
    try store.writeSessionBatch([.init(snapshot: .init(
        spaces: [.init(id: "space", title: "Synced", systemImageName: "globe")],
        tabs: [.init(id: "deleted", urlString: "https://example.com/deleted", spaceID: "space")],
    ), origin: .local(syncMove: nil))])
    try store.bindSyncOwner(fixture.owner)
    let deletion = try JSONDecoder().decode(BrowserSyncEvent.self, from: Data("""
    {"serverSeq":1,"deviceID":null,"entityType":"tab","entityID":"deleted","op":"delete",
    "data":{"id":"deleted"},"createdAt":"2026-10-03T00:00:00Z"}
    """.utf8))
    let before = try store.applyRemoteSyncEvents([deletion], cursor: 1, for: fixture.owner)
    #expect(!before.tabs.contains { $0.id == "deleted" })
    let session = mobileRegistrySession(ids: ["deleted"], selected: "deleted")
    let source = try fixture.write(session, filename: "scene.json")
    let queue = try fixture.queueBytes()
    let baseline = try fixture.baselineBytes()
    for current in try [store, fixture.store()] {
        #expect(throws: BrowserSessionImportError.self) {
            try BrowserMobileProfileRegistry.importLegacySessions([("scene.json", session)], into: current)
        }
        #expect(try !current.hasCompletedSessionImport(BrowserMobileProfileRegistry.importIdentifier))
        #expect(try current.loadSnapshotStrict() == before)
        #expect(try current.syncCursor(for: fixture.owner) == 1)
        #expect(try fixture.queueBytes() == queue)
        #expect(try fixture.baselineBytes() == baseline)
        #expect(try Data(contentsOf: fixture.legacyURL("scene.json")) == source)
    }
}

@MainActor @Test func mobileRegistryRestartAfterDeletingImportedTabsDoesNotReadoptSource() async throws {
    let fixture = MobileRegistryFixture()
    defer { fixture.cleanup() }
    let bytes = try fixture.write(mobileRegistrySession(ids: ["a", "b"], selected: "b"), filename: "scene.json")
    let document = try await BrowserMobileProfileRegistry(directory: fixture.directory).document()
    #expect(document.removeTab(id: "a"))
    #expect(document.removeTab(id: "b"))
    #expect(document.snapshot.tabs.isEmpty && !document.hasUncommittedWrites)
    let reopened = try await BrowserMobileProfileRegistry(directory: fixture.directory).document()
    #expect(reopened !== document)
    #expect(reopened.snapshot.tabs.isEmpty)
    #expect(reopened.snapshot.spaces?.map(\.id) == document.snapshot.spaces?.map(\.id))
    #expect(try Data(contentsOf: fixture.legacyURL("scene.json")) == bytes)
    #expect(try fixture.store().hasCompletedSessionImport(BrowserMobileProfileRegistry.importIdentifier))
}

@MainActor @Test func mobileRegistryDuplicateSceneTabIDsKeepBothPagesAndPersistAllocatedIdentity() async throws {
    let fixture = MobileRegistryFixture()
    defer { fixture.cleanup() }
    let first = BrowserMobileSession(
        tabs: [.init(id: "copied", urlString: "https://example.com/first", title: "First")],
        selectedTabID: "copied",
    )
    let second = BrowserMobileSession(
        tabs: [.init(id: "copied", urlString: "https://example.com/second", title: "Second")],
        selectedTabID: "copied",
    )
    _ = try fixture.write(second, filename: "b.json")
    _ = try fixture.write(first, filename: "a.json")
    let document = try await BrowserMobileProfileRegistry(directory: fixture.directory).document()
    let ids = document.snapshot.tabs.compactMap(\.id)
    #expect(ids.count == 2 && Set(ids).count == 2 && ids.first == "copied")
    #expect(document.snapshot.tabs.map(\.urlString) == [first.tabs[0].urlString, second.tabs[0].urlString])
    #expect(document.snapshot.spaces?.map(\.selectedTabIndex) == [0, 0])
    #expect(Set(document.snapshot.tabs.compactMap(\.spaceID)).count == 2)
    let reopened = try await BrowserMobileProfileRegistry(directory: fixture.directory).document()
    #expect(reopened.snapshot == document.snapshot, "The replacement identity must be committed with the import marker")
}

@MainActor @Test func mobileRegistryCorruptLegacyFileFailsClosedAndRetryPreservesSourceBytes() async throws {
    let fixture = MobileRegistryFixture()
    defer { fixture.cleanup() }
    let good = mobileRegistrySession(ids: ["safe"], selected: "safe")
    let goodBytes = try fixture.write(good, filename: "a-valid.json")
    let corrupt = Data("{\"version\":1,\"tabs\":[".utf8)
    try corrupt.write(to: fixture.legacyURL("z-corrupt.json"), options: .atomic)
    let registry = BrowserMobileProfileRegistry(directory: fixture.directory)
    for _ in 0..<2 {
        await #expect(throws: BrowserMobileSessionError.invalidSession) { try await registry.document() }
        let store = try fixture.store()
        #expect(try store.loadSnapshotStrict() == nil)
        #expect(try !store.hasCompletedSessionImport(BrowserMobileProfileRegistry.importIdentifier))
        #expect(try Data(contentsOf: fixture.legacyURL("a-valid.json")) == goodBytes)
        #expect(try Data(contentsOf: fixture.legacyURL("z-corrupt.json")) == corrupt)
    }
    let repaired = mobileRegistrySession(ids: ["repaired"], selected: "repaired")
    _ = try fixture.write(repaired, filename: "z-corrupt.json")
    let document = try await registry.document()
    #expect(document.snapshot.tabs.map(\.id) == ["safe", "repaired"])
}

@MainActor @Test func mobileRegistryConcurrentAcquisitionSharesOneDocumentAndFreshIdentity() async throws {
    let fixture = MobileRegistryFixture()
    defer { fixture.cleanup() }
    let registry = BrowserMobileProfileRegistry(directory: fixture.directory)
    let requests = (0..<8).map { _ in Task { @MainActor in try await registry.document() } }
    var documents = [BrowserMobileProfileDocument]()
    for request in requests {
        try await documents.append(request.value)
    }
    let first = try #require(documents.first)
    #expect(documents.allSatisfy { $0 === first })
    #expect(first.snapshot.spaces?.count == 1)
    #expect(first.snapshot.tabs.count == 1 && first.snapshot.tabs[0].urlString == "about:blank")
    let space = try #require(first.snapshot.spaces?.first?.id)
    let created = try #require(first.createTab(urlString: "https://example.com/shared", spaceID: space))
    #expect(documents.allSatisfy { $0.snapshot.tabs.contains { $0.id == created } })
    let reopened = try await BrowserMobileProfileRegistry(directory: fixture.directory).document()
    #expect(reopened.snapshot == first.snapshot)
}

// MARK: - MobileRegistryFixture

private struct MobileRegistryFixture {
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "owner")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MobileRegistry-\(UUID())",
        isDirectory: true,
    )

    var databaseURL: URL {
        directory.appendingPathComponent("MobileProfile")
            .appendingPathComponent(BrowserSQLiteSessionStore.databaseFileName)
    }

    func legacyURL(_ filename: String) -> URL { directory.appendingPathComponent("MobileSessions")
        .appendingPathComponent(filename)
    }

    func store() throws -> BrowserSQLiteSessionStore { try .init(databaseURL: databaseURL) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func write(_ session: BrowserMobileSession, filename: String) throws -> Data {
        try FileManager.default.createDirectory(
            at: legacyURL(filename).deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let bytes = try JSONEncoder().encode(session)
        try bytes.write(to: legacyURL(filename), options: .atomic)
        return bytes
    }

    func execute(_ sql: String) throws {
        let database = try DatabaseQueue(path: databaseURL.path)
        try database.write { try $0.execute(sql: sql) }
    }

    func queueBytes() throws -> [Data] {
        let database = try DatabaseQueue(path: databaseURL.path)
        return try database.read { try Data.fetchAll(
            $0,
            sql: "SELECT payload FROM browser_sync_outbox ORDER BY position",
        ) }
    }

    func baselineBytes() throws -> Data? {
        let database = try DatabaseQueue(path: databaseURL.path)
        return try database.read { try Data.fetchOne($0, sql: "SELECT payload FROM browser_sync_baseline WHERE id=1") }
    }
}

private func mobileRegistrySession(ids: [String], selected: String?) -> BrowserMobileSession {
    .init(
        tabs: ids.map { .init(id: $0, urlString: "https://example.com/\($0)", title: "Title \($0)") },
        selectedTabID: selected,
    )
}
