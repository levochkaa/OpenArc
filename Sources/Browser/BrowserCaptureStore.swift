// BrowserCaptureStore.swift

import Foundation

// MARK: - BrowserCapture

/// A picture saved to the Library from a capture, with the page it came from.
struct BrowserCapture: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case area
        case image
        case fullPage
    }

    let id: UUID
    let createdAt: Date
    let kind: Kind
    let pageURL: String?
    let title: String?

    var fileName: String { id.uuidString + ".png" }
}

// MARK: - BrowserCaptureStore

/// Captures saved to the Library: PNG files in one folder and an index with
/// where each came from. Media lists the folder like the other picture folders.
final class BrowserCaptureStore: @unchecked Sendable {
    // MARK: Internal

    static let didChangeNotification = Notification.Name("BrowserCaptureStoreDidChange")

    /// The running browser's store, next to its session data; set at launch.
    nonisolated(unsafe) static var shared: BrowserCaptureStore?

    let directory: URL

    // MARK: Private

    private let fileManager: FileManager

    /// Newest first.
    var captures: [BrowserCapture] {
        loadIndex().sorted { $0.createdAt > $1.createdAt }
    }

    private var indexURL: URL { directory.appendingPathComponent("Captures.json", isDirectory: false) }

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func fileURL(for capture: BrowserCapture) -> URL {
        directory.appendingPathComponent(capture.fileName, isDirectory: false)
    }

    /// The capture a file in the folder belongs to.
    func capture(forFileURL url: URL) -> BrowserCapture? {
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            return nil
        }
        return loadIndex().first { $0.fileName == url.lastPathComponent }
    }

    @discardableResult func save(
        png: Data,
        kind: BrowserCapture.Kind,
        pageURL: String?,
        title: String?,
        now: Date = Date(),
    ) -> BrowserCapture? {
        let capture = BrowserCapture(id: UUID(), createdAt: now, kind: kind, pageURL: pageURL, title: title)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: fileURL(for: capture), options: .atomic)
            var index = loadIndex()
            index.append(capture)
            try writeIndex(index)
        } catch {
            try? fileManager.removeItem(at: fileURL(for: capture))
            return nil
        }
        notifyChange()
        return capture
    }

    /// Replaces the picture of a saved capture, after an edit.
    func replacePNG(_ png: Data, of capture: BrowserCapture) {
        guard (try? png.write(to: fileURL(for: capture), options: .atomic)) != nil else { return }
        notifyChange()
    }

    func delete(_ capture: BrowserCapture) {
        try? fileManager.removeItem(at: fileURL(for: capture))
        let index = loadIndex().filter { $0.id != capture.id }
        try? writeIndex(index)
        notifyChange()
    }

    /// Entries whose file is gone are left out.
    private func loadIndex() -> [BrowserCapture] {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder.captureIndex.decode([BrowserCapture].self, from: data)
        else { return [] }
        return entries.filter { fileManager.fileExists(atPath: fileURL(for: $0).path) }
    }

    private func writeIndex(_ entries: [BrowserCapture]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.captureIndex.encode(entries).write(to: indexURL, options: .atomic)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

private extension JSONEncoder {
    static var captureIndex: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var captureIndex: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
