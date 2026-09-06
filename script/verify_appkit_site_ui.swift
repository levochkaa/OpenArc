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

@MainActor func verifySiteControls() throws {
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
    let keyboard = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    defer { TISSelectInputSource(keyboard) }
    TISSelectInputSource(TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue())
    let pasteboard = NSPasteboard.general
    let savedClipboard = (pasteboard.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
    }
    defer {
        pasteboard.clearContents()
        pasteboard.writeObjects(savedClipboard.map { saved in
            let item = NSPasteboardItem()
            for (type, data) in saved {
                item.setData(data, forType: type)
            }
            return item
        })
    }
    try require(app.activate(), "Cannot activate app")
    func elements() -> [AXUIElement] { (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [])
        .flatMap { descendants($0) }
    }
    func id(_ element: AXUIElement) -> String { attribute(element, kAXIdentifierAttribute) as? String ?? "" }
    func element(_ identifier: String) -> AXUIElement? { elements().first { id($0) == identifier } }
    func activeURL() -> AXUIElement? { element("browser.site-toolbar.url") ?? element("browser.sidebar.url") }
    func press(_ element: AXUIElement) throws { try require(
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success,
        "Cannot press \(id(element))"
    ) }
    func movePointer(to element: AXUIElement) throws {
        guard let frame = elementFrame(element) else { throw UIError.failed("Missing control frame") }
        CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: frame.midX, y: frame.midY),
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }
    func menuAction(_ title: String) throws {
        guard let url = activeURL(), let frame = elementFrame(url) else { throw UIError.failed("No URL control") }
        let point = CGPoint(x: frame.minX + 20, y: frame.midY)
        CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?
            .post(tap: .cghidEventTap)
        func menuItem() -> AXUIElement? {
            descendants(ax).first { attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole && attribute(
                $0,
                kAXTitleAttribute
            ) as? String == title }
        }
        try waitFor("menu \(title)") { menuItem() != nil }
        try press(menuItem()!)
    }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("thebrowser-site-controls.html")
    try "<html><head><title>Native Site Controls</title></head><body>Native Site Controls</body></html>".write(
        to: fixture,
        atomically: true,
        encoding: .utf8
    )
    try runAppleScript("click menu item \"New Tab\" of menu 1 of menu bar item \"File\" of menu bar 1", pid: pid)
    try waitFor("command input") {
        element("browser.command.query").flatMap { attribute($0, kAXFocusedAttribute) as? Bool } == true
    }
    try runAppleScript("keystroke \"\(fixture.absoluteString)\"\nkey code 36", pid: pid)
    try waitFor("URL control ready") { activeURL() != nil && element("browser.command.query") == nil }
    let initiallyToolbar = element("browser.site-toolbar.url") != nil
    defer {
        let nowToolbar = element("browser.site-toolbar.url") != nil
        if nowToolbar != initiallyToolbar {
            try? menuAction(initiallyToolbar ? "Show as Toolbar" : "Show in Sidebar")
        }
    }
    if !initiallyToolbar {
        try menuAction("Show as Toolbar")
        try waitFor("toolbar enabled") { element("browser.site-toolbar.url") != nil }
    }
    guard let copy = element("browser.site.copy-url") else { throw UIError.failed("Missing copy button") }
    try press(copy)
    try waitFor("copied URL") { pasteboard.string(forType: .string) == fixture.absoluteString }
    try press(element("browser.site-toolbar.url")!)
    try waitFor("toolbar URL editing") { element("browser.command.current-page-query").flatMap { attribute(
        $0,
        kAXFocusedAttribute
    ) as? Bool } == true }
    try require(
        element("browser.command.current-page-query").flatMap { attribute($0, kAXValueAttribute) as? String } == fixture
            .absoluteString,
        "URL editor must use the complete current address"
    )
    try runAppleScript("key code 53", pid: pid)
    try waitFor("URL editor closes") { element("browser.command.current-page-query") == nil }
    print("PASS toolbar: copy URL and open complete URL editor")

    try menuAction("Show in Sidebar")
    try waitFor("sidebar URL mode") {
        element("browser.sidebar.url") != nil && element("browser.site-toolbar.url") == nil
    }
    try press(element("browser.sidebar.url")!)
    try waitFor("sidebar URL editor") { element("browser.command.current-page-query").flatMap { attribute(
        $0,
        kAXFocusedAttribute
    ) as? Bool } == true }
    try runAppleScript("key code 53", pid: pid)
    try waitFor("sidebar URL editor closes") { element("browser.command.current-page-query") == nil }
    try movePointer(to: element("browser.sidebar.url")!)
    try waitFor("sidebar action controls appear") { element("browser.site.controls") != nil }
    try press(element("browser.site.controls")!)
    try waitFor("native extension center") { element("browser.extensions.control-center") != nil }
    try require(element("browser.extensions.add") != nil, "Extension center must retain Add Extension")
    try require(element("browser.extensions.manage") != nil, "Extension center must retain Manage")
    try runAppleScript("key code 53", pid: pid)
    try waitFor("Escape closes extension center") { element("browser.extensions.control-center") == nil }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    try menuAction("Show as Toolbar")
    try waitFor("toolbar restored") { element("browser.site-toolbar.url") != nil }
    print("PASS sidebar URL: mode switch, URL editor, extension center, Escape")
}

do { try MainActor.assumeIsolated { try verifySiteControls() } }
catch { fputs("FAIL \(error)\n", stderr)
    exit(1)
}
