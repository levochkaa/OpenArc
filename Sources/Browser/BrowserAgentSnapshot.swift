// BrowserAgentSnapshot.swift

import Foundation

// MARK: - BrowserAgentSnapshot

/// Turns Chromium's accessibility tree into the short outline an agent reads, with
/// a ref on everything it can act on. Refs stay valid for the page they came from.
enum BrowserAgentSnapshot {
    static let maximumLength = 120_000

    /// Presses an element `count` times with the events a person's click sends, for a page that is not drawn.
    static let clickScript = """
    function(count) {
      this.scrollIntoView({block: 'center', inline: 'center'});
      const r = this.getBoundingClientRect();
      const base = {bubbles: true, cancelable: true, composed: true, view: this.ownerDocument.defaultView,
        clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0};
      const pointer = {pointerId: 1, pointerType: 'mouse', isPrimary: true};
      for (let i = 1; i <= count; i++) {
        this.dispatchEvent(new PointerEvent('pointerdown', {...base, ...pointer, buttons: 1, detail: i}));
        this.dispatchEvent(new MouseEvent('mousedown', {...base, buttons: 1, detail: i}));
        if (i === 1 && typeof this.focus === 'function') this.focus();
        this.dispatchEvent(new PointerEvent('pointerup', {...base, ...pointer, detail: i}));
        this.dispatchEvent(new MouseEvent('mouseup', {...base, detail: i}));
        // click() also runs what a click does by default: follows a link, toggles a check box.
        if (i === 1 && typeof this.click === 'function') this.click();
        else this.dispatchEvent(new MouseEvent('click', {...base, detail: i}));
      }
      if (count === 2) this.dispatchEvent(new MouseEvent('dblclick', {...base, detail: 2}));
      return true;
    }
    """

    static let removeLabelsScript = "document.getElementById('__openarc_refs')?.remove(), true"

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
        outline(fromAXTree: tree, interactiveOnly: interactiveOnly, refs: &refs, scope: nil, frames: [:]) ?? ""
    }

    /// The outline of the element with DOM node `scope`, or the whole page; nil when that element has no
    /// accessibility node. `frames` holds the trees of child frames by their frame element's DOM node, and
    /// each is shown under its frame.
    static func outline(
        fromAXTree tree: [String: Any],
        interactiveOnly: Bool,
        refs: inout [Int: String],
        scope: Int?,
        frames: [Int: [String: Any]],
    ) -> String? {
        var byID = [String: [String: Any]]()
        func index(_ tree: [String: Any], prefix: String) -> [String: Any]? {
            let nodes = tree["nodes"] as? [[String: Any]] ?? []
            for var node in nodes {
                guard let id = node["nodeId"] as? String else { continue }
                // Frames number their nodes from 1 too.
                node["nodeId"] = prefix + id
                node["childIds"] = (node["childIds"] as? [String] ?? []).map { prefix + $0 }
                byID[prefix + id] = node
            }
            guard let root = nodes.first(where: { $0["parentId"] == nil }) ?? nodes.first,
                  let id = root["nodeId"] as? String else { return nil }
            return byID[prefix + id]
        }
        guard let pageRoot = index(tree, prefix: "") else { return "" }
        var frameRoots = [Int: [String: Any]]()
        for (number, element) in frames.keys.sorted().enumerated() {
            if let frameTree = frames[element], let root = index(frameTree, prefix: "f\(number + 1):") {
                frameRoots[element] = root
            }
        }
        var root = pageRoot
        if let scope {
            guard let scoped = byID.values.first(where: { $0["backendDOMNodeId"] as? Int == scope }) else {
                return nil
            }
            root = scoped
        }
        var lines = [String]()
        var length = 0
        var nextRef = (refs.values.compactMap { Int($0.dropFirst()) }.max() ?? 0) + 1

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
                    let ref: String
                    if let known = refs[backendID] {
                        ref = known
                    } else {
                        ref = "e\(nextRef)"
                        nextRef += 1
                    }
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
            if role == "Iframe", let element = node["backendDOMNodeId"] as? Int, let frameRoot = frameRoots[element] {
                if !isShown, !interactiveOnly {
                    lines.append(String(repeating: "  ", count: depth) + "- Iframe")
                    childDepth += 1
                }
                visit(frameRoot, depth: interactiveOnly ? depth : childDepth)
            }
        }
        visit(root, depth: 0)
        if length >= maximumLength {
            lines.append("… the page is longer than this snapshot; read one part with a selector or a ref.")
        }
        return lines.joined(separator: "\n")
    }

    /// The lines that changed between two outlines: `+` for new ones, `-` for gone ones, each under
    /// the nearest unchanged line above it for context.
    static func diff(from old: String, to new: String) -> String {
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        let changes = after.difference(from: before)
        guard !changes.isEmpty else { return "(no changes)" }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var output = [String]()
        var context: String?
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < before.count || newIndex < after.count {
            let line: String
            if removed.contains(oldIndex) {
                line = "- " + before[oldIndex]
                oldIndex += 1
            } else if inserted.contains(newIndex) {
                line = "+ " + after[newIndex]
                newIndex += 1
            } else {
                context = after[newIndex]
                oldIndex += 1
                newIndex += 1
                continue
            }
            if let shown = context {
                output.append("  " + shown)
                context = nil
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    /// Draws each box from a JSON list of `{ref, x, y, width, height}` in viewport coordinates.
    static func showLabelsScript(boxesJSON: String) -> String {
        """
        (() => {
          document.getElementById('__openarc_refs')?.remove();
          const layer = document.createElement('div');
          layer.id = '__openarc_refs';
          layer.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none';
          for (const b of \(boxesJSON)) {
            const box = document.createElement('div');
            box.style.cssText = `position:absolute;left:${b.x}px;top:${b.y}px;width:${b.width}px;`
              + `height:${b.height}px;outline:2px solid #e5484d;box-sizing:border-box`;
            const label = document.createElement('span');
            label.textContent = b.ref;
            label.style.cssText = 'position:absolute;left:-2px;top:-16px;font:bold 11px/14px Menlo,monospace;'
              + 'color:#fff;background:#e5484d;padding:0 3px;border-radius:2px;white-space:nowrap';
            box.append(label);
            layer.append(box);
          }
          document.documentElement.append(layer);
          return true;
        })()
        """
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
