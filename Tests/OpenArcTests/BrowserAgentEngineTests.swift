// BrowserAgentEngineTests.swift

import AppKit
import Foundation
import Testing

// MARK: - AgentPage

/// The two kinds of page the agent CLI drives: a Chromium page (CEF, the Chrome engine) answers DevTools' DOM and
/// accessibility methods; a WebKit or Ladybird page answers only scripts, screenshots and input. Every test here runs
/// on both, so an action works alike on every engine.
enum AgentPage: String, CaseIterable, CustomTestStringConvertible {
    case devTools
    case scriptsOnly

    var testDescription: String { rawValue }

    /// Answers like the page: `script` stands for the page running a Runtime.evaluate expression.
    @MainActor func answer(
        _ method: String,
        _ params: [String: Any],
        script: (String) -> Any?,
    ) -> String? {
        func json(_ value: Any) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
        }
        switch method {
        case "Runtime.evaluate":
            let value = script(params["expression"] as? String ?? "")
            return json(["result": ["type": "object", "value": value ?? NSNull()]])
        case "Input.dispatchKeyEvent", "Input.dispatchMouseEvent", "Input.insertText", "Page.reload":
            return "{}"
        default:
            break
        }
        guard self == .devTools else { return nil }
        switch method {
        case "DOM.getDocument":
            return json(["root": ["nodeId": 1]])
        case "DOM.querySelector":
            return json(["nodeId": params["selector"] as? String == "#go" ? 5 : 0])
        case "DOM.getContentQuads":
            return json(["quads": [[10, 20, 30, 20, 30, 40, 10, 40]]])
        case "DOM.resolveNode":
            return json(["object": ["objectId": "field"]])
        case "Accessibility.getFullAXTree":
            return json(["nodes": [
                ["nodeId": "1", "role": ["value": "RootWebArea"], "childIds": ["2"]],
                [
                    "nodeId": "2",
                    "parentId": "1",
                    "role": ["value": "button"],
                    "name": ["value": "Go"],
                    "backendDOMNodeId": 7,
                ],
            ]])
        default:
            return "{}"
        }
    }
}

@MainActor private func makeAgent(_ page: AgentPage, script: @escaping (String) -> Any? = { _ in nil })
    -> (BrowserAgentService, FakeBrowserTabDriver)
{
    let driver = FakeBrowserTabDriver()
    let defaults = UserDefaults(suiteName: BrowserTestDefaults.suiteName("OpenArcAgentEngineTests"))!
    let model = BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: InMemorySessionSnapshotStore(loadedSnapshot: BrowserTabSessionSnapshot(tabs: [
            .init(urlString: "https://example.com/form"),
        ])),
        sessionPreferencesStore: InMemorySessionPreferencesStore(storedSelectedTabIndex: 0),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults),
        extensionManager: FakeBrowserExtensionManager(),
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {},
    )
    model.handleContextReady()
    driver.flushPendingCreateEvents()
    for tab in model.tabs {
        driver.emitTabCreationState(id: tab.id, state: .ready)
    }
    driver.devToolsAnswer = { method, params in page.answer(method, params, script: script) }
    let service = BrowserAgentService(models: { [model] }, approveSignIn: { _, _ in false })
    return (service, driver)
}

/// The page's point for an element script: the middle of #go, as the DevTools page's quad has it.
private func elementCenter(_ expression: String) -> Any? {
    expression.contains("getClientRects") ? [20.0, 30.0] : nil
}

@MainActor private func mouseEvents(_ driver: FakeBrowserTabDriver) -> [[String: Any]] {
    driver.devToolsCalls.filter { $0.method == "Input.dispatchMouseEvent" }.map(\.params)
}

// MARK: - BrowserAgentEngineTests

@MainActor struct BrowserAgentEngineTests {
    @Test(arguments: AgentPage.allCases) func aClickPressesTheMiddleOfTheElement(page: AgentPage) async throws {
        let (service, driver) = makeAgent(page, script: elementCenter)
        _ = try await service.handle(method: "click", params: ["selector": "#go"])
        let events = mouseEvents(driver)
        #expect(events.map { $0["type"] as? String } == ["mouseMoved", "mousePressed", "mouseReleased"])
        #expect(events.allSatisfy { $0["x"] as? Double == 20 && $0["y"] as? Double == 30 })
        #expect(events.last?["button"] as? String == "left")
    }

    @Test(arguments: AgentPage.allCases) func aMissingElementSaysSoAlike(page: AgentPage) async {
        let (service, _) = makeAgent(page)
        let error = await #expect(throws: BrowserAgentError.self) {
            _ = try await service.handle(method: "click", params: ["selector": "#nothing"])
        }
        #expect(error?.message == "Nothing matches #nothing.")
    }

    @Test(arguments: AgentPage.allCases) func fillEmptiesTheFieldThenTypes(page: AgentPage) async throws {
        var cleared = false
        let (service, driver) = makeAgent(page) { expression in
            if expression.contains("this.value = ''") {
                cleared = true
                return ["found": true]
            }
            return nil
        }
        _ = try await service.handle(method: "fill", params: ["selector": "#go", "text": "hello"])
        let calls = driver.devToolsCalls.map(\.method)
        if page == .devTools {
            cleared = calls.contains("Runtime.callFunctionOn")
        }
        #expect(cleared)
        #expect(calls.last == "Input.insertText")
        #expect(driver.devToolsCalls.last?.params["text"] as? String == "hello")
    }

    @Test(arguments: AgentPage.allCases) func aSnapshotRefLeadsTheNextClick(page: AgentPage) async throws {
        let (service, driver) = makeAgent(page) { expression in
            if expression.contains("store.byRef") {
                return #"- button "Go" [ref=e1]"#
            }
            if expression.contains(#"byRef.get("e1")"#) {
                return [20.0, 30.0]
            }
            return nil
        }
        let snapshot = try await service.handle(method: "snapshot", params: ["interactive": true]) as? [String: Any]
        #expect((snapshot?["snapshot"] as? String)?.contains(#"- button "Go" [ref=e1]"#) == true)
        _ = try await service.handle(method: "click", params: ["ref": "@e1"])
        #expect(mouseEvents(driver).count == 3)
        if page == .devTools {
            let quads = driver.devToolsCalls.first { $0.method == "DOM.getContentQuads" }
            #expect(quads?.params["backendNodeId"] as? Int == 7)
        }
        let error = await #expect(throws: BrowserAgentError.self) {
            _ = try await service.handle(method: "click", params: ["ref": "@e9"])
        }
        #expect(error?.message == "No @e9 on this page. Take a fresh snapshot.")
    }

    @Test(arguments: AgentPage.allCases) func keysAndTextGoThroughInput(page: AgentPage) async throws {
        let (service, driver) = makeAgent(page)
        _ = try await service.handle(method: "type", params: ["text": "abc"])
        _ = try await service.handle(method: "press", params: ["key": "Enter"])
        let calls = driver.devToolsCalls
        #expect(calls.first { $0.method == "Input.insertText" }?.params["text"] as? String == "abc")
        let keys = calls.filter { $0.method == "Input.dispatchKeyEvent" }.map(\.params)
        #expect(keys.map { $0["type"] as? String } == ["keyDown", "keyUp"])
        #expect(keys.first?["code"] as? String == "Enter")
    }
}

// MARK: - RecordingEngineView

/// The engine's view: records the AppKit events a page without DevTools gets.
private final class RecordingEngineView: NSView, @MainActor NSTextInputClient {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var events = [(type: NSEvent.EventType, point: NSPoint, keyCode: UInt16, characters: String?)]()
    var inserted = [String]()

    override func mouseDown(with event: NSEvent) { record(event) }
    override func mouseUp(with event: NSEvent) { record(event) }
    override func mouseMoved(with event: NSEvent) { record(event) }
    override func keyDown(with event: NSEvent) { record(event) }
    override func keyUp(with event: NSEvent) { record(event) }

    func insertText(_ string: Any, replacementRange _: NSRange) { inserted.append("\(string)") }
    func setMarkedText(_: Any, selectedRange _: NSRange, replacementRange _: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for _: NSPoint) -> Int { 0 }

    private func record(_ event: NSEvent) {
        let isKey = event.type == .keyDown || event.type == .keyUp
        events.append((
            event.type,
            convert(event.locationInWindow, from: nil),
            isKey ? event.keyCode : 0,
            isKey ? event.characters : nil,
        ))
    }
}

// MARK: - BrowserPeerPageInputTests

@MainActor struct BrowserPeerPageInputTests {
    @Test func aClickLandsWhereTheCSSPointIs() async throws {
        let (window, engineView) = makePage()
        defer { window.close() }
        for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
            let answer = try await perform(
                "Input.dispatchMouseEvent",
                ["type": type, "x": 25, "y": 10, "button": "left", "clickCount": 1],
                in: #require(window.contentView),
            )
            #expect(answer == "{}")
        }
        #expect(engineView.events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        #expect(engineView.events.allSatisfy { $0.point == NSPoint(x: 50, y: 20) })
    }

    @Test func keysAndTextReachTheEngineView() async throws {
        let (window, engineView) = makePage()
        defer { window.close() }
        let page = try #require(window.contentView)
        _ = await perform("Input.insertText", ["text": "hello"], in: page)
        _ = await perform(
            "Input.dispatchKeyEvent",
            ["type": "keyDown", "key": "Enter", "code": "Enter", "text": "\r"],
            in: page,
        )
        _ = await perform("Input.dispatchKeyEvent", ["type": "keyUp", "key": "Enter", "code": "Enter"], in: page)
        _ = await perform(
            "Input.dispatchKeyEvent",
            ["type": "rawKeyDown", "key": "ArrowDown", "code": "ArrowDown"],
            in: page,
        )
        #expect(engineView.inserted == ["hello"])
        #expect(engineView.events.map(\.type) == [.keyDown, .keyUp, .keyDown])
        #expect(engineView.events.map(\.keyCode) == [36, 36, 125])
        #expect(engineView.events.first?.characters == "\r")
        #expect(try engineView.events.last?
            .characters == String(Character(#require(UnicodeScalar(NSDownArrowFunctionKey)))))
        #expect(window.firstResponder === engineView)
    }

    @Test func aPageOutOfAWindowTakesNoInput() async {
        let engineView = RecordingEngineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let answer = await perform("Input.insertText", ["text": "x"], in: engineView)
        #expect(answer == nil)
        #expect(engineView.inserted.isEmpty)
        #expect(!BrowserPeerPageInput.handles("DOM.getDocument"))
    }

    /// A page 200 × 100 points wide whose viewport is 100 × 50 CSS pixels: zoomed to 200 %.
    private func perform(_ method: String, _ params: [String: Any], in view: NSView) async -> String? {
        let json = String(data: try! JSONSerialization.data(withJSONObject: params), encoding: .utf8)!
        return await withCheckedContinuation { continuation in
            BrowserPeerPageInput.answer(
                method,
                params: json,
                in: view,
                devTools: { _, _, done in done(#"{"result":{"type":"object","value":[100,50]}}"#) },
                reload: { _ in },
                completion: { continuation.resume(returning: $0) },
            )
        }
    }

    private func makePage() -> (NSWindow, RecordingEngineView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true,
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let engineView = RecordingEngineView(frame: NSRect(x: 50, y: 50, width: 200, height: 100))
        container.addSubview(engineView)
        window.contentView = container
        return (window, engineView)
    }
}
