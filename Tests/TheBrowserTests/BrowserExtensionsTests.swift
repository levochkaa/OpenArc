import Foundation
import Testing

@Test func extensionControlCenterGridAlwaysKeepsAddTileLast() {
    let extensions = [
        makeExtension(id: "one"),
        makeExtension(id: "two"),
        makeExtension(id: "three"),
        makeExtension(id: "four"),
        makeExtension(id: "five"),
    ]

    let items = BrowserExtensionControlCenterModel.gridItems(for: extensions)

    #expect(items.count == 4)
    #expect(items.map(\.id) == [
        "extension:one",
        "extension:two",
        "extension:three",
        "extension:add",
    ])
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
            iconData: iconData
        ),
    ])
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

    #expect(Array(driver.createdTabRequests.suffix(3).map(\.urlString)) == [
        BrowserExtensionRouting.extensionsURLString,
        "tb://extensions/?id=abc%20123",
        BrowserExtensionRouting.chromeWebStoreURLString,
    ])
}

private func makeExtension(id: String, isEnabled: Bool = true) -> BrowserExtension {
    BrowserExtension(
        id: id,
        name: id.capitalized,
        version: "1.0",
        isEnabled: isEnabled,
        iconData: nil
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
    extensionManager: (any BrowserExtensionManaging)? = nil
) -> BrowserChromeModel {
    BrowserChromeModel(
        tabDriver: driver ?? FakeBrowserTabDriver(),
        sessionSnapshotStore: InMemorySessionSnapshotStore(),
        sessionPreferencesStore: InMemorySessionPreferencesStore(),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        extensionManager: extensionManager ?? FakeBrowserExtensionManager(),
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {}
    )
}
