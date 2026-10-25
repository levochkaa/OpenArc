// BrowserMobileFileSessionStore.swift

import Foundation

// MARK: - BrowserMobileSessionStoring

protocol BrowserMobileSessionStoring: Sendable {
    func load() async throws -> BrowserMobileSession?
    func save(_ session: BrowserMobileSession) async throws
}

// MARK: - BrowserMobileFileSessionStore

/// Each scene supplies its own URL. A failed load never grants permission to
/// replace that file; the caller must retry restoration before it can save.
actor BrowserMobileFileSessionStore: BrowserMobileSessionStoring {
    // MARK: Private

    private static let maximumBytes = 8 * 1024 * 1024

    private let fileURL: URL
    private var canSave = false

    init(fileURL: URL) { self.fileURL = fileURL }

    // MARK: Internal

    func load() throws -> BrowserMobileSession? {
        canSave = false
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            canSave = true
            return nil
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > Self.maximumBytes {
            throw BrowserMobileSessionError.tooLarge
        }
        let data = try Data(contentsOf: fileURL)
        let session: BrowserMobileSession
        do {
            session = try JSONDecoder().decode(BrowserMobileSession.self, from: data)
        } catch {
            throw BrowserMobileSessionError.invalidSession
        }
        try session.validate()
        canSave = true
        return session
    }

    func save(_ session: BrowserMobileSession) throws {
        guard canSave else { throw BrowserMobileSessionError.restoreRequired }
        try session.validate()
        let data = try JSONEncoder().encode(session)
        guard data.count <= Self.maximumBytes else { throw BrowserMobileSessionError.tooLarge }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
