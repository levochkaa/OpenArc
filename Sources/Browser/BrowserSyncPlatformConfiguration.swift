// BrowserSyncPlatformConfiguration.swift

import Foundation

// MARK: - BrowserHostedService

/// The switch for everything that needs an OpenArc server: accounts, sync and
/// the Beta update channel. While it is off, the apps are local only.
///
/// It needs a running server, `OPENARC_SPARKLE_FEED_URL` set to that server,
/// and a privacy policy that covers accounts.
enum BrowserHostedService {
    static let isEnabled = true
}

// MARK: - BrowserSyncDeviceIdentity

/// Supplied by the platform composition root, never inferred by the transport.
struct BrowserSyncDeviceIdentity: Equatable {
    let name: String
    let platform: String
}

// MARK: - BrowserAuthSessionNamespace

/// Default desktop credentials retain their historical Keychain account name.
/// Other profiles opt into an explicit namespace on either platform.
enum BrowserAuthSessionNamespace: Equatable {
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

enum BrowserSyncFailurePhase: Equatable {
    case push
    case pull
}

typealias BrowserSyncErrorReporter = @MainActor (Error, BrowserSyncFailurePhase) -> Void
