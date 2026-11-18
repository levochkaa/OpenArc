// BrowserContentRuleListCompiler.swift

import Foundation

// MARK: - BrowserContentRule

/// One rule of a WebKit content rule list.
struct BrowserContentRule: Encodable, Equatable {
    struct Trigger: Encodable, Equatable {
        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case isCaseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case loadContext = "load-context"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case ifTopURL = "if-top-url"
        }

        var urlFilter: String
        var isCaseSensitive: Bool?
        var resourceType: [String]?
        var loadType: [String]?
        var loadContext: [String]?
        var ifDomain: [String]?
        var unlessDomain: [String]?
        var ifTopURL: [String]?
    }

    struct Action: Encodable, Equatable {
        var type: String
        var selector: String?
    }

    var trigger: Trigger
    var action: Action
}

// MARK: - BrowserContentRuleListCompiler

/// Turns a filter list into WebKit content rules, in an order where later
/// rules override earlier ones: blocking, exceptions, important blocking,
/// then element hiding, which a page's own document never undoes.
enum BrowserContentRuleListCompiler {
    // MARK: Internal

    static func rules(for list: BrowserParsedFilterList) -> [BrowserContentRule] {
        var blocking = [BrowserContentRule]()
        var exceptions = [BrowserContentRule]()
        var important = [BrowserContentRule]()
        var documentExceptions = [BrowserContentRule]()
        for filter in list.networkFilters {
            if filter.isException, filter.documentOptions.contains(.document) {
                for urlFilter in urlFilters(for: filter) {
                    documentExceptions.append(BrowserContentRule(
                        trigger: .init(urlFilter: ".*", ifTopURL: [urlFilter]),
                        action: .init(type: "ignore-previous-rules"),
                    ))
                }
            }
            guard !filter.types.isEmpty else { continue }
            let rules = networkRules(for: filter)
            if filter.isException {
                exceptions += rules
            } else if filter.isImportant {
                important += rules
            } else {
                blocking += rules
            }
        }
        // A tab's own page always loads; a blocked one would show only an error.
        let pageDocument = BrowserContentRule(
            trigger: .init(urlFilter: ".*", resourceType: ["document"], loadContext: ["top-frame"]),
            action: .init(type: "ignore-previous-rules"),
        )
        return blocking + exceptions + important + [pageDocument] + hidingRules(for: list.cosmeticFilters)
            + documentExceptions
    }

    static func encodedJSON(for list: BrowserParsedFilterList) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(rules(for: list)) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// WebKit's regular expressions for the filter's URL pattern. A `^` at the
    /// end stands for a separator or the URL's end, which WebKit cannot say in
    /// one expression, so that pattern gives two.
    static func urlFilters(for filter: BrowserNetworkFilter) -> [String] {
        guard filter.pattern.unicodeScalars.allSatisfy(\.isASCII) else { return [] }
        var prefix = ""
        switch filter.anchor {
        case .host: prefix = "^[^:]+://+([^:/]+\\.)?"
        case .start: prefix = "^"
        case .none: break
        }
        var pattern = Substring(filter.pattern)
        var endsWithSeparator = false
        if !filter.endAnchor, pattern.hasSuffix("^") {
            pattern = pattern.dropLast()
            endsWithSeparator = true
        }
        var body = ""
        for character in pattern {
            switch character {
            case "*": body += ".*"
            case "^": body += separatorClass
            case ".",
                 "+",
                 "?",
                 "$",
                 "{",
                 "}",
                 "(",
                 ")",
                 "[",
                 "]",
                 "\\",
                 "|": body += "\\\(character)"
            default: body.append(character)
            }
        }
        let regex = prefix + body
        if filter.endAnchor {
            return [regex + "$"]
        }
        guard endsWithSeparator else {
            return [regex.isEmpty ? ".*" : regex]
        }
        // A host is always followed by a port or a path.
        if filter.hostOnlyPattern != nil {
            return [regex + separatorClass]
        }
        return [regex + separatorClass, regex + "$"]
    }

    // MARK: Private

    private static let separatorClass = "[^a-zA-Z0-9_.%-]"

    private static func networkRules(for filter: BrowserNetworkFilter) -> [BrowserContentRule] {
        var trigger = BrowserContentRule.Trigger(urlFilter: "")
        if filter.matchCase {
            trigger.isCaseSensitive = true
        }
        if filter.types != .all {
            var types = [String]()
            let names: [(BrowserFilterResourceTypes, String)] = [
                (.script, "script"), (.image, "image"), (.stylesheet, "style-sheet"), (.font, "font"),
                (.media, "media"), (.subdocument, "document"), (.xmlHTTPRequest, "fetch"), (.ping, "ping"),
                (.websocket, "websocket"), (.object, "other"), (.other, "other"),
            ]
            for (type, name) in names where filter.types.contains(type) && !types.contains(name) {
                types.append(name)
            }
            trigger.resourceType = types
        }
        if let thirdParty = filter.thirdParty {
            trigger.loadType = [thirdParty ? "third-party" : "first-party"]
        }
        if !filter.includedDomains.isEmpty {
            trigger.ifDomain = filter.includedDomains.map { "*" + $0 }
        } else if !filter.excludedDomains.isEmpty {
            trigger.unlessDomain = filter.excludedDomains.map { "*" + $0 }
        }
        let action = BrowserContentRule.Action(type: filter.isException ? "ignore-previous-rules" : "block")
        return urlFilters(for: filter).map { urlFilter in
            var trigger = trigger
            trigger.urlFilter = urlFilter
            return BrowserContentRule(trigger: trigger, action: action)
        }
    }

    /// `css-display-none` rules: generic selectors a few to a rule, and each
    /// site's own. A selector a site unhides is kept off that site.
    private static func hidingRules(for filters: [BrowserCosmeticFilter]) -> [BrowserContentRule] {
        var globalExceptions = Set<String>()
        var exceptionDomains = [String: [String]]()
        for filter in filters where filter.isException {
            if filter.includedDomains.isEmpty {
                globalExceptions.insert(filter.selector)
            }
            for domain in filter.includedDomains {
                exceptionDomains[filter.selector, default: []].append(domain)
            }
        }
        var generic = [String]()
        var seen = Set<String>()
        var rules = [BrowserContentRule]()
        var specific = [[String]: [String]]()
        var specificOrder = [[String]]()
        for filter in filters where !filter.isException && !globalExceptions.contains(filter.selector) {
            let unhidden = exceptionDomains[filter.selector] ?? []
            if !filter.includedDomains.isEmpty {
                let domains = filter.includedDomains.filter { !unhidden.contains($0) }.map { "*" + $0 }
                guard !domains.isEmpty else { continue }
                if specific[domains] == nil {
                    specificOrder.append(domains)
                }
                specific[domains, default: []].append(filter.selector)
            } else if !filter.excludedDomains.isEmpty || !unhidden.isEmpty {
                rules.append(BrowserContentRule(
                    trigger: .init(urlFilter: ".*", unlessDomain: (filter.excludedDomains + unhidden).map { "*" + $0 }),
                    action: .init(type: "css-display-none", selector: filter.selector),
                ))
            } else if seen.insert(filter.selector).inserted {
                generic.append(filter.selector)
            }
        }
        var index = 0
        while index < generic.count {
            let end = min(index + BrowserCosmeticIndex.selectorsPerRule, generic.count)
            rules.append(BrowserContentRule(
                trigger: .init(urlFilter: ".*"),
                action: .init(type: "css-display-none", selector: generic[index..<end].joined(separator: ",")),
            ))
            index = end
        }
        for domains in specificOrder {
            let selectors = specific[domains] ?? []
            var start = 0
            while start < selectors.count {
                let end = min(start + BrowserCosmeticIndex.selectorsPerRule, selectors.count)
                rules.append(BrowserContentRule(
                    trigger: .init(urlFilter: ".*", ifDomain: domains),
                    action: .init(type: "css-display-none", selector: selectors[start..<end].joined(separator: ",")),
                ))
                start = end
            }
        }
        return rules
    }
}
