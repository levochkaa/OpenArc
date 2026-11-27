// BrowserPeerPageInput.swift

import AppKit

// MARK: - BrowserPeerPageInput

/// DevTools' input methods for a page whose engine has no DevTools of its own, WebKit and Ladybird: the agent CLI's
/// clicks, keys and text arrive as AppKit events in the page's view, so the page takes them as the person's own, user
/// activation included. Points are CSS pixels of the viewport, as Chromium takes them.
@MainActor @objc final class BrowserPeerPageInput: NSObject {
    private static let methods: Set = [
        "Input.dispatchMouseEvent", "Input.dispatchKeyEvent", "Input.insertText", "Page.reload",
    ]

    /// Mac key codes by DOM `code`.
    private static let keyCodes: [String: UInt16] = [
        "Enter": 36, "Tab": 48, "Escape": 53, "Backspace": 51, "Delete": 117, "Space": 49, "ArrowUp": 126,
        "ArrowDown": 125, "ArrowLeft": 123, "ArrowRight": 124, "Home": 115, "End": 119, "PageUp": 116,
        "PageDown": 121, "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5, "KeyZ": 6, "KeyX": 7,
        "KeyC": 8, "KeyV": 9, "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16, "KeyT": 17,
        "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit6": 22, "Digit5": 23, "Digit9": 25,
        "Digit7": 26, "Digit8": 28, "Digit0": 29, "KeyO": 31, "KeyU": 32, "KeyI": 34, "KeyP": 35, "KeyL": 37,
        "KeyJ": 38, "KeyK": 40, "KeyN": 45, "KeyM": 46,
    ]

    /// AppKit's characters for keys that type none.
    private static let functionKeys: [String: Int] = [
        "Tab": 0x09, "Escape": 0x1B, "Backspace": 0x7F, "Delete": NSDeleteFunctionKey, "ArrowUp": NSUpArrowFunctionKey,
        "ArrowDown": NSDownArrowFunctionKey, "ArrowLeft": NSLeftArrowFunctionKey,
        "ArrowRight": NSRightArrowFunctionKey, "Home": NSHomeFunctionKey, "End": NSEndFunctionKey,
        "PageUp": NSPageUpFunctionKey, "PageDown": NSPageDownFunctionKey,
    ]

    @objc static func handles(_ method: String) -> Bool {
        methods.contains(method)
    }

    /// `devTools` runs a method the page itself answers (`Runtime.evaluate`); the answer is "{}", or nil when the page
    /// has no window to take events.
    @objc static func answer(
        _ method: String,
        params paramsJSON: String,
        in view: NSView,
        devTools: @escaping (String, String, @escaping (String?) -> Void) -> Void,
        reload: @escaping (Bool) -> Void,
        completion: @escaping (String?) -> Void,
    ) {
        let params = paramsJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard let window = view.window, let target = textClient(in: view) else {
            completion(nil)
            return
        }
        switch method {
        case "Page.reload":
            reload(params["ignoreCache"] as? Bool ?? false)
            completion("{}")
        case "Input.insertText":
            focus(target, in: view, window: window)
            (keyTarget(in: view, window: window) as? NSTextInputClient)?.insertText(
                params["text"] as? String ?? "",
                replacementRange: NSRange(location: NSNotFound, length: 0),
            )
            completion("{}")
        case "Input.dispatchKeyEvent":
            dispatchKey(params, view: view, target: target, window: window)
            completion("{}")
        default:
            viewport(devTools) { size in
                guard let size else {
                    completion(nil)
                    return
                }
                dispatchMouse(params, viewport: size, view: target, window: window, devTools: devTools)
                completion("{}")
            }
        }
    }

    // MARK: Private

    /// The engine's own view, which takes text input.
    private static func textClient(in view: NSView) -> NSView? {
        if view is NSTextInputClient {
            return view
        }
        for subview in view.subviews {
            if let found = textClient(in: subview) {
                return found
            }
        }
        return nil
    }

    private static func keyTarget(in view: NSView, window: NSWindow) -> NSView? {
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) {
            return responder
        }
        return textClient(in: view)
    }

    private static func focus(_ target: NSView, in view: NSView, window: NSWindow) {
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) {
            return
        }
        window.makeFirstResponder(target)
    }

    private static func viewport(
        _ devTools: @escaping (String, String, @escaping (String?) -> Void) -> Void,
        completion: @escaping (CGSize?) -> Void,
    ) {
        let params = #"{"expression":"[innerWidth, innerHeight]","returnByValue":true}"#
        devTools("Runtime.evaluate", params) { answer in
            let value = answer?.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { ($0["result"] as? [String: Any])?["value"] as? [Double] }
            guard let value, value.count == 2, value[0] > 0, value[1] > 0 else {
                completion(nil)
                return
            }
            completion(CGSize(width: value[0], height: value[1]))
        }
    }

    private static func modifiers(_ params: [String: Any]) -> NSEvent.ModifierFlags {
        let bits = params["modifiers"] as? Int ?? 0
        var flags = NSEvent.ModifierFlags()
        if bits & 1 != 0 { flags.insert(.option) }
        if bits & 2 != 0 { flags.insert(.control) }
        if bits & 4 != 0 { flags.insert(.command) }
        if bits & 8 != 0 { flags.insert(.shift) }
        return flags
    }

    private static func dispatchMouse(
        _ params: [String: Any],
        viewport: CGSize,
        view: NSView,
        window: NSWindow,
        devTools: @escaping (String, String, @escaping (String?) -> Void) -> Void,
    ) {
        let x = params["x"] as? Double ?? 0
        let y = params["y"] as? Double ?? 0
        let type = params["type"] as? String ?? ""
        if type == "mouseWheel" {
            // AppKit makes no wheel event for a window; the scroller under the point scrolls as a wheel would.
            let dx = params["deltaX"] as? Double ?? 0
            let dy = params["deltaY"] as? Double ?? 0
            let script = """
            (() => { let e = document.elementFromPoint(\(x), \(y));
            while (e && !(e.scrollHeight > e.clientHeight && /(auto|scroll)/.test(getComputedStyle(e).overflowY))) {
            e = e.parentElement; }
            (e || document.scrollingElement || document.documentElement).scrollBy(\(dx), \(dy)); })()
            """
            let body = try? JSONSerialization.data(withJSONObject: ["expression": script])
            devTools("Runtime.evaluate", body.flatMap { String(data: $0, encoding: .utf8) } ?? "{}") { _ in }
            return
        }
        let bounds = view.bounds
        let local = NSPoint(
            x: x * bounds.width / viewport.width,
            y: view.isFlipped
                ? y * bounds.height / viewport.height
                : bounds.height - y * bounds.height / viewport
                    .height,
        )
        let location = view.convert(local, to: nil)
        let button = params["button"] as? String ?? "left"
        let kind: NSEvent.EventType? =
            switch (type, button) {
            case ("mouseMoved", _): .mouseMoved
            case ("mousePressed", "right"): .rightMouseDown
            case ("mouseReleased", "right"): .rightMouseUp
            case ("mousePressed", "middle"): .otherMouseDown
            case ("mouseReleased", "middle"): .otherMouseUp
            case ("mousePressed", _): .leftMouseDown
            case ("mouseReleased", _): .leftMouseUp
            default: nil
            }
        guard let kind, let event = NSEvent.mouseEvent(
            with: kind,
            location: location,
            modifierFlags: modifiers(params),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: params["clickCount"] as? Int ?? (kind == .mouseMoved ? 0 : 1),
            pressure: kind == .leftMouseDown || kind == .rightMouseDown || kind == .otherMouseDown ? 1 : 0,
        ) else { return }
        switch kind {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        case .otherMouseDown: view.otherMouseDown(with: event)
        default: view.otherMouseUp(with: event)
        }
    }

    private static func dispatchKey(_ params: [String: Any], view: NSView, target: NSView, window: NSWindow) {
        let type = params["type"] as? String ?? ""
        let code = params["code"] as? String ?? ""
        if type == "char" {
            (keyTarget(in: view, window: window) as? NSTextInputClient)?.insertText(
                params["text"] as? String ?? "",
                replacementRange: NSRange(location: NSNotFound, length: 0),
            )
            return
        }
        let characters = (params["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? functionKeys[code].flatMap(UnicodeScalar.init).map { String(Character($0)) }
            ?? (params["key"] as? String).flatMap { $0.count == 1 ? $0 : nil }
            ?? ""
        guard let event = NSEvent.keyEvent(
            with: type == "keyUp" ? .keyUp : .keyDown,
            location: .zero,
            modifierFlags: modifiers(params),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCodes[code] ?? 0,
        ) else { return }
        focus(target, in: view, window: window)
        let responder = keyTarget(in: view, window: window) ?? target
        if type == "keyUp" {
            responder.keyUp(with: event)
        } else {
            responder.keyDown(with: event)
        }
    }
}
