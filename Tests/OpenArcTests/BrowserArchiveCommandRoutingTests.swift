// BrowserArchiveCommandRoutingTests.swift

import AppKit
import Testing

// MARK: - BrowserArchiveCommandRoutingTests

@Suite(.serialized) @MainActor struct BrowserArchiveCommandRoutingTests {
    @Test(arguments: ["unregistered", "terminating", "incognito", "web-app", "discarded", "shutdown", "unrelated"])
    func rejectedOwnerNeverPresentsAnArchive(reason: String) async throws {
        try await withArchiveRoutingFixture { f in
            let owner: BrowserChromeModel =
                switch reason {
                case "incognito": f.makeModel(mode: .incognito)
                case "web-app": f.makeModel(mode: .webApp(archiveRoutingWebApp()))
                default: f.model
                }
            if reason == "discarded" {
                owner.discardUnsavedSessionForClosure()
            }
            if reason == "shutdown" {
                owner.prepareForTermination()
            }
            var presented = 0
            let before = try f.store.loadSnapshotStrict()
            let archive = try f.store.loadArchivePage()
            let handled = BrowserArchiveCommandRouting.perform(
                reason == "unrelated" ? .archiveTab : .clearArchive,
                from: owner,
                registeredOwners: reason == "unregistered" ? [f.makeModel()] : [owner],
                isTerminating: reason == "terminating",
                present: { _ in
                    presented += 1
                    return nil
                },
            )
            #expect(!handled && presented == 0)
            #expect(try f.store.loadSnapshotStrict() == before)
            #expect(try f.store.loadArchivePage() == archive)
            let noEnginesCreated = f.drivers.allSatisfy(\.createdTabRequests.isEmpty)
            #expect(noEnginesCreated)
        }
    }

    @Test func wrongOwnerReturnedByPresenterCannotClearItsArchive() async throws {
        try await withArchiveRoutingFixture { f in
            let other = f.makeModel()
            var alerts = 0
            let wrong = BrowserArchiveViewController(model: other, alertPresenter: { _, _ in alerts += 1 })
            defer { wrong.invalidate() }
            let before = try f.store.loadArchivePage()
            let handled = BrowserArchiveCommandRouting.perform(
                .clearArchive,
                from: f.model,
                registeredOwners: [f.model, other],
                isTerminating: false,
                present: { owner in
                    #expect(owner === f.model)
                    return wrong
                },
            )
            await Task.yield()
            #expect(!handled && alerts == 0 && wrong.pendingClearBoundary == nil)
            #expect(try f.store.loadArchivePage() == before)
        }
    }

    @Test func viewUsesRegisteredIdentityWithoutAnEngineAndFocusesItsSearchField() async throws {
        try await withArchiveRoutingFixture { f in
            let other = f.makeModel()
            let controller = BrowserArchiveViewController(model: f.model)
            let window = NSWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: 740, height: 480),
                styleMask: [.titled], backing: .buffered, defer: true,
            )
            window.contentViewController = controller
            defer {
                controller.invalidate()
                window.contentViewController = nil
            }
            #expect(!f.model.isContextReady && f.model.canBrowseArchive)
            let before = try f.store.loadSnapshotStrict()
            var owners = [ObjectIdentifier]()
            for _ in 0..<2 {
                let handled = BrowserArchiveCommandRouting.perform(
                    .viewArchive,
                    from: f.model,
                    registeredOwners: [other, f.model],
                    isTerminating: false,
                    present: { owner in
                        owners.append(ObjectIdentifier(owner))
                        return controller
                    },
                )
                #expect(handled)
            }
            #expect(owners == [ObjectIdentifier(f.model), ObjectIdentifier(f.model)])
            #expect(controller.searchField.currentEditor() === window.firstResponder)
            #expect(try f.store.loadSnapshotStrict() == before)
            let noEnginesCreated = f.drivers.allSatisfy(\.createdTabRequests.isEmpty)
            #expect(noEnginesCreated)
        }
    }

    @Test func archiveMenuUsesCustomizedShortcutsForLatinDispatchAndPhysicalLayoutBridge() throws {
        _ = NSApplication.shared
        let suite = BrowserTestDefaults.suiteName("ArchiveCommandShortcuts")
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let shortcuts = BrowserShortcutStore(userDefaults: preferences)
        let target = ArchiveRoutingMenuTarget()
        let initial = BrowserArchiveCommandRouting.menuItems(
            shortcutResolver: shortcuts,
            viewAction: #selector(ArchiveRoutingMenuTarget.viewArchive(_:)),
            clearAction: #selector(ArchiveRoutingMenuTarget.clearArchive(_:)),
            target: target,
        )
        let noDefaultShortcuts = initial.allSatisfy(\.keyEquivalent.isEmpty)
        #expect(initial.count == 2 && noDefaultShortcuts)
        #expect(initial.map(\.identifier?.rawValue) == ["browser.archive.open", "browser.archive.clear"])
        // Keep the synthetic NSEvent unshifted: NSMenu's direct matcher compares
        // its character string literally. Physical shifted-event translation is
        // outside this offscreen fixture; both native actions must still dispatch.
        let modifiers: NSEvent.ModifierFlags = [.command, .control]
        #expect(shortcuts.setShortcut(.init("j", modifiers: modifiers), for: .viewArchive))
        #expect(shortcuts.setShortcut(.init("k", modifiers: modifiers), for: .clearArchive))
        let menu = NSMenu(title: "Archive commands")
        menu.autoenablesItems = false
        let items = BrowserArchiveCommandRouting.menuItems(
            shortcutResolver: shortcuts,
            viewAction: #selector(ArchiveRoutingMenuTarget.viewArchive(_:)),
            clearAction: #selector(ArchiveRoutingMenuTarget.clearArchive(_:)),
            target: target,
        )
        for item in items {
            menu.addItem(item)
        }
        #expect(items.map(\.keyEquivalent) == ["j", "k"])
        #expect(items.allSatisfy { $0.keyEquivalentModifierMask == modifiers && $0.target === target })
        for (key, code) in [("j", UInt16(38)), ("k", UInt16(40))] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code,
            ))
            #expect(menu.performKeyEquivalent(with: event))
            #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
                keyCode: code, modifierFlags: modifiers, charactersIgnoringModifiers: key,
                shortcutResolver: shortcuts,
            ) == nil)
        }
        #expect(target.commands == [.viewArchive, .clearArchive])
        #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
            keyCode: 38, modifierFlags: modifiers, charactersIgnoringModifiers: "о", shortcutResolver: shortcuts,
        ) == .viewArchive)
        #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
            keyCode: 40, modifierFlags: modifiers, charactersIgnoringModifiers: "л", shortcutResolver: shortcuts,
        ) == .clearArchive)
    }
}

// MARK: - ArchiveRoutingMenuTarget

@MainActor private final class ArchiveRoutingMenuTarget: NSObject {
    var commands = [BrowserCommandID]()

    @objc func viewArchive(_: Any?) { commands.append(.viewArchive) }
    @objc func clearArchive(_: Any?) { commands.append(.clearArchive) }
}

@MainActor private func withArchiveRoutingFixture(
    _ body: (ArchiveRoutingFixture) async throws -> Void,
) async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runArchiveRoutingFixture(directory: directory, body)
}

@MainActor private func runArchiveRoutingFixture(
    directory: URL, _ body: (ArchiveRoutingFixture) async throws -> Void,
) async throws {
    let fixture = try ArchiveRoutingFixture(directory: directory)
    defer { fixture.stop() }
    try await body(fixture)
}

// MARK: - ArchiveRoutingFixture

@MainActor private final class ArchiveRoutingFixture {
    // MARK: Internal

    let store: BrowserSQLiteSessionStore
    let suite = BrowserTestDefaults.suiteName("ArchiveCommandRouting")
    let preferences: UserDefaults
    private(set) var model: BrowserChromeModel!
    private(set) var models = [BrowserChromeModel]()
    private(set) var drivers = [FakeBrowserTabDriver]()

    init(directory: URL) throws {
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        self.preferences = try #require(UserDefaults(suiteName: suite))
        let space = BrowserSpaceSessionSnapshot(id: "work", title: "Work", systemImageName: "globe")
        let tab = BrowserTabSessionSnapshotTab(id: "old", urlString: "https://old.example", spaceID: "work")
        try store.writeSessionBatch([.init(
            snapshot: .init(spaces: [space], tabs: [tab]), origin: .local(syncMove: nil),
        ), .init(
            snapshot: .init(spaces: [space], tabs: []), origin: .local(syncMove: nil),
            archiveAction: .insert(.init(id: "archived", tab: tab, archivedAt: 100)),
        )])
        self.model = makeModel()
    }

    func makeModel(mode: BrowserWindowMode = .normal) -> BrowserChromeModel {
        let driver = FakeBrowserTabDriver()
        let model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: preferences),
            shortcutStore: BrowserShortcutStore(userDefaults: preferences),
            extensionManager: FakeBrowserExtensionManager(), windowMode: mode,
            windowTitleHandler: { _ in }, allTabsClosedHandler: {},
        )
        models.append(model)
        drivers.append(driver)
        return model
    }

    func stop() {
        for model in models {
            model.discardUnsavedSessionForClosure()
            model.prepareForTermination()
        }
        preferences.removePersistentDomain(forName: suite)
    }
}

private func archiveRoutingWebApp() -> BrowserWebAppConfiguration {
    .init(
        identifier: "test.archive", name: "Test", startURL: URL(string: "https://example.com")!,
        scopeURL: URL(string: "https://example.com")!, profileDirectoryName: "web-app", profileName: "Test",
        hostBundleURL: URL(fileURLWithPath: "/tmp/Browser.app"), bundleURL: URL(fileURLWithPath: "/tmp/Test.app"),
    )
}
