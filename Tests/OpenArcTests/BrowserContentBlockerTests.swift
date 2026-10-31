// BrowserContentBlockerTests.swift

import Foundation
import Testing

// MARK: - BrowserContentBlockerTests

@Suite(.serialized)
@MainActor struct BrowserContentBlockerTests {
}

// MARK: - Fetched

private actor Fetched {
    private(set) var count = 0

    func add(_: URL) { count += 1 }
}
