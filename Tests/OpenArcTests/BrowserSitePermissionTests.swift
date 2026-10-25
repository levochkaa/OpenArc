import AppKit
import Foundation
import Testing

// MARK: - SitePermissionFixture

@MainActor private final class SitePermissionFixture {
    // MARK: Lifecycle

    /// Windows of one app share `store`, as they share the app's.
    init(
        mode: BrowserWindowMode = .normal,
        defaults existing: UserDefaults? = nil,
        store: BrowserUserPreferencesStore? = nil
    ) throws {
        let suite = "BrowserSitePermissionTests.\(UUID().uuidString)"
        self.suite = suite
        let defaults = try existing ?? #require(UserDefaults(suiteName: suite))
        let driver = FakeBrowserTabDriver()
        self.defaults = defaults
        self.driver = driver
        self.model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(),
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: store ?? BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            windowMode: mode,
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {}
        )
        // macOS has already let OpenArc use the camera and microphone.
        model.requestSystemMediaCaptureAuthorization = { _, completion in completion(true) }
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        model.createNewTab()
        driver.flushPendingCreateEvents()
    }

    // MARK: Internal

    let suite: String
    let defaults: UserDefaults
    let driver: FakeBrowserTabDriver
    let model: BrowserChromeModel

    var selectedTabID: String {
        model.selectedTabID ?? ""
    }

    func request(
        _ id: Int,
        tabID: String? = nil,
        origin: String = "https://meet.google.com",
        kinds: [BrowserSitePermissionKind] = [.camera, .microphone],
        media: Bool = true
    ) {
        driver.onSitePermissionRequested?(BrowserSitePermissionRequest(
            id: id,
            tabID: tabID ?? selectedTabID,
            origin: origin,
            kinds: kinds,
            isMediaAccess: media
        ))
    }

    func resolutions() -> [String] {
        driver.sitePermissionResolutions.map { "\($0.id):\($0.allowed.map { $0 ? "allow" : "block" } ?? "dismiss")" }
    }

    func cleanup(removingDefaults: Bool = true) {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        if removingDefaults {
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor @Test func cameraAndMicrophoneAnswersAreRememberedPerOriginAndProfile() throws {
    let fixture = try SitePermissionFixture()
    defer { fixture.cleanup() }
    fixture.request(1)
    #expect(fixture.model.visibleSitePermissionRequest?.id == 1)
    #expect(fixture.resolutions().isEmpty)

    fixture.model.answerSitePermissionRequest(id: 1, allowed: true)
    #expect(fixture.model.sitePermissionRequests.isEmpty)
    #expect(fixture.resolutions() == ["1:allow"])
    #expect(fixture.model.rememberedSitePermissions.map(\.kind) == [.camera, .microphone])

    // The same origin, any page, is answered without a prompt.
    fixture.request(2, origin: "https://meet.google.com:443")
    fixture.request(3, kinds: [.microphone])
    #expect(fixture.model.sitePermissionRequests.isEmpty)
    #expect(fixture.resolutions() == ["1:allow", "2:allow", "3:allow"])

    // Another origin asks again; Block is remembered too.
    fixture.request(4, origin: "https://zoom.us", kinds: [.camera])
    #expect(fixture.model.visibleSitePermissionRequest?.id == 4)
    fixture.model.answerSitePermissionRequest(id: 4, allowed: false)
    fixture.request(5, origin: "https://zoom.us", kinds: [.camera, .microphone])
    // A blocked kind refuses the whole request: CEF grants all or nothing.
    #expect(fixture.model.sitePermissionRequests.isEmpty)
    #expect(fixture.resolutions().suffix(2) == ["4:block", "5:block"])
    fixture.request(6, origin: "https://zoom.us", kinds: [.microphone])
    #expect(fixture.model.visibleSitePermissionRequest?.id == 6)

    // Forget asks again.
    fixture.model.forgetSitePermissions(forOrigin: "https://meet.google.com")
    fixture.request(7)
    #expect(fixture.model.sitePermissionRequests.map(\.id) == [6, 7])

    // Another profile does not share the answers.
    let other = BrowserSitePermissionDecision.remembered(
        for: BrowserSitePermissionRequest(
            id: 8,
            tabID: "t",
            origin: "https://zoom.us",
            kinds: [.camera],
            isMediaAccess: true
        ),
        profileID: "another-profile",
        in: fixture.model.userPreferencesStore.sitePermissionDecisions
    )
    #expect(other == nil)
}

@MainActor @Test func incognitoWindowsKeepTheirOwnAnswersUntilTheyClose() throws {
    let normal = try SitePermissionFixture()
    defer { normal.cleanup() }
    normal.request(1)
    normal.model.answerSitePermissionRequest(id: 1, allowed: true)

    let incognito = try SitePermissionFixture(
        mode: .incognito,
        defaults: normal.defaults,
        store: normal.model.userPreferencesStore
    )
    defer { incognito.cleanup(removingDefaults: false) }
    incognito.request(1)
    #expect(incognito.model.visibleSitePermissionRequest?.id == 1)
    incognito.model.answerSitePermissionRequest(id: 1, allowed: false)
    // The window's answer covers its next request without touching the profile's.
    incognito.request(2, kinds: [.microphone])
    #expect(incognito.resolutions() == ["1:block", "2:block"])
    #expect(incognito.model.rememberedSitePermissions.map(\.allowed) == [false, false])
    #expect(normal.model.userPreferencesStore.sitePermissionDecisions.map(\.allowed) == [true, true])
}

@MainActor @Test func anAnswerCoversTheOriginsOtherWaitingRequestsInEveryWindow() throws {
    let first = try SitePermissionFixture()
    defer { first.cleanup() }
    let second = try SitePermissionFixture(defaults: first.defaults, store: first.model.userPreferencesStore)
    defer { second.cleanup(removingDefaults: false) }
    let other = first.selectedTabID
    first.model.createNewTab()
    first.driver.flushPendingCreateEvents()

    first.request(1)
    first.request(2, tabID: other, kinds: [.camera])
    first.request(3, origin: "https://zoom.us")
    second.request(4, kinds: [.microphone])
    // Another origin and Chromium's own prompts still ask.
    second.request(5, kinds: [.location], media: false)
    first.model.answerSitePermissionRequest(id: 1, allowed: true)
    #expect(first.resolutions() == ["1:allow", "2:allow"])
    #expect(first.model.sitePermissionRequests.map(\.id) == [3])
    #expect(second.resolutions() == ["4:allow"])
    #expect(second.model.sitePermissionRequests.map(\.id) == [5])
}

@MainActor @Test func chromiumPromptsAreNotRememberedAndCanBeDismissed() throws {
    let fixture = try SitePermissionFixture()
    defer { fixture.cleanup() }
    fixture.request(1, origin: "https://maps.example", kinds: [.location], media: false)
    fixture.model.answerSitePermissionRequest(id: 1, allowed: true)
    fixture.request(2, origin: "https://maps.example", kinds: [.location], media: false)
    #expect(fixture.model.visibleSitePermissionRequest?.id == 2)
    #expect(fixture.model.rememberedSitePermissions.isEmpty)

    // Close answers nothing; a request the engine withdraws just goes away.
    fixture.model.dismissSitePermissionRequest(id: 2)
    fixture.request(3, origin: "https://maps.example", kinds: [.clipboard], media: false)
    fixture.driver.onSitePermissionRequestDismissed?(3)
    #expect(fixture.model.sitePermissionRequests.isEmpty)
    #expect(fixture.resolutions() == ["1:allow", "2:dismiss"])

    // A request without a kind the prompt can name is dismissed at once.
    fixture.request(4, kinds: [], media: false)
    #expect(fixture.resolutions().last == "4:dismiss")
}

@MainActor @Test func notificationsWaitForTheSystemsPermission() async throws {
    let fixture = try SitePermissionFixture()
    defer { fixture.cleanup() }
    var systemAnswer: (@Sendable (Bool) -> Void)?
    fixture.model
        .requestSystemNotificationAuthorization = { systemAnswer = $0 }
    fixture.request(1, origin: "https://mail.example", kinds: [.notifications], media: false)
    fixture.model.answerSitePermissionRequest(id: 1, allowed: true)
    #expect(fixture.resolutions().isEmpty)
    systemAnswer?(false)
    // The answer hops to the main queue.
    for _ in 0..<100 where fixture.resolutions().isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    // A system refusal leaves the site unanswered, so it can ask again later.
    #expect(fixture.resolutions() == ["1:dismiss"])

    // Block does not ask the system.
    systemAnswer = nil
    fixture.request(2, origin: "https://mail.example", kinds: [.notifications], media: false)
    fixture.model.answerSitePermissionRequest(id: 2, allowed: false)
    #expect(systemAnswer == nil)
    #expect(fixture.resolutions().last == "2:block")
}

@MainActor @Test func cameraAndMicrophoneWaitForMacOSWhoseRefusalLeavesTheSiteUnanswered() throws {
    let fixture = try SitePermissionFixture()
    defer { fixture.cleanup() }
    var asked = [[BrowserSitePermissionKind]]()
    var systemAnswer: (@MainActor (Bool) -> Void)?
    fixture.model
        .requestSystemMediaCaptureAuthorization = { kinds, completion in
            asked.append(kinds)
            systemAnswer = completion
        }
    fixture.request(1)
    fixture.model.answerSitePermissionRequest(id: 1, allowed: true)
    #expect(asked == [[.camera, .microphone]])
    #expect(fixture.resolutions().isEmpty)
    // macOS refused: the site stays allowed, and the page gets no answer.
    systemAnswer?(false)
    #expect(fixture.resolutions() == ["1:dismiss"])
    #expect(fixture.model.rememberedSitePermissions.map(\.allowed) == [true, true])

    // The remembered answer also waits for macOS, which now allows.
    fixture.request(2)
    #expect(asked.count == 2)
    systemAnswer?(true)
    #expect(fixture.resolutions().last == "2:allow")

    // Block does not ask macOS.
    asked = []
    fixture.request(3, origin: "https://other.example", kinds: [.microphone])
    fixture.model.answerSitePermissionRequest(id: 3, allowed: false)
    #expect(asked.isEmpty)
    #expect(fixture.resolutions().last == "3:block")
}

@MainActor @Test func onlyRequestsOfPagesOnScreenAreShownAndTheEngineWithdrawsThem() throws {
    let fixture = try SitePermissionFixture()
    defer { fixture.cleanup() }
    let first = fixture.selectedTabID
    fixture.model.createNewTab()
    fixture.driver.flushPendingCreateEvents()
    let second = fixture.selectedTabID
    #expect(first != second)

    fixture.request(1, tabID: first)
    #expect(fixture.model.visibleSitePermissionRequest == nil)
    fixture.model.selectTab(id: first)
    #expect(fixture.model.visibleSitePermissionRequest?.id == 1)

    // An address change alone keeps it: the request may come from a frame of
    // another origin, and only a new document withdraws it, in the engine.
    fixture.driver.emitUpdate(id: first, urlString: "https://example.com/#call")
    #expect(fixture.model.sitePermissionRequests.map(\.id) == [1])
    fixture.driver.onSitePermissionRequestDismissed?(1)
    #expect(fixture.model.sitePermissionRequests.isEmpty)
    #expect(fixture.resolutions().isEmpty)
}

@MainActor @Test func peekCardsShowTheirOwnRequestsAndUseRememberedAnswers() throws {
    let fixture = try SitePermissionFixture()
    defer { fixture.cleanup() }
    fixture.request(1)
    fixture.request(2, tabID: "peek:7", origin: "https://zoom.us")
    fixture.request(3, tabID: "peek:7", origin: "https://zoom.us", kinds: [.location], media: false)
    // The window's prompt keeps to its tabs; the card gets its own requests.
    #expect(fixture.model.visibleSitePermissionRequest?.id == 1)
    #expect(fixture.driver.peekSitePermissionRequests.map(\.id) == [2, 3])
    #expect(fixture.driver.peekSitePermissionRequests.first?.peekSessionID == 7)

    fixture.driver.onPeekSitePermissionAnswered?(2, true)
    fixture.driver.onPeekSitePermissionAnswered?(3, nil)
    #expect(fixture.resolutions() == ["2:allow", "3:dismiss"])
    #expect(fixture.driver.peekSitePermissionRequests.isEmpty)

    // A remembered answer applies in a card without a prompt.
    fixture.request(4, tabID: "peek:8", origin: "https://zoom.us", kinds: [.camera])
    #expect(fixture.resolutions().last == "4:allow")
    #expect(fixture.driver.peekSitePermissionRequests.isEmpty)
}

@Test func sitePermissionOriginsCompareWithoutDefaultPortsOrCase() {
    #expect(BrowserSitePermissionRequest
        .origin(ofURLString: "https://Meet.Google.com:443/abc?x=1") == "https://meet.google.com")
    #expect(BrowserSitePermissionRequest.origin(ofURLString: "http://localhost:3000/") == "http://localhost:3000")
    #expect(BrowserSitePermissionRequest.origin(ofURLString: "about:blank") == nil)
    let request = BrowserSitePermissionRequest(
        id: 1,
        tabID: "t",
        origin: "https://meet.google.com:8443/",
        kinds: [.camera],
        isMediaAccess: true
    )
    #expect(request.displayOrigin == "meet.google.com:8443")
}

@MainActor @Test func contentViewShowsTheVisibleRequestAndAnswersIt() throws {
    let fixture = try SitePermissionFixture()
    defer { fixture.cleanup() }
    let content = BrowserContentNSView(hostView: fixture.model.hostView)
    content.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    content.bindTabCreation(to: fixture.model)
    content.update(
        hostView: fixture.model.hostView,
        isContextReady: true,
        hasSelectedTab: true,
        isSidebarVisible: true,
        usesWindowContentInsets: true
    )
    #expect(content.permissionPrompt.isHidden)

    fixture.request(1)
    content.refreshPermissionPrompt()
    content.layoutSubtreeIfNeeded()
    #expect(!content.permissionPrompt.isHidden)
    #expect(content.permissionPrompt.request?.id == 1)
    #expect(content.permissionPrompt.frame.minX == 12)
    #expect(content.permissionPrompt.frame.width == BrowserSitePermissionPromptView.width)
    let allow = try #require(sitePermissionView("browser.site-permission.allow", in: content) as? BrowserActionButton)
    #expect(sitePermissionView("browser.site-permission.kind.camera", in: content) != nil)
    #expect(sitePermissionView("browser.site-permission.kind.microphone", in: content) != nil)
    allow.performClick(nil)
    #expect(fixture.resolutions() == ["1:allow"])
    content.refreshPermissionPrompt()
    #expect(content.permissionPrompt.isHidden)

    // A new request ignores input for half a second, so a double click on
    // one prompt cannot answer the next.
    fixture.request(2, origin: "https://zoom.us")
    content.refreshPermissionPrompt()
    let now = ProcessInfo.processInfo.systemUptime
    #expect(!content.permissionPrompt.acceptsInput(at: now))
    #expect(content.permissionPrompt.acceptsInput(at: now + BrowserSitePermissionPromptView.inputDelay))
}

@MainActor private func sitePermissionView(_ identifier: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == identifier {
        return view
    }
    for subview in view.subviews {
        if let match = sitePermissionView(identifier, in: subview) {
            return match
        }
    }
    return nil
}
