// verify_appkit_sidebar_ui.swift

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
        &dimensions,
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

@MainActor func verifySidebar() throws {
    guard CommandLine.arguments.count == 2
    else { throw UIError.failed("Pass the running isolated OpenArc.app path") }
    let bundle = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    guard let app = NSWorkspace.shared
        .runningApplications
        .first(where: { $0.bundleURL?.resolvingSymlinksInPath() == bundle })
    else { throw UIError.failed("The isolated browser is not running") }
    let pid = app.processIdentifier
    let ax = AXUIElementCreateApplication(pid)
    try waitFor("browser window and menu bar") {
        !(attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []).isEmpty
            && attribute(ax, kAXMenuBarAttribute) != nil
    }

    let keyboard = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    defer { TISSelectInputSource(keyboard) }
    try require(
        TISSelectInputSource(TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()) == noErr,
        "Cannot select ASCII input",
    )
    try require(app.activate(), "Cannot activate browser")
    func elements() -> [AXUIElement] { (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [])
        .flatMap { descendants($0) }
    }
    func id(_ element: AXUIElement) -> String { attribute(element, kAXIdentifierAttribute) as? String ?? "" }
    func label(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let string = attribute(element, key) as? String, !string.isEmpty {
                return string
            }
        }
        return ""
    }
    func element(_ identifier: String) -> AXUIElement? { elements().first { id($0) == identifier } }
    func row(_ title: String) -> AXUIElement? { elements()
        .first { id($0).hasPrefix("browser.sidebar.tab.") && label($0) == title }
    }
    func press(_ element: AXUIElement) throws { try require(
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success,
        "Cannot press \(id(element))",
    ) }
    func type(_ text: String, endingWith code: Int? = nil) throws {
        let escaped = text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
        try runAppleScript("keystroke \"\(escaped)\"" + (code.map { "\nkey code \($0)" } ?? ""), pid: pid)
    }
    func open(_ title: String) throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(title + ".html")
        try "<html><head><title>\(title)</title></head><body><h1>\(title)</h1></body></html>".write(
            to: fixture,
            atomically: true,
            encoding: .utf8,
        )
        try runAppleScript("click menu item \"New Tab\" of menu 1 of menu bar item \"File\" of menu bar 1", pid: pid)
        try waitFor("focused command field") { element("browser.command.query").flatMap { attribute(
            $0,
            kAXFocusedAttribute,
        ) as? Bool } == true }
        try type(fixture.absoluteString, endingWith: 36)
        try waitFor("tab \(title)") { row(title) != nil }
    }
    func editField(for row: AXUIElement) -> AXUIElement? {
        element(id(row).replacing("browser.sidebar.tab.", with: "browser.sidebar.rename-tab."))
    }
    func clickAt(_ point: CGPoint, button: CGMouseButton = .left) {
        let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }
    func drag(_ source: AXUIElement, to end: CGPoint) throws {
        let frame = try requireFrame(source)
        let start = CGPoint(x: frame.midX, y: frame.midY)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        for step in 1...16 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            let t = CGFloat(step) / 16
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: point,
                mouseButton: .left,
            )?.post(tap: .cghidEventTap)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
    func requireRow(_ title: String) throws -> AXUIElement {
        guard let value = row(title) else { throw UIError.failed("Missing row \(title)") }
        return value
    }
    func requireFrame(_ element: AXUIElement) throws -> CGRect {
        guard let frame = elementFrame(element) else { throw UIError.failed("Missing frame \(id(element))") }
        return frame
    }
    let suffix = String(UUID().uuidString.prefix(6))
    let a = "Sidebar A-\(suffix)"
    let b = "Sidebar B-\(suffix)"
    let c = "Sidebar C-\(suffix)"
    let renamedC = "Renamed C-\(suffix)"
    let renamedB = "Renamed B-\(suffix)"
    try open(a)
    try open(b)
    try open(c)
    try press(requireRow(c))
    try waitFor("active tab starts rename") { row(c).flatMap(editField) != nil }
    try type(renamedC, endingWith: 36)
    try waitFor("rename commits") { row(renamedC) != nil && row(renamedC).flatMap(editField) == nil }
    try press(requireRow(a))
    try press(requireRow(a))
    try waitFor("rename field for Escape") { row(a).flatMap(editField) != nil }
    try type("Discard this title", endingWith: 53)
    try waitFor("Escape preserves title") { row(a) != nil && row(a).flatMap(editField) == nil }
    try press(requireRow(b))
    try press(requireRow(b))
    try waitFor("rename field for blur") { row(b).flatMap(editField) != nil }
    try type(renamedB)
    try press(requireRow(renamedC))
    try waitFor("blur commits title") { row(renamedB) != nil }
    print("PASS sidebar rename: Return, Escape, blur")

    let targetA = try requireFrame(requireRow(a))
    try drag(requireRow(renamedC), to: CGPoint(x: targetA.midX, y: targetA.minY + 2))
    try waitFor("drag reorders tabs") {
        guard let first = row(renamedC).flatMap(elementFrame),
              let second = row(a).flatMap(elementFrame) else { return false }
        return first.minY < second.minY
    }
    guard let header = elements().first(where: { id($0).hasPrefix("browser.sidebar.space-header.") })
    else { throw UIError.failed("Missing space header") }
    let headerFrame = try requireFrame(header)
    try drag(requireRow(renamedC), to: CGPoint(x: headerFrame.midX, y: headerFrame.midY))
    try waitFor("drag pins tab") {
        guard let pinned = row(renamedC).flatMap(elementFrame),
              let newTab = element("browser.sidebar.new-tab").flatMap(elementFrame) else { return false }
        return pinned.minY < newTab.minY
    }
    print("PASS sidebar drag: reorder and pin")

    try press(requireRow(a))
    let pinnedFrame = try requireFrame(requireRow(renamedC))
    clickAt(CGPoint(x: pinnedFrame.midX, y: pinnedFrame.midY), button: .right)
    func menuItem(_ title: String) -> AXUIElement? {
        descendants(ax).first { attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole && label($0) == title }
    }
    try waitFor("New Folder context menu") { menuItem("New Folder") != nil }
    try press(menuItem("New Folder")!)
    try waitFor("folder created") { elements().contains { id($0).hasPrefix("browser.sidebar.folder.") } }
    let newTabFrame = try requireFrame(element("browser.sidebar.new-tab")!)
    let pinnedAFrame = try requireFrame(requireRow(a))
    let pinnedCFrame = try requireFrame(requireRow(renamedC))
    try require(pinnedAFrame.minY < newTabFrame.minY, "Folder must include the active temporary tab")
    try require(
        pinnedCFrame.minY < newTabFrame.minY,
        "Folder must include the clicked pinned tab",
    )
    print("PASS sidebar folder: context menu includes clicked and active tabs")

    let d = "Sidebar D-\(suffix)"
    try open(d)
    let activeFrame = try requireFrame(requireRow(d))
    CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: CGPoint(x: activeFrame.midX, y: activeFrame.midY),
        mouseButton: .left,
    )?.post(tap: .cghidEventTap)
    try waitFor("Clear appears on hover") { element("browser.sidebar.clear-temporary") != nil }
    try press(element("browser.sidebar.clear-temporary")!)
    try waitFor("first Clear retains active temporary tab") { row(renamedB) == nil && row(d) != nil }
    try press(element("browser.sidebar.clear-temporary")!)
    try waitFor("second Clear removes active temporary tab") { row(d) == nil }
    try require(row(a) != nil && row(renamedC) != nil, "Clear must retain pinned folder tabs")
    print("PASS sidebar Clear: inactive first, active second, pinned tabs retained")

    guard let downloads = element("browser.sidebar.downloads") else { throw UIError.failed("Missing downloads button") }
    try press(downloads)
    try waitFor("native downloads popover") { element("browser.downloads.popover") != nil }
    try require(
        element("browser.downloads.clear-finished").flatMap { attribute($0, kAXEnabledAttribute) as? Bool } == false,
        "Empty downloads must disable Clear Finished",
    )
    try runAppleScript("key code 53", pid: pid)
    try waitFor("Escape closes downloads") { element("browser.downloads.popover") == nil }
    print("PASS downloads: native empty state, disabled Clear, Escape")

    func spaceButtons() -> [AXUIElement] { elements().filter { id($0).hasPrefix("browser.sidebar.select-space.") } }
    let existingSpaceIDs = Set(spaceButtons().map(id))
    guard let createSpace = element("browser.sidebar.create-space")
    else { throw UIError.failed("Missing Create Space") }
    try press(createSpace)
    try waitFor("new space appears") { spaceButtons().count == existingSpaceIDs.count + 1 }
    guard let newSpaceButton = spaceButtons().first(where: { !existingSpaceIDs.contains(id($0)) })
    else { throw UIError.failed("Missing new space") }
    let newSpaceID = id(newSpaceButton).replacing("browser.sidebar.select-space.", with: "")
    let newHeaderID = "browser.sidebar.space-header." + newSpaceID
    try press(element(newHeaderID)!)
    let renameSpaceID = "browser.sidebar.rename-space." + newSpaceID
    try waitFor("space rename field") { element(renameSpaceID) != nil }
    try type("Sidebar Space-" + suffix, endingWith: 36)
    try waitFor("space rename updates footer") { element(id(newSpaceButton)).map(label) == "Sidebar Space-" + suffix }
    let newHeaderFrame = try requireFrame(element(newHeaderID)!)
    try drag(element(newHeaderID)!, to: CGPoint(x: newHeaderFrame.midX + 120, y: newHeaderFrame.midY))
    try waitFor("mouse swipe returns to first space") {
        guard let tabFrame = row(a).flatMap(elementFrame),
              let sidebarFrame = element("browser.sidebar").flatMap(elementFrame) else { return false }
        return tabFrame.minX >= sidebarFrame.minX && tabFrame.maxX <= sidebarFrame.maxX
    }
    let newButtonFrame = try requireFrame(element(id(newSpaceButton))!)
    clickAt(CGPoint(x: newButtonFrame.midX, y: newButtonFrame.midY), button: .right)
    try waitFor("Delete Space menu") { menuItem("Delete Space") != nil }
    try press(menuItem("Delete Space")!)
    try waitFor("test space removed") { spaceButtons().count == existingSpaceIDs.count }
    try require(row(a) != nil && row(renamedC) != nil, "Deleting the test space must preserve the original space")
    print("PASS spaces: create, rename, mouse swipe, context-menu delete")
}

do {
    try MainActor.assumeIsolated { try verifySidebar() }
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
