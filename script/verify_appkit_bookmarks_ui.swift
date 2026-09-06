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

@MainActor func verifyBookmarks() throws {
    guard CommandLine.arguments.count == 2 else { throw UIError.failed("Pass the isolated running app bundle") }
    let bundle = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    guard let app = NSWorkspace.shared
        .runningApplications
        .first(where: { $0.bundleURL?.resolvingSymlinksInPath() == bundle })
    else { throw UIError.failed("App is not running") }
    let pid = app.processIdentifier
    let ax = AXUIElementCreateApplication(pid)
    try waitFor("browser ready") { attribute(ax, kAXMenuBarAttribute) != nil && !(attribute(
        ax,
        kAXWindowsAttribute
    ) as? [AXUIElement] ?? []).isEmpty }
    app.activate()
    let keyboard = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    defer { TISSelectInputSource(keyboard) }
    TISSelectInputSource(TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue())
    func elements() -> [AXUIElement] { (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [])
        .flatMap { descendants($0) }
    }
    func id(_ e: AXUIElement) -> String { attribute(e, kAXIdentifierAttribute) as? String ?? "" }
    func element(_ value: String) -> AXUIElement? { elements().first { id($0) == value } }
    func press(_ e: AXUIElement) throws { try require(
        AXUIElementPerformAction(e, kAXPressAction as CFString) == .success,
        "Cannot press \(id(e))"
    ) }
    func bookmark(_ title: String) -> AXUIElement? { elements()
        .first { id($0).hasPrefix("browser.bookmarks.item.") && (attribute(
            $0,
            kAXTitleAttribute
        ) as? String == title || attribute($0, kAXDescriptionAttribute) as? String == title) }
    }
    func context(_ title: String, on e: AXUIElement) throws {
        guard let frame = elementFrame(e) else { throw UIError.failed("Missing frame") }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?
            .post(tap: .cghidEventTap)
        func item() -> AXUIElement? { descendants(ax)
            .first { attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole && attribute(
                $0,
                kAXTitleAttribute
            ) as? String == title }
        }
        try waitFor("context \(title)") { item() != nil }
        try press(item()!)
    }
    try runAppleScript("set frontmost to true\nkey code 53", pid: pid)
    if elements().contains(where: { id($0).hasPrefix("browser.settings.") }) {
        try runAppleScript(
            "key code 13 using command down",
            pid: pid
        )
    }
    let initiallyVisible = element("browser.bookmarks.bar") != nil
    if !initiallyVisible {
        try runAppleScript("key code 11 using {command down, shift down}", pid: pid)
    }
    defer {
        if !initiallyVisible {
            try? runAppleScript("key code 11 using {command down, shift down}", pid: pid)
        }
    }
    try waitFor("bookmarks bar") { element("browser.bookmarks.bar") != nil }
    let title = "Native Bookmark \(UUID().uuidString.prefix(6))"
    let fixture = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("\(title.replacingOccurrences(of: " ", with: "-")).html")
    try "<html><head><title>\(title)</title></head><body>Native bookmark fixture</body></html>".write(
        to: fixture,
        atomically: true,
        encoding: .utf8
    )
    try runAppleScript("click menu item \"New Tab\" of menu 1 of menu bar item \"File\" of menu bar 1", pid: pid)
    try waitFor("command focus") {
        element("browser.command.query").flatMap { attribute($0, kAXFocusedAttribute) as? Bool } == true
    }
    try runAppleScript("keystroke \"\(fixture.absoluteString)\"\nkey code 36", pid: pid)
    try waitFor("fixture loaded") {
        elements()
            .contains { (attribute($0, kAXTitleAttribute) as? String == title || attribute(
                $0,
                kAXDescriptionAttribute
            ) as? String == title) } && element("browser.command.query") ==
            nil
    }
    try press(element("browser.bookmarks.toggle-current")!)
    try waitFor("new bookmark") { bookmark(title) != nil }
    try context("Rename...", on: bookmark(title)!)
    try waitFor("rename field") {
        elements().contains { attribute($0, kAXRoleAttribute) as? String == kAXTextFieldRole && attribute(
            $0,
            kAXValueAttribute
        ) as? String == title }
    }
    let renamed = "Renamed \(title)"
    try runAppleScript("key code 0 using command down\nkeystroke \"\(renamed)\"\nkey code 36", pid: pid)
    try waitFor("renamed bookmark") { bookmark(renamed) != nil }
    try press(bookmark(renamed)!)
    try context("Delete", on: bookmark(renamed)!)
    try waitFor("only fixture bookmark deleted") { bookmark(renamed) == nil }
    print("PASS bookmarks: star, rename, open, delete and visibility restoration")
}

do { try MainActor.assumeIsolated { try verifyBookmarks() } }
catch { fputs("FAIL \(error)\n", stderr)
    exit(1)
}
