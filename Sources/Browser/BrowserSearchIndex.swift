// BrowserSearchIndex.swift

import Foundation

// MARK: - BrowserSearchDocument

struct BrowserSearchDocument: Codable {
    var title: String
    var urlString: String
    var visitCount = 0
    var typedCount = 0
    /// Seconds since 1970, or 0 when unknown.
    var lastVisit: TimeInterval = 0
}

// MARK: - BrowserSearchIndex

/// Finds pages in the time of one keystroke. Every distinct word is listed once with
/// a mask of the characters in it, so most words are ruled out by two integer
/// comparisons before any text is compared. A word contains a term only if it has all
/// the term's classes, and each edit changes at most two of them, so the mask never
/// drops a real match. The idea comes from fsearch, by way of DoodleMaster's search.
final class BrowserSearchIndex: Sendable {
    private enum Field: UInt8 { case host = 0, title = 1, path = 2 }

    private struct Posting {
        let document: Int32
        let field: UInt8
    }

    // MARK: Internal

    let documents: [BrowserSearchDocument]

    private let words: [[UInt8]]
    private let masks: [UInt64]
    private let postings: [[Posting]]
    private let hosts: [[UInt8]]

    init(documents: [BrowserSearchDocument]) {
        self.documents = documents
        var ids = [String: Int]()
        var words = [[UInt8]]()
        var masks = [UInt64]()
        var postings = [[Posting]]()
        var hosts = [[UInt8]]()
        hosts.reserveCapacity(documents.count)
        for (index, document) in documents.enumerated() {
            let parts = Self.addressParts(of: document.urlString)
            hosts.append(Array(Self.normalized(parts.host).utf8))
            for (text, field) in [(parts.host, Field.host), (document.title, .title), (parts.path, .path)] {
                var seen = Set<String>()
                for word in Self.words(in: text) where seen.insert(word).inserted {
                    let id: Int
                    if let known = ids[word] {
                        id = known
                    } else {
                        id = words.count
                        ids[word] = id
                        let bytes = Array(word.utf8)
                        words.append(bytes)
                        masks.append(Self.mask(of: bytes))
                        postings.append([])
                    }
                    postings[id].append(Posting(document: Int32(index), field: field.rawValue))
                }
            }
        }
        self.words = words
        self.masks = masks
        self.postings = postings
        self.hosts = hosts
    }

    // MARK: Text

    /// Lowercase without accents. The same text always gives the same words.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    static func words(in text: String) -> [String] {
        normalized(text)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Damerau–Levenshtein, giving up once it passes `limit`.
    static func editDistance(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previousPrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1..<(a.count + 1) {
            current[0] = i
            var rowBest = i
            for j in 1..<(b.count + 1) {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                var value = min(substitution, min(previous[j] + 1, current[j - 1] + 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previousPrevious[j - 2] + 1)
                }
                current[j] = value
                rowBest = min(rowBest, value)
            }
            if rowBest > limit { return limit + 1 }
            swap(&previousPrevious, &previous)
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: Private

    private static func addressParts(of urlString: String) -> (host: String, path: String) {
        guard let components = URLComponents(string: urlString) else { return ("", urlString) }
        var host = components.host ?? ""
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return (host, components.path + " " + (components.query ?? ""))
    }

    private static func mask(of bytes: [UInt8]) -> UInt64 {
        var mask: UInt64 = 0
        for byte in bytes {
            mask |= 1 << UInt64(byte % 64)
        }
        return mask
    }

    private static func allowedEdits(forLength length: Int) -> Int {
        switch length {
        case ..<4: 0
        case ..<8: 1
        default: 2
        }
    }

    private static func quality(of word: [UInt8], against term: [UInt8], contained: Bool, maximumEdits: Int) -> Float {
        if contained {
            if word == term { return 1 }
            if word.starts(with: term) { return 0.85 }
            if term.count >= 2, containsSequence(word, term) { return 0.45 }
        }
        guard maximumEdits > 0, editDistance(word, term, limit: maximumEdits) <= maximumEdits else { return 0 }
        return 0.35
    }

    private static func containsSequence(_ word: [UInt8], _ term: [UInt8]) -> Bool {
        guard word.count >= term.count else { return false }
        for start in 0...(word.count - term.count) where word[start] == term[0] {
            var offset = 1
            while offset < term.count, word[start + offset] == term[offset] {
                offset += 1
            }
            if offset == term.count { return true }
        }
        return false
    }

    /// Document indices, best first. Every word of the query must match somewhere.
    func search(_ query: String, limit: Int, now: Date = Date()) -> [Int] {
        let terms = Self.words(in: query)
        guard !terms.isEmpty, limit > 0, !documents.isEmpty else { return [] }
        var totals = [Float](repeating: 0, count: documents.count)
        var counts = [UInt8](repeating: 0, count: documents.count)
        var best = [Float](repeating: 0, count: documents.count)
        var touched = [Int32]()
        for (termIndex, term) in terms.enumerated() {
            let termBytes = Array(term.utf8)
            let termMask = Self.mask(of: termBytes)
            let maximumEdits = Self.allowedEdits(forLength: termBytes.count)
            touched.removeAll(keepingCapacity: true)
            for wordIndex in words.indices {
                let word = words[wordIndex]
                let mask = masks[wordIndex]
                let contained = word.count >= termBytes.count && (mask & termMask) == termMask
                let lengthGap = abs(word.count - termBytes.count)
                let nearby = maximumEdits > 0 && lengthGap <= maximumEdits
                    && (mask ^ termMask).nonzeroBitCount <= maximumEdits * 2
                guard contained || nearby else { continue }
                let quality = Self.quality(
                    of: word,
                    against: termBytes,
                    contained: contained,
                    maximumEdits: maximumEdits,
                )
                guard quality > 0 else { continue }
                for posting in postings[wordIndex] {
                    let fieldWeight: Float =
                        switch posting.field {
                        case Field.host.rawValue: 1.5
                        case Field.title.rawValue: 1.2
                        default: 0.6
                        }
                    let score = quality * fieldWeight
                    let document = Int(posting.document)
                    if best[document] == 0 {
                        touched.append(posting.document)
                    }
                    best[document] = max(best[document], score)
                }
            }
            for document in touched {
                let index = Int(document)
                if Int(counts[index]) == termIndex {
                    counts[index] += 1
                    totals[index] += best[index]
                }
                best[index] = 0
            }
        }
        let needed = UInt8(terms.count)
        let rawQuery = Array(Self.normalized(query).utf8)
        var scored = [(index: Int, score: Float)]()
        for index in documents.indices where counts[index] == needed {
            scored.append((index, totals[index] * 4 + importance(of: index, rawQuery: rawQuery, now: now)))
        }
        scored.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        return scored.prefix(limit).map(\.index)
    }

    /// How much a page matters regardless of the words: visits, typing it by hand,
    /// recency, a short address, and the query being how its host starts.
    private func importance(of index: Int, rawQuery: [UInt8], now: Date) -> Float {
        let document = documents[index]
        var score = log2(Float(document.visitCount) + 1) * 0.5 + log2(Float(document.typedCount) + 1) * 1.1
        if document.lastVisit > 0 {
            let days = Float(max(now.timeIntervalSince1970 - document.lastVisit, 0) / 86400)
            score += 1.6 / (1 + days / 21)
        }
        score -= log2(Float(document.urlString.utf8.count) + 1) * 0.12
        if !rawQuery.isEmpty, hosts[index].starts(with: rawQuery) {
            score += 3
        }
        return score
    }
}
