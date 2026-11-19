// BrowserWebKitDialogTests.swift

import BrowserMobileTestHost
import Foundation
import Network
import Testing
import UIKit
import WebKit

// MARK: - BrowserWebKitDialogTests

extension BrowserMobileUITests {
    enum Cancellation: CaseIterable { case navigate, close, shutdown, processTermination, stop, detach }

    @Test func actualJavaScriptAlertConfirmAndPromptReturnUserResponses() async throws {
        let fixture = try DialogWebKitFixture()
        defer { fixture.close() }
        try await fixture.load()
        fixture.response = { request in
            switch request.message {
            case "cancel": .cancel
            case "empty": .accept(text: "")
            case "default": .accept(text: "initial")
            default: .accept(text: nil)
            }
        }
        #expect(try await fixture.evaluate("alert('alert'); return true") == "true")
        #expect(try await fixture.evaluate("return confirm('accept')") == "true")
        #expect(try await fixture.evaluate("return confirm('cancel')") == "false")
        #expect(try await fixture.evaluate("return prompt('default', 'initial')") == "\"initial\"")
        #expect(try await fixture.evaluate("return prompt('empty', 'initial')") == "\"\"")
        #expect(try await fixture.evaluate("return prompt('cancel', 'initial')") == "null")
        #expect(fixture.requests.map(\.kind) == [
            .alert, .confirm, .confirm,
            .prompt(defaultText: "initial"), .prompt(defaultText: "initial"), .prompt(defaultText: "initial"),
        ])
        #expect(fixture.requests.allSatisfy { $0.origin == "https://dialog.example" })
        #expect(fixture.finished == fixture.requests.map(\.id))
    }

    @Test func actualBackgroundAndInactiveDialogsFinishWithoutPresentation() async throws {
        let fixture = try DialogWebKitFixture()
        defer { fixture.close() }
        try await fixture.load()
        fixture.engine.setJavaScriptDialogPresentationActive(false)
        #expect(try await fixture.evaluate("return confirm('inactive')") == "false")
        #expect(try await fixture.evaluate("return prompt('inactive')") == "null")
        fixture.engine.setJavaScriptDialogPresentationActive(true)
        try fixture.engine.createTab(id: "background", url: #require(URL(string: "about:blank")))
        fixture.engine.loadHTMLString("<title>Background</title>", baseURL: nil, id: "background")
        try #require(await fixture.wait { fixture.states["background"]?.isLoading == false })
        let background = try #require(fixture.engine.webView(for: "background"))
        #expect(try await fixture
            .evaluate("alert('background'); return confirm('background')", in: background) == "false")
        #expect(fixture.requests.isEmpty)
        #expect(fixture.finished.isEmpty)
    }

    @Test func actualPendingDialogIsCanceledOnSwitchAndInactiveWithoutAnsweringNextDialog() async throws {
        let fixture = try DialogWebKitFixture()
        defer { fixture.close() }
        try await fixture.load()
        let evaluation = fixture.startEvaluation("return confirm('first')")
        try #require(await fixture.wait { fixture.requests.count == 1 })
        let first = try #require(fixture.requests.first)
        try fixture.engine.createTab(id: "other", url: #require(URL(string: "about:blank")))
        fixture.engine.selectTab(id: "other")
        #expect(try await fixture.result(of: evaluation) == "false")
        #expect(fixture.finished == [first.id])
        fixture.engine.selectTab(id: "tab")
        let secondEvaluation = fixture.startEvaluation("return prompt('second', 'value')")
        try #require(await fixture.wait { fixture.requests.count == 2 })
        let second = try #require(fixture.requests.last)
        fixture.engine.resolveJavaScriptDialog(id: first.id, response: .accept(text: "stale"))
        #expect(fixture.finished == [first.id])
        fixture.engine.setJavaScriptDialogPresentationActive(false)
        #expect(try await fixture.result(of: secondEvaluation) == "null")
        fixture.engine.resolveJavaScriptDialog(id: second.id, response: .accept(text: "late"))
        #expect(fixture.finished == [first.id, second.id])
    }

    @Test func replacingDocumentRejectsResumedOldPromptButAdmitsNewDocumentStartupDialog() async throws {
        let server = try HeldDialogHTTPServer()
        try await server.start()
        defer { server.stop() }
        let fixture = try DialogWebKitFixture()
        defer { fixture.close() }
        try await fixture.load()
        let evaluation = fixture.startEvaluation("return [confirm('old'), prompt('old-followup', 'stale')]")
        try #require(await fixture.wait { fixture.requests.count == 1 })
        try fixture.engine.navigate(id: "tab", url: server.url())
        try #require(await fixture.wait { server.hasRequest })
        #expect(try await fixture.result(of: evaluation) == "[false,null]")
        #expect(fixture.requests.map(\.message) == ["old"])
        fixture.response = { _ in .cancel }
        server.release(body: "<title>Replacement</title><script>confirm('new-startup')</script>")
        try #require(await fixture.wait { fixture.states["tab"]?.title == "Replacement" })
        #expect(fixture.requests.map(\.message) == ["old", "new-startup"])
        #expect(fixture.finished == fixture.requests.map(\.id))
    }

    @Test func fragmentNavigationAndBackAndStopKeepCommittedDocumentDialogsAvailable() async throws {
        let server = try HeldDialogHTTPServer()
        try await server.start()
        defer { server.stop() }
        let fixture = try DialogWebKitFixture()
        defer { fixture.close() }
        try fixture.engine.navigate(id: "tab", url: server.url())
        try #require(await fixture.wait { server.hasRequest })
        server.release(body: "<title>Fragments</title>")
        try #require(await fixture.wait { fixture.states["tab"]?.title == "Fragments" })
        fixture.response = { _ in .accept(text: nil) }
        let fragmentURL = try #require(URL(string: server.url().absoluteString + "#one"))
        fixture.engine.navigate(id: "tab", url: fragmentURL)
        try #require(await fixture.wait { fixture.webView.url == fragmentURL })
        #expect(try await fixture.evaluate("return confirm('fragment')") == "true")
        try #require(fixture.webView.canGoBack)
        fixture.engine.goBack(id: "tab")
        try #require(await fixture.wait { fixture.webView.url?.fragment == nil })
        #expect(try await fixture.evaluate("return confirm('back')") == "true")
        fixture.engine.stop(id: "tab")
        #expect(try await fixture.evaluate("return confirm('stopped')") == "true")
        #expect(fixture.requests.map(\.message) == ["fragment", "back", "stopped"])
    }

    @Test(arguments: Cancellation.allCases)
    func lifecycleCancellationCompletesExactlyOnce(_ cancellation: Cancellation) async throws {
        let fixture = try DialogWebKitFixture()
        defer { fixture.close() }
        try await fixture.load()
        var responses = [BrowserMobileJavaScriptDialogResponse]()
        fixture.engine.requestJavaScriptDialog(
            in: fixture.webView, kind: .confirm, message: "pending", origin: "https://dialog.example",
        ) { responses.append($0) }
        let request = try #require(fixture.requests.first)
        switch cancellation {
        case .navigate: fixture.engine.loadHTMLString("<title>Next</title>", baseURL: nil, id: "tab")
        case .close: fixture.engine.closeTab(id: "tab")
        case .shutdown: fixture.engine.shutdown()
        case .processTermination: fixture.engine.webViewWebContentProcessDidTerminate(fixture.webView)
        case .stop: fixture.engine.stop(id: "tab")
        case .detach: fixture.engine.onEvent = nil
        }
        #expect(responses == [.cancel])
        fixture.engine.resolveJavaScriptDialog(id: request.id, response: .accept(text: nil))
        fixture.engine.resolveJavaScriptDialog(id: request.id, response: .cancel)
        #expect(responses == [.cancel])
        if cancellation != .detach {
            #expect(fixture.finished == [request.id])
        }
    }

    @Test func overlapReentrancyUnknownViewAndNoOpNavigationCannotLeakCompletion() async throws {
        let fixture = try DialogWebKitFixture()
        defer { fixture.close() }
        try await fixture.load()
        var responses = [BrowserMobileJavaScriptDialogResponse]()
        var nested = [BrowserMobileJavaScriptDialogResponse]()
        fixture.engine.requestJavaScriptDialog(
            in: fixture.webView, kind: .confirm, message: "owned", origin: "https://dialog.example",
        ) { response in
            responses.append(response)
            fixture.engine.requestJavaScriptDialog(
                in: fixture.webView, kind: .confirm, message: "reentrant", origin: "https://dialog.example",
            ) { nested.append($0) }
        }
        fixture.engine.requestJavaScriptDialog(
            in: fixture.webView, kind: .alert, message: "overlap", origin: "https://dialog.example",
        ) { nested.append($0) }
        fixture.engine.requestJavaScriptDialog(
            in: WKWebView(), kind: .confirm, message: "unknown", origin: "https://dialog.example",
        ) { nested.append($0) }
        fixture.engine.selectTab(id: "tab")
        fixture.engine.goForward(id: "tab")
        try fixture.engine.navigate(id: "tab", url: #require(URL(string: "openarc://settings")))
        #expect(responses.isEmpty)
        #expect(nested == [.cancel, .cancel])
        #expect(fixture.requests.count == 1)
        let request = try #require(fixture.requests.first)
        fixture.engine.resolveJavaScriptDialog(id: request.id, response: .accept(text: nil))
        fixture.engine.resolveJavaScriptDialog(id: request.id, response: .cancel)
        #expect(responses == [.accept(text: nil)])
        #expect(nested == [.cancel, .cancel, .cancel])
        #expect(fixture.finished == [request.id])
    }

    @Test func iframeDialogUsesInitiatingFrameOriginIncludingOpaqueSandbox() async throws {
        let fixture = try DialogWebKitFixture()
        defer { fixture.close() }
        fixture.response = { _ in .cancel }
        let frames = DialogFrameCapture()
        let content = fixture.webView.configuration.userContentController
        content.add(frames, name: "dialogFrame")
        defer { content.removeScriptMessageHandler(forName: "dialogFrame") }
        try await fixture.load(html: """
        <title>Frames</title>
        <iframe srcdoc="<script>confirm('inherited')</script>"></iframe>
        <iframe sandbox="allow-scripts" srcdoc="<script>window.webkit.messageHandlers.dialogFrame.postMessage('opaque')</script>"></iframe>
        """)
        try #require(await fixture.wait { fixture.requests.count == 1 && frames.opaque != nil })
        #expect(fixture.requests.first { $0.message == "inherited" }?.origin == "https://dialog.example")
        // Sandboxed modal policy belongs to WebKit. Use its actual opaque frame
        // metadata to test our delegate without depending on modal admission.
        var answer: Bool?
        try fixture.engine.webView(
            fixture.webView, runJavaScriptConfirmPanelWithMessage: "opaque",
            initiatedByFrame: #require(frames.opaque),
        ) { answer = $0 }
        #expect(answer == false)
        #expect(fixture.requests.first { $0.message == "opaque" }?.origin == String(
            localized: "Unknown origin", table: "Mobile",
        ))
        #expect(fixture.finished.count == 2)
        let pageURL = fixture.states["tab"]?.url
        try fixture.engine.navigate(id: "tab", url: #require(URL(string: "about:srcdoc")))
        #expect(fixture.states["tab"]?.error != nil)
        #expect(fixture.states["tab"]?.url == pageURL)
    }
}

// MARK: - HeldDialogHTTPServer

/// Holds one loopback response so old JavaScript can resume before the next
/// document commits. No remote endpoint or timing-based network race is used.
@MainActor private final class HeldDialogHTTPServer {
    // MARK: Internal

    private(set) var hasRequest = false

    // MARK: Private

    private let listener: NWListener
    private var connections = [NWConnection]()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready: completeStart()
                    case .failed(let error),
                         .waiting(let error): completeStart(error: error)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { connection.cancel()
                            return
                        }
                        connections.append(connection)
                        hasRequest = true
                    }
                }
            }
            listener.start(queue: .main)
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.completeStart(error: URLError(.timedOut))
            }
        }
    }

    func url() throws -> URL {
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/dialog"))
    }

    func release(body: String) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        for connection in connections {
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
        connections.removeAll()
    }

    func stop() {
        completeStart(error: URLError(.cancelled))
        connections.forEach { $0.cancel() }
        connections.removeAll()
        listener.cancel()
    }

    private func completeStart(error: Error? = nil) {
        timeout?.cancel()
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

// MARK: - DialogFrameCapture

@MainActor private final class DialogFrameCapture: NSObject, WKScriptMessageHandler {
    var opaque: WKFrameInfo?

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? String == "opaque" {
            opaque = message.frameInfo
        }
    }
}

// MARK: - DialogWebKitFixture

@MainActor private final class DialogWebKitFixture {
    // MARK: Internal

    let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
    let window: UIWindow
    private(set) var webView: WKWebView!
    var requests = [BrowserMobileJavaScriptDialog]()
    var finished = [UUID]()
    var states = [String: BrowserMobilePageState]()
    var response: ((BrowserMobileJavaScriptDialog) -> BrowserMobileJavaScriptDialogResponse?)?

    // MARK: Private

    private var evaluations = [UUID: Result<String, Error>]()
    private var tasks = [Task<Void, Never>]()

    init() throws {
        let scene = try #require(BrowserMobileTestScene.windowScene)
        self.window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = engine.hostView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        engine.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .state(let id, let state): states[id] = state
            case .closed,
                 .httpAuthenticationFinished,
                 .httpAuthenticationRequested,
                 .openInNewTab: break
            case .javaScriptDialogRequested(let request):
                requests.append(request)
                if let answer = response?(request) {
                    engine.resolveJavaScriptDialog(id: request.id, response: answer)
                }
            case .javaScriptDialogFinished(let id): finished.append(id)
            }
        }
        engine.createTab(id: "tab", url: URL(string: "about:blank")!)
        engine.selectTab(id: "tab")
        let created: WKWebView? = engine.webView(for: "tab")
        do {
            let view = try #require(created)
            self.webView = view
        } catch {
            engine.shutdown()
            window.isHidden = true
            window.rootViewController = nil
            throw error
        }
        engine.setJavaScriptDialogPresentationActive(true)
    }

    func load(html: String = "<title>Dialog fixture</title>") async throws {
        engine.loadHTMLString(html, baseURL: URL(string: "https://dialog.example"), id: "tab")
        try #require(await wait { self.states["tab"]?.isLoading == false })
    }

    func startEvaluation(_ body: String, in view: WKWebView? = nil) -> UUID {
        let id = UUID()
        let target = view ?? webView!
        tasks.append(Task { @MainActor [weak self] in
            do {
                let result = try await target.evaluateJavaScript("JSON.stringify((() => { \(body) })())")
                self?.evaluations[id] = .success(result as? String ?? "undefined")
            } catch {
                self?.evaluations[id] = .failure(error)
            }
        })
        return id
    }

    func result(of id: UUID) async throws -> String {
        try #require(await wait { self.evaluations[id] != nil })
        let completed = evaluations.removeValue(forKey: id)
        return try #require(completed).get()
    }

    func evaluate(_ body: String, in view: WKWebView? = nil) async throws -> String {
        try await result(of: startEvaluation(body, in: view))
    }

    func wait(_ condition: () -> Bool) async -> Bool {
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

    func close() {
        engine.shutdown()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        window.isHidden = true
        window.rootViewController = nil
    }
}
