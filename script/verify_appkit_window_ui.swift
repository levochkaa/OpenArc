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

@MainActor func verifyWindow() throws {
    guard CommandLine.arguments.count == 2 else { throw UIError.failed("Pass the isolated running app bundle") }
    let bundle = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    guard let app = NSWorkspace.shared
        .runningApplications
        .first(where: { $0.bundleURL?.resolvingSymlinksInPath() == bundle })
    else { throw UIError.failed("App is not running") }
    let pid = app.processIdentifier
    let ax = AXUIElementCreateApplication(pid)
    try waitFor("window ready") { !(attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []).isEmpty }
    app.activate()
    let keyboard = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    defer { TISSelectInputSource(keyboard) }
    TISSelectInputSource(TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue())
    func elements() -> [AXUIElement] { (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [])
        .flatMap { descendants($0) }
    }
    func id(_ e: AXUIElement) -> String { attribute(e, kAXIdentifierAttribute) as? String ?? "" }
    func element(_ value: String) -> AXUIElement? { elements().first { id($0) == value } }
    func frame(_ value: String) -> CGRect? { element(value).flatMap(elementFrame) }
    func titleIs(_ title: String) -> Bool { elements().contains { id($0).hasPrefix("browser.sidebar.tab.") && attribute(
        $0,
        kAXDescriptionAttribute
    ) as? String == title } }
    func press(_ e: AXUIElement) throws { try require(
        AXUIElementPerformAction(e, kAXPressAction as CFString) == .success,
        "Cannot press \(id(e))"
    ) }
    func mouse(_ type: CGEventType, _ point: CGPoint) { CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
    )?.post(tap: .cghidEventTap) }
    func click(_ point: CGPoint) { mouse(.leftMouseDown, point)
        mouse(.leftMouseUp, point)
    }
    func drag(_ start: CGPoint, _ end: CGPoint) {
        mouse(.mouseMoved, start)
        mouse(.leftMouseDown, start)
        for index in 1...12 {
            let t = CGFloat(index) / 12
            mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        mouse(.leftMouseUp, end)
    }
    try runAppleScript("set frontmost to true\nkey code 53", pid: pid)
    let suffix = String(UUID().uuidString.prefix(6))
    let title = "Window Fixture \(suffix)"
    let clicked = "Clicked \(suffix)"
    let typed = "Typed \(suffix)"
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("openarc-window-\(suffix).html")
    try "<html><head><title>\(title)</title></head><body style='background:#eee;color:#222;font:24px system-ui;padding:80px' tabindex='0' onmousedown=\"document.title='\(clicked)'\" onkeydown=\"document.title='\(typed)'\">Native window interaction fixture</body></html>"
        .write(
            to: fixture,
            atomically: true,
            encoding: .utf8
        )
    try runAppleScript("click menu item \"New Tab\" of menu 1 of menu bar item \"File\" of menu bar 1", pid: pid)
    try waitFor("command focus") {
        element("browser.command.query").flatMap { attribute($0, kAXFocusedAttribute) as? Bool } == true
    }
    TISSelectInputSource(TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue())
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    try runAppleScript("keystroke \"\(fixture.absoluteString)\"\nkey code 36", pid: pid)
    try waitFor("fixture loaded") { titleIs(title) }
    guard let initialContent = frame("browser.content"),
          let initialSidebar = frame("browser.sidebar") else { throw UIError.failed("Missing native window geometry") }
    click(CGPoint(x: initialContent.midX, y: initialContent.midY))
    try waitFor("page receives mouse") { titleIs(clicked) }
    try runAppleScript("key code 0", pid: pid)
    try waitFor("page receives keyboard") { titleIs(typed) }
    print("PASS window: native chrome passes mouse and keyboard into CEF")
    try runAppleScript("key code 3 using command down", pid: pid)
    try waitFor("find within page") { frame("browser.find.query") != nil }
    for _ in 0..<2 {
        guard let page = frame("browser.content"), let query = frame("browser.find.query") else {
            throw UIError.failed("Missing page or find field")
        }
        try require(page.contains(query), "Find field must stay inside the Chromium viewport")
        let offset = query.minY - page.minY
        try runAppleScript("key code 11 using {command down, shift down}", pid: pid)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let nextPage = frame("browser.content"), let nextQuery = frame("browser.find.query") else {
            throw UIError.failed("Find disappeared while toggling bookmarks")
        }
        try require(abs(nextPage.minY - page.minY) > 20, "Bookmarks toggle did not change page geometry")
        try require(abs(nextQuery.minY - nextPage.minY - offset) < 1, "Find did not follow page below bookmarks")
    }
    try runAppleScript("key code 53", pid: pid)
    print("PASS find: stays in Chromium viewport and follows bookmarks bar")

    guard let handle = frame("browser.sidebar.resize") else { throw UIError.failed("Missing resize handle") }
    drag(CGPoint(x: handle.midX, y: handle.midY), CGPoint(x: handle.midX + 48, y: handle.midY))
    try waitFor("sidebar resized") { (frame("browser.sidebar")?.width ?? 0) > initialSidebar.width + 30 }
    guard let enlarged = frame("browser.sidebar"),
          let updatedHandle = frame("browser.sidebar.resize") else { throw UIError.failed("Missing resized sidebar") }
    drag(
        CGPoint(x: updatedHandle.midX, y: updatedHandle.midY),
        CGPoint(x: updatedHandle.midX - (enlarged.width - initialSidebar.width), y: updatedHandle.midY)
    )
    try waitFor("sidebar width restored") { abs((frame("browser.sidebar")?.width ?? 0) - initialSidebar.width) < 1 }
    guard let sidebarElement = element("browser.sidebar"), let pageElement = element("browser.content"),
          let toggleFrame = frame("browser.sidebar.toggle") else { throw UIError.failed("Missing animation controls") }
    click(CGPoint(x: toggleFrame.midX, y: toggleFrame.midY))
    var intermediateFrames = 0
    let animationDeadline = Date().addingTimeInterval(0.3)
    repeat {
        if let sidebar = elementFrame(sidebarElement), let page = elementFrame(pageElement),
           page.minX < initialContent.minX - 35, page.minX > initialContent.minX - initialSidebar.width + 18
        {
            intermediateFrames += 1
            try require(sidebar.minX < initialSidebar.minX - 2, "Page moved before sidebar")
            try require(abs(sidebar.width - initialSidebar.width) < 1, "Hiding sidebar compressed its contents")
            // AX requests cross process boundaries; allow one display frame between reads.
            try require(abs(page.minX - sidebar.maxX) < 32, "Sidebar and page are on different animation frames")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.006))
    } while Date() < animationDeadline
    try require(intermediateFrames > 0, "No intermediate geometry frames were observed")
    print("PASS sidebar: synchronized intermediate frames and constant content width")
    try waitFor("sidebar collapsed") {
        (frame("browser.content")?.minX ?? 9999) < initialContent.minX - 100
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    guard let hiddenContent = frame("browser.content"),
          let root = frame("browser.window.chrome") else { throw UIError.failed("Missing collapsed geometry") }
    mouse(.mouseMoved, CGPoint(x: root.minX + 2, y: root.midY))
    try waitFor("hover sidebar revealed") { (frame("browser.sidebar")?.minX ?? -9999) > root.minX }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    try require(frame("browser.content") == hiddenContent, "Hover reveal must leave CEF geometry unchanged")
    mouse(.mouseMoved, CGPoint(x: hiddenContent.maxX - 40, y: hiddenContent.midY))
    try waitFor("hover sidebar dismissed") { (frame("browser.sidebar")?.maxX ?? 9999) <= root.minX + 1 }
    mouse(.mouseMoved, CGPoint(x: root.minX + 2, y: root.midY))
    try waitFor("hover sidebar revealed again") { (frame("browser.sidebar")?.minX ?? -9999) > root.minX }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    try press(element("browser.sidebar.toggle")!)
    try waitFor("hover sidebar pinned") { abs((frame("browser.content")?.minX ?? 0) - initialContent.minX) < 1 }
    print("PASS sidebar: resize, restore, delayed hover, dismissal and pinning without moving CEF under overlay")
    try runAppleScript(
        "click menu item \"Enter Full Screen\" of menu 1 of menu bar item \"View\" of menu bar 1",
        pid: pid
    )
    func fullscreen() -> Bool {
        (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [])
            .contains { attribute($0, "AXFullScreen") as? Bool == true }
    }

    try waitFor("fullscreen entered") { fullscreen() }
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    try require(frame("browser.content") != nil, "CEF viewport must survive fullscreen")
    try runAppleScript(
        "click menu item \"Exit Full Screen\" of menu 1 of menu bar item \"View\" of menu bar 1",
        pid: pid
    )
    try waitFor("fullscreen exited") { !fullscreen() }
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    try require(
        abs((frame("browser.sidebar")?.width ?? 0) - initialSidebar.width) < 1,
        "Fullscreen must preserve sidebar width"
    )
    print("PASS fullscreen: native window enters and exits with viewport and sidebar intact")
    try press(element("browser.sidebar.toggle")!)
    try waitFor("sidebar hidden before fullscreen hover") {
        (frame("browser.content")?.minX ?? 9999) < initialContent.minX - 100
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    let windowRoot = frame("browser.window.chrome")!
    mouse(.mouseMoved, CGPoint(x: windowRoot.minX + 2, y: windowRoot.midY))
    try waitFor("hover shown before fullscreen") { (frame("browser.sidebar")?.minX ?? -9999) > windowRoot.minX }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    try runAppleScript(
        "click menu item \"Enter Full Screen\" of menu 1 of menu bar item \"View\" of menu bar 1",
        pid: pid
    )
    try waitFor("hover fullscreen entered") { fullscreen() }
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let fullRoot = frame("browser.window.chrome")!
    let fullContent = frame("browser.content")!
    try require(
        (frame("browser.sidebar")?.minX ?? -9999) > fullRoot.minX,
        "Hover sidebar must survive fullscreen entry"
    )
    try require(
        abs(fullContent.minX - fullRoot.minX) < 1,
        "Hover sidebar must not reserve viewport width in fullscreen"
    )
    mouse(.mouseMoved, CGPoint(x: fullContent.maxX - 30, y: fullContent.midY))
    try waitFor("fullscreen hover dismissed after pointer movement") {
        (frame("browser.sidebar")?.maxX ?? 9999) <= fullRoot.minX + 1
    }
    try runAppleScript(
        "click menu item \"Exit Full Screen\" of menu 1 of menu bar item \"View\" of menu bar 1",
        pid: pid
    )
    try waitFor("hover fullscreen exited") { !fullscreen() }
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    try runAppleScript("click menu item \"Toggle Sidebar\" of menu 1 of menu bar item \"View\" of menu bar 1", pid: pid)
    try waitFor("pinned sidebar restored after fullscreen hover") {
        abs((frame("browser.content")?.minX ?? 0) - initialContent.minX) < 1
    }
    print("PASS fullscreen hover: overlay preserved during transition and dismissed on pointer movement")

    let beforeWindowCount = (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []).count
    try runAppleScript(
        "click menu item \"New Incognito Window\" of menu 1 of menu bar item \"File\" of menu bar 1",
        pid: pid
    )
    func privateWindow() -> AXUIElement? {
        (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [])
            .first { window in descendants(window).contains { attribute(
                $0,
                kAXValueAttribute
            ) as? String == "Incognito Tabs" } }
    }
    try waitFor("native incognito window") { privateWindow() != nil }
    let privateChrome = descendants(privateWindow()!).first { id($0) == "browser.window.chrome" }
    try require(privateChrome != nil, "Incognito window must use the native chrome root")
    guard let close = descendants(privateWindow()!).first(where: { id($0) == "browser.window.control.0" }) else {
        throw UIError.failed("Missing native private window close button")
    }
    try press(close)
    try waitFor("private window closed independently") { privateWindow() == nil && (attribute(
        ax,
        kAXWindowsAttribute
    ) as? [AXUIElement] ?? []).count == beforeWindowCount }
    print("PASS incognito: native root, private tabs and independent close")
}

do { try MainActor.assumeIsolated { try verifyWindow() } }
catch { fputs("FAIL \(error)\n", stderr)
    exit(1)
}
