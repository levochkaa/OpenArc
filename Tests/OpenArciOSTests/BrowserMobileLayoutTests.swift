// BrowserMobileLayoutTests.swift

import BrowserMobileTestHost
import Foundation
import Testing
import UIKit

// MARK: - BrowserMobileUITests

@MainActor @Suite(.serialized) struct BrowserMobileUITests {
    @Test func splitPageResizesChromeAndMountedContentInsideSafeArea() async throws {
        let engine = MobileLayoutEngine()
        let workspace = BrowserMobileWorkspace(engine: engine, store: MobileLayoutStore())
        await workspace.restore()
        workspace.submit("https://example.com/loaded")
        let selectedID = workspace.selectedTabID
        let runtimeID = try #require(workspace.selectedTab?.runtimeID)
        let root = BrowserMobileViewController(workspace: workspace, contentView: engine.hostView)
        let host = try MobileLayoutHost(controller: root)
        defer { host.close() }
        root.pageController.additionalSafeAreaInsets = UIEdgeInsets(top: 13, left: 7, bottom: 11, right: 5)

        let sizes: [(CGSize, UIUserInterfaceSizeClass, UIUserInterfaceSizeClass, Bool)] = [
            (.init(width: 390, height: 844), .compact, .regular, true),
            (.init(width: 1024, height: 768), .regular, .regular, false),
            (.init(width: 600, height: 700), .compact, .regular, true),
            (.init(width: 844, height: 390), .compact, .compact, false),
        ]
        for (size, horizontal, vertical, bottom) in sizes {
            host.resize(size, horizontal: horizontal, vertical: vertical)
            let page = root.pageController
            // Override the actual page as well: split-view column traits may
            // differ from the window's traits while a collapse is in progress.
            page.traitOverrides.horizontalSizeClass = horizontal
            page.traitOverrides.verticalSizeClass = vertical
            page.view.layoutIfNeeded()
            let chrome = try #require(page.view.mobileView(withID: "browser.chrome"))
            let safe = page.view.safeAreaLayoutGuide.layoutFrame
            let contentFrame = engine.hostView.convert(engine.hostView.bounds, to: page.view)
            let chromeFrame = chrome.convert(chrome.bounds, to: page.view)
            #expect(page.chromeIsAtBottom == bottom)
            #expect(engine.hostView.isDescendant(of: page.view))
            #expect(engine.loadedSurface.isDescendant(of: engine.hostView))
            #expect(contentFrame.width > 0 && contentFrame.height > 0)
            #expect(safe.insetBy(dx: -0.5, dy: -0.5).contains(contentFrame))
            #expect(safe.insetBy(dx: -0.5, dy: -0.5).contains(chromeFrame))
            #expect(abs(contentFrame.width - safe.width) < 0.5)
            #expect(page.addressField.bounds.height >= 44)
            if bottom {
                #expect(contentFrame.maxY <= chromeFrame.minY + 0.5)
            } else {
                #expect(chromeFrame.maxY <= contentFrame.minY + 0.5)
            }
            #expect(workspace.selectedTabID == selectedID)
            #expect(engine.selectedID == runtimeID)
        }
        #expect(root.viewController(for: .primary) is UINavigationController)
        #expect(root.splitViewController(root, topColumnForCollapsingToProposedTopColumn: .primary) == .secondary)
        host.close()
        #expect(await workspace.shutdown())
    }

    @Test func addressEditingSurvivesPageStateAndReturnSubmitsThroughRealController() async throws {
        let engine = MobileLayoutEngine()
        let workspace = BrowserMobileWorkspace(engine: engine, store: MobileLayoutStore())
        await workspace.restore()
        workspace.submit("https://example.com/original")
        let tab = try #require(workspace.selectedTab)
        let root = BrowserMobileViewController(workspace: workspace, contentView: engine.hostView)
        let host = try MobileLayoutHost(controller: root)
        defer { host.close() }
        host.resize(.init(width: 390, height: 844), horizontal: .compact, vertical: .regular)
        let page = root.pageController
        page.focusAddress()
        try #require(page.addressField.isFirstResponder)
        page.addressField.text = "example.com/from-address"
        engine.onEvent?(.state(id: tab.runtimeID, .init(
            url: URL(string: tab.urlString), title: "Updated page title", isLoading: true,
            progress: 0.6, canGoBack: true,
        )))
        #expect(page.addressField.text == "example.com/from-address")
        #expect(workspace.selectedTab?.title == "Updated page title")
        let back = try #require(page.view.mobileView(withID: "browser.back") as? UIButton)
        #expect(back.isEnabled)
        back.sendActions(for: .touchUpInside)
        #expect(engine.commands.last == "back:\(tab.runtimeID)")

        #expect(page.textFieldShouldReturn(page.addressField))
        #expect(!page.addressField.isFirstResponder)
        #expect(engine.navigations.last?.0 == tab.runtimeID)
        #expect(engine.navigations.last?.1.absoluteString == "https://example.com/from-address")
        #expect(workspace.selectedTab?.urlString == "https://example.com/from-address")
        #expect(page.addressField.text == "https://example.com/from-address")
        let reload = try #require(page.view.mobileView(withID: "browser.reload") as? UIButton)
        reload.sendActions(for: .touchUpInside)
        #expect(engine.commands.last == "stop:\(tab.runtimeID)")
        let reloadCommand = try #require(page.keyCommands?.first { $0.input == "r" && $0.modifierFlags == .command })
        let reloadAction = try #require(reloadCommand.action)
        #expect(UIApplication.shared.sendAction(reloadAction, to: page, from: reloadCommand, for: nil))
        #expect(engine.commands.last == "reload:\(tab.runtimeID)", "Cmd+R reloads even while loading")
        host.close()
        #expect(await workspace.shutdown())
    }

    @Test(arguments: [false, true])
    func addressDraftBelongsToSelectedTabAcrossNewTabAndSidebarSwitch(keyboardShortcut: Bool) async throws {
        let engine = MobileLayoutEngine()
        let workspace = BrowserMobileWorkspace(engine: engine, store: MobileLayoutStore())
        await workspace.restore()
        workspace.submit("https://example.com/original")
        let original = try #require(workspace.selectedTab)
        let root = BrowserMobileViewController(workspace: workspace, contentView: engine.hostView)
        let host = try MobileLayoutHost(controller: root)
        defer { host.close() }
        host.resize(.init(width: 1024, height: 768), horizontal: .regular, vertical: .regular)
        let page = root.pageController
        page.focusAddress()
        try #require(page.addressField.isFirstResponder)
        page.addressField.text = "unfinished query for original tab"
        engine.onEvent?(.state(id: original.runtimeID, .init(url: URL(string: original.urlString), progress: 0.3)))
        #expect(page.addressField.text == "unfinished query for original tab")

        if keyboardShortcut {
            let command = try #require(page.keyCommands?.first { $0.input == "t" && $0.modifierFlags == .command })
            let action = try #require(command.action)
            #expect(UIApplication.shared.sendAction(action, to: page, from: command, for: nil))
        } else {
            let newTab = try #require(page.view.mobileView(withID: "browser.newTab") as? UIButton)
            newTab.sendActions(for: .touchUpInside)
        }
        let created = try #require(workspace.selectedTab)
        #expect(created.id != original.id && created.urlString == "about:blank")
        #expect(page.addressField.isFirstResponder)
        #expect(page.addressField.text == "")
        page.addressField.text = "unfinished query for new tab"
        engine.onEvent?(.state(id: created.runtimeID, .init(url: URL(string: "about:blank"), progress: 0.5)))
        #expect(page.addressField.text == "unfinished query for new tab")

        let sidebar = root.tabsController
        sidebar.loadViewIfNeeded()
        let table = try #require(sidebar.tableView)
        sidebar.tableView(table, didSelectRowAt: .init(row: 0, section: 0))
        #expect(workspace.selectedTabID == original.id)
        #expect(!page.addressField.isFirstResponder)
        #expect(page.addressField.text == original.urlString)
        page.focusAddress()
        try #require(page.addressField.isFirstResponder)
        page.addressField.text = "revised draft for original tab"
        engine.onEvent?(.state(id: original.runtimeID, .init(url: URL(string: original.urlString), progress: 0.8)))
        #expect(page.addressField.text == "revised draft for original tab")
        #expect(engine.navigations.map(\.1.absoluteString) == [original.urlString], "Drafts never navigate implicitly")
        host.close()
        #expect(await workspace.shutdown())
    }

    @Test func sidebarSelectionAndDeferredCloseUseStableTabIdentity() async throws {
        let engine = MobileLayoutEngine()
        let workspace = BrowserMobileWorkspace(engine: engine, store: MobileLayoutStore())
        await workspace.restore()
        workspace.submit("https://example.com/first")
        workspace.newTab()
        workspace.submit("https://example.com/second")
        workspace.newTab()
        workspace.submit("https://example.com/third")
        let original = workspace.tabs
        let root = BrowserMobileViewController(workspace: workspace, contentView: engine.hostView)
        let host = try MobileLayoutHost(controller: root)
        defer { host.close() }
        host.resize(.init(width: 1024, height: 768), horizontal: .regular, vertical: .regular)
        let sidebar = root.tabsController
        sidebar.loadViewIfNeeded()
        let table = try #require(sidebar.tableView)
        sidebar.tableView(table, didSelectRowAt: .init(row: 1, section: 0))
        #expect(workspace.selectedTabID == original[1].id)
        #expect(engine.selectedID == original[1].runtimeID)
        let selectedCell = sidebar.tableView(table, cellForRowAt: .init(row: 1, section: 0))
        #expect(selectedCell.accessoryType == .checkmark)
        #expect(selectedCell.accessibilityTraits.contains(.selected))
        #expect(selectedCell.accessibilityIdentifier == "browser.tab." + original[1].id)
        let configuration = try #require(sidebar.tableView(
            table, trailingSwipeActionsConfigurationForRowAt: .init(row: 1, section: 0),
        ))
        let close = try #require(configuration.actions.first)
        workspace.closeTab(id: original[0].id)
        #expect(workspace.tabs.map(\.id) == [original[1].id, original[2].id])
        var completed = false
        close.handler(close, selectedCell) { completed = $0 }
        #expect(completed)
        #expect(workspace.tabs.map(\.id) == [original[2].id])
        #expect(workspace.selectedTabID == original[2].id)
        #expect(engine.closedIDs == [original[0].runtimeID, original[1].runtimeID])
        #expect(sidebar.tableView(table, numberOfRowsInSection: 0) == 1)
        host.close()
        #expect(await workspace.shutdown())
    }
}

// MARK: - MobileLayoutHost

@MainActor private final class MobileLayoutHost {
    // MARK: Internal

    let window: UIWindow
    let controller: UIViewController

    init(controller: UIViewController) throws {
        let scene = try #require(
            BrowserMobileTestScene.windowScene,
            "UIKit interaction coverage requires a connected test-runner window scene",
        )
        self.controller = controller
        self.window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        window.makeKeyAndVisible()
    }

    func resize(_ size: CGSize, horizontal: UIUserInterfaceSizeClass, vertical: UIUserInterfaceSizeClass) {
        controller.traitOverrides.horizontalSizeClass = horizontal
        controller.traitOverrides.verticalSizeClass = vertical
        window.frame.size = size
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        if let split = controller as? BrowserMobileViewController {
            split.pageController.loadViewIfNeeded()
            split.pageController.view.layoutIfNeeded()
        }
    }

    func close() {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }
}

// MARK: - MobileLayoutEngine

@MainActor private final class MobileLayoutEngine: BrowserMobileEngine {
    // MARK: Internal

    let hostView = UIView()
    let loadedSurface = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    var selectedID: String?
    var navigations = [(String, URL)]()
    var commands = [String]()
    var closedIDs = [String]()

    init() {
        loadedSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        loadedSurface.frame = hostView.bounds
        hostView.addSubview(loadedSurface)
    }

    func createTab(id: String, url: URL) { onEvent?(.state(id: id, .init(url: url))) }
    func selectTab(id: String?) { selectedID = id }
    func navigate(id: String, url: URL) {
        navigations.append((id, url))
        onEvent?(.state(id: id, .init(url: url, isLoading: true)))
    }

    func goBack(id: String) { commands.append("back:\(id)") }
    func goForward(id: String) { commands.append("forward:\(id)") }
    func reload(id: String) { commands.append("reload:\(id)") }
    func stop(id: String) { commands.append("stop:\(id)") }
    func closeTab(id: String) { closedIDs.append(id)
        onEvent?(.closed(id: id))
    }

    func shutdown() {}
    func setJavaScriptDialogPresentationActive(_: Bool) {}
    func resolveJavaScriptDialog(id: UUID, response _: BrowserMobileJavaScriptDialogResponse) {
        onEvent?(.javaScriptDialogFinished(id: id))
    }
}

// MARK: - MobileLayoutStore

private actor MobileLayoutStore: BrowserMobileSessionStoring {
    var session: BrowserMobileSession?

    func load() -> BrowserMobileSession? { session }
    func save(_ session: BrowserMobileSession) { self.session = session }
}

@MainActor private extension UIView {
    func mobileView(withID id: String) -> UIView? {
        if accessibilityIdentifier == id {
            return self
        }
        for child in subviews {
            if let match = child.mobileView(withID: id) {
                return match
            }
        }
        return nil
    }
}
