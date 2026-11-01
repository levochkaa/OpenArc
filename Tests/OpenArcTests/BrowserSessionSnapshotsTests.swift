// BrowserSessionSnapshotsTests.swift

import Foundation
import GRDB
import Testing

private func makeDatabase(value: String) throws -> (BrowserSessionSnapshots, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("session.sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE t (v TEXT)")
        try db.execute(sql: "INSERT INTO t VALUES (?)", arguments: [value])
    }
    try queue.close()
    return (BrowserSessionSnapshots(databaseURL: url), url)
}

private func value(in url: URL) throws -> String? {
    let queue = try DatabaseQueue(path: url.path)
    defer { try? queue.close() }
    return try queue.read { try String.fetchOne($0, sql: "SELECT v FROM t") }
}

private func set(_ text: String, in url: URL) throws {
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { try $0.execute(sql: "UPDATE t SET v = ?", arguments: [text]) }
    try queue.close()
}

@Test func aCopyIsTakenOnceADay() throws {
    let (points, _) = try makeDatabase(value: "a")
    let start = Date(timeIntervalSince1970: 1_000_000)
    points.prepareForLaunch(now: start)
    points.prepareForLaunch(now: start.addingTimeInterval(3600))
    #expect(points.snapshots().count == 1)
    points.prepareForLaunch(now: start.addingTimeInterval(25 * 3600))
    #expect(points.snapshots().count == 2)
    #expect(points.date(of: points.snapshots()[0]) == start.addingTimeInterval(25 * 3600), "Newest first")
}

@Test func aNewProfileHasNothingToCopy() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let points = BrowserSessionSnapshots(databaseURL: directory.appendingPathComponent("session.sqlite"))
    points.prepareForLaunch()
    #expect(points.snapshots().isEmpty)
}

@Test func onlyTheLastCopiesStay() throws {
    let (points, _) = try makeDatabase(value: "a")
    let start = Date(timeIntervalSince1970: 1_000_000)
    for day in 0..<BrowserSessionSnapshots.keptSnapshots + 3 {
        try points.takeSnapshot(now: start.addingTimeInterval(Double(day) * 86400))
    }
    #expect(points.snapshots().count == BrowserSessionSnapshots.keptSnapshots)
}

@Test func aRestoreHappensOnceAtLaunchAndKeepsWhatItReplaces() throws {
    let (points, url) = try makeDatabase(value: "old")
    let start = Date(timeIntervalSince1970: 1_000_000)
    try points.takeSnapshot(now: start)
    let copy = try #require(points.snapshots().first)
    try set("new", in: url)

    try points.scheduleRestore(of: copy)
    #expect(try value(in: url) == "new", "Nothing changes until the next launch")
    points.prepareForLaunch(now: start.addingTimeInterval(60))
    #expect(try value(in: url) == "old")
    #expect(points.snapshots().count == 2)
    #expect(try value(in: #require(points.snapshots().first)) == "new", "The way back")

    try set("later", in: url)
    points.prepareForLaunch(now: start.addingTimeInterval(120))
    #expect(try value(in: url) == "later", "It doesn't repeat")
}

@Test func theOldestCopyCanBeRestoredThoughItsPlaceIsNeeded() throws {
    let (points, url) = try makeDatabase(value: "oldest")
    let start = Date(timeIntervalSince1970: 1_000_000)
    try points.takeSnapshot(now: start)
    let oldest = try #require(points.snapshots().first)
    try set("newer", in: url)
    for day in 1..<BrowserSessionSnapshots.keptSnapshots {
        try points.takeSnapshot(now: start.addingTimeInterval(Double(day) * 86400))
    }
    try points.scheduleRestore(of: oldest)
    points.prepareForLaunch(now: start.addingTimeInterval(20 * 86400))
    #expect(try value(in: url) == "oldest")
}

@Test func aMissingCopyLeavesTheSessionAlone() throws {
    let (points, url) = try makeDatabase(value: "kept")
    try FileManager.default.createDirectory(at: points.directoryURL, withIntermediateDirectories: true)
    try points.scheduleRestore(of: points.directoryURL.appendingPathComponent("../../gone.sqlite"))
    points.prepareForLaunch()
    #expect(try value(in: url) == "kept")
}
