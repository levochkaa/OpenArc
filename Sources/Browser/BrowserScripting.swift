// BrowserScripting.swift

import AppKit
import Foundation

// MARK: - BrowserScriptWindow

/// A browser window as AppleScript sees it. `make new window` creates one
/// empty and the controller fills it in when it inserts it.
@MainActor @objc(BrowserScriptWindow) final class BrowserScriptWindow: NSObject {
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let scriptID, let application = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: application,
            containerSpecifier: nil,
            key: "appleScriptWindows",
            uniqueID: scriptID,
        )
    }

    // MARK: Internal

    @objc var mode = "normal"

    private(set) var window: NSWindow?
    private(set) var model: BrowserChromeModel?

    /// Apple events arrive on the main thread, but the specifier's override is not isolated.
    private nonisolated(unsafe) var scriptID: String?

    @objc var id: String { window.map { String($0.windowNumber) } ?? "" }
    @objc var uniqueID: String { id }
    @objc var title: String { window?.title ?? "" }
    @objc var orderedIndex: Int {
        get { (NSApp.orderedWindows.firstIndex { $0 === window } ?? 0) + 1 }
        set {
            guard newValue == 1 else { return }
            window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc var hasCloseBox: Bool { window?.styleMask.contains(.closable) ?? false }
    @objc var isMiniaturizable: Bool { window?.styleMask.contains(.miniaturizable) ?? false }
    @objc var isResizable: Bool { window?.styleMask.contains(.resizable) ?? false }
    @objc var isZoomable: Bool { window?.isZoomable ?? false }
    @objc var isMiniaturized: Bool {
        get { window?.isMiniaturized ?? false }
        set { newValue ? window?.miniaturize(nil) : window?.deminiaturize(nil) }
    }

    @objc var isVisible: Bool {
        get { window?.isVisible ?? false }
        set { newValue ? window?.orderFront(nil) : window?.orderOut(nil) }
    }

    @objc var isZoomed: Bool {
        get { window?.isZoomed ?? false }
        set { if newValue != isZoomed { window?.zoom(nil) } }
    }

    @objc var isIncognito: Bool {
        get { model?.isIncognito ?? (mode == "incognito") }
        set { if window == nil { mode = newValue ? "incognito" : "normal" } }
    }

    @objc var activeTab: BrowserScriptTab? {
        guard let model, let tab = model.currentTab else { return nil }
        return BrowserScriptTab(window: self, model: model, tabID: tab.id)
    }

    @objc var activeSpace: BrowserScriptSpace? {
        guard let model, let spaceID = model.selectedSpaceID else { return nil }
        return BrowserScriptSpace(window: self, model: model, spaceID: spaceID)
    }

    @objc var appleScriptTabs: [BrowserScriptTab] {
        guard let model else { return [] }
        return model.tabs.map { BrowserScriptTab(window: self, model: model, tabID: $0.id) }
    }

    @objc var appleScriptSpaces: [BrowserScriptSpace] {
        guard let model else { return [] }
        return model.spaces.map { BrowserScriptSpace(window: self, model: model, spaceID: $0.id) }
    }

    override init() {
        super.init()
    }

    init(window: NSWindow, model: BrowserChromeModel) {
        self.window = window
        self.model = model
        self.scriptID = String(window.windowNumber)
        super.init()
    }

    func attach(window: NSWindow, model: BrowserChromeModel) {
        self.window = window
        self.model = model
        scriptID = String(window.windowNumber)
    }

    @objc(insertInAppleScriptTabs:) func insertInAppleScriptTabs(_ tab: BrowserScriptTab) {
        guard let model else { return }
        tab.open(window: self, model: model)
    }

    @objc(insertObject:inAppleScriptTabsAtIndex:) func insertObject(
        _ tab: BrowserScriptTab,
        inAppleScriptTabsAt _: Int,
    ) {
        insertInAppleScriptTabs(tab)
    }

    @objc(close:) func close(_: NSScriptCommand) -> Any? {
        window?.performClose(nil)
        return nil
    }
}

// MARK: - BrowserScriptSpace

@MainActor @objc(BrowserScriptSpace) final class BrowserScriptSpace: NSObject {
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let container = window.objectSpecifier,
              let description = container.keyClassDescription else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: description,
            containerSpecifier: container,
            key: "appleScriptSpaces",
            uniqueID: spaceID,
        )
    }

    // MARK: Internal

    private let window: BrowserScriptWindow
    private let model: BrowserChromeModel
    private let spaceID: String
    private nonisolated let scriptID: String
    private nonisolated(unsafe) let containerSpecifier: NSScriptObjectSpecifier?

    @objc var id: String { spaceID }
    @objc var uniqueID: String { spaceID }
    @objc var title: String { model.spaces.first { $0.id == spaceID }?.title ?? "" }

    @objc var appleScriptTabs: [BrowserScriptTab] {
        model.tabs.filter { $0.spaceID == spaceID }.map { BrowserScriptTab(window: window, model: model, tabID: $0.id) }
    }

    init(window: BrowserScriptWindow, model: BrowserChromeModel, spaceID: String) {
        self.window = window
        self.model = model
        self.spaceID = spaceID
        self.scriptID = spaceID
        self.containerSpecifier = window.objectSpecifier
        super.init()
    }

    @objc(insertInAppleScriptTabs:) func insertInAppleScriptTabs(_ tab: BrowserScriptTab) {
        tab.open(window: window, model: model, spaceID: spaceID)
    }

    @objc(insertObject:inAppleScriptTabsAtIndex:) func insertObject(
        _ tab: BrowserScriptTab,
        inAppleScriptTabsAt _: Int,
    ) {
        insertInAppleScriptTabs(tab)
    }

    @objc(focus:) func focus(_: NSScriptCommand) -> Any? {
        model.selectSpace(id: spaceID)
        return nil
    }
}

// MARK: - BrowserScriptTab

/// A tab as AppleScript sees it. `make new tab` creates one with only a URL;
/// its container opens the page and fills in the rest.
@MainActor @objc(BrowserScriptTab) final class BrowserScriptTab: NSObject {
    // MARK: Internal

    static let javaScriptTurnedOffMessage = BrowserStrings.scriptJavaScriptTurnedOff

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let containerSpecifier, let scriptID, let description = containerSpecifier.keyClassDescription else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: description,
            containerSpecifier: containerSpecifier,
            key: "appleScriptTabs",
            uniqueID: scriptID,
        )
    }

    private(set) var pendingURLString: String?

    private var window: BrowserScriptWindow?
    private var model: BrowserChromeModel?
    private var tabID: String? {
        didSet { scriptID = tabID }
    }

    private nonisolated(unsafe) var scriptID: String?
    private nonisolated(unsafe) var containerSpecifier: NSScriptObjectSpecifier?

    @objc var id: String { tabID ?? "" }
    @objc var uniqueID: String { id }
    @objc var title: String { tab?.displayTitle ?? "" }
    @objc var loading: Bool { tab?.isLoading ?? false }

    @objc var URL: String {
        get { tab?.urlString ?? pendingURLString ?? "" }
        set {
            guard let model, let tabID else {
                pendingURLString = newValue
                return
            }
            model.navigateTab(id: tabID, toURLString: newValue)
        }
    }

    @objc var location: String {
        get {
            switch tab?.placement {
            case .app: "topApp"
            case .spacePinned: "pinned"
            case nil, .temporary: "unpinned"
            }
        }
        set {
            guard let model, let tabID, let tab, tab.placement != .app else { return }
            if (newValue == "pinned") != (tab.placement == .spacePinned) {
                model.togglePinned(forTabID: tabID)
            }
        }
    }

    private var tab: BrowserChromeModel.Tab? {
        guard let model, let tabID else { return nil }
        return model.tabs.first { $0.id == tabID }
    }

    override init() {
        super.init()
    }

    init(window: BrowserScriptWindow, model: BrowserChromeModel, tabID: String) {
        self.window = window
        self.model = model
        self.tabID = tabID
        self.scriptID = tabID
        self.containerSpecifier = window.objectSpecifier
        super.init()
    }

    /// Opens the page of a tab made by `make new tab`.
    func open(window: BrowserScriptWindow, model: BrowserChromeModel, spaceID: String? = nil) {
        let url = pendingURLString.flatMap { Foundation.URL(string: $0) }
        if let url {
            if let spaceID {
                model.openURL(url, inSpaceWithID: spaceID)
            } else {
                model.openURLInNewTab(url)
            }
        } else {
            model.createNewTab()
        }
        self.window = window
        self.model = model
        containerSpecifier = window.objectSpecifier
        tabID = model.selectedTabID
        pendingURLString = nil
    }

    @objc(select:) func select(_: NSScriptCommand) -> Any? {
        selectTab()
        return nil
    }

    @objc(goBack:) func goBack(_: NSScriptCommand) -> Any? {
        selectTab()
        model?.goBack()
        return nil
    }

    @objc(goForward:) func goForward(_: NSScriptCommand) -> Any? {
        selectTab()
        model?.goForward()
        return nil
    }

    @objc(reload:) func reload(_: NSScriptCommand) -> Any? {
        selectTab()
        model?.reloadCurrentTab()
        return nil
    }

    @objc(stopLoading:) func stopLoading(_: NSScriptCommand) -> Any? {
        selectTab()
        model?.stopLoadingCurrentTab()
        return nil
    }

    @objc(close:) func close(_: NSScriptCommand) -> Any? {
        if let tabID {
            model?.closeTab(id: tabID)
        }
        return nil
    }

    /// Answers with the expression's value once the page has it.
    @objc(executeJavascript:) func executeJavascript(_ command: NSScriptCommand) -> Any? {
        guard let model, let tabID, let code = command.evaluatedArguments?["javascript"] as? String else {
            return nil
        }
        guard model.userPreferencesStore.allowsJavaScriptFromAppleEvents else {
            command.scriptErrorNumber = errAEEventNotPermitted
            command.scriptErrorString = Self.javaScriptTurnedOffMessage
            return nil
        }
        command.suspendExecution()
        model.evaluateJavaScript(code, inTabWithID: tabID) { value in
            command.resumeExecution(withResult: value ?? "")
        }
        return nil
    }

    private func selectTab() {
        if let tabID {
            model?.selectTab(id: tabID)
        }
    }
}

// MARK: - errAEEventNotPermitted

private let errAEEventNotPermitted = -1743
