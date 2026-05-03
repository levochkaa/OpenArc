import Foundation

// MARK: - BrowserChromiumExtensionManager

@MainActor final class BrowserChromiumExtensionManager: BrowserExtensionManaging {
    // MARK: Internal

    func installedExtensions() -> [BrowserExtension] {
        if let extensions = installedExtensionsFromBridge(), !extensions.isEmpty {
            return extensions
        }

        guard let configuration = BrowserRuntimeConfiguration.currentConfiguration() else {
            return []
        }

        return BrowserExtensionProfileSnapshotStore.installedExtensions(
            profileDirectories: extensionProfileDirectories(configuration: configuration)
        )
    }

    func setExtension(id: String, isEnabled: Bool) -> Bool {
        BrowserSetExtensionEnabled(id, isEnabled)
    }

    func removeExtension(id: String) -> Bool {
        BrowserRemoveExtension(id)
    }

    // MARK: Private

    private func installedExtensionsFromBridge() -> [BrowserExtension]? {
        guard
            let jsonString = BrowserCopyInstalledExtensionsJSON(),
            let jsonData = jsonString.data(using: .utf8)
        else {
            return nil
        }

        return try? JSONDecoder()
            .decode([BrowserChromiumExtensionPayload].self, from: jsonData)
            .map(\.browserExtension)
    }

    private func extensionProfileDirectories(configuration: BrowserRuntimeConfiguration) -> [URL] {
        let cacheURL = URL(fileURLWithPath: configuration.cachePath, isDirectory: true)
        let rootCacheURL = URL(fileURLWithPath: configuration.rootCachePath, isDirectory: true)

        return [
            cacheURL,
            cacheURL.appendingPathComponent("Default", isDirectory: true),
            rootCacheURL.appendingPathComponent("Default", isDirectory: true),
            rootCacheURL.appendingPathComponent("Profile", isDirectory: true),
        ]
    }
}

// MARK: - BrowserChromiumExtensionPayload

private struct BrowserChromiumExtensionPayload: Decodable {
    let id: String
    let name: String
    let version: String
    let isEnabled: Bool
    let iconBase64: String?

    var browserExtension: BrowserExtension {
        BrowserExtension(
            id: id,
            name: name,
            version: version,
            isEnabled: isEnabled,
            iconData: iconBase64.flatMap { Data(base64Encoded: $0) }
        )
    }
}
