import Foundation

// MARK: - BrowserMobileTab

struct BrowserMobileTab: Identifiable, Equatable {
    let id: String
    let runtimeID: String
    var urlString: String
    var title: String
    var state: BrowserMobilePageState
    var spaceID: String?
    var placement = BrowserTabPlacement.temporary
    var pinnedFolderID: String?
    var userTitleOverride: String?
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

    init(
        engine: any BrowserMobileEngine, sceneID: String,
        profileLoader: @escaping @MainActor () async throws -> BrowserMobileProfileDocument,
        preferences: UserDefaults = .standard,
        navigationResolver: BrowserNavigationResolver = BrowserNavigationResolver()
    ) {
        self.engine = engine
        self.store = nil
        self.navigationResolver = navigationResolver
        self.profileLoader = profileLoader
        self.sceneID = sceneID
        self.scenePreferences = preferences
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
    private(set) var javaScriptDialog: BrowserMobileJavaScriptDialog?
    private(set) var profileDocument: BrowserMobileProfileDocument?
    private(set) var selectedSpaceID: String?

    var syncSession: BrowserMobileSyncSession? { profileDocument?.syncSession }

    var spaces: [BrowserSpaceSessionSnapshot] { profileDocument?.snapshot.spaces ?? [] }
    var visibleTabs: [BrowserMobileTab] {
        guard profileDocument != nil else { return tabs }
        return tabs.filter { $0.placement == .app || $0.spaceID == selectedSpaceID }
    }

    var selectedTab: BrowserMobileTab? { tabs.first { $0.id == selectedTabID } }

    func restore() async {
        guard !isClosed, !hasRestored, !isRestoring else { return }
        if profileLoader != nil {
            await restoreProfile()
            return
        }
        isRestoring = true
        sessionError = nil
        notify()
        do {
            let saved = try await store?.load()
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
        if let profileDocument {
            guard let tab = selectedTab else {
                insertNewTab(url: url)
                notify()
                return
            }
            if tab.urlString == url.absoluteString, registeredRuntimeIDs.contains(tab.runtimeID) {
                engine.navigate(id: tab.runtimeID, url: url)
            } else {
                // Reconciliation owns exactly one create/navigation after the
                // document accepts the action, including unsupported URL recovery.
                profileDocument.updateURL(tabID: tab.id, urlString: url.absoluteString)
            }
            notify()
            return
        }
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
        unloadedPersistentIDs.remove(id)
        if profileDocument != nil, tab.placement != .app {
            selectedSpaceID = tab.spaceID
        }
        selectedTabID = id
        cancelJavaScriptDialogIfSelectionChanged()
        navigationError = nil
        enqueueCurrentSession()
        selectCurrentRuntime()
        notify()
    }

    func selectSpace(id: String) {
        guard canEdit, spaces.contains(where: { $0.id == id }) else { return }
        selectedSpaceID = id
        if !visibleTabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = visibleTabs.first?.id
        }
        cancelJavaScriptDialogIfSelectionChanged()
        saveSceneSelection()
        selectCurrentRuntime()
        notify()
    }

    func closeTab(id: String) {
        guard canEdit, let tab = tabs.first(where: { $0.id == id }) else { return }
        if let profileDocument {
            if tab.placement == .temporary {
                profileDocument.removeTab(id: id)
            } else {
                unloadPersistentTab(tab)
            }
            return
        }
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

    func setSyncActive(_ active: Bool) {
        isSyncActive = active && !isClosed
        syncSession?.setSceneActive(isSyncActive, sceneID: sceneID)
    }

    func setJavaScriptDialogPresentationActive(_ active: Bool) {
        isJavaScriptDialogPresentationActive = active && !isClosed
        if !isJavaScriptDialogPresentationActive {
            cancelJavaScriptDialog()
        }
        engine.setJavaScriptDialogPresentationActive(isJavaScriptDialogPresentationActive)
    }

    func resolveJavaScriptDialog(id: UUID, response: BrowserMobileJavaScriptDialogResponse) {
        guard let dialog = javaScriptDialog, dialog.id == id else { return }
        let mayRespond = canEdit && isJavaScriptDialogPresentationActive
            && selectedTab?.runtimeID == dialog.runtimeID
        javaScriptDialog = nil
        engine.resolveJavaScriptDialog(id: id, response: mayRespond ? response : .cancel)
        notify()
    }

    @discardableResult func retryPersistence() async -> Bool {
        if !hasRestored {
            await restore()
            return isReady
        }
        if let profileDocument {
            let succeeded = profileDocument.retryPersistence()
            updateProfileError()
            notify()
            return succeeded
        }
        saveFailed = false
        sessionError = nil
        startSaveWorker()
        notify()
        return await flushPersistence()
    }

    @discardableResult func flushPersistence() async -> Bool {
        if let profileDocument {
            return !profileDocument.hasUncommittedWrites
        }
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
            setJavaScriptDialogPresentationActive(false)
            setSyncActive(false)
            engine.onEvent = nil
            engine.onPopupCreated = nil
            if let documentObserver {
                profileDocument?.removeObserver(documentObserver)
            }
            documentObserver = nil
            engine.shutdown()
            notify()
        }
        return await flushPersistence()
    }

    // MARK: Private

    private static let blankURL = URL(string: "about:blank")!

    private let engine: any BrowserMobileEngine
    private let store: (any BrowserMobileSessionStoring)?
    private let navigationResolver: BrowserNavigationResolver
    private var hasRestored = false
    private var isClosed = false
    private var pendingSave: BrowserMobileSession?
    private var lastSaved: BrowserMobileSession?
    private var saveWorker: Task<Void, Never>?
    private var saveFailed = false
    private var isJavaScriptDialogPresentationActive = false
    private var isSyncActive = false
    private var profileLoader: (@MainActor () async throws -> BrowserMobileProfileDocument)?
    private var sceneID = ""
    private var scenePreferences: UserDefaults?
    private var documentObserver: UUID?
    private var applyingDocument = false
    private var registeredRuntimeIDs = Set<String>()
    private var adoptedPopupRuntimeID: String?
    private var unloadedPersistentIDs = Set<String>()

    private var canEdit: Bool {
        isReady && !isClosed && !isRestoring && (profileDocument?.canEdit ?? true)
    }

    private var selectionKey: String { "mobile.scene." + Data(sceneID.utf8).base64EncodedString() }

    private func restoreProfile() async {
        guard let profileLoader else { return }
        isRestoring = true
        sessionError = nil
        notify()
        do {
            let document = try await profileLoader()
            guard !isClosed else { isRestoring = false
                return
            }
            profileDocument = document
            syncSession?.setSceneActive(isSyncActive, sceneID: sceneID)
            selectedSpaceID = scenePreferences?.string(forKey: selectionKey + ".space")
            selectedTabID = scenePreferences?.string(forKey: selectionKey + ".tab")
            if selectedSpaceID == nil {
                let filename = Data(sceneID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".json"
                let importedID = BrowserMobileProfileRegistry.legacySpaceID(filename: filename)
                if let space = document.snapshot.spaces?.first(where: { $0.id == importedID }) {
                    selectedSpaceID = importedID
                    let importedTabs = document.snapshot.tabs.filter { $0.spaceID == importedID }
                    if let index = space.selectedTabIndex, importedTabs.indices.contains(index) {
                        selectedTabID = importedTabs[index].id
                    }
                }
            }
            hasRestored = true
            isRestoring = false
            isReady = true
            documentObserver = document.observe { [weak self] snapshot in self?.applyProfile(snapshot) }
        } catch {
            isRestoring = false
            guard !isClosed else { return }
            isReady = false
            sessionError = error.localizedDescription
            notify()
        }
    }

    private func applyProfile(_ snapshot: BrowserTabSessionSnapshot) {
        guard !isClosed else { return }
        applyingDocument = true
        defer { applyingDocument = false }
        let previous = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let oldSelectionIndex = visibleTabs.firstIndex { $0.id == selectedTabID } ?? 0
        tabs = snapshot.tabs.compactMap { record in
            guard let id = record.id else { return nil }
            var tab = previous[id] ?? BrowserMobileTab(
                id: id, runtimeID: adoptedPopupRuntimeID ?? UUID().uuidString,
                urlString: record.urlString, title: "",
                state: BrowserMobilePageState(url: URL(string: record.urlString))
            )
            if previous[id] == nil, adoptedPopupRuntimeID != nil {
                registeredRuntimeIDs.insert(tab.runtimeID)
            }
            if tab.urlString != record.urlString {
                tab.title = ""
            }
            tab.urlString = record.urlString
            tab.userTitleOverride = record.userTitleOverride
            tab.spaceID = record.spaceID
            tab.placement = record.placement
            tab.pinnedFolderID = record.pinnedFolderID
            if BrowserMobileSession.allowedURL(record.urlString) == nil {
                tab.state = BrowserMobilePageState(
                    url: URL(string: record.urlString),
                    error: "This address is unavailable on this device."
                )
            }
            return tab
        }
        let surviving = Set(tabs.map(\.id))
        unloadedPersistentIDs.formIntersection(surviving)
        for tab in previous.values where !surviving.contains(tab.id) {
            if registeredRuntimeIDs.remove(tab.runtimeID) != nil {
                engine.closeTab(id: tab.runtimeID)
            }
        }
        if !spaces.contains(where: { $0.id == selectedSpaceID }) {
            selectedSpaceID = spaces.first?.id
        }
        if !visibleTabs.contains(where: { $0.id == selectedTabID }) {
            let visible = visibleTabs.filter { !unloadedPersistentIDs.contains($0.id) }
            selectedTabID = visible.isEmpty ? nil : visible[min(oldSelectionIndex, visible.count - 1)].id
        }
        cancelJavaScriptDialogIfSelectionChanged()
        // Register all logical identities before WebKit can call back synchronously.
        for tab in tabs {
            guard !unloadedPersistentIDs.contains(tab.id) else { continue }
            guard let url = BrowserMobileSession.allowedURL(tab.urlString) else {
                if registeredRuntimeIDs.remove(tab.runtimeID) != nil {
                    engine.closeTab(id: tab.runtimeID)
                    if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                        // An engine ID cannot be reused after close.
                        let old = tabs[index]
                        tabs[index] = BrowserMobileTab(
                            id: old.id,
                            runtimeID: UUID().uuidString,
                            urlString: old.urlString,
                            title: old.title,
                            state: old.state,
                            spaceID: old.spaceID,
                            placement: old.placement,
                            pinnedFolderID: old.pinnedFolderID,
                            userTitleOverride: old.userTitleOverride
                        )
                    }
                }
                continue
            }
            if registeredRuntimeIDs.insert(tab.runtimeID).inserted {
                engine.createTab(id: tab.runtimeID, url: url)
            } else if previous[tab.id]?.urlString != tab.urlString, previous[tab.id] != nil {
                engine.navigate(id: tab.runtimeID, url: url)
            }
        }
        updateProfileError()
        saveSceneSelection()
        selectCurrentRuntime()
        notify()
    }

    private func saveSceneSelection() {
        scenePreferences?.set(selectedSpaceID, forKey: selectionKey + ".space")
        scenePreferences?.set(selectedTabID, forKey: selectionKey + ".tab")
    }

    private func selectCurrentRuntime() {
        if profileDocument != nil, let tab = selectedTab,
           !unloadedPersistentIDs.contains(tab.id), !registeredRuntimeIDs.contains(tab.runtimeID),
           let url = BrowserMobileSession.allowedURL(tab.urlString)
        {
            registeredRuntimeIDs.insert(tab.runtimeID)
            engine.createTab(id: tab.runtimeID, url: url)
        }
        let id = selectedTab?.runtimeID
        engine.selectTab(id: profileDocument == nil || id.map(registeredRuntimeIDs.contains) == true ? id : nil)
    }

    private func updateProfileError() {
        guard let failure = profileDocument?.persistenceFailure else { sessionError = nil
            return
        }
        sessionError = failure.isRetryable
            ? "Changes could not be saved. Retry before closing the browser."
            : "Changes could not be saved. Keep this window open to preserve your unsaved work."
    }

    private func unloadPersistentTab(_ tab: BrowserMobileTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        unloadedPersistentIDs.insert(tab.id)
        tabs[index] = BrowserMobileTab(
            id: tab.id,
            runtimeID: UUID().uuidString,
            urlString: tab.urlString,
            title: tab.title,
            state: BrowserMobilePageState(url: URL(string: tab.urlString)),
            spaceID: tab.spaceID,
            placement: tab.placement,
            pinnedFolderID: tab.pinnedFolderID,
            userTitleOverride: tab.userTitleOverride
        )
        if selectedTabID == tab.id {
            selectedTabID = visibleTabs.first { !unloadedPersistentIDs.contains($0.id) }?.id
        }
        cancelJavaScriptDialogIfSelectionChanged()
        if registeredRuntimeIDs.remove(tab.runtimeID) != nil {
            engine.closeTab(id: tab.runtimeID)
        }
        saveSceneSelection()
        selectCurrentRuntime()
        notify()
    }

    private func insertNewTab(url: URL) {
        if let profileDocument {
            var spaceID = selectedSpaceID ?? spaces.first?.id
            if spaceID == nil {
                spaceID = profileDocument.createSpace(title: "Personal")
            }
            guard let spaceID,
                  let id = profileDocument.createTab(urlString: url.absoluteString, spaceID: spaceID) else { return }
            selectTab(id: id)
            return
        }
        let tab = BrowserMobileTab(
            id: UUID().uuidString,
            runtimeID: UUID().uuidString,
            urlString: url.absoluteString,
            title: "",
            state: BrowserMobilePageState(url: url)
        )
        tabs.append(tab)
        selectedTabID = tab.id
        cancelJavaScriptDialogIfSelectionChanged()
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
        if let profileDocument {
            guard let spaceID = selectedSpaceID ?? spaces.first?.id else { engine.closeTab(id: runtimeID)
                return
            }
            adoptedPopupRuntimeID = runtimeID
            defer { adoptedPopupRuntimeID = nil }
            if let id = profileDocument.createTab(urlString: url.absoluteString, spaceID: spaceID) {
                selectTab(id: id)
            } else {
                engine.closeTab(id: runtimeID)
            }
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
        cancelJavaScriptDialogIfSelectionChanged()
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
                if let profileDocument {
                    if !applyingDocument, previousURL != tabs[index].urlString {
                        profileDocument.updateURL(tabID: tabs[index].id, urlString: tabs[index].urlString)
                    }
                } else {
                    enqueueCurrentSession()
                }
            }
            notify()
        case .closed(let runtimeID):
            if let profileDocument {
                guard registeredRuntimeIDs.remove(runtimeID) != nil,
                      let tab = tabs.first(where: { $0.runtimeID == runtimeID }) else { return }
                if tab.placement == .temporary {
                    profileDocument.removeTab(id: tab.id)
                } else {
                    unloadPersistentTab(tab)
                }
            } else {
                removeTab(runtimeID: runtimeID)
            }
        case .javaScriptDialogRequested(let dialog):
            guard canEdit, isJavaScriptDialogPresentationActive,
                  selectedTab?.runtimeID == dialog.runtimeID
            else {
                engine.resolveJavaScriptDialog(id: dialog.id, response: .cancel)
                return
            }
            if let current = javaScriptDialog {
                if current.id != dialog.id {
                    engine.resolveJavaScriptDialog(id: dialog.id, response: .cancel)
                }
                return
            }
            javaScriptDialog = dialog
            notify()
        case .javaScriptDialogFinished(let id):
            guard javaScriptDialog?.id == id else { return }
            javaScriptDialog = nil
            notify()
        }
    }

    private func removeTab(runtimeID: String) {
        guard let index = tabs.firstIndex(where: { $0.runtimeID == runtimeID }) else { return }
        let removed = tabs.remove(at: index)
        if selectedTabID == removed.id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        cancelJavaScriptDialogIfSelectionChanged()
        if tabs.isEmpty, canEdit {
            insertNewTab(url: Self.blankURL)
        } else {
            enqueueCurrentSession()
            engine.selectTab(id: selectedTab?.runtimeID)
        }
        notify()
    }

    private func cancelJavaScriptDialogIfSelectionChanged() {
        guard let dialog = javaScriptDialog, dialog.runtimeID != selectedTab?.runtimeID else { return }
        cancelJavaScriptDialog()
    }

    private func cancelJavaScriptDialog() {
        guard let dialog = javaScriptDialog else { return }
        javaScriptDialog = nil
        engine.resolveJavaScriptDialog(id: dialog.id, response: .cancel)
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
        if let profileDocument {
            saveSceneSelection()
            if !applyingDocument, let tab = selectedTab {
                profileDocument.updateURL(tabID: tab.id, urlString: tab.urlString)
            }
            return
        }
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
                try await store?.save(session)
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
