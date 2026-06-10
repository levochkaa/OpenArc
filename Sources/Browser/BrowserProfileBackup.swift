import Foundation
import ZIPFoundation

// MARK: - BrowserProfileBackupManifest

struct BrowserProfileBackupManifest: Codable, Equatable {
    let profileDirectoryName: String
    let profileDisplayName: String
    let createdAt: String
    let appVersion: String
}

// MARK: - BrowserProfileBackupArchiver

final class BrowserProfileBackupArchiver {
    // MARK: Lifecycle

    init(
        rootCacheURL: URL,
        backupDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.rootCacheURL = rootCacheURL
        self.backupDirectoryURL = backupDirectoryURL ?? rootCacheURL.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        self.fileManager = fileManager
        self.now = now
    }

    // MARK: Internal

    func createBackup(for profile: BrowserProfile) throws -> URL {
        let profileURL = rootCacheURL.appendingPathComponent(profile.directoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: profileURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BrowserProfileBackupError.missingProfileDirectory(profileURL)
        }

        try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        let stagingURL = fileManager.temporaryDirectory
            .appendingPathComponent("TheBrowserProfileBackup-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: stagingURL)
        }

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try copyLocalStateIfPresent(to: stagingURL)
        try fileManager.copyItem(
            at: profileURL,
            to: stagingURL.appendingPathComponent(profile.directoryName, isDirectory: true)
        )
        try writeManifest(for: profile, to: stagingURL)

        let destinationURL = try uniqueBackupURL(for: profile)
        try fileManager.zipItem(
            at: stagingURL,
            to: destinationURL,
            shouldKeepParent: false,
            compressionMethod: .deflate
        )
        return destinationURL
    }

    // MARK: Private

    private let rootCacheURL: URL
    private let backupDirectoryURL: URL
    private let fileManager: FileManager
    private let now: () -> Date

    private var localStateURL: URL {
        rootCacheURL.appendingPathComponent("Local State", isDirectory: false)
    }

    private static func filenameTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func sanitizedFilenameComponent(_ value: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitizedScalars = value.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(sanitizedScalars).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return sanitized.isEmpty ? "Profile" : sanitized
    }

    private func copyLocalStateIfPresent(to stagingURL: URL) throws {
        guard fileManager.fileExists(atPath: localStateURL.path) else {
            return
        }

        try fileManager.copyItem(
            at: localStateURL,
            to: stagingURL.appendingPathComponent(localStateURL.lastPathComponent, isDirectory: false)
        )
    }

    private func writeManifest(for profile: BrowserProfile, to stagingURL: URL) throws {
        let manifest = BrowserProfileBackupManifest(
            profileDirectoryName: profile.directoryName,
            profileDisplayName: profile.displayName,
            createdAt: ISO8601DateFormatter().string(from: now()),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: stagingURL.appendingPathComponent("manifest.json", isDirectory: false), options: .atomic)
    }

    private func uniqueBackupURL(for profile: BrowserProfile) throws -> URL {
        let timestamp = Self.filenameTimestamp(from: now())
        let baseName = "\(Self.sanitizedFilenameComponent(profile.directoryName))-\(timestamp)"

        for suffix in [""] + (2...999).map({ "-\($0)" }) {
            let candidateURL = backupDirectoryURL.appendingPathComponent("\(baseName)\(suffix).zip", isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        throw BrowserProfileBackupError.unableToCreateUniqueDestination(backupDirectoryURL)
    }
}

// MARK: - BrowserProfileBackupError

enum BrowserProfileBackupError: LocalizedError {
    case missingProfileDirectory(URL)
    case unableToCreateUniqueDestination(URL)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .missingProfileDirectory(let url):
            "Profile directory does not exist: \(url.path)"
        case .unableToCreateUniqueDestination(let url):
            "Unable to create a unique backup name in \(url.path)"
        }
    }
}

extension BrowserProfileStore {
    func createBackup(for profile: BrowserProfile) throws -> URL {
        try BrowserProfileBackupArchiver(rootCacheURL: rootCacheURL).createBackup(for: profile)
    }
}
