// BrowserTestDefaults.swift

import Foundation

// MARK: - BrowserTestDefaults

/// Suite names for test preferences. A plain name puts a plist in
/// `~/Library/Preferences` that stays even after `removePersistentDomain`, so
/// thousands of runs left thousands of files there. An absolute path keeps the
/// file in the temporary directory instead.
enum BrowserTestDefaults {
    private static let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenArcTestDefaults",
            isDirectory: true,
        )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func suiteName(_ prefix: String) -> String {
        directory.appendingPathComponent("\(prefix).\(UUID().uuidString)").path
    }
}
