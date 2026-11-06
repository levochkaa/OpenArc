// BrowserSessionSnapshots.swift

import Foundation
import GRDB

/// Dated copies of a profile's sidebar and tabs, restored from Help > Restore Data.
/// One is taken at launch, at most once a day. A restore happens at the next launch, before the
/// database opens, and first keeps a copy of what it replaces, so it can be undone the same way.
struct BrowserSessionSnapshots {
    // MARK: Internal

    static let keptSnapshots = 10
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    // MARK: Private

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter
    }()

    let databaseURL: URL

    var directoryURL: URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("Restore Points", isDirectory: true)
    }

    private var pendingURL: URL {
        directoryURL.appendingPathComponent("restore-pending")
    }

    /// Newest first.
    func snapshots() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ??
            []
        return files.filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func date(of snapshot: URL) -> Date? {
        Self.formatter.date(from: snapshot.deletingPathExtension().lastPathComponent)
    }

    /// What launch does first. Never in the way of opening the app: a failure just leaves things as they are.
    func prepareForLaunch(now: Date = Date()) {
        do {
            try applyPendingRestore(now: now)
            try takeSnapshotIfDue(now: now)
        } catch {
            NSLog("OpenArc restore points: \(error)")
        }
    }

    /// The next launch puts this snapshot in place.
    func scheduleRestore(of snapshot: URL) throws {
        try snapshot.lastPathComponent.write(to: pendingURL, atomically: true, encoding: .utf8)
    }

    func takeSnapshot(now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let name = Self.formatter.string(from: now) + ".sqlite"
        let target = directoryURL.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let partial = target.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        // VACUUM INTO includes what's still in the write-ahead log, and writes one self-contained file.
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [partial.path])
        }
        try queue.close()
        try FileManager.default.moveItem(at: partial, to: target)
        for old in snapshots().dropFirst(Self.keptSnapshots) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private func takeSnapshotIfDue(now: Date) throws {
        if let newest = snapshots().first.flatMap(date(of:)),
           now.timeIntervalSince(newest) < Self.minimumInterval
        {
            return
        }
        try takeSnapshot(now: now)
    }

    private func applyPendingRestore(now: Date) throws {
        guard let name = try? String(contentsOf: pendingURL, encoding: .utf8) else { return }
        // Once only, whatever happens next: a bad restore mustn't repeat at every launch.
        try FileManager.default.removeItem(at: pendingURL)
        let snapshot = directoryURL.appendingPathComponent((name as NSString).lastPathComponent)
        guard FileManager.default.fileExists(atPath: snapshot.path) else { return }
        let staged = databaseURL.appendingPathExtension("restoring")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: snapshot, to: staged)
        // After staging, since making room may remove the oldest copy, which could be this one.
        try takeSnapshot(now: now)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
        _ = try FileManager.default.replaceItemAt(databaseURL, withItemAt: staged)
    }
}
