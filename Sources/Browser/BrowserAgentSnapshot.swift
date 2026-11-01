// BrowserAgentSnapshot.swift

import Foundation

// MARK: - BrowserAgentSnapshot

/// Turns Chromium's accessibility tree into the short outline an agent reads, with
/// a ref on everything it can act on. Refs stay valid for the page they came from.
enum BrowserAgentSnapshot {
    static let maximumLength = 120_000

    private static let interactiveRoles: Set = [
        "button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox", "menuitem",
        "menuitemcheckbox", "menuitemradio", "option", "slider", "spinbutton", "switch", "tab", "treeitem",
    ]
    private static let silentRoles: Set = [
        "none", "generic", "InlineTextBox", "LineBreak", "StaticText", "RootWebArea", "paragraph", "group",
        "presentation", "LabelText", "ListMarker", "Section",
    ]
    private static let reportedStates = ["checked", "selected", "expanded", "disabled", "focused", "required"]

    /// `refs` keeps a page's refs between snapshots, from DOM node to name.
    static func outline(
        fromAXTree tree: [String: Any],
        interactiveOnly: Bool,
        refs: inout [Int: String],
    ) -> String {
        let nodes = tree["nodes"] as? [[String: Any]] ?? []
        var byID = [String: [String: Any]]()
        for node in nodes {
            if let id = node["nodeId"] as? String {
                byID[id] = node
            }
        }
        guard let root = nodes.first(where: { $0["parentId"] == nil }) ?? nodes.first else { return "" }
        var lines = [String]()
        var length = 0

        func visit(_ node: [String: Any], depth: Int) {
            guard length < maximumLength else { return }
            var childDepth = depth
            let isIgnored = node["ignored"] as? Bool ?? false
            let role = (node["role"] as? [String: Any])?["value"] as? String ?? ""
            let name = ((node["name"] as? [String: Any])?["value"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isInteractive = interactiveRoles.contains(role)
            let isShown = !isIgnored && (isInteractive
                || (!interactiveOnly && (!silentRoles.contains(role) || (role == "StaticText" && !name.isEmpty))))
            if isShown {
                var line = String(repeating: "  ", count: depth) + "- " + role
                if !name.isEmpty {
                    line += " \"\(name.prefix(200))\""
                }
                if isInteractive, let backendID = node["backendDOMNodeId"] as? Int {
                    let ref = refs[backendID] ?? "e\(refs.count + 1)"
                    refs[backendID] = ref
                    line += " [ref=\(ref)]"
                }
                if let value = (node["value"] as? [String: Any])?["value"], "\(value)" != "", name != "\(value)" {
                    line += " value=\"\(String(describing: value).prefix(200))\""
                }
                for property in node["properties"] as? [[String: Any]] ?? [] {
                    guard let key = property["name"] as? String, reportedStates.contains(key),
                          let value = (property["value"] as? [String: Any])?["value"]
                    else { continue }
                    if let isOn = value as? Bool {
                        if isOn { line += " [\(key)]" }
                    } else if "\(value)" != "false" {
                        line += " [\(key)=\(value)]"
                    }
                }
                lines.append(line)
                length += line.count + 1
                childDepth += 1
            }
            for childID in node["childIds"] as? [String] ?? [] {
                if let child = byID[childID] {
                    visit(child, depth: childDepth)
                }
            }
        }
        visit(root, depth: 0)
        if length >= maximumLength {
            lines.append("… the page is longer than this snapshot; scroll, or read one part with a selector.")
        }
        return lines.joined(separator: "\n")
    }

    /// A key for Input.dispatchKeyEvent, by the names people and agents use.
    static func keyEvent(named name: String) -> (key: String, code: String, virtualCode: Int, text: String?)? {
        let named: [String: (String, String, Int, String?)] = [
            "enter": ("Enter", "Enter", 13, "\r"), "return": ("Enter", "Enter", 13, "\r"),
            "tab": ("Tab", "Tab", 9, nil), "escape": ("Escape", "Escape", 27, nil), "esc": (
                "Escape",
                "Escape",
                27,
                nil,
            ),
            "backspace": ("Backspace", "Backspace", 8, nil), "delete": ("Delete", "Delete", 46, nil),
            "space": (" ", "Space", 32, " "), "arrowup": ("ArrowUp", "ArrowUp", 38, nil),
            "arrowdown": ("ArrowDown", "ArrowDown", 40, nil), "arrowleft": ("ArrowLeft", "ArrowLeft", 37, nil),
            "arrowright": ("ArrowRight", "ArrowRight", 39, nil), "home": ("Home", "Home", 36, nil),
            "end": ("End", "End", 35, nil), "pageup": ("PageUp", "PageUp", 33, nil),
            "pagedown": ("PageDown", "PageDown", 34, nil),
        ]
        if let key = named[name.lowercased()] {
            return key
        }
        guard name.count == 1, let scalar = name.uppercased().unicodeScalars.first else { return nil }
        return (name, "Key\(name.uppercased())", Int(scalar.value), name)
    }
}
