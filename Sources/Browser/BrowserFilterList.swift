// BrowserFilterList.swift

import Foundation

// MARK: - BrowserFilterResourceTypes

/// The kinds of request a network filter names with its type options.
struct BrowserFilterResourceTypes: OptionSet, Hashable {
    static let script = Self(rawValue: 1 << 0)
    static let image = Self(rawValue: 1 << 1)
    static let stylesheet = Self(rawValue: 1 << 2)
    static let object = Self(rawValue: 1 << 3)
    static let xmlHTTPRequest = Self(rawValue: 1 << 4)
    static let subdocument = Self(rawValue: 1 << 5)
    static let ping = Self(rawValue: 1 << 6)
    static let media = Self(rawValue: 1 << 7)
    static let font = Self(rawValue: 1 << 8)
    static let websocket = Self(rawValue: 1 << 9)
    static let other = Self(rawValue: 1 << 10)

    /// Every request but a page's own document, which a filter without type options covers.
    static let all: Self = [
        .script, .image, .stylesheet, .object, .xmlHTTPRequest, .subdocument, .ping, .media, .font, .websocket, .other,
    ]

    static let optionNames: [String: Self] = [
        "script": .script,
        "image": .image,
        "stylesheet": .stylesheet,
        "css": .stylesheet,
        "object": .object,
        "object-subrequest": .object,
        "xmlhttprequest": .xmlHTTPRequest,
        "xhr": .xmlHTTPRequest,
        "subdocument": .subdocument,
        "frame": .subdocument,
        "ping": .ping,
        "beacon": .ping,
        "media": .media,
        "font": .font,
        "websocket": .websocket,
        "other": .other,
    ]

    let rawValue: UInt16
}

// MARK: - BrowserNetworkFilter

/// One request rule of a filter list: a URL pattern with Adblock Plus anchors
/// and wildcards, and the options it keeps.
struct BrowserNetworkFilter: Equatable {
    enum Anchor: Equatable {
        case none
        /// `|`: the URL starts with the pattern.
        case start
        /// `||`: the pattern starts at the host or at one of its labels.
        case host
    }

    /// What an exception with a document option turns off on matching pages.
    enum DocumentOption: Equatable {
        /// Every filter of the list.
        case document
        /// Element hiding.
        case elementHiding
        /// Element hiding that names no site.
        case genericHiding
    }

    var pattern: String
    var anchor = Anchor.none
    var endAnchor = false
    var isException = false
    var isImportant = false
    var matchCase = false
    /// nil matches both; true only requests to other sites; false only to the page's own.
    var thirdParty: Bool?
    var types = BrowserFilterResourceTypes.all
    var includedDomains = [String]()
    var excludedDomains = [String]()
    var documentOptions = [DocumentOption]()

    /// The pattern is a host with a separator after it, as in `||ads.example^`.
    var hostOnlyPattern: String? {
        guard anchor == .host, !endAnchor, pattern.hasSuffix("^") else { return nil }
        let host = pattern.dropLast()
        guard !host.isEmpty, host.utf8.allSatisfy(BrowserFilterListParser.isHostByte) else { return nil }
        return String(host)
    }
}

// MARK: - BrowserCosmeticFilter

/// One element hiding rule: a CSS selector and the sites it applies to.
struct BrowserCosmeticFilter: Equatable {
    var selector: String
    var includedDomains = [String]()
    var excludedDomains = [String]()
    var isException = false

    var isGeneric: Bool { includedDomains.isEmpty }
}

// MARK: - BrowserParsedFilterList

struct BrowserParsedFilterList: Equatable {
    var networkFilters = [BrowserNetworkFilter]()
    var cosmeticFilters = [BrowserCosmeticFilter]()
    /// Rules in a syntax the engine leaves out, such as regular expressions,
    /// redirects, scriptlets and procedural selectors.
    var skippedRuleCount = 0
}

// MARK: - BrowserFilterListParser

/// Reads the Adblock Plus filter syntax that EasyList and its sibling lists use.
/// A rule with an option or a selector the engine cannot honor is left out
/// whole, so it never blocks more than its authors meant.
enum BrowserFilterListParser {
    enum Line: Equatable {
        case network(BrowserNetworkFilter)
        case cosmetic(BrowserCosmeticFilter)
        case skipped
        case comment
    }

    // MARK: Internal

    static func parse(_ text: String) -> BrowserParsedFilterList {
        var list = BrowserParsedFilterList()
        text.enumerateLines { line, _ in
            switch parseLine(line) {
            case .network(let filter): list.networkFilters.append(filter)
            case .cosmetic(let filter): list.cosmeticFilters.append(filter)
            case .skipped: list.skippedRuleCount += 1
            case .comment: break
            }
        }
        return list
    }

    static func parseLine(_ rawLine: String) -> Line {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return .comment }
        if let separator = cosmeticSeparator(in: line) {
            return parseCosmetic(line, separator: separator)
        }
        return parseNetwork(line)
    }

    /// Letters, digits, dots and dashes: a host as filter lists write it.
    static func isHostByte(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2E || byte == 0x2D
    }

    /// Lowercased ASCII domains of a `domain=` option or a cosmetic rule's
    /// prefix. Nil when one cannot be honored, such as `example.*`.
    static func parseDomains(_ list: Substring, separator: Character) -> (
        included: [String],
        excluded: [String],
    )? {
        var included = [String]()
        var excluded = [String]()
        for rawDomain in list.split(separator: separator) {
            var domain = rawDomain.trimmingCharacters(in: .whitespaces).lowercased()
            let isExcluded = domain.hasPrefix("~")
            if isExcluded {
                domain.removeFirst()
            }
            guard !domain.isEmpty,
                  !domain.hasPrefix("."),
                  !domain.hasSuffix("."),
                  domain.utf8.allSatisfy(isHostByte) else { return nil }
            if isExcluded {
                excluded.append(domain)
            } else {
                included.append(domain)
            }
        }
        return (included, excluded)
    }

    // MARK: Private

    private enum CosmeticSeparator {
        case hide
        case exception
        case unsupported
    }

    /// Selectors that only uBlock Origin or Adblock Plus scripts understand.
    private static let proceduralMarkers = [
        ":-abp-", ":has-text(", ":xpath(", ":upward(", ":remove(", ":style(", ":matches-css", ":min-text-length(",
        ":watch-attr(", ":matches-path(", ":matches-attr(", ":matches-prop(", ":matches-media(", ":others(",
        ":shadow(", ":nth-ancestor(", ":remove-attr(", ":remove-class(", ":contains(", ":if(", ":if-not(",
        ":properties(", ":spath(",
    ]

    /// The separator of a cosmetic rule, found at the line's first `#`.
    private static func cosmeticSeparator(in line: String) -> (CosmeticSeparator, Range<String.Index>)? {
        guard let hash = line.firstIndex(of: "#") else { return nil }
        let rest = line[hash...]
        let forms: [(String, CosmeticSeparator)] = [
            ("#@#", .exception), ("##", .hide), ("#?#", .unsupported), ("#@?#", .unsupported),
            ("#$#", .unsupported), ("#@$#", .unsupported), ("#%#", .unsupported), ("#@%#", .unsupported),
            ("#$?#", .unsupported), ("#@$?#", .unsupported),
        ]
        for (form, kind) in forms where rest.hasPrefix(form) {
            return (kind, hash..<line.index(hash, offsetBy: form.count))
        }
        return nil
    }

    private static func parseCosmetic(_ line: String, separator: (CosmeticSeparator, Range<String.Index>)) -> Line {
        let (kind, range) = separator
        guard kind != .unsupported else { return .skipped }
        let selector = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard isSupportedSelector(selector),
              let domains = parseDomains(line[..<range.lowerBound], separator: ",") else { return .skipped }
        return .cosmetic(BrowserCosmeticFilter(
            selector: selector,
            includedDomains: domains.included,
            excludedDomains: domains.excluded,
            isException: kind == .exception,
        ))
    }

    /// Plain CSS with balanced brackets, quotes and parentheses; scriptlets,
    /// HTML filters and procedural operators are left out.
    private static func isSupportedSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty,
              !selector.hasPrefix("+js("),
              !selector.hasPrefix("^"),
              !selector.contains("{"),
              !selector.contains("}"),
              !selector.contains("\\"),
              selector.unicodeScalars.allSatisfy(\.isASCII) else { return false }
        let lowercased = selector.lowercased()
        guard !proceduralMarkers.contains(where: { lowercased.contains($0) }) else { return false }
        var depth = 0
        var bracketDepth = 0
        var quote: Character?
        for character in selector {
            if let open = quote {
                if character == open {
                    quote = nil
                }
                continue
            }
            switch character {
            case "\"",
                 "'": quote = character
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth < 0 { return false }
            case "[": bracketDepth += 1
            case "]":
                bracketDepth -= 1
                if bracketDepth < 0 { return false }
            default: break
            }
        }
        return depth == 0 && bracketDepth == 0 && quote == nil
    }

    private static func parseNetwork(_ line: String) -> Line {
        var body = Substring(line)
        var filter = BrowserNetworkFilter(pattern: "")
        if body.hasPrefix("@@") {
            filter.isException = true
            body = body.dropFirst(2)
        }
        if let dollar = body.lastIndex(of: "$") {
            let options = body[body.index(after: dollar)...]
            if !options.isEmpty, !options.contains("/") {
                guard applyOptions(options, to: &filter) else { return .skipped }
                body = body[..<dollar]
            }
        }
        // `/…/` is a regular expression. One of plain words and slashes is
        // the same text found anywhere; others are left out.
        if body.count > 2, body.hasPrefix("/"), body.hasSuffix("/") {
            let inner = body.dropFirst().dropLast()
            guard inner.utf8.allSatisfy({ isHostByte($0) && $0 != 0x2E || $0 == 0x2F || $0 == 0x5F }) else {
                return .skipped
            }
            body = inner
        }
        if body.hasPrefix("||") {
            filter.anchor = .host
            body = body.dropFirst(2)
        } else if body.hasPrefix("|") {
            filter.anchor = .start
            body = body.dropFirst()
        }
        if body.hasSuffix("|") {
            filter.endAnchor = true
            body = body.dropLast()
        }
        guard body.unicodeScalars.allSatisfy(\.isASCII), !body.contains(" ") else { return .skipped }
        var pattern = filter.matchCase ? String(body) : body.lowercased()
        while pattern.contains("**") {
            pattern = pattern.replacingOccurrences(of: "**", with: "*")
        }
        if filter.anchor == .none {
            while pattern.hasPrefix("*") {
                pattern.removeFirst()
            }
        }
        if !filter.endAnchor {
            while pattern.hasSuffix("*") {
                pattern.removeLast()
            }
        }
        // A rule that names no URL and no site would block everything.
        if pattern.isEmpty, filter.includedDomains.isEmpty {
            return .skipped
        }
        filter.pattern = pattern
        if filter.types.isEmpty, filter.documentOptions.isEmpty {
            return .skipped
        }
        return .network(filter)
    }

    /// Applies the options after `$`; false when one cannot be honored.
    private static func applyOptions(_ options: Substring, to filter: inout BrowserNetworkFilter) -> Bool {
        var included = BrowserFilterResourceTypes()
        var excluded = BrowserFilterResourceTypes()
        var namesDocument = false
        for rawOption in options.split(separator: ",") {
            let option = rawOption.trimmingCharacters(in: .whitespaces)
            let lowercased = option.lowercased()
            let negated = lowercased.hasPrefix("~")
            let name = negated ? String(lowercased.dropFirst()) : lowercased
            if let type = BrowserFilterResourceTypes.optionNames[name] {
                if negated {
                    excluded.insert(type)
                } else {
                    included.insert(type)
                }
                continue
            }
            switch name {
            case "third-party",
                 "3p":
                filter.thirdParty = !negated
            case "first-party",
                 "1p":
                filter.thirdParty = negated
            case "match-case":
                filter.matchCase = !negated
            case "important":
                filter.isImportant = true
            case "document",
                 "doc":
                guard !negated else { continue }
                // A blocked page would show only an error; such rules are left out.
                guard filter.isException else { return false }
                namesDocument = true
                filter.documentOptions.append(.document)
            case "elemhide",
                 "ehide":
                guard filter.isException, !negated else { return false }
                namesDocument = true
                filter.documentOptions.append(.elementHiding)
            case "generichide",
                 "ghide":
                guard filter.isException, !negated else { return false }
                namesDocument = true
                filter.documentOptions.append(.genericHiding)
            default:
                guard !negated, name.hasPrefix("domain=") || name.hasPrefix("from="),
                      let value = option.split(separator: "=", maxSplits: 1).last,
                      let domains = parseDomains(value, separator: "|") else { return false }
                filter.includedDomains = domains.included
                filter.excludedDomains = domains.excluded
            }
        }
        if !included.isEmpty {
            filter.types = included.subtracting(excluded)
        } else if !excluded.isEmpty {
            filter.types = BrowserFilterResourceTypes.all.subtracting(excluded)
        } else if namesDocument {
            filter.types = []
        }
        return true
    }
}
