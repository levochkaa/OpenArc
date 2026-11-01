// BrowserScriptingTests.swift

import AppKit
import Foundation
import Testing

// MARK: - BrowserScriptingTests

@MainActor struct BrowserScriptingTests {
    // MARK: Internal

    @Test func aWindowListsItsSpacesAndTabs() {
        let (model, driver, window) = makeWindow()
        model.createNewTab()
        driver.flushPendingCreateEvents()
        #expect(window.appleScriptSpaces.map(\.id) == model.spaces.map(\.id))
        #expect(window.appleScriptTabs.map(\.id) == model.tabs.map(\.id))
        #expect(window.activeTab?.id == model.selectedTabID)
        #expect(window.activeSpace?.id == model.selectedSpaceID)
        #expect(!window.isIncognito)
        #expect(window.mode == "normal")
    }

    @Test func aMadeTabOpensItsURLWhenInserted() {
        let (model, driver, window) = makeWindow()
        let count = model.tabs.count
        let tab = BrowserScriptTab()
        tab.URL = "https://example.com/"
        #expect(tab.pendingURLString == "https://example.com/")
        window.insertInAppleScriptTabs(tab)
        driver.flushPendingCreateEvents()
        #expect(model.tabs.count == count + 1)
        #expect(tab.pendingURLString == nil)
        #expect(tab.id == model.selectedTabID)
        #expect(tab.URL.hasPrefix("https://example.com"))
    }

    @Test func locationPinsAndUnpins() throws {
        let (model, driver, window) = makeWindow()
        model.createNewTab()
        driver.flushPendingCreateEvents()
        let tab = try #require(window.activeTab)
        #expect(tab.location == "unpinned")
        tab.location = "pinned"
        #expect(tab.location == "pinned")
        tab.location = "unpinned"
        #expect(tab.location == "unpinned")
    }

    @Test func javaScriptStaysOffUntilAllowed() throws {
        let (model, driver, window) = makeWindow()
        model.createNewTab()
        driver.flushPendingCreateEvents()
        let tab = try #require(window.activeTab)
        let command = NSScriptCommand()
        command.arguments = ["javascript": "1+1"]
        #expect(!model.userPreferencesStore.allowsJavaScriptFromAppleEvents)
        #expect(tab.executeJavascript(command) == nil)
    }

    // MARK: Private

    private func makeWindow() -> (BrowserChromeModel, FakeBrowserTabDriver, BrowserScriptWindow) {
        let driver = FakeBrowserTabDriver()
        let defaults = UserDefaults(suiteName: "OpenArcScriptingTests.\(UUID().uuidString)")!
        let model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(),
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(extensions: []),
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true,
        )
        window.isReleasedWhenClosed = false
        return (model, driver, BrowserScriptWindow(window: window, model: model))
    }
}

@Test @MainActor func localServersStartInDeveloperModeUntilTurnedOff() {
    var hosts = BrowserDeveloperModeHosts()
    #expect(hosts.isEnabled(host: "localhost"))
    #expect(hosts.isEnabled(host: "127.0.0.1"))
    #expect(!hosts.isEnabled(host: "example.com"))
    hosts.set(false, host: "localhost")
    #expect(!hosts.isEnabled(host: "localhost"))
    hosts.set(true, host: "localhost")
    #expect(hosts.isEnabled(host: "localhost"))
    #expect(hosts.enabled.isEmpty, "A default host needs no entry of its own")
    hosts.set(true, host: "example.com")
    #expect(hosts.isEnabled(host: "example.com"))
    hosts.set(false, host: "example.com")
    #expect(!hosts.isEnabled(host: "example.com"))
    #expect(BrowserChromeModel.developerModeHost(ofURLString: "https://Example.com/a") == "example.com")
    #expect(BrowserChromeModel.developerModeHost(ofURLString: "openarc://settings") == nil)
}

@Test @MainActor func tabVolumeIsRememberedForTheMiniPlayer() throws {
    let driver = FakeBrowserTabDriver()
    let defaults = try #require(UserDefaults(suiteName: "OpenArcVolumeTests.\(UUID().uuidString)"))
    let model = BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: InMemorySessionSnapshotStore(),
        sessionPreferencesStore: InMemorySessionPreferencesStore(),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults),
        extensionManager: FakeBrowserExtensionManager(extensions: []),
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {},
    )
    model.setMediaVolume(0.25, tabID: "tab")
    #expect(model.tabMediaVolumes["tab"] == 0.25)
}

@Test @MainActor func onlyPinnedSiteTabsOfferARecentPagesPreview() throws {
    let driver = FakeBrowserTabDriver()
    let defaults = try #require(UserDefaults(suiteName: "OpenArcPreviewTests.\(UUID().uuidString)"))
    let model = BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: InMemorySessionSnapshotStore(
            loadedSnapshot: .init(tabURLStrings: ["https://linear.app/team"]),
        ),
        sessionPreferencesStore: InMemorySessionPreferencesStore(),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults),
        extensionManager: FakeBrowserExtensionManager(extensions: []),
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {},
    )
    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let id = try #require(model.selectedTabID)
    #expect(try model.recentPagesPreviewID(forTab: #require(model.tabs.first { $0.id == id })) == nil)
    model.togglePinned(forTabID: id)
    #expect(try model.recentPagesPreviewID(forTab: #require(model.tabs.first { $0.id == id })) != nil)
    #expect(!model.openRecentPagePreviewItem(id: "plain-tab-id"))
}

@Test @MainActor func aLiveFolderFollowsItsPages() throws {
    let driver = FakeBrowserTabDriver()
    let defaults = try #require(UserDefaults(suiteName: "OpenArcLiveFolderTests.\(UUID().uuidString)"))
    let model = BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: InMemorySessionSnapshotStore(),
        sessionPreferencesStore: InMemorySessionPreferencesStore(),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults),
        extensionManager: FakeBrowserExtensionManager(extensions: []),
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {},
    )
    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let spaceID = try #require(model.selectedSpaceID)
    let folderID = try #require(model.createEmptyPinnedFolder(title: "GitHub", inSpaceID: spaceID))
    func urls() -> [String] { model.tabs.filter { $0.pinnedFolderID == folderID }.map(\.urlString) }
    let a = BrowserLivePage(url: "https://github.com/o/r/pull/1", title: "One")
    let b = BrowserLivePage(url: "https://github.com/o/r/pull/2", title: "Two")
    model.syncLiveFolder(id: folderID, pages: [a, b])
    #expect(urls() == [a.url, b.url])
    model.syncLiveFolder(id: folderID, pages: [a, b])
    #expect(urls() == [a.url, b.url], "A second round adds nothing")
    model.syncLiveFolder(id: folderID, pages: [b])
    driver.flushPendingCreateEvents()
    #expect(urls() == [b.url])
}

@Test @MainActor func theGitHubAnswerBecomesAnOutcome() {
    #expect(BrowserGitHubLiveFolderFetcher.outcome(for: nil) == nil)
    #expect(BrowserGitHubLiveFolderFetcher.outcome(for: "") == nil)
    #expect(BrowserGitHubLiveFolderFetcher.outcome(for: "SIGNED_OUT") == .signedOut)
    #expect(BrowserGitHubLiveFolderFetcher.outcome(for: "nonsense") == .failed)
    #expect(
        BrowserGitHubLiveFolderFetcher.outcome(for: #"[{"url":"https://github.com/o/r/pull/1","title":"One"}]"#)
            == .pages([.init(url: "https://github.com/o/r/pull/1", title: "One")]),
    )
}

@Test @MainActor func aSitesOwnSettingsReadAndWriteThroughTheirRows() throws {
    let driver = FakeBrowserTabDriver()
    let defaults = try #require(UserDefaults(suiteName: "OpenArcOwnSettingTests.\(UUID().uuidString)"))
    let model = BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: InMemorySessionSnapshotStore(),
        sessionPreferencesStore: InMemorySessionPreferencesStore(),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults),
        extensionManager: FakeBrowserExtensionManager(extensions: []),
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {},
    )
    let url = "https://example.com/a"
    func developerRow() -> BrowserSiteSettingValue? {
        model.siteSettingRows(forURLString: url).first { $0.kind == .developerMode }?.value
    }
    #expect(developerRow() == .off)
    model.setSiteSetting(.developerMode, value: .on, forURLString: url)
    #expect(developerRow() == .on)
    #expect(model.developerModeHost(forTabURLString: url) == "example.com")
    #expect(model.developerModeHost(forTabURLString: "http://localhost:3000/") == "localhost:3000")
    #expect(BrowserSiteSettingKind.developerMode.choices == [.on, .off])
}

@Test @MainActor func aPendingSplitKeepsItsOrientationOnce() throws {
    let driver = FakeBrowserTabDriver()
    let defaults = try #require(UserDefaults(suiteName: "OpenArcSplitPendingTests.\(UUID().uuidString)"))
    let model = BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: InMemorySessionSnapshotStore(
            loadedSnapshot: .init(tabURLStrings: ["https://example.com/"]),
        ),
        sessionPreferencesStore: InMemorySessionPreferencesStore(),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults),
        extensionManager: FakeBrowserExtensionManager(extensions: []),
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {},
    )
    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.presentSplitViewCommandBar(insertion: .before, orientation: .vertical)
    let pending = try #require(model.takePendingSplitAnchor())
    #expect(pending.insertion == .before)
    #expect(pending.orientation == .vertical)
    #expect(model.pendingSplitOrientation == .horizontal)
}

// MARK: - InMemoryPasswordStore

private final class InMemoryPasswordStore: BrowserPasswordStoring {
    var items = [BrowserSavedLogin: String]()

    func allLogins() -> [BrowserSavedLogin] { Array(items.keys) }
    func password(for login: BrowserSavedLogin) -> String? { items[login] }
    func save(_ password: String, for login: BrowserSavedLogin) -> Bool {
        items[login] = password
        return true
    }

    func delete(_ login: BrowserSavedLogin) { items[login] = nil }
}

// MARK: - BrowserSavedLogin + Hashable

@MainActor private func passwordModel(mode: BrowserWindowMode = .normal)
    -> (BrowserChromeModel, FakeBrowserTabDriver, InMemoryPasswordStore)
{
    let driver = FakeBrowserTabDriver()
    let defaults = UserDefaults(suiteName: "OpenArcPasswordTests.\(UUID().uuidString)")!
    let model = BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: InMemorySessionSnapshotStore(),
        sessionPreferencesStore: InMemorySessionPreferencesStore(),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults),
        extensionManager: FakeBrowserExtensionManager(extensions: []),
        windowMode: mode,
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {},
    )
    let store = InMemoryPasswordStore()
    model.passwordStore = store
    return (model, driver, store)
}

@Test @MainActor func aSubmittedPasswordIsKeptOnlyAfterSaving() {
    let (model, _, store) = passwordModel()
    let login = BrowserSavedLogin(origin: "https://example.com", username: "me")
    model.handlePasswordSubmitted(tabID: "t", urlString: "https://Example.com/login?x=1", username: "me", password: "p")
    #expect(model.passwordPrompt == .save(tabID: "t", login: login, password: "p", isUpdate: false))
    #expect(store.items.isEmpty)
    model.answerPasswordPrompt(save: false)
    #expect(store.items.isEmpty)
    #expect(model.passwordPrompt == nil)
    model.handlePasswordSubmitted(tabID: "t", urlString: "https://example.com/", username: "me", password: "p")
    model.answerPasswordPrompt(save: true)
    #expect(store.items[login] == "p")
    model.handlePasswordSubmitted(tabID: "t", urlString: "https://example.com/", username: "me", password: "p")
    #expect(model.passwordPrompt == nil, "The same password asks nothing")
    model.handlePasswordSubmitted(tabID: "t", urlString: "https://example.com/", username: "me", password: "q")
    #expect(model.passwordPrompt == .save(tabID: "t", login: login, password: "q", isUpdate: true))
    model.neverSavePasswordsFromPromptSite()
    model.handlePasswordSubmitted(tabID: "t", urlString: "https://example.com/", username: "you", password: "r")
    #expect(model.passwordPrompt == nil, "Never holds for the site")
}

@Test @MainActor func aSavedPasswordFillsOnlyItsOriginAfterAChoice() {
    let (model, driver, store) = passwordModel()
    let login = BrowserSavedLogin(origin: "https://example.com", username: "me")
    store.items[login] = "secret"
    store.items[BrowserSavedLogin(origin: "https://other.example", username: "them")] = "theirs"
    model.handlePasswordFormFound(tabID: "t", frameID: "f", urlString: "https://example.com/login")
    #expect(driver.filledPasswords.isEmpty, "Nothing fills by itself")
    #expect(model.passwordPrompt == .fill(
        tabID: "t",
        frameID: "f",
        urlString: "https://example.com/login",
        logins: [login],
    ))
    model.fillPassword(BrowserSavedLogin(origin: "https://other.example", username: "them"))
    #expect(driver.filledPasswords.isEmpty, "Another site's password never goes to this frame")
    model.fillPassword(login)
    #expect(driver.filledPasswords.count == 1)
    #expect(driver.filledPasswords.first?.password == "secret")
    #expect(driver.filledPasswords.first?.origin == "https://example.com")
    model.handlePasswordFormFound(tabID: "t", frameID: "f", urlString: "https://unknown.example/")
    #expect(model.passwordPrompt == nil)
    model.handlePasswordFormFound(tabID: "t", frameID: "f", urlString: "file:///tmp/a.html")
    #expect(model.passwordPrompt == nil)
}

@Test @MainActor func incognitoNeitherKeepsNorOffersPasswords() {
    let (model, _, store) = passwordModel(mode: .incognito)
    store.items[BrowserSavedLogin(origin: "https://example.com", username: "me")] = "secret"
    model.handlePasswordSubmitted(tabID: "t", urlString: "https://example.com/", username: "you", password: "p")
    #expect(model.passwordPrompt == nil)
    model.handlePasswordFormFound(tabID: "t", frameID: "f", urlString: "https://example.com/")
    #expect(model.passwordPrompt == nil)
}

@Test @MainActor func aPromptEndsWithItsTab() {
    let (model, _, _) = passwordModel()
    model.handlePasswordSubmitted(tabID: "gone", urlString: "https://example.com/", username: "me", password: "p")
    #expect(model.passwordPrompt != nil)
    model.dropStalePasswordPrompt()
    #expect(model.passwordPrompt == nil, "No password stays in memory for a closed tab")
}

@Test @MainActor func aPageTranslatesThroughGoogleWithItsAddressIntact() throws {
    let url = try #require(BrowserChromeModel.translatedPageURL(for: "https://example.com/a?b=c&d=e", language: "ru"))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items.first { $0.name == "u" }?.value == "https://example.com/a?b=c&d=e")
    #expect(items.first { $0.name == "tl" }?.value == "ru")
    #expect(BrowserChromeModel.translatedPageURL(for: "openarc://settings", language: "ru") == nil)
}

// MARK: - InMemoryAddressStore

private final class InMemoryAddressStore: BrowserAddressStoring {
    var items = [BrowserSavedAddress]()

    func addresses() -> [BrowserSavedAddress] { items }
    func setAddresses(_ addresses: [BrowserSavedAddress]) { items = addresses }
}

@Test @MainActor func anAddressIsKeptAfterSavingAndFillsAfterAChoice() throws {
    let (model, driver, _) = passwordModel()
    let store = InMemoryAddressStore()
    model.addressStore = store
    let json = #"{"name":"Test Person","address-line1":"1 Example St","postal-code":"12345"}"#
    model.handleAddressSubmitted(tabID: "t", urlString: "https://shop.example/checkout", json: json)
    guard case .saveAddress(_, let address)? = model.passwordPrompt else {
        Issue.record("No question")
        return
    }
    #expect(address.summary == "Test Person, 1 Example St")
    #expect(store.items.isEmpty)
    model.answerPasswordPrompt(save: true)
    #expect(store.items == [address])
    model.handleAddressSubmitted(tabID: "t", urlString: "https://other.example/", json: json)
    #expect(model.passwordPrompt == nil, "The same address asks nothing")
    model.handleAddressFormFound(tabID: "t", frameID: "f", urlString: "https://other.example/order")
    #expect(driver.filledAddresses.isEmpty, "Nothing fills by itself")
    model.fillAddress(address)
    #expect(driver.filledAddresses.first?.origin == "https://other.example")
    #expect(try JSONDecoder().decode(
        [String: String].self,
        from: Data(#require(driver.filledAddresses.first?.json).utf8),
    ) == address.fields)
}

@Test @MainActor func incognitoNeitherKeepsNorOffersAddresses() {
    let (model, _, _) = passwordModel(mode: .incognito)
    let store = InMemoryAddressStore()
    store.items = [BrowserSavedAddress(fields: ["name": "A", "postal-code": "1"])]
    model.addressStore = store
    model.handleAddressFormFound(tabID: "t", frameID: "f", urlString: "https://example.com/")
    #expect(model.passwordPrompt == nil)
    model.handleAddressSubmitted(
        tabID: "t",
        urlString: "https://example.com/",
        json: #"{"name":"B","postal-code":"2","tel":"3"}"#,
    )
    #expect(model.passwordPrompt == nil)
}

@Test @MainActor func aFrameFromAnotherSiteGetsNoAddress() {
    let (model, driver, _) = passwordModel()
    let store = InMemoryAddressStore()
    store.items = [BrowserSavedAddress(fields: ["name": "A", "postal-code": "1"])]
    model.addressStore = store
    driver.emitCreatedTab(id: "t", urlString: "https://shop.example/checkout", isActive: true)
    model.handleAddressFormFound(tabID: "t", frameID: "f", urlString: "https://ads.example/frame")
    #expect(model.passwordPrompt == nil)
    let json = #"{"name":"B","postal-code":"2","tel":"3"}"#
    model.handleAddressSubmitted(tabID: "t", urlString: "https://ads.example/frame", json: json)
    #expect(model.passwordPrompt == nil)
    model.handleAddressFormFound(tabID: "t", frameID: "f", urlString: "https://shop.example/checkout")
    #expect(model.passwordPrompt != nil)
}

// MARK: - InMemoryCardStore

private final class InMemoryCardStore: BrowserCardStoring {
    var items = [BrowserSavedCard]()

    func cards() -> [BrowserSavedCard] { items }
    func setCards(_ cards: [BrowserSavedCard]) { items = cards }
}

private let testCardJSON = #"{"cc-name":"Test Person","cc-number":"4242 4242 4242 4242","cc-exp":"12/30"}"#

@Test func aCardNeedsANumberThatPassesItsCheck() throws {
    #expect(BrowserSavedCard(fields: ["cc-number": "4242 4242 4242 4241"]) == nil)
    #expect(BrowserSavedCard(fields: ["cc-number": "1234"]) == nil)
    #expect(BrowserSavedCard(fields: ["cc-name": "A"]) == nil)
    let card = try #require(BrowserSavedCard(fields: ["cc-number": "4242-4242-4242-4242", "cc-exp": "12/30"]))
    #expect(card.fields["cc-number"] == "4242424242424242")
    #expect(card.summary == "•••• 4242, 12/30")
}

@Test @MainActor func aCardIsKeptAfterSavingAndAsksNothingAgain() {
    let (model, _, _) = passwordModel()
    let store = InMemoryCardStore()
    model.cardStore = store
    model.handleAddressSubmitted(tabID: "t", urlString: "http://shop.example/pay", json: testCardJSON)
    #expect(model.passwordPrompt == nil, "No card from a page without encryption")
    model.handleAddressSubmitted(tabID: "t", urlString: "https://shop.example/pay", json: testCardJSON)
    guard case .saveCard(_, let card)? = model.passwordPrompt else {
        Issue.record("No question")
        return
    }
    #expect(store.items.isEmpty)
    model.answerPasswordPrompt(save: true)
    #expect(store.items == [card])
    model.handleAddressSubmitted(tabID: "t", urlString: "https://other.example/", json: testCardJSON)
    #expect(model.passwordPrompt == nil, "The same card asks nothing")
}

@Test @MainActor func aCardFillsOnlyAfterTheOwnerConfirms() async throws {
    let (model, driver, _) = passwordModel()
    let store = InMemoryCardStore()
    let card = try #require(BrowserSavedCard(fields: ["cc-number": "4242424242424242"]))
    store.items = [card]
    model.cardStore = store
    var answers = [false, true]
    model.authenticateCardUse = { _ in answers.removeFirst() }
    model.handleCardFormFound(tabID: "t", frameID: "f", urlString: "http://shop.example/pay")
    #expect(model.passwordPrompt == nil)
    for expected in [0, 1] {
        model.handleCardFormFound(tabID: "t", frameID: "f", urlString: "https://shop.example/pay")
        #expect(driver.filledAddresses.isEmpty || expected == 1, "Nothing fills by itself")
        model.fillCard(card)
        for _ in 0..<50 where driver.filledAddresses.count < expected {
            await Task.yield()
        }
        await Task.yield()
        #expect(driver.filledAddresses.count == expected)
    }
    #expect(driver.filledAddresses.first?.origin == "https://shop.example")
}

@Test @MainActor func incognitoNeitherKeepsNorOffersCards() throws {
    let (model, _, _) = passwordModel(mode: .incognito)
    let store = InMemoryCardStore()
    store.items = try [#require(BrowserSavedCard(fields: ["cc-number": "4242424242424242"]))]
    model.cardStore = store
    model.handleCardFormFound(tabID: "t", frameID: "f", urlString: "https://example.com/")
    #expect(model.passwordPrompt == nil)
    model.handleAddressSubmitted(
        tabID: "t",
        urlString: "https://example.com/",
        json: #"{"cc-number":"5555555555554444"}"#,
    )
    #expect(model.passwordPrompt == nil)
}

@Test @MainActor func aPromptFromAPeekLastsAsLongAsThePeek() {
    let (model, driver, _) = passwordModel()
    driver.openPeekSessions = [7]
    model.handlePasswordSubmitted(tabID: "peek-7", urlString: "https://example.com/", username: "me", password: "p")
    #expect(model.passwordPrompt?.peekSessionID == 7)
    model.dropStalePasswordPrompt()
    #expect(model.passwordPrompt != nil, "No tab has this id, and that's not the end of it")
    driver.openPeekSessions = []
    model.dropStalePasswordPrompt()
    #expect(model.passwordPrompt == nil)
    #expect(BrowserPasswordPrompt.saveAddress(tabID: "t", address: .init(fields: [:])).peekSessionID == nil)
}
