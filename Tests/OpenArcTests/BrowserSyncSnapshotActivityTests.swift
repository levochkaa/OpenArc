// BrowserSyncSnapshotActivityTests.swift

import Foundation
import Testing

@Test(arguments: [0.123456, 0.123789])
func legacyRemoteSnapshotReadsCanonicalMicrosecondActivity(fraction: TimeInterval) throws {
    let wire = String(format: "2026-10-03T10:00:00.%06dZ", Int((fraction * 1_000_000).rounded()))
    let old = BrowserTabSessionSnapshot(
        spaces: [.init(id: "space", title: "Space", systemImageName: "globe")],
        tabs: [.init(
            id: "tab",
            urlString: "https://example.com",
            spaceID: "space",
            lastActivityTimestamp: 1_900_000_000,
        )],
    )
    let event = BrowserSyncEvent(
        serverSeq: 1, deviceID: "remote", entityType: "tab", entityID: "tab", op: "upsert",
        data: .tab(.init(
            id: "tab", spaceID: "space", placement: .temporary, rank: 0,
            urlString: "https://example.com/new", pinnedURLString: nil, title: nil,
            userTitleOverride: "Remote title", faviconURLString: nil, lastActivityAt: wire,
        )),
        createdAt: "2026-10-03T10:00:01Z",
    )
    let projected = BrowserSyncSnapshotMerger.snapshot(applying: [event], to: old)
    let tab = try #require(projected.tabs.first)
    let timestamp = try #require(tab.lastActivityTimestamp)
    #expect(abs(timestamp - (1_791_021_600 + fraction)) < 0.0000003)
    #expect(tab.urlString == "https://example.com/new" && tab.userTitleOverride == "Remote title")
    // A different authoritative date wins; this decoder must not invent a
    // permanent local maximum from an unrelated old snapshot.
    #expect(timestamp < 1_900_000_000)
}
