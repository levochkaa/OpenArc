// BrowserExtensions.swift

import AppKit
import Foundation

// MARK: - BrowserExtension

struct BrowserExtension: Identifiable, Equatable {
    let id: String
    var name: String
    var version: String
    var isEnabled: Bool
    var iconData: Data?
    var sidePanelURLString: String?

    var iconImage: NSImage? {
        guard let iconData else {
            return nil
        }

        return BrowserImageThumbnailer.image(
            data: iconData,
            maximumPixelSize: BrowserImageThumbnailer.chromeIconMaximumPixelSize,
        )
    }
}

// MARK: - BrowserExtensionManaging

@MainActor protocol BrowserExtensionManaging: AnyObject {
    func enableDefaultExtensionsOnce()
    func installedExtensions() -> [BrowserExtension]
    func runAction(id: String) -> BrowserExtensionActionResult
    func setExtension(id: String, isEnabled: Bool) -> Bool
    func removeExtension(id: String) -> Bool
}

extension BrowserExtensionManaging {
    func enableDefaultExtensionsOnce() {}
}

// MARK: - BrowserExtensionActionResult

enum BrowserExtensionActionResult: Equatable {
    case popup(urlString: String)
    case sidePanel
    case handled
    case failed
}

// MARK: - BrowserEmptyExtensionManager

@MainActor final class BrowserEmptyExtensionManager: BrowserExtensionManaging {
    func installedExtensions() -> [BrowserExtension] {
        []
    }

    func runAction(id _: String) -> BrowserExtensionActionResult {
        .failed
    }

    func setExtension(id _: String, isEnabled _: Bool) -> Bool {
        false
    }

    func removeExtension(id _: String) -> Bool {
        false
    }
}

// MARK: - BrowserExtensionProfileSnapshotStore

enum BrowserExtensionProfileSnapshotStore {
    // MARK: Internal

    static func installedExtensions(profileDirectories: [URL]) -> [BrowserExtension] {
        for profileDirectory in uniqueExistingDirectories(profileDirectories) {
            let extensions = installedExtensions(profileDirectory: profileDirectory)
            if !extensions.isEmpty {
                return extensions
            }
        }

        return []
    }

    // MARK: Private

    private static func installedExtensions(profileDirectory: URL) -> [BrowserExtension] {
        guard
            let preferencesData = preferencesData(in: profileDirectory),
            let snapshot = try? JSONDecoder().decode(BrowserExtensionPreferencesSnapshot.self, from: preferencesData),
            let settings = snapshot.extensions?.settings
        else {
            return []
        }

        return settings.compactMap { id, entry -> BrowserExtension? in
            guard
                entry.isUserVisible,
                let manifest = entry.manifest,
                let name = extensionName(
                    from: manifest,
                    extensionDirectory: extensionDirectory(for: id, entry: entry, profileDirectory: profileDirectory),
                )
            else {
                return nil
            }

            let extensionDirectory = extensionDirectory(for: id, entry: entry, profileDirectory: profileDirectory)
            return BrowserExtension(
                id: id,
                name: name,
                version: manifest.version ?? entry.version ?? "",
                isEnabled: entry.isEnabled,
                iconData: iconData(from: manifest, extensionDirectory: extensionDirectory),
                sidePanelURLString: sidePanelURLString(
                    from: manifest,
                    extensionID: id,
                    extensionDirectory: extensionDirectory,
                ),
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func uniqueExistingDirectories(_ urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var seenPaths = Set<String>()
        var directories = [URL]()

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard !seenPaths.contains(standardizedURL.path) else {
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                continue
            }

            seenPaths.insert(standardizedURL.path)
            directories.append(standardizedURL)
        }

        return directories
    }

    private static func preferencesData(in profileDirectory: URL) -> Data? {
        let fileManager = FileManager.default
        let candidateURLs = [
            profileDirectory.appendingPathComponent("Secure Preferences", isDirectory: false),
            profileDirectory.appendingPathComponent("Preferences", isDirectory: false),
        ]

        for url in candidateURLs where fileManager.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }

        return nil
    }

    private static func extensionDirectory(
        for id: String,
        entry: BrowserExtensionPreferencesEntry,
        profileDirectory: URL,
    ) -> URL {
        let fileManager = FileManager.default

        if let path = entry.path, !path.isEmpty {
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }

            let extensionsRelativeURL = profileDirectory
                .appendingPathComponent("Extensions", isDirectory: true)
                .appendingPathComponent(path, isDirectory: true)
            if fileManager.fileExists(atPath: extensionsRelativeURL.path) {
                return extensionsRelativeURL
            }

            let profileRelativeURL = profileDirectory.appendingPathComponent(path, isDirectory: true)
            if fileManager.fileExists(atPath: profileRelativeURL.path) {
                return profileRelativeURL
            }
        }

        let extensionRootURL = profileDirectory
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        guard
            let versionURLs = try? fileManager.contentsOfDirectory(
                at: extensionRootURL,
                includingPropertiesForKeys: nil,
            ),
            let latestVersionURL = versionURLs
                .filter(\.hasDirectoryPath)
                .min(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
                })
        else {
            return extensionRootURL
        }

        return latestVersionURL
    }

    private static func extensionName(
        from manifest: BrowserExtensionManifest,
        extensionDirectory: URL,
    ) -> String? {
        let rawName = manifest.name ?? manifest.shortName
        guard let rawName, !rawName.isEmpty else {
            return nil
        }

        return localizedManifestValue(rawName, manifest: manifest, extensionDirectory: extensionDirectory)
    }

    private static func localizedManifestValue(
        _ value: String,
        manifest: BrowserExtensionManifest,
        extensionDirectory: URL,
    ) -> String {
        guard
            value.hasPrefix("__MSG_"),
            value.hasSuffix("__")
        else {
            return value
        }

        let keyStart = value.index(value.startIndex, offsetBy: "__MSG_".count)
        let keyEnd = value.index(value.endIndex, offsetBy: -2)
        let messageKey = String(value[keyStart..<keyEnd])
        let localeCandidates = [
            manifest.currentLocale,
            manifest.defaultLocale,
            manifest.currentLocale?.split(separator: "_").first.map(String.init),
            manifest.defaultLocale?.split(separator: "_").first.map(String.init),
        ]
            .compactMap(\.self)

        for locale in localeCandidates {
            let messagesURL = extensionDirectory
                .appendingPathComponent("_locales", isDirectory: true)
                .appendingPathComponent(locale, isDirectory: true)
                .appendingPathComponent("messages.json", isDirectory: false)
            guard
                let data = try? Data(contentsOf: messagesURL),
                let messages = try? JSONDecoder().decode([String: BrowserExtensionLocaleMessage].self, from: data),
                let message = messages[messageKey]?.message,
                !message.isEmpty
            else {
                continue
            }

            return message
        }

        return value
    }

    private static func iconData(
        from manifest: BrowserExtensionManifest,
        extensionDirectory: URL,
    ) -> Data? {
        let iconSet = manifest.icons
            ?? manifest.action?.defaultIcon
            ?? manifest.browserAction?.defaultIcon
            ?? manifest.pageAction?.defaultIcon
        guard let iconPath = iconSet?.preferredPath else {
            return nil
        }

        let iconURL = extensionDirectory.appendingPathComponent(iconPath, isDirectory: false)
        return try? Data(contentsOf: iconURL)
    }

    private static func sidePanelURLString(
        from manifest: BrowserExtensionManifest,
        extensionID: String,
        extensionDirectory: URL,
    ) -> String? {
        if let defaultPath = manifest.sidePanel?.defaultPath {
            return BrowserExtensionRouting.extensionResourceURLString(
                forExtensionID: extensionID,
                path: defaultPath,
            )
        }

        guard manifest.hasSidePanelPermission else {
            return nil
        }

        let candidatePaths = [
            "sidepanel.html",
            "side_panel.html",
            "sidebar.html",
            "panel.html",
        ]
        let fileManager = FileManager.default
        guard let sidePanelPath = candidatePaths.first(where: { path in
            fileManager.fileExists(atPath: extensionDirectory.appendingPathComponent(path).path)
        }) else {
            return nil
        }

        return BrowserExtensionRouting.extensionResourceURLString(
            forExtensionID: extensionID,
            path: sidePanelPath,
        )
    }
}

// MARK: - BrowserExtensionRouting

enum BrowserExtensionRouting {
    static let extensionsURLString = "openarc://extensions/"
    static let chromeWebStoreURLString = "https://chromewebstore.google.com/"
    static let chromeWebStoreDetailBaseURLString = "https://chromewebstore.google.com/detail/"

    static func extensionResourceURLString(forExtensionID extensionID: String, path: String) -> String? {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !extensionID.isEmpty, !trimmedPath.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "chrome-extension"
        components.host = extensionID
        components.path = "/" + trimmedPath
        return components.url?.absoluteString
    }

    static func detailsURLString(forExtensionID extensionID: String) -> String {
        guard var components = URLComponents(string: extensionsURLString) else {
            return extensionsURLString
        }

        components.queryItems = [
            URLQueryItem(name: "id", value: extensionID),
        ]
        return components.url?.absoluteString ?? extensionsURLString
    }

    static func chromeWebStoreURLString(forExtensionID extensionID: String) -> String {
        guard !extensionID.isEmpty else {
            return chromeWebStoreURLString
        }

        return chromeWebStoreDetailBaseURLString + extensionID
    }
}

// MARK: - BrowserExtensionControlCenterItem

struct BrowserExtensionControlCenterItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case installed(BrowserExtension)
        case add
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .installed(let browserExtension):
            "extension:\(browserExtension.id)"
        case .add:
            "extension:add"
        }
    }
}

// MARK: - BrowserExtensionControlCenterModel

enum BrowserExtensionControlCenterModel {
    /// Two rows of four; Manage lists the rest.
    static let maximumVisibleTiles = 8

    static func gridItems(
        for extensions: [BrowserExtension],
        maximumVisibleTiles: Int = Self.maximumVisibleTiles,
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

// MARK: - BrowserExtensionPreferencesSnapshot

private struct BrowserExtensionPreferencesSnapshot: Decodable {
    let extensions: BrowserExtensionPreferencesContainer?
}

// MARK: - BrowserExtensionPreferencesContainer

private struct BrowserExtensionPreferencesContainer: Decodable {
    let settings: [String: BrowserExtensionPreferencesEntry]?
}

// MARK: - BrowserExtensionPreferencesEntry

private struct BrowserExtensionPreferencesEntry: Decodable {
    enum CodingKeys: String, CodingKey {
        case disableReasons = "disable_reasons"
        case location
        case manifest
        case path
        case state
        case version
        case wasInstalledByDefault = "was_installed_by_default"
        case wasInstalledByOem = "was_installed_by_oem"
    }

    let disableReasons: BrowserExtensionDisableReasons?
    let location: Int?
    let manifest: BrowserExtensionManifest?
    let path: String?
    let state: Int?
    let version: String?
    let wasInstalledByDefault: Bool?
    let wasInstalledByOem: Bool?

    var isEnabled: Bool {
        if let state, state == 0 {
            return false
        }

        return disableReasons?.isEmpty ?? true
    }

    var isUserVisible: Bool {
        guard manifest != nil else {
            return false
        }

        if wasInstalledByDefault == true || wasInstalledByOem == true {
            return false
        }

        // Chrome component extensions such as the Web Store app and PDF viewer
        // live in the same preferences map but should not be shown as installed
        // user extensions in OpenArc chrome.
        if location == 5 {
            return false
        }

        return true
    }
}

// MARK: - BrowserExtensionManifest

private struct BrowserExtensionManifest: Decodable {
    enum CodingKeys: String, CodingKey {
        case action
        case browserAction = "browser_action"
        case currentLocale = "current_locale"
        case defaultLocale = "default_locale"
        case icons
        case name
        case optionalPermissions = "optional_permissions"
        case pageAction = "page_action"
        case permissions
        case sidePanel = "side_panel"
        case shortName = "short_name"
        case version
    }

    let action: BrowserExtensionAction?
    let browserAction: BrowserExtensionAction?
    let currentLocale: String?
    let defaultLocale: String?
    let icons: BrowserExtensionIconSet?
    let name: String?
    let optionalPermissions: [BrowserExtensionManifestPermission]?
    let pageAction: BrowserExtensionAction?
    let permissions: [BrowserExtensionManifestPermission]?
    let sidePanel: BrowserExtensionSidePanelManifest?
    let shortName: String?
    let version: String?

    var hasSidePanelPermission: Bool {
        let permissionValues = (permissions ?? []) + (optionalPermissions ?? [])
        return permissionValues.contains { $0.value == "sidePanel" }
    }
}

// MARK: - BrowserExtensionManifestPermission

private struct BrowserExtensionManifestPermission: Decodable {
    // MARK: Internal

    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try? container.decode(String.self)
    }
}

// MARK: - BrowserExtensionSidePanelManifest

private struct BrowserExtensionSidePanelManifest: Decodable {
    enum CodingKeys: String, CodingKey {
        case defaultPath = "default_path"
    }

    let defaultPath: String?
}

// MARK: - BrowserExtensionAction

private struct BrowserExtensionAction: Decodable {
    enum CodingKeys: String, CodingKey {
        case defaultIcon = "default_icon"
    }

    let defaultIcon: BrowserExtensionIconSet?
}

// MARK: - BrowserExtensionIconSet

private struct BrowserExtensionIconSet: Decodable {
    // MARK: Internal

    let pathsBySize: [Int: String]

    var preferredPath: String? {
        let sortedIcons = pathsBySize.sorted { lhs, rhs in
            if lhs.key == rhs.key {
                return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending
            }

            return lhs.key > rhs.key
        }

        return sortedIcons.first { $0.key <= 128 }?.value ?? sortedIcons.last?.value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let path = try? container.decode(String.self) {
            self.pathsBySize = [0: path]
            return
        }

        let rawPathsBySize = try container.decode([String: String].self)
        self.pathsBySize = rawPathsBySize.reduce(into: [:]) { result, item in
            result[Int(item.key) ?? 0] = item.value
        }
    }
}

// MARK: - BrowserExtensionDisableReasons

private struct BrowserExtensionDisableReasons: Decodable {
    // MARK: Internal

    let isEmpty: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let reasons = try? container.decode([String].self) {
            self.isEmpty = reasons.isEmpty
            return
        }

        if let reasons = try? container.decode([Int].self) {
            self.isEmpty = reasons.isEmpty
            return
        }

        if let reasons = try? container.decode([String: Bool].self) {
            self.isEmpty = reasons.isEmpty
            return
        }

        if let reasonMask = try? container.decode(Int.self) {
            self.isEmpty = reasonMask == 0
            return
        }

        self.isEmpty = true
    }
}

// MARK: - BrowserExtensionLocaleMessage

private struct BrowserExtensionLocaleMessage: Decodable {
    let message: String
}
