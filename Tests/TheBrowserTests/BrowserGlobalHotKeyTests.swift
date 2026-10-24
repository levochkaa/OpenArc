import Carbon.HIToolbox
import Testing

// MARK: - BrowserGlobalHotKeyTests

@MainActor struct BrowserGlobalHotKeyTests {
    @Test func aHotKeyHoldsItsCombinationUntilReleased() {
        // An unusual combination keeps the test from taking a real shortcut.
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        var first = BrowserGlobalHotKey(keyCode: UInt32(kVK_F19), carbonModifiers: modifiers) {}
        #expect(first != nil)
        #expect(
            BrowserGlobalHotKey(keyCode: UInt32(kVK_F19), carbonModifiers: modifiers) {} == nil,
            "A held combination cannot be taken twice"
        )
        first = nil
        #expect(BrowserGlobalHotKey(keyCode: UInt32(kVK_F19), carbonModifiers: modifiers) {} != nil)
    }
}
