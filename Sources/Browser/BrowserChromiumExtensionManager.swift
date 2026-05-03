import Foundation

@MainActor
final class BrowserChromiumExtensionManager: BrowserExtensionManaging {
    func installedExtensions() -> [BrowserExtension] {
        guard
            let jsonString = BrowserCopyInstalledExtensionsJSON(),
            let jsonData = jsonString.data(using: .utf8)
        else {
            return []
        }

        do {
            return try JSONDecoder()
                .decode([BrowserChromiumExtensionPayload].self, from: jsonData)
                .map(\.browserExtension)
        } catch {
            return []
        }
    }

    func setExtension(id: String, isEnabled: Bool) -> Bool {
        BrowserSetExtensionEnabled(id, isEnabled)
    }

    func removeExtension(id: String) -> Bool {
        BrowserRemoveExtension(id)
    }
}

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
