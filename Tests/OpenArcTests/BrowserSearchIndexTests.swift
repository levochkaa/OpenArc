// BrowserSearchIndexTests.swift

import Foundation
import Testing

private func titles(_ index: BrowserSearchIndex, _ query: String, limit: Int = 10) -> [String] {
    index.search(query, limit: limit).map { index.documents[$0].title }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func wordsMatchByPrefixAnywhereAndAllMustMatch() {
    let index = BrowserSearchIndex(documents: [
        .init(title: "Pull requests", urlString: "https://github.com/pulls"),
        .init(title: "Swift Forums", urlString: "https://forums.swift.org/latest"),
        .init(title: "Pull-ups guide", urlString: "https://fitness.example/pull"),
    ])
    #expect(titles(index, "swi") == ["Swift Forums"])
    #expect(titles(index, "git pull") == ["Pull requests"], "Words can be in the address and the title")
    #expect(titles(index, "pull git") == ["Pull requests"], "In either order")
    #expect(titles(index, "pull nothing").isEmpty)
    #expect(titles(index, "   ").isEmpty)
}

@Test func typosStillFindThePageButExactWins() {
    let index = BrowserSearchIndex(documents: [
        .init(title: "Documentation", urlString: "https://docs.example/a"),
        .init(title: "Documenter", urlString: "https://docs.example/b"),
    ])
    #expect(titles(index, "documentaiton").first == "Documentation", "A swapped pair of letters")
    #expect(titles(index, "documentatio").first == "Documentation")
    #expect(titles(index, "doc").count == 2)
    #expect(titles(index, "abc").isEmpty, "Short terms don't get typos")
}

@Test func accentsCaseAndOtherAlphabetsMatch() {
    let index = BrowserSearchIndex(documents: [
        .init(title: "Café Menu", urlString: "https://cafe.example/"),
        .init(title: "Новости дня", urlString: "https://news.example/ru"),
    ])
    #expect(titles(index, "CAFE") == ["Café Menu"])
    #expect(titles(index, "новости") == ["Новости дня"])
    #expect(titles(index, "нов") == ["Новости дня"])
}

@Test func pagesPeopleUseRankFirst() {
    let index = BrowserSearchIndex(documents: [
        .init(title: "GitHub rarely", urlString: "https://github.com/some/long/path/here", visitCount: 1),
        .init(
            title: "GitHub",
            urlString: "https://github.com/",
            visitCount: 50,
            typedCount: 20,
            lastVisit: now.timeIntervalSince1970,
        ),
    ])
    #expect(index.search("git", limit: 2, now: now).first == 1)
}

@Test func theHostAnAddressStartsWithBeatsAWordElsewhere() {
    let index = BrowserSearchIndex(documents: [
        .init(title: "How to use mail", urlString: "https://blog.example/mail-tips"),
        .init(title: "Inbox", urlString: "https://mail.google.com/"),
    ])
    #expect(titles(index, "mail").first == "Inbox")
}

@Test func editDistanceCountsASwapAsOneEdit() {
    func distance(_ a: String, _ b: String) -> Int {
        BrowserSearchIndex.editDistance(Array(a.utf8), Array(b.utf8), limit: 3)
    }
    #expect(distance("form", "from") == 1)
    #expect(distance("kitten", "sitting") == 3)
    #expect(distance("same", "same") == 0)
    #expect(distance("abcdefgh", "a") == 4)
}

@Test func searchingTwentyThousandPagesTakesMilliseconds() {
    var documents = [BrowserSearchDocument]()
    for index in 0..<20000 {
        documents.append(.init(
            title: "Page \(index) about topic\(index % 500) and thing\(index % 97)",
            urlString: "https://site\(index % 800).example/section\(index % 60)/item\(index)",
            visitCount: index % 7,
        ))
    }
    let search = BrowserSearchIndex(documents: documents)
    let clock = ContinuousClock()
    var results = 0
    let elapsed = clock.measure {
        for query in ["topic4", "site7 sect", "thing9 page", "itme1234", "pag"] {
            results += search.search(query, limit: 10).count
        }
    }
    #expect(results > 0)
    // A debug build is far slower than a release one, so this only catches a regression in kind.
    #expect(elapsed < .milliseconds(1500), "Five searches took \(elapsed)")
}
