import AppKit
import Combine
import Foundation

@MainActor
final class BrowserChromeModel: NSObject, ObservableObject {
    static let minSidebarWidth: CGFloat = 188
    static let defaultSidebarWidth: CGFloat = 224
    static let maxSidebarWidth: CGFloat = 420

    struct Tab: Identifiable, Equatable {
        let id: String
        var title: String
        var urlString: String
        var faviconURLString: String?

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

    private var hasCreatedInitialTab = false
    private var closingTabIDs = Set<String>()
    private(set) var isContextReady = false
    var isShuttingDown = false

    init(windowTitleHandler: @escaping (String) -> Void) {
        self.windowTitleHandler = windowTitleHandler

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
        guard isContextReady, !isShuttingDown else {
            return
        }

        let tabID = tabController.createTab(withURLString: newTabURLString, makeActive: true)
        selectedTabID = tabID
        updateWindowTitle()
    }

    func reloadCurrentTab() {
        guard isContextReady, !isShuttingDown else {
            return
        }

        tabController.reloadActiveTab()
    }

    func forceReloadCurrentTab() {
        guard isContextReady, !isShuttingDown else {
            return
        }

        tabController.reloadActiveTabIgnoringCache()
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

    func closeTab(id: String) {
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
        tabController.closeTab(withID: id)
        updateWindowTitle()
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = min(max(width, Self.minSidebarWidth), Self.maxSidebarWidth)
    }

    private func ensureInitialTab() {
        guard isContextReady, !hasCreatedInitialTab, !isShuttingDown else {
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
        let didCloseOptimistically = closingTabIDs.remove(id) != nil
        if !didCloseOptimistically {
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

            if isContextReady, !isShuttingDown {
                ensureInitialTab()
            }
        }

        updateWindowTitle()
    }
}
