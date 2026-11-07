// BrowserNativeMessagingHostInstaller.swift

import Foundation

/// The iCloud Passwords extension cannot run in OpenArc: macOS kills Apple's
/// `PasswordManagerBrowserExtensionHelper` (SIGKILL, Code Signature Invalid)
/// unless a browser on Apple's list starts it, and passwords go through
/// OpenArc's own Keychain store instead. Earlier builds linked Apple's host
/// manifest into each profile, which only made the extension start a helper
/// that died at once. This removes that manifest and nothing else.
struct BrowserNativeMessagingHostInstaller {
    // MARK: Internal

    static let applePasswordManagerHostName = "com.apple.passwordmanager"
    static let nativeMessagingHostsDirectoryName = "NativeMessagingHosts"

    // MARK: Private

    private static let applePasswordManagerManifestFileName = "\(applePasswordManagerHostName).json"
    private static let applePasswordManagerManifestCandidates = [
        URL(
            fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts/\(applePasswordManagerManifestFileName)",
            isDirectory: false,
        ),
        URL(
            fileURLWithPath:
            "/System/Library/Templates/Data/Library/Google/Chrome/NativeMessagingHosts/\(applePasswordManagerManifestFileName)",
            isDirectory: false,
        ),
    ]

    let fileManager: FileManager
    let manifestCandidates: [URL]

    init(
        fileManager: FileManager = .default,
        manifestCandidates: [URL] = Self.applePasswordManagerManifestCandidates,
    ) {
        self.fileManager = fileManager
        self.manifestCandidates = manifestCandidates
    }

    static func removeApplePasswordManagerHost(in rootCacheURL: URL, fileManager: FileManager = .default) {
        do {
            try BrowserNativeMessagingHostInstaller(fileManager: fileManager)
                .removeApplePasswordManagerHost(in: rootCacheURL)
        } catch {
            NSLog("Unable to remove the iCloud Passwords native messaging host: \(error.localizedDescription)")
        }
    }

    /// Removes the manifest earlier builds put there: a link to one of Apple's
    /// manifests, or a copy of one.
    func removeApplePasswordManagerHost(in rootCacheURL: URL) throws {
        let manifestURL = rootCacheURL
            .appendingPathComponent(Self.nativeMessagingHostsDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.applePasswordManagerManifestFileName, isDirectory: false)
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: manifestURL.path) {
            let resolved = URL(fileURLWithPath: destination, relativeTo: manifestURL.deletingLastPathComponent())
                .standardizedFileURL
                .path
            if manifestCandidates.contains(where: { $0.standardizedFileURL.path == resolved }) {
                try fileManager.removeItem(at: manifestURL)
            }
            return
        }
        guard let data = try? Data(contentsOf: manifestURL),
              manifestCandidates.contains(where: { (try? Data(contentsOf: $0)) == data })
        else { return }
        try fileManager.removeItem(at: manifestURL)
    }
}
