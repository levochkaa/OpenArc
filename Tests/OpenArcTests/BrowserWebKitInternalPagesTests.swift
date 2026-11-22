// BrowserWebKitInternalPagesTests.swift

import Foundation
import Testing

// MARK: - BrowserWebKitInternalPagesTests

@MainActor struct BrowserWebKitInternalPagesTests {
    @Test func easelsAndNotesGetTheEmptyPagesTheWindowDrawsOver() throws {
        let easel = try BrowserWebKitInternalPages.response(for: #require(URL(string: "openarc://easel/abc")))
        #expect(easel.statusCode == 200)
        #expect(String(decoding: easel.body, as: UTF8.self).contains("<title>Easel</title>"))
        let note = try BrowserWebKitInternalPages.response(for: #require(URL(string: "openarc://notes/1")))
        #expect(note.statusCode == 200)
        #expect(note.mimeType == "text/html")
    }

    @Test func chromiumsOwnPagesSayTheyAreUnavailable() throws {
        for address in ["openarc://settings/", "chrome://history/", "openarc://password-manager/passwords"] {
            let page = try BrowserWebKitInternalPages.response(for: #require(URL(string: address)))
            #expect(page.statusCode == 200, "\(address)")
            #expect(String(decoding: page.body, as: UTF8.self).contains("<title>"), "\(address)")
        }
    }

    @Test func creditsComeFromTheBundleAndOtherAddressesAreNotFound() throws {
        let credits = try #require(URL(string: "openarc://credits/"))
        // Bundle remembers a folder's files after its first lookup, so each case gets a folder of its own.
        let empty = try scratchBundle(files: [:])
        #expect(BrowserWebKitInternalPages.response(for: credits, bundle: empty).statusCode == 404)
        let withCredits = try scratchBundle(files: ["Credits.html": "<h1>Credits</h1>"])
        let found = BrowserWebKitInternalPages.response(for: credits, bundle: withCredits)
        #expect(found.statusCode == 200)
        #expect(found.body == Data("<h1>Credits</h1>".utf8))
        let unknown = try BrowserWebKitInternalPages.response(for: #require(URL(string: "openarc://nothing/")))
        #expect(unknown.statusCode == 404)
    }

    private func scratchBundle(files: [String: String]) throws -> Bundle {
        let folder = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("InternalPages-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: folder.appendingPathComponent(name))
        }
        return try #require(Bundle(path: folder.path))
    }
}
