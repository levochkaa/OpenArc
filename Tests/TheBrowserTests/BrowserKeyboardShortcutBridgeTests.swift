import AppKit
import Testing

@Test
func layoutIndependentBridgeIgnoresShortcutsThatAlreadyMatchCurrentLayout() {
    let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 8,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "c"
    )

    #expect(command == nil)
}

@Test
func layoutIndependentBridgeMapsSelectAllWhenPhysicalShortcutDoesNotMatchLayout() {
    let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 0,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "u"
    )

    #expect(command == .selectAll)
}

@Test
func layoutIndependentBridgeMapsPasteWhenPhysicalShortcutDoesNotMatchLayout() {
    let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 9,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "m"
    )

    #expect(command == .paste)
}

@Test
func layoutIndependentBridgeMapsBrowserCommandsFromPhysicalKeys() {
    let settingsCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 43,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "б"
    )
    let newTabCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 17,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "e"
    )
    let savePageCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 1,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "w"
    )
    let copyLinkCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 8,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "с"
    )
    let clearTemporaryTabsCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 40,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "л"
    )
    let goBackCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 33,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "x"
    )

    #expect(settingsCommand == .openSettings)
    #expect(newTabCommand == .newTab)
    #expect(savePageCommand == .savePage)
    #expect(copyLinkCommand == .copyLink)
    #expect(clearTemporaryTabsCommand == .clearTemporaryTabs)
    #expect(goBackCommand == .goBack)
}
