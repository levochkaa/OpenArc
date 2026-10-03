import BrowserMobileTestHost
import Foundation
import Testing
import UIKit
import WebKit

/// Share the serialized UI suite: these tests create windows in the same scene.
extension BrowserMobileUITests {
    @Test func javaScriptDialogsRoundTripThroughUIKitAndResumeSequentialPageScript() async throws {
        let fixture = try await MobileDialogUIKitFixture()
        defer { fixture.close() }
        let result = MobileDialogScriptResult()
        let script = fixture.run("""
        JSON.stringify([
            alert('notice') === undefined,
            confirm('accept confirmation'),
            prompt('empty answer', 'initial text'),
            confirm('cancel confirmation'),
            prompt('cancel answer', 'keep this')
        ])
        """, result: result)
        defer { script.cancel() }

        var request = try await fixture.waitForDialog("notice")
        var alert = try #require(fixture.presenter.presentedAlert)
        #expect(alert.title == "https://dialog.example")
        #expect(alert.actions.map(\.title) == ["OK"])
        #expect(alert.textFields?.isEmpty != false)
        fixture.presenter.accept(id: request.id)

        request = try await fixture.waitForDialog("accept confirmation")
        alert = try #require(fixture.presenter.presentedAlert)
        #expect(alert.actions.map(\.title) == ["Cancel", "OK"])
        #expect(alert.preferredAction?.title == "OK")
        fixture.presenter.accept(id: request.id)

        request = try await fixture.waitForDialog("empty answer")
        alert = try #require(fixture.presenter.presentedAlert)
        let input = try #require(alert.textFields?.first)
        #expect(input.text == "initial text")
        input.text = ""
        fixture.presenter.accept(id: request.id)

        request = try await fixture.waitForDialog("cancel confirmation")
        fixture.presenter.cancel(id: request.id)
        request = try await fixture.waitForDialog("cancel answer")
        #expect(fixture.presenter.presentedAlert?.textFields?.first?.text == "keep this")
        fixture.presenter.cancel(id: request.id)
        try #require(await dialogEventually { result.value != nil })
        #expect(try result.value?.get() == "[true,true,\"\",false,null]")
        #expect(fixture.workspace.javaScriptDialog == nil)
        #expect(fixture.presenter.presentedAlert == nil)
        #expect(fixture.root.presentedViewController == nil)
    }

    @Test(arguments: [false, true])
    func javaScriptDialogCancellationDismissesOnlyOwnedUIAndIgnoresOldActions(duringAccept: Bool) async throws {
        let fixture = try await MobileDialogUIKitFixture()
        defer { fixture.close() }
        let result = MobileDialogScriptResult()
        let script = fixture.run("JSON.stringify(confirm('old page'))", result: result)
        defer { script.cancel() }
        let request = try await fixture.waitForDialog("old page")
        if duringAccept {
            fixture.presenter.accept(id: request.id)
            #expect(fixture.presenter.isTransitioning)
        }
        fixture.workspace.setJavaScriptDialogPresentationActive(false)
        // A late tap after engine cancellation must not turn false into true.
        fixture.presenter.accept(id: request.id)
        try #require(await dialogEventually {
            result.value != nil && !fixture.presenter.isTransitioning && fixture.root.presentedViewController == nil
        })
        #expect(try result.value?.get() == "false")
        #expect(fixture.workspace.javaScriptDialog == nil)

        fixture.workspace.setJavaScriptDialogPresentationActive(true)
        let second = MobileDialogScriptResult()
        let nextScript = fixture.run("JSON.stringify(prompt('new page', 'new text'))", result: second)
        defer { nextScript.cancel() }
        let next = try await fixture.waitForDialog("new page")
        #expect(next.id != request.id)
        fixture.presenter.cancel(id: request.id)
        #expect(fixture.presenter.presentedID == next.id)
        fixture.presenter.accept(id: next.id)
        fixture.presenter.cancel(id: next.id)
        try #require(await dialogEventually { second.value != nil })
        #expect(try second.value?.get() == "\"new text\"")
    }

    @Test func nextJavaScriptDialogWaitsForCanceledPresentationTransition() async throws {
        let fixture = try await MobileDialogUIKitFixture()
        defer { fixture.close() }
        let firstResult = MobileDialogScriptResult()
        let firstScript = fixture.run("JSON.stringify(confirm('interrupted'))", result: firstResult)
        defer { firstScript.cancel() }
        try #require(await dialogEventually {
            fixture.workspace.javaScriptDialog?.message == "interrupted" && fixture.presenter.isTransitioning
        })
        fixture.workspace.setJavaScriptDialogPresentationActive(false)
        fixture.workspace.setJavaScriptDialogPresentationActive(true)
        let secondResult = MobileDialogScriptResult()
        let secondScript = fixture.run("JSON.stringify(confirm('replacement'))", result: secondResult)
        defer { secondScript.cancel() }
        let request = try await fixture.waitForDialog("replacement")
        fixture.presenter.accept(id: request.id)
        try #require(await dialogEventually { firstResult.value != nil && secondResult.value != nil })
        #expect(try firstResult.value?.get() == "false")
        #expect(try secondResult.value?.get() == "true")
    }

    @Test(arguments: [false, true])
    func javaScriptResponseSurvivesUIKitDismissalAlreadyInProgress(dismissFirst: Bool) async throws {
        let fixture = try await MobileDialogUIKitFixture()
        defer { fixture.close() }
        let result = MobileDialogScriptResult()
        let script = fixture.run("JSON.stringify(confirm('native dismissal'))", result: result)
        defer { script.cancel() }
        let request = try await fixture.waitForDialog("native dismissal")
        let alert = try #require(fixture.presenter.presentedAlert)
        // Exercise both UIKit dismissal orderings around our action path using
        // public APIs. This is not an injected physical UIAlertAction tap.
        if dismissFirst {
            alert.dismiss(animated: true)
        }
        fixture.presenter.accept(id: request.id)
        if !dismissFirst {
            alert.dismiss(animated: true)
        }
        try #require(await dialogEventually { result.value != nil && !fixture.presenter.isTransitioning })
        #expect(try result.value?.get() == "true")
        #expect(fixture.root.presentedViewController == nil)
    }

    @Test func javaScriptDialogCannotReplaceAnExistingNativeSheet() async throws {
        let fixture = try await MobileDialogUIKitFixture()
        defer { fixture.close() }
        let sheet = UIViewController()
        sheet.view.backgroundColor = .systemBackground
        fixture.root.present(sheet, animated: false)
        try #require(await dialogEventually { sheet.presentingViewController != nil })
        let result = MobileDialogScriptResult()
        let script = fixture.run("JSON.stringify(confirm('while sharing'))", result: result)
        defer { script.cancel() }
        try #require(await dialogEventually { result.value != nil })
        #expect(try result.value?.get() == "false")
        #expect(fixture.presenter.presentedAlert == nil)
        #expect(fixture.root.presentedViewController === sheet)
        sheet.dismiss(animated: false)
    }

    @Test func javaScriptDialogWithoutAttachedPresenterCancelsImmediately() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        var responses = [(UUID, BrowserMobileJavaScriptDialogResponse)]()
        let presenter = BrowserMobileJavaScriptDialogPresenter(host: host) { responses.append(($0, $1)) }
        let request = BrowserMobileJavaScriptDialog(
            id: UUID(), runtimeID: "unattached", origin: "https://example.com",
            message: "No window", kind: .prompt(defaultText: "value")
        )
        presenter.update(request)
        #expect(responses.count == 1)
        #expect(responses.first?.0 == request.id && responses.first?.1 == .cancel)
        #expect(presenter.presentedAlert == nil)
    }
}

// MARK: - MobileDialogUIKitFixture

@MainActor private final class MobileDialogUIKitFixture {
    // MARK: Lifecycle

    init() async throws {
        let scene = try #require(BrowserMobileTestScene.windowScene)
        let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
        let workspace = BrowserMobileWorkspace(engine: engine, store: MobileDialogMemoryStore())
        let root = BrowserMobileViewController(workspace: workspace, contentView: engine.hostView)
        let window = UIWindow(windowScene: scene)
        do {
            await workspace.restore()
            window.rootViewController = root
            window.makeKeyAndVisible()
            root.loadViewIfNeeded()
            root.view.layoutIfNeeded()
            try #require(await dialogEventually { scene.activationState == .foregroundActive })
            workspace.setJavaScriptDialogPresentationActive(true)
            let id = try #require(workspace.selectedTab?.runtimeID)
            engine.loadHTMLString(
                "<html><head><title>Dialog fixture</title></head><body>Test page</body></html>",
                baseURL: URL(string: "https://dialog.example/"), id: id
            )
            let webView = try #require(engine.webView(for: id))
            try #require(await dialogEventually { workspace.selectedTab?.title == "Dialog fixture" })
            self.engine = engine
            self.workspace = workspace
            self.root = root
            self.window = window
            self.webView = webView
        } catch {
            workspace.setJavaScriptDialogPresentationActive(false)
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            await workspace.shutdown()
            throw error
        }
    }

    // MARK: Internal

    let engine: BrowserWebKitEngine
    let workspace: BrowserMobileWorkspace
    let root: BrowserMobileViewController
    let window: UIWindow
    let webView: WKWebView

    var presenter: BrowserMobileJavaScriptDialogPresenter { root.javaScriptDialogPresenter }

    func run(_ script: String, result: MobileDialogScriptResult) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                let value = try await webView.evaluateJavaScript(script)
                result.value = .success(value as? String)
            } catch {
                result.value = .failure(error)
            }
        }
    }

    func waitForDialog(_ message: String) async throws -> BrowserMobileJavaScriptDialog {
        try #require(await dialogEventually {
            self.workspace.javaScriptDialog?.message == message &&
                self.presenter.presentedAlert?.presentingViewController != nil && !self.presenter.isTransitioning
        })
        return try #require(workspace.javaScriptDialog)
    }

    func close() {
        workspace.setJavaScriptDialogPresentationActive(false)
        engine.shutdown()
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }
}

// MARK: - MobileDialogScriptResult

@MainActor private final class MobileDialogScriptResult {
    var value: Result<String?, Error>?
}

// MARK: - MobileDialogMemoryStore

private actor MobileDialogMemoryStore: BrowserMobileSessionStoring {
    // MARK: Internal

    func load() -> BrowserMobileSession? { session }
    func save(_ session: BrowserMobileSession) { self.session = session }

    // MARK: Private

    private var session: BrowserMobileSession?
}

@MainActor private func dialogEventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return predicate()
}
