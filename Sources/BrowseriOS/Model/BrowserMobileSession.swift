// BrowserMobileSession.swift

import Foundation

// MARK: - BrowserMobileSession

struct BrowserMobileSession: Codable, Equatable {
    var version = 1
    var tabs: [BrowserMobileSessionTab]
    var selectedTabID: String?

    static func allowedURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "about", url.absoluteString.lowercased() == "about:blank" {
            return url
        }
        guard ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }

    func validate() throws {
        guard version == 1 else { throw BrowserMobileSessionError.unsupportedVersion(version) }
        let ids = tabs.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count,
              selectedTabID.map({ ids.contains($0) }) ?? true,
              tabs.allSatisfy({ BrowserMobileSession.allowedURL($0.urlString) != nil })
        else { throw BrowserMobileSessionError.invalidSession }
    }
}

// MARK: - BrowserMobileSessionTab

struct BrowserMobileSessionTab: Codable, Equatable {
    let id: String
    var urlString: String
    var title: String
}

// MARK: - BrowserMobileSessionError

enum BrowserMobileSessionError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidSession
    case restoreRequired
    case tooLarge

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "This session was saved by an unsupported version. The saved file has been kept."
        case .invalidSession:
            "The saved session could not be read. The saved file has been kept."
        case .restoreRequired:
            "Restore the saved session before saving changes."
        case .tooLarge:
            "The session is too large to save."
        }
    }
}
