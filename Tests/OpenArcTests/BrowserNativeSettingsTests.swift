// BrowserNativeSettingsTests.swift

import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeSettingsTests {
    // MARK: Private

    @MainActor private struct Fixture {
        // MARK: Internal

        let suite: String
        let defaults: UserDefaults
        let root: URL
        let profiles: BrowserProfileStore
        let model: BrowserChromeModel

        init() throws {
            self.suite = "OpenArcNativeSettingsTests.\(UUID().uuidString)"
            self.defaults = try #require(UserDefaults(suiteName: suite))
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.profiles = BrowserProfileStore(rootCacheURL: root)
            self.model = BrowserChromeModel(
                tabDriver: FakeBrowserTabDriver(),
                sessionSnapshotStore: InMemorySessionSnapshotStore(),
                sessionPreferencesStore: InMemorySessionPreferencesStore(),
                commandBarSuggestionProvider: FakeSuggestionProvider(),
                userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
                shortcutStore: BrowserShortcutStore(userDefaults: defaults),
                extensionManager: FakeBrowserExtensionManager(),
                windowTitleHandler: { _ in },
                allTabsClosedHandler: {},
            )
        }

        func controller(_ pane: BrowserSettingsPane) -> BrowserSettingsViewController {
            BrowserSettingsViewController(
                model: model,
                profileStore: profiles,
                currentProfileID: BrowserProfile.defaultProfile.id,
                accountStore: nil,
                pane: pane,
                openProfile: { _ in },
                openURL: { _ in },
            )
        }

        func cleanup() { defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Internal

    @Test func openProfileCannotBeDeletedEvenIfItOpensAfterSettingsRenders() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let profile = fixture.profiles.createProfile()
        var openProfiles = Set<String>()
        let controller = BrowserSettingsViewController(
            model: fixture.model,
            profileStore: fixture.profiles,
            currentProfileID: BrowserProfile.defaultProfile.id,
            accountStore: nil,
            pane: .profiles,
            canDeleteProfile: { !openProfiles.contains($0.id) },
            openProfile: { _ in },
            openURL: { _ in },
        )
        let delete = try #require(find(
            "browser.settings.profile.delete.\(profile.id)",
            in: controller.view,
        ) as? BrowserActionButton)
        #expect(delete.isEnabled)
        openProfiles.insert(profile.id)
        delete.performClick(nil)
        #expect(fixture.profiles.profile(withID: profile.id) != nil)

        let freshController = BrowserSettingsViewController(
            model: fixture.model,
            profileStore: fixture.profiles,
            currentProfileID: BrowserProfile.defaultProfile.id,
            accountStore: nil,
            pane: .profiles,
            canDeleteProfile: { !openProfiles.contains($0.id) },
            openProfile: { _ in },
            openURL: { _ in },
        )
        let disabled = try #require(find(
            "browser.settings.profile.delete.\(profile.id)",
            in: freshController.view,
        ) as? BrowserActionButton)
        #expect(!disabled.isEnabled)
        #expect(disabled.toolTip == BrowserStrings.sessionRecoveryCloseProfileBeforeDeleting)
        openProfiles.remove(profile.id)
        fixture.model.updateProfilePresentation(profile: .defaultProfile, availableProfileCount: 2)
        try await waitUntil { disabled.isEnabled }
        #expect(disabled.toolTip == nil)
        delete.performClick(nil)
        #expect(fixture.profiles.profile(withID: profile.id) == nil)
    }

    @Test func togglesAndPopupsWriteToExistingPreferencesAndReceiveExternalChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller(.general)
        let toggle = try #require(find("browser.settings.battery-saver", in: controller.view) as? BrowserActionToggle)
        let oldValue = fixture.model.userPreferencesStore.batterySaverEnabled
        toggle.performClick(nil)
        #expect(fixture.model.userPreferencesStore.batterySaverEnabled != oldValue)
        fixture.model.userPreferencesStore.batterySaverEnabled = oldValue
        try await waitUntil { toggle.state == (oldValue ? .on : .off) }
        let profiles = fixture.controller(.profiles)
        let popup = try #require(find(
            "browser.settings.search-engine",
            in: profiles.view,
        ) as? BrowserActionPopUpButton)
        popup.selectItem(withTitle: BrowserSearchEngine.brave.title)
        _ = popup.sendAction(popup.action, to: popup.target)
        #expect(fixture.model.userPreferencesStore.searchEngine == .brave)
        fixture.model.userPreferencesStore.searchEngine = .duckDuckGo
        try await waitUntil { popup.titleOfSelectedItem == BrowserSearchEngine.duckDuckGo.title }
    }

    @Test func downloadLocationShowsTheChosenFolderAndFallsBackToDownloads() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let preferences = fixture.model.userPreferencesStore
        preferences.downloadDirectoryPath = nil
        let controller = fixture.controller(.profiles)
        _ = controller.view
        controller.viewWillAppear()
        let path = try #require(find("browser.settings.download-location.path", in: controller.view) as? NSTextField)
        let reset = try #require(find(
            "browser.settings.download-location.reset",
            in: controller.view,
        ) as? BrowserActionButton)
        let downloads = BrowserDownloadLocation.defaultDirectory()
        #expect(path.stringValue == (downloads.path as NSString).abbreviatingWithTildeInPath)
        #expect(reset.isHidden)

        let folder = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("OpenArcDownloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        preferences.downloadDirectoryPath = folder.path
        try await waitUntil { !reset.isHidden }
        #expect(path.stringValue == (folder.path as NSString).abbreviatingWithTildeInPath)
        #expect(BrowserDownloadLocation.directory(customPath: folder.path) == URL(
            fileURLWithPath: folder.path,
            isDirectory: true,
        ))
        #expect(
            BrowserDownloadLocation.directory(customPath: folder.path + "-missing") == downloads,
            "A missing folder falls back",
        )
        reset.performClick(nil)
        #expect(preferences.downloadDirectoryPath == nil)
    }

    @Test func accountsPaneExistsOnlyWithTheHostedService() {
        #expect(BrowserSettingsPane.available.contains(.accounts) == BrowserHostedService.isEnabled)
    }

    @Test func everyPaneLaysOutNativeContentWithinTheViewport() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for pane in BrowserSettingsPane.allCases {
            let controller = fixture.controller(pane)
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.view.fittingSize == NSSize(
                width: BrowserSettingsLayout.windowWidth,
                height: BrowserSettingsLayout.windowHeight,
            ))
            let views = descendants(controller.view)
            let scroll = try #require(views.first { $0 is BrowserNativeScrollingStack } as? BrowserNativeScrollingStack)
            scroll.layoutSubtreeIfNeeded()
            #expect(scroll.documentView?.bounds.width == scroll.contentView.bounds.width)
            for control in views.compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                #expect(control.frame.width > 0, "\(pane): zero-width \(control)")
                #expect(control.frame.height > 0, "\(pane): zero-height \(control)")
            }
        }
    }

    @Test func multilineDescriptionsKeepControlsInOneTrailingColumn() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller(.general)
        controller.view.layoutSubtreeIfNeeded()
        let ids = ["automatic-updates", "warn-before-quitting", "battery-saver", "block-ads"]
        let edges = try ids.map { id in
            let control = try #require(find("browser.settings.\(id)", in: controller.view))
            return control.convert(control.bounds, to: controller.view).maxX
        }
        #expect(try #require(edges.max()) - #require(edges.min()) < 0.5)
    }

    @Test func filteringShortcutsRetainsSearchFieldAndFindsTitlesAndKeyCaps() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller(.shortcuts)
        let search = try #require(find("browser.settings.shortcut-search", in: controller.view) as? NSSearchField)
        let count = recordingButtons(controller.view).count
        #expect(count == fixture.model.shortcutStore.commandIDs.count)
        search.stringValue = "battery-nonexistent-shortcut"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(recordingButtons(controller.view).isEmpty)
        #expect(find("browser.settings.shortcut-search", in: controller.view) === search)
        search.stringValue = "Find"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(!recordingButtons(controller.view).isEmpty)
        #expect(recordingButtons(controller.view).count < count)
    }

    @Test func recorderConsumesBrowserShortcutsAndEscapeBeforeGlobalDispatch() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        let capture = BrowserShortcutCaptureNSView()
        window.contentView = capture
        defer { window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        var captured = [BrowserKeyboardShortcut]()
        var cancelled = false
        capture.onCapture = { captured.append($0) }
        capture.onCancel = { cancelled = true }
        #expect(window.makeFirstResponder(capture))
        let reload = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "r",
            charactersIgnoringModifiers: "r",
            isARepeat: false,
            keyCode: 15,
        ))
        #expect(BrowserShortcutCaptureNSView.handleRecordingEvent(reload))
        #expect(captured == [BrowserKeyboardShortcut("r")])
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53,
        ))
        #expect(BrowserShortcutCaptureNSView.handleRecordingEvent(escape))
        #expect(cancelled)
        window.makeFirstResponder(nil)
        #expect(!BrowserShortcutCaptureNSView.handleRecordingEvent(reload))
    }

    @Test func linkRulesAreAddedEditedAndRemovedInLinks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let preferences = fixture.model.userPreferencesStore
        let controller = fixture.controller(.links)
        let add = try #require(find("browser.settings.link-routes.add", in: controller.view) as? BrowserActionButton)
        add.performClick(nil)
        let route = try #require(preferences.linkRoutes.first)
        let firstSpace = fixture.model.spaces.first
        #expect(route.destination == firstSpace.map {
            .space(profileID: BrowserProfile.defaultProfile.id, spaceID: $0.id)
        } ?? .littleWindow)

        let field = try #require(find("browser.settings.link-routes.pattern", in: controller.view) as? NSTextField)
        field.stringValue = "figma.com"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        let match = try #require(find(
            "browser.settings.link-routes.match",
            in: controller.view,
        ) as? BrowserActionPopUpButton)
        match.onChange(1)
        let destination = try #require(
            find("browser.settings.link-routes.destination", in: controller.view) as? BrowserActionPopUpButton,
        )
        destination.onChange(destination.numberOfItems - 1)
        #expect(preferences.linkRoutes == [BrowserLinkRoute(
            id: route.id,
            match: .contains,
            pattern: "figma.com",
            destination: .littleWindow,
            spaceTitle: route.spaceTitle,
        )])

        let remove = try #require(find(
            "browser.settings.link-routes.remove",
            in: controller.view,
        ) as? BrowserActionButton)
        remove.performClick(nil)
        #expect(preferences.linkRoutes.isEmpty)
        #expect(find("browser.settings.link-routes.remove", in: controller.view) == nil)
    }

    @Test func siteSearchesAreAddedEditedRestoredAndRemovedInProfiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let preferences = fixture.model.userPreferencesStore
        preferences.siteSearches = []
        let controller = fixture.controller(.profiles)
        let add = try #require(find("browser.settings.site-search.add", in: controller.view) as? BrowserActionButton)
        add.performClick(nil)
        let added = try #require(preferences.siteSearches.first)
        for (identifier, value) in [
            ("name", "Google Translate"),
            ("keyword", "@t"),
            ("url", "https://translate.google.com/?q=%s"),
        ] {
            let field = try #require(find(
                "browser.settings.site-search.\(identifier)",
                in: controller.view,
            ) as? NSTextField)
            field.stringValue = value
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        #expect(preferences.siteSearches == [BrowserSiteSearch(
            id: added.id,
            name: "Google Translate",
            keyword: "@t",
            urlTemplate: "https://translate.google.com/?q=%s",
        )])

        let restore = try #require(find(
            "browser.settings.site-search.restore",
            in: controller.view,
        ) as? BrowserActionButton)
        restore.performClick(nil)
        #expect(preferences.siteSearches.count == BrowserSiteSearch.arcDefaults.count + 1)
        restore.performClick(nil)
        #expect(preferences.siteSearches.count == BrowserSiteSearch.arcDefaults.count + 1)

        let remove = try #require(find(
            "browser.settings.site-search.remove",
            in: controller.view,
        ) as? BrowserActionButton)
        remove.performClick(nil)
        // Restored entries get identities of their own.
        #expect(preferences.siteSearches.map(\.keyword) == BrowserSiteSearch.arcDefaults.map(\.keyword))
        #expect(Set(preferences.siteSearches.map(\.id)).isDisjoint(with: BrowserSiteSearch.arcDefaults.map(\.id)))
        let importMenu = try #require(find(
            "browser.settings.site-search.import",
            in: controller.view,
        ) as? NSPopUpButton)
        #expect(importMenu.itemTitles.dropFirst() == ["Arc", "Dia", "Google Chrome"])
    }

    private func find(_ id: String, in view: NSView) -> NSView? {
        descendants(view).first { $0.accessibilityIdentifier() == id }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func recordingButtons(_ view: NSView) -> [NSView] {
        descendants(view)
            .filter { $0.accessibilityIdentifier().hasPrefix("browser.settings.shortcut.record.") == true }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }
}
