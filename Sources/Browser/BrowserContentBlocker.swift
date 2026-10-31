// BrowserContentBlocker.swift

import Combine
import Foundation

// MARK: - BrowserFilterList

/// What a filter list asks for, reduced to what the blocker can do quickly: hosts
/// to refuse, and elements to hide. Rules for a path or a single file are skipped.
struct BrowserFilterList: Equatable {
    var blockedHosts = Set<String>()
    var thirdPartyHosts = Set<String>()
    var exceptionHosts = Set<String>()
    var genericSelectors = [String]()
    var selectorsByHost = [String: [String]]()

    init() {}

    /// Reads Adblock Plus syntax.
    init(parsing text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            add(line.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func isHost(_ value: String) -> Bool {
        value.contains(".") && value.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 46
        }
    }

    /// Procedural selectors need a script engine, and a browser would drop a whole
    /// stylesheet rule over them.
    private static func isSupported(selector: String) -> Bool {
        !selector.hasPrefix("+js(") && !selector.contains(":-abp") && !selector.contains(":has-text")
            && !selector.contains(":xpath") && !selector.contains(":style(") && !selector.contains(":remove(")
            && !selector.contains(":matches-") && !selector.contains(":upward(") && !selector.contains("{")
    }

    private mutating func add(_ line: String) {
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return }
        if let range = line.range(of: "##") {
            addCosmetic(domains: String(line[..<range.lowerBound]), selector: String(line[range.upperBound...]))
            return
        }
        // Exceptions to hiding, scripted and extended rules.
        guard !line.contains("#@#"), !line.contains("#?#"), !line.contains("#$#") else { return }
        let isException = line.hasPrefix("@@")
        let rule = isException ? String(line.dropFirst(2)) : line
        guard rule.hasPrefix("||") else { return }
        let body = rule.dropFirst(2)
        let parts = body.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        var pattern = String(parts.first ?? "")
        if pattern.hasSuffix("^") { pattern.removeLast() }
        guard Self.isHost(pattern) else { return }
        let options = parts.count > 1
            ? parts[1].split(separator: ",").map { $0.lowercased() }
            : []
        if isException {
            if options.isEmpty { exceptionHosts.insert(pattern) }
            return
        }
        if options.isEmpty {
            blockedHosts.insert(pattern)
        } else if options == ["third-party"] || options == ["3p"] {
            thirdPartyHosts.insert(pattern)
        }
    }

    private mutating func addCosmetic(domains: String, selector: String) {
        guard !selector.isEmpty, Self.isSupported(selector: selector) else { return }
        if domains.isEmpty {
            genericSelectors.append(selector)
            return
        }
        for domain in domains.split(separator: ",") where !domain.hasPrefix("~") {
            selectorsByHost[domain.lowercased(), default: []].append(selector)
        }
    }
}

// MARK: - BrowserContentBlockerSettings

struct BrowserContentBlockerSettings: Equatable {
    var blocksAds = false
    var blocksTrackers = false
    var blocksCookieBanners = false
    var excludedHosts = [String]()

    var isEnabled: Bool { blocksAds || blocksTrackers || blocksCookieBanners }
}

// MARK: - BrowserContentBlocker

/// Downloads public filter lists when a kind of blocking is on, keeps them for a
/// week and hands the result to the engine that refuses requests.
@MainActor final class BrowserContentBlocker: ObservableObject {
    // MARK: Internal

    enum List: String, CaseIterable {
        case ads
        case trackers
        case cookieBanners

        // MARK: Internal

        var url: URL {
            switch self {
            case .ads: URL(string: "https://easylist.to/easylist/easylist.txt")!
            case .trackers: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!
            case .cookieBanners: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!
            }
        }
    }

    typealias Loader = @Sendable (URL) async throws -> Data

    // MARK: Private

    private static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("OpenArc/FilterLists", isDirectory: true)
    }

    /// False after a download failed and no earlier copy exists.
    @Published private(set) var lastUpdateFailed = false
    private(set) var settings = BrowserContentBlockerSettings()

    private let directory: URL
    private let loader: Loader
    private let apply: @MainActor (BrowserContentBlockerRules) -> Void
    private let now: () -> Date
    private var rebuildTask: Task<Void, Never>?

    init(
        directory: URL = BrowserContentBlocker.defaultDirectory,
        loader: @escaping Loader = { url in try await URLSession.shared.data(from: url).0 },
        apply: @escaping @MainActor (BrowserContentBlockerRules) -> Void,
        now: @escaping () -> Date = Date.init,
    ) {
        self.directory = directory
        self.loader = loader
        self.apply = apply
        self.now = now
    }

    /// Applies new settings, fetching any list that is needed and missing or old.
    func update(settings: BrowserContentBlockerSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        rebuildTask?.cancel()
        let lists = enabledLists(settings)
        rebuildTask = Task { [weak self] in
            await self?.rebuild(lists: lists, settings: settings)
        }
    }

    func waitForPendingWork() async {
        await rebuildTask?.value
    }

    private func enabledLists(_ settings: BrowserContentBlockerSettings) -> [List] {
        var lists = [List]()
        if settings.blocksAds { lists.append(.ads) }
        if settings.blocksTrackers { lists.append(.trackers) }
        if settings.blocksCookieBanners { lists.append(.cookieBanners) }
        return lists
    }

    private func rebuild(lists: [List], settings: BrowserContentBlockerSettings) async {
        var failed = false
        var texts = [(List, String)]()
        for list in lists {
            if let text = await text(of: list) {
                texts.append((list, text))
            } else {
                failed = true
            }
        }
        guard !Task.isCancelled else { return }
        let excluded = settings.excludedHosts
        let rules = await Task.detached(priority: .utility) {
            BrowserContentBlockerRules(
                lists: texts.map { (BrowserFilterList(parsing: $0.1), $0.0 == .cookieBanners) },
                excludedSites: excluded,
            )
        }.value
        guard !Task.isCancelled else { return }
        apply(rules)
        lastUpdateFailed = failed
    }

    /// The saved copy while it is fresh; otherwise a new download, or the old copy
    /// if the download fails.
    private func text(of list: List) async -> String? {
        let file = directory.appendingPathComponent("\(list.rawValue).txt")
        let saved = try? String(contentsOf: file, encoding: .utf8)
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if saved != nil, let modified, now().timeIntervalSince(modified) < Self.maximumAge {
            return saved
        }
        guard let data = try? await loader(list.url), let text = String(data: data, encoding: .utf8) else {
            return saved
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        return text
    }
}

// MARK: - BrowserContentBlockerRules

/// The enabled lists combined. Hiding rules for all sites come only from lists
/// meant for them, because thousands of selectors on each page cost too much.
struct BrowserContentBlockerRules: Equatable {
    var blockedHosts = Set<String>()
    var thirdPartyHosts = Set<String>()
    var exceptionHosts = Set<String>()
    var excludedSites = [String]()
    var genericSelectors = [String]()
    var selectorsByHost = [String: [String]]()

    init(lists: [(list: BrowserFilterList, usesGenericSelectors: Bool)], excludedSites: [String]) {
        self.excludedSites = excludedSites
        for (list, usesGenericSelectors) in lists {
            blockedHosts.formUnion(list.blockedHosts)
            thirdPartyHosts.formUnion(list.thirdPartyHosts)
            exceptionHosts.formUnion(list.exceptionHosts)
            if usesGenericSelectors { genericSelectors += list.genericSelectors }
            selectorsByHost.merge(list.selectorsByHost) { $0 + $1 }
        }
    }
}
