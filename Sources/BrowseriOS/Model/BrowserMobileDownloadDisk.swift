import Foundation

// MARK: - BrowserMobileDownloadError

enum BrowserMobileDownloadError: Error, Equatable {
    case invalidManifest
    case invalidDestination
    case missingFile
    case notCompleted
    case busy
}

// MARK: - BrowserMobileDownloadDiskState

struct BrowserMobileDownloadDiskState: Sendable {
    let revision: UInt64
    let entries: [BrowserMobileDownload]
    let pendingCleanupIDs: Set<UUID>
}

// MARK: - BrowserMobileDownloadStoring

protocol BrowserMobileDownloadStoring: Sendable {
    func snapshot() async throws -> BrowserMobileDownloadDiskState
    func prepare(id: UUID, filename: String) async throws -> URL
    func completeState(_ entry: BrowserMobileDownload) async throws -> BrowserMobileDownloadDiskState
    func removeState(id: UUID) async throws -> BrowserMobileDownloadDiskState
    func retryCleanup() async throws -> BrowserMobileDownloadDiskState
    func exportURL(id: UUID) async throws -> URL
    func discardState(id: UUID) async throws -> BrowserMobileDownloadDiskState
}

// MARK: - BrowserMobileDownloadDisk

/// File operations stay on this actor. Only completed, atomically committed
/// records survive reopening; interrupted transfers are not resumed.
actor BrowserMobileDownloadDisk: BrowserMobileDownloadStoring {
    // MARK: Lifecycle

    init(
        directory: URL,
        writeManifest: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
        removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.directory = directory
        self.writeManifest = writeManifest
        self.removeItem = removeItem
    }

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
        try snapshot().entries
    }

    func snapshot() throws -> BrowserMobileDownloadDiskState {
        try ensureLoaded()
        // Every read has an actor-ordered revision, including availability and
        // cleanup changes. Main-actor publication can then reject late results.
        revision += 1
        let entries = completed.map { entry in
            var result = entry
            do { _ = try checkedFile(for: entry) }
            catch {
                result.status = .failed
                result.error = String(localized: "downloads.error.missingFile", table: "Mobile")
            }
            return result
        }
        return .init(revision: revision, entries: entries, pendingCleanupIDs: pendingCleanupIDs)
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
        let state = try completeState(entry)
        guard let saved = state.entries.first(where: { $0.id == entry.id }) else {
            throw BrowserMobileDownloadError.invalidManifest
        }
        return saved
    }

    func completeState(_ entry: BrowserMobileDownload) throws -> BrowserMobileDownloadDiskState {
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
            return try snapshot()
        }
        let next = [saved] + completed
        try commit(next)
        completed = next
        return try snapshot()
    }

    func removeState(id: UUID) throws -> BrowserMobileDownloadDiskState {
        try ensureLoaded()
        if completed.contains(where: { $0.id == id }) {
            let next = completed.filter { $0.id != id }
            // A failed commit leaves the record and its bytes untouched.
            try commit(next)
            completed = next
            pendingCleanupIDs.insert(id)
        }
        // Cleanup cannot turn a committed removal into a reported rollback.
        if pendingCleanupIDs.contains(id) {
            try? clean(id: id)
        }
        return try snapshot()
    }

    func retryCleanup() throws -> BrowserMobileDownloadDiskState {
        try ensureLoaded()
        for id in pendingCleanupIDs {
            try? clean(id: id)
        }
        return try snapshot()
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
        pendingCleanupIDs.insert(id)
        try clean(id: id)
    }

    func discardState(id: UUID) throws -> BrowserMobileDownloadDiskState {
        try ensureLoaded()
        if !completed.contains(where: { $0.id == id }) {
            pendingCleanupIDs.insert(id)
            try? clean(id: id)
        }
        return try snapshot()
    }

    // MARK: Private

    private struct Manifest: Codable {
        let version: Int
        let entries: [BrowserMobileDownload]
    }

    private static let maximumManifestBytes = 8 * 1024 * 1024

    private let directory: URL
    private let writeManifest: @Sendable (Data, URL) throws -> Void
    private let removeItem: @Sendable (URL) throws -> Void
    private var completed = [BrowserMobileDownload]()
    private var pendingCleanupIDs = Set<UUID>()
    private var isLoaded = false
    private var revision: UInt64 = 0

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
        let retained = Set(restored.map(\.id))
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if let id = UUID(uuidString: url.lastPathComponent), !retained.contains(id) {
                pendingCleanupIDs.insert(id)
            }
        }
        completed = restored
        isLoaded = true
        for id in pendingCleanupIDs {
            try? clean(id: id)
        }
    }

    private func commit(_ entries: [BrowserMobileDownload]) throws {
        let data = try JSONEncoder().encode(Manifest(version: 1, entries: entries))
        guard data.count <= Self.maximumManifestBytes else { throw BrowserMobileDownloadError.invalidManifest }
        try writeManifest(data, manifestURL)
    }

    private func clean(id: UUID) throws {
        guard !completed.contains(where: { $0.id == id }) else { return }
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        do { try removeItem(folder) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        pendingCleanupIDs.remove(id)
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
