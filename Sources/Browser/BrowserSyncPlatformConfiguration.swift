import Foundation

// MARK: - BrowserSyncDeviceIdentity

/// Supplied by the platform composition root, never inferred by the transport.
struct BrowserSyncDeviceIdentity: Equatable, Sendable {
    let name: String
    let platform: String
}

// MARK: - BrowserAuthSessionNamespace

/// Default desktop credentials retain their historical Keychain account name.
/// Other profiles opt into an explicit namespace on either platform.
enum BrowserAuthSessionNamespace: Equatable, Sendable {
    case defaultProfile
    case profile(String)

    // MARK: Internal

    var keychainAccount: String {
        switch self {
        case .defaultProfile: "auth-session"
        case .profile(let id): "auth-session.\(id)"
        }
    }
}

// MARK: - BrowserSyncFailurePhase

enum BrowserSyncFailurePhase: Equatable, Sendable {
    case push
    case pull
}

typealias BrowserSyncErrorReporter = @MainActor (Error, BrowserSyncFailurePhase) -> Void
