// BrowserWebExtensionStore.swift

import Foundation

// MARK: - BrowserWebExtensionSource

/// Where an extension came from, which decides how it installs and updates.
enum BrowserWebExtensionSource: String, Codable {
    case chromeWebStore
    case firefoxAddons
    /// Installed by Chromium in the Mac profile; WebKit pages load it read-only.
    case chromiumProfile
}

// MARK: - BrowserWebExtensionStoreItem

/// An extension's page in a store: the Chrome Web Store's ID, or an AMO slug,
/// numeric ID or GUID.
struct BrowserWebExtensionStoreItem: Equatable {
    /// The Chromium version WebKit pages name to Google's update service,
    /// which serves only packages that run on it.
    static let chromiumVersion = "158.0.8127.18"

    let source: BrowserWebExtensionSource
    let identifier: String

    /// The package's address: Google's update service for the Chrome Web
    /// Store, the add-on's API record for AMO.
    var metadataURL: URL? {
        switch source {
        case .chromeWebStore:
            Self.chromeDownloadURL(id: identifier)
        case .firefoxAddons:
            Self.amoAddonURL(identifier)
        case .chromiumProfile:
            nil
        }
    }

    /// The item a store page shows; nil for other pages.
    init?(pageURL url: URL) {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "chromewebstore.google.com":
            guard components.first == "detail",
                  let id = components.dropFirst().last(where: Self.isChromeID) else { return nil }
            self.init(source: .chromeWebStore, identifier: id)
        case "chrome.google.com":
            guard components.starts(with: ["webstore", "detail"]),
                  let id = components.dropFirst(2).last(where: Self.isChromeID) else { return nil }
            self.init(source: .chromeWebStore, identifier: id)
        case "addons.mozilla.org":
            guard let addon = components.firstIndex(of: "addon"), addon > 0,
                  ["firefox", "android"].contains(components[addon - 1]),
                  addon + 1 < components.count else { return nil }
            let slug = components[addon + 1]
            guard Self.isAddonSlug(slug) else { return nil }
            self.init(source: .firefoxAddons, identifier: slug)
        default:
            return nil
        }
    }

    init(source: BrowserWebExtensionSource, identifier: String) {
        self.source = source
        self.identifier = identifier
    }

    static func isChromeID(_ string: String) -> Bool {
        string.count == 32 && string.utf8.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "p")).contains($0) }
    }

    /// AMO slugs are letters, digits, `-` and `_`; numeric IDs and GUIDs
    /// (`name@domain` or `{uuid}`) name the same add-ons.
    static func isAddonSlug(_ string: String) -> Bool {
        guard !string.isEmpty, string.count <= 256 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@{}+"))
        return string.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func chromeDownloadURL(id: String) -> URL? {
        guard isChromeID(id) else { return nil }
        return URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion="
            + chromiumVersion + "&acceptformat=crx2,crx3&x=id%3D" + id + "%26uc")
    }

    /// One request asks about every installed Chrome Web Store extension.
    static func chromeUpdateCheckURL(versions: [(id: String, version: String)]) -> URL? {
        var query = "response=updatecheck&prodversion=\(chromiumVersion)&acceptformat=crx3"
        // Each `x` carries its own query, whose `=` and `&` stay encoded.
        let versionCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "."))
        for entry in versions where isChromeID(entry.id) {
            guard let version = entry.version.addingPercentEncoding(withAllowedCharacters: versionCharacters)
            else { continue }
            query += "&x=id%3D\(entry.id)%26v%3D\(version)%26uc"
        }
        return URL(string: "https://clients2.google.com/service/update2/crx?" + query)
    }

    static func amoAddonURL(_ identifier: String) -> URL? {
        guard isAddonSlug(identifier),
              let path = identifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(
                  CharacterSet(charactersIn: "-_."),
              )) else { return nil }
        return URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(path)/")
    }

    /// Whether a download may come from this address: HTTPS on Google's or
    /// Mozilla's hosts.
    static func isTrustedDownload(_ url: URL?, source: BrowserWebExtensionSource) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        let suffixes =
            switch source {
            case .chromeWebStore: ["google.com", "googleusercontent.com", "gvt1.com"]
            case .firefoxAddons: ["mozilla.org", "mozilla.net"]
            case .chromiumProfile: [String]()
            }
        return suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

// MARK: - BrowserAMOAddon

/// The parts of an AMO add-on record an install needs.
struct BrowserAMOAddon: Decodable, Equatable {
    struct Version: Decodable, Equatable {
        let version: String
        let file: File
    }

    struct File: Decodable, Equatable {
        let url: URL
        let hash: String
        let size: Int?
    }

    enum CodingKeys: String, CodingKey {
        case guid
        case slug
        case currentVersion = "current_version"
    }

    let guid: String
    let slug: String
    let currentVersion: Version

    static func decode(_ data: Data) throws -> BrowserAMOAddon {
        try JSONDecoder().decode(BrowserAMOAddon.self, from: data)
    }
}

// MARK: - BrowserChromeUpdateResponse

/// Google's update service answer: per extension, a newer version and its
/// package address, or nothing.
enum BrowserChromeUpdateResponse {
    struct Update: Equatable {
        let id: String
        let version: String
        let codebase: URL
        let sha256: String?
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var updates = [Update]()

        private var appID: String?

        func parser(
            _: XMLParser, didStartElement element: String, namespaceURI _: String?, qualifiedName _: String?,
            attributes: [String: String] = [:],
        ) {
            switch element {
            case "app":
                appID = attributes["appid"]
            case "updatecheck":
                guard let appID, attributes["status"] == "ok", let version = attributes["version"],
                      let codebase = attributes["codebase"].flatMap(URL.init(string:)) else { return }
                updates.append(Update(
                    id: appID,
                    version: version,
                    codebase: codebase,
                    sha256: attributes["hash_sha256"],
                ))
            default:
                break
            }
        }

        func parser(_: XMLParser, didEndElement element: String, namespaceURI _: String?, qualifiedName _: String?) {
            if element == "app" { appID = nil }
        }
    }

    static func updates(from data: Data) -> [Update] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.updates
    }
}

// MARK: - BrowserWebExtensionVersion

enum BrowserWebExtensionVersion {
    /// Dotted versions compare part by part, numbers as numbers: `4.9.135`
    /// is newer than `4.9.99`.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        candidate.compare(installed, options: .numeric) == .orderedDescending
    }
}

// MARK: - BrowserWebExtensionUpdateSchedule

/// Updates are checked on launch, about once a day.
struct BrowserWebExtensionUpdateSchedule: Equatable {
    static let standard = BrowserWebExtensionUpdateSchedule(interval: 23 * 60 * 60)

    /// A little under a day, so a check on each morning's launch still runs.
    let interval: TimeInterval

    /// Due when never checked, a day has passed, or the clock went back.
    func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }

    /// When the next check is due.
    func nextCheck(after lastCheck: Date?, now: Date) -> Date {
        isDue(lastCheck: lastCheck, now: now) ? now : lastCheck!.addingTimeInterval(interval)
    }
}
