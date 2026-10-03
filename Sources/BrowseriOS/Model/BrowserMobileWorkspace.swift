import Foundation

// MARK: - BrowserMobileTab

struct BrowserMobileTab: Identifiable, Equatable {
    let id: String
    let runtimeID: String
    var urlString: String
    var title: String
    var state: BrowserMobilePageState
}

// MARK: - BrowserMobileWorkspace

@MainActor final class BrowserMobileWorkspace {
    // MARK: Lifecycle

    init(
        engine: any BrowserMobileEngine, store: any BrowserMobileSessionStoring,
        navigationResolver: BrowserNavigationResolver = BrowserNavigationResolver()
    ) {
        self.engine = engine
        self.store = store
        self.navigationResolver = navigationResolver
        engine.onEvent = { [weak self] event in self?.receive(event) }
        engine.onPopupCreated = { [weak self] runtimeID, url in self?.adoptPopup(runtimeID: runtimeID, url: url) }
    }

    // MARK: Internal

    var onChange: (() -> Void)?
    private(set) var tabs = [BrowserMobileTab]()
    private(set) var selectedTabID: String?
    private(set) var isRestoring = false
    private(set) var isReady = false
    private(set) var sessionError: String?
    private(set) var navigationError: String?

    var selectedTab: BrowserMobileTab? { tabs.first { $0.id == selectedTabID } }

    func restore() async {
        guard !isClosed, !hasRestored, !isRestoring else { return }
        isRestoring = true
        sessionError = nil
        notify()
        do {
            let saved = try await store.load()
            guard !isClosed else { isRestoring = false
                return
            }
            try saved?.validate()
            let logicalTabs = saved?.tabs ?? []
            tabs = logicalTabs.map {
                BrowserMobileTab(
                    id: $0.id,
                    runtimeID: UUID().uuidString,
                    urlString: $0.urlString,
                    title: $0.title,
                    state: BrowserMobilePageState(url: URL(string: $0.urlString))
                )
            }
            selectedTabID = saved?.selectedTabID ?? tabs.first?.id
            lastSaved = saved
            hasRestored = true
            // Register every identity before the first engine call. Engine
            // state events are allowed to arrive synchronously from create.
            let restoringTabs = tabs
            for tab in restoringTabs {
                guard !isClosed else { break }
                engine.createTab(id: tab.runtimeID, url: URL(string: tab.urlString)!)
            }
            guard !isClosed else { isRestoring = false
                return
            }
            isRestoring = false
            isReady = true
            if tabs.isEmpty {
                insertNewTab(url: Self.blankURL)
            } else {
                engine.selectTab(id: selectedTab?.runtimeID)
            }
            enqueueCurrentSession()
            notify()
        } catch {
            guard !isClosed else { isRestoring = false
                return
            }
            isRestoring = false
            isReady = false
            sessionError = error.localizedDescription
            notify()
        }
    }

    func newTab() {
        guard canEdit else { return }
        navigationError = nil
        insertNewTab(url: Self.blankURL)
        notify()
    }

    func submit(_ input: String) {
        guard canEdit else { return }
        guard let resolution = navigationResolver.resolve(input),
              let url = BrowserMobileSession.allowedURL(resolution.resolvedURLString)
        else {
            navigationError = "This address cannot be opened in this browser. Use an HTTP or HTTPS address."
            notify()
            return
        }
        navigationError = nil
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            insertNewTab(url: url)
            notify()
            return
        }
        let runtimeID = tabs[index].runtimeID
        if tabs[index].urlString != url.absoluteString {
            tabs[index].title = ""
            tabs[index].state.title = ""
        }
        tabs[index].urlString = url.absoluteString
        tabs[index].state.url = url
        tabs[index].state.error = nil
        enqueueCurrentSession()
        engine.navigate(id: runtimeID, url: url)
        notify()
    }

    func selectTab(id: String) {
        guard canEdit, let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedTabID = id
        navigationError = nil
        enqueueCurrentSession()
        engine.selectTab(id: tab.runtimeID)
        notify()
    }

    func closeTab(id: String) {
        guard canEdit, let tab = tabs.first(where: { $0.id == id }) else { return }
        removeTab(runtimeID: tab.runtimeID)
        engine.closeTab(id: tab.runtimeID)
    }

    func goBack() {
        guard canEdit, let tab = selectedTab, tab.state.canGoBack else { return }
        engine.goBack(id: tab.runtimeID)
    }

    func goForward() {
        guard canEdit, let tab = selectedTab, tab.state.canGoForward else { return }
        engine.goForward(id: tab.runtimeID)
    }

    func reload() {
        guard canEdit, let tab = selectedTab else { return }
        engine.reload(id: tab.runtimeID)
    }

    func reloadOrStop() {
        guard canEdit, let tab = selectedTab else { return }
        if tab.state.isLoading {
            engine.stop(id: tab.runtimeID)
        } else {
            engine.reload(id: tab.runtimeID)
        }
    }

    @discardableResult func retryPersistence() async -> Bool {
        if !hasRestored {
            await restore()
            return isReady
        }
        saveFailed = false
        sessionError = nil
        startSaveWorker()
        notify()
        return await flushPersistence()
    }

    @discardableResult func flushPersistence() async -> Bool {
        startSaveWorker()
        while let worker = saveWorker {
            await worker.value
        }
        return hasRestored && pendingSave == nil && sessionError == nil
    }

    @discardableResult func shutdown() async -> Bool {
        if !isClosed {
            isClosed = true
            isReady = false
            engine.onEvent = nil
            engine.onPopupCreated = nil
            engine.shutdown()
            notify()
        }
        return await flushPersistence()
    }

    // MARK: Private

    private static let blankURL = URL(string: "about:blank")!

    private let engine: any BrowserMobileEngine
    private let store: any BrowserMobileSessionStoring
    private let navigationResolver: BrowserNavigationResolver
    private var hasRestored = false
    private var isClosed = false
    private var pendingSave: BrowserMobileSession?
    private var lastSaved: BrowserMobileSession?
    private var saveWorker: Task<Void, Never>?
    private var saveFailed = false

    private var canEdit: Bool { isReady && !isClosed && !isRestoring }

    private func insertNewTab(url: URL) {
        let tab = BrowserMobileTab(
            id: UUID().uuidString,
            runtimeID: UUID().uuidString,
            urlString: url.absoluteString,
            title: "",
            state: BrowserMobilePageState(url: url)
        )
        tabs.append(tab)
        selectedTabID = tab.id
        enqueueCurrentSession()
        engine.createTab(id: tab.runtimeID, url: url)
        if tabs.contains(where: { $0.id == tab.id }) {
            engine.selectTab(id: tab.runtimeID)
        }
    }

    private func adoptPopup(runtimeID: String, url: URL?) {
        guard !tabs.contains(where: { $0.runtimeID == runtimeID }) else { return }
        guard canEdit else { engine.closeTab(id: runtimeID)
            return
        }
        guard let url = BrowserMobileSession.allowedURL((url ?? Self.blankURL).absoluteString) else {
            navigationError = "This popup address cannot be opened in this browser."
            engine.closeTab(id: runtimeID)
            notify()
            return
        }
        let tab = BrowserMobileTab(
            id: UUID().uuidString,
            runtimeID: runtimeID,
            urlString: url.absoluteString,
            title: "",
            state: BrowserMobilePageState(url: url)
        )
        tabs.append(tab)
        selectedTabID = tab.id
        navigationError = nil
        enqueueCurrentSession()
        engine.selectTab(id: runtimeID)
        notify()
    }

    private func receive(_ event: BrowserMobileEngineEvent) {
        guard !isClosed else { return }
        switch event {
        case .state(let runtimeID, let state):
            guard let index = tabs.firstIndex(where: { $0.runtimeID == runtimeID }) else { return }
            let previousURL = tabs[index].urlString, previousTitle = tabs[index].title
            tabs[index].state = state
            if let url = state.url, BrowserMobileSession.allowedURL(url.absoluteString) != nil {
                if previousURL != url.absoluteString {
                    tabs[index].title = ""
                }
                tabs[index].urlString = url.absoluteString
            }
            if !state.title.isEmpty {
                tabs[index].title = state.title
            }
            if previousURL != tabs[index].urlString || previousTitle != tabs[index].title {
                enqueueCurrentSession()
            }
            notify()
        case .closed(let runtimeID): removeTab(runtimeID: runtimeID)
        }
    }

    private func removeTab(runtimeID: String) {
        guard let index = tabs.firstIndex(where: { $0.runtimeID == runtimeID }) else { return }
        let removed = tabs.remove(at: index)
        if selectedTabID == removed.id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty, canEdit {
            insertNewTab(url: Self.blankURL)
        } else {
            enqueueCurrentSession()
            engine.selectTab(id: selectedTab?.runtimeID)
        }
        notify()
    }

    private func snapshot() -> BrowserMobileSession {
        BrowserMobileSession(
            tabs: tabs.map { .init(id: $0.id, urlString: $0.urlString, title: $0.title) },
            selectedTabID: selectedTabID
        )
    }

    private func enqueueCurrentSession() {
        guard hasRestored, !isRestoring else { return }
        let latest = snapshot()
        if latest == pendingSave || (pendingSave == nil && saveWorker == nil && latest == lastSaved) {
            return
        }
        pendingSave = latest
        startSaveWorker()
    }

    private func startSaveWorker() {
        guard hasRestored, !saveFailed, pendingSave != nil, saveWorker == nil else { return }
        // One retained worker and one replaceable pending snapshot bound memory
        // and prevent an older asynchronous save from finishing after a newer one.
        saveWorker = Task { await self.drainSaves() }
    }

    private func drainSaves() async {
        while let session = pendingSave {
            pendingSave = nil
            do {
                try await store.save(session)
                lastSaved = session
                sessionError = nil
            } catch {
                if pendingSave == nil {
                    pendingSave = session
                }
                saveFailed = true
                sessionError = error.localizedDescription
                break
            }
        }
        saveWorker = nil
        notify()
    }

    private func notify() { onChange?() }
}
