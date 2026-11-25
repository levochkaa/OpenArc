// BrowserAgentService.swift

import AppKit
import Foundation

// MARK: - BrowserAgentError

struct BrowserAgentError: Error {
    let message: String

    init(_ message: String) { self.message = message }
}

// MARK: - BrowserAgentService

/// What the `openarc` command line and MCP server can do. A signed-in password is
/// typed by the browser after the person agrees and never comes back in a result.
@MainActor final class BrowserAgentService {
    /// Seconds to wait for a DevTools answer; a script may take a while, a stalled page never answers.
    static let devToolsTimeout: Double = 60

    // MARK: Internal

    /// Windows an agent may reach. Incognito windows are left out.
    var models: () -> [BrowserChromeModel]
    /// Asks the person before a saved password goes into a page.
    var approveSignIn: (_ username: String, _ host: String) -> Bool

    var refsByTab = [String: (urlString: String, refs: [Int: String])]()
    var sealedTabs = [String: String]()
    /// Each tab's last outline per scope, so the next snapshot can say what changed.
    var outlinesByTab = [String: (urlString: String, outlines: [String: String])]()

    init(
        models: @escaping () -> [BrowserChromeModel],
        approveSignIn: @escaping (_ username: String, _ host: String) -> Bool,
    ) {
        self.models = models
        self.approveSignIn = approveSignIn
    }

    static func encode(_ value: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])) ??
            Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: Encoding

    static func javaScriptLiteral(_ text: String) -> String? {
        (try? JSONSerialization.data(withJSONObject: [text]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) }
    }

    private static func color(hex: String) -> BrowserSpaceTheme.Color? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return BrowserSpaceTheme.Color(
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255,
        )
    }

    /// Answers one line of the socket protocol.
    func respond(toLine line: String) async -> String {
        guard let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = request["method"] as? String
        else { return Self.encode(["error": "That request is not valid JSON."]) }
        let id = request["id"]
        var response = [String: Any]()
        if let id { response["id"] = id }
        do {
            response["result"] = try await handle(method: method, params: request["params"] as? [String: Any] ?? [:])
        } catch let error as BrowserAgentError {
            response["error"] = error.message
        } catch {
            response["error"] = error.localizedDescription
        }
        return Self.encode(response)
    }

    func handle(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "status": status()
        case "tabs": try tabList(params)
        case "profiles": profileList()
        case "open": try await open(params)
        case "select": try select(params)
        case "close": try close(params)
        case "navigate": try await navigate(params)
        case "back": try await history(params, forward: false)
        case "forward": try await history(params, forward: true)
        case "reload": try await reload(params)
        case "read": try await read(params)
        case "snapshot": try await snapshot(params)
        case "click": try await click(params)
        case "fill": try await fill(params)
        case "type": try await type(params)
        case "press": try await press(params)
        case "scroll": try await scroll(params)
        case "screenshot": try await screenshot(params)
        case "eval": try await evaluate(params)
        case "wait": try await wait(params)
        case "hover": try await hover(params)
        case "dblclick": try await click(params, count: 2)
        case "choose": try await choose(params)
        case "check": try await check(params, on: true)
        case "uncheck": try await check(params, on: false)
        case "upload": try await upload(params)
        case "pdf": try await pdf(params)
        case "viewport": try await viewport(params)
        case "history": try history(params)
        case "notes": try notes(params)
        case "note": try note(params)
        case "downloads": try downloads(params)
        case "download": try await download(params)
        case "logins": logins(params)
        case "signin": try await signIn(params)
        case "bookmarks": try bookmarks(params)
        case "spaces": try spaceList(params)
        case "space.new": try newSpace(params)
        case "space.select": try selectSpace(params)
        case "space.update": try updateSpace(params)
        case "pin": try pin(params)
        case "split": try split(params)
        case "commandbar": try commandBar(params)
        case "commands": try commands(params)
        case "command": try command(params)
        default: throw BrowserAgentError("Unknown command \(method). Run `openarc help`.")
        }
    }

    /// The windows of the profile `params` names by id or name, key window first; every window without one.
    func windows(_ params: [String: Any]) throws -> [BrowserChromeModel] {
        let all = models()
        guard let wanted = (params["profile"] as? String)?.lowercased(), !wanted.isEmpty else { return all }
        let matching = all.filter {
            $0.profile.id.lowercased() == wanted || $0.profile.displayName.lowercased() == wanted
        }
        guard !matching.isEmpty else {
            throw BrowserAgentError("No open window has the profile \(wanted). See `openarc profiles`.")
        }
        return matching
    }

    /// The window an agent's command goes to when it names no tab.
    func window(_ params: [String: Any]) throws -> BrowserChromeModel {
        guard let model = try windows(params).first else { throw BrowserAgentError("OpenArc has no window open.") }
        return model
    }

    func target(_ params: [String: Any]) throws -> (model: BrowserChromeModel, tab: BrowserChromeModel.Tab) {
        if let id = params["tab"] as? String {
            for model in models() {
                if let tab = model.tabs.first(where: { $0.id == id }) {
                    return (model, tab)
                }
            }
            throw BrowserAgentError("No tab \(id). Run `openarc tabs`.")
        }
        guard let model = try windows(params).first, let tab = model.currentTab else {
            throw BrowserAgentError("No tab is selected. Run `openarc open <url>`.")
        }
        return (model, tab)
    }

    /// The tab, with its page created, as a dormant pin has none yet.
    func loadedTarget(_ params: [String: Any]) async throws -> (BrowserChromeModel, BrowserChromeModel.Tab) {
        let (model, tab) = try target(params)
        if tab.creationState == .ready {
            return (model, tab)
        }
        model.selectTab(id: tab.id)
        for _ in 0..<75 {
            try? await Task.sleep(for: .milliseconds(200))
            if let current = model.tabs.first(where: { $0.urlString == tab.urlString && $0.creationState == .ready }) {
                return (model, current)
            }
        }
        throw BrowserAgentError("That tab's page did not start in time.")
    }

    func devTools(
        _ model: BrowserChromeModel,
        _ tabID: String,
        _ method: String,
        _ params: [String: Any] = [:],
    ) async throws -> [String: Any] {
        let json = (try? JSONSerialization.data(withJSONObject: params)).flatMap { String(data: $0, encoding: .utf8) }
        // A page that stopped drawing never answers some methods; the agent hears so instead of waiting forever.
        var timedOut = false
        let result: String? = await withCheckedContinuation { continuation in
            var resumed = false
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.devToolsTimeout))
                guard !resumed else { return }
                resumed = true
                timedOut = true
                continuation.resume(returning: nil)
            }
            model.executeDevTools(method: method, paramsJSON: json ?? "{}", tabID: tabID) { answer in
                guard !resumed else { return }
                resumed = true
                timeout.cancel()
                continuation.resume(returning: answer)
            }
        }
        if timedOut {
            throw BrowserAgentError("The page did not answer \(method) in \(Int(Self.devToolsTimeout)) seconds.")
        }
        guard let result, let data = result.data(using: .utf8),
              let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw BrowserAgentError("The page did not answer \(method).") }
        return dictionary
    }

    func run(_ model: BrowserChromeModel, _ tabID: String, script: String) async throws -> Any? {
        let result = try await devTools(model, tabID, "Runtime.evaluate", [
            "expression": script, "returnByValue": true, "awaitPromise": true,
        ])
        if let details = result["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw BrowserAgentError(
                exception?["description"] as? String ?? details["text"] as? String ?? "The script failed.",
            )
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    func waitForLoad(_ model: BrowserChromeModel, _ tabID: String, timeout: Double = 15) async {
        let start = Date()
        // A navigation may not have started when the first answer comes back.
        try? await Task.sleep(for: .milliseconds(150))
        while Date().timeIntervalSince(start) < timeout {
            // Ladybird keeps the old document until the new one's response arrives, but marks the tab loading at once.
            let loading = model.tabs.first { $0.id == tabID }?.isLoading ?? false
            if !loading,
               let state = try? await run(model, tabID, script: "document.readyState") as? String,
               state == "complete"
            {
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func pageSummary(_ model: BrowserChromeModel, _ tabID: String) -> [String: Any] {
        let tab = model.tabs.first { $0.id == tabID }
        return ["tab": tabID, "title": tab?.title ?? "", "url": tab?.urlString ?? ""]
    }

    func requiredString(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty else {
            throw BrowserAgentError("Missing \(key).")
        }
        return value
    }

    /// Script addresses would get around the scripts being off after a sign-in.
    func webURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = URL(string: trimmed).flatMap { $0.scheme == nil ? nil : $0 }
            ?? BrowserBookmarkEditor.normalizedAddress(trimmed).flatMap(URL.init(string:))
        guard let url = candidate, ["http", "https", "file", "openarc"].contains(url.scheme?.lowercased() ?? "") else {
            throw BrowserAgentError("\(text) is not an address OpenArc will open for an agent.")
        }
        return url
    }

    func snapshot(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        _ = try await devTools(model, tab.id, "Accessibility.enable")
        let tree = try await devTools(model, tab.id, "Accessibility.getFullAXTree")
        var known = refsByTab[tab.id]
        if known?.urlString != tab.urlString {
            known = (tab.urlString, [:])
        }
        let scope: Int? =
            if params["ref"] != nil || params["selector"] != nil {
                try await backendID(of: node(params, model, tab), model, tab.id)
            } else {
                nil
            }
        var refs = known?.refs ?? [:]
        let interactive = params["interactive"] as? Bool ?? false
        let frames = await frameTrees(in: tree, model, tab.id)
        guard let outline = BrowserAgentSnapshot.outline(
            fromAXTree: tree,
            interactiveOnly: interactive,
            refs: &refs,
            scope: scope,
            frames: frames,
        ) else { throw BrowserAgentError("That element is not in the page's accessibility tree.") }
        refsByTab[tab.id] = (tab.urlString, refs)
        // The diff compares with the last outline of the same page, scope and filter.
        let key = "\(interactive) \(params["ref"] ?? "") \(params["selector"] ?? "")"
        var outlines = outlinesByTab[tab.id]
        if outlines?.urlString != tab.urlString {
            outlines = (tab.urlString, [:])
        }
        let previous = outlines?.outlines[key]
        outlines?.outlines[key] = outline
        outlinesByTab[tab.id] = outlines
        var result = pageSummary(model, tab.id)
        result["snapshot"] = outline
        result["diff"] = previous.map { BrowserAgentSnapshot.diff(from: $0, to: outline) } ?? outline
        return result
    }

    // MARK: Acting

    /// A DOM node from a snapshot ref or a CSS selector, in DevTools' terms.
    func node(
        _ params: [String: Any],
        _ model: BrowserChromeModel,
        _ tab: BrowserChromeModel.Tab,
    ) async throws -> [String: Any] {
        _ = try await devTools(model, tab.id, "DOM.enable")
        if let ref = params["ref"] as? String {
            let name = ref.hasPrefix("@") ? String(ref.dropFirst()) : ref
            guard let known = refsByTab[tab.id], known.urlString == tab.urlString,
                  let backendID = known.refs.first(where: { $0.value == name })?.key
            else { throw BrowserAgentError("No \(ref) on this page. Take a fresh snapshot.") }
            return ["backendNodeId": backendID]
        }
        let selector = try requiredString(params, "selector")
        let document = try await devTools(model, tab.id, "DOM.getDocument")
        guard let rootID = (document["root"] as? [String: Any])?["nodeId"] as? Int else {
            throw BrowserAgentError("The page has no document yet.")
        }
        let found = try await devTools(model, tab.id, "DOM.querySelector", ["nodeId": rootID, "selector": selector])
        guard let nodeID = found["nodeId"] as? Int, nodeID != 0 else {
            throw BrowserAgentError("Nothing matches \(selector).")
        }
        return ["nodeId": nodeID]
    }

    func center(
        of node: [String: Any],
        _ model: BrowserChromeModel,
        _ tabID: String,
    ) async throws -> (x: Double, y: Double) {
        _ = try await devTools(model, tabID, "DOM.scrollIntoViewIfNeeded", node)
        let quads = try await devTools(model, tabID, "DOM.getContentQuads", node)
        guard let quad = (quads["quads"] as? [[Double]])?.first, quad.count == 8 else {
            throw BrowserAgentError("That element has no place on screen.")
        }
        return ((quad[0] + quad[2] + quad[4] + quad[6]) / 4, (quad[1] + quad[3] + quad[5] + quad[7]) / 4)
    }

    func click(_ params: [String: Any], count: Int = 1) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        let target = try await node(params, model, tab)
        // A tab behind the shown one draws nothing, so the engine can't aim a pointer press at it; the
        // element gets the same events from a script instead.
        if try await run(model, tab.id, script: "document.visibilityState") as? String == "hidden" {
            _ = try await call(BrowserAgentSnapshot.clickScript, arguments: [count], on: target, model, tab.id)
            await settleAfterClick(model, tab.id)
            return pageSummary(model, tab.id)
        }
        let point = try await center(of: target, model, tab.id)
        var events = [("mouseMoved", 0, 0)]
        for click in 1...count {
            events += [("mousePressed", 1, click), ("mouseReleased", 0, click)]
        }
        for (type, buttons, clickCount) in events {
            var event: [String: Any] = ["type": type, "x": point.x, "y": point.y, "buttons": buttons]
            if type != "mouseMoved" {
                event["button"] = "left"
                event["clickCount"] = clickCount
            }
            _ = try await devTools(model, tab.id, "Input.dispatchMouseEvent", event)
        }
        await settleAfterClick(model, tab.id)
        return pageSummary(model, tab.id)
    }

    /// A click may start a navigation: gives it a moment to show, and waits for the page it started.
    private func settleAfterClick(_ model: BrowserChromeModel, _ tabID: String) async {
        let before = model.tabs.first { $0.id == tabID }?.urlString
        try? await Task.sleep(for: .milliseconds(250))
        let tab = model.tabs.first { $0.id == tabID }
        if tab?.isLoading == true || tab?.urlString != before {
            await waitForLoad(model, tabID)
        }
    }

    // MARK: Private

    private func status() -> [String: Any] {
        [
            "app": "OpenArc",
            "windows": models().count,
            "tabs": models().reduce(0) { $0 + $1.tabs.count },
            "selectedTab": models().first?.selectedTabID as Any,
        ]
    }

    private func tabList(_ params: [String: Any]) throws -> [[String: Any]] {
        let shown = try windows(params)
        return models().enumerated().flatMap { index, model -> [[String: Any]] in
            guard shown.contains(where: { $0 === model }) else { return [] }
            return model.tabs.map { tab in
                [
                    "id": tab.id,
                    "title": tab.title,
                    "url": tab.urlString,
                    "window": index,
                    "profile": model.profile.id,
                    "selected": tab.id == model.selectedTabID,
                    "loaded": tab.creationState == .ready,
                    "pinned": tab.placement != .temporary,
                ] as [String: Any]
            }
        }
    }

    // MARK: Tabs

    private func open(_ params: [String: Any]) async throws -> [String: Any] {
        let url = try webURL(requiredString(params, "url"))
        let model = try window(params)
        let before = Set(model.tabs.map(\.id))
        // A background tab leaves the page the person is looking at on screen.
        let opened = params["background"] as? Bool == true ? model.openURLInBackgroundTab(url) : nil
        if opened == nil {
            model.openURLInNewTab(url)
        }
        for _ in 0..<75 {
            if let tab = model.tabs.first(where: { tab in
                (opened.map { $0 == tab.id } ?? !before.contains(tab.id)) && tab.creationState == .ready
            }) {
                await waitForLoad(model, tab.id)
                return pageSummary(model, tab.id)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw BrowserAgentError("The new tab did not start in time.")
    }

    private func select(_ params: [String: Any]) throws -> [String: Any] {
        let (model, tab) = try target(params)
        model.selectTab(id: tab.id)
        return pageSummary(model, tab.id)
    }

    private func close(_ params: [String: Any]) throws -> [String: Any] {
        let (model, tab) = try target(params)
        model.closeTab(id: tab.id)
        refsByTab[tab.id] = nil
        sealedTabs[tab.id] = nil
        return ["closed": tab.id]
    }

    private func navigate(_ params: [String: Any]) async throws -> [String: Any] {
        let url = try webURL(requiredString(params, "url"))
        let (model, tab) = try await loadedTarget(params)
        model.navigateTab(id: tab.id, toURLString: url.absoluteString)
        await waitForLoad(model, tab.id)
        return pageSummary(model, tab.id)
    }

    private func history(_ params: [String: Any], forward: Bool) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        _ = try await run(model, tab.id, script: forward ? "history.forward()" : "history.back()")
        await waitForLoad(model, tab.id)
        return pageSummary(model, tab.id)
    }

    private func reload(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        _ = try await devTools(model, tab.id, "Page.reload")
        await waitForLoad(model, tab.id)
        return pageSummary(model, tab.id)
    }

    // MARK: Reading

    private func read(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        let selector = params["selector"] as? String
        let source = selector.flatMap { Self.javaScriptLiteral($0) }.map { "document.querySelector(\($0))" }
            ?? "document.body"
        let text = try await run(model, tab.id, script: "(\(source)||{}).innerText||''") as? String ?? ""
        var result = pageSummary(model, tab.id)
        result["text"] = String(text.prefix(BrowserAgentSnapshot.maximumLength))
        return result
    }

    private func screenshot(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        var capture: [String: Any] = [
            "format": "png",
            "captureBeyondViewport": params["fullPage"] as? Bool ?? false,
        ]
        if params["ref"] != nil || params["selector"] != nil {
            capture["clip"] = try await clip(of: node(params, model, tab), model, tab.id)
            capture["captureBeyondViewport"] = true
        }
        let annotated = params["annotate"] as? Bool == true
        var labels = [String]()
        if annotated {
            labels = try await showRefLabels(model, tab)
        }
        let shot = try await devTools(model, tab.id, "Page.captureScreenshot", capture)
        if annotated {
            _ = try? await run(model, tab.id, script: BrowserAgentSnapshot.removeLabelsScript)
        }
        guard let base64 = shot["data"] as? String, let data = Data(base64Encoded: base64) else {
            throw BrowserAgentError("The page gave no picture. A background tab may need `openarc select` first.")
        }
        let path = params["path"] as? String ?? FileManager.default
            .temporaryDirectory
            .appendingPathComponent("openarc-\(UUID().uuidString.prefix(8)).png")
            .path
        try data.write(to: URL(fileURLWithPath: path))
        var result = pageSummary(model, tab.id)
        result["path"] = path
        if annotated {
            result["refs"] = labels
        }
        if params["includeData"] as? Bool == true {
            result["data"] = base64
        }
        return result
    }

    private func evaluate(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        if let sealedURL = sealedTabs[tab.id] {
            guard sealedURL != tab.urlString else {
                throw BrowserAgentError(
                    "Scripts are off on this page after a sign-in filled its password. Load another page first.",
                )
            }
            sealedTabs[tab.id] = nil
        }
        let value = try await run(model, tab.id, script: requiredString(params, "script"))
        return ["value": value ?? NSNull()]
    }

    private func wait(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        let timeout = (params["timeout"] as? Double) ?? 15
        if let ms = params["ms"] as? Double {
            try? await Task.sleep(for: .milliseconds(Int(min(ms, 60000))))
            return ["waited": ms]
        }
        let check: String
        if let selector = (params["selector"] as? String).flatMap(Self.javaScriptLiteral) {
            check = "!!document.querySelector(\(selector))"
        } else if let text = (params["text"] as? String).flatMap(Self.javaScriptLiteral) {
            check = "(document.body.innerText||'').includes(\(text))"
        } else {
            await waitForLoad(model, tab.id, timeout: timeout)
            return pageSummary(model, tab.id)
        }
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if try await run(model, tab.id, script: check) as? Bool == true {
                return pageSummary(model, tab.id)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw BrowserAgentError("Nothing matched in \(Int(timeout)) seconds.")
    }

    private func fill(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        let text = params["text"] as? String ?? ""
        let resolved = try await devTools(model, tab.id, "DOM.resolveNode", node(params, model, tab))
        guard let objectID = (resolved["object"] as? [String: Any])?["objectId"] as? String else {
            throw BrowserAgentError("That element is gone. Take a fresh snapshot.")
        }
        _ = try await devTools(model, tab.id, "Runtime.callFunctionOn", [
            "objectId": objectID,
            "functionDeclaration": """
            function() {
              this.focus();
              if ('value' in this) {
                this.value = '';
                this.dispatchEvent(new Event('input', {bubbles: true}));
              } else if (this.isContentEditable) {
                this.textContent = '';
              }
            }
            """,
        ])
        _ = try await devTools(model, tab.id, "Input.insertText", ["text": text])
        return pageSummary(model, tab.id)
    }

    private func type(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        _ = try await devTools(model, tab.id, "Input.insertText", ["text": requiredString(params, "text")])
        return pageSummary(model, tab.id)
    }

    private func press(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        let name = try requiredString(params, "key")
        guard let key = BrowserAgentSnapshot.keyEvent(named: name) else {
            throw BrowserAgentError("Unknown key \(name).")
        }
        var event: [String: Any] = [
            "type": key.text == nil ? "rawKeyDown" : "keyDown",
            "key": key.key,
            "code": key.code,
            "windowsVirtualKeyCode": key.virtualCode,
            "nativeVirtualKeyCode": key.virtualCode,
        ]
        if let text = key.text { event["text"] = text }
        _ = try await devTools(model, tab.id, "Input.dispatchKeyEvent", event)
        event["type"] = "keyUp"
        event["text"] = nil
        _ = try await devTools(model, tab.id, "Input.dispatchKeyEvent", event)
        return pageSummary(model, tab.id)
    }

    private func scroll(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        _ = try await devTools(model, tab.id, "Input.dispatchMouseEvent", [
            "type": "mouseWheel", "x": 200, "y": 200,
            "deltaX": params["dx"] as? Double ?? 0,
            "deltaY": params["dy"] as? Double ?? 600,
        ])
        return pageSummary(model, tab.id)
    }

    // MARK: Passwords

    /// Names only: the saved sign-ins for a site, never their passwords.
    private func logins(_ params: [String: Any]) -> [[String: Any]] {
        guard let store = (try? window(params))?.passwordStore else { return [] }
        let host = (params["host"] as? String)?.lowercased()
        return store.allLogins()
            .filter { login in host.map { login.host.lowercased().contains($0) } ?? true }
            .map { ["origin": $0.origin, "username": $0.username] }
    }

    private func signIn(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        guard let store = model.passwordStore,
              let origin = BrowserChromeModel.passwordOrigin(ofURLString: tab.urlString)
        else { throw BrowserAgentError("Passwords are not available on this page.") }
        let saved = store.allLogins().filter { $0.origin == origin }
        let wanted = params["username"] as? String
        guard let login = wanted.map({ name in saved.first { $0.username == name } }) ?? saved.first else {
            throw BrowserAgentError("No saved sign-in for \(origin). See `openarc logins`.")
        }
        guard saved.count == 1 || wanted != nil else {
            let names = saved.map(\.username).joined(separator: ", ")
            throw BrowserAgentError("Several sign-ins for \(origin): \(names). Pass one as username.")
        }
        guard approveSignIn(login.username, login.host) else {
            throw BrowserAgentError("The person declined this sign-in.")
        }
        guard let password = store.password(for: login) else {
            throw BrowserAgentError("The password could not be read.")
        }
        guard model.fillPasswordInMainFrame(
            username: login.username,
            password: password,
            origin: origin,
            tabID: tab.id,
        ) else {
            throw BrowserAgentError("This page has no frame to sign in on.")
        }
        // The value now sits in the page, so scripts can't read it back from here.
        sealedTabs[tab.id] = tab.urlString
        return ["signedInAs": login.username, "origin": origin]
    }

    // MARK: Browser data

    private func bookmarks(_ params: [String: Any]) throws -> [[String: Any]] {
        let model = try window(params)
        let query = (params["query"] as? String)?.lowercased()
        func flatten(_ items: [BrowserBookmarkItem], folder: String) -> [[String: Any]] {
            items.flatMap { item -> [[String: Any]] in
                if item.isFolder {
                    return flatten(
                        item.children,
                        folder: folder.isEmpty
                            ? item.displayTitle
                            : "\(folder)/\(item.displayTitle)",
                    )
                }
                let text = "\(item.displayTitle) \(item.urlString ?? "")".lowercased()
                guard query.map(text.contains) ?? true else { return [] }
                return [["title": item.displayTitle, "url": item.urlString ?? "", "folder": folder]]
            }
        }
        return flatten(model.bookmarksModel.bookmarkBarItems, folder: "")
    }

    // MARK: Spaces and layout

    private func spaceList(_ params: [String: Any]) throws -> [[String: Any]] {
        let model = try window(params)
        return model.spaces.map {
            ["id": $0.id, "title": $0.title, "icon": $0.systemImageName, "selected": $0.id == model.selectedSpaceID]
        }
    }

    private func space(_ params: [String: Any], _ model: BrowserChromeModel) throws -> BrowserChromeModel.Space {
        let wanted = try requiredString(params, "space")
        guard let space = model.spaces.first(where: { $0.id == wanted || $0.title.lowercased() == wanted.lowercased() })
        else { throw BrowserAgentError("No Space \(wanted). See `openarc spaces`.") }
        return space
    }

    /// A Space with a title, an optional icon and a theme from one color, as #rrggbb.
    private func newSpace(_ params: [String: Any]) throws -> [String: Any] {
        let model = try window(params)
        guard model.supportsSpaces else { throw BrowserAgentError("This window has no Spaces.") }
        model.createNewSpace()
        guard let id = model.selectedSpaceID else { throw BrowserAgentError("The Space was not made.") }
        if let title = params["title"] as? String {
            model.setTitle(title, forSpaceID: id)
        }
        if let icon = params["icon"] as? String {
            model.setIcon(icon, forSpaceID: id)
        }
        if let hex = params["color"] as? String, let color = Self.color(hex: hex) {
            _ = model.setTheme(BrowserSpaceTheme(key: color, colorCount: 3, wheel: .analogous), forSpaceID: id)
        }
        return ["id": id]
    }

    private func updateSpace(_ params: [String: Any]) throws -> [String: Any] {
        let model = try window(params)
        let space = try space(params, model)
        if let title = params["title"] as? String {
            model.setTitle(title, forSpaceID: space.id)
        }
        if let icon = params["icon"] as? String {
            model.setIcon(icon, forSpaceID: space.id)
        }
        if let hex = params["color"] as? String, let color = Self.color(hex: hex) {
            _ = model.setTheme(BrowserSpaceTheme(key: color, colorCount: 3, wheel: .analogous), forSpaceID: space.id)
        }
        return ["updated": space.id]
    }

    private func selectSpace(_ params: [String: Any]) throws -> [String: Any] {
        let model = try window(params)
        let space = try space(params, model)
        model.selectSpace(id: space.id)
        return ["selected": space.id]
    }

    private func pin(_ params: [String: Any]) throws -> [String: Any] {
        let (model, tab) = try target(params)
        model.togglePinned(forTabID: tab.id)
        let pinned = model.tabs.first { $0.id == tab.id }?.placement != .temporary
        return ["tab": tab.id, "pinned": pinned]
    }

    private func split(_ params: [String: Any]) throws -> [String: Any] {
        let url = try webURL(requiredString(params, "url"))
        guard try window(params).openURLInSplitView(url) else {
            throw BrowserAgentError("Split View is not available here.")
        }
        return ["split": url.absoluteString]
    }

    /// Shows the command bar with `query` typed in it, or closes it.
    private func commandBar(_ params: [String: Any]) throws -> [String: Any] {
        let model = try window(params)
        if params["close"] as? Bool == true {
            model.dismissCommandBar()
            return ["open": false]
        }
        if !model.commandBarModel.isPresented {
            model.presentCommandBar()
        }
        model.commandBarModel.query = params["query"] as? String ?? ""
        return [
            "open": model.commandBarModel.isPresented,
            "results": model.commandBarModel.suggestions.map(\.displayText),
        ]
    }

    private func commands(_ params: [String: Any]) throws -> [[String: Any]] {
        let model = try window(params)
        return BrowserCommandID.allCases.map { id in
            [
                "id": id.rawValue,
                "title": model.shortcutStore.descriptor(for: id).menuTitle,
                "available": model.isCommandBarActionAvailable(id),
            ]
        }
    }

    private func command(_ params: [String: Any]) throws -> [String: Any] {
        let name = try requiredString(params, "id")
        guard let id = BrowserCommandID(rawValue: name) else {
            throw BrowserAgentError("Unknown command \(name). See `openarc commands`.")
        }
        let model = try window(params)
        guard model.isCommandBarActionAvailable(id) else {
            throw BrowserAgentError("\(name) is not available right now.")
        }
        model.performToolbarCommand(id)
        return ["ran": name]
    }
}
