import Foundation

struct BrowserNativeMessagingHostInstaller {
    // MARK: Lifecycle

    init(
        fileManager: FileManager = .default,
        manifestCandidates: [URL] = Self.applePasswordManagerManifestCandidates
    ) {
        self.fileManager = fileManager
        self.manifestCandidates = manifestCandidates
    }

    // MARK: Internal

    static let applePasswordManagerHostName = "com.apple.passwordmanager"
    static let nativeMessagingHostsDirectoryName = "NativeMessagingHosts"

    let fileManager: FileManager
    let manifestCandidates: [URL]

    static func installApplePasswordManagerHostIfAvailable(
        in rootCacheURL: URL,
        fileManager: FileManager = .default
    ) {
        do {
            try BrowserNativeMessagingHostInstaller(fileManager: fileManager)
                .installApplePasswordManagerHostIfAvailable(in: rootCacheURL)
        } catch {
            NSLog("Unable to install iCloud Passwords native messaging host: \(error.localizedDescription)")
        }
    }

    func installApplePasswordManagerHostIfAvailable(in rootCacheURL: URL) throws {
        guard let sourceManifestURL = manifestCandidates.first(where: { fileManager.fileExists(atPath: $0.path) })
        else {
            return
        }

        let hostsDirectoryURL = rootCacheURL.appendingPathComponent(
            Self.nativeMessagingHostsDirectoryName,
            isDirectory: true
        )
        let destinationManifestURL = hostsDirectoryURL.appendingPathComponent(
            Self.applePasswordManagerManifestFileName,
            isDirectory: false
        )

        try fileManager.createDirectory(at: hostsDirectoryURL, withIntermediateDirectories: true)

        guard destinationNeedsUpdate(destinationManifestURL, sourceManifestURL: sourceManifestURL) else {
            return
        }

        if destinationExistsOrIsSymbolicLink(destinationManifestURL) {
            try fileManager.removeItem(at: destinationManifestURL)
        }

        do {
            try fileManager.createSymbolicLink(at: destinationManifestURL, withDestinationURL: sourceManifestURL)
        } catch {
            try fileManager.copyItem(at: sourceManifestURL, to: destinationManifestURL)
        }
    }

    // MARK: Private

    private static let applePasswordManagerManifestFileName = "\(applePasswordManagerHostName).json"
    private static let applePasswordManagerManifestCandidates = [
        URL(
            fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts/\(applePasswordManagerManifestFileName)",
            isDirectory: false
        ),
        URL(
            fileURLWithPath:
            "/System/Library/Templates/Data/Library/Google/Chrome/NativeMessagingHosts/\(applePasswordManagerManifestFileName)",
            isDirectory: false
        ),
    ]

    private func destinationNeedsUpdate(_ destinationURL: URL, sourceManifestURL: URL) -> Bool {
        if let symbolicLinkDestination = try? fileManager.destinationOfSymbolicLink(atPath: destinationURL.path) {
            let resolvedDestinationURL = URL(
                fileURLWithPath: symbolicLinkDestination,
                relativeTo: destinationURL.deletingLastPathComponent()
            )
            .standardizedFileURL
            return resolvedDestinationURL.path != sourceManifestURL.standardizedFileURL.path
        }

        guard fileManager.fileExists(atPath: destinationURL.path) else {
            return true
        }

        guard
            let destinationData = try? Data(contentsOf: destinationURL),
            let sourceData = try? Data(contentsOf: sourceManifestURL)
        else {
            return true
        }

        return destinationData != sourceData
    }

    private func destinationExistsOrIsSymbolicLink(_ destinationURL: URL) -> Bool {
        fileManager.fileExists(atPath: destinationURL.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: destinationURL.path)) != nil
    }
}
