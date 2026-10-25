import Foundation

// MARK: - BrowserDownloadLocation

/// Where the engine saves downloads: the folder chosen in Settings while it
/// exists, otherwise the user's Downloads folder. The location is not kept
/// per profile; OpenArc keeps one for the app.
@objc final class BrowserDownloadLocation: NSObject {
    /// Called by the engine on its own thread; `UserDefaults` is thread-safe.
    @objc static func directoryPath() -> String {
        directory(customPath: UserDefaults.standard.string(forKey: BrowserUserPreferencesStore.downloadDirectoryKey))
            .path
    }

    static func directory(customPath: String?, fileManager: FileManager = .default) -> URL {
        var isDirectory: ObjCBool = false
        if let customPath, !customPath.isEmpty,
           fileManager.fileExists(atPath: customPath, isDirectory: &isDirectory), isDirectory.boolValue
        {
            return URL(fileURLWithPath: customPath, isDirectory: true)
        }
        return defaultDirectory(fileManager: fileManager)
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
    }
}
