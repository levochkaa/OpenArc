// BrowserStartupRestorationTests.swift

import Foundation
import Testing

// MARK: - BrowserStartupRestorationTests

@Suite(.serialized)
@MainActor struct BrowserStartupRestorationTests {
    @Test func logicalRestoreIsCompleteBeforeReversedOrDuplicateCallbacks() throws {
        let f = StartupRestorationFixture(snapshot: startupSnapshot())
        defer { f.cleanup() }
        f.model.handleContextReady()
        #expect(f.model.tabs.map(\.syncID) == ["a", "b", "c"])
        #expect(f.model.tabs.map(\.urlString) == startupSnapshot().tabs.map(\.urlString))
        #expect(f.model.selectedSpaceID == "work")
        let selected = try #require(f.model.tabs.first { $0.syncID == "b" })
        #expect(f.model.selectedTabID == selected.id)
        #expect(f.model.tabs.first?.pinnedFolderID == "folder")
        let saved = f.store.savedSnapshots.count
        let pushes = f.sync.pushes.count
        for request in f.driver.createdTabRequests.reversed() {
            f.driver.emitCreatedTab(id: request.id, urlString: request.urlString, isActive: true)
        }
        f.driver.emitCreatedTab(id: selected.id, urlString: selected.urlString, isActive: false)
        #expect(f.model.tabs.map(\.syncID) == ["a", "b", "c"])
        #expect(f.model.selectedTabID == selected.id)
        #expect(f.store.savedSnapshots.count == saved)
        #expect(f.sync.pushes.count == pushes)
    }

    @Test func localCreationBeforeSavedCallbacksKeepsFreshIdentityAndSelection() throws {
        let f = StartupRestorationFixture(snapshot: startupSnapshot())
        defer { f.cleanup() }
        f.model.handleContextReady()
        let restoredRequests = f.driver.createdTabRequests
        try f.model.openURLInNewTab(#require(URL(string: "https://new.example/")))
        let created = try #require(f.driver.createdTabRequests.last)
        f.driver.emitCreatedTab(id: created.id, urlString: created.urlString, isActive: true)
        let tab = try #require(f.model.tabs.first { $0.id == created.id })
        #expect(!["a", "b", "c"].contains(tab.syncID))
        #expect(tab.urlString == "https://new.example/")
        #expect(f.model.selectedTabID == tab.id)
        let saved = f.store.savedSnapshots.count
        for request in restoredRequests.reversed() {
            f.driver.emitCreatedTab(id: request.id, urlString: request.urlString, isActive: true)
        }
        #expect(f.model.tabs.map(\.syncID) == ["a", "b", "c", tab.syncID])
        #expect(f.model.selectedTabID == tab.id)
        #expect(f.store.savedSnapshots.count == saved)
        #expect(f.store.savedSnapshots.last?.tabs.last?.id == tab.syncID)
    }

    @Test func editsMoveAndDeleteBeforeCallbacksPersistWithoutStaleResurrection() throws {
        let f = StartupRestorationFixture(snapshot: startupSnapshot())
        defer { f.cleanup() }
        f.model.handleContextReady()
        let a = try #require(f.model.tabs.first { $0.syncID == "a" })
        let b = try #require(f.model.tabs.first { $0.syncID == "b" })
        f.model.setUserTitleOverride("Local name", forTabID: a.id)
        f.model.moveTab(withID: b.id, toPlacement: .spacePinned, atSectionIndex: 0)
        #expect(f.store.savedSyncMoves.last == .init(tabIDs: ["b"]))
        f.driver.emitUpdate(id: a.id, title: "Live title", urlString: "https://live.example/")
        #expect(f.model.closeTab(id: b.id))
        let saved = try #require(f.store.savedSnapshots.last)
        let attempts = f.store.attemptedSessionWriteBatches.count
        let closes = f.driver.closedTabRequests.count
        let pushes = f.sync.pushes.count
        for request in f.driver.createdTabRequests.reversed() {
            f.driver.emitCreatedTab(id: request.id, urlString: request.urlString, isActive: true)
        }
        // A duplicate delayed placeholder must not turn a deleted restored ID
        // into a new local tab after its first canceled callback was consumed.
        f.driver.emitCreatedTab(id: b.id, urlString: b.urlString, isActive: true)
        f.driver.emitClose(id: b.id)
        f.driver.emitClose(id: b.id)
        #expect(f.model.tabs.map(\.syncID) == ["a", "c"])
        #expect(f.model.tabs.first?.userTitleOverride == "Local name")
        #expect(f.model.tabs.first?.urlString == "https://live.example/")
        #expect(f.model.tabs.first?.title == "Live title")
        #expect(f.store.attemptedSessionWriteBatches.count == attempts)
        #expect(f.driver.closedTabRequests.count == closes)
        #expect(f.sync.pushes.count == pushes)
        #expect(f.store.savedSnapshots.last == saved)
        let reopened = StartupRestorationFixture(snapshot: saved)
        defer { reopened.cleanup() }
        reopened.model.handleContextReady()
        #expect(reopened.model.tabs.map(\.syncID) == ["a", "c"])
        #expect(reopened.model.tabs.first?.userTitleOverride == "Local name")
        #expect(reopened.model.tabs.first?.urlString == "https://live.example/")
    }

    @Test func remoteMetadataAndLocalEditsSurviveOlderStartupCallbacks() throws {
        let f = StartupRestorationFixture(snapshot: startupSnapshot())
        defer { f.cleanup() }
        f.model.handleContextReady()
        let savedRequests = f.driver.createdTabRequests
        let b = try #require(f.model.tabs.first { $0.syncID == "b" })
        f.driver.emitTabCreationState(id: b.id, state: .ready)
        f.driver.emitUpdate(id: b.id, title: "Current page", urlString: "https://live.example/")
        f.model.applyRemoteSyncSnapshot(.init(
            spaces: [.init(id: "work", title: "Remote", systemImageName: "star")],
            tabs: [.init(
                id: "b",
                urlString: "https://remote.example/",
                userTitleOverride: "Remote name",
                spaceID: "work",
            )],
        ))
        f.model.setUserTitleOverride("Latest local", forTabID: b.id)
        let writes = f.store.attemptedSessionWriteBatches.count
        let pushes = f.sync.pushes.count
        for request in savedRequests.reversed() {
            f.driver.emitCreatedTab(
                id: request.id,
                title: "Stale placeholder",
                urlString: request.urlString,
                isActive: true,
            )
        }
        #expect(f.model.tabs.map(\.syncID) == ["b"])
        #expect(f.model.tabs.first?.id == b.id)
        #expect(f.model.tabs.first?.userTitleOverride == "Latest local")
        #expect(f.model.tabs.first?.urlString == "https://live.example/")
        #expect(f.model.tabs.first?.title == "Current page")
        #expect(f.model.spaces.first?.title == "Remote")
        #expect(f.store.attemptedSessionWriteBatches.count == writes)
        #expect(f.sync.pushes.count == pushes)
    }

    @Test func failedStartupSaveExportsAllTabsAndRetriesWithoutCallbackWrites() throws {
        let f = StartupRestorationFixture(snapshot: startupSnapshot())
        defer { f.cleanup() }
        f.store.sessionWriteError = StartupRestorationError.unavailable
        f.model.handleContextReady()
        #expect(f.model.hasUncommittedSessionWrites)
        #expect(f.model.sessionRecoverySnapshot().tabs.map(\.id) == ["a", "b", "c"])
        let b = try #require(f.model.tabs.first { $0.syncID == "b" })
        f.model.setUserTitleOverride("While unsaved", forTabID: b.id)
        let batch = try #require(f.store.attemptedSessionWriteBatches.last)
        #expect(batch.count == 2)
        let attempts = f.store.attemptedSessionWriteBatches.count
        f.driver.flushPendingCreateEvents()
        #expect(f.store.attemptedSessionWriteBatches.count == attempts)
        f.store.sessionWriteError = nil
        #expect(f.model.retrySessionPersistence())
        #expect(f.store.savedSessionWriteBatches.last == batch)
        #expect(f.store.savedSnapshots.last?.tabs.map(\.id) == ["a", "b", "c"])
        #expect(f.store.savedSnapshots.last?.tabs.first { $0.id == "b" }?.userTitleOverride == "While unsaved")
    }

    @Test func legacyMissingIdentitiesAreAssignedOnceBeforeAnyCallback() {
        let f = StartupRestorationFixture(snapshot: .init(tabURLStrings: ["https://a.example/", "https://b.example/"]))
        defer { f.cleanup() }
        f.model.handleContextReady()
        let ids = f.model.tabs.map(\.syncID)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { !$0.isEmpty })
        let saved = f.store.savedSnapshots.count
        for request in f.driver.createdTabRequests.reversed() {
            f.driver.emitCreatedTab(id: request.id, urlString: request.urlString, isActive: true)
        }
        #expect(f.model.tabs.map(\.syncID) == ids)
        #expect(f.store.savedSnapshots.count == saved)
    }
}

// MARK: - StartupRestorationError

private enum StartupRestorationError: Error { case unavailable }

// MARK: - StartupRestorationFixture

@MainActor private final class StartupRestorationFixture {
    // MARK: Internal

    let suiteName: String
    let defaults: UserDefaults
    let driver = FakeBrowserTabDriver()
    let store: InMemorySessionSnapshotStore
    let sync = StartupSyncRecorder()
    let model: BrowserChromeModel

    init(snapshot: BrowserTabSessionSnapshot) {
        self.suiteName = BrowserTestDefaults.suiteName("BrowserStartupRestorationTests")
        self.defaults = UserDefaults(suiteName: suiteName)!
        self.store = InMemorySessionSnapshotStore(loadedSnapshot: snapshot)
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store,
            sessionPreferencesStore: InMemorySessionPreferencesStore(storedSelectedTabIndex: 1),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: sync,
            windowTitleHandler: { _ in }, allTabsClosedHandler: {},
        )
    }

    func cleanup() { defaults.removePersistentDomain(forName: suiteName) }
}

// MARK: - StartupSyncRecorder

@MainActor private final class StartupSyncRecorder: BrowserSyncCoordinating {
    var pushes = [BrowserTabSessionSnapshot]()

    func schedulePush(snapshot: BrowserTabSessionSnapshot) { pushes.append(snapshot) }
    func schedulePull() {}
}

private func startupSnapshot() -> BrowserTabSessionSnapshot {
    .init(
        spaces: [
            .init(id: "work", title: "Work", systemImageName: "briefcase", selectedTabIndex: 1),
            .init(id: "read", title: "Read", systemImageName: "book", selectedTabIndex: 0),
        ],
        pinnedTabFolders: [.init(id: "folder", spaceID: "work", title: "Saved folder")],
        tabs: [
            .init(
                id: "a",
                urlString: "https://a.example/",
                placement: .spacePinned,
                spaceID: "work",
                pinnedFolderID: "folder",
            ),
            .init(id: "b", urlString: "https://b.example/", spaceID: "work"),
            .init(id: "c", urlString: "https://c.example/", spaceID: "read"),
        ],
    )
}
