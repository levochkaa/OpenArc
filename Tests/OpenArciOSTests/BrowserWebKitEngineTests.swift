import Foundation
import Network
import Testing
import UIKit
import WebKit

// MARK: - BrowserWebKitEngineTests

@Suite(.serialized)
@MainActor struct BrowserWebKitEngineTests {
    @Test func sharedSQLiteProfileKeepsLiveWebKitHistoryAcrossTreeEditsAndScenes() async throws {
        let fixture = try LocalBrowserHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("session.sqlite")
        let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        let initial = BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "source", title: "Source", systemImageName: "globe"),
                .init(id: "target", title: "Target", systemImageName: "folder"),
            ],
            tabs: [
                .init(id: "browsing", urlString: "about:blank", spaceID: "source"),
                .init(id: "retained", urlString: "about:blank", spaceID: "source"),
            ]
        )
        try store.writeSessionBatch([.init(snapshot: initial, origin: .local(syncMove: nil))])
        let document = try BrowserMobileProfileDocument(store: store, loadSnapshot: { try store.loadSnapshotStrict() })
        let preferencesName = "WebKitSharedProfile." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: preferencesName))
        let firstEngine = BrowserWebKitEngine(dataStore: .nonPersistent())
        let secondEngine = BrowserWebKitEngine(dataStore: .nonPersistent())
        let reopenedEngine = BrowserWebKitEngine(dataStore: .nonPersistent())
        defer {
            firstEngine.shutdown()
            secondEngine.shutdown()
            reopenedEngine.shutdown()
            preferences.removePersistentDomain(forName: preferencesName)
            try? FileManager.default.removeItem(at: directory)
        }
        let first = BrowserMobileWorkspace(
            engine: firstEngine, sceneID: "first", profileLoader: { document }, preferences: preferences
        )
        let second = BrowserMobileWorkspace(
            engine: secondEngine, sceneID: "second", profileLoader: { document }, preferences: preferences
        )
        await first.restore()
        try #require(first.isReady)
        let page = BrowserMobilePageViewController(workspace: first, contentView: firstEngine.hostView)
        first.onChange = { [weak page] in page?.render() }
        page.loadViewIfNeeded()
        page.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        page.view.layoutIfNeeded()
        first.selectTab(id: "browsing")
        let firstURL = try fixture.url(path: "first"), secondURL = try fixture.url(path: "second")
        page.addressField.text = firstURL.absoluteString
        #expect(page.textFieldShouldReturn(page.addressField))
        try #require(await eventually {
            first.selectedTab?.title == "First" && first.selectedTab?.state.isLoading == false
        })
        let firstRuntime = try #require(first.selectedTab?.runtimeID)
        let liveView = try #require(firstEngine.webView(for: firstRuntime))
        _ = try await liveView.evaluateJavaScript("document.getElementById('next').click()")
        try #require(await eventually {
            first.selectedTab?.title == "Second" && first.selectedTab?.state.isLoading == false
        })
        #expect(first.selectedTab?.urlString == secondURL.absoluteString)
        #expect(try store.loadSnapshotStrict()?.tabs.first { $0.id == "browsing" }?.urlString == secondURL
            .absoluteString)
        let backURLs = liveView.backForwardList.backList.map(\.url)
        try #require(backURLs.contains(firstURL))

        #expect(document.renameTab(id: "browsing", title: "Named tab"))
        #expect(document.setTabPinned(id: "browsing", isPinned: true))
        let folder = try #require(document.createFolder(spaceID: "source", title: "Carried folder"))
        #expect(document.setPlacement(tabID: "browsing", placement: .spacePinned, pinnedFolderID: folder))
        let parent = try #require(document.createFolder(spaceID: "target", title: "Target parent"))
        #expect(document.move(
            items: [.init(entityType: .folder, entityID: folder)],
            destination: .tabs(spaceID: "target", placement: .spacePinned, pinnedFolderID: parent)
        ))
        first.selectTab(id: "browsing")
        #expect(first.selectedSpaceID == "target")
        #expect(first.selectedTab?.userTitleOverride == "Named tab")
        #expect(first.selectedTab?.runtimeID == firstRuntime)
        #expect(firstEngine.webView(for: firstRuntime) === liveView)
        #expect(liveView.backForwardList.backList.map(\.url) == backURLs)
        first.goBack()
        try #require(await eventually {
            first.selectedTab?.title == "First" && first.selectedTab?.state.isLoading == false
        })
        #expect(first.selectedTab?.state.canGoForward == true)
        first.goForward()
        try #require(await eventually {
            first.selectedTab?.title == "Second" && first.selectedTab?.state.isLoading == false
        })

        await second.restore()
        try #require(second.isReady)
        #expect(second.selectedSpaceID == "source")
        #expect(second.selectedTabID == "retained")
        #expect(first.selectedTabID == "browsing")
        second.selectTab(id: "browsing")
        try #require(await eventually {
            second.selectedTab?.title == "Second" && second.selectedTab?.state.isLoading == false
        })
        let secondRuntime = try #require(second.selectedTab?.runtimeID)
        let secondView = try #require(secondEngine.webView(for: secondRuntime))
        #expect(secondRuntime != firstRuntime && secondView !== liveView)
        #expect(second.selectedTab?.userTitleOverride == "Named tab")
        #expect(second.selectedTab?.pinnedFolderID == folder)
        #expect(firstEngine.webView(for: firstRuntime) === liveView)
        #expect(liveView.backForwardList.backList.map(\.url) == backURLs)

        #expect(document.removeTab(id: "browsing"))
        #expect(firstEngine.webView(for: firstRuntime) == nil)
        #expect(secondEngine.webView(for: secondRuntime) == nil)
        #expect(liveView.navigationDelegate == nil && secondView.navigationDelegate == nil)
        #expect(first.tabs.map(\.id) == ["retained"] && second.tabs.map(\.id) == ["retained"])
        first.selectTab(id: "retained")
        let storedSnapshot = try store.loadSnapshotStrict()
        let saved = try #require(storedSnapshot)
        #expect(saved == document.snapshot)
        #expect(saved.pinnedTabFolders?.first { $0.id == folder }?.parentFolderID == parent)
        try #require(await first.shutdown())
        try #require(await second.shutdown())

        let reopenedStore = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        let reopenedDocument = try BrowserMobileProfileDocument(
            store: reopenedStore, loadSnapshot: { try reopenedStore.loadSnapshotStrict() }
        )
        let reopened = BrowserMobileWorkspace(
            engine: reopenedEngine, sceneID: "first", profileLoader: { reopenedDocument }, preferences: preferences
        )
        await reopened.restore()
        #expect(reopened.isReady && reopened.selectedTabID == "retained")
        #expect(reopened.tabs.map(\.id) == saved.tabs.compactMap(\.id))
        #expect(reopened.tabs.map(\.urlString) == saved.tabs.map(\.urlString))
        #expect(reopenedDocument.snapshot == saved)
        #expect(reopened.tabs.allSatisfy { $0.runtimeID != firstRuntime && $0.runtimeID != secondRuntime })
        try #require(await reopened.shutdown())
    }

    @Test func composedUIKitWebKitWorkspacePersistsAndRestoresStableTabs() async throws {
        let fixture = try LocalBrowserHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("session.json")
        let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
        let workspace = BrowserMobileWorkspace(
            engine: engine, store: BrowserMobileFileSessionStore(fileURL: fileURL)
        )
        var reopenedWorkspace: BrowserMobileWorkspace?
        var reopenedEngine: BrowserWebKitEngine?
        defer {
            engine.shutdown()
            reopenedEngine?.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        do {
            await workspace.restore()
            try #require(workspace.isReady)
            let page = BrowserMobilePageViewController(workspace: workspace, contentView: engine.hostView)
            workspace.onChange = { [weak page] in page?.render() }
            page.loadViewIfNeeded()
            page.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            page.view.layoutIfNeeded()
            let originalID = try #require(workspace.selectedTabID)
            let firstURL = try fixture.url(path: "first")
            let secondURL = try fixture.url(path: "second")
            page.addressField.text = firstURL.absoluteString
            #expect(page.textFieldShouldReturn(page.addressField))
            try #require(await eventually {
                workspace.selectedTab?.title == "First" && workspace.selectedTab?.state.isLoading == false
            })
            #expect(workspace.selectedTab?.urlString == firstURL.absoluteString)

            let originalRuntime = try #require(workspace.selectedTab?.runtimeID)
            let webView = try #require(engine.webView(for: originalRuntime))
            // Follow a real document link, exercising WKNavigationDelegate's
            // page-originated path rather than issuing a second model command.
            _ = try await webView.evaluateJavaScript("document.getElementById('next').click()")
            try #require(await eventually {
                workspace.selectedTab?.title == "Second" && workspace.selectedTab?.state.isLoading == false
            })
            #expect(workspace.selectedTab?.urlString == secondURL.absoluteString)
            #expect(workspace.selectedTab?.state.canGoBack == true)
            workspace.goBack()
            try #require(await eventually {
                workspace.selectedTab?.title == "First" && workspace.selectedTab?.state.isLoading == false
            })
            #expect(workspace.selectedTab?.state.canGoForward == true)
            workspace.goForward()
            try #require(await eventually {
                workspace.selectedTab?.title == "Second" && workspace.selectedTab?.state.isLoading == false
            })

            workspace.newTab()
            let retainedID = try #require(workspace.selectedTabID)
            page.addressField.text = firstURL.absoluteString
            #expect(page.textFieldShouldReturn(page.addressField))
            try #require(await eventually {
                workspace.selectedTab?.title == "First" && workspace.selectedTab?.state.isLoading == false
            })
            workspace.newTab()
            let closedID = try #require(workspace.selectedTabID)
            workspace.closeTab(id: closedID)
            #expect(workspace.selectedTabID == retainedID)
            workspace.selectTab(id: originalID)
            #expect(workspace.selectedTab?.urlString == secondURL.absoluteString)
            #expect(workspace.tabs.map(\.id) == [originalID, retainedID])
            try #require(await workspace.flushPersistence())
            let saved = try JSONDecoder().decode(BrowserMobileSession.self, from: Data(contentsOf: fileURL))
            try saved.validate()
            #expect(saved.tabs.map(\.id) == [originalID, retainedID])
            #expect(saved.tabs.map(\.urlString) == [secondURL.absoluteString, firstURL.absoluteString])
            #expect(saved.tabs.map(\.title) == ["Second", "First"])
            #expect(saved.selectedTabID == originalID)
            let oldRuntimeIDs = Set(workspace.tabs.map(\.runtimeID))
            try #require(await workspace.shutdown())

            let nextEngine = BrowserWebKitEngine(dataStore: .nonPersistent())
            reopenedEngine = nextEngine
            let reopened = BrowserMobileWorkspace(
                engine: nextEngine, store: BrowserMobileFileSessionStore(fileURL: fileURL)
            )
            reopenedWorkspace = reopened
            await reopened.restore()
            try #require(reopened.isReady)
            #expect(reopened.tabs.map(\.id) == saved.tabs.map(\.id))
            #expect(reopened.tabs.map(\.urlString) == saved.tabs.map(\.urlString))
            #expect(reopened.selectedTabID == originalID)
            #expect(oldRuntimeIDs.isDisjoint(with: reopened.tabs.map(\.runtimeID)))
            let backgroundRuntime = try #require(reopened.tabs.last?.runtimeID)
            #expect(nextEngine.webView(for: backgroundRuntime) == nil)
            try #require(await eventually {
                reopened.selectedTab?.title == "Second" && reopened.selectedTab?.state.isLoading == false
            })
            #expect(reopened.selectedTab?.urlString == secondURL.absoluteString)
            try #require(await reopened.shutdown())
        } catch {
            // Await every file worker before deleting the fixture directory.
            await workspace.shutdown()
            await reopenedWorkspace?.shutdown()
            throw error
        }
    }

    @Test func localHTTPNavigationBackForwardAndSingleMountedTab() async throws {
        let fixture = try LocalBrowserHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
        defer { engine.shutdown() }
        let recorder = MobileWebKitRecorder(engine: engine)
        let first = try fixture.url(path: "first")
        let second = try fixture.url(path: "second")
        engine.createTab(id: "one", url: first)
        engine.selectTab(id: "one")
        #expect(await eventually { recorder.finished("one", title: "First") })
        #expect(recorder.states["one"]?.url == first)
        #expect(engine.hostView.subviews.count == 1)

        engine.navigate(id: "one", url: second)
        #expect(await eventually { recorder.finished("one", title: "Second") })
        #expect(recorder.states["one"]?.canGoBack == true)
        engine.goBack(id: "one")
        #expect(await eventually { recorder.finished("one", title: "First") })
        #expect(recorder.states["one"]?.canGoForward == true)
        engine.goForward(id: "one")
        #expect(await eventually { recorder.finished("one", title: "Second") })
        #expect(recorder.states["one"]?.progress == 1)

        try engine.createTab(id: "two", url: #require(URL(string: "about:blank")))
        let firstView = try #require(engine.webView(for: "one"))
        engine.selectTab(id: "two")
        #expect(firstView.superview == nil)
        #expect(engine.hostView.subviews.count == 1)
        #expect(engine.hostView.subviews.first === engine.webView(for: "two"))
        engine.selectTab(id: "one")
        #expect(engine.hostView.subviews.first === firstView)
        #expect(firstView.canGoBack)
    }

    @Test func restoringManyTabsCreatesOnlySelectedWebView() throws {
        let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
        defer { engine.shutdown() }
        let url = try #require(URL(string: "about:blank"))
        for index in 0..<1000 {
            engine.createTab(id: "saved-\(index)", url: url)
        }
        #expect((0..<1000).allSatisfy { engine.webView(for: "saved-\($0)") == nil })
        engine.selectTab(id: "saved-500")
        #expect(engine.webView(for: "saved-500") != nil)
        #expect((0..<1000).filter { engine.webView(for: "saved-\($0)") != nil }.count == 1)
        engine.closeTab(id: "saved-999")
        #expect(engine.webView(for: "saved-999") == nil)
        engine.navigate(id: "saved-100", url: url)
        #expect(engine.webView(for: "saved-100") != nil)
        #expect(engine.hostView.subviews.first === engine.webView(for: "saved-500"))
    }

    @Test func newerNavigationRejectsOldFailureAndCompletion() async throws {
        let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
        defer { engine.shutdown() }
        let recorder = MobileWebKitRecorder(engine: engine)
        try engine.createTab(id: "tab", url: #require(URL(string: "about:blank")))
        engine.selectTab(id: "tab")
        let view = try #require(engine.webView(for: "tab"))
        let first = try #require(engine.loadHTMLString(
            "<title>Old</title>", baseURL: URL(string: "https://fixture.invalid/old"), id: "tab"
        ))
        let secondURL = try #require(URL(string: "https://fixture.invalid/new"))
        engine.loadHTMLString("<title>New</title>", baseURL: secondURL, id: "tab")
        engine.webView(view, didFailProvisionalNavigation: first, withError: URLError(.timedOut))
        engine.webView(view, didFinish: first)
        #expect(recorder.states["tab"]?.url == secondURL)
        #expect(recorder.states["tab"]?.error == nil)
        #expect(recorder.states["tab"]?.isLoading == true)
        #expect(await eventually { recorder.finished("tab", title: "New") })
        #expect(recorder.states["tab"]?.url == secondURL)
    }

    @Test func closeAndShutdownRejectLateDelegatesAndReleaseViews() async throws {
        let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
        let recorder = MobileWebKitRecorder(engine: engine)
        try engine.createTab(id: "tab", url: #require(URL(string: "about:blank")))
        engine.selectTab(id: "tab")
        let releasedView = WeakMobileWebView()
        do {
            let view = try #require(engine.webView(for: "tab"))
            releasedView.value = view
            let navigation = engine.loadHTMLString("<title>Closing</title>", baseURL: nil, id: "tab")
            engine.selectTab(id: "tab")
            engine.closeTab(id: "tab")
            let countAfterClose = recorder.eventCount
            engine.webViewWebContentProcessDidTerminate(view)
            engine.webView(view, didFinish: navigation)
            engine.webView(view, didFail: navigation, withError: URLError(.timedOut))
            #expect(recorder.eventCount == countAfterClose)
            #expect(recorder.closedIDs == ["tab"])
            #expect(view.navigationDelegate == nil)
            #expect(view.uiDelegate == nil)
            #expect(engine.hostView.subviews.isEmpty)
            #expect(engine.webView(for: "tab") == nil)
        }
        #expect(await eventually { releasedView.value == nil })

        try engine.createTab(id: "next", url: #require(URL(string: "about:blank")))
        engine.selectTab(id: "next")
        let next = try #require(engine.webView(for: "next"))
        engine.shutdown()
        engine.webViewWebContentProcessDidTerminate(next)
        try engine.createTab(id: "after-shutdown", url: #require(URL(string: "about:blank")))
        #expect(engine.webView(for: "next") == nil)
        #expect(engine.webView(for: "after-shutdown") == nil)
        #expect(engine.onEvent == nil)
        #expect(engine.onPopupCreated == nil)
    }

    @Test func popupUsesSuppliedConfigurationAndSynchronousAdoptionWithoutLoadingTwice() throws {
        let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
        defer { engine.shutdown() }
        let configuration = WKWebViewConfiguration()
        let popupStore = WKWebsiteDataStore.nonPersistent()
        let userContent = WKUserContentController()
        configuration.websiteDataStore = popupStore
        configuration.userContentController = userContent
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        var adoptedID: String?
        var registeredBeforeCallback = false
        engine.onPopupCreated = { id, url in
            adoptedID = id
            registeredBeforeCallback = engine.webView(for: id) != nil
            #expect(url?.absoluteString == "https://fixture.invalid/popup")
            engine.selectTab(id: id)
        }
        let popup = try #require(engine.adoptPopup(
            configuration: configuration, url: URL(string: "https://fixture.invalid/popup")
        ))
        let id = try #require(adoptedID)
        #expect(registeredBeforeCallback)
        #expect(engine.webView(for: id) === popup)
        #expect(popup.configuration.websiteDataStore === popupStore)
        #expect(popup.configuration.userContentController === userContent)
        #expect(popup.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(popup.url == nil)
        #expect(popup.isLoading == false)
        #expect(engine.hostView.subviews.first === popup)

        engine.onPopupCreated = { id, _ in engine.closeTab(id: id) }
        #expect(engine.adoptPopup(configuration: configuration, url: nil) == nil)
        engine.onPopupCreated = nil
        #expect(engine.adoptPopup(configuration: configuration, url: nil) == nil)
    }

    @Test func processTerminationAndLoadFailureExposeRetry() async throws {
        let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
        defer { engine.shutdown() }
        let recorder = MobileWebKitRecorder(engine: engine)
        try engine.createTab(id: "tab", url: #require(URL(string: "about:blank")))
        let navigation = try #require(engine.loadHTMLString("<title>Recovered</title>", baseURL: nil, id: "tab"))
        let view = try #require(engine.webView(for: "tab"))
        #expect(await eventually { recorder.finished("tab", title: "Recovered") })
        // Exercise the real delegate entry point without killing a system process.
        engine.webViewWebContentProcessDidTerminate(view)
        #expect(recorder.states["tab"]?.error != nil)
        #expect(recorder.states["tab"]?.isLoading == false)
        engine.webView(view, didFinish: navigation)
        #expect(recorder.states["tab"]?.error != nil)
        engine.reload(id: "tab")
        #expect(await eventually { recorder.finished("tab", title: "Recovered") })

        let failed = try #require(engine.loadHTMLString("<title>Retried</title>", baseURL: nil, id: "tab"))
        engine.webView(view, didFailProvisionalNavigation: failed, withError: URLError(.cannotConnectToHost))
        #expect(recorder.states["tab"]?.error != nil)
        engine.reload(id: "tab")
        #expect(await eventually { recorder.finished("tab", title: "Retried") })
    }

    @Test func isolatedDataStoresAndUnsupportedAddress() async throws {
        let firstStore = WKWebsiteDataStore.nonPersistent()
        let secondStore = WKWebsiteDataStore.nonPersistent()
        let first = BrowserWebKitEngine(dataStore: firstStore)
        let second = BrowserWebKitEngine(dataStore: secondStore)
        defer { first.shutdown()
            second.shutdown()
        }
        let recorder = MobileWebKitRecorder(engine: first)
        try first.createTab(id: "one", url: #require(URL(string: "about:blank")))
        try second.createTab(id: "two", url: #require(URL(string: "about:blank")))
        first.selectTab(id: "one")
        second.selectTab(id: "two")
        #expect(first.webView(for: "one")?.configuration.websiteDataStore === firstStore)
        #expect(second.webView(for: "two")?.configuration.websiteDataStore === secondStore)
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "fixture.invalid", .path: "/", .name: "isolated", .value: "one",
        ]))
        await firstStore.httpCookieStore.setCookie(cookie)
        #expect(await firstStore.httpCookieStore.allCookies().contains { $0.name == "isolated" })
        #expect(await secondStore.httpCookieStore.allCookies().isEmpty)
        #expect(await eventually { recorder.states["one"]?.isLoading == false })
        try first.navigate(id: "one", url: #require(URL(string: "openarc://settings")))
        #expect(recorder.states["one"]?.error != nil)
        #expect(recorder.states["one"]?.url?.absoluteString == "about:blank")
    }
}

// MARK: - WeakMobileWebView

@MainActor private final class WeakMobileWebView {
    weak var value: WKWebView?
}

// MARK: - MobileWebKitRecorder

@MainActor private final class MobileWebKitRecorder {
    // MARK: Lifecycle

    init(engine: BrowserWebKitEngine) {
        engine.onEvent = { [weak self] event in
            guard let self else { return }
            eventCount += 1
            switch event {
            case .state(let id, let state): states[id] = state
            case .closed(let id): closedIDs.append(id)
            case .httpAuthenticationFinished, .httpAuthenticationRequested, .javaScriptDialogFinished,
                 .javaScriptDialogRequested: break
            }
        }
    }

    // MARK: Internal

    var states = [String: BrowserMobilePageState]()
    var closedIDs = [String]()
    var eventCount = 0

    func finished(_ id: String, title: String) -> Bool {
        states[id]?.title == title && states[id]?.isLoading == false && states[id]?.error == nil
    }
}

@MainActor private func eventually(
    timeout: Duration = .seconds(8), condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

// MARK: - LocalBrowserHTTPFixture

/// Disposable loopback HTTP documents; no internet requests or shared cookies.
@MainActor private final class LocalBrowserHTTPFixture {
    // MARK: Lifecycle

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
    }

    // MARK: Internal

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        startTimeout?.cancel()
                        startContinuation?.resume()
                        startContinuation = nil
                    case .failed(let error), .waiting(let error):
                        startTimeout?.cancel()
                        startContinuation?.resume(throwing: error)
                        startContinuation = nil
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let title = request.hasPrefix("GET /second ") ? "Second" : "First"
                    let body = "<html><head><title>\(title)</title></head><body>\(title)<a id='next' href='/second'>Next</a></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
            listener.start(queue: .main)
            startTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                startContinuation?.resume(throwing: URLError(.timedOut))
                startContinuation = nil
                listener.cancel()
            }
        }
    }

    func url(path: String) throws -> URL {
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/\(path)"))
    }

    func stop() {
        startTimeout?.cancel()
        startContinuation?.resume(throwing: URLError(.cancelled))
        startContinuation = nil
        listener.cancel()
    }

    // MARK: Private

    private let listener: NWListener
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startTimeout: Task<Void, Never>?
}
