import AppKit
import Foundation
import Testing

// MARK: - SitePermissionFixture

@MainActor private final class SitePermissionFixture {
    // MARK: Lifecycle

    init(mode: BrowserWindowMode = .normal, defaults existing: UserDefaults? = nil) throws {
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
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            windowMode: mode,
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {}
        )
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

@MainActor @Test func incognitoWindowsNeitherUseNorRememberAnswers() throws {
    let normal = try SitePermissionFixture()
    defer { normal.cleanup() }
    normal.request(1)
    normal.model.answerSitePermissionRequest(id: 1, allowed: true)

    let incognito = try SitePermissionFixture(mode: .incognito, defaults: normal.defaults)
    defer { incognito.cleanup(removingDefaults: false) }
    incognito.request(1)
    #expect(incognito.model.visibleSitePermissionRequest?.id == 1)
    incognito.model.answerSitePermissionRequest(id: 1, allowed: false)
    #expect(incognito.resolutions() == ["1:block"])
    #expect(normal.model.userPreferencesStore.sitePermissionDecisions.map(\.allowed) == [true, true])
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
    #expect(fixture.resolutions() == ["1:block"])

    // Block does not ask the system.
    systemAnswer = nil
    fixture.request(2, origin: "https://mail.example", kinds: [.notifications], media: false)
    fixture.model.answerSitePermissionRequest(id: 2, allowed: false)
    #expect(systemAnswer == nil)
    #expect(fixture.resolutions().last == "2:block")
}

@MainActor @Test func onlyRequestsOfPagesOnScreenAreShownAndLeavingTheOriginWithdrawsThem() throws {
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

    // Same origin keeps the request; another origin withdraws it.
    fixture.driver.emitUpdate(id: first, urlString: "https://meet.google.com/abc-defg-hij")
    #expect(fixture.model.sitePermissionRequests.map(\.id) == [1])
    fixture.driver.emitUpdate(id: first, urlString: "https://example.com/")
    #expect(fixture.model.sitePermissionRequests.isEmpty)
    #expect(fixture.resolutions() == ["1:dismiss"])
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
