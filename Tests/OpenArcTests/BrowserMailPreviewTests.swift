// BrowserMailPreviewTests.swift

import Foundation
import Testing

@Test func eachGmailAccountHasItsFeed() {
    #expect(BrowserMailFeed.feedURLString(forTabURLString: "https://mail.google.com/mail/u/2/#inbox")
        == "https://mail.google.com/mail/u/2/feed/atom")
    #expect(BrowserMailFeed.feedURLString(forTabURLString: "https://mail.google.com/")
        == "https://mail.google.com/mail/u/0/feed/atom")
    #expect(BrowserMailFeed.feedURLString(forTabURLString: "https://gmail.example/mail/u/0/") == nil)
    #expect(BrowserMailFeed.feedURLString(forTabURLString: "https://mail.google.com.evil.example/") == nil)
}

private let feedText = #"""
<?xml version="1.0" encoding="UTF-8"?>
<feed version="0.3" xmlns="http://purl.org/atom/ns#">
<title>Gmail - Inbox</title><fullcount>12</fullcount>
<entry><title>Hello &amp; welcome</title><summary>not shown</summary>
<link rel="alternate" href="https://mail.google.com/mail/u/0/?message_id=1&amp;view=conv" type="text/html"/>
<author><name>Test Person</name><email>t@example.invalid</email></author></entry>
<entry><title>Trap</title><link href="https://evil.example/"/><author><name>X</name></author></entry>
<entry><title>Trap 2</title><link href="javascript:alert(1)"/><author><name>X</name></author></entry>
</feed>
"""#

@Test func theFeedIsRead() {
    #expect(BrowserMailFeed.preview(forFeedText: nil) == .signedOut, "Refused: no session")
    #expect(BrowserMailFeed.preview(forFeedText: "<html>Sign in</html>") == .signedOut)
    #expect(BrowserMailFeed.preview(forFeedText: "not xml") == .signedOut)
    #expect(BrowserMailFeed.preview(forFeedText: feedText) == .unread(count: 12, messages: [
        BrowserUnreadMail(
            title: "Hello & welcome",
            sender: "Test Person",
            url: "https://mail.google.com/mail/u/0/?message_id=1&view=conv",
        ),
    ]), "A click only ever opens Gmail")
}

@Test @MainActor func mailPreviewsAreOffUntilAskedFor() throws {
    let f = SidebarDragFixture(apps: ["gmail"])
    let id = f.id("gmail")
    #expect(f.model.setPinnedURLString("https://mail.google.com/mail/u/0/", forTabID: id))
    let tab = try #require(f.model.tabs.first { $0.id == id })
    #expect(!f.model.userPreferencesStore.mailPreviewsEnabled)
    #expect(!f.model.isMailPreviewTab(tab))
    f.model.applyMailPreview(.unread(count: 3, messages: []), forTabID: id)
    #expect(f.model.unreadMailCount(forTabID: id) == 0, "Nothing shows while it's off")

    f.model.userPreferencesStore.mailPreviewsEnabled = true
    #expect(f.model.isMailPreviewTab(tab))
    #expect(f.model.unreadMailCount(forTabID: id) == 3)
    #expect(f.model.recentPagesPreviewID(forTab: tab) != nil)
}

@Test @MainActor func aGmailTabListsItsMailOrSaysWhy() throws {
    let f = SidebarDragFixture(apps: ["gmail"])
    let id = f.id("gmail")
    f.model.userPreferencesStore.mailPreviewsEnabled = true
    #expect(f.model.setPinnedURLString("https://mail.google.com/mail/u/0/", forTabID: id))
    let tab = try #require(f.model.tabs.first { $0.id == id })
    let previewID = try #require(f.model.recentPagesPreviewID(forTab: tab))
    func titles() -> [String] { f.model.recentPagesPreviewItems(previewID: previewID).map(\.title) }

    #expect(titles() == [BrowserStrings.mailPreviewLoading])
    f.model.applyMailPreview(.signedOut, forTabID: id)
    #expect(titles() == [BrowserStrings.mailPreviewSignIn])
    f.model.applyMailPreview(.unread(count: 0, messages: []), forTabID: id)
    #expect(titles() == [BrowserStrings.mailPreviewEmpty])
    let url = "https://mail.google.com/mail/u/0/?message_id=1"
    f.model.applyMailPreview(
        .unread(count: 1, messages: [BrowserUnreadMail(title: "Hi", sender: "A", url: url)]),
        forTabID: id,
    )
    #expect(titles() == ["Hi · A"])
    let item = try #require(f.model.recentPagesPreviewItems(previewID: previewID).first)
    #expect(f.model.openRecentPagePreviewItem(id: item.id))
    #expect(f.model.selectedTabID == id)
}

@Test @MainActor func aTemporaryGmailTabHasNoPreview() throws {
    let f = SidebarDragFixture(temporary: ["x"])
    f.model.userPreferencesStore.mailPreviewsEnabled = true
    f.driver.emitUpdate(id: f.id("x"), title: "Inbox", urlString: "https://mail.google.com/mail/u/0/")
    let tab = try #require(f.model.tabs.first { $0.id == f.id("x") })
    #expect(!f.model.isMailPreviewTab(tab))
}

// MARK: - FakeMailBrowser

@MainActor private final class FakeMailBrowser: BrowserMailFeedBrowsing {
    var feed: String?
    private(set) var opened = [String]()
    private(set) var closed = [String]()
    private(set) var fetched = [String]()

    func openPage(urlString: String) -> String {
        opened.append(urlString)
        return "page"
    }

    func closePage(id: String) {
        closed.append(id)
    }

    func evaluate(_: String, inPageWithID _: String, completion: @escaping @MainActor (String?) -> Void) {
        completion("READY")
    }

    func fetchText(
        urlString: String,
        firstPartyURLString _: String,
        inPageWithID _: String,
        completion: @escaping @MainActor (String?) -> Void,
    ) {
        fetched.append(urlString)
        completion(feed)
    }
}

@MainActor private func fetch(_ fetcher: BrowserMailPreviewFetcher) async -> BrowserMailPreview {
    await withCheckedContinuation { continuation in
        fetcher.fetch(feedURLString: "feed") { continuation.resume(returning: $0) }
    }
}

@Test @MainActor func aRefusedFeedMeansSignedOutAndNoPageIsLeft() async {
    let browser = FakeMailBrowser()
    let preview = await fetch(BrowserMailPreviewFetcher(browser: browser, pollInterval: 0.001))
    #expect(preview == .signedOut)
    #expect(browser.opened == ["about:blank"], "The feed never opens as a page: it would ask for a password")
    #expect(browser.fetched == ["feed"])
    #expect(browser.closed == ["page"])
}

@Test @MainActor func anAnsweredFeedIsShown() async {
    let browser = FakeMailBrowser()
    browser.feed = feedText
    let preview = await fetch(BrowserMailPreviewFetcher(browser: browser, pollInterval: 0.001))
    guard case .unread(let count, let messages) = preview else {
        Issue.record("Not read")
        return
    }
    #expect(count == 12 && messages.count == 1)
    #expect(browser.closed == ["page"])
}

@Test @MainActor func twoGmailTabsAreReadInTurn() async {
    let browser = FakeMailBrowser()
    browser.feed = feedText
    let fetcher = BrowserMailPreviewFetcher(browser: browser, pollInterval: 0.001)
    let answers: [BrowserMailPreview] = await withCheckedContinuation { continuation in
        var collected = [BrowserMailPreview]()
        for feed in ["one", "two"] {
            fetcher.fetch(feedURLString: feed) { preview in
                collected.append(preview)
                if collected.count == 2 {
                    continuation.resume(returning: collected)
                }
            }
        }
    }
    #expect(answers.count == 2)
    #expect(browser.fetched == ["one", "two"])
    #expect(browser.closed.count == 2)
}
