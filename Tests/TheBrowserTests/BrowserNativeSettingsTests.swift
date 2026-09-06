import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeSettingsTests {
    // MARK: Internal

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
        let popup = try #require(find(
            "browser.settings.search-engine",
            in: controller.view
        ) as? BrowserActionPopUpButton)
        popup.selectItem(withTitle: BrowserSearchEngine.brave.title)
        _ = popup.sendAction(popup.action, to: popup.target)
        #expect(fixture.model.userPreferencesStore.searchEngine == .brave)
        fixture.model.userPreferencesStore.searchEngine = .duckDuckGo
        try await waitUntil { popup.titleOfSelectedItem == BrowserSearchEngine.duckDuckGo.title }
    }

    @Test func everyPaneLaysOutNativeContentWithinTheViewport() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for pane in BrowserSettingsPane.allCases {
            let controller = fixture.controller(pane)
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.view.fittingSize == NSSize(
                width: BrowserSettingsLayout.windowWidth,
                height: BrowserSettingsLayout.windowHeight
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
        let ids = ["automatic-updates", "warn-before-quitting", "battery-saver", "search-suggestions"]
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
            defer: false
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
            keyCode: 15
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
            keyCode: 53
        ))
        #expect(BrowserShortcutCaptureNSView.handleRecordingEvent(escape))
        #expect(cancelled)
        window.makeFirstResponder(nil)
        #expect(!BrowserShortcutCaptureNSView.handleRecordingEvent(reload))
    }

    // MARK: Private

    @MainActor private struct Fixture {
        // MARK: Lifecycle

        init() throws {
            self.suite = "TheBrowserNativeSettingsTests.\(UUID().uuidString)"
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
                allTabsClosedHandler: {}
            )
        }

        // MARK: Internal

        let suite: String
        let defaults: UserDefaults
        let root: URL
        let profiles: BrowserProfileStore
        let model: BrowserChromeModel

        func controller(_ pane: BrowserSettingsPane) -> BrowserSettingsViewController {
            BrowserSettingsViewController(
                model: model,
                profileStore: profiles,
                currentProfileID: BrowserProfile.defaultProfile.id,
                accountStore: nil,
                pane: pane,
                openProfile: { _ in },
                openURL: { _ in }
            )
        }

        func cleanup() { defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
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
