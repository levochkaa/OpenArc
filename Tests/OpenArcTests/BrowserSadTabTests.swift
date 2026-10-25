// BrowserSadTabTests.swift

import AppKit
import Testing

// MARK: - BrowserSadTabTests

@Suite(.serialized)
@MainActor struct BrowserSadTabTests {
    @Test func aCrashOnScreenShowsTheCrashPageAndABackgroundCrashReloadsWhenShown() async throws {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        let x = f.id("x")
        let y = f.id("y")
        f.model.selectTab(id: x)
        let reloads = f.driver.reloadCount

        f.driver.onRenderProcessTerminated?(x, 5)
        #expect(f.model.crashedTabErrorCodes == [x: 5])
        // Loading again clears it, as ⌘R would.
        f.driver.emitLoadingStateChange(id: x, isLoading: true)
        #expect(f.model.crashedTabErrorCodes.isEmpty)

        // Reload on the crash page reloads the tab.
        f.driver.onRenderProcessTerminated?(x, 5)
        f.model.reloadCrashedTab(id: x)
        #expect(f.model.crashedTabErrorCodes.isEmpty)
        #expect(f.driver.reloadCount == reloads + 1)

        // A tab off screen reloads once it is shown, as in Chrome.
        f.driver.onRenderProcessTerminated?(y, 9)
        #expect(f.model.crashedTabErrorCodes.isEmpty)
        f.model.selectTab(id: y)
        for _ in 0..<50 where f.driver.reloadCount == reloads + 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.driver.reloadCount == reloads + 2)
        #expect(f.model.selectedTabID == y)
    }

    @Test func theCrashPageCoversThePageAndItsLinkReloads() throws {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        let x = f.id("x")
        f.model.selectTab(id: x)
        let content = BrowserContentNSView(hostView: f.model.hostView)
        content.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        content.bindTabCreation(to: f.model)
        content.update(
            hostView: f.model.hostView,
            isContextReady: true,
            hasSelectedTab: true,
            isSidebarVisible: true,
            usesWindowContentInsets: true,
        )
        f.driver.onRenderProcessTerminated?(x, 11)
        content.refreshCrashPages()
        content.layoutSubtreeIfNeeded()
        let page = try #require(content.crashPages[x])
        #expect(!page.isHidden && page.frame == content.bounds)
        #expect(page.accessibilityLabel() == String(
            format: BrowserStrings.sadTabMessage,
            BrowserStrings.sadTabReloadLink,
        ))
        let reloads = f.driver.reloadCount
        let message = try #require(page.subviews.compactMap { $0 as? NSTextView }.first)
        let handled = page.textView(message, clickedOnLink: BrowserSadTabView.reloadLink, at: 0)
        #expect(handled)
        #expect(f.driver.reloadCount == reloads + 1)
        content.refreshCrashPages()
        #expect(content.crashPages.isEmpty)
    }
}
