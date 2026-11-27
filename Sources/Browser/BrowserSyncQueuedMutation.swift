// BrowserSyncQueuedMutation.swift

import Foundation

// MARK: - BrowserSyncQueuedMutation

/// Queue rows keep their original codec and identity across protocol upgrades.
enum BrowserSyncQueuedMutation: Equatable {
    case legacy(BrowserSyncMutation)
    case semantic(BrowserSyncSemanticMutation)
    case folders(BrowserSyncFolderMutation)
    case expiry(BrowserSyncExpiryMutation)
    case boosts(BrowserSyncBoostMutation)
    case mobileTabs(BrowserSyncMobileTabMutation)

    // MARK: Internal

    var id: String {
        switch self {
        case .legacy(let mutation): mutation.id
        case .semantic(let mutation): mutation.id
        case .folders(let mutation): mutation.id
        case .expiry(let mutation): mutation.id
        case .boosts(let mutation): mutation.id
        case .mobileTabs(let mutation): mutation.id
        }
    }

    var protocolVersion: Int {
        switch self {
        case .legacy: 2
        case .semantic: 3
        case .folders: 4
        case .expiry: 5
        case .boosts: 6
        case .mobileTabs: 7
        }
    }
}

// MARK: - BrowserSyncQueueError

enum BrowserSyncQueueError: Error, Equatable {
    case unsupportedProtocolVersion(Int)
    case protocolVersionMismatch
    case invalidMutationIdentity
    case mutationTooLarge
    case bootstrapRequiresLegacyDrain
    case expiryBootstrapRequired
    case mutationIdentityConflict
}
