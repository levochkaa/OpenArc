import Foundation
import Testing

@Test
func extensionControlCenterGridAlwaysKeepsAddTileLast() {
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

@Test
func extensionControlCenterGridShowsAddTileWhenNoExtensionsAreInstalled() {
    let items = BrowserExtensionControlCenterModel.gridItems(for: [])

    #expect(items.map(\.id) == ["extension:add"])
}

@Test
@MainActor
func extensionManagerActionsRefreshFromEngineSource() {
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
@MainActor
func extensionRoutesOpenExpectedTabs() {
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

@MainActor
private func makeExtensionModel(
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
