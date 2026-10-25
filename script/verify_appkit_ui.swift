import AppKit
import ApplicationServices
import Carbon

// MARK: - UIError

// Run after ./build.sh run --skip-build --runtime-suffix appkit-ui-verification.
// Uses a local fixture and the specified app bundle; restores the user's keyboard layout.
// This is an opt-in live UI check, separate from the console-only Build and Test actions.

enum UIError: Error, CustomStringConvertible {
    case failed(String)

    // MARK: Internal

    var description: String { switch self { case .failed(let message): message } }
}

@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw UIError.failed(message)
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 20 else { return [] }
    let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return [element] + children.flatMap { descendants($0, depth: depth + 1) }
}

func elementFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(
        size as! AXValue,
        .cgSize,
        &dimensions
    ) else { return nil }
    return CGRect(origin: point, size: dimensions)
}

@MainActor func waitFor(_ description: String, _ predicate: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(8)
    repeat {
        if predicate() {
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    throw UIError.failed("Timed out: \(description)")
}

@MainActor func runAppleScript(_ body: String, pid: pid_t) throws {
    let script = "tell application \"System Events\" to tell first application process whose unix id is \(pid)\n\(body)\nend tell"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw UIError.failed(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

@MainActor func verify() throws {
    guard CommandLine.arguments.count == 2 else {
        throw UIError.failed("Usage: xcrun swift script/verify_appkit_ui.swift /absolute/path/OpenArc.app")
    }
    let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleURL?.resolvingSymlinksInPath() == bundleURL
    }) else { throw UIError.failed("The specified app is not running. Launch an isolated verification session first.") }
    let pid = app.processIdentifier
    let axApp = AXUIElementCreateApplication(pid)
    try waitFor("browser window and menu bar") {
        !(attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []).isEmpty
            && attribute(axApp, kAXMenuBarAttribute) != nil
    }
    let keyboard = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let asciiKeyboard = TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()
    try require(TISSelectInputSource(asciiKeyboard) == noErr, "Could not select ASCII input source")
    defer { TISSelectInputSource(keyboard) }

    func element(_ identifier: String) -> AXUIElement? {
        let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.flatMap { descendants($0) }.first {
            attribute($0, kAXIdentifierAttribute) as? String == identifier
        }
    }
    func field() -> AXUIElement? { element("browser.find.query") }
    func value(_ element: AXUIElement?) -> String? {
        element.flatMap { attribute($0, kAXValueAttribute) as? String }
    }
    func enabled(_ identifier: String) -> Bool {
        element(identifier).flatMap { attribute($0, kAXEnabledAttribute) as? Bool } ?? false
    }
    func press(_ identifier: String) throws {
        guard let control = element(identifier) else { throw UIError.failed("Missing control: \(identifier)") }
        try require(
            AXUIElementPerformAction(control, kAXPressAction as CFString) == .success,
            "Cannot press \(identifier)"
        )
    }
    func openFind() throws {
        try runAppleScript(
            "click menu item \"Find...\" of menu 1 of menu item \"Find\" of menu 1 of menu bar item \"Edit\" of menu bar 1",
            pid: pid
        )
        try waitFor("find field appears") { field() != nil }
    }
    app.activate()
    if let newTab = element("browser.sidebar.new-tab"), let frame = elementFrame(newTab) {
        let point = CGPoint(x: frame.midX, y: frame.midY)
        for type: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        try waitFor("New Tab stays presented after mouse-up") { element("browser.command.query") != nil }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try require(element("browser.command.query") != nil, "New Tab closed on its opening mouse-up")
        try runAppleScript("key code 53", pid: pid)
        print("PASS command bar: real New Tab mouse click stays open")
    } else {
        throw UIError.failed("A visible sidebar is required for New Tab mouse verification")
    }
    let fixture = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("openarc-native-ui-verification.html")
    try "<html><head><title>Native UI Verification</title></head><body><h1>Native UI Verification</h1><p>needle one</p><p>needle two</p><input aria-label='Page input'></body></html>"
        .write(
            to: fixture,
            atomically: true,
            encoding: .utf8
        )
    try require(app.activate(options: []), "Could not activate browser")
    try runAppleScript("click menu item \"New Tab\" of menu 1 of menu bar item \"File\" of menu bar 1", pid: pid)
    try waitFor("native command field") {
        element("browser.command.query").flatMap { attribute($0, kAXFocusedAttribute) as? Bool } == true
    }
    try runAppleScript("keystroke \"\(fixture.absoluteString)\"\nkey code 36", pid: pid)
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    try runAppleScript("click menu item \"New Tab\" of menu 1 of menu bar item \"File\" of menu bar 1", pid: pid)
    try waitFor("command field for pointer submission") { element("browser.command.query") != nil }
    try runAppleScript("keystroke \"\(fixture.absoluteString)\"", pid: pid)
    func primaryURLSuggestionID() -> String? {
        let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.flatMap { descendants($0) }
            .compactMap { attribute($0, kAXIdentifierAttribute) as? String }
            .first { $0.hasPrefix("browser.command.suggestion.url|") }
    }
    try waitFor("URL suggestion button") { primaryURLSuggestionID() != nil }
    try press(primaryURLSuggestionID()!)
    try waitFor("pointer submission closes command bar") { element("browser.command.query") == nil }
    try runAppleScript("click menu item \"New Tab\" of menu 1 of menu bar item \"File\" of menu bar 1", pid: pid)
    try waitFor("command field for keyboard scrolling") { element("browser.command.query") != nil }
    try runAppleScript("keystroke \"refresh\"", pid: pid)
    try waitFor("scrollable command suggestions") {
        element("browser.command.suggestions")
            .flatMap { attribute($0, kAXRowsAttribute) as? [AXUIElement] }?
            .count ?? 0 >= 6
    }
    for _ in 0..<5 {
        try runAppleScript("key code 125", pid: pid)
    }
    try waitFor("selected suggestion scrolls fully into view") {
        guard let table = element("browser.command.suggestions"),
              let selected = (attribute(table, kAXSelectedRowsAttribute) as? [AXUIElement])?.first,
              let rowFrame = elementFrame(selected),
              let scroll = element("browser.command.suggestion-scroll"),
              let viewport = elementFrame(scroll) else { return false }
        return viewport.contains(rowFrame.insetBy(dx: 1, dy: 1))
    }
    guard let suggestionTable = element("browser.command.suggestions"),
          let rows = attribute(suggestionTable, kAXRowsAttribute) as? [AXUIElement]
    else {
        throw UIError.failed("Missing suggestion rows")
    }
    for _ in rows {
        try runAppleScript("key code 125", pid: pid)
    }
    try waitFor("last suggestion rests at viewport bottom without blank rows") {
        guard let selected = (attribute(suggestionTable, kAXSelectedRowsAttribute) as? [AXUIElement])?.first,
              let row = elementFrame(selected), let scroll = element("browser.command.suggestion-scroll"),
              let viewport = elementFrame(scroll) else { return false }
        let gap = viewport.maxY - row.maxY
        return gap >= -1 && gap < 12
    }
    try runAppleScript("key code 53", pid: pid)
    try waitFor("Escape closes command bar") { element("browser.command.query") == nil }
    print("PASS command bar: Return, suggestion click, keyboard scrolling, Escape")
    try openFind()
    try waitFor("find field focus") { field().flatMap { attribute($0, kAXFocusedAttribute) as? Bool } == true }
    try runAppleScript("keystroke \"needle\"", pid: pid)
    try waitFor("query updates without losing focus") { value(field()) == "needle" }
    try waitFor("CEF reports matches") { enabled("browser.find.next") && enabled("browser.find.previous") }
    try press("browser.find.next")
    try press("browser.find.previous")
    try require(value(field()) == "needle", "Stepping changed the query")
    print("PASS find: text input, CEF matches, next/previous")

    try openFind()
    try runAppleScript("keystroke \"absent-native-ui-token\"", pid: pid)
    try waitFor("reopen selects existing query") { value(field()) == "absent-native-ui-token" }
    try waitFor("no-match navigation disables") { !enabled("browser.find.next") && !enabled("browser.find.previous") }
    try runAppleScript("key code 53", pid: pid)
    try waitFor("Escape dismisses find") { field() == nil }
    try openFind()
    try press("browser.find.close")
    try waitFor("close button dismisses find") { field() == nil }
    print("PASS find: select-all on reopen, no matches, Escape, close")

    try runAppleScript("click menu item 1 of menu 1 of menu bar item \"OpenArc\" of menu bar 1", pid: pid)
    try waitFor("native About credits") { element("browser.about.credits") != nil }
    try require(value(element("browser.about.credits"))?.contains("Chromium") == true, "About credits are missing")
    try runAppleScript("key code 13 using command down", pid: pid)
    try waitFor("About closes without archiving the browser tab") { element("browser.about.credits") == nil }
    print("PASS about: native window, selectable credits, close")

    try runAppleScript(
        "click menu item \"Settings…\" of menu 1 of menu bar item \"OpenArc\" of menu bar 1",
        pid: pid
    )
    try waitFor("accounts page") { element("browser.settings.default-browser") != nil }
    for (title, sentinel) in [
        ("General", "battery-saver"),
        ("Profiles", "new-profile"),
        ("Shortcuts", "shortcut-search"),
        ("Content", "haptic-feedback"),
        ("Accounts", "default-browser"),
    ] {
        try runAppleScript("click button \"\(title)\" of toolbar 1 of window 1", pid: pid)
        try waitFor("settings \(title)") { element("browser.settings.\(sentinel)") != nil }
    }
    print("PASS settings: all five native pages")
    try runAppleScript("click button \"Content\" of toolbar 1 of window 1", pid: pid)
    try waitFor("content checkbox") { element("browser.settings.haptic-feedback") != nil }
    func checkboxValue() -> Int? {
        element("browser.settings.haptic-feedback").flatMap { attribute($0, kAXValueAttribute) as? Int }
    }
    guard let originalCheckbox = checkboxValue() else { throw UIError.failed("Cannot read checkbox state") }
    defer {
        if originalCheckbox != checkboxValue() {
            try? press("browser.settings.haptic-feedback")
        }
    }
    try press("browser.settings.haptic-feedback")
    try waitFor("checkbox change") { checkboxValue() != originalCheckbox }
    try press("browser.settings.haptic-feedback")
    try waitFor("checkbox restored") { checkboxValue() == originalCheckbox }
    try runAppleScript("click button \"Shortcuts\" of toolbar 1 of window 1", pid: pid)
    try waitFor("shortcut search") { element("browser.settings.shortcut-search") != nil }
    if let search = element("browser.settings.shortcut-search") {
        try require(
            AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
            "Could not focus shortcut search"
        )
    }
    try runAppleScript("keystroke \"Find\"", pid: pid)
    try waitFor("shortcut filter") { value(element("browser.settings.shortcut-search")) == "Find" }
    let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let recordID = windows.flatMap { descendants($0) }
        .compactMap { attribute($0, kAXIdentifierAttribute) as? String }
        .first { $0.hasPrefix("browser.settings.shortcut.record.") }
    guard let recordID else { throw UIError.failed("Shortcut filtering removed matching commands") }
    try press(recordID)
    try waitFor("shortcut recorder focus") { element("browser.settings.shortcut-capture") != nil }
    try runAppleScript("key code 53", pid: pid)
    try waitFor("cancel shortcut recording") { element("browser.settings.shortcut-capture") == nil }
    print("PASS settings: checkbox round trip, shortcut filtering, recorder cancellation")
}

do { try MainActor.assumeIsolated { try verify() } } catch { fputs("UI verification failed: \(error)\n", stderr)
    exit(1)
}
