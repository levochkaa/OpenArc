// BrowserLaunchWarmupTests.swift

import Foundation
import Testing

@Test func speechVoicesWarmOffTheMainThreadAndLaterLookupsAreQuick() async {
    let ranOnMainThread = await withCheckedContinuation { continuation in
        BrowserLaunchWarmup.warmSpeechVoices { continuation.resume(returning: Thread.isMainThread) }
    }
    #expect(!ranOnMainThread)
    let start = Date()
    #expect(BrowserLaunchWarmup.defaultSpeechVoice() != nil)
    #expect(Date().timeIntervalSince(start) < 0.05, "The engine's later lookup finds the voice ready")
}
