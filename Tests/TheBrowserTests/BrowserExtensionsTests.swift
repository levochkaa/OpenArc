import Foundation
import Testing

@Test func extensionControlCenterGridAlwaysKeepsAddTileLast() {
    let extensions = (1...9).map { makeExtension(id: "e\($0)") }

    let items = BrowserExtensionControlCenterModel.gridItems(for: extensions)

    // Two rows of four: seven extensions, then Add.
    #expect(items.count == 8)
    #expect(items.map(\.id) == (1...7).map { "extension:e\($0)" } + ["extension:add"])
}

@Test func extensionControlCenterGridShowsAddTileWhenNoExtensionsAreInstalled() {
    let items = BrowserExtensionControlCenterModel.gridItems(for: [])

    #expect(items.map(\.id) == ["extension:add"])
}

@Test func extensionProfileSnapshotReadsUserInstalledExtensions() throws {
    let profileDirectory = try makeProfileDirectory()
    defer { try? FileManager.default.removeItem(at: profileDirectory) }

    let iconData = Data([0x89, 0x50, 0x4E, 0x47])
    let extensionDirectory = profileDirectory
        .appendingPathComponent("Extensions", isDirectory: true)
        .appendingPathComponent("reader", isDirectory: true)
        .appendingPathComponent("2.0.1_0", isDirectory: true)
    try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
    try iconData.write(to: extensionDirectory.appendingPathComponent("icon.png", isDirectory: false))

    try writeSecurePreferences(
        """
        {
          "extensions": {
            "settings": {
              "component": {
                "location": 5,
                "manifest": {
                  "name": "Chromium PDF Viewer",
                  "version": "1"
                },
                "path": "/component/pdf"
              },
              "reader": {
                "disable_reasons": [],
                "from_webstore": true,
                "location": 1,
                "manifest": {
                  "icons": {
                    "16": "icon.png"
                  },
                  "name": "Reader Mode",
                  "side_panel": {
                    "default_path": "panel.html"
                  },
                  "version": "2.0.1"
                },
                "path": "reader/2.0.1_0"
              }
            }
          }
        }
        """,
        in: profileDirectory
    )

    let extensions = BrowserExtensionProfileSnapshotStore.installedExtensions(profileDirectories: [profileDirectory])

    #expect(extensions == [
        BrowserExtension(
            id: "reader",
            name: "Reader Mode",
            version: "2.0.1",
            isEnabled: true,
            iconData: iconData,
            sidePanelURLString: "chrome-extension://reader/panel.html"
        ),
    ])
}

@Test func extensionResourceRouteNormalizesManifestSidePanelPath() {
    #expect(
        BrowserExtensionRouting.extensionResourceURLString(
            forExtensionID: "abc",
            path: "/panel/index.html"
        ) == "chrome-extension://abc/panel/index.html"
    )
}

@Test func extensionProfileSnapshotResolvesLocalizedNamesAndDisabledState() throws {
    let profileDirectory = try makeProfileDirectory()
    defer { try? FileManager.default.removeItem(at: profileDirectory) }

    let extensionDirectory = profileDirectory
        .appendingPathComponent("Extensions", isDirectory: true)
        .appendingPathComponent("clipper", isDirectory: true)
        .appendingPathComponent("1.0_0", isDirectory: true)
    let localeDirectory = extensionDirectory
        .appendingPathComponent("_locales", isDirectory: true)
        .appendingPathComponent("en", isDirectory: true)
    try FileManager.default.createDirectory(at: localeDirectory, withIntermediateDirectories: true)
    try Data("""
    {
      "extension_name": {
        "message": "Localized Clipper"
      }
    }
    """.utf8).write(to: localeDirectory.appendingPathComponent("messages.json", isDirectory: false))

    try writeSecurePreferences(
        """
        {
          "extensions": {
            "settings": {
              "clipper": {
                "disable_reasons": ["permissions_increase"],
                "location": 1,
                "manifest": {
                  "default_locale": "en",
                  "name": "__MSG_extension_name__",
                  "version": "1.0"
                },
                "path": "clipper/1.0_0"
              }
            }
          }
        }
        """,
        in: profileDirectory
    )

    let extensions = BrowserExtensionProfileSnapshotStore.installedExtensions(profileDirectories: [profileDirectory])

    #expect(extensions.map(\.name) == ["Localized Clipper"])
    #expect(extensions.first?.isEnabled == false)
}

@Test
@MainActor func extensionManagerActionsRefreshFromEngineSource() {
    let manager = FakeBrowserExtensionManager(
        extensions: [
            makeExtension(id: "reader", isEnabled: true),
            makeExtension(id: "clipper", isEnabled: false),
        ]
    )
    let model = makeExtensionModel(extensionManager: manager)

    model.refreshBrowserExtensions()
    #expect(model.browserExtensions.map(\.id) == ["reader", "clipper"])

    #expect(model.setExtension(id: "clipper", isEnabled: true))
    #expect(manager.enabledStateRequests.count == 1)
    #expect(manager.enabledStateRequests.first?.id == "clipper")
    #expect(manager.enabledStateRequests.first?.isEnabled == true)
    #expect(model.browserExtensions.first { $0.id == "clipper" }?.isEnabled == true)

    #expect(model.removeExtension(id: "reader"))
    #expect(manager.removedExtensionIDs == ["reader"])
    #expect(model.browserExtensions.map(\.id) == ["clipper"])
}

@Test
@MainActor func extensionRoutesOpenExpectedTabs() {
    let driver = FakeBrowserTabDriver()
    let model = makeExtensionModel(driver: driver)

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    model.openExtensionsManager()
    model.openExtensionDetails(id: "abc 123")
    model.openExtensionStore()
    model.openExtensionStore(id: "abc123")

    #expect(Array(driver.createdTabRequests.suffix(4).map(\.urlString)) == [
        BrowserExtensionRouting.extensionsURLString,
        "tb://extensions/?id=abc%20123",
        BrowserExtensionRouting.chromeWebStoreURLString,
        "https://chromewebstore.google.com/detail/abc123",
    ])
}

@Test
@MainActor func openingExtensionWithSidePanelUsesRightPanelInsteadOfDetailsTab() {
    let panelURLString = "chrome-extension://reader/panel.html"
    let manager = FakeBrowserExtensionManager(
        extensions: [
            makeExtension(id: "reader", sidePanelURLString: panelURLString),
        ]
    )
    manager.actionResults["reader"] = .sidePanel
    let driver = FakeBrowserTabDriver()
    let sidePanelDriver = FakeBrowserExtensionSidePanelDriver()
    let model = makeExtensionModel(
        driver: driver,
        extensionManager: manager,
        extensionSidePanelDriver: sidePanelDriver
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let createdTabCount = driver.createdTabRequests.count

    model.openExtension(id: "reader")

    #expect(manager.actionRequests == ["reader"])
    #expect(sidePanelDriver.openedURLStrings == [panelURLString])
    #expect(model.extensionSidePanel?.extensionID == "reader")
    #expect(model.extensionSidePanel?.urlString == panelURLString)
    #expect(driver.createdTabRequests.count == createdTabCount)
}

@Test
@MainActor func extensionWithoutPopupRunsActionWithoutOpeningDetailsTab() {
    let manager = FakeBrowserExtensionManager(
        extensions: [
            makeExtension(id: "reader"),
        ]
    )
    manager.actionResults["reader"] = .handled
    let driver = FakeBrowserTabDriver()
    let sidePanelDriver = FakeBrowserExtensionSidePanelDriver()
    let model = makeExtensionModel(
        driver: driver,
        extensionManager: manager,
        extensionSidePanelDriver: sidePanelDriver
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let createdTabCount = driver.createdTabRequests.count

    model.openExtension(id: "reader")

    #expect(manager.actionRequests == ["reader"])
    #expect(sidePanelDriver.openedURLStrings.isEmpty)
    #expect(driver.createdTabRequests.count == createdTabCount)
}

@Test
@MainActor func handledExtensionActionOpensKnownSidePanel() {
    let panelURLString = "chrome-extension://reader/panel.html"
    let manager = FakeBrowserExtensionManager(
        extensions: [
            makeExtension(id: "reader", sidePanelURLString: panelURLString),
        ]
    )
    manager.actionResults["reader"] = .handled
    let sidePanelDriver = FakeBrowserExtensionSidePanelDriver()
    let model = makeExtensionModel(
        extensionManager: manager,
        extensionSidePanelDriver: sidePanelDriver
    )

    model.handleContextReady()
    model.openExtension(id: "reader")

    #expect(manager.actionRequests == ["reader"])
    #expect(sidePanelDriver.openedURLStrings == [panelURLString])
    #expect(model.extensionSidePanel?.extensionID == "reader")
}

@Test
@MainActor func extensionPopupActionOpensActionPopoverInsteadOfDetailsTab() throws {
    let manager = FakeBrowserExtensionManager(
        extensions: [
            makeExtension(id: "reader"),
        ]
    )
    manager.actionResults["reader"] = .popup(urlString: "chrome-extension://reader/popup.html")
    let driver = FakeBrowserTabDriver()
    let popupDriver = FakeBrowserExtensionActionPopupDriver()
    let model = makeExtensionModel(
        driver: driver,
        extensionManager: manager,
        extensionActionPopupDriver: popupDriver
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let createdTabCount = driver.createdTabRequests.count

    let popup = try #require(model.openExtension(id: "reader"))

    #expect(manager.actionRequests == ["reader"])
    #expect(popup.extensionID == "reader")
    #expect(popup.title == "Reader")
    #expect(popupDriver.openedURLStrings == ["chrome-extension://reader/popup.html"])
    #expect(driver.createdTabRequests.count == createdTabCount)

    popup.close()
    #expect(popupDriver.closedPopupIDs == ["popup-1"])
}

@Test
@MainActor func pinnedExtensionsPersistAndAreRemovedWithExtension() throws {
    let suiteName = "TheBrowserTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }
    let preferencesStore = BrowserUserPreferencesStore(userDefaults: userDefaults)
    let manager = FakeBrowserExtensionManager(
        extensions: [
            makeExtension(id: "reader"),
            makeExtension(id: "clipper"),
        ]
    )
    let model = makeExtensionModel(
        userPreferencesStore: preferencesStore,
        extensionManager: manager
    )

    model.refreshBrowserExtensions()

    #expect(model.toggleExtensionPinned(id: "reader"))
    #expect(model.pinnedExtensionIDs == ["reader"])
    #expect(preferencesStore.pinnedExtensionIDs == ["reader"])
    #expect(model.toggleExtensionPinned(id: "reader"))
    #expect(model.pinnedExtensionIDs.isEmpty)

    #expect(model.setExtension(id: "clipper", isPinned: true))
    #expect(model.removeExtension(id: "clipper"))
    #expect(model.pinnedExtensionIDs.isEmpty)
    #expect(preferencesStore.pinnedExtensionIDs.isEmpty)
}

@Test
@MainActor func removingExtensionClosesActiveSidePanel() throws {
    let panelURLString = "chrome-extension://reader/panel.html"
    let manager = FakeBrowserExtensionManager(
        extensions: [
            makeExtension(id: "reader", sidePanelURLString: panelURLString),
        ]
    )
    manager.actionResults["reader"] = .sidePanel
    let sidePanelDriver = FakeBrowserExtensionSidePanelDriver()
    let model = makeExtensionModel(
        extensionManager: manager,
        extensionSidePanelDriver: sidePanelDriver
    )

    model.handleContextReady()
    model.openExtension(id: "reader")
    let panelID = try #require(model.extensionSidePanel?.panelID)

    #expect(model.removeExtension(id: "reader"))

    #expect(model.extensionSidePanel == nil)
    #expect(sidePanelDriver.closedPanelIDs == [panelID])
}

@Test func profileSnapshotInfersSidePanelFileForSidePanelExtensions() throws {
    let profileDirectory = try makeProfileDirectory()
    defer { try? FileManager.default.removeItem(at: profileDirectory) }

    let extensionDirectory = profileDirectory
        .appendingPathComponent("Extensions", isDirectory: true)
        .appendingPathComponent("reader", isDirectory: true)
        .appendingPathComponent("1.0_0", isDirectory: true)
    try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
    try Data("<html></html>".utf8).write(
        to: extensionDirectory.appendingPathComponent("sidepanel.html", isDirectory: false)
    )

    try writeSecurePreferences(
        """
        {
          "extensions": {
            "settings": {
              "reader": {
                "disable_reasons": [],
                "location": 1,
                "manifest": {
                  "manifest_version": 3,
                  "name": "Reader",
                  "permissions": ["sidePanel"],
                  "version": "1.0"
                },
                "path": "reader/1.0_0"
              }
            }
          }
        }
        """,
        in: profileDirectory
    )

    let extensionSnapshot = try #require(
        BrowserExtensionProfileSnapshotStore.installedExtensions(profileDirectories: [profileDirectory]).first
    )

    #expect(extensionSnapshot.sidePanelURLString == "chrome-extension://reader/sidepanel.html")
}

private func makeExtension(
    id: String,
    isEnabled: Bool = true,
    sidePanelURLString: String? = nil
) -> BrowserExtension {
    BrowserExtension(
        id: id,
        name: id.capitalized,
        version: "1.0",
        isEnabled: isEnabled,
        iconData: nil,
        sidePanelURLString: sidePanelURLString
    )
}

private func makeProfileDirectory() throws -> URL {
    let url = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("TheBrowserTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeSecurePreferences(_ json: String, in profileDirectory: URL) throws {
    try Data(json.utf8).write(to: profileDirectory.appendingPathComponent("Secure Preferences", isDirectory: false))
}

@MainActor private func makeExtensionModel(
    driver: FakeBrowserTabDriver? = nil,
    userPreferencesStore: BrowserUserPreferencesStore? = nil,
    extensionManager: (any BrowserExtensionManaging)? = nil,
    extensionSidePanelDriver: (any BrowserExtensionSidePanelDriving)? = nil,
    extensionActionPopupDriver: (any BrowserExtensionActionPopupDriving)? = nil
) -> BrowserChromeModel {
    BrowserChromeModel(
        tabDriver: driver ?? FakeBrowserTabDriver(),
        sessionSnapshotStore: InMemorySessionSnapshotStore(),
        sessionPreferencesStore: InMemorySessionPreferencesStore(),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: userPreferencesStore ?? BrowserUserPreferencesStore(),
        extensionManager: extensionManager ?? FakeBrowserExtensionManager(),
        extensionSidePanelDriver: extensionSidePanelDriver,
        extensionActionPopupDriver: extensionActionPopupDriver,
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {}
    )
}
