// BrowserFilterEngine.swift

import Foundation

// MARK: - BrowserFilterRequest

/// A request as the filters see it: its URL, the site of the document that
/// asked for it, and its kind.
struct BrowserFilterRequest {
    // MARK: Internal

    let url: [UInt8]
    let lowercasedURL: [UInt8]
    let hostRange: Range<Int>
    let host: String
    let sourceHost: String
    let type: BrowserFilterResourceTypes
    let isThirdParty: Bool

    /// Nil for URLs that are not web requests, such as `data:` or the browser's own pages.
    init?(
        urlString: String,
        sourceURLString: String?,
        type: BrowserFilterResourceTypes,
        registrableDomain: (String) -> String = BrowserFilterDomains.registrableDomain,
    ) {
        let url = Array(urlString.utf8)
        guard let hostRange = Self.hostRange(in: url) else { return nil }
        let lowercased = url.map(Self.lowercased)
        let host = String(decoding: lowercased[hostRange], as: UTF8.self)
        self.url = url
        self.lowercasedURL = lowercased
        self.hostRange = hostRange
        self.host = host
        self.type = type
        let sourceHost = sourceURLString.flatMap(Self.host(ofURLString:)) ?? ""
        self.sourceHost = sourceHost
        self.isThirdParty = !sourceHost.isEmpty && registrableDomain(sourceHost) != registrableDomain(host)
    }

    /// The lowercased host of an http, https, ws or wss URL.
    static func host(ofURLString urlString: String) -> String? {
        let url = Array(urlString.utf8)
        guard let range = hostRange(in: url) else { return nil }
        return String(decoding: url[range].map(lowercased), as: UTF8.self)
    }

    // MARK: Private

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    private static func hostRange(in url: [UInt8]) -> Range<Int>? {
        let schemes: [[UInt8]] = [
            Array("http://".utf8),
            Array("https://".utf8),
            Array("ws://".utf8),
            Array("wss://".utf8),
        ]
        guard let scheme = schemes.first(where: { scheme in
            url.count > scheme.count && zip(scheme, url).allSatisfy { $0 == lowercased($1) }
        }) else { return nil }
        var start = scheme.count
        var end = start
        while end < url.count, ![0x2F, 0x3F, 0x23].contains(url[end]) {
            end += 1
        }
        // Credentials before the host: `user:password@host`.
        if let at = url[start..<end].lastIndex(of: 0x40) {
            start = at + 1
        }
        var hostEnd = start
        while hostEnd < end, url[hostEnd] != 0x3A {
            hostEnd += 1
        }
        return hostEnd > start ? start..<hostEnd : nil
    }
}

// MARK: - BrowserFilterDomains

enum BrowserFilterDomains {
    /// The site a host belongs to, such as `example.co.uk` for `ads.example.co.uk`.
    static func registrableDomain(_ host: String) -> String {
        coreRegistrableDomain(host: host)
    }

    /// `ads.example.com` is `example.com` or one of its subdomains.
    static func host(_ host: String, isOrIsSubdomainOf domain: String) -> Bool {
        guard host.hasSuffix(domain) else { return false }
        let hostBytes = host.utf8
        let extra = hostBytes.count - domain.utf8.count
        return extra == 0 ||
            (extra > 0 && hostBytes[hostBytes.index(hostBytes.startIndex, offsetBy: extra - 1)] == 0x2E)
    }

    /// The host and every parent domain, longest first.
    static func hostAndParents(_ host: String) -> [String] {
        var result = [host]
        var rest = Substring(host)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if !rest.isEmpty {
                result.append(String(rest))
            }
        }
        return result
    }

    static func matches(host: String, included: [String], excluded: [String]) -> Bool {
        if !included.isEmpty, !included.contains(where: { Self.host(host, isOrIsSubdomainOf: $0) }) {
            return false
        }
        return !excluded.contains { Self.host(host, isOrIsSubdomainOf: $0) }
    }
}

// MARK: - BrowserCompiledNetworkFilter

/// A network filter ready to match: its pattern bytes carry a leading `*`
/// unless anchored and a trailing `*` unless the URL must end there.
struct BrowserCompiledNetworkFilter {
    // MARK: Private

    private static let star = UInt8(ascii: "*")
    private static let separator = UInt8(ascii: "^")

    // MARK: Internal

    let pattern: [UInt8]
    let anchor: BrowserNetworkFilter.Anchor
    let matchCase: Bool
    let thirdParty: Bool?
    let types: BrowserFilterResourceTypes
    let includedDomains: [String]
    let excludedDomains: [String]

    init(_ filter: BrowserNetworkFilter) {
        var pattern = Array(filter.pattern.utf8)
        if filter.anchor == .none, pattern.first != Self.star {
            pattern.insert(Self.star, at: 0)
        }
        if !filter.endAnchor, pattern.last != Self.star {
            pattern.append(Self.star)
        }
        self.pattern = pattern
        self.anchor = filter.anchor
        self.matchCase = filter.matchCase
        self.thirdParty = filter.thirdParty
        self.types = filter.types
        self.includedDomains = filter.includedDomains
        self.excludedDomains = filter.excludedDomains
    }

    /// `^` matches anything but a letter, a digit, `_`, `-`, `.` and `%`, or the URL's end.
    static func isSeparator(_ byte: UInt8) -> Bool {
        !((byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x5F || byte == 0x2D || byte == 0x2E || byte == 0x25)
    }

    /// Wildcard match of the whole text from `start`: `*` takes any run, `^` one separator.
    static func globMatch(_ pattern: [UInt8], _ text: [UInt8], from start: Int) -> Bool {
        let patternCount = pattern.count
        let textCount = text.count
        var textIndex = start
        var patternIndex = 0
        var starIndex = -1
        var mark = 0
        while textIndex < textCount {
            if patternIndex < patternCount {
                let byte = pattern[patternIndex]
                if byte == Self.star {
                    if patternIndex == patternCount - 1 { return true }
                    starIndex = patternIndex
                    mark = textIndex
                    patternIndex += 1
                    continue
                }
                if byte == text[textIndex] || (byte == Self.separator && isSeparator(text[textIndex])) {
                    textIndex += 1
                    patternIndex += 1
                    continue
                }
            }
            guard starIndex >= 0 else { return false }
            patternIndex = starIndex + 1
            mark += 1
            textIndex = mark
        }
        while patternIndex < patternCount,
              pattern[patternIndex] == Self.star || pattern[patternIndex] == Self.separator
        {
            patternIndex += 1
        }
        return patternIndex == patternCount
    }

    func matches(_ request: BrowserFilterRequest) -> Bool {
        guard types.contains(request.type) else { return false }
        if let thirdParty, thirdParty != request.isThirdParty { return false }
        if !includedDomains.isEmpty || !excludedDomains.isEmpty {
            guard BrowserFilterDomains.matches(
                host: request.sourceHost,
                included: includedDomains,
                excluded: excludedDomains,
            ) else { return false }
        }
        return matchesURL(request)
    }

    func matchesURL(_ request: BrowserFilterRequest) -> Bool {
        let text = matchCase ? request.url : request.lowercasedURL
        switch anchor {
        case .none,
             .start:
            return Self.globMatch(pattern, text, from: 0)
        case .host:
            let range = request.hostRange
            if Self.globMatch(pattern, text, from: range.lowerBound) {
                return true
            }
            for index in range where text[index] == 0x2E && index + 1 < range.upperBound {
                if Self.globMatch(pattern, text, from: index + 1) {
                    return true
                }
            }
            return false
        }
    }
}

// MARK: - BrowserNetworkFilterSet

/// Network filters indexed so a request checks only the few that could match:
/// by the host a `||host^` filter names, or by the rarest whole word of the
/// pattern, which every URL it matches must also hold.
struct BrowserNetworkFilterSet {
    // MARK: Internal

    let filters: [BrowserCompiledNetworkFilter]

    // MARK: Private

    private let byHost: [UInt64: [Int32]]
    private let byToken: [UInt64: [Int32]]
    private let fallback: [Int32]

    var isEmpty: Bool { filters.isEmpty }

    init(_ filters: [BrowserNetworkFilter]) {
        self.filters = filters.map(BrowserCompiledNetworkFilter.init)
        var byHost = [UInt64: [Int32]]()
        var candidates = [[UInt64]](repeating: [], count: filters.count)
        var frequency = [UInt64: Int]()
        for (index, filter) in filters.enumerated() {
            if let host = filter.hostOnlyPattern {
                byHost[Self.hash(Array(host.utf8)[...]), default: []].append(Int32(index))
                continue
            }
            let tokens = Self.patternTokens(filter)
            candidates[index] = tokens
            for token in tokens {
                frequency[token, default: 0] += 1
            }
        }
        var byToken = [UInt64: [Int32]]()
        var fallback = [Int32]()
        for (index, filter) in filters.enumerated() where filter.hostOnlyPattern == nil {
            if let token = candidates[index].min(by: { frequency[$0, default: 0] < frequency[$1, default: 0] }) {
                byToken[token, default: []].append(Int32(index))
            } else {
                fallback.append(Int32(index))
            }
        }
        self.byHost = byHost
        self.byToken = byToken
        self.fallback = fallback
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x25
    }

    /// FNV-1a of a word.
    private static func hash(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Whole words of the pattern: a word that touches `*`, or the pattern's
    /// unanchored edge, may be part of a longer word in the URL.
    private static func patternTokens(_ filter: BrowserNetworkFilter) -> [UInt64] {
        let pattern = Array(filter.pattern.lowercased().utf8)
        var tokens = [UInt64]()
        var start = -1
        for index in 0...pattern.count {
            if index < pattern.count, isTokenByte(pattern[index]) {
                if start < 0 { start = index }
                continue
            }
            guard start >= 0 else { continue }
            let leftOK = start == 0 ? filter.anchor != .none : pattern[start - 1] != UInt8(ascii: "*")
            let rightOK = index == pattern.count ? filter.endAnchor : pattern[index] != UInt8(ascii: "*")
            if leftOK, rightOK, index - start >= 2 {
                tokens.append(hash(pattern[start..<index]))
            }
            start = -1
        }
        return tokens
    }

    func firstMatch(_ request: BrowserFilterRequest) -> BrowserCompiledNetworkFilter? {
        guard !filters.isEmpty else { return nil }
        let url = request.lowercasedURL
        // The host and each parent domain.
        var start = request.hostRange.lowerBound
        let end = request.hostRange.upperBound
        while start < end {
            if let indices = byHost[Self.hash(url[start..<end])],
               let filter = firstMatch(indices, request)
            {
                return filter
            }
            guard let dot = url[start..<end].firstIndex(of: 0x2E) else { break }
            start = dot + 1
        }
        var tokenStart = -1
        for index in 0...url.count {
            let isToken = index < url.count && Self.isTokenByte(url[index])
            if isToken {
                if tokenStart < 0 { tokenStart = index }
                continue
            }
            guard tokenStart >= 0 else { continue }
            if let indices = byToken[Self.hash(url[tokenStart..<index])],
               let filter = firstMatch(indices, request)
            {
                return filter
            }
            tokenStart = -1
        }
        return firstMatch(fallback, request)
    }

    private func firstMatch(_ indices: [Int32], _ request: BrowserFilterRequest) -> BrowserCompiledNetworkFilter? {
        for index in indices where filters[Int(index)].matches(request) {
            return filters[Int(index)]
        }
        return nil
    }
}

// MARK: - BrowserCosmeticIndex

/// Element hiding rules: the selectors every site hides, and those of single sites.
struct BrowserCosmeticIndex {
    // MARK: Internal

    /// Selectors of a hiding rule, one rule per this many.
    static let selectorsPerRule = 20

    let genericSelectors: [String]

    // MARK: Private

    private let genericSet: Set<String>
    private let genericWithExclusions: [BrowserCosmeticFilter]
    private let specific: [String: [BrowserCosmeticFilter]]
    private let exceptions: [String: Set<String>]
    private let genericStyleSheet: String

    var isEmpty: Bool { genericSelectors.isEmpty && genericWithExclusions.isEmpty && specific.isEmpty }

    init(_ filters: [BrowserCosmeticFilter]) {
        var globalExceptions = Set<String>()
        var exceptions = [String: Set<String>]()
        for filter in filters where filter.isException {
            if filter.includedDomains.isEmpty {
                globalExceptions.insert(filter.selector)
            }
            for domain in filter.includedDomains {
                exceptions[domain, default: []].insert(filter.selector)
            }
        }
        var generic = [String]()
        var seenGeneric = Set<String>()
        var genericWithExclusions = [BrowserCosmeticFilter]()
        var specific = [String: [BrowserCosmeticFilter]]()
        for filter in filters where !filter.isException && !globalExceptions.contains(filter.selector) {
            if !filter.includedDomains.isEmpty {
                for domain in filter.includedDomains {
                    specific[domain, default: []].append(filter)
                }
            } else if !filter.excludedDomains.isEmpty {
                genericWithExclusions.append(filter)
            } else if seenGeneric.insert(filter.selector).inserted {
                generic.append(filter.selector)
            }
        }
        self.genericSelectors = generic
        self.genericSet = seenGeneric
        self.genericWithExclusions = genericWithExclusions
        self.specific = specific
        self.exceptions = exceptions
        self.genericStyleSheet = Self.styleSheet(generic)
    }

    /// CSS that hides matching elements, one `display: none` rule per few
    /// selectors so an invalid one loses only its neighbors.
    static func styleSheet(_ selectors: [String]) -> String {
        guard !selectors.isEmpty else { return "" }
        var css = ""
        var index = 0
        while index < selectors.count {
            let end = min(index + selectorsPerRule, selectors.count)
            css += selectors[index..<end].joined(separator: ",")
            css += "{display:none!important}\n"
            index = end
        }
        return css
    }

    /// The selectors a page of the host hides: the generic ones unless the
    /// list turns them off there, then the site's own.
    func styleSheet(forHost host: String, includesGeneric: Bool) -> String {
        let domains = BrowserFilterDomains.hostAndParents(host)
        let unhidden = domains.reduce(into: Set<String>()) { $0.formUnion(exceptions[$1] ?? []) }
        var css = ""
        if includesGeneric {
            if unhidden.isDisjoint(with: genericSet) {
                css = genericStyleSheet
            } else {
                css = Self.styleSheet(genericSelectors.filter { !unhidden.contains($0) })
            }
        }
        var own = [String]()
        var seen = Set<String>()
        if includesGeneric {
            for filter in genericWithExclusions where !unhidden.contains(filter.selector)
                && !filter.excludedDomains.contains(where: { BrowserFilterDomains.host(host, isOrIsSubdomainOf: $0) })
                && seen.insert(filter.selector).inserted
            {
                own.append(filter.selector)
            }
        }
        for domain in domains {
            for filter in specific[domain] ?? [] where !unhidden.contains(filter.selector)
                && !filter.excludedDomains.contains(where: { BrowserFilterDomains.host(host, isOrIsSubdomainOf: $0) })
                && seen.insert(filter.selector).inserted
            {
                own.append(filter.selector)
            }
        }
        return css + Self.styleSheet(own)
    }
}

// MARK: - BrowserFilterEngine

/// One filter list, ready to answer for requests and pages.
final class BrowserFilterEngine: Sendable {
    // MARK: Internal

    let networkFilterCount: Int
    let cosmeticFilterCount: Int

    // MARK: Private

    private let blocking: BrowserNetworkFilterSet
    private let important: BrowserNetworkFilterSet
    private let exceptions: BrowserNetworkFilterSet
    private let documentExceptions: [([BrowserNetworkFilter.DocumentOption], BrowserCompiledNetworkFilter)]
    private let cosmetic: BrowserCosmeticIndex

    init(_ list: BrowserParsedFilterList) {
        var blocking = [BrowserNetworkFilter]()
        var important = [BrowserNetworkFilter]()
        var exceptions = [BrowserNetworkFilter]()
        var documentExceptions = [BrowserNetworkFilter]()
        for filter in list.networkFilters {
            if filter.isException {
                if !filter.documentOptions.isEmpty {
                    documentExceptions.append(filter)
                }
                if !filter.types.isEmpty {
                    exceptions.append(filter)
                }
            } else if filter.isImportant {
                important.append(filter)
            } else {
                blocking.append(filter)
            }
        }
        self.blocking = BrowserNetworkFilterSet(blocking)
        self.important = BrowserNetworkFilterSet(important)
        self.exceptions = BrowserNetworkFilterSet(exceptions)
        self.documentExceptions = documentExceptions.map { ($0.documentOptions, BrowserCompiledNetworkFilter($0)) }
        self.cosmetic = BrowserCosmeticIndex(list.cosmeticFilters)
        self.networkFilterCount = list.networkFilters.count
        self.cosmeticFilterCount = list.cosmeticFilters.count
    }

    convenience init(text: String) {
        self.init(BrowserFilterListParser.parse(text))
    }

    /// Whether the list blocks the request. `documentURLString` is the page
    /// in the tab, whose exceptions may allow everything on it.
    func blocks(_ request: BrowserFilterRequest, documentURLString: String?) -> Bool {
        if important.firstMatch(request) != nil {
            return true
        }
        guard blocking.firstMatch(request) != nil else { return false }
        if exceptions.firstMatch(request) != nil {
            return false
        }
        if let documentURLString, documentOptions(forDocumentURLString: documentURLString).contains(.document) {
            return false
        }
        return true
    }

    /// What the list's exceptions turn off on a page.
    func documentOptions(forDocumentURLString urlString: String) -> Set<BrowserNetworkFilter.DocumentOption> {
        guard !documentExceptions.isEmpty,
              let request = BrowserFilterRequest(urlString: urlString, sourceURLString: urlString, type: .other)
        else { return [] }
        var options = Set<BrowserNetworkFilter.DocumentOption>()
        for (kinds, filter) in documentExceptions where filter.matchesDocument(request) {
            options.formUnion(kinds)
        }
        return options
    }

    /// CSS that hides the list's elements on a page at this URL.
    func hidingStyleSheet(forDocumentURLString urlString: String, includesGeneric: Bool = true) -> String {
        guard !cosmetic.isEmpty, let host = BrowserFilterRequest.host(ofURLString: urlString) else { return "" }
        let options = documentOptions(forDocumentURLString: urlString)
        guard !options.contains(.document), !options.contains(.elementHiding) else { return "" }
        return cosmetic.styleSheet(
            forHost: host,
            includesGeneric: includesGeneric && !options.contains(.genericHiding),
        )
    }
}

private extension BrowserCompiledNetworkFilter {
    /// A document exception names the page's own URL and the sites it applies on.
    func matchesDocument(_ request: BrowserFilterRequest) -> Bool {
        if !includedDomains.isEmpty || !excludedDomains.isEmpty {
            guard BrowserFilterDomains.matches(
                host: request.host,
                included: includedDomains,
                excluded: excludedDomains,
            ) else { return false }
        }
        return matchesURL(request)
    }
}
