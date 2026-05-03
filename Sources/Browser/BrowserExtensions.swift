import AppKit
import Foundation

struct BrowserExtension: Identifiable, Equatable {
    let id: String
    var name: String
    var version: String
    var isEnabled: Bool
    var iconData: Data?

    var iconImage: NSImage? {
        guard let iconData else {
            return nil
        }

        return NSImage(data: iconData)
    }
}

@MainActor
protocol BrowserExtensionManaging: AnyObject {
    func installedExtensions() -> [BrowserExtension]
    func setExtension(id: String, isEnabled: Bool) -> Bool
    func removeExtension(id: String) -> Bool
}

enum BrowserExtensionRouting {
    static let extensionsURLString = "tb://extensions/"
    static let chromeWebStoreURLString = "https://chromewebstore.google.com/"

    static func detailsURLString(forExtensionID extensionID: String) -> String {
        guard var components = URLComponents(string: extensionsURLString) else {
            return extensionsURLString
        }

        components.queryItems = [
            URLQueryItem(name: "id", value: extensionID),
        ]
        return components.url?.absoluteString ?? extensionsURLString
    }
}

struct BrowserExtensionControlCenterItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case installed(BrowserExtension)
        case add
    }

    let kind: Kind

    var id: String {
        switch kind {
        case let .installed(browserExtension):
            "extension:\(browserExtension.id)"
        case .add:
            "extension:add"
        }
    }
}

enum BrowserExtensionControlCenterModel {
    static let maximumVisibleTiles = 4

    static func gridItems(
        for extensions: [BrowserExtension],
        maximumVisibleTiles: Int = Self.maximumVisibleTiles
    ) -> [BrowserExtensionControlCenterItem] {
        guard maximumVisibleTiles > 0 else {
            return []
        }

        let extensionLimit = max(maximumVisibleTiles - 1, 0)
        let installedItems = extensions
            .prefix(extensionLimit)
            .map { BrowserExtensionControlCenterItem(kind: .installed($0)) }

        return installedItems + [BrowserExtensionControlCenterItem(kind: .add)]
    }
}
