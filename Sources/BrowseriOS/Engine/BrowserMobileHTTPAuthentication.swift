import Foundation

// MARK: - BrowserMobileHTTPAuthentication

/// A transient request for credentials. The origin is the challenged protection
/// space, which may differ from the top-level page; no credentials are persisted.
struct BrowserMobileHTTPAuthentication: Equatable, Sendable {
    let id: UUID
    let runtimeID: String
    let origin: String
    let realm: String?
    let previousFailureCount: Int
}

// MARK: - BrowserMobileHTTPAuthenticationResponse

/// Deliberately neither Codable nor Equatable: credentials are passed directly
/// to WebKit and must not become stored state or diagnostic equality output.
enum BrowserMobileHTTPAuthenticationResponse: Sendable {
    case credentials(username: String, password: String)
    case cancel
}
