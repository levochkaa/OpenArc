// BrowserLaunchWarmup.swift

import AppKit

// MARK: - BrowserLaunchWarmup

/// System lookups the engine makes on the main thread the first time a page needs
/// them, started at launch on a background queue so their cost is paid there.
@objc final class BrowserLaunchWarmup: NSObject {
    /// The system library AppKit loads on the main thread the first time a menu
    /// item runs, to report it to app suggestions.
    static let menuDonationLibraryPath =
        "/System/Library/PrivateFrameworks/AppPredictionClient.framework/AppPredictionClient"

    @objc static func start() {
        warmSpeechVoices()
        warmMenuDonation()
    }

    /// Loading the library took 20 ms of the first keyboard shortcut after launch.
    static func warmMenuDonation(completion: (@Sendable () -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            _ = dlopen(menuDonationLibraryPath, RTLD_LAZY)
            completion?()
        }
    }

    /// The first default voice lookup in a process waits on the speech service for
    /// about half a second; the engine makes it when a page lists speech voices.
    static func warmSpeechVoices(completion: (@Sendable () -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = defaultSpeechVoice()
            completion?()
        }
    }

    /// The engine's call, `NSSpeechSynthesizer.defaultVoice`, made by name since
    /// the class is deprecated.
    static func defaultSpeechVoice() -> String? {
        guard let synthesizer = NSClassFromString("NSSpeechSynthesizer") as? NSObject.Type else { return nil }
        return synthesizer.perform(NSSelectorFromString("defaultVoice"))?.takeUnretainedValue() as? String
    }
}
