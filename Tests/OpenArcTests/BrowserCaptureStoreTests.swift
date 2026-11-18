// BrowserCaptureStoreTests.swift

import Foundation
import Testing

// MARK: - BrowserCaptureStoreTests

struct BrowserCaptureStoreTests {
    private static func makeStore() -> (BrowserCaptureStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Captures-\(UUID())")
        return (BrowserCaptureStore(directory: root), root)
    }

    @Test func aSavedCaptureKeepsItsPictureAndPageNewestFirst() throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        let old = try #require(store.save(
            png: png,
            kind: .area,
            pageURL: "https://example.com/",
            title: "Example",
            now: Date(timeIntervalSince1970: 1000),
        ))
        let new = try #require(store.save(
            png: png,
            kind: .image,
            pageURL: nil,
            title: nil,
            now: Date(timeIntervalSince1970: 2000),
        ))

        #expect(store.captures.map(\.id) == [new.id, old.id])
        #expect(try Data(contentsOf: store.fileURL(for: old)) == png)
        #expect(store.capture(forFileURL: store.fileURL(for: old))?.pageURL == "https://example.com/")
        #expect(store.capture(forFileURL: root.appendingPathComponent("elsewhere/\(old.fileName)")) == nil)
    }

    @Test func deletingRemovesTheFileAndTheEntry() throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try #require(store.save(png: Data([1]), kind: .area, pageURL: nil, title: nil))

        store.delete(capture)

        #expect(store.captures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: capture).path))
    }

    @Test func anEntryWhoseFileIsGoneIsLeftOut() throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try #require(store.save(png: Data([1]), kind: .fullPage, pageURL: nil, title: nil))

        try FileManager.default.removeItem(at: store.fileURL(for: capture))

        #expect(store.captures.isEmpty)
    }

    @Test func mediaOffersCapturesBeforeDownloads() {
        #expect(BrowserLibraryMediaSource.allCases == [.documents, .desktop, .screenshots, .captures, .downloads])
    }
}
