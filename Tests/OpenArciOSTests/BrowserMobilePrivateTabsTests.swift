// BrowserMobilePrivateTabsTests.swift

import Foundation
import Testing
import UIKit
import WebKit

// MARK: - BrowserMobilePrivateTabsTests

@Suite(.serialized)
@MainActor struct BrowserMobilePrivateTabsTests {
    @Test func privateTabIsNeverWrittenToTheSavedSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateTabs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        let engine = PrivateTabsEngine()
        let workspace = BrowserMobileWorkspace(engine: engine, store: BrowserMobileFileSessionStore(fileURL: url))
        await workspace.restore()
        workspace.submit("https://example.com/saved")
        let saved = try #require(workspace.selectedTab)
        #expect(await workspace.flushPersistence())

        workspace.submitInNewPrivateTab("https://example.com/secret")
        let secret = try #require(workspace.selectedTab)
        #expect(secret.isPrivate && secret.id != saved.id)
        #expect(engine.privateIDs == [secret.runtimeID])
        #expect(engine.selectedID == secret.runtimeID)
        engine.emit(id: secret.runtimeID, url: "https://example.com/secret/next", title: "Secret page")
        #expect(workspace.selectedTab?.title == "Secret page")
        #expect(await workspace.flushPersistence())
        let session = try JSONDecoder().decode(BrowserMobileSession.self, from: Data(contentsOf: url))
        #expect(session.tabs.map(\.id) == [saved.id])
        #expect(session.selectedTabID == saved.id)
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("secret"))

        // A link opened from the private page stays private.
        try engine.onEvent?(.openInNewTab(#require(URL(string: "https://example.com/linked")), inBackground: true))
        let linked = try #require(workspace.tabs.last)
        #expect(linked.isPrivate && workspace.selectedTabID == secret.id)
        #expect(engine.privateIDs == [secret.runtimeID, linked.runtimeID])

        workspace.closeTab(id: secret.id)
        workspace.closeTab(id: linked.id)
        #expect(workspace.tabs.allSatisfy { !$0.isPrivate })
        #expect(engine.closed == [secret.runtimeID, linked.runtimeID])
        #expect(workspace.selectedTabID == saved.id)
        #expect(await workspace.shutdown())

        let reopened = BrowserMobileWorkspace(
            engine: PrivateTabsEngine(), store: BrowserMobileFileSessionStore(fileURL: url),
        )
        await reopened.restore()
        #expect(reopened.tabs.map(\.id) == [saved.id])
        #expect(await reopened.shutdown())
    }

    @Test func privateTabStaysOutOfTheProfileSyncAndArchive() async throws {
        let f = try PrivateTabsProfileFixture()
        defer { f.cleanup() }
        let engine = PrivateTabsEngine()
        let workspace = BrowserMobileWorkspace(
            engine: engine, sceneID: "scene", profileLoader: { [document = f.document] in document },
            preferences: f.preferences,
        )
        await workspace.restore()
        #expect(workspace.isReady && workspace.supportsArchive)
        workspace.selectTab(id: "a")
        let snapshot = f.document.snapshot
        let loaded = try f.store.loadSnapshotStrict()
        let stored = try #require(loaded)
        let queue = try f.queue()

        workspace.submitInNewPrivateTab("https://example.com/secret")
        let secret = try #require(workspace.selectedTab)
        #expect(secret.isPrivate && engine.privateIDs == [secret.runtimeID])
        #expect(workspace.switcherTabs.contains { $0.id == secret.id })
        engine.emit(id: secret.runtimeID, url: "https://example.com/secret/next", title: "Secret page")
        workspace.submit("https://example.com/secret/typed")
        #expect(engine.navigated.last == URL(string: "https://example.com/secret/typed"))
        #expect(workspace.selectedTab?.urlString == "https://example.com/secret/typed")

        // A popup from the private page is private too.
        let popupURL = try #require(URL(string: "https://example.com/secret/popup"))
        engine.openPopup(id: "popup", url: popupURL)
        let popup = try #require(workspace.selectedTab)
        #expect(popup.isPrivate && popup.runtimeID == "popup")

        // A change from elsewhere keeps the private tabs and their pages.
        #expect(f.document.renameTab(id: "b", title: "Renamed"))
        #expect(workspace.tabs.first { $0.id == secret.id }?.runtimeID == secret.runtimeID)
        #expect(workspace.selectedTabID == popup.id)

        #expect(f.document.snapshot.tabs.map(\.id) == snapshot.tabs.map(\.id))
        #expect(!f.document.snapshot.tabs.contains { $0.urlString.contains("secret") })
        let loadedAfter = try f.store.loadSnapshotStrict()
        let storedAfter = try #require(loadedAfter)
        #expect(!storedAfter.tabs.contains { $0.urlString.contains("secret") })
        #expect(storedAfter.tabs.count == stored.tabs.count)
        let operations = try f.queue().dropFirst(queue.count)
        #expect(operations.count == 1, "Only the rename is queued for sync")
        #expect(!String(describing: Array(operations)).contains("secret"))
        let recent = f.preferences.dictionaryRepresentation().values.compactMap { $0 as? [String] }.flatMap(\.self)
        #expect(!recent.contains(secret.id) && !recent.contains(popup.id))
        #expect(f.preferences.dictionaryRepresentation().values.compactMap { $0 as? String }.allSatisfy {
            $0 != secret.id && $0 != popup.id
        })

        workspace.closeTab(id: popup.id)
        workspace.closeTab(id: secret.id)
        #expect(workspace.tabs.allSatisfy { !$0.isPrivate })
        #expect(try workspace.archivePage().entries.isEmpty, "Closing a private tab discards it")
        #expect(try f.queue().count == queue.count + 1)
        #expect(workspace.selectedTabID == "a")
        #expect(engine.selectedID == workspace.selectedTab?.runtimeID)
        #expect(await workspace.shutdown())
    }

    @Test func privatePagesShareOneInMemoryStoreUntilTheLastCloses() throws {
        let base = WKWebsiteDataStore.nonPersistent()
        let engine = BrowserWebKitEngine(dataStore: base)
        defer { engine.shutdown() }
        engine.onEvent = { _ in }
        let blank = try #require(URL(string: "about:blank"))
        engine.createPrivateTab(id: "first", url: blank)
        engine.createPrivateTab(id: "second", url: blank)
        engine.createTab(id: "regular", url: blank)
        for id in ["first", "second", "regular"] {
            engine.loadHTMLString("<p>\(id)</p>", baseURL: nil, id: id)
        }
        let first = try #require(engine.webView(for: "first")).configuration.websiteDataStore
        let second = try #require(engine.webView(for: "second")).configuration.websiteDataStore
        let regular = try #require(engine.webView(for: "regular")).configuration.websiteDataStore
        #expect(first === second && !first.isPersistent)
        #expect(regular === base && first !== base)
        #expect(engine.isPrivateTab(id: "first") && !engine.isPrivateTab(id: "regular"))

        var popups = [String]()
        engine.onPopupCreated = { id, _ in popups.append(id) }
        let opener = try #require(engine.webView(for: "first")).configuration
        _ = engine.adoptPopup(configuration: opener, url: URL(string: "https://example.com/popup"))
        let popup = try #require(popups.first)
        #expect(engine.isPrivateTab(id: popup))
        let regularOpener = try #require(engine.webView(for: "regular")).configuration
        _ = engine.adoptPopup(configuration: regularOpener, url: URL(string: "https://example.com/other"))
        #expect(popups.count == 2 && !engine.isPrivateTab(id: popups[1]))

        engine.closeTab(id: "first")
        engine.closeTab(id: popup)
        #expect(engine.currentPrivateDataStore() === second, "Open private tabs keep their store")
        engine.closeTab(id: "second")
        engine.createPrivateTab(id: "third", url: blank)
        engine.loadHTMLString("<p>third</p>", baseURL: nil, id: "third")
        let third = try #require(engine.webView(for: "third")).configuration.websiteDataStore
        #expect(third !== second && !third.isPersistent, "The last private tab took its website data along")
    }
}

// MARK: - PrivateTabsProfileFixture

@MainActor private final class PrivateTabsProfileFixture {
    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateTabsProfile-\(UUID())")
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://private.example")!, userID: "private-tabs")
    let suite = "PrivateTabs." + UUID().uuidString
    let preferences: UserDefaults
    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument

    init() throws {
        self.preferences = try #require(UserDefaults(suiteName: suite))
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        try store.bindSyncOwner(owner)
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [.init(id: "source", title: "Source", systemImageName: "globe")],
            tabs: [
                .init(id: "a", urlString: "https://example.com/a", spaceID: "source"),
                .init(id: "b", urlString: "https://example.com/b", spaceID: "source"),
            ],
        )
        let events = try privateTabsEvents(BrowserSyncFolderProjection.canonicalChanges(snapshot))
        _ = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: owner)
        self.document = try BrowserMobileProfileDocument(store: store, initialSnapshot: store.loadSnapshotStrict())
    }

    func queue() throws -> [BrowserSyncQueuedMutation] { try store.pendingSyncQueue(for: owner) }

    func cleanup() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - PrivateTabsEngine

@MainActor private final class PrivateTabsEngine: BrowserMobileEngine {
    // MARK: Internal

    let hostView = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    var privateIDs = [String]()
    var navigated = [URL]()
    var closed = [String]()
    var selectedID: String?

    // MARK: Private

    private var records = [String: Bool]()

    func createTab(id: String, url: URL) {
        records[id] = false
        onEvent?(.state(id: id, .init(url: url)))
    }

    func createPrivateTab(id: String, url: URL) {
        records[id] = true
        privateIDs.append(id)
        onEvent?(.state(id: id, .init(url: url)))
    }

    func isPrivateTab(id: String) -> Bool { records[id] == true }

    /// A page of the selected tab opens a popup.
    func openPopup(id: String, url: URL) {
        records[id] = selectedID.flatMap { records[$0] } ?? false
        onPopupCreated?(id, url)
        onEvent?(.state(id: id, .init(url: url)))
    }

    func emit(id: String, url: String, title: String) {
        onEvent?(.state(id: id, .init(url: URL(string: url), title: title)))
    }

    func selectTab(id: String?) { selectedID = id }
    func navigate(id: String, url: URL) {
        navigated.append(url)
        onEvent?(.state(id: id, .init(url: url, isLoading: true)))
    }

    func closeTab(id: String) {
        guard records.removeValue(forKey: id) != nil else { return }
        closed.append(id)
        onEvent?(.closed(id: id))
    }

    func goBack(id _: String) {}
    func goForward(id _: String) {}
    func reload(id _: String) {}
    func stop(id _: String) {}
    func setJavaScriptDialogPresentationActive(_: Bool) {}
    func resolveJavaScriptDialog(id _: UUID, response _: BrowserMobileJavaScriptDialogResponse) {}
    func shutdown() { records.removeAll() }
}

private func privateTabsEvents(_ changes: [BrowserSyncChange]) throws -> [BrowserSyncEvent] {
    try changes.enumerated().map { offset, change in
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
        var payload = object["data"] as? [String: Any] ?? [:]
        payload["id"] = change.entityID
        let wire: [String: Any] = [
            "serverSeq": offset + 1, "deviceID": NSNull(), "entityType": change.entityType.rawValue,
            "entityID": change.entityID, "op": change.op.rawValue, "data": payload, "createdAt": "2026-10-03T00:00:00Z",
        ]
        return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: wire))
    }
}
