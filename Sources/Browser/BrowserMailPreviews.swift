// BrowserMailPreviews.swift

import Foundation

// MARK: - BrowserUnreadMail

/// One unread message from Gmail's Atom feed.
struct BrowserUnreadMail: Equatable {
    let title: String
    let sender: String
    let url: String
}

// MARK: - BrowserMailPreview

/// What a Gmail tab has to say. It stays in memory: nothing about mail is saved or sent anywhere.
enum BrowserMailPreview: Equatable {
    case loading
    case signedOut
    case unread(count: Int, messages: [BrowserUnreadMail])
}

// MARK: - BrowserMailFeed

enum BrowserMailFeed {
    static let host = "mail.google.com"
    static let maximumMessages = 8

    /// The feed of the account the tab shows.
    static func feedURLString(forTabURLString urlString: String) -> String? {
        guard let components = URLComponents(string: urlString), components.host?.lowercased() == host else {
            return nil
        }
        let parts = components.path.split(separator: "/")
        let account = parts.firstIndex(of: "u").flatMap { index in
            parts.indices.contains(index + 1) ? Int(parts[index + 1]) : nil
        } ?? 0
        return "https://\(host)/mail/u/\(account)/feed/atom"
    }

    /// nil text is a refused request: Gmail answers 401 without a session.
    static func preview(forFeedText text: String?) -> BrowserMailPreview {
        guard let data = text?.data(using: .utf8) else { return .signedOut }
        let reader = BrowserMailFeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), let count = reader.count else { return .signedOut }
        // The feed decides what's shown, not where a click goes: only Gmail's own pages open.
        let messages = reader.messages.filter { message in
            guard let url = URLComponents(string: message.url) else { return false }
            return url.scheme == "https" && url.host?.lowercased() == host
        }
        return .unread(count: max(count, 0), messages: Array(messages.prefix(maximumMessages)))
    }
}

// MARK: - BrowserMailFeedReader

private final class BrowserMailFeedReader: NSObject, XMLParserDelegate {
    private(set) var count: Int?
    private(set) var messages = [BrowserUnreadMail]()

    private var isInEntry = false
    private var isInAuthor = false
    private var text = ""
    private var title = ""
    private var sender = ""
    private var url = ""

    func parser(
        _: XMLParser,
        didStartElement name: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes: [String: String] = [:],
    ) {
        text = ""
        switch name {
        case "entry":
            isInEntry = true
            title = ""
            sender = ""
            url = ""
        case "author":
            isInAuthor = true
        case "link" where isInEntry:
            url = attributes["href"] ?? ""
        default:
            break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_: XMLParser, didEndElement name: String, namespaceURI _: String?, qualifiedName _: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "fullcount":
            count = Int(value) ?? 0
        case "title" where isInEntry:
            title = value
        case "name" where isInAuthor:
            sender = value
        case "author":
            isInAuthor = false
        case "entry":
            isInEntry = false
            messages.append(BrowserUnreadMail(title: title, sender: sender, url: url))
        default:
            break
        }
    }
}

// MARK: - BrowserMailFeedBrowsing

protocol BrowserMailFeedBrowsing: BrowserLiveFolderBrowsing {
    /// With the page's profile and cookies. Never shows a password window; nil when refused.
    func fetchText(
        urlString: String,
        firstPartyURLString: String,
        inPageWithID id: String,
        completion: @escaping @MainActor (String?) -> Void,
    )
}

// MARK: - BrowserMailPreviewFetcher

/// Reads a tab's feed through a blank hidden page of the same profile, one at a time.
@MainActor final class BrowserMailPreviewFetcher {
    // MARK: Private

    private let browser: BrowserMailFeedBrowsing
    private let pollInterval: TimeInterval
    private var isFetching = false
    private var waiting = [(String, @MainActor (BrowserMailPreview) -> Void)]()

    // MARK: Internal

    init(browser: BrowserMailFeedBrowsing, pollInterval: TimeInterval = 0.2) {
        self.browser = browser
        self.pollInterval = pollInterval
    }

    func fetch(feedURLString: String, completion: @escaping @MainActor (BrowserMailPreview) -> Void) {
        guard !isFetching else {
            waiting.append((feedURLString, completion))
            return
        }
        isFetching = true
        let page = browser.openPage(urlString: "about:blank")
        waitForPage(id: page, attemptsLeft: 25, feedURLString: feedURLString, completion: completion)
    }

    private func waitForPage(
        id: String,
        attemptsLeft: Int,
        feedURLString: String,
        completion: @escaping @MainActor (BrowserMailPreview) -> Void,
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            guard let self else { return }
            browser.evaluate("'READY'", inPageWithID: id) { [weak self] value in
                guard let self else { return }
                if value == "READY" {
                    browser.fetchText(
                        urlString: feedURLString,
                        firstPartyURLString: "https://\(BrowserMailFeed.host)/",
                        inPageWithID: id,
                    ) { [weak self] text in
                        self?.finish(id: id, BrowserMailFeed.preview(forFeedText: text), completion)
                    }
                } else if attemptsLeft > 0 {
                    waitForPage(
                        id: id,
                        attemptsLeft: attemptsLeft - 1,
                        feedURLString: feedURLString,
                        completion: completion,
                    )
                } else {
                    finish(id: id, .signedOut, completion)
                }
            }
        }
    }

    private func finish(
        id: String,
        _ preview: BrowserMailPreview,
        _ completion: @MainActor (BrowserMailPreview) -> Void,
    ) {
        browser.closePage(id: id)
        isFetching = false
        completion(preview)
        if !waiting.isEmpty {
            let (feed, next) = waiting.removeFirst()
            fetch(feedURLString: feed, completion: next)
        }
    }
}

// MARK: - BrowserChromeModel + mail previews

extension BrowserChromeModel {
    private static let mailRefreshInterval: TimeInterval = 60

    private func mailFeedURLString(forTab tab: Tab) -> String? {
        guard userPreferencesStore.mailPreviewsEnabled, tab.placement != .temporary else { return nil }
        return BrowserMailFeed.feedURLString(forTabURLString: tab.pinnedURLString ?? tab.urlString)
    }

    func isMailPreviewTab(_ tab: Tab) -> Bool {
        mailFeedURLString(forTab: tab) != nil
    }

    func unreadMailCount(forTabID tabID: String) -> Int {
        guard userPreferencesStore.mailPreviewsEnabled, case .unread(let count, _)? = mailPreviews[tabID] else {
            return 0
        }
        return count
    }

    /// Pinned Gmail tabs and Favorites, each no more than once a minute.
    func refreshMailPreviews(now: Date = Date()) {
        for tab in tabs where isMailPreviewTab(tab) {
            refreshMailPreview(forTabID: tab.id, now: now)
        }
    }

    func refreshMailPreview(forTabID tabID: String, now: Date = Date()) {
        guard let tab = tabs.first(where: { $0.id == tabID }), let fetcher = mailPreviewFetcher,
              let feed = mailFeedURLString(forTab: tab),
              now.timeIntervalSince(mailPreviewDates[tabID] ?? .distantPast) >= Self.mailRefreshInterval
        else { return }
        mailPreviewDates[tabID] = now
        if mailPreviews[tabID] == nil {
            mailPreviews[tabID] = .loading
        }
        fetcher.fetch(feedURLString: feed) { [weak self] preview in
            self?.applyMailPreview(preview, forTabID: tabID)
        }
    }

    func applyMailPreview(_ preview: BrowserMailPreview, forTabID tabID: String) {
        mailPreviews[tabID] = preview
        onMailPreviewChanged?()
    }

    func mailPreviewItems(tab: Tab) -> [BrowserFolderPreviewItem] {
        let home = tab.pinnedURLString ?? tab.urlString
        func item(_ title: String, url: String) -> BrowserFolderPreviewItem {
            BrowserFolderPreviewItem(
                id: Self.recentPagesPreviewPrefix + tab.id + "|" + url,
                title: title,
                urlString: url,
                faviconURL: tab.faviconURL,
            )
        }
        switch mailPreviews[tab.id] ?? .loading {
        case .loading:
            return [item(BrowserStrings.mailPreviewLoading, url: home)]
        case .signedOut:
            return [item(BrowserStrings.mailPreviewSignIn, url: home)]
        case .unread(_, let messages) where messages.isEmpty:
            return [item(BrowserStrings.mailPreviewEmpty, url: home)]
        case .unread(_, let messages):
            return messages.map { message in
                item(message.sender.isEmpty ? message.title : "\(message.title) · \(message.sender)", url: message.url)
            }
        }
    }
}
