// BrowserNativeSiteControlsTests.swift

import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeSiteControlsTests {
    // MARK: Internal

    @Test func toolbarKeepsURLWithinChromeAndHonorsFullURLPreference() throws {
        let model = makeModel()
        let view = BrowserSiteControlsNSView(model: model, mode: .toolbar)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: BrowserChromeLayout.siteToolbarHeight)
        view.layoutSubtreeIfNeeded()
        #expect(view.urlButton.frame.width <= BrowserChromeLayout.siteToolbarURLButtonMaximumWidth)
        #expect(view.bounds.contains(view.urlButton.frame))
        #expect(view.copyButton.frame.maxX < view.urlButton.frame.minX)
        #expect(view.urlButton.frame.maxX < view.siteButton.frame.minX)
        model.userPreferencesStore.siteToolbarShowsFullURL = true
        view.refresh()
        #expect(try view.urlButton.accessibilityLabel() == BrowserURLDisplayFormatter
            .fullDisplayString(for: #require(model.currentTab?.urlString)))
        model.userPreferencesStore.siteToolbarShowsFullURL = false
        view.refresh()
        #expect(try view.urlButton.accessibilityLabel() == BrowserURLDisplayFormatter
            .displayString(for: #require(model.currentTab?.urlString)))
    }

    @Test func toolbarContextMenuChangesOnlyRequestedPreferences() throws {
        let model = makeModel()
        let view = BrowserSiteControlsNSView(model: model, mode: .toolbar)
        let wasToolbar = model.userPreferencesStore.siteURLToolbarEnabled
        let wasBookmarks = model.userPreferencesStore.bookmarksBarVisible
        let menu = view.urlMenu()
        let title = wasToolbar ? BrowserStrings.siteShowInSidebarAction : BrowserStrings.siteShowAsToolbarAction
        let index = try #require(menu.items.firstIndex { $0.title == title })
        menu.performActionForItem(at: index)
        #expect(model.userPreferencesStore.siteURLToolbarEnabled != wasToolbar)
        #expect(model.userPreferencesStore.bookmarksBarVisible == wasBookmarks)
    }

    @Test func pinnedExtensionButtonsFollowPinnedOrderAndExcludeDisabledExtensions() {
        let a = browserExtension("a")
        let b = browserExtension("b")
        let disabled = browserExtension("disabled", enabled: false)
        let model = makeModel(extensions: [a, b, disabled])
        model.setExtension(id: b.id, isPinned: true)
        model.setExtension(id: disabled.id, isPinned: true)
        model.setExtension(id: a.id, isPinned: true)
        let view = BrowserSiteControlsNSView(model: model, mode: .toolbar)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 28)
        view.layoutSubtreeIfNeeded()
        let buttons = view.subviews
            .compactMap { $0 as? BrowserNativeExtensionButton }
            .sorted { $0.frame.minX < $1.frame.minX }
        #expect(buttons.map { $0.accessibilityIdentifier() } == [
            "browser.extensions.pinned.b",
            "browser.extensions.pinned.a",
        ])
    }

    @Test func extensionMenuPreservesPinActionAndDisabledInspector() throws {
        let model = makeModel(extensions: [browserExtension("a")])
        let presenter = BrowserNativeExtensionPopoverPresenter(model: model)
        let menu = presenter.menu(for: browserExtension("a"))
        let pin = try #require(menu.items.firstIndex { $0.title == BrowserStrings.extensionsPinAction })
        menu.performActionForItem(at: pin)
        #expect(model.isExtensionPinned(id: "a"))
        let inspector = try #require(menu.items.first { $0.title == BrowserStrings.extensionsInspectPopup })
        #expect(!inspector.isEnabled)
    }

    @Test func extensionPopupClosesEngineOnceAcrossBothCloseAndDisappear() {
        var closes = 0
        let host = NSView()
        let popup = BrowserExtensionActionPopup(
            id: "popup",
            extensionID: "extension",
            title: "Extension",
            hostView: host,
        ) { closes += 1 }
        let controller = BrowserExtensionActionPopupViewController(popup: popup)
        _ = controller.view
        #expect(host.superview === controller.view)
        #expect(controller.preferredContentSize == NSSize(
            width: BrowserChromeLayout.extensionActionPopupWidth,
            height: BrowserChromeLayout.extensionActionPopupHeight,
        ))
        controller.close()
        controller.viewDidDisappear()
        controller.close()
        #expect(closes == 1)
    }

    @Test func sidebarURLActionsAreHiddenUntilHoverAndDisabledWhileResizing() throws {
        let view = BrowserSiteControlsNSView(model: makeModel(), mode: .sidebar)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 36)
        view.layoutSubtreeIfNeeded()
        #expect(view.copyButton.isHidden)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0,
        ))
        view.mouseEntered(with: event)
        view.layoutSubtreeIfNeeded()
        #expect(!view.copyButton.isHidden)
        #expect(view.urlButton.maskedTrailingWidth == 61, "The address makes room for the actions at once")
        view.isSidebarResizing = true
        #expect(view.copyButton.isHidden)
        #expect(!view.copyButton.isEnabled)
        #expect(view.urlButton.maskedTrailingWidth == BrowserChromeLayout.sidebarCurrentURLRestingTrailingWidth)
    }

    // MARK: Private

    private func browserExtension(_ id: String, enabled: Bool = true) -> BrowserExtension {
        .init(id: id, name: id.uppercased(), version: "1.0", isEnabled: enabled, iconData: nil, sidePanelURLString: nil)
    }

    private func makeModel(extensions: [BrowserExtension] = []) -> BrowserChromeModel {
        let driver = FakeBrowserTabDriver()
        let defaults = UserDefaults(suiteName: "OpenArcNativeSiteTests.\(UUID().uuidString)")!
        let model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(
                loadedSnapshot: .init(tabURLStrings: ["https://example.com/path?query=value"]),
            ),
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(extensions: extensions),
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        model.refreshBrowserExtensions()
        return model
    }
}
