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

@Test func aScopedSnapshotShowsOnlyThatElement() {
    var refs = [Int: String]()
    let tree: [String: Any] = ["nodes": [
        axNode("1", role: "RootWebArea", children: ["2", "3"]),
        axNode("2", role: "navigation", name: "Top", backend: 20, parent: "1", children: ["4"]),
        axNode("4", role: "link", name: "Home", backend: 40, parent: "2"),
        axNode("3", role: "link", name: "Elsewhere", backend: 30, parent: "1"),
    ]]
    let outline = BrowserAgentSnapshot.outline(
        fromAXTree: tree, interactiveOnly: false, refs: &refs, scope: 20, frames: [:],
    )
    #expect(outline?.contains(#"- navigation "Top""#) == true)
    #expect(outline?.contains(#"link "Home""#) == true)
    #expect(outline?.contains("Elsewhere") == false)
    #expect(BrowserAgentSnapshot.outline(
        fromAXTree: tree, interactiveOnly: false, refs: &refs, scope: 999, frames: [:],
    ) == nil, "An element without an accessibility node gives no outline")
}

@Test func aFramesOutlineSitsUnderItsFrameWithRefsOfItsOwn() {
    var refs = [Int: String]()
    let tree: [String: Any] = ["nodes": [
        axNode("1", role: "RootWebArea", children: ["2", "3"]),
        axNode("2", role: "button", name: "Outside", backend: 20, parent: "1"),
        axNode("3", role: "Iframe", backend: 30, parent: "1"),
    ]]
    // A frame numbers its accessibility nodes from 1 as well.
    let frame: [String: Any] = ["nodes": [
        axNode("1", role: "RootWebArea", children: ["2"]),
        axNode("2", role: "button", name: "Inside", backend: 70, parent: "1"),
    ]]
    let outline = BrowserAgentSnapshot.outline(
        fromAXTree: tree, interactiveOnly: false, refs: &refs, scope: nil, frames: [30: frame],
    ) ?? ""
    #expect(outline.contains(#"- button "Outside" [ref=e1]"#))
    #expect(outline.contains(#"  - button "Inside" [ref=e2]"#), "\(outline)")
    #expect(refs[70] == "e2")
}

@Test func aDiffShowsOnlyWhatChangedUnderItsContext() {
    let before = "- heading \"Cart\"\n  - button \"Add\" [ref=e1]\n  - text \"0 items\""
    let after = "- heading \"Cart\"\n  - button \"Add\" [ref=e1]\n  - text \"1 item\""
    let diff = BrowserAgentSnapshot.diff(from: before, to: after)
    #expect(diff == "    - button \"Add\" [ref=e1]\n-   - text \"0 items\"\n+   - text \"1 item\"")
    #expect(BrowserAgentSnapshot.diff(from: after, to: after) == "(no changes)")
}

@Test func newRefsNeverReuseANameAfterNodesLeave() {
    var refs = [30: "e1", 40: "e5"]
    _ = BrowserAgentSnapshot.outline(fromAXTree: page, interactiveOnly: true, refs: &refs)
    #expect(refs[50] == "e6", "A new node takes a name after the highest, not after the count")
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

@Test @MainActor func profilesNotesAndHistoryAreAnsweredForTheWindow() async throws {
    let (model, _) = makeModel(store: nil)
    model.notesStore = BrowserNotesStore()
    let note = model.notesStore.createNote(title: "Trip", markdown: "Flight to Tbilisi on Friday")
    let service = BrowserAgentService(models: { [model] }, approveSignIn: { _, _ in false })

    let profiles = try await service.handle(method: "profiles", params: [:]) as? [[String: Any]]
    #expect(profiles?.first?["id"] as? String == model.profile.id)
    #expect(profiles?.first?["selected"] as? Bool == true)

    let found = try await service.handle(method: "notes", params: ["query": "tbilisi"]) as? [[String: Any]]
    #expect(found?.first?["id"] as? String == note.id)
    let read = try await service.handle(method: "note", params: ["id": note.id]) as? [String: Any]
    #expect(read?["markdown"] as? String == "Flight to Tbilisi on Friday")

    let history = try await service.handle(method: "history", params: [:]) as? [[String: Any]]
    #expect(history?.isEmpty == true, "A window without stored history answers with none")

    let missing = await service.respond(toLine: #"{"method":"tabs","params":{"profile":"Nobody"}}"#)
    #expect(missing.contains("No open window has the profile"))
}
