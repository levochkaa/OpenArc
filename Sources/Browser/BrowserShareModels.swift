// BrowserShareModels.swift

import Foundation

// MARK: - BrowserShareKind

enum BrowserShareKind: String, Equatable {
    case space
    case folder
    case quote
}

// MARK: - BrowserShareItem

/// A tab or a folder of a shared Space or folder. `parent` is the index of an
/// earlier folder in the same list; items without one sit at the top level.
struct BrowserShareItem: Equatable {
    enum Kind: String, Equatable {
        case tab
        case folder
    }

    var kind: Kind
    var title: String?
    var urlString: String?
    var faviconPNG: Data?
    var icon: String?
    var parent: Int?

    static func tab(title: String?, urlString: String, faviconPNG: Data? = nil, parent: Int? = nil) -> Self {
        Self(kind: .tab, title: title, urlString: urlString, faviconPNG: faviconPNG, parent: parent)
    }

    static func folder(title: String?, icon: String? = nil, parent: Int? = nil) -> Self {
        Self(kind: .folder, title: title, icon: icon, parent: parent)
    }
}

// MARK: - BrowserShareCollection

/// A Space or folder as it is shared: its pinned tabs and folders, depth first.
struct BrowserShareCollection: Equatable {
    var sourceID: String
    var title: String
    /// An emoji, or a symbol name.
    var icon: String?
    /// The symbol drawn as a PNG, for viewers without it.
    var iconPNG: Data?
    /// `#RRGGBB`, the leading color first.
    var colors: [String]
    var items: [BrowserShareItem]

    var tabCount: Int { items.count { $0.kind == .tab } }
    var folderCount: Int { items.count { $0.kind == .folder } }
}

// MARK: - BrowserShareQuote

struct BrowserShareQuote: Equatable {
    var text: String
    var title: String?
    /// The page with a text fragment that opens it at the quote.
    var urlString: String
    var faviconPNG: Data?
}

// MARK: - BrowserShareRequest

enum BrowserShareRequest: Equatable {
    case space(BrowserShareCollection)
    case folder(BrowserShareCollection)
    case quote(BrowserShareQuote)

    // MARK: Internal

    var kind: BrowserShareKind {
        switch self {
        case .space: .space
        case .folder: .folder
        case .quote: .quote
        }
    }
}

// MARK: - BrowserSharedLink

/// One of the account's links, as the server lists it.
struct BrowserSharedLink: Equatable, Identifiable {
    let id: String
    let kind: BrowserShareKind
    let url: URL
    let sourceID: String
    let title: String
    let excerpt: String?
    let itemCount: Int
    let createdAt: Date
    let updatedAt: Date
}

// MARK: - BrowserSharedContent

/// What anyone with a Space or folder link reads, to add it.
struct BrowserSharedContent: Equatable {
    let id: String
    let kind: BrowserShareKind
    let title: String?
    let icon: String?
    let colors: [String]
    let items: [BrowserShareItem]
    let updatedAt: Date

    var tabCount: Int { items.count { $0.kind == .tab } }
    var folderCount: Int { items.count { $0.kind == .folder } }
}

// MARK: - BrowserShareError

enum BrowserShareError: Error, Equatable {
    case signedOut
    case notFound
    case tooManyRequests(String?)
    case rejected(String?)
    case server(statusCode: Int, message: String?)
}

// MARK: - BrowserShareTransport

protocol BrowserShareTransport: AnyObject, Sendable {
    func publishShare(_ request: BrowserShareRequest, authSession: BrowserAuthSession) async throws
        -> BrowserSharedLink
    func listShares(authSession: BrowserAuthSession) async throws -> [BrowserSharedLink]
    func deleteShare(id: String, authSession: BrowserAuthSession) async throws
    func readShare(id: String) async throws -> BrowserSharedContent
}

// MARK: - BrowserShareLink

/// `openarc://share/<id>`, which a shared page's Add to OpenArc button opens.
enum BrowserShareLink {
    // MARK: Internal

    static let scheme = "openarc"
    static let host = "share"

    // MARK: Private

    private static let idLength = 10
    private static let pngPrefix = "data:image/png;base64,"

    /// The identifier a share link names, nil for any other address.
    static func id(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 1, isShareID(String(parts[0])) else { return nil }
        return String(parts[0])
    }

    static func url(id: String) -> URL? {
        isShareID(id) ? URL(string: "\(scheme)://\(host)/\(id)") : nil
    }

    static func isShareID(_ id: String) -> Bool {
        id.count == idLength && id.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    static func dataURL(png: Data) -> String {
        pngPrefix + png.base64EncodedString()
    }

    static func png(dataURL: String) -> Data? {
        guard dataURL.hasPrefix(pngPrefix) else { return nil }
        return Data(base64Encoded: String(dataURL.dropFirst(pngPrefix.count)))
    }
}
