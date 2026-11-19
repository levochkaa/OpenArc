// BrowserFilterListUpdater.swift

import Combine
import CryptoKit
import Foundation
import os
import WebKit

// MARK: - BrowserFilterListMetadata

/// What the last download of a list left: its validators and times.
struct BrowserFilterListMetadata: Codable, Equatable {
    var entityTag: String?
    var lastModified: String?
    var checkedAt: Date?
    var downloadedAt: Date?

    /// A list is due once the authors' update period has passed since the last check.
    func isDue(now: Date, interval: TimeInterval) -> Bool {
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= interval || checkedAt > now
    }
}

// MARK: - BrowserFilterListUpdater

/// Loads the filter lists the settings turn on and keeps them current: the
/// copy in the app until the first download, then a fresh one every four
/// days, the period the lists ask for, without an app update.
@MainActor final class BrowserFilterListUpdater {
    // MARK: Internal

    static let shared = BrowserFilterListUpdater()

    static let updateInterval: TimeInterval = 4 * 24 * 60 * 60

    // MARK: Private

    private static let logger = Logger(subsystem: "com.levochkaa.OpenArc", category: "content-blocking")

    let changes = PassthroughSubject<Void, Never>()

    private(set) var isUpdating = false

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OpenArc/Filter Lists", isDirectory: true)
    }()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private var timer: Timer?
    private var loading = Set<BrowserFilterListKind>()
    private var loaded = Set<BrowserFilterListKind>()

    /// The latest download of a list in use; nil while the app's own copies are in use.
    var lastDownloaded: Date? {
        BrowserContentBlocker.shared.settings.enabledKinds.compactMap { metadata(for: $0).downloadedAt }.max()
    }

    /// The list text an engine starts from: the last download, else the app's copy.
    nonisolated static func listText(for kind: BrowserFilterListKind, directory: URL) -> String? {
        if let text = try? String(contentsOf: cachedListURL(for: kind, directory: directory), encoding: .utf8),
           looksLikeFilterList(text)
        {
            return text
        }
        guard let url = Bundle.main.url(forResource: kind.bundledResourceName, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Adblock Plus lists open with their syntax header; an error page does not.
    nonisolated static func looksLikeFilterList(_ text: String) -> Bool {
        text.hasPrefix("[Adblock Plus") && text.utf8.count > 10000
    }

    nonisolated static func cachedListURL(for kind: BrowserFilterListKind, directory: URL) -> URL {
        directory.appendingPathComponent("\(kind.rawValue).txt", isDirectory: false)
    }

    /// Follows the settings: loads the lists they turn on and checks for updates now and then.
    func start(settings: BrowserContentBlockingSettings) {
        apply(settings)
        guard timer == nil else { return }
        // The first check waits until the launch has settled.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in await BrowserFilterListUpdater.shared.checkForUpdates(force: false) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            await checkForUpdates(force: false)
        }
    }

    func apply(_ settings: BrowserContentBlockingSettings) {
        BrowserContentBlocker.shared.update(settings: settings)
        for kind in settings.enabledKinds where !loaded.contains(kind) {
            load(kind)
        }
        BrowserWebKitContentRules.shared.changes.send()
        changes.send()
    }

    /// Downloads the lists in use whose period has passed, or all of them when forced.
    func checkForUpdates(force: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        changes.send()
        defer {
            isUpdating = false
            changes.send()
        }
        let now = Date()
        for kind in BrowserContentBlocker.shared.settings.enabledKinds {
            var metadata = metadata(for: kind)
            guard force || metadata.isDue(now: now, interval: Self.updateInterval) else { continue }
            let hasDownload = FileManager.default.fileExists(atPath: Self.cachedListURL(for: kind, directory: directory)
                .path)
            var request = URLRequest(
                url: kind.downloadURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 60,
            )
            if hasDownload {
                request.setValue(metadata.entityTag, forHTTPHeaderField: "If-None-Match")
                request.setValue(metadata.lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
            guard let result = try? await session.data(for: request),
                  let http = result.1 as? HTTPURLResponse
            else {
                Self.logger.error("filter list \(kind.rawValue, privacy: .public) download failed")
                continue
            }
            metadata.checkedAt = now
            if http.statusCode == 200 {
                let data = result.0
                let text = String(decoding: data, as: UTF8.self)
                guard Self.looksLikeFilterList(text) else {
                    Self.logger.error("filter list \(kind.rawValue, privacy: .public) download is not a list")
                    continue
                }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: Self.cachedListURL(for: kind, directory: directory), options: .atomic)
                } catch {
                    Self.logger.error("filter list \(kind.rawValue, privacy: .public) not saved: \(error)")
                    continue
                }
                metadata.entityTag = http.value(forHTTPHeaderField: "ETag")
                metadata.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
                metadata.downloadedAt = now
                save(metadata, for: kind)
                load(kind)
            } else if http.statusCode == 304 {
                save(metadata, for: kind)
            } else {
                Self.logger.error(
                    "filter list \(kind.rawValue, privacy: .public) download answered \(http.statusCode)",
                )
            }
        }
    }

    private func metadataURL(for kind: BrowserFilterListKind) -> URL {
        directory.appendingPathComponent("\(kind.rawValue).json", isDirectory: false)
    }

    private func metadata(for kind: BrowserFilterListKind) -> BrowserFilterListMetadata {
        guard let data = try? Data(contentsOf: metadataURL(for: kind)) else { return .init() }
        return (try? JSONDecoder().decode(BrowserFilterListMetadata.self, from: data)) ?? .init()
    }

    private func save(_ metadata: BrowserFilterListMetadata, for kind: BrowserFilterListKind) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(metadata).write(to: metadataURL(for: kind), options: .atomic)
    }

    /// Reads and indexes a list away from the main thread, then hands it to
    /// both engines; iOS has only WebKit, which needs no index of its own.
    private func load(_ kind: BrowserFilterListKind) {
        guard loading.insert(kind).inserted else { return }
        loaded.insert(kind)
        let directory = directory
        Task.detached(priority: .utility) {
            let text = Self.listText(for: kind, directory: directory)
            let list = text.map(BrowserFilterListParser.parse)
            #if os(macOS)
                if let list {
                    BrowserContentBlocker.shared.install(BrowserFilterEngine(list), for: kind)
                }
            #endif
            let digest = text
                .map { SHA256.hash(data: Data($0.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }
            await MainActor.run {
                BrowserFilterListUpdater.shared.loading.remove(kind)
                BrowserFilterListUpdater.shared.changes.send()
                if let list, let digest {
                    BrowserWebKitContentRules.shared.prepare(kind, list: list, digest: digest)
                } else {
                    BrowserFilterListUpdater.shared.loaded.remove(kind)
                    Self.logger.error("filter list \(kind.rawValue, privacy: .public) missing")
                }
            }
        }
    }
}

// MARK: - BrowserWebKitContentRules

/// The filter lists compiled for WebKit pages. WebKit keeps compiled lists
/// on disk, so a list compiles once per version.
@MainActor final class BrowserWebKitContentRules {
    // MARK: Internal

    static let shared = BrowserWebKitContentRules()

    // MARK: Private

    /// Raised when the compiler's output changes, so stored lists compile again.
    private static let compilerVersion = 1
    private static let logger = Logger(subsystem: "com.levochkaa.OpenArc", category: "content-blocking")

    /// Sends when a list or the settings change, so pages pick the lists again.
    let changes = PassthroughSubject<Void, Never>()

    private var lists = [BrowserFilterListKind: WKContentRuleList]()

    /// Puts the lists the settings turn on into a page's controller, none on an allowed site.
    func apply(to controller: WKUserContentController, urlString: String?) {
        let settings = BrowserContentBlocker.shared.settings
        controller.removeAllContentRuleLists()
        for kind in urlString.map(settings.enabledKinds(forURLString:)) ?? settings.enabledKinds {
            if let list = lists[kind] {
                controller.add(list)
            }
        }
    }

    func prepare(_ kind: BrowserFilterListKind, list: BrowserParsedFilterList, digest: String) {
        let identifier = "openarc.\(kind.rawValue).\(Self.compilerVersion).\(digest)"
        Task { @MainActor in
            guard let store = WKContentRuleListStore.default() else { return }
            if let found = try? await store.contentRuleList(forIdentifier: identifier) {
                install(found, for: kind, store: store)
                return
            }
            let json = await Task.detached(priority: .utility) {
                BrowserContentRuleListCompiler.encodedJSON(for: list)
            }.value
            do {
                if let compiled = try await store.compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: json,
                ) {
                    install(compiled, for: kind, store: store)
                }
            } catch {
                Self.logger.error("content rules \(kind.rawValue, privacy: .public) not compiled: \(error)")
            }
        }
    }

    private func install(_ list: WKContentRuleList, for kind: BrowserFilterListKind, store: WKContentRuleListStore) {
        lists[kind] = list
        changes.send()
        Task { @MainActor in
            let prefix = "openarc.\(kind.rawValue)."
            for identifier in await store.availableIdentifiers() ?? []
                where identifier.hasPrefix(prefix) && identifier != list.identifier
            {
                try? await store.removeContentRuleList(forIdentifier: identifier)
            }
        }
    }
}
