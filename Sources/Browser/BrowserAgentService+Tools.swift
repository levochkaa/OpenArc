// BrowserAgentService+Tools.swift

import AppKit
import Foundation

// MARK: - Page tools

extension BrowserAgentService {
    /// The most child frames a snapshot reads, so a page of ads can't stall it.
    static let maximumFrames = 20
    /// The most labels an annotated screenshot draws.
    static let maximumLabels = 300

    func backendID(of node: [String: Any], _ model: BrowserChromeModel, _ tabID: String) async throws -> Int {
        if let id = node["backendNodeId"] as? Int {
            return id
        }
        let described = try await devTools(model, tabID, "DOM.describeNode", node)
        guard let id = (described["node"] as? [String: Any])?["backendNodeId"] as? Int else {
            throw BrowserAgentError("That element is gone. Take a fresh snapshot.")
        }
        return id
    }

    /// The accessibility trees of the page's same-site frames, by their frame element's node. A cross-site
    /// frame runs in another process, which this tab's DevTools session doesn't reach, and is left out.
    func frameTrees(
        in tree: [String: Any],
        _ model: BrowserChromeModel,
        _ tabID: String,
    ) async -> [Int: [String: Any]] {
        let frameElements = (tree["nodes"] as? [[String: Any]] ?? []).compactMap { node -> Int? in
            guard (node["role"] as? [String: Any])?["value"] as? String == "Iframe" else { return nil }
            return node["backendDOMNodeId"] as? Int
        }
        var trees = [Int: [String: Any]]()
        for element in frameElements.prefix(Self.maximumFrames) {
            guard let described = try? await devTools(model, tabID, "DOM.describeNode", ["backendNodeId": element]),
                  let frameID = (described["node"] as? [String: Any])?["frameId"] as? String,
                  var frameTree = try? await devTools(model, tabID, "Accessibility.getFullAXTree", ["frameId": frameID])
            else { continue }
            // A frame builds its tree a moment after the page turns accessibility on.
            if (frameTree["nodes"] as? [Any] ?? []).count < 2 {
                try? await Task.sleep(for: .milliseconds(250))
                frameTree = await (try? devTools(model, tabID, "Accessibility.getFullAXTree", ["frameId": frameID]))
                    ?? frameTree
            }
            guard !(frameTree["nodes"] as? [Any] ?? []).isEmpty else { continue }
            trees[element] = frameTree
        }
        return trees
    }

    /// A screenshot clip around an element, in page coordinates.
    func clip(of node: [String: Any], _ model: BrowserChromeModel, _ tabID: String) async throws -> [String: Any] {
        _ = try await devTools(model, tabID, "DOM.scrollIntoViewIfNeeded", node)
        let quads = try await devTools(model, tabID, "DOM.getContentQuads", node)
        guard let quad = (quads["quads"] as? [[Double]])?.first, quad.count == 8 else {
            throw BrowserAgentError("That element has no place on screen.")
        }
        let xs = stride(from: 0, to: 8, by: 2).map { quad[$0] }
        let ys = stride(from: 1, to: 8, by: 2).map { quad[$0] }
        let metrics = try await devTools(model, tabID, "Page.getLayoutMetrics")
        let viewport = metrics["cssVisualViewport"] as? [String: Any]
        let pageX = viewport?["pageX"] as? Double ?? 0
        let pageY = viewport?["pageY"] as? Double ?? 0
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard width >= 1, height >= 1 else { throw BrowserAgentError("That element has no size.") }
        return [
            "x": (xs.min() ?? 0) + pageX,
            "y": (ys.min() ?? 0) + pageY,
            "width": width,
            "height": height,
            "scale": 1,
        ]
    }

    /// Takes an interactive snapshot and draws each ref's box and name over the page, for the
    /// screenshot that follows. Returns the refs drawn.
    func showRefLabels(_ model: BrowserChromeModel, _ tab: BrowserChromeModel.Tab) async throws -> [String] {
        _ = try await snapshot(["tab": tab.id, "interactive": true])
        guard let refs = refsByTab[tab.id]?.refs else { return [] }
        var boxes = [[String: Any]]()
        for (backendID, ref) in refs.sorted(by: { $0.value.localizedStandardCompare($1.value) == .orderedAscending }) {
            guard boxes.count < Self.maximumLabels,
                  let quads = try? await devTools(model, tab.id, "DOM.getContentQuads", ["backendNodeId": backendID]),
                  let quad = (quads["quads"] as? [[Double]])?.first, quad.count == 8
            else { continue }
            let xs = stride(from: 0, to: 8, by: 2).map { quad[$0] }
            let ys = stride(from: 1, to: 8, by: 2).map { quad[$0] }
            boxes.append([
                "ref": ref,
                "x": xs.min() ?? 0, "y": ys.min() ?? 0,
                "width": (xs.max() ?? 0) - (xs.min() ?? 0), "height": (ys.max() ?? 0) - (ys.min() ?? 0),
            ])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: boxes),
              let json = String(data: data, encoding: .utf8)
        else { return [] }
        _ = try await run(model, tab.id, script: BrowserAgentSnapshot.showLabelsScript(boxesJSON: json))
        return boxes.compactMap { $0["ref"] as? String }
    }

    func hover(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        let point = try await center(of: node(params, model, tab), model, tab.id)
        _ = try await devTools(model, tab.id, "Input.dispatchMouseEvent", [
            "type": "mouseMoved", "x": point.x, "y": point.y, "buttons": 0,
        ])
        return pageSummary(model, tab.id)
    }

    /// Runs `function` with the element as `this` and returns its value.
    func call(
        _ function: String,
        arguments: [Any] = [],
        on node: [String: Any],
        _ model: BrowserChromeModel,
        _ tabID: String,
    ) async throws -> Any? {
        if let expression = node[Self.scriptNodeKey] as? String {
            let argumentsJSON = (try? JSONSerialization.data(withJSONObject: arguments))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let answer = try await run(model, tabID, script: """
            (() => { const e = \(expression); if (!e) return {found: false};
            return {found: true, value: (\(function)).apply(e, \(argumentsJSON))}; })()
            """) as? [String: Any]
            guard answer?["found"] as? Bool == true else {
                throw BrowserAgentError(node[Self.scriptNodeMissingKey] as? String ?? "That element is gone.")
            }
            return answer?["value"]
        }
        let resolved = try await devTools(model, tabID, "DOM.resolveNode", node)
        guard let objectID = (resolved["object"] as? [String: Any])?["objectId"] as? String else {
            throw BrowserAgentError("That element is gone. Take a fresh snapshot.")
        }
        let result = try await devTools(model, tabID, "Runtime.callFunctionOn", [
            "objectId": objectID,
            "functionDeclaration": function,
            "arguments": arguments.map { ["value": $0] },
            "returnByValue": true,
        ])
        if let details = result["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw BrowserAgentError(exception?["description"] as? String ?? "The element refused that.")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    /// Picks options of a list box by value or by their text.
    func choose(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        let values = params["values"] as? [String] ?? (params["value"] as? String).map { [$0] } ?? []
        guard !values.isEmpty else { throw BrowserAgentError("Missing value.") }
        let chosen = try await call(
            """
            function(wanted) {
              if (!(this instanceof HTMLSelectElement)) throw new Error('That element is not a list box.');
              const options = [...this.options];
              const picked = wanted.map(w => options.find(o => o.value === w)
                || options.find(o => o.label.trim() === w) || options.find(o => o.label.trim().includes(w)));
              const missing = wanted.filter((w, i) => !picked[i]);
              if (missing.length) throw new Error('No option ' + missing.join(', ') + '. Options: '
                + options.map(o => o.label.trim()).join(', '));
              if (!this.multiple && picked.length > 1) throw new Error('This list box takes one option.');
              for (const o of options) o.selected = picked.includes(o);
              this.dispatchEvent(new Event('input', {bubbles: true}));
              this.dispatchEvent(new Event('change', {bubbles: true}));
              return picked.map(o => o.value);
            }
            """,
            arguments: [values],
            on: node(params, model, tab),
            model,
            tab.id,
        )
        var result = pageSummary(model, tab.id)
        result["selected"] = chosen ?? []
        return result
    }

    /// Clicks a check box, radio button or switch when it isn't already in the wanted state.
    func check(_ params: [String: Any], on wanted: Bool) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        let state = """
        function() {
          if ('checked' in this && (this.type === 'checkbox' || this.type === 'radio')) return this.checked;
          const aria = this.getAttribute('aria-checked') ?? this.getAttribute('aria-pressed');
          if (aria !== null) return aria === 'true';
          throw new Error('That element is not a check box, radio button or switch.');
        }
        """
        let target = try await node(params, model, tab)
        if try await call(state, on: target, model, tab.id) as? Bool != wanted {
            _ = try await click(params)
            guard try await call(state, on: target, model, tab.id) as? Bool == wanted else {
                throw BrowserAgentError("The page kept it \(wanted ? "unchecked" : "checked").")
            }
        }
        var result = pageSummary(model, tab.id)
        result["checked"] = wanted
        return result
    }

    /// Puts files into a file field, as if the person picked them.
    func upload(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        let files = params["files"] as? [String] ?? []
        guard !files.isEmpty else { throw BrowserAgentError("Missing files.") }
        for file in files where !(file.hasPrefix("/") && FileManager.default.fileExists(atPath: file)) {
            throw BrowserAgentError("No file at \(file). Give full paths.")
        }
        var request = try await node(params, model, tab)
        request["files"] = files
        _ = try await devTools(model, tab.id, "DOM.setFileInputFiles", request)
        var result = pageSummary(model, tab.id)
        result["files"] = files
        return result
    }

    /// Prints the page to a PDF file.
    func pdf(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        var options: [String: Any] = ["printBackground": true, "landscape": params["landscape"] as? Bool ?? false]
        if let ranges = params["pageRanges"] as? String {
            options["pageRanges"] = ranges
        }
        let printed = try await devTools(model, tab.id, "Page.printToPDF", options)
        guard let base64 = printed["data"] as? String, let data = Data(base64Encoded: base64) else {
            throw BrowserAgentError("The page gave no PDF.")
        }
        let path = params["path"] as? String ?? FileManager.default
            .temporaryDirectory
            .appendingPathComponent("openarc-\(UUID().uuidString.prefix(8)).pdf")
            .path
        try data.write(to: URL(fileURLWithPath: path))
        var result = pageSummary(model, tab.id)
        result["path"] = path
        result["bytes"] = data.count
        return result
    }

    /// Lays the page out at a width and height, as a phone or a small window would; `reset` undoes it.
    func viewport(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        if params["reset"] as? Bool == true {
            _ = try await devTools(model, tab.id, "Emulation.clearDeviceMetricsOverride")
            return pageSummary(model, tab.id)
        }
        guard let width = params["width"] as? Double, let height = params["height"] as? Double,
              (100...10000).contains(width), (100...10000).contains(height)
        else { throw BrowserAgentError("Give a width and a height between 100 and 10000.") }
        let mobile = params["mobile"] as? Bool ?? false
        _ = try await devTools(model, tab.id, "Emulation.setDeviceMetricsOverride", [
            "width": Int(width), "height": Int(height), "deviceScaleFactor": mobile ? 3 : 0, "mobile": mobile,
        ])
        var result = pageSummary(model, tab.id)
        result["viewport"] = ["width": Int(width), "height": Int(height), "mobile": mobile]
        return result
    }
}

// MARK: - Browser data

extension BrowserAgentService {
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func limit(_ params: [String: Any], default fallback: Int, maximum: Int = 200) -> Int {
        let value = (params["limit"] as? Int) ?? (params["limit"] as? Double).map { Int($0) } ?? fallback
        return min(max(value, 1), maximum)
    }

    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// The profiles with open windows; `--profile` picks one for a command.
    func profileList() -> [[String: Any]] {
        var seen = [String: [String: Any]]()
        var order = [String]()
        for model in models() {
            let id = model.profile.id
            if var entry = seen[id] {
                entry["windows"] = (entry["windows"] as? Int ?? 0) + 1
                seen[id] = entry
            } else {
                order.append(id)
                seen[id] = [
                    "id": id,
                    "name": model.profile.displayName,
                    "default": model.profile.isDefault,
                    "windows": 1,
                    "tabs": model.tabs.count,
                    "selected": order.count == 1,
                ]
            }
        }
        return order.compactMap { seen[$0] }
    }

    /// Visited pages: the best matches of a query, or the latest.
    func history(_ params: [String: Any]) throws -> [[String: Any]] {
        let model = try window(params)
        let query = params["query"] as? String ?? ""
        return model.historyPages(matching: query, maximumCount: Self.limit(params, default: 20)).map { page in
            var entry: [String: Any] = [
                "title": page.title,
                "url": page.urlString,
                "visits": page.visitCount,
            ]
            if page.lastVisit > 0 {
                entry["lastVisit"] = Self.date(Date(timeIntervalSince1970: page.lastVisit))
            }
            return entry
        }
    }

    /// The person's notes: those matching a query, or the latest edited. Read-only.
    func notes(_ params: [String: Any]) throws -> [[String: Any]] {
        let model = try window(params)
        guard model.supportsNotes else { return [] }
        let store = model.notesStore
        let limit = Self.limit(params, default: 20)
        let query = (params["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let found = query.isEmpty
            ? Array(store.notes.filter { !$0.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
            : store.search(query, limit: limit)
        return found.map { note in
            [
                "id": note.id,
                "title": note.displayTitle,
                "updated": Self.date(note.updatedAt),
                "snippet": (query.isEmpty ? nil : store.snippet(for: note, matching: query))
                    ?? String(note.plainText.replacingOccurrences(of: "\n", with: " ").prefix(160)),
            ]
        }
    }

    func note(_ params: [String: Any]) throws -> [String: Any] {
        let model = try window(params)
        let id = try requiredString(params, "id")
        guard model.supportsNotes, let note = model.notesStore.note(id: id) else {
            throw BrowserAgentError("No note \(id). See `openarc notes`.")
        }
        return [
            "id": note.id,
            "title": note.displayTitle,
            "created": Self.date(note.createdAt),
            "updated": Self.date(note.updatedAt),
            "markdown": note.markdown,
        ]
    }

    /// The window's downloads, running ones included, newest first.
    func downloads(_ params: [String: Any]) throws -> [[String: Any]] {
        let model = try window(params)
        return model.downloadsModel
            .items
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(Self.limit(params, default: 20))
            .map { item in
                var entry: [String: Any] = [
                    "id": item.id,
                    "file": item.fileName,
                    "url": item.urlString,
                    "state": item.state.rawValue,
                    "receivedBytes": item.receivedBytes,
                    "totalBytes": item.totalBytes,
                    "started": Self.date(item.startedAt),
                ]
                if let path = item.fullPath, !path.isEmpty {
                    entry["path"] = path
                }
                return entry
            }
    }

    /// Fetches an address with the cookies the page's profile has for it, and saves the answer.
    func download(_ params: [String: Any]) async throws -> [String: Any] {
        let (model, tab) = try await loadedTarget(params)
        let text = try requiredString(params, "url")
        guard let url = URL(string: text, relativeTo: URL(string: tab.urlString))?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { throw BrowserAgentError("\(text) is not a web address.") }
        let cookies = try await devTools(model, tab.id, "Network.getCookies", ["urls": [url.absoluteString]])
        let header = (cookies["cookies"] as? [[String: Any]] ?? [])
            .compactMap { cookie -> String? in
                guard let name = cookie["name"] as? String, let value = cookie["value"] as? String else { return nil }
                return "\(name)=\(value)"
            }
            .joined(separator: "; ")
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        if !header.isEmpty {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        if let agent = try? await run(model, tab.id, script: "navigator.userAgent") as? String {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        if URL(string: tab.urlString)?.host == url.host {
            request.setValue(tab.urlString, forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let name = response.suggestedFilename ?? url.lastPathComponent
        let path = params["path"] as? String ?? FileManager.default
            .temporaryDirectory
            .appendingPathComponent("openarc-\(UUID().uuidString.prefix(8))-\(name.isEmpty ? "download" : name)")
            .path
        try data.write(to: URL(fileURLWithPath: path))
        var result: [String: Any] = [
            "path": path,
            "url": url.absoluteString,
            "status": http?.statusCode ?? 0,
            "bytes": data.count,
            "file": name,
        ]
        if let type = http?.value(forHTTPHeaderField: "Content-Type") {
            result["contentType"] = type
        }
        return result
    }
}
