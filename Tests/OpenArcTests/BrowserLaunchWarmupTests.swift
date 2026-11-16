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

@Test func theMenuDonationLibraryIsLoadedBeforeTheFirstShortcut() async {
    await withCheckedContinuation { continuation in
        BrowserLaunchWarmup.warmMenuDonation { continuation.resume() }
    }
    #expect(dlopen(BrowserLaunchWarmup.menuDonationLibraryPath, RTLD_NOLOAD) != nil)
}
