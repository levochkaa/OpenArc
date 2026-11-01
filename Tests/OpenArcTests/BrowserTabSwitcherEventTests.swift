// BrowserTabSwitcherEventTests.swift

import AppKit
import Testing

@MainActor struct BrowserTabSwitcherEventTests {
    @Test func controlTabOpensTheSwitcherInBothDirections() throws {
        #expect(try BrowserTabSwitcherKeys.isSwitcherTab(key(48, [.control])))
        #expect(try BrowserTabSwitcherKeys.isSwitcherTab(key(48, [.control, .shift])))
    }

    @Test func otherTabChordsPassThrough() throws {
        #expect(try !BrowserTabSwitcherKeys.isSwitcherTab(key(48, [.option])))
        #expect(try !BrowserTabSwitcherKeys.isSwitcherTab(key(48, [.control, .command])))
        #expect(try !BrowserTabSwitcherKeys.isSwitcherTab(key(48, [])))
        #expect(try !BrowserTabSwitcherKeys.isSwitcherTab(key(49, [.control])))
    }

    private func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: keyCode,
        ))
    }
}
