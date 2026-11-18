// BrowserMobilePhoneTests.swift

import Foundation
import Testing
import UIKit

// MARK: - Search suggestions

@Test func mobileSearchSuggestionsListTabsForAnEmptyQuery() {
    let candidates = [
        BrowserMobileSearchSuggestions.Candidate(
            tabID: "a", title: "", urlString: "https://www.apple.com/", location: nil,
        ),
        .init(tabID: "b", title: "Docs", urlString: "https://docs.example.com/", location: "Pinned in Work"),
    ]
    let suggestions = BrowserMobileSearchSuggestions(query: "  ", candidates: candidates)
    #expect(suggestions.completion == nil)
    #expect(suggestions.items.map(\.kind) == [.tab("a"), .tab("b")])
    #expect(suggestions.items.map(\.title) == ["apple.com", "Docs"], "An untitled tab shows its host")
    #expect(suggestions.items[1].subtitle == "Pinned in Work")
}

@Test func mobileSearchSuggestionsCompleteATypedHostFromOpenTabs() {
    let candidates = [
        BrowserMobileSearchSuggestions.Candidate(
            tabID: "a", title: "Apple", urlString: "https://www.apple.com/iphone", location: nil,
        ),
    ]
    let suggestions = BrowserMobileSearchSuggestions(query: "app", candidates: candidates)
    #expect(suggestions.completion == "apple.com")
    #expect(suggestions.items.map(\.kind) == [.address("apple.com"), .search("app"), .tab("a")])
    #expect(suggestions.items[0].title == "Apple")

    let exact = BrowserMobileSearchSuggestions(query: "apple.com", candidates: candidates)
    #expect(exact.completion == nil, "A host typed in full needs no completion")
    #expect(exact.items.first?.kind == .address("apple.com"))
}

@Test func mobileSearchSuggestionsTreatSpacedTextAsASearch() {
    let suggestions = BrowserMobileSearchSuggestions(query: "apple pie", candidates: [])
    #expect(suggestions.completion == nil)
    #expect(suggestions.items.map(\.kind) == [.search("apple pie")])
    let address = BrowserMobileSearchSuggestions(query: "example.org/path", candidates: [])
    #expect(address.items.map(\.kind) == [.address("example.org/path"), .search("example.org/path")])
    #expect(address.items[0].iconPage == "https://example.org/path")
}

// MARK: - Bar backdrop

@Test func mobileBackdropMeasuresLuminanceAndKeepsItsLookBetweenTheLimits() throws {
    func image(white: CGFloat) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor(white: white, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return try #require(rendered.cgImage)
    }
    let black = try #require(BrowserMobileBackdrop.luminance(of: image(white: 0)))
    let white = try #require(BrowserMobileBackdrop.luminance(of: image(white: 1)))
    #expect(black < 0.01)
    #expect(white > 0.99)
    #expect(BrowserMobileBackdrop.isDark(luminance: black, current: false))
    #expect(!BrowserMobileBackdrop.isDark(luminance: white, current: true))
    #expect(BrowserMobileBackdrop.isDark(luminance: 0.2, current: true))
    #expect(!BrowserMobileBackdrop.isDark(luminance: 0.2, current: false))
}

// MARK: - Favicons

@Test func mobileFaviconsShareAHostWithAndWithoutWWW() {
    #expect(BrowserMobileFavicons.host(forPage: "https://www.Example.com/a") == "example.com")
    #expect(BrowserMobileFavicons.host(forPage: "http://example.com") == "example.com")
    #expect(BrowserMobileFavicons.host(forPage: "about:blank") == nil)
    #expect(BrowserMobileFavicons.host(forPage: "file:///tmp/a.html") == nil)
}

@Test func mobileFaviconsRankDrawnAndSizedIconsFirstAndFallBackToFaviconICO() {
    let rows = [
        ["https://example.com/icon.svg", "icon", "", "image/svg+xml"],
        ["https://example.com/touch.png", "apple-touch-icon", "180x180", ""],
        ["https://example.com/16.png", "icon", "16x16", "image/png"],
        ["https://example.com/32.png", "icon", "32x32", "image/png"],
        ["data:image/png;base64,AAAA", "icon", "", ""],
        ["javascript:alert(1)", "icon", "", ""],
    ]
    let urls = BrowserMobileFavicons.rankedIconURLs(rows, pageURL: URL(string: "https://example.com/page?q=1"))
    #expect(urls.map(\.absoluteString) == [
        "data:image/png;base64,AAAA",
        "https://example.com/32.png",
        "https://example.com/16.png",
        "https://example.com/touch.png",
        "https://example.com/icon.svg",
        "https://example.com/favicon.ico",
    ])
}

// MARK: - Page menu

@MainActor @Test func mobileTextSizeStepsStopAtTheEnds() {
    let steps = BrowserMobilePhoneViewController.zoomSteps
    #expect(BrowserMobilePhoneViewController.nextZoom(from: 1, larger: true) == 1.15)
    #expect(BrowserMobilePhoneViewController.nextZoom(from: 1, larger: false) == 0.85)
    #expect(BrowserMobilePhoneViewController.nextZoom(from: 1.1, larger: false) == 1, "Off-step sizes snap to a step")
    #expect(BrowserMobilePhoneViewController.nextZoom(from: steps[steps.count - 1], larger: true) == steps.last)
    #expect(BrowserMobilePhoneViewController.nextZoom(from: steps[0], larger: false) == steps.first)
}

// MARK: - Tab switcher

@MainActor @Test func mobileSwitcherCardsBunchOlderTabsLeftAndSpaceTheNewestOut() {
    let switcher = BrowserMobileTabSwitcherView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    let entries = (0..<4).map { BrowserMobileTabSwitcherView.Entry(id: "\($0)", title: "", urlString: "") }
    switcher.setEntries(entries, focus: 2)
    let width: CGFloat = 402
    let focused = switcher.cardFrame(index: 2, position: 2)
    #expect(abs(focused.minX - width * 0.211) < 0.5)
    #expect(abs(focused.width - width * BrowserMobileTabSwitcherView.cardWidthShare) < 0.5)
    #expect(abs(focused.height / focused.width - 874 / width) < 0.01, "Cards keep the screen's shape")

    let newest = switcher.cardFrame(index: 3, position: 2)
    let step = BrowserMobileTabSwitcherView.forwardStep + BrowserMobileTabSwitcherView.newestExtraStep
    #expect(abs(newest.minX - focused.minX - width * step) < 0.5)
    #expect(abs(switcher.cardFrame(index: 3, position: 1).minX - switcher.cardFrame(index: 2, position: 1).minX
            - width * step) < 0.5, "The newest card keeps its extra room once a step away")

    let older = switcher.cardFrame(index: 1, position: 2)
    let oldest = switcher.cardFrame(index: 0, position: 2)
    #expect(abs(focused.minX - older.minX - width * BrowserMobileTabSwitcherView.backwardStep) < 0.5)
    #expect(focused.minX - older.minX > older.minX - oldest.minX, "Older cards bunch up")
    #expect(oldest.minX < older.minX)
}

@Test func mobileFaviconsPlateOnlyIconsThatVanishOnDarkBackgrounds() throws {
    func icon(_ color: UIColor, background: UIColor?) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
            if let background {
                background.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
            color.setFill()
            context.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
        }
        return try #require(rendered.cgImage)
    }
    #expect(try BrowserMobileFavicons.isTooDarkForDarkBackground(icon(.black, background: nil)))
    #expect(try !BrowserMobileFavicons.isTooDarkForDarkBackground(icon(.black, background: .white)))
    #expect(try !BrowserMobileFavicons.isTooDarkForDarkBackground(icon(.systemRed, background: nil)))
    #expect(try !BrowserMobileFavicons.isTooDarkForDarkBackground(icon(.white, background: nil)))
}

@Test func mobileFaviconsRejectBlankIcons() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format)
    let blank = try #require(renderer.image { _ in }.cgImage)
    let mark = try #require(renderer.image { context in
        UIColor.black.setFill()
        context.fill(CGRect(x: 6, y: 6, width: 4, height: 4))
    }
    .cgImage)
    #expect(BrowserMobileFavicons.isBlank(blank))
    #expect(!BrowserMobileFavicons.isBlank(mark))
}
