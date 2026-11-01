// BrowserLiveFolders.swift

import AppKit
import Foundation

// MARK: - BrowserLivePage

/// A page a live folder lists.
struct BrowserLivePage: Decodable, Equatable {
    let url: String
    let title: String
}

// MARK: - BrowserLiveFolderBrowsing

/// A hidden browser of the profile.
@MainActor protocol BrowserLiveFolderBrowsing {
    func openPage(urlString: String) -> String
    func closePage(id: String)
    func evaluate(_ code: String, inPageWithID id: String, completion: @escaping @MainActor (String?) -> Void)
}

// MARK: - BrowserGitHubLiveFolderFetcher

/// Reads the signed-in user's open pull requests from GitHub's page, in a hidden
/// browser of the profile, since no token is involved.
@MainActor final class BrowserGitHubLiveFolderFetcher {
    // MARK: Internal

    enum Outcome: Equatable {
        case pages([BrowserLivePage])
        case signedOut
        case failed
    }

    static let pullsURL = "https://github.com/pulls"
    static let loginURL = "https://github.com/login"

    /// Answers `SIGNED_OUT`, the list as JSON once the page has it, or nothing yet.
    static let expression = #"""
    (() => {
      if (location.pathname.startsWith('/login') || location.pathname.startsWith('/session')) return 'SIGNED_OUT';
      if (document.readyState !== 'complete') return '';
      const seen = new Set(), pages = [];
      for (const a of document.querySelectorAll('a[href*="/pull/"]')) {
        const url = new URL(a.href, location.href);
        if (!/^\/[^/]+\/[^/]+\/pull\/\d+$/.test(url.pathname) || seen.has(url.pathname)) continue;
        const title = a.textContent.trim();
        if (!title || /^#?\d+$/.test(title)) continue;
        seen.add(url.pathname);
        pages.push({url: url.origin + url.pathname, title});
      }
      return JSON.stringify(pages);
    })()
    """#

    // MARK: Private

    private let browser: BrowserLiveFolderBrowsing
    private var isFetching = false

    // MARK: Internal

    init(browser: BrowserLiveFolderBrowsing) {
        self.browser = browser
    }

    /// `value` is what `expression` answered: nil to try again.
    nonisolated static func outcome(for value: String?) -> Outcome? {
        guard let value, !value.isEmpty else { return nil }
        if value == "SIGNED_OUT" {
            return .signedOut
        }
        guard let data = value.data(using: .utf8),
              let pages = try? JSONDecoder().decode([BrowserLivePage].self, from: data)
        else { return .failed }
        return .pages(pages)
    }

    func fetch(completion: @escaping @MainActor (Outcome) -> Void) {
        guard !isFetching else { return }
        isFetching = true
        let tabID = browser.openPage(urlString: Self.pullsURL)
        poll(tabID: tabID, attemptsLeft: 25, completion: completion)
    }

    // MARK: Private

    private func poll(tabID: String, attemptsLeft: Int, completion: @escaping @MainActor (Outcome) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            browser.evaluate(Self.expression, inPageWithID: tabID) { [weak self] value in
                guard let self else { return }
                if let outcome = Self.outcome(for: value) {
                    finish(tabID: tabID, outcome, completion)
                } else if attemptsLeft > 0 {
                    poll(tabID: tabID, attemptsLeft: attemptsLeft - 1, completion: completion)
                } else {
                    finish(tabID: tabID, .failed, completion)
                }
            }
        }
    }

    private func finish(tabID: String, _ outcome: Outcome, _ completion: @MainActor (Outcome) -> Void) {
        browser.closePage(id: tabID)
        isFetching = false
        completion(outcome)
    }
}

// MARK: - BrowserChromeModel + live folders

extension BrowserChromeModel {
    /// Live Folders > GitHub: an empty folder that the fetcher keeps filled.
    @discardableResult func createGitHubLiveFolder(inSpaceID spaceID: String) -> String? {
        guard let folderID = createEmptyPinnedFolder(title: BrowserStrings.liveFolderGitHubTitle, inSpaceID: spaceID)
        else {
            return nil
        }
        userPreferencesStore.gitHubLiveFolderIDs.insert(folderID)
        refreshGitHubLiveFolders(openingLoginIfSignedOut: true)
        return folderID
    }

    /// `openingLoginIfSignedOut` asks to sign in the first time; later rounds stay quiet.
    func refreshGitHubLiveFolders(openingLoginIfSignedOut: Bool = false) {
        let ids = userPreferencesStore.gitHubLiveFolderIDs.filter { id in pinnedTabFolders.contains { $0.id == id } }
        guard !ids.isEmpty, let liveFolderFetcher else { return }
        liveFolderFetcher.fetch { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .pages(let pages):
                for id in ids {
                    syncLiveFolder(id: id, pages: pages)
                }
            case .signedOut:
                if openingLoginIfSignedOut, let url = URL(string: BrowserGitHubLiveFolderFetcher.loginURL) {
                    openURLInNewTab(url)
                }
            case .failed:
                break
            }
        }
    }
}
