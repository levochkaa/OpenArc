// BrowserNativeTabCreationTests.swift

import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeTabCreationTests {
    // MARK: Internal

    @Test func initializationCreationAndFailureNeverExposeThePreviousPage() throws {
        let host = NSView()
        let view = BrowserContentNSView(hostView: host)
        let loading = try find("browser.content.loading", in: view)
        let loadingMessage = try control(NSTextField.self, "browser.content.loading.message", in: view)
        let failure = try find("browser.content.creation-failure", in: view)
        let retry = try control(NSButton.self, "browser.content.creation-failure.retry", in: view)
        var retries = 0
        view.onRetryTabCreation = { retries += 1 }

        update(view, host: host, state: .failed, contextReady: false)
        #expect(view.viewport.isHidden)
        #expect(!loading.isHidden && failure.isHidden)
        #expect(loadingMessage.stringValue == BrowserStrings.loadingLaunchingBrowser)
        retry.performClick(nil)
        #expect(retries == 0)

        update(view, host: host, state: .creating)
        #expect(view.viewport.isHidden)
        #expect(!loading.isHidden && failure.isHidden)
        #expect(loadingMessage.stringValue == BrowserStrings.loadingOpeningTab)

        update(view, host: host, state: .failed)
        #expect(view.viewport.isHidden)
        #expect(loading.isHidden && !failure.isHidden)
        #expect(retry.isEnabled && retry.title == BrowserStrings.tabCreationRetry)
        retry.performClick(nil)
        #expect(retries == 1)

        update(view, host: host, state: .ready)
        #expect(!view.viewport.isHidden)
        #expect(loading.isHidden && failure.isHidden)
        retry.performClick(nil)
        #expect(retries == 1)

        update(view, host: host, state: .failed, hasSelectedTab: false)
        #expect(view.viewport.isHidden)
        #expect(loading.isHidden && failure.isHidden)
        #expect(!retry.isEnabled)
    }

    @Test(arguments: [240.0, 640.0, 1200.0]) func failureTextAndRetryFitWithoutOverlap(width: Double) throws {
        let host = NSView()
        let view = BrowserContentNSView(hostView: host)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 260)
        update(view, host: host, state: .failed)
        view.layoutSubtreeIfNeeded()
        let failure = try find("browser.content.creation-failure", in: view)
        let controls = failure.subviews.compactMap { $0 as? NSControl }
        #expect(controls.count == 3)
        #expect(failure.frame == view.bounds)
        #expect(failure.layer?.cornerRadius == view.viewport.layer?.cornerRadius)
        #expect(failure.layer?.maskedCorners == view.viewport.layer?.maskedCorners)
        let frames = controls.map { $0.convert($0.bounds, to: view) }
        for frame in frames {
            #expect(frame.width > 0 && frame.height > 0)
            #expect(view.bounds.contains(frame))
        }
        for i in frames.indices {
            for j in frames.indices where i < j {
                #expect(!frames[i].intersects(frames[j]))
            }
        }
        let retry = try #require(controls.first { $0 is NSButton })
        #expect(abs(retry.frame.midX - view.bounds.midX) < 0.5)
    }

    @Test func productionBindingRetriesOnlyTheSelectedFailedTab() throws {
        let suiteName = BrowserTestDefaults.suiteName("BrowserNativeTabCreationTests")
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = BrowserUserPreferencesStore(userDefaults: defaults)
        preferences.restoreWindowsOnLaunch = true
        let driver = FakeBrowserTabDriver()
        let model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(
                loadedSnapshot: .init(tabURLStrings: ["https://first.example", "https://second.example"]),
            ),
            sessionPreferencesStore: InMemorySessionPreferencesStore(storedSelectedTabIndex: 0),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: preferences,
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        defer { model.prepareForTermination() }
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        let selectedID = try #require(model.selectedTabID)
        let otherID = try #require(model.tabs.first { $0.id != selectedID }?.id)
        driver.emitTabCreationState(id: selectedID, state: .failed)

        let content = BrowserContentNSView(hostView: model.hostView)
        content.bindTabCreation(to: model)
        content.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        refresh(content, from: model)
        content.layoutSubtreeIfNeeded()
        let failure = try find("browser.content.creation-failure", in: content)
        let loading = try find("browser.content.loading", in: content)
        let retry = try control(NSButton.self, "browser.content.creation-failure.retry", in: content)
        #expect(!failure.isHidden && content.viewport.isHidden)
        retry.performClick(nil)
        retry.performClick(nil)
        #expect(driver.retryCreationRequests == [.init(id: selectedID, urlString: "https://first.example")])
        #expect(model.selectedTabCreationState == .creating)
        refresh(content, from: model)
        #expect(failure.isHidden && !loading.isHidden)
        #expect(content.viewport.isHidden)

        driver.emitTabCreationState(id: selectedID, state: .ready)
        refresh(content, from: model)
        #expect(!content.viewport.isHidden && loading.isHidden)
        driver.emitTabCreationState(id: otherID, state: .failed)
        refresh(content, from: model)
        #expect(model.selectedTabCreationState == .ready)
        #expect(failure.isHidden && !content.viewport.isHidden)
        model.selectTab(id: otherID)
        refresh(content, from: model)
        #expect(!failure.isHidden && content.viewport.isHidden)
        model.selectTab(id: selectedID)
        refresh(content, from: model)
        #expect(failure.isHidden && !content.viewport.isHidden)
        #expect(driver.retryCreationRequests.count == 1)
    }

    @Test func aPageThatAttachesAfterTheCreationWatchdogStillShows() {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.selectTab(id: f.id("x"))
        f.driver.emitTabCreationState(id: f.id("x"), state: .failed)
        #expect(f.model.selectedTabCreationState == .failed)
        // The engine reports a late page as Creating, then Ready.
        f.driver.emitTabCreationState(id: f.id("x"), state: .creating)
        f.driver.emitTabCreationState(id: f.id("x"), state: .ready)
        #expect(f.model.selectedTabCreationState == .ready)
    }

    // MARK: Private

    private func update(
        _ view: BrowserContentNSView,
        host: NSView,
        state: BrowserTabCreationState,
        contextReady: Bool = true,
        hasSelectedTab: Bool = true,
    ) {
        view.update(
            hostView: host,
            isContextReady: contextReady,
            hasSelectedTab: hasSelectedTab,
            isSidebarVisible: true,
            usesWindowContentInsets: true,
            selectedTabCreationState: state,
        )
    }

    private func find(_ identifier: String, in view: NSView) throws -> NSView {
        try #require(descendants(view).first { $0.accessibilityIdentifier() == identifier })
    }

    private func control<T: NSView>(_: T.Type, _ identifier: String, in view: NSView) throws -> T {
        let found = try find(identifier, in: view)
        return try #require(found as? T)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func refresh(_ content: BrowserContentNSView, from model: BrowserChromeModel) {
        content.update(
            hostView: model.hostView,
            isContextReady: model.isContextReady,
            hasSelectedTab: model.selectedTabID != nil,
            isSidebarVisible: true,
            usesWindowContentInsets: true,
            selectedTabCreationState: model.selectedTabCreationState,
        )
    }
}
