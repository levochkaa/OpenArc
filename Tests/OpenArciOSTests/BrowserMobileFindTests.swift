// BrowserMobileFindTests.swift

import BrowserMobileTestHost
import Foundation
import Testing
import UIKit
import WebKit

extension BrowserMobileUITests {
    @Test func nativeFindButtonSearchesActualWebKitMatchesWithoutWritingSession() async throws {
        try await withMobileFindFixture { f in
            try await f.start()
            let webView = try await f.load()
            let saved = try f.durableState()
            let navigationDelegate = webView.navigationDelegate
            let uiDelegate = webView.uiDelegate
            let runtimeID = f.workspace.selectedTab?.runtimeID
            let interaction = try await f.openUsingButton()
            let session = try #require(interaction.activeFindSession)

            interaction.searchText = "needle"
            session.performSearch(query: "needle", options: nil)
            try #require(await mobileFindEventually { session.resultCount == 3 })
            // Counting results need not highlight one. Drive the public native
            // navigation action before asserting its selected-result index.
            interaction.findNext()
            try #require(await mobileFindEventually {
                (0..<3).contains(session.highlightedResultIndex)
            })
            let first = session.highlightedResultIndex
            interaction.findNext()
            try #require(await mobileFindEventually { session.highlightedResultIndex != first })
            #expect((0..<3).contains(session.highlightedResultIndex))
            interaction.findPrevious()
            try #require(await mobileFindEventually { session.highlightedResultIndex == first })

            interaction.searchText = "absent-token"
            session.performSearch(query: "absent-token", options: nil)
            try #require(await mobileFindEventually { session.resultCount == 0 })
            #expect(interaction.isFindNavigatorVisible)
            #expect(f.workspace.selectedTab?.runtimeID == runtimeID)
            #expect(webView.navigationDelegate === navigationDelegate)
            #expect(webView.uiDelegate === uiDelegate)
            #expect(try f.durableState() == saved)

            f.workspace.dismissFindInPage()
            try #require(await mobileFindEventually { !interaction.isFindNavigatorVisible })
            #expect(!webView.isFindInteractionEnabled && webView.findInteraction == nil)
            #expect(try f.durableState() == saved)
        }
    }

    @Test func findKeyboardActionsAndNarrowToolbarUseSelectedPageWithoutSubmittingAddressDraft() async throws {
        try await withMobileFindFixture { f in
            try await f.start()
            let webView = try await f.load()
            f.resize(width: 320, height: 700)
            let page = f.root.pageController
            let chrome = try #require(mobileFindView("browser.chrome", in: page.view))
            let toolbarIDs = [
                "browser.back", "browser.forward", "browser.share", "browser.findInPage",
                "browser.showTabs", "browser.newTab",
            ]
            let buttons = try toolbarIDs.map { try #require(mobileFindView($0, in: page.view) as? UIButton) }
            let frames = buttons.map { $0.convert($0.bounds, to: chrome) }
            for frame in frames {
                #expect(frame.width >= 43.5 && frame.height >= 43.5)
                #expect(chrome.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame))
            }
            for pair in zip(
                frames.sorted(by: { $0.minX < $1.minX }),
                frames.sorted(by: { $0.minX < $1.minX }).dropFirst(),
            ) {
                #expect(pair.0.maxX <= pair.1.minX + 0.5)
            }

            let saved = try f.durableState()
            page.focusAddress()
            try #require(page.addressField.isFirstResponder)
            page.addressField.text = "https://must-not-submit.example/draft"
            let pageCommands: [UIKeyCommand] = page.keyCommands ?? []
            let commandFlags = UIKeyModifierFlags.command
            let findCommand: UIKeyCommand? = pageCommands.first {
                $0.input == "f" && $0.modifierFlags == commandFlags
            }
            let command = try #require(findCommand)
            let findAction = try #require(command.action)
            #expect(command.wantsPriorityOverSystemBehavior)
            #expect(UIApplication.shared.sendAction(findAction, to: nil, from: command, for: nil))
            try #require(await mobileFindEventually { webView.findInteraction?.isFindNavigatorVisible == true })
            #expect(!page.addressField.isFirstResponder)
            #expect(try f.durableState() == saved)
            let interaction = try #require(webView.findInteraction)
            let escapeCommand: UIKeyCommand? = pageCommands.first { $0.input == UIKeyCommand.inputEscape }
            let escape = try #require(escapeCommand)
            let escapeAction = try #require(escape.action)
            #expect(UIApplication.shared.sendAction(escapeAction, to: nil, from: escape, for: nil))
            try #require(await mobileFindEventually { !interaction.isFindNavigatorVisible })
            #expect(!webView.isFindInteractionEnabled)
            #expect(try f.durableState() == saved)

            // After a sidebar drag, focus can remain in the split's primary
            // sibling. The root command must reach the selected page through
            // UIKit's responder chain, without targeting the page explicitly.
            f.resize(width: 1024, height: 768, horizontal: .regular)
            try #require(f.root.tabsController.becomeFirstResponder())
            try #require(f.root.tabsController.isFirstResponder)
            let rootCommands: [UIKeyCommand] = f.root.keyCommands ?? []
            let rootFindCommand: UIKeyCommand? = rootCommands.first {
                $0.input == "f" && $0.modifierFlags == commandFlags
            }
            let rootCommand = try #require(rootFindCommand)
            let rootFindAction = try #require(rootCommand.action)
            #expect(UIApplication.shared.sendAction(rootFindAction, to: nil, from: rootCommand, for: nil))
            try #require(await mobileFindEventually { webView.findInteraction?.isFindNavigatorVisible == true })
            try #require(await mobileFindEventually { webView.findInteraction?.activeFindSession != nil })
            let siblingSession = try #require(webView.findInteraction?.activeFindSession)
            siblingSession.performSearch(query: "needle", options: nil)
            try #require(await mobileFindEventually { siblingSession.resultCount == 3 })
            #expect(try f.durableState() == saved)
        }
    }

    @Test func findSelectionAndNavigationDoNotOpenOrMutateIndependentWindow() async throws {
        try await withMobileFindFixture { f in
            try await withMobileFindFixture { other in
                try await f.start()
                let first = try await f.load()
                f.workspace.selectTab(id: "b")
                let second = try await f.load(tabID: "b", title: "Second", body: "second document")
                f.workspace.selectTab(id: "a")
                try await other.start()
                let independent = try await other.load(title: "Independent", body: "independent document")
                let otherSaved = try other.durableState()
                let otherRuntime = other.workspace.selectedTab?.runtimeID
                f.window.makeKeyAndVisible()

                let saved = try f.durableState()
                let interaction = try await f.openUsingButton()
                #expect(independent.findInteraction?.isFindNavigatorVisible != true)
                f.workspace.selectTab(id: "b")
                try #require(await mobileFindEventually { !interaction.isFindNavigatorVisible })
                #expect(!first.isFindInteractionEnabled && first.findInteraction == nil)
                #expect(try f.engine.webView(for: #require(f.workspace.selectedTab?.runtimeID)) === second)
                #expect(other.workspace.selectedTab?.runtimeID == otherRuntime)
                #expect(try f.durableState() == saved)
                #expect(try other.durableState() == otherSaved)

                f.workspace.selectTab(id: "a")
                let reopened = try await f.openUsingButton()
                let runtimeID = try #require(f.workspace.selectedTab?.runtimeID)
                f.engine.loadHTMLString(
                    "<title>Replacement</title><p>new document</p>",
                    baseURL: URL(string: "https://find.example/replacement"), id: runtimeID,
                )
                #expect(!f.workspace.canFindInPage)
                #expect(!f.workspace.presentFindInPage())
                try #require(await mobileFindEventually { !reopened.isFindNavigatorVisible })
                #expect(!first.isFindInteractionEnabled)
                try #require(await mobileFindEventually {
                    f.workspace.selectedTab?.title == "Replacement" && f.workspace.selectedTab?.state.isLoading == false
                })
                #expect(f.engine.webView(for: runtimeID) === first)
                #expect(try other.engine.webView(for: #require(otherRuntime)) === independent)
                #expect(try other.durableState() == otherSaved)
                #expect(independent.findInteraction?.isFindNavigatorVisible != true)
            }
        }
    }

    @Test func findRejectsUnloadedDetachedInactiveFailedAndMissingSelectedPages() async throws {
        try await withMobileFindFixture { f in
            #expect(!f.workspace.presentFindInPage())
            try await f.start()
            // A restored blank page has no searchable product document.
            #expect(!f.workspace.canFindInPage)
            #expect(!f.workspace.presentFindInPage())
            let webView = try await f.load()
            let interaction = try await f.openUsingButton()
            let saved = try f.durableState()
            f.workspace.setJavaScriptDialogPresentationActive(false)
            try #require(await mobileFindEventually { !interaction.isFindNavigatorVisible })
            #expect(!webView.isFindInteractionEnabled && webView.findInteraction == nil)
            #expect(!f.workspace.presentFindInPage())
            let inactiveButton = try #require(mobileFindView(
                "browser.findInPage",
                in: f.root.pageController.view,
            ) as? UIButton)
            #expect(!inactiveButton.isEnabled)
            #expect(try f.durableState() == saved)
            f.workspace.setJavaScriptDialogPresentationActive(true)
            let restoredButton = try #require(mobileFindView(
                "browser.findInPage",
                in: f.root.pageController.view,
            ) as? UIButton)
            #expect(restoredButton.isEnabled)

            let selectedRuntime = try #require(f.workspace.selectedTab?.runtimeID)
            f.engine.selectTab(id: nil)
            #expect(!f.workspace.presentFindInPage())
            f.engine.selectTab(id: selectedRuntime)
            let beforeFailure = try await f.openUsingButton()
            f.engine.webViewWebContentProcessDidTerminate(webView)
            try #require(await mobileFindEventually { !beforeFailure.isFindNavigatorVisible })
            #expect(!webView.isFindInteractionEnabled && webView.findInteraction == nil)
            #expect(!f.workspace.canFindInPage && !f.workspace.presentFindInPage())
            #expect(try f.durableState() == saved)

            _ = try await f.load()
            let beforeClose = try await f.openUsingButton()
            #expect(f.document.removeTab(id: "a"))
            try #require(await mobileFindEventually { !beforeClose.isFindNavigatorVisible })
            #expect(f.document.removeTab(id: "b"))
            #expect(f.workspace.selectedTab == nil)
            #expect(!f.workspace.presentFindInPage())
            let button = try #require(mobileFindView("browser.findInPage", in: f.root.pageController.view) as? UIButton)
            #expect(!button.isEnabled)
        }
    }

    @Test func actualJavaScriptDialogDismissesFindBeforeNativeAlertAndPreservesResponse() async throws {
        try await withMobileFindFixture { f in
            try await f.start()
            let webView = try await f.load()
            let saved = try f.durableState()
            let interaction = try await f.openUsingButton()
            let result = MobileFindScriptResult()
            let evaluation = Task { @MainActor in
                do {
                    let response = try await webView.evaluateJavaScript("confirm('Find dialog boundary')") as? Bool
                    result.value = .success(response)
                } catch {
                    result.value = .failure(error)
                }
            }
            defer { evaluation.cancel() }
            try #require(await mobileFindEventually { f.workspace.javaScriptDialog != nil })
            try #require(await mobileFindEventually { !interaction.isFindNavigatorVisible })
            #expect(!webView.isFindInteractionEnabled && webView.findInteraction == nil)
            #expect(!f.workspace.presentFindInPage())
            let dialog = try #require(f.workspace.javaScriptDialog)
            try #require(await mobileFindEventually { f.root.presentedViewController is UIAlertController })
            f.workspace.resolveJavaScriptDialog(id: dialog.id, response: .cancel)
            try #require(await mobileFindEventually { result.value != nil })
            let response = try #require(result.value).get()
            #expect(response == false)
            #expect(try f.durableState() == saved)
        }
    }
}

// MARK: - MobileFindScriptResult

@MainActor private final class MobileFindScriptResult {
    var value: Result<Bool?, Error>?
}

// MARK: - MobileFindFixture

@MainActor private final class MobileFindFixture {
    // MARK: Internal

    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "find-owner")
    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument
    let preferencesName = "MobileFind." + UUID().uuidString
    let preferences: UserDefaults
    let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
    let workspace: BrowserMobileWorkspace
    let root: BrowserMobileViewController
    let window: UIWindow

    init(directory: URL) throws {
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [.init(id: "space", title: "Space", systemImageName: "globe")],
            tabs: [
                .init(id: "a", urlString: "about:blank", spaceID: "space"),
                .init(id: "b", urlString: "about:blank", spaceID: "space"),
            ],
        )
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        try store.bindSyncOwner(owner)
        self.document = try BrowserMobileProfileDocument(store: store, initialSnapshot: store.loadSnapshotStrict())
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        let document = document
        self.workspace = BrowserMobileWorkspace(
            engine: engine, sceneID: UUID().uuidString, profileLoader: { document }, preferences: preferences,
        )
        self.root = BrowserMobileViewController(workspace: workspace, contentView: engine.hostView)
        self.window = try UIWindow(windowScene: #require(BrowserMobileTestScene.windowScene))
    }

    func start() async throws {
        await workspace.restore()
        try #require(workspace.isReady)
        workspace.setJavaScriptDialogPresentationActive(true)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.loadViewIfNeeded()
        resize(width: 390, height: 844)
        workspace.selectTab(id: "a")
    }

    func resize(width: CGFloat, height: CGFloat, horizontal: UIUserInterfaceSizeClass = .compact) {
        root.traitOverrides.horizontalSizeClass = horizontal
        root.traitOverrides.verticalSizeClass = .regular
        root.pageController.traitOverrides.horizontalSizeClass = horizontal
        root.pageController.traitOverrides.verticalSizeClass = .regular
        window.frame.size = CGSize(width: width, height: height)
        root.view.frame = window.bounds
        root.view.setNeedsLayout()
        root.view.layoutIfNeeded()
        root.pageController.view.layoutIfNeeded()
    }

    func load(
        tabID: String = "a", title: String = "Find fixture",
        body: String = "<p>needle first</p><p>needle second</p><p>needle third</p>",
    ) async throws -> WKWebView {
        workspace.selectTab(id: tabID)
        let runtimeID = try #require(workspace.selectedTab?.runtimeID)
        engine.loadHTMLString(
            "<meta name='viewport' content='width=device-width'><title>\(title)</title><main>\(body)</main>",
            baseURL: URL(string: "https://find.example/\(tabID)"), id: runtimeID,
        )
        try #require(await mobileFindEventually {
            self.workspace.selectedTab?.title == title && self.workspace.selectedTab?.state.isLoading == false
        })
        root.render()
        root.view.layoutIfNeeded()
        root.pageController.view.layoutIfNeeded()
        let view = try #require(engine.webView(for: runtimeID))
        try #require(view.window === window && !engine.hostView.isHidden)
        return view
    }

    func openUsingButton() async throws -> UIFindInteraction {
        let runtimeID = try #require(workspace.selectedTab?.runtimeID)
        let view = try #require(engine.webView(for: runtimeID))
        let button = try #require(mobileFindView("browser.findInPage", in: root.pageController.view) as? UIButton)
        try #require(button.isEnabled)
        button.sendActions(for: .touchUpInside)
        try #require(await mobileFindEventually { view.findInteraction?.isFindNavigatorVisible == true })
        let interaction = try #require(view.findInteraction)
        try #require(await mobileFindEventually { interaction.activeFindSession != nil })
        return interaction
    }

    func durableState() throws -> (BrowserTabSessionSnapshot?, [BrowserSyncQueuedMutation]) {
        try (store.loadSnapshotStrict(), store.pendingSyncQueue(for: owner))
    }

    func close() {
        engine.shutdown()
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        preferences.removePersistentDomain(forName: preferencesName)
    }
}

/// The inner async frame releases the profile/store before the outer scope
/// removes its SQLite files; never unlink an open database during UIKit cleanup.
@MainActor private func withMobileFindFixture(_ body: (MobileFindFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileFind-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runMobileFindFixture(directory: directory, body)
}

@MainActor private func runMobileFindFixture(
    directory: URL, _ body: (MobileFindFixture) async throws -> Void,
) async throws {
    let fixture = try MobileFindFixture(directory: directory)
    defer { fixture.close() }
    do {
        try await body(fixture)
    } catch {
        _ = await fixture.workspace.shutdown()
        throw error
    }
    #expect(await fixture.workspace.shutdown())
}

@MainActor private func mobileFindEventually(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor private func mobileFindView(_ id: String, in view: UIView) -> UIView? {
    if view.accessibilityIdentifier == id {
        return view
    }
    return view.subviews.lazy.compactMap { mobileFindView(id, in: $0) }.first
}

@MainActor @Test func thePhoneAddressFieldShowsTheSiteAndEditsTheWholeAddress() {
    #expect(BrowserMobilePageViewController.displayAddress("https://www.example.com/a?b=1") == "example.com")
    #expect(BrowserMobilePageViewController.displayAddress("http://example.org/") == "example.org")
    #expect(BrowserMobilePageViewController.displayAddress("about:blank") == "")
    #expect(BrowserMobilePageViewController.displayAddress(nil) == "")
    #expect(BrowserMobilePageViewController.displayAddress("file:///tmp/a.html") == "file:///tmp/a.html")
}
