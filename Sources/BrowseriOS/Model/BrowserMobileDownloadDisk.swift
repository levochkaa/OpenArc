import Foundation

// MARK: - BrowserMobileDownloadError

enum BrowserMobileDownloadError: Error, Equatable {
    case invalidManifest
    case invalidDestination
    case missingFile
    case notCompleted
}

// MARK: - BrowserMobileDownloadDisk

/// File operations stay on this actor. Only completed, atomically committed
/// records survive reopening; interrupted transfers are not resumed.
actor BrowserMobileDownloadDisk {
    // MARK: Lifecycle

    init(directory: URL) { self.directory = directory }

    // MARK: Internal

    nonisolated static func safeFilename(_ suggested: String) -> String {
        let last = suggested.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? ""
        let allowed = last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" }
        let trimmed = String(String.UnicodeScalarView(allowed))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var result = ""
        for character in trimmed {
            guard result.utf8.count + String(character).utf8.count <= 200 else { break }
            result.append(character)
        }
        return result.isEmpty ? "Download" : result
    }

    func load() throws -> [BrowserMobileDownload] {
        try ensureLoaded()
        return completed.map { entry in
            var result = entry
            do { _ = try checkedFile(for: entry) }
            catch {
                result.status = .failed
                result.error = String(localized: "downloads.error.missingFile", table: "Mobile")
            }
            return result
        }
    }

    func prepare(id: UUID, filename: String) throws -> URL {
        try ensureLoaded()
        guard Self.safeFilename(filename) == filename,
              !completed.contains(where: { $0.id == id })
        else {
            throw BrowserMobileDownloadError.invalidDestination
        }
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw BrowserMobileDownloadError.invalidDestination
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder.appendingPathComponent(filename, isDirectory: false)
    }

    func complete(_ entry: BrowserMobileDownload) throws -> BrowserMobileDownload {
        try ensureLoaded()
        let url = try checkedFile(for: entry)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = attributes[.size] as? NSNumber else { throw BrowserMobileDownloadError.missingFile }
        var saved = entry
        saved.status = .completed
        saved.receivedBytes = bytes.int64Value
        saved.totalBytes = bytes.int64Value
        saved.error = nil
        if let existing = completed.first(where: { $0.id == entry.id }) {
            guard existing == saved else { throw BrowserMobileDownloadError.invalidManifest }
            return existing
        }
        let next = [saved] + completed
        let data = try JSONEncoder().encode(Manifest(version: 1, entries: next))
        guard data.count <= Self.maximumManifestBytes else { throw BrowserMobileDownloadError.invalidManifest }
        try data.write(to: manifestURL, options: .atomic)
        completed = next
        return saved
    }

    func exportURL(id: UUID) throws -> URL {
        try ensureLoaded()
        guard let entry = completed.first(where: { $0.id == id }) else {
            throw BrowserMobileDownloadError.notCompleted
        }
        return try checkedFile(for: entry)
    }

    func discard(id: UUID) throws {
        try ensureLoaded()
        guard !completed.contains(where: { $0.id == id }) else { return }
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Private

    private struct Manifest: Codable {
        let version: Int
        let entries: [BrowserMobileDownload]
    }

    private static let maximumManifestBytes = 8 * 1024 * 1024

    private let directory: URL
    private var completed = [BrowserMobileDownload]()
    private var isLoaded = false

    private var manifestURL: URL { directory.appendingPathComponent("downloads.json", isDirectory: false) }

    private func ensureLoaded() throws {
        guard !isLoaded else { return }
        guard directory.isFileURL else { throw BrowserMobileDownloadError.invalidDestination }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var restored = [BrowserMobileDownload]()
        if manager.fileExists(atPath: manifestURL.path) {
            let attributes = try manager.attributesOfItem(atPath: manifestURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let bytes = attributes[.size] as? NSNumber, bytes.intValue <= Self.maximumManifestBytes
            else {
                throw BrowserMobileDownloadError.invalidManifest
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.version == 1, Set(manifest.entries.map(\.id)).count == manifest.entries.count,
                  manifest.entries.allSatisfy({
                      $0.status == .completed && $0.filename == Self.safeFilename($0.filename)
                          && $0.receivedBytes >= 0 && $0.totalBytes == $0.receivedBytes && $0.error == nil
                  }) else { throw BrowserMobileDownloadError.invalidManifest }
            restored = manifest.entries
        }
        // Do not touch any bytes until the manifest is known to be valid.
        // UUID directories without a committed record are interrupted transfers.
        let retained = Set(restored.map(\.id.uuidString))
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if UUID(uuidString: url.lastPathComponent) != nil, !retained.contains(url.lastPathComponent) {
                try manager.removeItem(at: url)
            }
        }
        completed = restored
        isLoaded = true
    }

    private func checkedFile(for entry: BrowserMobileDownload) throws -> URL {
        guard entry.filename == Self.safeFilename(entry.filename) else {
            throw BrowserMobileDownloadError.invalidDestination
        }
        let folder = directory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(entry.filename, isDirectory: false)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              folder.resolvingSymlinksInPath().standardizedFileURL
              == directory.resolvingSymlinksInPath()
              .standardizedFileURL
              .appendingPathComponent(entry.id.uuidString, isDirectory: true)
        else {
            throw BrowserMobileDownloadError.missingFile
        }
        return url
    }
}
