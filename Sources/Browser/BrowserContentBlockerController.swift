// BrowserContentBlockerController.swift

import Foundation

extension BrowserContentBlocker {
    /// Hands each new set of rules to the engine that sees every request.
    static let shared = BrowserContentBlocker { rules in
        BrowserContentBlockerEngine.apply(
            blockedHosts: Array(rules.blockedHosts),
            thirdPartyHosts: Array(rules.thirdPartyHosts),
            exceptionHosts: Array(rules.exceptionHosts),
            excludedSites: rules.excludedSites,
            genericSelectors: rules.genericSelectors,
            selectorsByHost: rules.selectorsByHost,
        )
    }
}
