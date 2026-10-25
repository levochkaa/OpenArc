// BrowserSyncOwner.swift

import Foundation

// MARK: - BrowserSyncOwner

/// The durable account that owns a profile's synchronized data. Credentials and
/// device registrations can change without changing this identity.
struct BrowserSyncOwner: Codable, Equatable {
    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case baseURL
        case userID
    }

    // MARK: Internal

    let baseURL: URL
    let userID: String

    init(baseURL: URL, userID: String) {
        self.baseURL = Self.normalized(baseURL)
        self.userID = userID
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            baseURL: values.decode(URL.self, forKey: .baseURL),
            userID: values.decode(String.self, forKey: .userID),
        )
    }

    private static func normalized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true) else {
            return url.absoluteURL
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        components.fragment = nil
        return components.url ?? url.absoluteURL
    }
}

// MARK: - BrowserSyncStoreError

enum BrowserSyncStoreError: Error, Equatable {
    case ownerNotBound
    case ownerMismatch
    case invalidCursor
    case invalidStoredOwner
    case authenticationRequired
    case invalidAuthenticationState
}
