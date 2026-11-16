// BrowserLaunchWarmup.swift

import AppKit

// MARK: - BrowserLaunchWarmup

/// System lookups the engine makes on the main thread the first time a page needs
/// them, started at launch on a background queue so their cost is paid there.
@objc final class BrowserLaunchWarmup: NSObject {
    @objc static func start() {
        warmSpeechVoices()
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
