import AppKit
import Testing

@Test
func browserKeyboardShortcutBuildsKeyCapsForSingleModifierShortcut() {
    let shortcut = BrowserKeyboardShortcut("t")

    #expect(shortcut.keyCaps == ["⌘", "T"])
    #expect(shortcut.displayText == "⌘T")
}

@Test
func browserKeyboardShortcutKeepsModifierOrderForTooltipKeyCaps() {
    let shortcut = BrowserKeyboardShortcut("r", modifiers: [.command, .shift])

    #expect(shortcut.keyCaps == ["⇧", "⌘", "R"])
    #expect(shortcut.displayText == "⇧⌘R")
}
