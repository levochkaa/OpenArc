import BrowserMobileTestHost
import Foundation
import Testing
import UIKit
import WebKit

extension BrowserMobileUITests {
    @Test func realHTTPBasicPromptRetriesCredentialsAndLoadsProtectedDocument() async throws {
        try await withAuthenticationWebKit { f in
            let view = try await f.start()
            let request = try await f.openAuthentication()
            let presenter = f.root.httpAuthenticationPresenter
            let alert = try #require(presenter.presentedAlert)
            let origin = try String(f.server.url("/").absoluteString.dropLast())
            #expect(alert.title == origin)
            #expect(request.realm == "Fixture" && request.previousFailureCount == 0)
            let saved = try f.durableState()
            let fields = try #require(alert.textFields)
            try #require(fields.count == 2)
            #expect(fields[1].isSecureTextEntry)
            fields[0].text = BasicAuthHTTPFixture.username
            fields[1].text = "wrong-password"
            let afterEditing = try f.durableState()
            #expect(saved.0 == afterEditing.0 && saved.1 == afterEditing.1)
            presenter.accept(id: request.id)
            try await authenticationWait {
                f.workspace.httpAuthentication?.id != request.id && f.workspace.httpAuthentication != nil
            }
            let retry = try await f.awaitAuthentication()
            #expect(retry.previousFailureCount > 0)
            #expect(f.server.invalidAuthorizationRequestCount > 0)
            #expect(fields.allSatisfy { $0.text?.isEmpty != false })
            // An old token cannot authenticate or consume this explicit retry.
            f.workspace.resolveHTTPAuthentication(
                id: request.id,
                response: .credentials(username: "stale", password: "stale")
            )
            #expect(f.workspace.httpAuthentication?.id == retry.id)
            try f.signIn(request: retry)
            try await authenticationWait {
                f.workspace.selectedTab?.title == "Authenticated page" && f.workspace.selectedTab?.state
                    .isLoading == false
            }
            #expect(f.server.authenticatedRequestCount == 1)
            #expect(f.workspace.httpAuthentication == nil && presenter.presentedAlert == nil)
            #expect(view.uiDelegate === f.engine && view.navigationDelegate === f.engine)
            #expect(f.server.parseErrors.isEmpty)
            let persisted = try JSONEncoder().encode(f.store.loadSnapshotStrict())
            #expect(persisted.range(of: Data(BasicAuthHTTPFixture.password.utf8)) == nil)
            #expect(persisted.range(of: Data(BasicAuthHTTPFixture.username.utf8)) == nil)
        }
    }

    @Test func realHTTPBasicCancelDoesNotSendCredentialsAndReloadCanPromptAgain() async throws {
        try await withAuthenticationWebKit { f in
            _ = try await f.start()
            let first = try await f.openAuthentication()
            f.root.httpAuthenticationPresenter.cancel(id: first.id)
            // Cancel sends no credentials and shows the server's 401 document
            // at the challenged address, so Reload challenges again.
            try await authenticationWait {
                f.workspace.httpAuthentication == nil && f.workspace.selectedTab?.state.isLoading == false
                    && f.workspace.selectedTab?.title == "Authentication required"
            }
            #expect(try f.workspace.selectedTab?.urlString == f.server.url("/protected").absoluteString)
            #expect(f.server.authenticatedRequestCount == 0 && f.server.invalidAuthorizationRequestCount == 0)
            f.workspace.reloadOrStop()
            let second = try await f.awaitAuthentication()
            #expect(second.id != first.id)
            try f.signIn(request: second)
            try await authenticationWait { f.workspace.selectedTab?.title == "Authenticated page" }
            #expect(f.server.authenticatedRequestCount == 1)
        }
    }

    @Test(arguments: ["navigate", "switch", "close", "inactive", "disconnect", "stop", "shutdown"])
    func realHTTPBasicLifecycleCancelsPromptAndRejectsLateCredentials(transition: String) async throws {
        try await withAuthenticationWebKit { f in
            _ = try await f.start()
            _ = try await f.loadSource(tabID: "b")
            f.workspace.selectTab(id: "a")
            let request = try await f.openAuthentication()
            let presenter = f.root.httpAuthenticationPresenter
            let oldAlert = try #require(presenter.presentedAlert)
            oldAlert.textFields?[0].text = BasicAuthHTTPFixture.username
            oldAlert.textFields?[1].text = BasicAuthHTTPFixture.password
            switch transition {
            case "navigate": try f.workspace.submit(f.server.url("/public?next").absoluteString)
            case "switch": f.workspace.selectTab(id: "b")
            case "close": f.workspace.closeTab(id: "a")
                f.workspace.selectTab(id: "b")
            case "inactive": f.workspace.setActivityActive(false)
                f.workspace.setJavaScriptDialogPresentationActive(false)
            case "disconnect": f.workspace.setSceneAttached(false)
                f.workspace.setJavaScriptDialogPresentationActive(false)
            case "stop": f.workspace.reloadOrStop()
            case "shutdown": #expect(await f.workspace.shutdown())
            default: Issue.record("Unknown transition")
            }
            try await authenticationWait { presenter.presentedAlert == nil && !presenter.isTransitioning }
            #expect(f.workspace.httpAuthentication == nil)
            #expect(oldAlert.textFields?.allSatisfy { $0.text?.isEmpty != false } == true)
            let afterTransition = try f.durableState()
            let selected = f.workspace.selectedTab?.id
            presenter.accept(id: request.id)
            f.workspace.resolveHTTPAuthentication(id: request.id, response: .credentials(
                username: BasicAuthHTTPFixture.username, password: BasicAuthHTTPFixture.password
            ))
            // Wait for the actual challenged load to stop, not only UI dismissal.
            if transition != "shutdown", transition != "switch", transition != "close" {
                try await authenticationWait { f.workspace.selectedTab?.state.isLoading == false }
            }
            if transition == "inactive" {
                // The load stays wanted: WebKit shows the server's 401 document
                // at the challenged address instead of reverting the page.
                try await authenticationWait { f.workspace.selectedTab?.title == "Authentication required" }
                #expect(try f.workspace.selectedTab?.urlString == f.server.url("/protected").absoluteString)
            }
            #expect(f.server.authenticatedRequestCount == 0 && f.server.invalidAuthorizationRequestCount == 0)
            #expect(f.workspace.selectedTab?.id == selected)
            // Resolution itself never writes model state; normal navigation may
            // still publish page metadata independently after the transition.
            let afterLateResponse = try f.durableState()
            if transition == "switch" || transition == "close" || transition == "shutdown" {
                #expect(afterLateResponse.0 == afterTransition.0 && afterLateResponse.1 == afterTransition.1)
            }
            #expect(f.server.parseErrors.isEmpty)
        }
    }

    @Test func realHTTPBasicPromptsBelongToTheirOriginalWindow() async throws {
        try await withAuthenticationWebKit { first in
            _ = try await first.start()
            try await withAuthenticationWebKit { second in
                _ = try await second.start()
                let a = try await first.openAuthentication()
                #expect(second.workspace.httpAuthentication == nil)
                #expect(second.root.httpAuthenticationPresenter.presentedAlert == nil)
                let b = try await second.openAuthentication()
                #expect(a.id != b.id)
                first.workspace.setJavaScriptDialogPresentationActive(false)
                try await authenticationWait { first.root.httpAuthenticationPresenter.presentedAlert == nil }
                first.workspace.resolveHTTPAuthentication(id: a.id, response: .credentials(
                    username: BasicAuthHTTPFixture.username, password: BasicAuthHTTPFixture.password
                ))
                #expect(second.workspace.httpAuthentication?.id == b.id)
                try second.signIn(request: b)
                try await authenticationWait { second.workspace.selectedTab?.title == "Authenticated page" }
                #expect(second.server.authenticatedRequestCount == 1)
                #expect(first.server.authenticatedRequestCount == 0)
            }
        }
    }
}

// MARK: - AuthenticationWebKitFixture

@MainActor private final class AuthenticationWebKitFixture {
    // MARK: Lifecycle

    init(directory: URL) throws {
        self.directory = directory
        self.server = try BasicAuthHTTPFixture()
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [.init(id: "space", title: "Space", systemImageName: "globe")],
            tabs: ["a", "b"].map {
                .init(id: $0, urlString: "about:blank", spaceID: "space", lastActivityTimestamp: 1_800_000_000)
            }
        )
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        try store.bindSyncOwner(owner)
        self.document = try BrowserMobileProfileDocument(
            store: store, initialSnapshot: snapshot,
            dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) }, automaticArchivalCheckInterval: nil
        )
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        let document = document
        self.workspace = BrowserMobileWorkspace(
            engine: engine, sceneID: UUID().uuidString, profileLoader: { document }, preferences: preferences
        )
        self.root = BrowserMobileViewController(workspace: workspace, contentView: engine.hostView)
        self.window = try UIWindow(windowScene: #require(BrowserMobileTestScene.windowScene))
    }

    // MARK: Internal

    let directory: URL
    let server: BasicAuthHTTPFixture
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "authentication-owner")
    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument
    let preferencesName = "MobileAuthentication." + UUID().uuidString
    let preferences: UserDefaults
    let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
    let workspace: BrowserMobileWorkspace
    let root: BrowserMobileViewController
    let window: UIWindow

    func start() async throws -> WKWebView {
        try await server.start()
        await workspace.restore()
        try #require(workspace.isReady)
        workspace.setSceneAttached(true)
        workspace.setActivityActive(true)
        workspace.setJavaScriptDialogPresentationActive(true)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.loadViewIfNeeded()
        root.view.frame = window.bounds
        root.view.layoutIfNeeded()
        return try await loadSource(tabID: "a")
    }

    func loadSource(tabID: String) async throws -> WKWebView {
        workspace.selectTab(id: tabID)
        try workspace.submit(server.url("/public").absoluteString)
        try await authenticationWait {
            self.workspace.selectedTab?.title == "Public page" && self.workspace.selectedTab?.state.isLoading == false
        }
        root.render()
        root.view.layoutIfNeeded()
        root.pageController.view.layoutIfNeeded()
        let runtime = try #require(workspace.selectedTab?.runtimeID)
        let view = try #require(engine.webView(for: runtime))
        try #require(view.window === window && !engine.hostView.isHidden)
        return view
    }

    func openAuthentication() async throws -> BrowserMobileHTTPAuthentication {
        try workspace.submit(server.url("/protected").absoluteString)
        return try await awaitAuthentication()
    }

    func awaitAuthentication() async throws -> BrowserMobileHTTPAuthentication {
        try await authenticationWait {
            let presenter = self.root.httpAuthenticationPresenter
            return self.workspace.httpAuthentication != nil && presenter.presentedID == self.workspace
                .httpAuthentication?.id
                && presenter.presentedAlert?.viewIfLoaded?.window === self.window && !presenter.isTransitioning
        }
        return try #require(workspace.httpAuthentication)
    }

    func signIn(request: BrowserMobileHTTPAuthentication) throws {
        let presenter = root.httpAuthenticationPresenter
        let fields = try #require(presenter.presentedAlert?.textFields)
        try #require(fields.count == 2)
        fields[0].text = BasicAuthHTTPFixture.username
        fields[1].text = BasicAuthHTTPFixture.password
        presenter.accept(id: request.id)
    }

    func durableState() throws -> (BrowserTabSessionSnapshot?, [BrowserSyncQueuedMutation]) {
        try (store.loadSnapshotStrict(), store.pendingSyncQueue(for: owner))
    }

    func close() {
        root.dismiss(animated: false)
        workspace.onChange = nil
        engine.shutdown()
        server.stop()
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        preferences.removePersistentDomain(forName: preferencesName)
    }
}

@MainActor private func withAuthenticationWebKit(_ body: (AuthenticationWebKitFixture) async throws
    -> Void) async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileAuthentication-\(UUID())")
    weak var store: BrowserSQLiteSessionStore?
    var failure: (any Error)?
    do {
        try await runAuthenticationWebKit(directory: directory, observeStore: { store = $0 }, body)
    } catch { failure = error }
    // UIKit may retain an outgoing controller until the next run-loop turn.
    // Wait for actual SQLite ownership release before removing the directory.
    try await authenticationWait { store == nil }
    try FileManager.default.removeItem(at: directory)
    if let failure {
        throw failure
    }
}

@MainActor private func runAuthenticationWebKit(
    directory: URL,
    observeStore: (BrowserSQLiteSessionStore) -> Void,
    _ body: (AuthenticationWebKitFixture) async throws -> Void
) async throws {
    let fixture = try AuthenticationWebKitFixture(directory: directory)
    observeStore(fixture.store)
    defer { fixture.close() }
    do {
        try await body(fixture)
    } catch {
        _ = await fixture.workspace.shutdown()
        throw error
    }
    #expect(await fixture.workspace.shutdown())
}

@MainActor private func authenticationWait(_ condition: () async throws -> Bool) async throws {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(8))
    while clock.now < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(await condition())
}
