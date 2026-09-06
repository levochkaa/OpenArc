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

@MainActor func verifyWebApp() throws {
    guard CommandLine.arguments.count == 2 else { throw UIError.failed("Pass the built TheBrowser.app bundle") }
    let host = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    let temporary = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("TheBrowser-WebApp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try "<html><head><title>Native Web App Fixture</title></head><body>Native Web App Fixture. Find this sample.</body></html>"
        .write(
            to: temporary.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.currentDirectoryURL = temporary
    server.arguments = [
        "-u",
        "-c",
        "import http.server,pathlib; s=http.server.ThreadingHTTPServer(('127.0.0.1',0),http.server.SimpleHTTPRequestHandler); pathlib.Path('port').write_text(str(s.server_port)); s.serve_forever()",
    ]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer {
        if server.isRunning {
            server.terminate()
        }
    }
    let portFile = temporary.appendingPathComponent("port")
    try waitFor("local fixture server") { FileManager.default.fileExists(atPath: portFile.path) }
    let port = try String(contentsOf: portFile, encoding: .utf8)
    let url = "http://127.0.0.1:\(port)/"
    let fixtureBundle = temporary.appendingPathComponent("Native Web App.app")
    let contents = fixtureBundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "com.thebrowser.native-webapp-verification",
        "CFBundleName": "Native Web App", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        "TheBrowserWebAppIdentifier": "native-ui-verification-\(UUID().uuidString)",
        "TheBrowserWebAppName": "Native Web App", "TheBrowserWebAppStartURL": url, "TheBrowserWebAppScopeURL": url,
        "TheBrowserWebAppProfileDirectoryName": "Default", "TheBrowserWebAppProfileName": "Verification",
        "TheBrowserHostBundlePath": host.path,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = ["--web-app-bundle=\(fixtureBundle.path)"]
    var launched: NSRunningApplication?
    var launchError: Error?
    NSWorkspace.shared
        .openApplication(at: host, configuration: configuration) { app, error in
            Task { @MainActor in launched = app
                launchError = error
            }
        }
    try waitFor("web app launch") { launched != nil || launchError != nil }
    guard let app = launched else { throw launchError ?? UIError.failed("Launch failed") }
    defer { app.terminate() }
    let pid = app.processIdentifier
    let ax = AXUIElementCreateApplication(pid)
    func elements() -> [AXUIElement] { (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [])
        .flatMap { descendants($0) }
    }
    func id(_ e: AXUIElement) -> String { attribute(e, kAXIdentifierAttribute) as? String ?? "" }
    func element(_ value: String) -> AXUIElement? { elements().first { id($0) == value } }
    func value(_ identifier: String) -> String? { element(identifier)
        .flatMap { attribute($0, kAXValueAttribute) as? String }
    }
    func press(_ e: AXUIElement) throws { try require(
        AXUIElementPerformAction(e, kAXPressAction as CFString) == .success,
        "Cannot press \(id(e))"
    ) }
    func click(_ e: AXUIElement) throws {
        guard let frame = elementFrame(e) else { throw UIError.failed("Missing frame") }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
    }
    func menuItem(_ title: String) -> AXUIElement? { descendants(ax)
        .first { attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole && attribute(
            $0,
            kAXTitleAttribute
        ) as? String == title }
    }
    try waitFor("native web app loaded") { value("browser.webapp.title") == "Native Web App Fixture" }
    app.activate()
    try require(element("browser.webapp.window") != nil, "Web app must have a native root")
    try require(element("browser.sidebar") == nil, "Web app must keep its separate toolbar layout")
    try press(element("browser.webapp.reload")!)
    try waitFor("reload completed") { value("browser.webapp.title") == "Native Web App Fixture" }
    try runAppleScript(
        "click menu item \"Always Show Full URLs\" of menu 1 of menu bar item \"View\" of menu bar 1",
        pid: pid
    )
    try waitFor("full URL title") { value("browser.webapp.title")?.contains("127.0.0.1") == true }
    try runAppleScript(
        "click menu item \"Always Show Full URLs\" of menu 1 of menu bar item \"View\" of menu bar 1",
        pid: pid
    )
    try waitFor("page title restored") { value("browser.webapp.title") == "Native Web App Fixture" }
    print("PASS web app: native root, reload and full URL preference")
    try click(element("browser.webapp.more")!)
    try waitFor("web app More menu") { menuItem("App Info") != nil }
    try require(menuItem("Find...") != nil, "More menu must retain Find")
    try press(menuItem("App Info")!)
    try waitFor("App Info") { elements().contains { attribute($0, kAXTitleAttribute) as? String == "Done" } }
    try press(elements().first { attribute($0, kAXTitleAttribute) as? String == "Done" }!)
    try press(element("browser.webapp.extensions")!)
    try waitFor("web app extensions") { element("browser.extensions.control-center") != nil }
    try runAppleScript("key code 53", pid: pid)
    try waitFor("web app extensions closed") { element("browser.extensions.control-center") == nil }
    print("PASS web app: More menu, App Info and extension center")
    guard let main = (attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [])
        .first(where: { window in descendants(window).contains { id($0) == "browser.webapp.window" } })
    else { throw UIError.failed("Missing web app window") }
    try require(
        AXUIElementSetAttributeValue(main, "AXFullScreen" as CFString, kCFBooleanTrue) == .success,
        "Cannot enter fullscreen"
    )
    try waitFor("web app fullscreen") { attribute(main, "AXFullScreen") as? Bool == true }
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    try waitFor("fullscreen hides web app toolbar") { element("browser.webapp.more") == nil }
    try runAppleScript(
        "click menu item \"Always Show Toolbar in Full Screen\" of menu 1 of menu bar item \"View\" of menu bar 1",
        pid: pid
    )
    try waitFor("fullscreen toolbar preference") { element("browser.webapp.more") != nil }
    try require(
        AXUIElementSetAttributeValue(main, "AXFullScreen" as CFString, kCFBooleanFalse) == .success,
        "Cannot exit fullscreen"
    )
    try waitFor("web app window restored") { attribute(main, "AXFullScreen") as? Bool != true }
    print("PASS web app: fullscreen toolbar hiding and persistent toolbar preference")
}

do { try MainActor.assumeIsolated { try verifyWebApp() } }
catch { fputs("FAIL \(error)\n", stderr)
    exit(1)
}
