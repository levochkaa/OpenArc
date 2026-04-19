import AppKit
import Combine
import Foundation
import OSLog

private enum BrowserChromeCommandDiagnostics {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.levochkaa.TheBrowser",
        category: "Commands"
    )

    static func rect(_ rect: CGRect) -> String {
        String(
            format: "(x:%.1f y:%.1f w:%.1f h:%.1f)",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }
}

@MainActor
final class BrowserChromeModel: NSObject, ObservableObject {
    static let defaultSidebarWidth: CGFloat = 224
    static let minSidebarWidth: CGFloat = defaultSidebarWidth
    static let maxSidebarWidth: CGFloat = defaultSidebarWidth * 2

    struct Tab: Identifiable, Equatable {
        let id: String
        var title: String
        var urlString: String
        var faviconURLString: String?
        var canGoBack = false
        var canGoForward = false

        var displayTitle: String {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                return trimmedTitle
            }

            if
                let url = URL(string: urlString),
                let host = url.host,
                !host.isEmpty
            {
                return host
            }

            return "New Tab"
        }

        var faviconURL: URL? {
            if
                let faviconURLString,
                let faviconURL = URL(string: faviconURLString)
            {
                return faviconURL
            }

            guard
                !urlString.isEmpty,
                let encodedURL = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            else {
                return nil
            }

            return URL(string: "https://www.google.com/s2/favicons?sz=64&domain_url=\(encodedURL)")
        }
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedTabID: String?
    @Published var isSidebarVisible = true
    @Published private(set) var sidebarWidth = BrowserChromeModel.defaultSidebarWidth

    let hostView: BrowserTabHostView

    private let tabController: BrowserTabController
    private let newTabURLString = "https://www.google.com"
    private let windowTitleHandler: (String) -> Void
    private let allTabsClosedHandler: () -> Void

    private var hasCreatedInitialTab = false
    private var closingTabIDs = Set<String>()
    private(set) var isContextReady = false
    var isShuttingDown = false

    var canCreateTab: Bool {
        isContextReady && !isShuttingDown
    }

    var canReload: Bool {
        canCreateTab && selectedTabID != nil
    }

    var canSavePage: Bool {
        canCreateTab && selectedTabID != nil
    }

    var canGoBack: Bool {
        selectedTab?.canGoBack ?? false
    }

    var canGoForward: Bool {
        selectedTab?.canGoForward ?? false
    }

    var hasTabs: Bool {
        !tabs.isEmpty
    }

    init(
        windowTitleHandler: @escaping (String) -> Void,
        allTabsClosedHandler: @escaping () -> Void
    ) {
        self.windowTitleHandler = windowTitleHandler
        self.allTabsClosedHandler = allTabsClosedHandler

        let hostView = BrowserTabHostView(frame: .zero)
        self.hostView = hostView
        tabController = BrowserTabController(hostView: hostView)

        super.init()
        tabController.delegate = self
        updateWindowTitle()
    }

    func handleContextReady() {
        guard !isContextReady else {
            return
        }

        isContextReady = true
        ensureInitialTab()
    }

    func createNewTab() {
        guard canCreateTab else {
            return
        }

        let tabID = tabController.createTab(withURLString: newTabURLString, makeActive: true)
        selectedTabID = tabID
        updateWindowTitle()
    }

    func reloadCurrentTab() {
        guard canReload else {
            return
        }

        tabController.reloadActiveTab()
    }

    func forceReloadCurrentTab() {
        guard canReload else {
            return
        }

        tabController.reloadActiveTabIgnoringCache()
    }

    func saveCurrentPage() {
        guard canSavePage, let selectedTab else {
            return
        }

        tabController.saveActiveTab(withSuggestedName: selectedTab.displayTitle)
    }

    func goBack() {
        guard canGoBack else {
            return
        }

        tabController.goBackActiveTab()
    }

    func goForward() {
        guard canGoForward else {
            return
        }

        tabController.goForwardActiveTab()
    }

    func closeAllTabs() {
        let openTabIDs = tabs.map(\.id)
        if isShuttingDown {
            closingTabIDs.formUnion(openTabIDs)
            for tabID in openTabIDs {
                tabController.closeTab(withID: tabID, forceClose: true)
            }
            return
        }

        for tabID in openTabIDs {
            closeTab(id: tabID)
        }
    }

    func selectTab(id: String) {
        guard
            selectedTabID != id,
            !closingTabIDs.contains(id),
            tabs.contains(where: { $0.id == id })
        else {
            return
        }

        selectedTabID = id
        tabController.selectTab(withID: id)
        updateWindowTitle()
    }

    func closeTab(id: String, forceClose: Bool = false) {
        guard
            let closingIndex = tabs.firstIndex(where: { $0.id == id }),
            !closingTabIDs.contains(id)
        else {
            return
        }

        closingTabIDs.insert(id)

        if tabs.count == 1, !isShuttingDown {
            let replacementID = tabController.createTab(withURLString: newTabURLString, makeActive: true)
            selectedTabID = replacementID
        } else if selectedTabID == id {
            let fallbackTabID = fallbackTabID(afterClosingIndex: closingIndex)
            selectedTabID = fallbackTabID
            if let fallbackTabID {
                tabController.selectTab(withID: fallbackTabID)
            }
        }

        tabs.removeAll { $0.id == id }
        tabController.closeTab(withID: id, forceClose: forceClose)
        updateWindowTitle()
    }

    func toggleSidebar() {
        let nextVisibility = !isSidebarVisible
        let message = String(
            format: "toggleSidebar current=%@ next=%@ width=%.1f hostFrame=%@ hostBounds=%@",
            String(isSidebarVisible),
            String(nextVisibility),
            sidebarWidth,
            BrowserChromeCommandDiagnostics.rect(hostView.frame),
            BrowserChromeCommandDiagnostics.rect(hostView.bounds)
        )
        BrowserChromeCommandDiagnostics.logger.notice(
            "\(message, privacy: .public)"
        )
        isSidebarVisible = nextVisibility
    }

    func setSidebarWidth(_ width: CGFloat) {
        let clampedWidth = min(max(width, Self.minSidebarWidth), Self.maxSidebarWidth)
        guard sidebarWidth != clampedWidth else {
            return
        }

        let message = String(
            format: "setSidebarWidth old=%.1f new=%.1f visible=%@ hostFrame=%@ hostBounds=%@",
            sidebarWidth,
            clampedWidth,
            String(isSidebarVisible),
            BrowserChromeCommandDiagnostics.rect(hostView.frame),
            BrowserChromeCommandDiagnostics.rect(hostView.bounds)
        )
        BrowserChromeCommandDiagnostics.logger.notice(
            "\(message, privacy: .public)"
        )
        sidebarWidth = clampedWidth
    }

    private func ensureInitialTab() {
        guard canCreateTab, !hasCreatedInitialTab else {
            return
        }

        hasCreatedInitialTab = true
        let tabID = tabController.createTab(withURLString: newTabURLString, makeActive: true)
        selectedTabID = tabID
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        let title = tabs.first(where: { $0.id == selectedTabID })?.displayTitle ?? "TheBrowser"
        windowTitleHandler(title)
    }

    private var selectedTab: Tab? {
        guard let selectedTabID else {
            return nil
        }

        return tabs.first(where: { $0.id == selectedTabID })
    }
}

extension BrowserChromeModel: BrowserTabControllerDelegate {
    nonisolated func browserTabController(
        _: BrowserTabController,
        didCreateTabWithID tabID: String,
        title: String,
        urlString: String
    ) {
        Task { @MainActor [weak self] in
            self?.handleCreatedTab(id: tabID, title: title, urlString: urlString)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateTabWithID tabID: String,
        title: String?,
        urlString: String?,
        faviconURLString: String?
    ) {
        Task { @MainActor [weak self] in
            self?.handleUpdatedTab(
                id: tabID,
                title: title,
                urlString: urlString,
                faviconURLString: faviconURLString
            )
        }
    }

    nonisolated func browserTabController(_: BrowserTabController, didCloseTabWithID tabID: String) {
        Task { @MainActor [weak self] in
            self?.handleClosedTab(id: tabID)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateNavigationStateForTabWithID tabID: String,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.handleNavigationStateChange(
                id: tabID,
                canGoBack: canGoBack,
                canGoForward: canGoForward
            )
        }
    }
}

@MainActor
private extension BrowserChromeModel {
    func fallbackTabID(afterClosingIndex closingIndex: Int) -> String? {
        let nextIndex = closingIndex + 1
        if tabs.indices.contains(nextIndex) {
            return tabs[nextIndex].id
        }

        let previousIndex = closingIndex - 1
        if tabs.indices.contains(previousIndex) {
            return tabs[previousIndex].id
        }

        return nil
    }

    func handleCreatedTab(id: String, title: String, urlString: String) {
        tabs.append(
            Tab(
                id: id,
                title: title,
                urlString: urlString,
                faviconURLString: nil
            )
        )

        if selectedTabID == nil {
            selectedTabID = id
        }

        updateWindowTitle()
    }

    func handleUpdatedTab(
        id: String,
        title: String?,
        urlString: String?,
        faviconURLString: String?
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        if let title {
            tabs[index].title = title
        }

        if let urlString {
            tabs[index].urlString = urlString
        }

        if let faviconURLString {
            tabs[index].faviconURLString = faviconURLString
        }

        updateWindowTitle()
    }

    func handleClosedTab(id: String) {
        closingTabIDs.remove(id)
        if tabs.contains(where: { $0.id == id }) {
            tabs.removeAll { $0.id == id }
        }

        if selectedTabID == id {
            selectedTabID = tabs.first?.id
            if let selectedTabID {
                tabController.selectTab(withID: selectedTabID)
            }
        }

        if tabs.isEmpty, selectedTabID == nil {
            selectedTabID = nil
            hasCreatedInitialTab = false

            if isShuttingDown {
                allTabsClosedHandler()
            } else if isContextReady {
                ensureInitialTab()
            }
        }

        updateWindowTitle()
    }

    func handleNavigationStateChange(id: String, canGoBack: Bool, canGoForward: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        tabs[index].canGoBack = canGoBack
        tabs[index].canGoForward = canGoForward
    }
}
