// BrowserSiteControlCenterTests.swift

import AppKit
import Foundation
import Testing

// MARK: - SiteControlFixture

@MainActor private final class SiteControlFixture {
    // MARK: Internal

    let suite: String
    let defaults: UserDefaults
    let driver: FakeBrowserTabDriver
    let model: BrowserChromeModel

    init(extensions: [BrowserExtension] = [], mode: BrowserWindowMode = .normal) throws {
        let suite = BrowserTestDefaults.suiteName("BrowserSiteControlCenterTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        let driver = FakeBrowserTabDriver()
        self.suite = suite
        self.defaults = defaults
        self.driver = driver
        self.model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(),
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(extensions: extensions),
            windowMode: mode,
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        // macOS has already let OpenArc use the camera, microphone and location.
        model.requestSystemMediaCaptureAuthorization = { _, completion in completion(true) }
        model.requestSystemLocationAuthorization = { completion in completion(true) }
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        model.createNewTab()
        driver.flushPendingCreateEvents()
        model.refreshBrowserExtensions()
    }

    func show(_ urlString: String) throws {
        let tab = try #require(model.selectedTabID)
        driver.emitUpdate(id: tab, urlString: urlString)
    }

    func cleanup() {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor @Test func siteSettingsListRememberedAnswersAndChromiumValuesInOrder() throws {
    let fixture = try SiteControlFixture()
    defer { fixture.cleanup() }
    let url = "https://meet.example/room?x=1"
    try fixture.show(url)
    #expect(fixture.model.siteSettingRows(forURLString: url).filter { $0.kind != .developerMode }.isEmpty)

    fixture.driver.siteSettingsByURL[url] = [.notifications: .block, .location: .allow]
    fixture.model.setSiteSetting(.microphone, value: .allow, forURLString: url)
    fixture.model.setSiteSetting(.camera, value: .block, forURLString: "https://meet.example/other")
    #expect(fixture.model.siteSettingRows(forURLString: url).filter { $0.kind != .developerMode } == [
        .init(kind: .camera, value: .block),
        .init(kind: .microphone, value: .allow),
        .init(kind: .location, value: .allow),
        .init(kind: .notifications, value: .block),
    ])

    // Ask forgets a remembered answer; Chromium kinds go to the engine.
    fixture.model.setSiteSetting(.camera, value: .ask, forURLString: url)
    fixture.model.setSiteSetting(.notifications, value: .default, forURLString: url)
    fixture.model.setSiteSetting(.popups, value: .allow, forURLString: url)
    #expect(fixture.model.siteSettingRows(forURLString: url).filter { $0.kind != .developerMode }.map(\.kind) == [
        .microphone,
        .location,
        .popups,
    ])
    #expect(fixture.model.rememberedSitePermissions.map(\.kind) == [.microphone])

    // Internal pages have no site settings.
    #expect(fixture.model.siteSettingRows(forURLString: "openarc://settings").isEmpty)
}

@MainActor @Test func incognitoSiteSettingsStayInTheWindow() throws {
    let fixture = try SiteControlFixture(mode: .incognito)
    defer { fixture.cleanup() }
    let url = "https://meet.example/"
    fixture.model.setSiteSetting(.camera, value: .allow, forURLString: url)
    #expect(fixture.model.userPreferencesStore.sitePermissionDecisions.isEmpty)
    #expect(fixture.model.siteSettingRows(forURLString: url).filter { $0.kind != .developerMode } == [.init(
        kind: .camera,
        value: .allow,
    )])
}

@MainActor @Test func pictureInPictureCanGoBackToAsk() {
    #expect(BrowserSiteSettingKind.autoPictureInPicture.choices == [.allow, .block, .ask])
    #expect(BrowserSiteSettingKind.popups.choices == [.allow, .block])
}

@MainActor @Test func allSiteSettingsOpensChromiumsPageForTheOrigin() throws {
    let fixture = try SiteControlFixture()
    defer { fixture.cleanup() }
    fixture.model.openAllSiteSettings(forURLString: "https://meet.example:8443/room")
    fixture.driver.flushPendingCreateEvents()
    #expect(fixture.driver.createdTabRequests.last?.urlString
        == "openarc://settings/content/siteDetails?site=https://meet.example:8443")
}

@MainActor @Test func controlCenterLaysOutActionsWrappedExtensionsSettingsAndConnection() throws {
    let extensions = (1...6).map { BrowserExtension(id: "e\($0)", name: "E\($0)", version: "1", isEnabled: true) }
    let fixture = try SiteControlFixture(extensions: extensions)
    defer { fixture.cleanup() }
    let url = "https://meet.example/room"
    try fixture.show(url)
    fixture.model.setSiteSetting(.camera, value: .allow, forURLString: url)
    fixture.driver.siteSettingsByURL[url] = [.location: .block]

    let controller = BrowserSiteControlCenterViewController(model: fixture.model)
    var actions = [BrowserSiteControlCenterViewController.Action]()
    controller.onAction = { actions.append($0) }
    _ = controller.view
    controller.reloadSiteSettings()
    let view = controller.view
    view.layoutSubtreeIfNeeded()

    let identifiers = ["share", "copy-url", "capture", "capture-full-page"]
    let buttons = try identifiers.map { try #require(siteControlView("browser.site-control.\($0)", in: view)) }
    #expect(Set(buttons.map(\.frame.minY)).count == 1, "The page actions share one row")
    // Six extensions and Add wrap four to a row.
    let tiles = view.subviews.compactMap { $0 as? BrowserNativeExtensionButton }
    #expect(tiles.count == 7)
    #expect(Set(tiles.map(\.frame.minY)).count == 2)
    #expect(tiles.allSatisfy { $0.frame.maxX <= BrowserChromeLayout.siteControlPopoverWidth })
    let camera = try #require(siteControlView("browser.site-control.setting.camera", in: view))
    let location = try #require(siteControlView("browser.site-control.setting.location", in: view))
    #expect(camera.frame.maxY <= location.frame.minY)
    let security = try #require(siteControlView("browser.site-control.security", in: view))
    #expect(security.accessibilityLabel() == BrowserStrings.siteControlSecure)
    #expect(security.frame.maxY <= controller.preferredContentSize.height)

    let copy = try #require(buttons[1] as? BrowserNativePressableView)
    copy.onClick(nil)
    #expect(actions == [.copyURL])

    // A page that moves to another origin while the popover is open shows that
    // site's settings: a plain HTTP page without any, and not secure.
    try fixture.show("http://plain.example/")
    controller.refresh()
    #expect(security.accessibilityLabel() == BrowserStrings.siteControlNotSecure)
    #expect(siteControlView("browser.site-control.setting.camera", in: view)?.isHidden ?? true)
}

@MainActor private func siteControlView(_ identifier: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == identifier {
        return view
    }
    for subview in view.subviews {
        if let match = siteControlView(identifier, in: subview) {
            return match
        }
    }
    return nil
}

@MainActor @Test func controlCenterKeepsWherePopoverPlacesItsContent() throws {
    let fixture = try SiteControlFixture(extensions: [])
    defer { fixture.cleanup() }
    try fixture.show("https://meet.example/room")
    let controller = BrowserSiteControlCenterViewController(model: fixture.model)
    // A popover with its arrow on the left puts the content past the arrow.
    controller.view.setFrameOrigin(NSPoint(x: 13, y: 0))
    controller.reloadSiteSettings()
    #expect(controller.view.frame.origin == NSPoint(x: 13, y: 0))
    #expect(controller.view.frame.size == controller.preferredContentSize)
}
