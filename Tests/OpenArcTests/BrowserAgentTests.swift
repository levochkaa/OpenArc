// BrowserAgentTests.swift

import Foundation
import Testing

private func axNode(
    _ id: String,
    role: String,
    name: String = "",
    backend: Int? = nil,
    parent: String? = nil,
    children: [String] = [],
    value: String? = nil,
    properties: [[String: Any]] = [],
) -> [String: Any] {
    var node: [String: Any] = [
        "nodeId": id,
        "ignored": false,
        "role": ["value": role],
        "name": ["value": name],
        "childIds": children,
        "properties": properties,
    ]
    if let backend { node["backendDOMNodeId"] = backend }
    if let parent { node["parentId"] = parent }
    if let value { node["value"] = ["value": value] }
    return node
}

private nonisolated(unsafe) let page: [String: Any] = ["nodes": [
    axNode("1", role: "RootWebArea", name: "Page", children: ["2", "3", "4", "5"]),
    axNode("2", role: "heading", name: "Welcome", parent: "1", properties: [["name": "level", "value": ["value": 1]]]),
    axNode("3", role: "link", name: "More", backend: 30, parent: "1"),
    axNode("4", role: "textbox", name: "Email", backend: 40, parent: "1", value: "a@b.c"),
    axNode(
        "5",
        role: "checkbox",
        name: "Keep",
        backend: 50,
        parent: "1",
        properties: [["name": "checked", "value": ["value": true]]],
    ),
]]

@Test func aSnapshotPutsRefsOnWhatCanBeActedOn() {
    var refs = [Int: String]()
    let outline = BrowserAgentSnapshot.outline(fromAXTree: page, interactiveOnly: false, refs: &refs)
    #expect(outline.contains(#"- heading "Welcome""#))
    #expect(outline.contains(#"- link "More" [ref=e1]"#))
    #expect(outline.contains(#"- textbox "Email" [ref=e2] value="a@b.c""#))
    #expect(outline.contains(#"- checkbox "Keep" [ref=e3] [checked]"#))
    #expect(!outline.contains("RootWebArea"))
}

@Test func anInteractiveSnapshotDropsTextAndRefsSurviveARefresh() {
    var refs = [50: "e9"]
    let outline = BrowserAgentSnapshot.outline(fromAXTree: page, interactiveOnly: true, refs: &refs)
    #expect(!outline.contains("heading"))
    #expect(outline.contains("[ref=e9]"), "A node keeps the ref it already had")
    #expect(refs[30] != nil)
}

@Test func keysGoByTheirUsualNames() {
    #expect(BrowserAgentSnapshot.keyEvent(named: "Enter")?.text == "\r")
    #expect(BrowserAgentSnapshot.keyEvent(named: "arrowdown")?.virtualCode == 40)
    #expect(BrowserAgentSnapshot.keyEvent(named: "a")?.code == "KeyA")
    #expect(BrowserAgentSnapshot.keyEvent(named: "no-such-key") == nil)
}

@MainActor private func makeModel(store: BrowserPasswordStoring?) -> (BrowserChromeModel, FakeBrowserTabDriver) {
    let driver = FakeBrowserTabDriver()
    let defaults = UserDefaults(suiteName: BrowserTestDefaults.suiteName("OpenArcAgentTests"))!
    let model = BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: InMemorySessionSnapshotStore(loadedSnapshot: BrowserTabSessionSnapshot(tabs: [
            .init(urlString: "https://example.com/login"),
        ])),
        sessionPreferencesStore: InMemorySessionPreferencesStore(storedSelectedTabIndex: 0),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults),
        extensionManager: FakeBrowserExtensionManager(),
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {},
    )
    model.handleContextReady()
    driver.flushPendingCreateEvents()
    for tab in model.tabs {
        driver.emitTabCreationState(id: tab.id, state: .ready)
    }
    model.passwordStore = store
    return (model, driver)
}

// MARK: - OneLoginStore

private final class OneLoginStore: BrowserPasswordStoring {
    func allLogins() -> [BrowserSavedLogin] { [.init(origin: "https://example.com", username: "me")] }
    func password(for _: BrowserSavedLogin) -> String? { "hunter2" }
    func save(_: String, for _: BrowserSavedLogin) -> Bool { true }
    func delete(_: BrowserSavedLogin) {}
}

@Test @MainActor func aPasswordIsTypedByTheBrowserAndNeverReachesTheAgent() async throws {
    let (model, driver) = makeModel(store: OneLoginStore())
    var asked = [String]()
    let service = BrowserAgentService(models: { [model] }, approveSignIn: { user, host in
        asked.append("\(user)@\(host)")
        return true
    })
    let logins = try await service.handle(method: "logins", params: [:]) as? [[String: Any]]
    #expect(logins?.first?["username"] as? String == "me")
    #expect(!String(describing: logins).contains("hunter2"))

    let line = await service.respond(toLine: #"{"id":1,"method":"signin","params":{}}"#)
    #expect(!line.contains("hunter2"), "The answer names the login only")
    #expect(line.contains(#""signedInAs":"me""#))
    #expect(asked == ["me@example.com"])
    #expect(driver.mainFrameFills.first?.password == "hunter2")

    let evaluated = await service.respond(toLine: #"{"id":2,"method":"eval","params":{"script":"1"}}"#)
    #expect(evaluated.contains("Scripts are off"), "A filled page can't be read back with a script")
}

@Test @MainActor func aDeclinedSignInFillsNothing() async {
    let (model, driver) = makeModel(store: OneLoginStore())
    let service = BrowserAgentService(models: { [model] }, approveSignIn: { _, _ in false })
    let line = await service.respond(toLine: #"{"method":"signin"}"#)
    #expect(line.contains("declined"))
    #expect(driver.mainFrameFills.isEmpty)
}

@Test @MainActor func scriptAddressesAreRefused() async {
    let (model, driver) = makeModel(store: nil)
    let service = BrowserAgentService(models: { [model] }, approveSignIn: { _, _ in true })
    let line = await service.respond(toLine: #"{"method":"navigate","params":{"url":"javascript:alert(1)"}}"#)
    #expect(line.contains("is not an address"))
    #expect(driver.targetedNavigationRequests.isEmpty)
}

@Test func screenShareSourcesUseChromiumsNames() {
    #expect(BrowserScreenShareSource.screen(id: 1, title: "Screen").mediaID == "screen:1:0")
    #expect(BrowserScreenShareSource.window(id: 9, title: "Doc", app: "Pages").mediaID == "window:9:0")
}
